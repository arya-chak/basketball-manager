class_name RotationManager
extends RefCounted

# ---------------------------------------------------------------------------
# RotationManager.gd
# Tracks playing time and manages substitutions for both teams across a game.
#
# Called by MatchEngine at the end of each possession via get_substitutions().
# Returns a list of {out: player_id, in: player_id} pairs to swap.
#
# Substitution triggers (in priority order):
#   1. Foul-out       — 6 personal fouls → forced removal, no return
#   2. Foul trouble   — 3 fouls in H1, or 4 fouls before Q4 → sit temporarily
#   3. Fatigue spike  — fatigue exceeds personal threshold → rest
#   4. Minutes target — starter has hit target → rotate to backup
#   5. Q4 starters back — rested starter returns for the stretch run
#
# Architecture:
#   - Pure logic, no DB, no signals.
#   - All state is per-game; a new RotationManager is created per game.
#   - get_player() allows MatchEngine to retrieve Player objects by id and side.
# ---------------------------------------------------------------------------

# Fatigue level that triggers an emergency sub regardless of minutes target.
const FATIGUE_SUB_THRESHOLD:    float = 0.72

# Fatigue level at which a rested player can re-enter.
const FATIGUE_REENTRY_THRESHOLD: float = 0.30

# Q4 clock threshold (seconds remaining) at which starters get called back
# if the game is still competitive.
const Q4_STARTERS_BACK_CLOCK:   int   = 360   # Last 6 minutes of Q4

# Foul counts that trigger a precautionary sit.
const FOUL_TROUBLE_H1:          int   = 3     # Sit in first half with this many
const FOUL_TROUBLE_PRE_Q4:      int   = 4     # Sit before Q4 with this many
const FOUL_OUT:                 int   = 6     # Forced removal — no return

# Seconds per possession estimate for minutes tracking.
# Actual time_used is in MatchEngine, so we use an estimate here.
const SECONDS_PER_POSSESSION:   float = 15.0

# ---------------------------------------------------------------------------
# Player registries — keyed by side ("home" / "away")
# ---------------------------------------------------------------------------

# Full roster: side -> Array of Player
var _rosters:     Dictionary = {}

# Starting five: side -> Array of Player (may change as subs happen)
var _starters:    Dictionary = {}

# Current bench (not on court): side -> Array of Player
var _bench:       Dictionary = {}

# All players by id for fast lookup: player_id -> Player
var _all_players: Dictionary = {}

# ---------------------------------------------------------------------------
# Minutes tracking
# minutes_played:   player_id -> float (seconds played this game)
# minutes_targets:  player_id -> float (target seconds, from Coach)
# ---------------------------------------------------------------------------

var _minutes_played:  Dictionary = {}
var _minutes_targets: Dictionary = {}

# ---------------------------------------------------------------------------
# Foul tracking: player_id -> int (personal fouls this game)
# ---------------------------------------------------------------------------

var _fouls: Dictionary = {}

# ---------------------------------------------------------------------------
# Foul-out registry: player_id -> bool
# Once fouled out a player can never re-enter.
# ---------------------------------------------------------------------------

var _fouled_out: Dictionary = {}

# ---------------------------------------------------------------------------
# Foul trouble sit list: player_id -> bool
# Temporarily sitting due to foul trouble. Can re-enter when situation clears.
# ---------------------------------------------------------------------------

var _in_foul_trouble_sit: Dictionary = {}

# ---------------------------------------------------------------------------
# Depth chart order for subs: side -> Dictionary: pos_string -> Array of player_ids
# Ordered starter-first. Used to pick the next available backup.
# ---------------------------------------------------------------------------

var _depth_charts: Dictionary = {}

# ---------------------------------------------------------------------------
# Position map: player_id -> pos_string (for sub matching)
# ---------------------------------------------------------------------------

var _positions: Dictionary = {}

# ---------------------------------------------------------------------------
# On-court tracking: player_id -> bool
# ---------------------------------------------------------------------------

var _on_court: Dictionary = {}

# ===========================================================================
# SETUP — called by MatchEngine once at game start
# ===========================================================================

func setup(
		home_roster: Array,
		away_roster: Array,
		home_coach:  Coach,
		away_coach:  Coach,
		home_five:   Array,
		away_five:   Array) -> void:

	_register_side("home", home_roster, home_five, home_coach)
	_register_side("away", away_roster, away_five, away_coach)

