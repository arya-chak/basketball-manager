class_name CoachTactics
extends RefCounted

# ---------------------------------------------------------------------------
# CoachTactics.gd
# The match-time tactics object. Built by MatchEngine at the start of each
# game from a Coach entity and the current roster, then injected into every
# possession state dictionary.
#
# Separates two concerns that often get conflated:
#   - What the coach WANTS to do (philosophy, preferences)
#   - How WELL they can execute it (coaching attributes → execution quality)
#
# All sim-facing values are pre-computed floats and dictionaries so
# PossessionSim never needs to reference the Coach entity directly.
# The possession state just reads from this object.
#
# Mutable during a game — in-game adjustments overwrite the base values.
# The base values (from build()) are cached so half-time resets work cleanly.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Offensive philosophy weights
# Injected directly into PossessionSim._build_initiation_weights() as
# the offense_tendencies multiplier table.
# Keys match PossessionSim's INITIATION_* constants.
# ---------------------------------------------------------------------------

var offense_initiation_weights: Dictionary = {}

# ---------------------------------------------------------------------------
# Defensive setup
# ---------------------------------------------------------------------------

var defense_philosophy: int = 0   # Coach.DefensePhilosophy enum value

# Whether the defense switches on screens this game.
# Affects _event_screen() in PossessionSim and assignment updates.
var switch_on_screens: bool = false

# Whether the defense is packing the paint.
# Applied as a modifier in ShotResolver: interior shots harder, threes easier.
var pack_the_paint: bool = false

# Whether the defense is pressing.
# Applied in transition: higher steal chance on opponent ball advances.
var press_active: bool = false

# ---------------------------------------------------------------------------
# Defensive assignments
# Built at match start. Updated after switches.
# Maps offensive_player_id (int) -> defensive_player_id (int)
# ---------------------------------------------------------------------------

var defensive_assignments: Dictionary = {}

# Reverse map for fast lookup: defensive_player_id -> offensive_player_id
var _assignment_reverse: Dictionary = {}

# ---------------------------------------------------------------------------
# Mismatch state
# Updated by PossessionSim after every screen/assignment change.
# Maps offensive_player_id -> mismatch_score (float, positive = offense advantage)
# ---------------------------------------------------------------------------

var active_mismatches: Dictionary = {}

# ---------------------------------------------------------------------------
# Execution quality (0.0–1.0)
# Pre-computed from coach attributes. Read by PossessionSim when applying
# noise to philosophy weights and mismatch detection.
# ---------------------------------------------------------------------------

var offense_execution_quality: float = 0.5
var defense_execution_quality: float = 0.5
var tactical_read_quality: float     = 0.5   # Mismatch detection + exploitation

# ---------------------------------------------------------------------------
# Pace
# Multiplier on base possessions per game (~100). Applied by MatchEngine
# when deciding how many possessions to simulate.
# ---------------------------------------------------------------------------

var pace_target: float = 1.0   # 0.8 (slow) – 1.2 (push pace)

# ---------------------------------------------------------------------------
# Player strength targeting
# If hunt_mismatches is true, PossessionSim boosts pass weights toward
# players with active mismatches in their favour.
# ---------------------------------------------------------------------------

var hunt_mismatches: bool = true

# ---------------------------------------------------------------------------
# Motivation bonus
# Flat attribute bonus applied to all players on this team at match start.
# Represents pre-game team talk quality. Applied by MatchEngine before sim.
# ---------------------------------------------------------------------------

var motivation_bonus: float = 0.0

# ---------------------------------------------------------------------------
# Stamina drain modifier
# Applied by RotationManager each possession. <1.0 = slower fatigue.
# ---------------------------------------------------------------------------

var stamina_drain_modifier: float = 1.0

# ---------------------------------------------------------------------------
# Specific player assignments — in-game tactical decisions
# ---------------------------------------------------------------------------

# Lock a specific defender onto a specific offensive player regardless of
# positional matching. Set by the coach ("put our best defender on #23").
# -1 = no lock.
var defensive_focus_player_id: int = -1   # Offensive player being locked down
var lock_defender_id: int          = -1   # Defender assigned to lock them

