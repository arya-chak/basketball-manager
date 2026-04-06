class_name ShotResolver
extends RefCounted

# ---------------------------------------------------------------------------
# ShotResolver.gd
# Resolves a shot attempt into a concrete outcome: made, missed, blocked,
# fouled, free throws, and all associated stat line updates.
#
# Called by MatchEngine immediately after PossessionSim sets
# state["_awaiting_shot_resolution"] = true.
#
# Inputs (from possession state):
#   ballhandler        — the shooter (Player)
#   primary_defender   — the contesting defender (Player)
#   shot_type          — string key from _select_shot_type()
#   current_openness   — 0.0–1.0 from possession chain
#   is_clutch          — bool
#   fatigue            — Dictionary: player_id -> 0.0–1.0
#   coach_tactics      — CoachTactics (may be null in QuickSim)
#   assist_player_id   — int (-1 if no assist)
#   defense_five       — Array of Player (for block finder)
#
# Outputs written back to state:
#   result             — "made", "missed", "blocked", "foul_shooting"
#   points_scored      — int (0, 1, 2, or 3)
#   block_player_id    — int (-1 if not blocked)
#   fouler_id          — int (-1 if no foul)
#   free_throws_to_shoot — int (0, 1, 2, or 3)
#   stat_deltas        — Dictionary: player_id -> stat delta dict
#                        MatchEngine merges these into the running box score.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Base make rates — anchored to NBA league averages.
# These are the starting point before any modifier is applied.
# ---------------------------------------------------------------------------
const BASE_RATES: Dictionary = {
	"layup":         0.60,
	"close_shot":    0.52,
	"driving_dunk":  0.72,
	"standing_dunk": 0.75,
	"post_hook":     0.50,
	"post_fade":     0.44,
	"mid_range":     0.42,
	"three_point":   0.36,
	"free_throw":    0.78,   # Used by _resolve_free_throw(), not _resolve_shot()
}

# Points value per shot type.
const SHOT_POINTS: Dictionary = {
	"layup":         2,
	"close_shot":    2,
	"driving_dunk":  2,
	"standing_dunk": 2,
	"post_hook":     2,
	"post_fade":     2,
	"mid_range":     2,
	"three_point":   3,
}

# Shot types eligible for a block attempt.
const BLOCKABLE_SHOTS: Array = [
	"layup", "driving_dunk", "standing_dunk", "close_shot", "post_hook"
]

# Primary attribute for each shot type — the shooter's skill that most
# directly drives make probability.
const SHOT_SKILL_ATTR: Dictionary = {
	"layup":         "layup",
	"close_shot":    "close_shot",
	"driving_dunk":  "driving_dunk",
	"standing_dunk": "standing_dunk",
	"post_hook":     "post_hook",
	"post_fade":     "post_fade",
	"mid_range":     "mid_range",
	"three_point":   "three_point",
}

# Primary defensive attribute for each shot type.
const SHOT_DEFENSE_ATTR: Dictionary = {
	"layup":         "interior_defense",
	"close_shot":    "interior_defense",
	"driving_dunk":  "interior_defense",
	"standing_dunk": "interior_defense",
	"post_hook":     "interior_defense",
	"post_fade":     "perimeter_defense",
	"mid_range":     "perimeter_defense",
	"three_point":   "perimeter_defense",
}

# Shooter skill modifier scale — per attribute point above/below 10.
const SKILL_SCALE:      float = 0.012   # ±0.12 at extremes (attrs 1–20)

# Defender contest modifier scale — how much defender skill costs the shooter.
# Multiplied by (1 - openness) so wide open shots barely feel the defender.
const CONTEST_SCALE:    float = 0.006

# Fatigue penalty — each 1.0 of fatigue reduces make probability by this much.
const FATIGUE_PENALTY:  float = 0.06

# Clutch modifier — scales with (composure + important_matches - 20).
const CLUTCH_SCALE:     float = 0.008

# Draw foul scale — per point of draw_foul above/below 10.
const DRAW_FOUL_SCALE:  float = 0.005

# Base foul chance on any shot attempt (before modifiers).
const BASE_FOUL_CHANCE: float = 0.08

# Block attempt base chance on blockable shots (before modifiers).
const BASE_BLOCK_CHANCE: float = 0.04

# Hard floor/ceiling for all make probabilities.
const MAKE_PROB_MIN: float = 0.05
const MAKE_PROB_MAX: float = 0.95

