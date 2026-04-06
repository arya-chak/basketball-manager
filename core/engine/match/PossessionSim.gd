class_name PossessionSim
extends RefCounted

# ---------------------------------------------------------------------------
# PossessionSim.gd
# Simulates a single basketball possession as a chain of events.
#
# Called by MatchEngine once per possession. Receives a fully populated
# possession state dictionary and returns it completed with result fields
# and a play_events log ready for CommentaryEngine.
#
# Architecture notes:
#   - Pure logic: no DB access, no UI signals, no autoload dependencies.
#   - All randomness goes through _rng (seeded by MatchEngine for replay).
#   - ShotResolver handles all shot math; this file only routes to it.
#   - RotationManager owns fatigue state; this file reads it, never writes it.
# ---------------------------------------------------------------------------

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# ---------------------------------------------------------------------------
# Chain depth distribution — weighted toward 4 events per possession.
# Index = depth value, weight relative to sum.
# ---------------------------------------------------------------------------
const CHAIN_DEPTH_WEIGHTS: Array = [
	# depth: 3    4    5    6
	            0.20, 0.40, 0.25, 0.15
]
const CHAIN_DEPTH_MIN: int = 3

# ---------------------------------------------------------------------------
# Openness → terminal probability table.
# If a non-terminal event produces openness >= threshold, use that probability.
# Evaluated top-down; first match wins.
# ---------------------------------------------------------------------------
const OPENNESS_TERMINAL_TABLE: Array = [
	# [min_openness, terminal_probability]
	[0.90, 0.90],
	[0.60, 0.70],
	[0.30, 0.40],
	[0.00, 0.15],
]

# Flair trigger base probability — scales up with the ballhandler's flair attr.
const FLAIR_BASE_CHANCE: float    = 0.03
const FLAIR_ATTR_SCALE: float     = 0.004   # +0.4% per flair point above 10
const FLAIR_ATTR_BASELINE: int    = 10

# Shot clock threshold that forces a terminal regardless of chain state.
const SHOT_CLOCK_DESPERATION: int = 5

# Fatigue attribute penalty scale: 1.0 fatigue = -FATIGUE_PENALTY_MAX points.
const FATIGUE_PENALTY_MAX: float  = 4.0

# ---------------------------------------------------------------------------
# Seed the RNG. MatchEngine calls this before each game for replay support.
# ---------------------------------------------------------------------------
func seed_rng(seed_value: int) -> void:
	_rng.seed = seed_value

# ===========================================================================
# PUBLIC ENTRY POINT
# ===========================================================================

## simulate_possession
## Runs a complete possession from initiation to terminal.
## Mutates and returns the state dictionary.
func simulate_possession(state: Dictionary) -> Dictionary:
	# Roll max chain depth for this possession.
	state["chain_depth"]     = 0
	state["max_chain_depth"] = _roll_chain_depth()

	# Initialise output fields.
	state["result"]           = ""
	state["shot_type"]        = ""
	state["points_scored"]    = 0
	state["assist_player_id"] = -1
	state["rebounder_id"]     = -1
	state["fouler_id"]        = -1
	state["steal_player_id"]  = -1
	state["block_player_id"]  = -1
	state["play_events"]      = []

	# Select and run the initiation pattern.
	var initiation: String = _select_initiation(state)
	state = _run_initiation(initiation, state)

	# If initiation already forced a terminal (e.g. charge on a drive),
	# return immediately.
	if state["result"] != "":
		return state

	# Chain non-terminal events until a terminal fires.
	state = _run_chain(state)

	return state

# ===========================================================================
# INITIATION SELECTION
# ===========================================================================

## _select_initiation
## Picks the initiation pattern based on team tendencies and personnel.
## Returns one of the INITIATION_* string constants below.
const INITIATION_ISO:        String = "iso"
const INITIATION_PNR:        String = "pick_and_roll"
const INITIATION_PNP:        String = "pick_and_pop"
const INITIATION_POST:       String = "post_entry"
const INITIATION_MOTION:     String = "motion_entry"
const INITIATION_TRANSITION: String = "transition"

func _select_initiation(state: Dictionary) -> String:
	# Transition takes priority when flagged.
	if state.get("is_transition", false):
		return INITIATION_TRANSITION

	var ballhandler: Player = state["ballhandler"]
	var offense_five: Array = state["offense_five"]

	# Build weighted table from team tendencies + personnel.
	var weights: Dictionary = _build_initiation_weights(ballhandler, offense_five, state)
	return _weighted_choice(weights)

func _build_initiation_weights(
		ballhandler: Player,
		offense_five: Array,
		state: Dictionary) -> Dictionary:

	# Base weights — will be scaled by personnel and team tendencies.
	var w: Dictionary = {
		INITIATION_ISO:    10.0,
		INITIATION_PNR:    25.0,
		INITIATION_PNP:    10.0,
		INITIATION_POST:   15.0,
		INITIATION_MOTION: 40.0,
	}

	# High ball handling → favour ISO and PNR.
	var bh: float = _attr(ballhandler, "ball_handling")
	w[INITIATION_ISO] += (bh - 10.0) * 0.8
	w[INITIATION_PNR] += (bh - 10.0) * 0.6

	# Good passer → favour motion.
	var pv: float = _attr(ballhandler, "pass_vision")
	w[INITIATION_MOTION] += (pv - 10.0) * 0.7

	# Check if there is a quality post player on court.
	var best_post: float = _best_attr_on_court(offense_five, "post_control")
	w[INITIATION_POST] += (best_post - 10.0) * 1.0

	# Check if there is a good three-point shooter to pop to.
	var best_three: float = _best_attr_on_court(offense_five, "three_point")
	w[INITIATION_PNP] += (best_three - 10.0) * 0.8

	# Apply CoachTactics philosophy multipliers.
	# Each key in offense_initiation_weights is a multiplier built from the
	# coach's philosophy, personnel fit, and execution quality noise.
	# Falls back to the old offense_tendencies dict if no tactics object exists
	# (e.g. during unit tests or QuickSim where tactics aren't built).
	var tactics: CoachTactics = state.get("coach_tactics", null)
	if tactics != null and not tactics.offense_initiation_weights.is_empty():
		for key in tactics.offense_initiation_weights:
			if w.has(key):
				w[key] = maxf(0.0, w[key] * tactics.offense_initiation_weights[key])
	else:
		# Legacy fallback — raw multiplier dict, no execution quality noise.
		var tendencies: Dictionary = state.get("offense_tendencies", {})
		for key in tendencies:
			if w.has(key):
				w[key] = maxf(0.0, w[key] * tendencies[key])

	# Clamp all weights to non-negative.
	for key in w:
		w[key] = maxf(0.0, w[key])

	return w