# ---------------------------------------------------------------------------
# Cached base values — restored on half-time reset or in-game undo
# ---------------------------------------------------------------------------

var _base_offense_weights: Dictionary = {}
var _base_switch_on_screens: bool     = false
var _base_pack_the_paint: bool        = false
var _base_press_active: bool          = false
var _base_pace_target: float          = 1.0

# ---------------------------------------------------------------------------
# BUILD — called by MatchEngine at match start
# ---------------------------------------------------------------------------

## build
## Constructs all tactics from a Coach entity and the team's on-court roster.
## offense_five / defense_five are the starting lineups (Array of Player).
## rng is passed in so weight noise is seeded deterministically.
static func build(
		coach: Coach,
		offense_five: Array,
		defense_five: Array,
		rng: RandomNumberGenerator) -> CoachTactics:

	var ct := CoachTactics.new()

	# Execution quality from coach attributes.
	ct.offense_execution_quality = coach.get_offense_execution_quality()
	ct.defense_execution_quality = coach.get_defense_execution_quality()
	ct.tactical_read_quality     = coach.get_tactical_read_quality()
	ct.motivation_bonus          = coach.get_motivation_bonus()
	ct.stamina_drain_modifier    = coach.get_stamina_drain_modifier()

	# Pace.
	ct.pace_target = coach.pref_pace_target

	# Mismatch hunting.
	ct.hunt_mismatches = coach.pref_hunt_mismatches

	# Defense setup.
	ct.defense_philosophy  = coach.preferred_defense
	ct.switch_on_screens   = coach.pref_switch_on_screens
	ct.pack_the_paint      = coach.pref_paint_protection
	ct.press_active        = coach.pref_press_full_court

	# Build offensive initiation weights from philosophy + personnel + coach quality.
	ct.offense_initiation_weights = ct._build_offense_weights(
		coach.preferred_offense,
		offense_five,
		coach.get_offense_execution_quality(),
		rng
	)

	# Build initial defensive assignments.
	ct.defensive_assignments = ct._build_initial_assignments(
		offense_five, defense_five, coach
	)
	ct._rebuild_reverse_map()

	# Cache base values for in-game reset.
	ct._base_offense_weights  = ct.offense_initiation_weights.duplicate()
	ct._base_switch_on_screens = ct.switch_on_screens
	ct._base_pack_the_paint    = ct.pack_the_paint
	ct._base_press_active      = ct.press_active
	ct._base_pace_target       = ct.pace_target

	return ct

# ---------------------------------------------------------------------------
# OFFENSIVE WEIGHT BUILDING
# ---------------------------------------------------------------------------