# ---------------------------------------------------------------------------
# RNG — seeded by MatchEngine alongside PossessionSim for replay consistency.
# ---------------------------------------------------------------------------
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func seed_rng(seed_value: int) -> void:
	_rng.seed = seed_value

# ===========================================================================
# PUBLIC ENTRY POINT
# ===========================================================================

## resolve
## The single public method. Receives the possession state from PossessionSim,
## resolves the shot, writes all outcomes back into state, and returns it.
func resolve(state: Dictionary) -> Dictionary:
	var shot_type: String = state.get("shot_type", "mid_range")
	var shooter:   Player = state["ballhandler"]
	var defender:  Player = state["primary_defender"]

	# Initialise stat_deltas — MatchEngine merges these into the box score.
	state["stat_deltas"] = {}
	state["free_throws_to_shoot"] = 0

	# --- Step 1: Block check (rim attempts only) ---
	if shot_type in BLOCKABLE_SHOTS:
		var block_result: Dictionary = _check_block(shooter, defender, state)
		if block_result["blocked"]:
			return _resolve_blocked(state, block_result["blocker"])

	# --- Step 2: Foul check (runs independently of make/miss) ---
	var foul_result: Dictionary = _check_foul_on_shot(shooter, defender, state)

	# --- Step 3: Make probability ---
	var make_prob: float = _calc_make_probability(shooter, defender, shot_type, state)

	# --- Step 4: Roll ---
	var made: bool = _rng.randf() < make_prob

	# --- Step 5: Resolve outcome ---
	if foul_result["fouled"]:
		return _resolve_fouled_shot(state, shot_type, made, foul_result["fouler_id"])

	if made:
		return _resolve_made(state, shot_type)
	else:
		return _resolve_missed(state, shot_type)

# ===========================================================================
# MAKE PROBABILITY
# ===========================================================================

func _calc_make_probability(
		shooter: Player,
		defender: Player,
		shot_type: String,
		state: Dictionary) -> float:

	var base: float     = BASE_RATES.get(shot_type, 0.42)
	var openness: float = state.get("current_openness", 0.5)

	# 1. Shooter skill modifier.
	var skill_attr:  String = SHOT_SKILL_ATTR.get(shot_type, "mid_range")
	var skill_val:   float  = float(shooter.get(skill_attr))
	var skill_mod:   float  = (skill_val - 10.0) * SKILL_SCALE

	# 2. Openness modifier — the most impactful single factor.
	# Maps 0.0–1.0 openness to roughly -0.15 to +0.15 adjustment.
	var openness_mod: float = (openness - 0.5) * 0.30

	# 3. Defender contest modifier — diminishes as openness rises.
	var def_attr:    String = SHOT_DEFENSE_ATTR.get(shot_type, "perimeter_defense")
	var def_val:     float  = float(defender.get(def_attr))
	var contest_mod: float  = -(def_val - 10.0) * CONTEST_SCALE * (1.0 - openness)

	# 4. Secondary defensive attributes add texture.
	#    Defensive IQ penalises shooter regardless of openness (positioning).
	#    Defensive Consistency adds a small flat penalty.
	var def_iq_mod:   float = -(float(defender.defensive_iq) - 10.0) * 0.003
	var def_cons_mod: float = -(float(defender.defensive_consistency) - 10.0) * 0.002

	# 5. Fatigue modifier — shooter's stamina degradation.
	var fatigue:     float  = state.get("fatigue", {}).get(shooter.id, 0.0)
	var fatigue_mod: float  = -fatigue * FATIGUE_PENALTY

	# 6. Clutch modifier — Composure + Important Matches (hidden).
	var clutch_mod: float = 0.0
	if state.get("is_clutch", false):
		var composure:        float = float(shooter.composure)
		var important_matches: float = float(shooter.important_matches)
		var clutch_delta:     float = (composure + important_matches) - 20.0
		clutch_mod = clutch_delta * CLUTCH_SCALE

	# 7. Coaching modifiers from CoachTactics.
	var coaching_mod: float = _calc_coaching_modifier(shot_type, openness, state)

	# 8. Shot IQ — bad decisions reduce probability. Good Shot IQ is already
	#    partially baked into _select_shot_type(), so effect here is subtle.
	var shot_iq_mod: float = (float(shooter.shot_iq) - 10.0) * 0.004

	# Sum all modifiers.
	var prob: float = base \
		+ skill_mod \
		+ openness_mod \
		+ contest_mod \
		+ def_iq_mod \
		+ def_cons_mod \
		+ fatigue_mod \
		+ clutch_mod \
		+ coaching_mod \
		+ shot_iq_mod

	return clampf(prob, MAKE_PROB_MIN, MAKE_PROB_MAX)