# ===========================================================================
# INITIATION RUNNERS
# ===========================================================================

func _run_initiation(initiation: String, state: Dictionary) -> Dictionary:
	match initiation:
		INITIATION_ISO:        return _run_iso(state)
		INITIATION_PNR:        return _run_pick_and_roll(state)
		INITIATION_PNP:        return _run_pick_and_pop(state)
		INITIATION_POST:       return _run_post_entry(state)
		INITIATION_MOTION:     return _run_motion_entry(state)
		INITIATION_TRANSITION: return _run_transition(state)
	return state

## ISO — ballhandler goes 1-on-1.
func _run_iso(state: Dictionary) -> Dictionary:
	var bh:  Player = state["ballhandler"]
	var def: Player = state["primary_defender"]

	var off_score: float = _attr(bh, "ball_handling") * 0.5 \
		+ _attr(bh, "decision_making") * 0.3 \
		+ _attr(bh, "flair") * 0.2
	var def_score: float = _attr(def, "perimeter_defense") * 0.6 \
		+ _attr(def, "defensive_iq") * 0.4

	var openness: float = _calc_openness(off_score, def_score)
	state["current_openness"] = openness

	_log_event(state, "iso", bh.id, def.id, "initiated")
	return state

## PICK AND ROLL — ballhandler uses a screen; screener rolls to basket.
func _run_pick_and_roll(state: Dictionary) -> Dictionary:
	var bh:      Player = state["ballhandler"]
	var screener: Player = _find_best_screener(state["offense_five"], bh)
	var def:     Player = state["primary_defender"]
	var help:    Player = _find_help_defender(state["defense_five"], screener)

	# Screen quality: screener Strength vs defender Agility to fight through.
	var screen_quality: float = _attr(screener, "strength") \
		- _attr(def, "agility") * 0.7 \
		- _attr(help, "help_defense_iq") * 0.5
	screen_quality = clampf(screen_quality, -5.0, 10.0)

	# Openness for ballhandler coming off the screen.
	var off_score: float = _attr(bh, "ball_handling") * 0.5 \
		+ _attr(bh, "decision_making") * 0.3 \
		+ screen_quality * 0.8
	var def_score: float = _attr(def, "perimeter_defense") * 0.5 \
		+ _attr(help, "help_defense_iq") * 0.5

	var openness: float = _calc_openness(off_score, def_score)

	# Decide whether the ball stays with the ballhandler or goes to the roller.
	# Good screener with poor help defender → pass to roller.
	var roller_openness: float = _calc_openness(
		_attr(screener, "off_ball_movement") * 0.6 + _attr(screener, "hands") * 0.4,
		_attr(help, "interior_defense") * 0.6 + _attr(help, "help_defense_iq") * 0.4
	)

	if roller_openness > openness + 0.15 and _rng.randf() < 0.55:
		# Ball goes to the roller — hand off possession context.
		state["ballhandler"]       = screener
		state["primary_defender"]  = help
		state["current_openness"]  = roller_openness
		state["assist_player_id"]  = bh.id
		_log_event(state, "pick_and_roll_to_roller", bh.id, screener.id, "roll_pass")
	else:
		state["current_openness"] = openness
		_log_event(state, "pick_and_roll_ballhandler", bh.id, screener.id, "off_screen")

	return state

## PICK AND POP — screener pops to the three-point line.
func _run_pick_and_pop(state: Dictionary) -> Dictionary:
	var bh:      Player = state["ballhandler"]
	var popper:  Player = _find_best_three_point_player(state["offense_five"], bh)
	var def:     Player = state["primary_defender"]
	var help:    Player = _find_help_defender(state["defense_five"], popper)

	var screen_quality: float = clampf(
		_attr(popper, "strength") - _attr(def, "agility") * 0.7, -5.0, 8.0
	)

	# Popper openness — driven by their three-point shooting + off-ball movement.
	var popper_openness: float = _calc_openness(
		_attr(popper, "three_point") * 0.5 \
			+ _attr(popper, "off_ball_movement") * 0.3 \
			+ screen_quality * 0.5,
		_attr(help, "perimeter_defense") * 0.6 \
			+ _attr(help, "pass_perception") * 0.4
	)

	# Good passer → ball goes to the popper.
	var pass_success: float = _attr(bh, "pass_vision") * 0.5 \
		+ _attr(bh, "pass_iq") * 0.3 \
		+ _attr(popper, "hands") * 0.2

	if pass_success > 12.0 and _rng.randf() < 0.60:
		state["ballhandler"]      = popper
		state["primary_defender"] = help
		state["current_openness"] = popper_openness
		state["assist_player_id"] = bh.id
		_log_event(state, "pick_and_pop", bh.id, popper.id, "pop_pass")
	else:
		# Ballhandler keeps it — ISO-like situation.
		state["current_openness"] = _calc_openness(
			_attr(bh, "ball_handling") * 0.5 + screen_quality * 0.5,
			_attr(def, "perimeter_defense")
		)
		_log_event(state, "pick_and_pop_no_pass", bh.id, popper.id, "kept")

	return state