## _build_offense_weights
## Translates the coach's offensive philosophy into initiation weight
## multipliers for PossessionSim. Applies execution quality noise —
## a poor coach running Pace & Space doesn't execute it cleanly.
func _build_offense_weights(
		philosophy: int,
		offense_five: Array,
		quality: float,
		rng: RandomNumberGenerator) -> Dictionary:

	# Base multipliers — 1.0 means unmodified PossessionSim default.
	var w: Dictionary = {
		"iso":           1.0,
		"pick_and_roll": 1.0,
		"pick_and_pop":  1.0,
		"post_entry":    1.0,
		"motion_entry":  1.0,
	}

	# Apply philosophy-specific multipliers.
	match philosophy:
		Coach.OffensePhilosophy.PACE_AND_SPACE:
			w["pick_and_pop"]  = 1.8
			w["motion_entry"]  = 1.5
			w["pick_and_roll"] = 1.3
			w["post_entry"]    = 0.4
			w["iso"]           = 0.7

		Coach.OffensePhilosophy.ISO_HEAVY:
			w["iso"]           = 2.2
			w["pick_and_roll"] = 1.4
			w["motion_entry"]  = 0.5
			w["post_entry"]    = 0.8
			w["pick_and_pop"]  = 0.7

		Coach.OffensePhilosophy.POST_UP:
			w["post_entry"]    = 2.5
			w["pick_and_roll"] = 1.2
			w["iso"]           = 0.8
			w["pick_and_pop"]  = 0.6
			w["motion_entry"]  = 0.7

		Coach.OffensePhilosophy.BALL_MOVEMENT:
			w["motion_entry"]  = 2.0
			w["pick_and_roll"] = 1.4
			w["pick_and_pop"]  = 1.2
			w["iso"]           = 0.5
			w["post_entry"]    = 0.8

		Coach.OffensePhilosophy.TRANSITION_FIRST:
			# Transition is handled separately in PossessionSim (flagged by
			# MatchEngine after steals/defensive rebounds). Here we reduce
			# half-court initiation weights to match the philosophy.
			w["iso"]           = 0.9
			w["pick_and_roll"] = 1.1
			w["motion_entry"]  = 1.0
			w["post_entry"]    = 0.6
			w["pick_and_pop"]  = 0.8

	# Apply personnel fit — boost philosophies that match what's on court.
	w = _apply_personnel_fit(w, offense_five, philosophy)

	# Apply execution quality noise.
	# A perfect coach (quality=1.0) executes cleanly. A poor coach (0.0) drifts
	# toward random — all weights pulled toward 1.0 proportionally.
	var noise_strength: float = 1.0 - quality   # 0.0 = no noise, 1.0 = full drift
	for key in w:
		var drift: float = (1.0 - w[key]) * noise_strength
		var variance: float = rng.randf_range(-0.10, 0.10) * noise_strength
		w[key] = maxf(0.1, w[key] + drift * 0.6 + variance)

	return w

## _apply_personnel_fit
## Boosts or penalises philosophies based on whether the roster supports them.
## Pace & Space needs shooters. Post Up needs a real post player.
## A mismatch between philosophy and personnel costs effectiveness.
func _apply_personnel_fit(
		w: Dictionary,
		five: Array,
		philosophy: int) -> Dictionary:

	# Count shooters (three_point >= 14) and post players (post_control >= 14).
	var shooters: int   = 0
	var post_players: int = 0
	var athletes: int   = 0   # speed >= 14
	for p in five:
		if p.three_point >= 14:   shooters += 1
		if p.post_control >= 14:  post_players += 1
		if p.speed >= 14:         athletes += 1

	match philosophy:
		Coach.OffensePhilosophy.PACE_AND_SPACE:
			# Needs shooters to space the floor.
			var fit: float = clampf(shooters / 3.0, 0.3, 1.2)
			w["pick_and_pop"] *= fit
			w["motion_entry"] *= fit

		Coach.OffensePhilosophy.POST_UP:
			# Needs an actual post player.
			var fit: float = clampf(post_players / 1.5, 0.3, 1.3)
			w["post_entry"] *= fit

		Coach.OffensePhilosophy.TRANSITION_FIRST:
			# Needs athletes.
			var fit: float = clampf(athletes / 2.0, 0.4, 1.2)
			w["motion_entry"] *= fit

	return w

# ---------------------------------------------------------------------------
# DEFENSIVE ASSIGNMENT BUILDING
# ---------------------------------------------------------------------------

## _build_initial_assignments
## Creates the starting defensive assignment map.
## Philosophy determines how the map is built:
##   MAN / SWITCHING / PRESS: positional matching (best fit first)
##   ZONE: no individual assignments (map left empty — zone logic in ShotResolver)
##   PACK_THE_PAINT: positional matching but help rotations favour the paint
func _build_initial_assignments(
		offense_five: Array,
		defense_five: Array,
		coach: Coach) -> Dictionary:

	var assignments: Dictionary = {}

	# Zone uses pooled coverage — no individual assignments.
	if coach.preferred_defense == Coach.DefensePhilosophy.ZONE_2_3:
		return assignments

	# All other philosophies: match by position, then by defensive rating.
	var unassigned_defenders: Array = defense_five.duplicate()

	# Sort offensive players by importance (tier desc) so the best offensive
	# players get matched first — the defense prioritises stopping stars.
	var sorted_offense: Array = offense_five.duplicate()
	sorted_offense.sort_custom(func(a, b): return a.tier > b.tier)

	for off_player in sorted_offense:
		if unassigned_defenders.is_empty():
			break

		var best_defender: Player = null
		var best_score: float     = -INF

		for defender in unassigned_defenders:
			var score: float = _defender_match_score(off_player, defender, coach)
			if score > best_score:
				best_score    = score
				best_defender = defender

		if best_defender != null:
			assignments[off_player.id] = best_defender.id
			unassigned_defenders.erase(best_defender)

	# Apply lock-on override: force the designated defender onto the target.
	if coach.pref_hunt_mismatches == false:
		pass  # No override; use pure positional matching.

	return assignments