func _calc_coaching_modifier(
		shot_type: String,
		openness: float,
		state: Dictionary) -> float:

	var tactics: CoachTactics = state.get("coach_tactics", null)
	if tactics == null:
		return 0.0

	var mod: float = 0.0

	# Zone defense — corners left open, interior more protected.
	if tactics.is_zone():
		if shot_type == "three_point":
			mod += tactics.get_zone_corner_three_bonus()
		elif shot_type in ["layup", "driving_dunk", "standing_dunk", "close_shot"]:
			mod -= tactics.get_zone_interior_protection()

	# Pack the paint — interior penalised, perimeter deliberately open.
	if tactics.pack_the_paint:
		if shot_type in ["layup", "driving_dunk", "standing_dunk", "close_shot", "post_hook"]:
			mod -= tactics.get_paint_protection_bonus()
		elif shot_type in ["three_point", "mid_range", "post_fade"]:
			mod += tactics.get_paint_perimeter_penalty()

	return mod

# ===========================================================================
# BLOCK CHECK
# ===========================================================================

func _check_block(
		shooter: Player,
		primary_defender: Player,
		state: Dictionary) -> Dictionary:

	# Find the best shot blocker on the defensive five — not just the primary.
	# Help defenders can rotate to block rim attempts.
	var defense_five: Array = state.get("defense_five", [])
	var blocker: Player     = _find_best_blocker(defense_five, primary_defender)

	var openness: float = state.get("current_openness", 0.5)

	# Block chance: blocker's block + vertical vs shooter's vertical.
	# Wide open shots (high openness) are very hard to block — the defense
	# has already been beaten to the spot.
	var block_score: float = float(blocker.block) * 0.5 \
		+ float(blocker.vertical) * 0.3 \
		+ float(blocker.interior_defense) * 0.2
	var evade_score: float = float(shooter.vertical) * 0.5 \
		+ float(shooter.agility) * 0.3 \
		+ float(shooter.layup) * 0.2   # Layup technique = harder to block

	var block_chance: float = BASE_BLOCK_CHANCE \
		+ (block_score - evade_score) * 0.006 \
		- openness * 0.08   # Wide open → near-zero block chance

	block_chance = clampf(block_chance, 0.0, 0.35)

	if _rng.randf() < block_chance:
		return {"blocked": true, "blocker": blocker}
	return {"blocked": false, "blocker": null}

func _find_best_blocker(defense_five: Array, primary_defender: Player) -> Player:
	if defense_five.is_empty():
		return primary_defender
	var best:    Player = primary_defender
	var best_val: float = float(primary_defender.block) + float(primary_defender.vertical)
	for p in defense_five:
		var v: float = float(p.block) + float(p.vertical)
		if v > best_val:
			best_val = v
			best     = p
	return best

# ===========================================================================
# FOUL CHECK
# ===========================================================================

func _check_foul_on_shot(
		shooter: Player,
		defender: Player,
		state: Dictionary) -> Dictionary:

	var openness: float = state.get("current_openness", 0.5)

	# Draw foul skill + tight contest → foul chance rises.
	# Wide open shots are rarely fouled — the defender didn't get close enough.
	var foul_chance: float = BASE_FOUL_CHANCE \
		+ (float(shooter.draw_foul) - 10.0) * DRAW_FOUL_SCALE \
		+ (1.0 - openness) * 0.06 \
		- (float(defender.defensive_consistency) - 10.0) * 0.004

	# Clutch time: desperate fouls more common in tight games.
	if state.get("is_clutch", false):
		foul_chance += 0.04

	foul_chance = clampf(foul_chance, 0.0, 0.30)

	if _rng.randf() < foul_chance:
		return {"fouled": true, "fouler_id": defender.id}
	return {"fouled": false, "fouler_id": -1}

# ===========================================================================
# OUTCOME RESOLVERS
# ===========================================================================