## POST ENTRY — ball entered to the post player.
func _run_post_entry(state: Dictionary) -> Dictionary:
	var bh:       Player = state["ballhandler"]
	var post_p:   Player = _find_best_post_player(state["offense_five"], bh)
	var def:      Player = state["primary_defender"]
	var post_def: Player = _get_primary_defender(post_p, state["defense_five"], state)

	# Entry pass success — passer vision vs defender pass perception.
	var entry_success: float = _attr(bh, "pass_accuracy") * 0.5 \
		+ _attr(post_p, "hands") * 0.3 \
		- _attr(post_def, "pass_perception") * 0.5

	if entry_success < 8.0 and _rng.randf() < 0.18:
		# Entry pass deflected / stolen → turnover.
		state["result"]           = "turnover"
		state["steal_player_id"]  = post_def.id
		_log_event(state, "post_entry_deflected", bh.id, post_def.id, "stolen")
		return state

	# Transfer possession to post player.
	state["ballhandler"]      = post_p
	state["primary_defender"] = post_def
	state["current_openness"] = _calc_openness(
		_attr(post_p, "post_control") * 0.5 + _attr(post_p, "strength") * 0.3,
		_attr(post_def, "interior_defense") * 0.6 + _attr(post_def, "strength") * 0.4
	)
	state["assist_player_id"] = bh.id
	_log_event(state, "post_entry", bh.id, post_p.id, "entered")
	return state

## MOTION ENTRY — ball moved to wing or corner off player movement.
func _run_motion_entry(state: Dictionary) -> Dictionary:
	var bh:     Player = state["ballhandler"]
	var target: Player = _select_motion_target(state)
	var def:    Player = _get_primary_defender(target, state["defense_five"], state)

	var off_score: float = _attr(target, "off_ball_movement") * 0.5 \
		+ _attr(bh, "pass_vision") * 0.3 \
		+ _attr(target, "shot_iq") * 0.2
	var def_score: float = _attr(def, "help_defense_iq") * 0.5 \
		+ _attr(def, "perimeter_defense") * 0.3 \
		+ _attr(def, "anticipation") * 0.2

	var openness: float = _calc_openness(off_score, def_score)

	state["ballhandler"]      = target
	state["primary_defender"] = def
	state["current_openness"] = openness
	state["assist_player_id"] = bh.id
	_log_event(state, "motion_entry", bh.id, target.id, "wing_entry")
	return state

## TRANSITION — fast break off steal or defensive rebound.
func _run_transition(state: Dictionary) -> Dictionary:
	var bh:  Player = state["ballhandler"]
	var def: Player = state["primary_defender"]

	# Defense is scrambling — base openness much higher.
	var off_score: float = _attr(bh, "speed") * 0.5 \
		+ _attr(bh, "speed_with_ball") * 0.3 \
		+ _attr(bh, "decision_making") * 0.2
	var def_score: float = _attr(def, "speed") * 0.4 \
		+ _attr(def, "help_defense_iq") * 0.4 \
		+ _attr(def, "anticipation") * 0.2

	# Transition openness has a significant bonus — defense not fully set.
	var openness: float = clampf(_calc_openness(off_score, def_score) + 0.25, 0.0, 1.0)

	state["current_openness"] = openness
	state["is_transition"]    = false   # Consumed.
	_log_event(state, "transition", bh.id, def.id, "fast_break")
	return state

# ===========================================================================
# NON-TERMINAL EVENT CHAIN
# ===========================================================================

## _run_chain
## Loops through non-terminal events until a terminal fires.
func _run_chain(state: Dictionary) -> Dictionary:
	while true:
		# Hard depth limit.
		if state["chain_depth"] >= state["max_chain_depth"]:
			state = _force_terminal(state)
			break

		# Shot clock emergency.
		if state.get("shot_clock", 24) <= SHOT_CLOCK_DESPERATION:
			state = _force_terminal(state)
			break

		# Check flair trigger before normal event routing.
		if _check_flair_trigger(state):
			state = _event_flair_play(state)
			if state["result"] != "":
				break
			continue

		# Check if current openness should terminate.
		var openness: float = state.get("current_openness", 0.3)
		var terminal_prob: float = _openness_to_terminal_prob(openness)

		if _rng.randf() < terminal_prob:
			state = _force_terminal(state)
			break

		# Otherwise, run the next non-terminal event.
		state = _run_next_non_terminal(state)

		# Non-terminal may have forced a terminal internally (e.g. charge).
		if state["result"] != "":
			break

		state["chain_depth"] += 1

	return state

## _run_next_non_terminal
## Selects and runs the contextually appropriate next event.
func _run_next_non_terminal(state: Dictionary) -> Dictionary:
	var bh:       Player = state["ballhandler"]
	var openness: float  = state.get("current_openness", 0.3)

	# Build weighted event table based on current context.
	var weights: Dictionary = _build_non_terminal_weights(state)
	var chosen:  String     = _weighted_choice(weights)

	match chosen:
		"drive_kick":   return _event_drive_kick(state)
		"swing_pass":   return _event_swing_pass(state)
		"skip_pass":    return _event_skip_pass(state)
		"hand_off":     return _event_hand_off(state)
		"cut":          return _event_cut(state)
		"screen":       return _event_screen(state)
		"oreb":         return _event_offensive_rebound(state)

	return state