func _register_side(
		side:    String,
		roster:  Array,
		starters: Array,
		coach:   Coach) -> void:

	_rosters[side]   = roster.duplicate()
	_starters[side]  = starters.duplicate()
	_depth_charts[side] = coach.depth_chart.duplicate(true)

	# Build bench — everyone not in the starting five.
	var starter_ids: Array = []
	for p in starters:
		starter_ids.append(p.id)

	var bench: Array = []
	for p in roster:
		if p.id not in starter_ids:
			bench.append(p)
	_bench[side] = bench

	# Register all players.
	for p in roster:
		_all_players[p.id]    = p
		_minutes_played[p.id] = 0.0
		_fouls[p.id]          = 0
		_fouled_out[p.id]     = false
		_in_foul_trouble_sit[p.id] = false
		_positions[p.id]      = p.get_position_string()

	# On-court: starters start on court.
	for p in roster:
		_on_court[p.id] = p.id in starter_ids

	# Minutes targets — convert per-game minute targets to seconds.
	# Coach stores targets per position; distribute proportionally to players.
	_build_minutes_targets(side, roster, starters, coach)

func _build_minutes_targets(
		side:     String,
		roster:   Array,
		starters: Array,
		coach:    Coach) -> void:

	var pos_targets: Dictionary = coach.minutes_targets   # pos_string -> minutes

	for p in roster:
		var pos_str: String = p.get_position_string()
		var target_mins: float = float(pos_targets.get(pos_str, 24))

		# Starters get their full target.
		# Bench players share the remaining minutes at their position.
		var starters_at_pos: int = 0
		var bench_at_pos:    int = 0
		for s in starters:
			if s.get_position_string() == pos_str:
				starters_at_pos += 1
		for b in roster:
			if b.id not in [s.id for s in starters] \
					and b.get_position_string() == pos_str:
				bench_at_pos += 1

		var is_starter: bool = p in starters

		if is_starter:
			_minutes_targets[p.id] = target_mins * 60.0
		else:
			# Bench players split remaining minutes. Min 8 minutes guaranteed.
			var remaining_mins: float = maxf(8.0, 48.0 - target_mins) / maxf(1, bench_at_pos)
			_minutes_targets[p.id] = remaining_mins * 60.0

# ===========================================================================
# CORE PUBLIC METHOD — called by MatchEngine every possession
# ===========================================================================

## get_substitutions
## Returns an Array of {out: int, in: int} substitution pairs.
## Empty array = no subs needed this possession.
func get_substitutions(
		side:          String,
		current_five:  Array,
		fatigue:       Dictionary,
		quarter:       int,
		clock_seconds: int,
		tactics:       CoachTactics) -> Array:

	# Accumulate minutes for all on-court players this possession.
	_tick_minutes(current_five)

	# Update foul counts from the box score (passed via tactics if available).
	# Fouls are updated separately via update_fouls() called by MatchEngine.

	var subs: Array = []

	for player in current_five:
		var pid:          int   = player.id
		var player_fouls: int   = _fouls.get(pid, 0)
		var player_fat:   float = fatigue.get(pid, 0.0)
		var mins_played:  float = _minutes_played.get(pid, 0.0)
		var mins_target:  float = _minutes_targets.get(pid, 999.0)

		# --- Trigger 1: Foul-out ---
		if player_fouls >= FOUL_OUT and not _fouled_out.get(pid, false):
			_fouled_out[pid] = true
			var replacement: Player = _find_replacement(player, side, fatigue, quarter, true)
			if replacement != null:
				subs.append({"out": pid, "in": replacement.id})
			continue

		# --- Trigger 2: Foul trouble sit ---
		var trouble_threshold: int = FOUL_TROUBLE_H1 if quarter <= 2 else FOUL_TROUBLE_PRE_Q4
		if player_fouls >= trouble_threshold and quarter < 4 \
				and not _in_foul_trouble_sit.get(pid, false) \
				and not _fouled_out.get(pid, false):
			_in_foul_trouble_sit[pid] = true
			var replacement: Player = _find_replacement(player, side, fatigue, quarter, false)
			if replacement != null:
				subs.append({"out": pid, "in": replacement.id})
			continue

		# --- Trigger 3: Fatigue spike ---
		if player_fat >= FATIGUE_SUB_THRESHOLD \
				and not _fouled_out.get(pid, false):
			var replacement: Player = _find_replacement(player, side, fatigue, quarter, false)
			if replacement != null:
				subs.append({"out": pid, "in": replacement.id})
			continue

		# --- Trigger 4: Minutes target reached ---
		# Only sub at natural moments — not every possession.
		# Gate with a clock check so subs happen at reasonable intervals.
		if mins_played >= mins_target \
				and quarter < 4 \
				and _should_sub_now(clock_seconds, quarter) \
				and not _fouled_out.get(pid, false):
			var replacement: Player = _find_replacement(player, side, fatigue, quarter, false)
			if replacement != null:
				subs.append({"out": pid, "in": replacement.id})
			continue

	# --- Trigger 5: Q4 starters back ---
	# In the final 6 minutes of Q4, if the game is competitive, return
	# rested starters to the floor regardless of the rotation schedule.
	if quarter == 4 and clock_seconds <= Q4_STARTERS_BACK_CLOCK:
		subs = _check_starters_return(side, current_five, fatigue, subs)

	return subs