## Made basket — no foul.
func _resolve_made(state: Dictionary, shot_type: String) -> Dictionary:
	var shooter:   Player = state["ballhandler"]
	var points:    int    = SHOT_POINTS.get(shot_type, 2)
	var is_three:  bool   = shot_type == "three_point"

	state["result"]        = "made"
	state["points_scored"] = points

	# Stat deltas.
	var sd: Dictionary = _init_stat_delta(shooter.id)
	sd["points"]  += points
	sd["fgm"]     += 1
	sd["fga"]     += 1
	if is_three:
		sd["fg3m"] += 1
		sd["fg3a"] += 1
	_apply_stat_delta(state, shooter.id, sd)

	# Assist — credit the last passer.
	var assist_id: int = state.get("assist_player_id", -1)
	if assist_id != -1 and assist_id != shooter.id:
		var asd: Dictionary = _init_stat_delta(assist_id)
		asd["assists"] += 1
		_apply_stat_delta(state, assist_id, asd)

	_log_shot_event(state, shot_type, "made", -1)
	return state

## Missed basket — no foul, no block.
func _resolve_missed(state: Dictionary, shot_type: String) -> Dictionary:
	var shooter:  Player = state["ballhandler"]
	var is_three: bool   = shot_type == "three_point"

	state["result"]        = "missed"
	state["points_scored"] = 0

	var sd: Dictionary = _init_stat_delta(shooter.id)
	sd["fga"] += 1
	if is_three:
		sd["fg3a"] += 1
	_apply_stat_delta(state, shooter.id, sd)

	# Flag that a rebound contest is now available.
	# MatchEngine will run _event_offensive_rebound or defensive rebound logic.
	state["_rebound_available"] = true

	_log_shot_event(state, shot_type, "missed", -1)
	return state

## Blocked shot.
func _resolve_blocked(state: Dictionary, blocker: Player) -> Dictionary:
	var shooter:  Player = state["ballhandler"]
	var shot_type: String = state.get("shot_type", "layup")

	state["result"]          = "blocked"
	state["points_scored"]   = 0
	state["block_player_id"] = blocker.id

	# Shooter stat: FGA only, no FGM.
	var sd: Dictionary = _init_stat_delta(shooter.id)
	sd["fga"] += 1
	_apply_stat_delta(state, shooter.id, sd)

	# Blocker stat.
	var bd: Dictionary = _init_stat_delta(blocker.id)
	bd["blocks"] += 1
	_apply_stat_delta(state, blocker.id, bd)

	# Flag rebound available — blocked shots create a loose ball.
	state["_rebound_available"] = true

	_log_shot_event(state, shot_type, "blocked", blocker.id)
	return state

## Fouled on a shot attempt.
## If made + fouled → and_one (1 free throw).
## If missed + fouled → 2 or 3 free throws depending on shot type.
func _resolve_fouled_shot(
		state: Dictionary,
		shot_type: String,
		made: bool,
		fouler_id: int) -> Dictionary:

	var shooter:  Player = state["ballhandler"]
	var is_three: bool   = shot_type == "three_point"
	var ft_count: int    = 1 if made else (3 if is_three else 2)

	state["fouler_id"]            = fouler_id
	state["free_throws_to_shoot"] = ft_count

	if made:
		# And-one: basket counts, one free throw added.
		var points: int = SHOT_POINTS.get(shot_type, 2)
		state["result"]        = "and_one"
		state["points_scored"] = points

		var sd: Dictionary = _init_stat_delta(shooter.id)
		sd["points"] += points
		sd["fgm"]    += 1
		sd["fga"]    += 1
		if is_three:
			sd["fg3m"] += 1
			sd["fg3a"] += 1
		_apply_stat_delta(state, shooter.id, sd)

		# Assist on the made basket.
		var assist_id: int = state.get("assist_player_id", -1)
		if assist_id != -1 and assist_id != shooter.id:
			var asd: Dictionary = _init_stat_delta(assist_id)
			asd["assists"] += 1
			_apply_stat_delta(state, assist_id, asd)

	else:
		# Missed + fouled: no basket, go to the line.
		state["result"]        = "foul_shooting"
		state["points_scored"] = 0

		var sd: Dictionary = _init_stat_delta(shooter.id)
		sd["fga"] += 1
		if is_three:
			sd["fg3a"] += 1
		_apply_stat_delta(state, shooter.id, sd)

	# Fouler personal foul.
	_apply_stat_delta(state, fouler_id, {"fouls": 1})

	_log_shot_event(state, shot_type, "and_one" if made else "foul_shooting", fouler_id)

	# Resolve the free throws immediately.
	state = _resolve_free_throws(state, shooter, ft_count)

	return state