func _build_non_terminal_weights(state: Dictionary) -> Dictionary:
	var bh: Player = state["ballhandler"]
	var openness: float = state.get("current_openness", 0.3)

	# Base weights.
	var w: Dictionary = {
		"drive_kick":  15.0,
		"swing_pass":  25.0,
		"skip_pass":   15.0,
		"hand_off":    10.0,
		"cut":         20.0,
		"screen":      15.0,
		"oreb":         0.0,   # Only valid after a missed shot.
	}

	# OREB is only an option after a miss registered in this chain.
	if state.get("_rebound_available", false):
		w["oreb"] = 30.0

	# Good ball handler drives and kicks.
	w["drive_kick"]  += (_attr(bh, "ball_handling") - 10.0) * 0.8
	w["drive_kick"]  += (_attr(bh, "speed_with_ball") - 10.0) * 0.5

	# Good passer favours swing and skip.
	w["swing_pass"]  += (_attr(bh, "pass_vision") - 10.0) * 0.8
	w["skip_pass"]   += (_attr(bh, "pass_accuracy") - 10.0) * 0.7

	# High openness — ballhandler is already open, drive kick is attractive.
	if openness > 0.6:
		w["drive_kick"] *= 1.4

	# Low openness — ball needs to move more, screens and cuts.
	if openness < 0.3:
		w["cut"]    *= 1.5
		w["screen"] *= 1.3

	# Clutch time — fewer flashy events, more reliable actions.
	if state.get("is_clutch", false):
		w["hand_off"] *= 0.5
		w["skip_pass"] *= 0.7
		w["swing_pass"] *= 1.3

	# Mismatch hunting — boost pass weights toward players with active mismatches.
	# CoachTactics.get_mismatch_weight_bonus() returns 0.0 if hunting is off
	# or no mismatches are active, so this is a safe no-op when not relevant.
	var tactics: CoachTactics = state.get("coach_tactics", null)
	if tactics != null:
		# Determine which event types route to a specific player.
		# We add the mismatch bonus to the events most likely to deliver the ball
		# to the mismatch target: cut, drive_kick, swing_pass, skip_pass.
		var mismatch_target_id: int = tactics.get_best_mismatch_target()
		if mismatch_target_id != -1:
			var bonus: float = tactics.get_mismatch_weight_bonus(mismatch_target_id)
			if bonus > 0.0:
				# The cut event is most likely to deliver to a specific player.
				# Swing and skip widen the passing lanes. Drive kick collapses
				# the defense and kicks to whoever is open (often the target).
				w["cut"]        += bonus * 1.2
				w["swing_pass"] += bonus * 0.8
				w["skip_pass"]  += bonus * 0.9
				w["drive_kick"] += bonus * 0.6

	for key in w:
		w[key] = maxf(0.0, w[key])

	return w

# ---------------------------------------------------------------------------
# Non-terminal event handlers
# Each updates ballhandler / defender / openness and logs an event.
# Returns the updated state. May set state["result"] for instant terminals.
# ---------------------------------------------------------------------------

## DRIVE AND KICK — ballhandler penetrates, kicks to open teammate.
func _event_drive_kick(state: Dictionary) -> Dictionary:
	var bh:     Player = state["ballhandler"]
	var def:    Player = state["primary_defender"]
	var target: Player = _select_pass_target(state, state["offense_five"])
	var t_def:  Player = _get_primary_defender(target, state["defense_five"], state)

	# Drive success: speed_with_ball + agility vs perimeter_defense.
	var drive_score: float = _fatigue_attr(bh, "speed_with_ball", state) * 0.5 \
		+ _fatigue_attr(bh, "agility", state) * 0.3 \
		+ _fatigue_attr(bh, "ball_handling", state) * 0.2
	var drive_def: float = _attr(def, "perimeter_defense") * 0.5 \
		+ _attr(def, "help_defense_iq") * 0.3 \
		+ _attr(def, "agility") * 0.2

	# If drive fails → turnover or contested shot forced.
	if drive_score < drive_def - 2.0 and _rng.randf() < 0.25:
		state["result"]  = "turnover"
		_log_event(state, "drive_kick_turnover", bh.id, def.id, "stripped")
		return state

	# Kick openness: passer vision vs help rotation.
	var kick_openness: float = _calc_openness(
		_attr(bh, "pass_vision") * 0.5 + _attr(target, "off_ball_movement") * 0.3,
		_attr(t_def, "help_defense_iq") * 0.5 + _attr(t_def, "pass_perception") * 0.3
	)

	state["ballhandler"]      = target
	state["primary_defender"] = t_def
	state["current_openness"] = kick_openness
	state["assist_player_id"] = bh.id
	_log_event(state, "drive_kick", bh.id, target.id, "kicked_out")
	return state

## SWING PASS — perimeter ball movement around the arc.
func _event_swing_pass(state: Dictionary) -> Dictionary:
	var bh:     Player = state["ballhandler"]
	var target: Player = _select_pass_target(state, state["offense_five"])
	var t_def:  Player = _get_primary_defender(target, state["defense_five"], state)

	# Pass quality vs defender anticipation.
	var pass_q: float = _fatigue_attr(bh, "pass_accuracy", state) * 0.5 \
		+ _fatigue_attr(bh, "pass_iq", state) * 0.3
	var react:  float = _attr(t_def, "anticipation") * 0.5 \
		+ _attr(t_def, "pass_perception") * 0.5

	# Bad pass → turnover risk.
	if pass_q < react - 3.0 and _rng.randf() < 0.15:
		state["result"]          = "turnover"
		state["steal_player_id"] = t_def.id
		_log_event(state, "swing_pass_intercepted", bh.id, t_def.id, "intercepted")
		return state

	var openness: float = _calc_openness(
		_attr(target, "shot_iq") * 0.4 + _attr(target, "off_ball_movement") * 0.3 + pass_q * 0.3,
		_attr(t_def, "perimeter_defense") * 0.6 + react * 0.4
	)

	state["ballhandler"]      = target
	state["primary_defender"] = t_def
	state["current_openness"] = openness
	state["assist_player_id"] = bh.id
	_log_event(state, "swing_pass", bh.id, target.id, "swung")
	return state

## SKIP PASS — ball skipped across the key to the weak side.
func _event_skip_pass(state: Dictionary) -> Dictionary:
	var bh:     Player = state["ballhandler"]
	var target: Player = _select_weak_side_target(state)
	var t_def:  Player = _get_primary_defender(target, state["defense_five"], state)

	# Skip passes are harder to complete but create bigger openness windows.
	var pass_q: float = _fatigue_attr(bh, "pass_vision", state) * 0.6 \
		+ _fatigue_attr(bh, "pass_accuracy", state) * 0.4
	var react:  float = _attr(t_def, "anticipation") * 0.6 \
		+ _attr(t_def, "pass_perception") * 0.4

	# Higher turnover risk than swing — longer distance, more telegraphed.
	if pass_q < react - 2.0 and _rng.randf() < 0.22:
		state["result"]          = "turnover"
		state["steal_player_id"] = t_def.id
		_log_event(state, "skip_pass_intercepted", bh.id, t_def.id, "intercepted")
		return state

	# Skip creates a more significant openness window when it connects.
	var base_openness: float = _calc_openness(
		_attr(target, "three_point") * 0.4 + _attr(target, "off_ball_movement") * 0.3,
		_attr(t_def, "perimeter_defense") * 0.5 + react * 0.3
	)
	var skip_bonus: float = clampf((pass_q - 12.0) * 0.03, 0.0, 0.20)
	var openness:   float = clampf(base_openness + skip_bonus, 0.0, 1.0)

	state["ballhandler"]      = target
	state["primary_defender"] = t_def
	state["current_openness"] = openness
	state["assist_player_id"] = bh.id
	_log_event(state, "skip_pass", bh.id, target.id, "skipped")
	return state