# ===========================================================================
# SUBSTITUTION LOGIC
# ===========================================================================

## _find_replacement
## Finds the best available bench player to sub in for a given player.
## Prefers players at the same position who are rested and not in foul trouble.
## forced = true means no restriction on foul count (foul-out replacement).
func _find_replacement(
		out_player: Player,
		side:       String,
		fatigue:    Dictionary,
		quarter:    int,
		forced:     bool) -> Player:

	var pos_str: String = out_player.get_position_string()

	# Get depth chart for this position — ordered backup list.
	var chart: Array = _depth_charts.get(side, {}).get(pos_str, [])

	# Try depth chart order first.
	for pid in chart:
		if _is_eligible(pid, fatigue, quarter, forced) and not _on_court.get(pid, false):
			return _all_players.get(pid, null)

	# Fallback: find any bench player at the same position who is eligible.
	var bench: Array = _bench.get(side, [])
	for p in bench:
		if p.get_position_string() == pos_str \
				and _is_eligible(p.id, fatigue, quarter, forced) \
				and not _on_court.get(p.id, false):
			return p

	# Fallback 2: adjacent position (e.g. SG for SF).
	var pos_enum: int = int(out_player.position)
	for p in bench:
		var p_pos: int = int(p.position)
		if abs(p_pos - pos_enum) == 1 \
				and _is_eligible(p.id, fatigue, quarter, forced) \
				and not _on_court.get(p.id, false):
			return p

	# No eligible replacement found.
	return null

## _is_eligible
## Returns true if a player can enter the game.
func _is_eligible(
		player_id: int,
		fatigue:   Dictionary,
		quarter:   int,
		forced:    bool) -> bool:

	# Fouled out — never eligible.
	if _fouled_out.get(player_id, false):
		return false

	# In foul trouble sit — only eligible if we're in Q4 or forced.
	if _in_foul_trouble_sit.get(player_id, false) and quarter < 4 and not forced:
		return false

	# Too fatigued to re-enter — needs rest.
	var fat: float = fatigue.get(player_id, 0.0)
	if fat > FATIGUE_REENTRY_THRESHOLD and not forced:
		return false

	return true

## _check_starters_return
## In the final 6 minutes of Q4, checks whether any rested starters should
## return to the floor. Adds them to the sub list if eligible.
func _check_starters_return(
		side:         String,
		current_five: Array,
		fatigue:      Dictionary,
		existing_subs: Array) -> Array:

	var starters: Array = _starters.get(side, [])
	var subs:     Array = existing_subs.duplicate()

	# Build set of player ids already being subbed in this tick.
	var incoming_ids: Array = []
	for s in subs:
		incoming_ids.append(s["in"])

	# Build set of player ids already being subbed out this tick.
	var outgoing_ids: Array = []
	for s in subs:
		outgoing_ids.append(s["out"])

	# Build set of current on-court ids.
	var on_court_ids: Array = []
	for p in current_five:
		on_court_ids.append(p.id)

	for starter in starters:
		var pid: int = starter.id

		# Already on court — nothing to do.
		if pid in on_court_ids:
			continue

		# Fouled out — can't return.
		if _fouled_out.get(pid, false):
			continue

		# Still too tired — skip.
		var fat: float = fatigue.get(pid, 0.0)
		if fat > FATIGUE_REENTRY_THRESHOLD:
			continue

		# Find a bench player on court at the same position to swap out.
		var pos_str: String = starter.get_position_string()
		for on_player in current_five:
			if on_player.get_position_string() == pos_str \
					and on_player.id not in [s.id for s in starters] \
					and on_player.id not in outgoing_ids \
					and pid not in incoming_ids:
				subs.append({"out": on_player.id, "in": pid})
				outgoing_ids.append(on_player.id)
				incoming_ids.append(pid)
				break   # One swap per starter per tick.

	return subs