# ===========================================================================
# FREE THROW RESOLUTION
# ===========================================================================

## _resolve_free_throws
## Simulates each free throw individually. Updates points_scored and stat lines.
func _resolve_free_throws(state: Dictionary, shooter: Player, count: int) -> Dictionary:
	var base_rate: float = BASE_RATES["free_throw"]

	# Shooter's FT attribute.
	var ft_skill: float = float(shooter.free_throw)
	var ft_prob:  float = base_rate + (ft_skill - 10.0) * SKILL_SCALE

	# Fatigue makes free throws harder — concentration lapses.
	var fatigue:  float = state.get("fatigue", {}).get(shooter.id, 0.0)
	ft_prob -= fatigue * 0.04

	# Clutch pressure — composure matters at the line.
	if state.get("is_clutch", false):
		var composure: float = float(shooter.composure)
		ft_prob += (composure - 10.0) * 0.006

	ft_prob = clampf(ft_prob, MAKE_PROB_MIN, MAKE_PROB_MAX)

	var sd: Dictionary = _init_stat_delta(shooter.id)

	for i in count:
		sd["fta"] += 1
		if _rng.randf() < ft_prob:
			sd["ftm"]    += 1
			sd["points"] += 1
			state["points_scored"] += 1
			_log_ft_event(state, shooter.id, "made", i + 1, count)
		else:
			_log_ft_event(state, shooter.id, "missed", i + 1, count)
			# Last FT missed → rebound available.
			if i == count - 1:
				state["_rebound_available"] = true

	_apply_stat_delta(state, shooter.id, sd)
	return state

# ===========================================================================
# REBOUND RESOLUTION
# ===========================================================================

## resolve_rebound
## Called by MatchEngine after a missed shot or blocked shot.
## Determines whether the offense or defense gets the board,
## and credits the appropriate player.
## Returns updated state with rebounder_id set.
func resolve_rebound(state: Dictionary) -> Dictionary:
	var offense_five: Array = state.get("offense_five", [])
	var defense_five: Array = state.get("defense_five", [])

	if offense_five.is_empty() or defense_five.is_empty():
		return state

	# Find best rebounders on each side.
	var o_reb: Player = _best_rebounder(offense_five, "offensive_rebounding")
	var d_reb: Player = _best_rebounder(defense_five, "defensive_rebounding")

	# Fatigue-adjusted rebound scores.
	var fatigue: Dictionary = state.get("fatigue", {})

	var o_score: float = _fatigued(o_reb, "offensive_rebounding", fatigue) * 0.5 \
		+ _fatigued(o_reb, "vertical", fatigue) * 0.3 \
		+ _fatigued(o_reb, "hustle", fatigue) * 0.2

	var d_score: float = _fatigued(d_reb, "defensive_rebounding", fatigue) * 0.5 \
		+ _fatigued(d_reb, "vertical", fatigue) * 0.3 \
		+ float(d_reb.strength) * 0.2

	# Blocked shots have slightly higher OREB rate — ball bounces unpredictably.
	if state.get("result") == "blocked":
		o_score *= 1.10

	var total: float = o_score + d_score
	if total <= 0.0:
		total = 1.0

	if _rng.randf() < (o_score / total):
		# Offensive rebound.
		state["rebounder_id"] = o_reb.id
		var sd: Dictionary    = _init_stat_delta(o_reb.id)
		sd["oreb"] += 1
		sd["rebounds"] += 1
		_apply_stat_delta(state, o_reb.id, sd)
		_log_rebound_event(state, o_reb.id, "offensive")
	else:
		# Defensive rebound.
		state["rebounder_id"] = d_reb.id
		var sd: Dictionary    = _init_stat_delta(d_reb.id)
		sd["dreb"] += 1
		sd["rebounds"] += 1
		_apply_stat_delta(state, d_reb.id, sd)
		_log_rebound_event(state, d_reb.id, "defensive")

	state["_rebound_available"] = false
	return state

# ===========================================================================
# STAT DELTA HELPERS
# ===========================================================================