## _defender_match_score
## Scores how well a defender matches up against an offensive player.
## Higher = better fit. Used to rank defenders during assignment building.
func _defender_match_score(
		off_player: Player,
		defender: Player,
		coach: Coach) -> float:

	var score: float = 0.0

	# Positional match bonus — same position is usually best.
	if defender.position == off_player.position:
		score += 5.0
	elif abs(int(defender.position) - int(off_player.position)) == 1:
		score += 2.0   # Adjacent position (e.g., SG on SF) is acceptable.

	# Defensive attributes relevant to the offensive player's strengths.
	match off_player.position:
		Player.Position.PG, Player.Position.SG:
			score += float(defender.perimeter_defense) * 0.5
			score += float(defender.agility) * 0.3
			score += float(defender.steal) * 0.2

		Player.Position.SF:
			score += float(defender.perimeter_defense) * 0.35
			score += float(defender.interior_defense) * 0.25
			score += float(defender.strength) * 0.2
			score += float(defender.help_defense_iq) * 0.2

		Player.Position.PF, Player.Position.C:
			score += float(defender.interior_defense) * 0.5
			score += float(defender.strength) * 0.3
			score += float(defender.block) * 0.2

	# Tactical Flexibility bonus: better coaches make smarter matchups.
	score += float(coach.tactical_flexibility) * 0.3

	return score

# ---------------------------------------------------------------------------
# ASSIGNMENT UPDATES — called by PossessionSim during screen events
# ---------------------------------------------------------------------------

## update_after_switch
## Called when the defense switches on a screen.
## Swaps the defenders assigned to the two offensive players involved.
## Returns the mismatch score created by the switch (positive = offense wins).
func update_after_switch(
		screener_id: int,
		ball_handler_id: int,
		offense_five: Array,
		defense_five: Array) -> float:

	if not switch_on_screens:
		return 0.0

	var bh_defender_id:  int = defensive_assignments.get(ball_handler_id, -1)
	var scr_defender_id: int = defensive_assignments.get(screener_id, -1)

	if bh_defender_id == -1 or scr_defender_id == -1:
		return 0.0

	# Swap assignments.
	defensive_assignments[ball_handler_id] = scr_defender_id
	defensive_assignments[screener_id]     = bh_defender_id
	_rebuild_reverse_map()

	# Calculate the mismatch created.
	var ball_handler: Player = _find_player(offense_five, ball_handler_id)
	var new_defender: Player = _find_player(defense_five, scr_defender_id)

	if ball_handler == null or new_defender == null:
		return 0.0

	return _calc_mismatch_score(ball_handler, new_defender)

## get_defender_for
## Returns the current assigned defender for an offensive player.
## Falls back to positional matching if no assignment exists (zone, or error).
func get_defender_for(
		offensive_player_id: int,
		defense_five: Array) -> Player:

	var defender_id: int = defensive_assignments.get(offensive_player_id, -1)
	if defender_id == -1:
		# Zone or unassigned — return best defensive fit by IQ.
		return _best_defender_by_iq(defense_five)

	return _find_player(defense_five, defender_id)

# ---------------------------------------------------------------------------
# MISMATCH SCANNING
# ---------------------------------------------------------------------------