## DRIBBLE HAND-OFF — ballhandler hands off to a cutter coming by.
func _event_hand_off(state: Dictionary) -> Dictionary:
	var bh:     Player = state["ballhandler"]
	var target: Player = _select_pass_target(state, state["offense_five"])
	var def:    Player = state["primary_defender"]
	var t_def:  Player = _get_primary_defender(target, state["defense_five"], state)

	# Hand-off success driven by both players' ball handling.
	var exchange: float = (_attr(bh, "ball_handling") + _attr(target, "ball_handling")) * 0.4 \
		+ _attr(target, "speed_with_ball") * 0.3

	# Defender can jump the hand-off if high anticipation.
	if _attr(def, "anticipation") > 14 and _rng.randf() < 0.12:
		state["result"]          = "turnover"
		state["steal_player_id"] = def.id
		_log_event(state, "hand_off_stolen", bh.id, def.id, "jumped")
		return state

	var openness: float = _calc_openness(
		exchange * 0.5 + _attr(target, "agility") * 0.3,
		_attr(t_def, "perimeter_defense") * 0.5 + _attr(t_def, "agility") * 0.3
	)

	state["ballhandler"]      = target
	state["primary_defender"] = t_def
	state["current_openness"] = openness
	state["assist_player_id"] = bh.id
	_log_event(state, "hand_off", bh.id, target.id, "exchanged")
	return state

## CUT — off-ball player cuts to the basket or to a gap.
func _event_cut(state: Dictionary) -> Dictionary:
	var bh:     Player = state["ballhandler"]
	var cutter: Player = _select_cutter(state)
	var c_def:  Player = _get_primary_defender(cutter, state["defense_five"], state)

	var cut_score: float = _fatigue_attr(cutter, "off_ball_movement", state) * 0.5 \
		+ _fatigue_attr(cutter, "speed", state) * 0.3 \
		+ _fatigue_attr(cutter, "anticipation", state) * 0.2
	var def_score: float = _attr(c_def, "help_defense_iq") * 0.5 \
		+ _attr(c_def, "anticipation") * 0.3 \
		+ _attr(c_def, "agility") * 0.2

	# Passer needs to see and deliver the cut pass.
	var deliver: float = _attr(bh, "pass_vision") * 0.5 + _attr(bh, "pass_iq") * 0.3

	if deliver < 9.0 and _rng.randf() < 0.15:
		# Passer doesn't see the cut — ball stays with the ballhandler.
		# Openness slightly decreases (wasted movement).
		state["current_openness"] = maxf(0.0, state.get("current_openness", 0.3) - 0.10)
		_log_event(state, "cut_missed", bh.id, cutter.id, "unseen")
		return state

	var openness: float = _calc_openness(cut_score, def_score)

	state["ballhandler"]      = cutter
	state["primary_defender"] = c_def
	state["current_openness"] = openness
	state["assist_player_id"] = bh.id
	_log_event(state, "cut", bh.id, cutter.id, "found_cutter")
	return state

## OFF-BALL SCREEN — screen set to free a shooter or cutter.
func _event_screen(state: Dictionary) -> Dictionary:
	var screener:  Player = _find_best_screener(state["offense_five"], state["ballhandler"])
	var freed:     Player = _select_pass_target(state, state["offense_five"])
	var s_def:     Player = _get_primary_defender(freed, state["defense_five"], state)
	var bh:        Player = state["ballhandler"]

	var screen_q: float = _attr(screener, "strength") * 0.6 \
		+ _attr(screener, "off_ball_movement") * 0.4
	var fight_q:  float = _attr(s_def, "agility") * 0.5 \
		+ _attr(s_def, "help_defense_iq") * 0.5

	var freed_openness: float = _calc_openness(
		_attr(freed, "off_ball_movement") * 0.5 + screen_q * 0.5,
		fight_q * 0.7 + _attr(s_def, "pass_perception") * 0.3
	)

	# If the defense switches, update CoachTactics assignments and rescan
	# for mismatches. The switch may create a guard-on-big or big-on-guard
	# mismatch that the offense will immediately try to exploit.
	var tactics: CoachTactics = state.get("coach_tactics", null)
	if tactics != null and tactics.switch_on_screens:
		var mismatch_score: float = tactics.update_after_switch(
			screener.id,
			bh.id,
			state["offense_five"],
			state["defense_five"]
		)
		# Rescan all assignments for new mismatches created by the switch.
		tactics.scan_mismatches(state["offense_five"], state["defense_five"], _rng)
		# Re-resolve s_def after the switch — assignment may have changed.
		s_def = _get_primary_defender(freed, state["defense_five"], state)
		# If a significant mismatch was created, log it for commentary.
		if mismatch_score > 3.0:
			_log_event(state, "switch_mismatch_created", screener.id, freed.id,
				"mismatch_%.1f" % mismatch_score)

	# Pass to the freed player if passer can see them.
	var see_pass: float = _attr(bh, "pass_vision") * 0.5 + _attr(bh, "pass_iq") * 0.3
	if see_pass > 11.0 and freed_openness > 0.4 and _rng.randf() < 0.65:
		state["ballhandler"]      = freed
		state["primary_defender"] = s_def
		state["current_openness"] = freed_openness
		state["assist_player_id"] = bh.id
		_log_event(state, "screen_pass", screener.id, freed.id, "freed")
	else:
		# Screen didn't lead to a pass — slight openness boost for ballhandler.
		state["current_openness"] = clampf(
			state.get("current_openness", 0.3) + screen_q * 0.02, 0.0, 1.0
		)
		_log_event(state, "screen_no_pass", screener.id, freed.id, "no_look")

	return state