# ===========================================================================
# FOUL UPDATE — called by MatchEngine after every possession
# ===========================================================================

## update_fouls
## Called by MatchEngine whenever a foul is committed.
## Also checks foul-out condition.
func update_fouls(player_id: int, foul_count: int) -> void:
	_fouls[player_id] = foul_count

	# Clear foul-trouble sit flag once a player is in Q4 (they can return).
	# This is handled by _is_eligible() checking quarter >= 4.

## update_fouls_from_box_score
## Syncs foul counts from the running box score.
## Called by MatchEngine at the start of each substitution check.
func update_fouls_from_box_score(box_score: Dictionary) -> void:
	for player_id in box_score:
		var fouls: int = box_score[player_id].get("fouls", 0)
		_fouls[player_id] = fouls
		# Auto-detect foul-out.
		if fouls >= FOUL_OUT:
			_fouled_out[player_id] = true

# ===========================================================================
# ON-COURT TRACKING
# ===========================================================================

## mark_substitution
## Called by MatchEngine after applying a substitution to keep _on_court in sync.
func mark_substitution(out_id: int, in_id: int) -> void:
	_on_court[out_id] = false
	_on_court[in_id]  = true

## get_minutes_played
## Returns minutes played for a player (converted from seconds).
func get_minutes_played(player_id: int) -> float:
	return _minutes_played.get(player_id, 0.0) / 60.0

## get_on_court_ids
## Returns the set of player ids currently on court for a given side.
func get_on_court_ids(side: String) -> Array:
	var result: Array = []
	for p in _rosters.get(side, []):
		if _on_court.get(p.id, false):
			result.append(p.id)
	return result

# ===========================================================================
# PLAYER LOOKUP — called by MatchEngine._apply_substitution
# ===========================================================================

## get_player
## Returns a Player object by id and side. Used by MatchEngine to retrieve
## the incoming player object to swap into the active five array.
func get_player(player_id: int, side: String) -> Player:
	return _all_players.get(player_id, null)

# ===========================================================================
# MINUTES TICKING
# ===========================================================================

## _tick_minutes
## Accumulates estimated seconds played for each on-court player per possession.
## MatchEngine doesn't pass actual time_used here, so we use an average estimate.
## A future improvement can pass actual seconds from the possession loop.
func _tick_minutes(current_five: Array) -> void:
	for p in current_five:
		_minutes_played[p.id] = _minutes_played.get(p.id, 0.0) + SECONDS_PER_POSSESSION

# ===========================================================================
# SUB TIMING GATE
# ===========================================================================

## _should_sub_now
## Returns true when it's a natural moment to rotate.
## Prevents the rotation from triggering on every single possession.
## Subs are most natural at quarter boundaries and on dead balls,
## but since MatchEngine doesn't model dead balls explicitly,
## we approximate: subs fire roughly every 5–7 possessions.
func _should_sub_now(clock_seconds: int, quarter: int) -> bool:
	# Always allow subs in the last 30 seconds of a quarter.
	if clock_seconds <= 30:
		return true

	# Natural sub window: every ~90 seconds of game time.
	# Approximated here as: allow a sub if clock is at a modulo boundary.
	# 90 seconds / 15 seconds per possession ≈ every 6 possessions.
	# Use clock_seconds as a proxy — fires roughly at expected intervals.
	var window: int = clock_seconds % 90
	return window < 20

# ===========================================================================
# PLAYER POSITION HELPERS
# ===========================================================================

## Returns the position string ("PG", "SG", etc.) for a given player id.
func get_position_string(player_id: int) -> String:
	return _positions.get(player_id, "PG")

## Returns true if a player id belongs to the home roster.
func is_home_player(player_id: int) -> bool:
	for p in _rosters.get("home", []):
		if p.id == player_id:
			return true
	return false