## scan_mismatches
## Evaluates every offensive player vs their current assigned defender.
## Populates active_mismatches with scores. Called after any assignment change.
## Gated by tactical_read_quality — poor coaches miss mismatches that exist.
func scan_mismatches(
		offense_five: Array,
		defense_five: Array,
		rng: RandomNumberGenerator) -> void:

	active_mismatches.clear()

	for off_player in offense_five:
		var defender: Player = get_defender_for(off_player.id, defense_five)
		if defender == null:
			continue

		var raw_score: float = _calc_mismatch_score(off_player, defender)

		# Mismatch must exceed a threshold to register.
		if raw_score < 2.0:
			continue

		# Detection gated by tactical_read_quality.
		# A poor coach (0.0) has a 20% base detection rate.
		# An elite coach (1.0) detects everything above threshold.
		var detect_chance: float = 0.20 + tactical_read_quality * 0.80
		if rng.randf() > detect_chance:
			continue   # Coach missed this mismatch.

		# Store it.
		active_mismatches[off_player.id] = raw_score

## _calc_mismatch_score
## Returns a positive float if the offensive player has an advantage,
## negative if the defender is winning the matchup, 0 if even.
## Considers multiple attribute pairs relevant to each position combo.
func _calc_mismatch_score(off_player: Player, defender: Player) -> float:
	var score: float = 0.0

	# Perimeter mismatch: guard/wing vs big who switched.
	if off_player.position in [Player.Position.PG, Player.Position.SG] and \
	   defender.position in [Player.Position.PF, Player.Position.C]:
		score += float(off_player.speed_with_ball) - float(defender.agility)
		score += float(off_player.three_point) - float(defender.perimeter_defense)
		score *= 1.2   # Guard-on-big is a significant mismatch type.

	# Post mismatch: big vs small who switched.
	elif off_player.position in [Player.Position.PF, Player.Position.C] and \
		 defender.position in [Player.Position.PG, Player.Position.SG]:
		score += float(off_player.post_control) - float(defender.interior_defense)
		score += float(off_player.strength) - float(defender.strength)
		score *= 1.2

	# Wing vs wing: look for speed and shot creation advantages.
	elif off_player.position == Player.Position.SF:
		score += float(off_player.speed_with_ball) * 0.4 - float(defender.agility) * 0.4
		score += float(off_player.shot_iq) * 0.3 - float(defender.defensive_iq) * 0.3

	# General: shot creation vs perimeter defense.
	else:
		score += float(off_player.mid_range + off_player.three_point) * 0.25 \
			   - float(defender.perimeter_defense + defender.defensive_consistency) * 0.25

	return score

## get_best_mismatch_target
## Returns the offensive player_id with the highest active mismatch score.
## Used by PossessionSim to decide who to route the ball toward.
## Returns -1 if no active mismatches or coach isn't hunting them.
func get_best_mismatch_target() -> int:
	if not hunt_mismatches or active_mismatches.is_empty():
		return -1

	var best_id: int    = -1
	var best_sc: float  = 0.0
	for pid in active_mismatches:
		if active_mismatches[pid] > best_sc:
			best_sc = active_mismatches[pid]
			best_id = pid
	return best_id

## get_mismatch_weight_bonus
## Returns an additive weight bonus for a target player in PossessionSim's
## non-terminal event weight table. Scales with score and tactical quality.
func get_mismatch_weight_bonus(player_id: int) -> float:
	if not hunt_mismatches:
		return 0.0
	var score: float = active_mismatches.get(player_id, 0.0)
	if score <= 0.0:
		return 0.0
	# Tactical quality amplifies exploitation: elite coaches hammer mismatches.
	return score * (1.0 + tactical_read_quality * 1.5)

# ---------------------------------------------------------------------------
# ZONE DEFENSE HELPERS
# ---------------------------------------------------------------------------

## is_zone
## Returns true if the current defense is operating in a zone shell.
func is_zone() -> bool:
	return defense_philosophy == Coach.DefensePhilosophy.ZONE_2_3

## get_zone_corner_three_bonus
## Zone defenses leave corners open. Returns extra openness added to
## corner three-point attempts in ShotResolver.
func get_zone_corner_three_bonus() -> float:
	if not is_zone():
		return 0.0
	# Better coached zones concede less (gap is smaller).
	return 0.25 - defense_execution_quality * 0.10