## OFFENSIVE REBOUND — second chance possession restart.
func _event_offensive_rebound(state: Dictionary) -> Dictionary:
	var rebounders: Array = state["offense_five"]
	var defenders:  Array = state["defense_five"]

	# Pick the best offensive rebounder on court.
	var o_reb: Player = _best_player_by_attr(rebounders, "offensive_rebounding")
	var d_reb: Player = _best_player_by_attr(defenders, "defensive_rebounding")

	var o_score: float = _fatigue_attr(o_reb, "offensive_rebounding", state) * 0.5 \
		+ _fatigue_attr(o_reb, "vertical", state) * 0.3 \
		+ _fatigue_attr(o_reb, "hustle", state) * 0.2
	var d_score: float = _attr(d_reb, "defensive_rebounding") * 0.5 \
		+ _attr(d_reb, "vertical") * 0.3 \
		+ _attr(d_reb, "strength") * 0.2

	if _rng.randf() > (o_score / (o_score + d_score)):
		# Defense gets the board — possession ends.
		state["result"]        = "defensive_rebound"
		state["rebounder_id"]  = d_reb.id
		_log_event(state, "defensive_rebound", d_reb.id, o_reb.id, "secured")
		return state

	# Offense gets the board — reset with new ballhandler and low openness.
	state["ballhandler"]       = o_reb
	state["primary_defender"]  = _get_primary_defender(o_reb, defenders, state)
	state["current_openness"]  = 0.25   # Defense is reset; openness is low.
	state["_rebound_available"] = false
	state["rebounder_id"]       = o_reb.id
	_log_event(state, "offensive_rebound", o_reb.id, d_reb.id, "tipped")
	return state

# ===========================================================================
# FLAIR PLAYS
# ===========================================================================

## _check_flair_trigger
## Returns true if a flair play should override the next normal event.
func _check_flair_trigger(state: Dictionary) -> bool:
	var bh:    Player = state["ballhandler"]
	var flair: float  = _attr(bh, "flair")

	# Flair triggers are more likely in transition and with high-flair players.
	var chance: float = FLAIR_BASE_CHANCE \
		+ (flair - FLAIR_ATTR_BASELINE) * FLAIR_ATTR_SCALE
	if state.get("is_transition", false):
		chance += 0.04

	# Flair triggers less in clutch time — players get serious.
	if state.get("is_clutch", false):
		chance *= 0.5

	return _rng.randf() < clampf(chance, 0.0, 0.25)

## _event_flair_play
## Resolves a flair event. These can be positive (highlight play) or
## negative (turnover from low Composure + high risk).
func _event_flair_play(state: Dictionary) -> Dictionary:
	var bh:        Player = state["ballhandler"]
	var flair:     float  = _attr(bh, "flair")
	var composure: float  = _attr(bh, "composure")

	# Risk of a flair play failing: high flair + low composure = volatile.
	var fail_chance: float = clampf((flair - composure) * 0.04, 0.0, 0.40)

	if _rng.randf() < fail_chance:
		# Spectacular failure — turnover.
		state["result"] = "turnover"
		_log_event(state, "flair_turnover", bh.id, -1, "lost_it")
		return state

	# Success — pick a flair play type based on position and attributes.
	var play_type: String = _pick_flair_play_type(bh)
	match play_type:
		"no_look_pass":
			# Ball goes to a teammate in a great spot.
			var target: Player = _select_pass_target(state, state["offense_five"])
			var t_def:  Player = _get_primary_defender(target, state["defense_five"], state)
			state["ballhandler"]      = target
			state["primary_defender"] = t_def
			state["current_openness"] = clampf(
				_calc_openness(
					_attr(target, "off_ball_movement") * 0.6,
					_attr(t_def, "help_defense_iq") * 0.5
				) + 0.20, 0.0, 1.0   # No-look passes create extra openness.
			)
			state["assist_player_id"] = bh.id
			_log_event(state, "flair_no_look", bh.id, target.id, "no_look")

		"euro_step":
			# Drives baseline and goes to the rim — force terminal.
			state["current_openness"] = clampf(
				_calc_openness(
					_attr(bh, "agility") * 0.6 + _attr(bh, "layup") * 0.4,
					_attr(state["primary_defender"], "interior_defense") * 0.5
				) + 0.15, 0.0, 1.0
			)
			_log_event(state, "flair_euro_step", bh.id, -1, "step_through")
			state = _force_terminal(state)

		"alley_oop":
			# Lob to the best athlete on the floor.
			var lob_target: Player = _best_player_by_attr(state["offense_five"], "vertical")
			var l_def:      Player = _get_primary_defender(lob_target, state["defense_five"], state)
			# High openness — either a dunk or a turnover, nothing in between.
			state["ballhandler"]      = lob_target
			state["primary_defender"] = l_def
			state["current_openness"] = 0.85
			state["assist_player_id"] = bh.id
			_log_event(state, "flair_alley_oop", bh.id, lob_target.id, "lob")
			state = _force_terminal(state)

	return state

func _pick_flair_play_type(player: Player) -> String:
	# Weight by position and attributes.
	var w: Dictionary = {
		"no_look_pass": _attr(player, "pass_vision") * 0.8,
		"euro_step":    _attr(player, "agility") * 0.6 + _attr(player, "speed_with_ball") * 0.4,
		"alley_oop":    _attr(player, "pass_vision") * 0.5 + _attr(player, "vertical") * 0.3,
	}
	# Guards favour no-look passes, big men favour alley-oop receipts.
	match player.position:
		Player.Position.PG, Player.Position.SG:
			w["no_look_pass"] *= 1.5
			w["euro_step"]    *= 1.3
		Player.Position.C, Player.Position.PF:
			w["alley_oop"]    *= 1.6
			w["euro_step"]    *= 0.5
	return _weighted_choice(w)

# ===========================================================================
# TERMINAL RESOLUTION
# ===========================================================================