## Returns a zeroed stat delta dict for a player.
func _init_stat_delta(player_id: int) -> Dictionary:
	return {
		"player_id":  player_id,
		"points":     0,
		"rebounds":   0,
		"oreb":       0,
		"dreb":       0,
		"assists":    0,
		"steals":     0,
		"blocks":     0,
		"turnovers":  0,
		"fouls":      0,
		"fgm":        0,
		"fga":        0,
		"fg3m":       0,
		"fg3a":       0,
		"ftm":        0,
		"fta":        0,
	}

## Merges a stat delta dict into state["stat_deltas"].
## state["stat_deltas"] is a Dictionary: player_id (int) -> stat delta dict.
func _apply_stat_delta(state: Dictionary, player_id: int, delta: Dictionary) -> void:
	if not state.has("stat_deltas"):
		state["stat_deltas"] = {}

	if not state["stat_deltas"].has(player_id):
		state["stat_deltas"][player_id] = _init_stat_delta(player_id)

	var existing: Dictionary = state["stat_deltas"][player_id]
	for key in delta:
		if key == "player_id":
			continue
		if existing.has(key):
			existing[key] += delta[key]
		else:
			existing[key] = delta[key]

# ===========================================================================
# PLAYER ATTRIBUTE HELPERS
# ===========================================================================

func _best_rebounder(five: Array, attr: String) -> Player:
	var best:    Player = five[0]
	var best_val: float = float(five[0].get(attr))
	for p in five:
		var v: float = float(p.get(attr))
		if v > best_val:
			best_val = v
			best     = p
	return best

func _fatigued(player: Player, attr: String, fatigue: Dictionary) -> float:
	var base: float    = float(player.get(attr))
	var f:    float    = fatigue.get(player.id, 0.0)
	return base - f * 3.0   # Lighter penalty than in PossessionSim — rebounding is instinctual

# ===========================================================================
# PLAY-BY-PLAY EVENT LOGGING
# ===========================================================================

## Logs a shot resolution event into state["play_events"].
## CommentaryEngine reads the full play_events array to generate text.
func _log_shot_event(
		state: Dictionary,
		shot_type: String,
		result: String,
		secondary_id: int) -> void:

	var shooter: Player = state["ballhandler"]
	state["play_events"].append({
		"quarter":             state.get("quarter", 1),
		"clock_seconds":       state.get("clock_seconds", 0),
		"shot_clock":          state.get("shot_clock", 24),
		"team":                state.get("offense_team_id", ""),
		"event":               "shot_resolution",
		"shot_type":           shot_type,
		"primary_player_id":   shooter.id,
		"secondary_player_id": secondary_id,
		"result":              result,
		"points":              state.get("points_scored", 0),
		"openness":            state.get("current_openness", 0.5),
		"is_clutch":           state.get("is_clutch", false),
		"make_prob_debug":     0.0,   # MatchEngine can fill this for dev logging
	})

## Logs a free throw event.
func _log_ft_event(
		state: Dictionary,
		shooter_id: int,
		result: String,
		ft_number: int,
		ft_total: int) -> void:

	state["play_events"].append({
		"quarter":             state.get("quarter", 1),
		"clock_seconds":       state.get("clock_seconds", 0),
		"shot_clock":          0,
		"team":                state.get("offense_team_id", ""),
		"event":               "free_throw",
		"ft_number":           ft_number,
		"ft_total":            ft_total,
		"primary_player_id":   shooter_id,
		"secondary_player_id": -1,
		"result":              result,
		"points":              1 if result == "made" else 0,
		"openness":            1.0,   # FTs are always uncontested
		"is_clutch":           state.get("is_clutch", false),
	})

## Logs a rebound event.
func _log_rebound_event(
		state: Dictionary,
		rebounder_id: int,
		reb_type: String) -> void:

	state["play_events"].append({
		"quarter":             state.get("quarter", 1),
		"clock_seconds":       state.get("clock_seconds", 0),
		"shot_clock":          24,
		"team":                state.get("offense_team_id" if reb_type == "offensive" \
									else "defense_team_id", ""),
		"event":               "rebound",
		"rebound_type":        reb_type,
		"primary_player_id":   rebounder_id,
		"secondary_player_id": -1,
		"result":              reb_type,
		"points":              0,
		"openness":            0.0,
		"is_clutch":           state.get("is_clutch", false),
	})