## get_zone_interior_protection
## Zone packs the paint. Returns a penalty to interior shot make probability.
func get_zone_interior_protection() -> float:
	if not is_zone():
		return 0.0
	return 0.12 * defense_execution_quality

# ---------------------------------------------------------------------------
# PAINT PROTECTION HELPERS
# ---------------------------------------------------------------------------

## get_paint_protection_bonus
## Pack the paint adds extra interior defense weight in ShotResolver.
func get_paint_protection_bonus() -> float:
	if not pack_the_paint:
		return 0.0
	return 0.15 * defense_execution_quality

## get_paint_perimeter_penalty
## Packing the paint deliberately concedes the perimeter.
## Returns extra openness added to perimeter shots.
func get_paint_perimeter_penalty() -> float:
	if not pack_the_paint:
		return 0.0
	return 0.10   # Flat — this is an intentional concession.

# ---------------------------------------------------------------------------
# PRESS HELPERS
# ---------------------------------------------------------------------------

## get_press_steal_bonus
## Press defense adds steal probability in PossessionSim transition events.
func get_press_steal_bonus() -> float:
	if not press_active:
		return 0.0
	return 0.08 * defense_execution_quality

## get_press_bust_out_chance
## Fast ball handlers can beat the press for easy transition layups.
## Returns probability that the press gets beaten for a clear transition look.
func get_press_bust_out_chance() -> float:
	if not press_active:
		return 0.0
	# Poorly executed press is easier to beat.
	return 0.10 + (1.0 - defense_execution_quality) * 0.10

# ---------------------------------------------------------------------------
# IN-GAME ADJUSTMENTS — called by MatchEngine from coaching decisions
# ---------------------------------------------------------------------------

## set_defensive_lock
## Assigns a specific defender to follow a specific offensive player
## regardless of positional matching. Rebuilds assignment map.
func set_defensive_lock(
		offensive_player_id: int,
		defender_id: int,
		offense_five: Array,
		defense_five: Array) -> void:

	defensive_focus_player_id = offensive_player_id
	lock_defender_id          = defender_id

	# Reassign: the locked defender goes to the target.
	# Whoever was previously on that offensive player gets swapped to the
	# defender's old assignment to maintain full coverage.
	var old_off_id: int = _assignment_reverse.get(defender_id, -1)
	var old_def_id: int = defensive_assignments.get(offensive_player_id, -1)

	defensive_assignments[offensive_player_id] = defender_id
	if old_off_id != -1 and old_def_id != -1:
		defensive_assignments[old_off_id] = old_def_id

	_rebuild_reverse_map()

## adjust_pace
## Called from the in-game touchline controls (slow it down / push pace).
func adjust_pace(new_target: float) -> void:
	pace_target = clampf(new_target, 0.7, 1.3)

## toggle_press
## Activates or deactivates the press mid-game.
func toggle_press(active: bool) -> void:
	press_active = active

## toggle_paint_protection
## Activates or deactivates paint protection mid-game.
func toggle_paint_protection(active: bool) -> void:
	pack_the_paint = active

## reset_to_base
## Restores all in-game adjustments to match-start values.
## Called at half-time if no adjustments were set during the break.
func reset_to_base() -> void:
	offense_initiation_weights = _base_offense_weights.duplicate()
	switch_on_screens          = _base_switch_on_screens
	pack_the_paint             = _base_pack_the_paint
	press_active               = _base_press_active
	pace_target                = _base_pace_target
	defensive_focus_player_id  = -1
	lock_defender_id           = -1
	active_mismatches.clear()

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

func _rebuild_reverse_map() -> void:
	_assignment_reverse.clear()
	for off_id in defensive_assignments:
		_assignment_reverse[defensive_assignments[off_id]] = off_id

func _find_player(five: Array, player_id: int) -> Player:
	for p in five:
		if p.id == player_id:
			return p
	return null

func _best_defender_by_iq(defense_five: Array) -> Player:
	var best: Player   = defense_five[0] if not defense_five.is_empty() else null
	var best_v: float  = -INF
	for p in defense_five:
		var v: float = float(p.defensive_iq)
		if v > best_v:
			best_v = v
			best   = p
	return best