## _force_terminal
## Picks the appropriate terminal based on context and routes to ShotResolver.
## ShotResolver is called externally by MatchEngine after this returns;
## this function just sets up the shot type and calls the resolver hook.
func _force_terminal(state: Dictionary) -> Dictionary:
	var bh:  Player = state["ballhandler"]
	var def: Player = state["primary_defender"]

	# Check if a foul occurs before the shot.
	var foul_check: Dictionary = _check_non_shooting_foul(state)
	if foul_check["fouled"]:
		state["result"]   = "foul_non_shooting"
		state["fouler_id"] = foul_check["fouler_id"]
		_log_event(state, "foul_non_shooting", bh.id, foul_check["fouler_id"], "foul")
		return state

	# Determine the shot type based on the ballhandler's position + attributes.
	var shot_type: String = _select_shot_type(bh, state)
	state["shot_type"] = shot_type

	# The actual shot math (make/miss/foul/block) is handled by ShotResolver.
	# Mark state as ready for resolution.
	state["_awaiting_shot_resolution"] = true
	_log_event(state, "shot_attempt", bh.id, def.id, shot_type)

	return state

## _select_shot_type
## Picks the most contextually appropriate shot type for the ballhandler.
func _select_shot_type(player: Player, state: Dictionary) -> String:
	var openness: float     = state.get("current_openness", 0.3)
	var in_post:  bool      = state.get("_in_post", false)
	var transition: bool    = state.get("is_transition", false)

	# Build weighted shot type table.
	var w: Dictionary = {}

	# Post shots — only if player is in post.
	if in_post or player.position in [Player.Position.PF, Player.Position.C]:
		w["post_hook"]  = _attr(player, "post_hook")  * 1.0
		w["post_fade"]  = _attr(player, "post_fade")  * 0.8
		w["close_shot"] = _attr(player, "close_shot") * 0.6

	# Rim attacks — transition and driving players.
	if transition or _attr(player, "driving_dunk") > 12:
		w["driving_dunk"] = _attr(player, "driving_dunk") * 1.0
		w["layup"]        = _attr(player, "layup") * 1.0

	# Perimeter shots — higher openness favours pull-up.
	if openness > 0.5:
		w["three_point"] = _attr(player, "three_point") * 1.2
		w["mid_range"]   = _attr(player, "mid_range") * 0.9

	# Fallback: always have some options available.
	if w.is_empty() or _sum_weights(w) < 1.0:
		w["layup"]      = _attr(player, "layup") * 0.8
		w["mid_range"]  = _attr(player, "mid_range") * 0.8
		w["three_point"] = _attr(player, "three_point") * 0.6

	# Shot IQ scales all shot types — low IQ players take worse shots.
	var iq_scale: float = clampf(_attr(player, "shot_iq") / 15.0, 0.6, 1.0)
	for key in w:
		w[key] *= iq_scale

	return _weighted_choice(w)

func _check_non_shooting_foul(state: Dictionary) -> Dictionary:
	# Small chance of a non-shooting foul before the shot.
	# Defender's defensive_consistency inversely drives foul risk.
	var def: Player = state["primary_defender"]
	var bh:  Player = state["ballhandler"]

	var foul_chance: float = 0.04
	foul_chance += (10.0 - _attr(def, "defensive_consistency")) * 0.005
	foul_chance += (_attr(bh, "draw_foul") - 10.0) * 0.003
	foul_chance = clampf(foul_chance, 0.0, 0.12)

	if _rng.randf() < foul_chance:
		return {"fouled": true, "fouler_id": def.id}
	return {"fouled": false, "fouler_id": -1}

# ===========================================================================
# PLAYER SELECTION HELPERS
# ===========================================================================

## Finds the best screener on court (not the ballhandler).
func _find_best_screener(five: Array, exclude: Player) -> Player:
	return _best_player_by_attr_excluding(five, "strength", exclude)

## Finds the best three-point shooter on court (not the ballhandler).
func _find_best_three_point_player(five: Array, exclude: Player) -> Player:
	return _best_player_by_attr_excluding(five, "three_point", exclude)

## Finds the best post player on court (not the ballhandler).
func _find_best_post_player(five: Array, exclude: Player) -> Player:
	return _best_player_by_attr_excluding(five, "post_control", exclude)

## Finds the help defender most relevant to a given offensive player.
func _find_help_defender(defense_five: Array, offensive_target: Player) -> Player:
	# Help defender is the one with the highest help_defense_iq
	# who is NOT already the primary defender on the ballhandler.
	return _best_player_by_attr(defense_five, "help_defense_iq")

## Selects the primary defender matched up against a given offensive player.
## Consults CoachTactics defensive assignments first (respects switches,
## lock-ons, and zone coverage). Falls back to positional matching when
## no tactics object is present (QuickSim / unit test contexts).
func _get_primary_defender(offensive_player: Player, defense_five: Array, state: Dictionary = {}) -> Player:
	if defense_five.is_empty():
		return offensive_player   # Fallback: never returns null.

	# CoachTactics path — assignment-aware lookup.
	var tactics: CoachTactics = state.get("coach_tactics", null)
	if tactics != null:
		var assigned: Player = tactics.get_defender_for(offensive_player.id, defense_five)
		if assigned != null:
			return assigned

	# Legacy fallback — positional matching used when no tactics object exists.
	var same_pos: Array = []
	for d in defense_five:
		if d.position == offensive_player.position:
			same_pos.append(d)

	if not same_pos.is_empty():
		return _best_player_by_attr(same_pos, "defensive_iq")

	return _best_player_by_attr(defense_five, "defensive_iq")

## Selects a target for a pass from the offense_five (excluding ballhandler).
func _select_pass_target(state: Dictionary, candidates: Array) -> Player:
	var bh:     Player    = state["ballhandler"]
	var scored: Dictionary = {}

	for p in candidates:
		if p.id == bh.id:
			continue
		# Score candidates by openness potential + shot readiness.
		var def: Player = _get_primary_defender(p, state["defense_five"], state)
		var off: float  = _attr(p, "off_ball_movement") * 0.4 \
			+ _attr(p, "shot_iq") * 0.3 \
			+ _attr(p, "three_point") * 0.2 \
			+ _attr(p, "hands") * 0.1
		var dfs: float  = _attr(def, "help_defense_iq") * 0.5 \
			+ _attr(def, "perimeter_defense") * 0.5
		scored[p.id] = maxf(0.1, off - dfs * 0.6 + _rng.randf_range(-1.5, 1.5))

	if scored.is_empty():
		return bh   # Fallback.

	# Pick the best-scored target.
	var best_id: int   = -1
	var best_sc: float = -INF
	for pid in scored:
		if scored[pid] > best_sc:
			best_sc = scored[pid]
			best_id = pid

	for p in candidates:
		if p.id == best_id:
			return p
	return bh

## Selects a weak-side target for a skip pass.
func _select_weak_side_target(state: Dictionary) -> Player:
	# Weak-side targets are perimeter shooters — prefer high three_point attr.
	var candidates: Array = []
	for p in state["offense_five"]:
		if p.id != state["ballhandler"].id:
			candidates.append(p)
	if candidates.is_empty():
		return state["ballhandler"]
	return _best_player_by_attr(candidates, "three_point")

## Selects the best cutter for a cut event.
func _select_cutter(state: Dictionary) -> Player:
	var candidates: Array = []
	for p in state["offense_five"]:
		if p.id != state["ballhandler"].id:
			candidates.append(p)
	if candidates.is_empty():
		return state["ballhandler"]
	return _best_player_by_attr(candidates, "off_ball_movement")

## Selects the best motion-entry target (wing catch-and-shoot candidate).
func _select_motion_target(state: Dictionary) -> Player:
	var bh: Player = state["ballhandler"]
	var candidates: Array = []
	for p in state["offense_five"]:
		if p.id != bh.id:
			candidates.append(p)
	if candidates.is_empty():
		return bh
	# Prefer wings with good shot_iq and off_ball_movement.
	var best: Player = candidates[0]
	var best_score: float = -INF
	for p in candidates:
		var s: float = _attr(p, "shot_iq") * 0.5 + _attr(p, "off_ball_movement") * 0.5
		if s > best_score:
			best_score = s
			best = p
	return best

# ===========================================================================
# ATTRIBUTE & FATIGUE HELPERS
# ===========================================================================

## Returns a player attribute as a float, applying no fatigue.
func _attr(player: Player, attr_name: String) -> float:
	return float(player.get(attr_name))

## Returns a player attribute with fatigue penalty applied.
func _fatigue_attr(player: Player, attr_name: String, state: Dictionary) -> float:
	var base: float   = _attr(player, attr_name)
	var fatigue: float = state.get("fatigue", {}).get(player.id, 0.0)
	return base - fatigue * FATIGUE_PENALTY_MAX

## Calculates openness (0.0–1.0) from offensive and defensive scores.
## Uses a sigmoid-like mapping so extreme differences don't produce 0 or 1.
func _calc_openness(off_score: float, def_score: float) -> float:
	var diff: float = off_score - def_score
	# Normalise: diff of +5 ≈ 0.85 openness, diff of -5 ≈ 0.15.
	return clampf(0.5 + diff * 0.07, 0.0, 1.0)

## Returns the best value of an attribute across all players in a five.
func _best_attr_on_court(five: Array, attr_name: String) -> float:
	var best: float = 0.0
	for p in five:
		var v: float = _attr(p, attr_name)
		if v > best:
			best = v
	return best

## Returns the player with the highest value of an attribute.
func _best_player_by_attr(players: Array, attr_name: String) -> Player:
	var best: Player = players[0]
	var best_val: float = -INF
	for p in players:
		var v: float = _attr(p, attr_name)
		if v > best_val:
			best_val = v
			best = p
	return best

## Returns the player with the highest attribute value, excluding one player.
func _best_player_by_attr_excluding(
		players: Array,
		attr_name: String,
		exclude: Player) -> Player:
	var candidates: Array = []
	for p in players:
		if p.id != exclude.id:
			candidates.append(p)
	if candidates.is_empty():
		return exclude
	return _best_player_by_attr(candidates, attr_name)

# ===========================================================================
# OPENNESS → TERMINAL PROBABILITY
# ===========================================================================

func _openness_to_terminal_prob(openness: float) -> float:
	for entry in OPENNESS_TERMINAL_TABLE:
		if openness >= entry[0]:
			return entry[1]
	return 0.15

# ===========================================================================
# CHAIN DEPTH ROLL
# ===========================================================================

func _roll_chain_depth() -> int:
	# Weighted roll over CHAIN_DEPTH_WEIGHTS.
	var total: float = 0.0
	for w in CHAIN_DEPTH_WEIGHTS:
		total += w
	var r: float = _rng.randf() * total
	var acc: float = 0.0
	for i in CHAIN_DEPTH_WEIGHTS.size():
		acc += CHAIN_DEPTH_WEIGHTS[i]
		if r < acc:
			return CHAIN_DEPTH_MIN + i
	return CHAIN_DEPTH_MIN + CHAIN_DEPTH_WEIGHTS.size() - 1

# ===========================================================================
# WEIGHTED RANDOM CHOICE
# ===========================================================================

## Picks a key from a Dictionary of {key: weight} using weighted randomness.
func _weighted_choice(weights: Dictionary) -> String:
	var total: float = 0.0
	for key in weights:
		total += weights[key]
	if total <= 0.0:
		return weights.keys()[0]

	var r: float = _rng.randf() * total
	var acc: float = 0.0
	for key in weights:
		acc += weights[key]
		if r < acc:
			return key
	return weights.keys()[-1]

func _sum_weights(w: Dictionary) -> float:
	var total: float = 0.0
	for key in w:
		total += w[key]
	return total

# ===========================================================================
# PLAY-BY-PLAY EVENT LOGGING
# ===========================================================================

## Appends a structured event to the possession's play_events log.
## CommentaryEngine reads these after the full possession to generate text.
func _log_event(
		state: Dictionary,
		event_type: String,
		primary_id: int,
		secondary_id: int,
		result: String) -> void:

	state["play_events"].append({
		"quarter":             state.get("quarter", 1),
		"clock_seconds":       state.get("clock_seconds", 0),
		"shot_clock":          state.get("shot_clock", 24),
		"team":                state.get("offense_team_id", ""),
		"event":               event_type,
		"primary_player_id":   primary_id,
		"secondary_player_id": secondary_id,
		"result":              result,
		"openness":            state.get("current_openness", 0.0),
		"is_clutch":           state.get("is_clutch", false),
		"chain_depth":         state.get("chain_depth", 0),
	})
