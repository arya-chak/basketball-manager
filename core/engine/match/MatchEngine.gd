class_name MatchEngine
extends RefCounted

# ---------------------------------------------------------------------------
# MatchEngine.gd
# Orchestrates a complete basketball game simulation.
#
# Responsibilities:
#   - Builds CoachTactics for both teams at match start
#   - Applies motivation bonus to all players pre-game
#   - Runs the possession loop: 4 quarters × ~25 possessions each
#   - Manages fatigue state across all 10 on-court players
#   - Calls PossessionSim once per possession
#   - Calls ShotResolver after every shot attempt
#   - Accumulates the box score from stat_deltas
#   - Handles overtime
#   - Emits EventBus signals at quarter end and game end
#   - Calls WorldState.record_match_result() when done
#   - Returns a fully populated MatchResult dictionary
#
# Architecture:
#   - Pure logic — no UI, no DB writes (WorldState handles persistence)
#   - All randomness seeded from a single game seed for replay support
#   - RotationManager.gd handles substitutions and minutes tracking
# ---------------------------------------------------------------------------

const BASE_POSSESSIONS_PER_QUARTER: int = 25   # ~100 per game at 1.0 pace
const QUARTERS:                     int = 4
const QUARTER_SECONDS:              int = 720   # 12 minutes
const SHOT_CLOCK_SECONDS:           int = 24
const OVERTIME_SECONDS:             int = 300   # 5 minutes

# Fatigue accumulation per possession for each on-court player.
# Stamina attribute and coach conditioning reduce this.
const BASE_FATIGUE_PER_POSSESSION: float = 0.008

# Home court advantage — applied as a flat make-probability boost
# to the home team's shots, injected into CoachTactics.
const HOME_COURT_ADVANTAGE: float = 0.012

# Score threshold below which clutch mode activates in Q4/OT.
const CLUTCH_MARGIN: int = 5

# Maximum overtime periods before the game is declared a draw
# (shouldn't happen in real NBA but prevents infinite loops).
const MAX_OT_PERIODS: int = 3

# ---------------------------------------------------------------------------
# Dependencies — instantiated once per MatchEngine instance.
# ---------------------------------------------------------------------------
var _possession_sim:  PossessionSim   = PossessionSim.new()
var _shot_resolver:   ShotResolver    = ShotResolver.new()
var _commentary:      CommentaryEngine = CommentaryEngine.new()
var _rotation_mgr:    RotationManager = null   # Instantiated in simulate_game()
var _rng:             RandomNumberGenerator = RandomNumberGenerator.new()

# ---------------------------------------------------------------------------
# Game seed — set externally for replay support, or auto-generated.
# ---------------------------------------------------------------------------
var game_seed: int = 0

# ===========================================================================
# PUBLIC ENTRY POINT
# ===========================================================================

## simulate_game
## Simulates a complete game between two teams.
##
## home_team / away_team: Team objects (from WorldState)
## home_coach / away_coach: Coach objects
## home_roster / away_roster: Array of Player (full 15-man, not just starters)
## schedule_entry: Dictionary with date fields and league_id
##
## Returns a MatchResult dictionary (defined in design doc).
func simulate_game(
		home_team:    Team,
		away_team:    Team,
		home_coach:   Coach,
		away_coach:   Coach,
		home_roster:  Array,
		away_roster:  Array,
		schedule_entry: Dictionary) -> Dictionary:

	# --- Seed all RNGs from a single game seed ---
	if game_seed == 0:
		game_seed = randi()
	_rng.seed             = game_seed
	_possession_sim.seed_rng(game_seed + 1)
	_shot_resolver.seed_rng(game_seed + 2)
	_commentary.seed_rng(game_seed + 3)

	# --- Build starting lineups from depth charts ---
	var home_five: Array = _build_starting_five(home_roster, home_coach)
	var away_five: Array = _build_starting_five(away_roster, away_coach)

	# --- Build CoachTactics for both teams ---
	var home_tactics: CoachTactics = CoachTactics.build(
		home_coach, home_five, away_five, _rng
	)
	var away_tactics: CoachTactics = CoachTactics.build(
		away_coach, away_five, home_five, _rng
	)

	# --- Apply home court advantage to home team's tactics ---
	home_tactics.home_court_bonus = HOME_COURT_ADVANTAGE

	# --- Initialise RotationManager ---
	_rotation_mgr = RotationManager.new()
	_rotation_mgr.setup(
		home_roster, away_roster,
		home_coach,  away_coach,
		home_five,   away_five
	)

	# --- Initialise game state ---
	var game: Dictionary = _init_game_state(
		home_team, away_team,
		home_coach, away_coach,
		home_five, away_five,
		home_tactics, away_tactics,
		schedule_entry
	)

	# --- Apply pre-game motivation bonus ---
	_apply_motivation_bonus(game)

	# --- Run quarter loop ---
	for q in QUARTERS:
		game = _simulate_quarter(game, q + 1)
		_emit_quarter_end(game, q + 1)

	# --- Overtime ---
	var ot: int = 0
	while game["home_score"] == game["away_score"] and ot < MAX_OT_PERIODS:
		ot += 1
		game = _simulate_overtime(game, ot)
		_emit_quarter_end(game, QUARTERS + ot)

	game["overtime_periods"] = ot

	# --- Finalise box score ---
	game = _finalise_box_score(game)

	# --- Report to WorldState ---
	WorldState.record_match_result(
		home_team.id,
		away_team.id,
		game["home_score"],
		game["away_score"],
		schedule_entry.get("league_id", "nba")
	)

	# --- Emit game-end signal ---
	EventBus.match_simulated.emit({
		"home_team_id": home_team.id,
		"away_team_id": away_team.id,
		"home_score":   game["home_score"],
		"away_score":   game["away_score"],
		"league_id":    schedule_entry.get("league_id", "nba"),
	})

	return _build_match_result(game, schedule_entry)

# ===========================================================================
# GAME STATE INITIALISATION
# ===========================================================================

func _init_game_state(
		home_team:    Team,
		away_team:    Team,
		home_coach:   Coach,
		away_coach:   Coach,
		home_five:    Array,
		away_five:    Array,
		home_tactics: CoachTactics,
		away_tactics: CoachTactics,
		schedule_entry: Dictionary) -> Dictionary:

	# Box score: player_id -> stat line dictionary
	var box_score: Dictionary = {}
	for p in home_five:
		box_score[p.id] = _empty_stat_line(p.id)
	for p in away_five:
		box_score[p.id] = _empty_stat_line(p.id)

	# Fatigue: player_id -> float (0.0 fresh, 1.0 gassed)
	var fatigue: Dictionary = {}
	for p in home_five:
		fatigue[p.id] = 0.0
	for p in away_five:
		fatigue[p.id] = 0.0

	# Quarter scores
	var home_quarters: Array = [0, 0, 0, 0]
	var away_quarters: Array = [0, 0, 0, 0]

	return {
		# Identity
		"home_team_id":   home_team.id,
		"away_team_id":   away_team.id,
		"league_id":      schedule_entry.get("league_id", "nba"),
		"date_day":       schedule_entry.get("date_day", 1),
		"date_month":     schedule_entry.get("date_month", 10),
		"date_year":      schedule_entry.get("date_year", 2025),

		# Scores
		"home_score":     0,
		"away_score":     0,
		"home_quarters":  home_quarters,
		"away_quarters":  away_quarters,

		# Rosters
		"home_five":      home_five,
		"away_five":      away_five,

		# Tactics
		"home_tactics":   home_tactics,
		"away_tactics":   away_tactics,

		# Coaches
		"home_coach":     home_coach,
		"away_coach":     away_coach,

		# Game tracking
		"box_score":      box_score,
		"fatigue":        fatigue,
		"play_by_play":   [],
		"possession_log": [],   # lightweight log for QuickSim fallback

		# Possession tracking
		"home_possessions": 0,
		"away_possessions": 0,
		"current_quarter":  0,
		"overtime_periods": 0,

		# Transition flag — set by steal/defensive rebound events
		"next_is_transition": false,
	}

# ===========================================================================
# QUARTER SIMULATION
# ===========================================================================

func _simulate_quarter(game: Dictionary, quarter: int) -> Dictionary:
	game["current_quarter"] = quarter

	# Determine possession count for this quarter from pace targets.
	var home_pace: float = game["home_tactics"].pace_target
	var away_pace: float = game["away_tactics"].pace_target
	var avg_pace:  float = (home_pace + away_pace) * 0.5
	var possessions: int = roundi(BASE_POSSESSIONS_PER_QUARTER * avg_pace)

	# Add a small random variance (±2) so quarters don't feel mechanical.
	possessions += _rng.randi_range(-2, 2)
	possessions  = clampi(possessions, 18, 32)

	var clock_seconds: int = QUARTER_SECONDS
	var shot_clock:    int = SHOT_CLOCK_SECONDS

	# Alternate possessions: home gets odd indices, away gets even.
	# First possession determined by coin flip (or tip-off in Q1).
	var home_starts: bool = quarter == 1 \
		? (_rng.randf() < 0.5) \
		: game.get("_last_quarter_started_away", false)   # Alternates each quarter.

	for i in possessions:
		if clock_seconds <= 0:
			break

		var home_offense: bool = (i % 2 == 0) == home_starts

		# Determine remaining clock for this possession (simulate time drain).
		var time_used: int = _rng.randi_range(12, 22)   # Seconds per possession
		clock_seconds     -= time_used
		shot_clock         = SHOT_CLOCK_SECONDS

		# Check clutch condition.
		var is_clutch: bool = (quarter >= 4) \
			and clock_seconds <= 120 \
			and abs(game["home_score"] - game["away_score"]) <= CLUTCH_MARGIN

		# Build possession state.
		var state: Dictionary = _build_possession_state(
			game, quarter, clock_seconds, shot_clock, home_offense, is_clutch
		)

		# Run possession.
		state = _possession_sim.simulate_possession(state)

		# Resolve shot if one was attempted.
		if state.get("_awaiting_shot_resolution", false):
			state = _shot_resolver.resolve(state)

		# Resolve rebound if needed.
		if state.get("_rebound_available", false):
			state = _shot_resolver.resolve_rebound(state)

		# Merge results back into game state.
		game = _merge_possession_result(game, state, quarter, home_offense)

		# Update fatigue for all on-court players.
		game = _update_fatigue(game, state)

		# Check if rotation manager wants to sub.
		game = _check_substitutions(game, quarter, clock_seconds)

	# Store which side starts next quarter.
	game["_last_quarter_started_away"] = home_starts

	return game

func _simulate_overtime(game: Dictionary, ot_period: int) -> Dictionary:
	var quarter: int = QUARTERS + ot_period
	game["current_quarter"] = quarter

	# OT: fewer possessions, no alternating — tip-off again.
	var possessions: int = roundi(BASE_POSSESSIONS_PER_QUARTER * 0.45)
	possessions         += _rng.randi_range(-2, 2)
	possessions          = clampi(possessions, 10, 16)

	var clock_seconds: int = OVERTIME_SECONDS
	var home_starts:   bool = _rng.randf() < 0.5

	for i in possessions:
		if clock_seconds <= 0:
			break
		if game["home_score"] != game["away_score"] and clock_seconds <= 0:
			break

		var home_offense: bool = (i % 2 == 0) == home_starts
		var time_used:    int  = _rng.randi_range(12, 22)
		clock_seconds         -= time_used

		# Clutch is always active in OT — every possession matters.
		var is_clutch: bool = true

		var state: Dictionary = _build_possession_state(
			game, quarter, clock_seconds, SHOT_CLOCK_SECONDS, home_offense, is_clutch
		)

		state = _possession_sim.simulate_possession(state)

		if state.get("_awaiting_shot_resolution", false):
			state = _shot_resolver.resolve(state)

		if state.get("_rebound_available", false):
			state = _shot_resolver.resolve_rebound(state)

		game = _merge_possession_result(game, state, quarter, home_offense)
		game = _update_fatigue(game, state)
		game = _check_substitutions(game, quarter, clock_seconds)

	return game

# ===========================================================================
# POSSESSION STATE BUILDER
# ===========================================================================

## _build_possession_state
## Constructs the full state dictionary that PossessionSim expects.
func _build_possession_state(
		game:          Dictionary,
		quarter:       int,
		clock_seconds: int,
		shot_clock:    int,
		home_offense:  bool,
		is_clutch:     bool) -> Dictionary:

	var offense_five:  Array        = game["home_five"] if home_offense else game["away_five"]
	var defense_five:  Array        = game["away_five"] if home_offense else game["home_five"]
	var offense_tactics: CoachTactics = game["home_tactics"] if home_offense else game["away_tactics"]
	var defense_tactics: CoachTactics = game["away_tactics"] if home_offense else game["home_tactics"]

	# Select ballhandler — PG or highest ball_handling on court.
	var ballhandler:     Player = _select_ballhandler(offense_five)
	var primary_defender: Player = offense_tactics != null \
		? _get_primary_defender_from_tactics(ballhandler, defense_five, defense_tactics) \
		: _fallback_defender(ballhandler, defense_five)

	var score_margin: int = game["home_score"] - game["away_score"]
	if not home_offense:
		score_margin = -score_margin

	return {
		# Teams
		"offense_team_id":  game["home_team_id"] if home_offense else game["away_team_id"],
		"defense_team_id":  game["away_team_id"] if home_offense else game["home_team_id"],

		# Players
		"offense_five":     offense_five,
		"defense_five":     defense_five,
		"ballhandler":      ballhandler,
		"primary_defender": primary_defender,

		# Tactics — offense sees its own, but defense tactics feed into
		# _get_primary_defender via coach_tactics key.
		"coach_tactics":    offense_tactics,
		"defense_tactics":  defense_tactics,

		# Clock
		"quarter":          quarter,
		"clock_seconds":    clock_seconds,
		"shot_clock":       shot_clock,

		# Context flags
		"is_transition":    game.get("next_is_transition", false),
		"is_clutch":        is_clutch,
		"score_margin":     score_margin,

		# Fatigue
		"fatigue":          game["fatigue"],

		# Output fields (initialised by simulate_possession)
		"result":           "",
		"shot_type":        "",
		"points_scored":    0,
		"assist_player_id": -1,
		"rebounder_id":     -1,
		"fouler_id":        -1,
		"steal_player_id":  -1,
		"block_player_id":  -1,
		"play_events":      [],
		"stat_deltas":      {},
		"_rebound_available":      false,
		"_awaiting_shot_resolution": false,
		"_in_post":          false,
		"_mismatch_check_needed": false,
	}

# ===========================================================================
# RESULT MERGING
# ===========================================================================

## _merge_possession_result
## Takes the completed possession state and merges all outcomes into game.
func _merge_possession_result(
		game:         Dictionary,
		state:        Dictionary,
		quarter:      int,
		home_offense: bool) -> Dictionary:

	var points: int = state.get("points_scored", 0)

	# Update score.
	if home_offense:
		game["home_score"] += points
		if quarter <= QUARTERS:
			game["home_quarters"][quarter - 1] += points
	else:
		game["away_score"] += points
		if quarter <= QUARTERS:
			game["away_quarters"][quarter - 1] += points

	# Merge stat deltas into box score.
	var deltas: Dictionary = state.get("stat_deltas", {})
	for player_id in deltas:
		game = _merge_stat_delta(game, player_id, deltas[player_id])

	# Append play events to play_by_play.
	# Annotate each event with the running score and commentary text before appending.
	for event in state.get("play_events", []):
		event["home_score"]      = game["home_score"]
		event["away_score"]      = game["away_score"]
		event["text"]            = _commentary.generate_text(event)
		event["clock_display"]   = _commentary.format_clock(event.get("clock_seconds", 0))
		event["quarter_display"] = _commentary.format_quarter(event.get("quarter", 1))
		game["play_by_play"].append(event)

	# Steal stats — credit steal to the defender who caused the turnover.
	var steal_id: int = state.get("steal_player_id", -1)
	if steal_id != -1:
		game = _merge_stat_delta(game, steal_id, {"steals": 1})

	# Fouls — already credited in ShotResolver for shooting fouls.
	# Non-shooting fouls credited here.
	if state.get("result", "") == "foul_non_shooting":
		var fouler_id: int = state.get("fouler_id", -1)
		if fouler_id != -1:
			game = _merge_stat_delta(game, fouler_id, {"fouls": 1})

	# Set transition flag for next possession.
	# Steals and defensive rebounds trigger a transition opportunity.
	var result: String = state.get("result", "")
	game["next_is_transition"] = result in ["turnover", "defensive_rebound"] \
		and _rng.randf() < 0.55   # Not every defensive stop leads to a push.

	# Possession counters.
	if home_offense:
		game["home_possessions"] += 1
	else:
		game["away_possessions"] += 1

	return game

func _merge_stat_delta(
		game:      Dictionary,
		player_id: int,
		delta:     Dictionary) -> Dictionary:

	# Ensure player has a stat line — may be a bench player credited
	# with a stat (e.g. foul from a sub who just entered).
	if not game["box_score"].has(player_id):
		game["box_score"][player_id] = _empty_stat_line(player_id)

	var line: Dictionary = game["box_score"][player_id]
	for key in delta:
		if key == "player_id":
			continue
		if line.has(key):
			line[key] += delta[key]
		else:
			line[key] = delta[key]

	return game

# ===========================================================================
# FATIGUE MANAGEMENT
# ===========================================================================

## _update_fatigue
## Accumulates fatigue for all players who were on court this possession.
## Coach conditioning attribute reduces the drain rate.
func _update_fatigue(game: Dictionary, state: Dictionary) -> Dictionary:
	var home_drain: float = BASE_FATIGUE_PER_POSSESSION \
		* game["home_tactics"].stamina_drain_modifier
	var away_drain: float = BASE_FATIGUE_PER_POSSESSION \
		* game["away_tactics"].stamina_drain_modifier

	for p in game["home_five"]:
		# Stamina attribute reduces personal fatigue accumulation.
		var personal_drain: float = home_drain \
			* (1.0 - (float(p.stamina) - 10.0) * 0.02)
		personal_drain = maxf(0.002, personal_drain)
		game["fatigue"][p.id] = minf(1.0, game["fatigue"].get(p.id, 0.0) + personal_drain)

	for p in game["away_five"]:
		var personal_drain: float = away_drain \
			* (1.0 - (float(p.stamina) - 10.0) * 0.02)
		personal_drain = maxf(0.002, personal_drain)
		game["fatigue"][p.id] = minf(1.0, game["fatigue"].get(p.id, 0.0) + personal_drain)

	return game

# ===========================================================================
# SUBSTITUTION CHECK
# ===========================================================================

## _check_substitutions
## Asks RotationManager whether any substitutions should happen.
## If so, swaps players in home_five / away_five and resets their fatigue entry.
func _check_substitutions(
		game:          Dictionary,
		quarter:       int,
		clock_seconds: int) -> Dictionary:

	if _rotation_mgr == null:
		return game

	# Sync foul counts from running box score before checking subs.
	# This ensures foul-trouble logic uses the latest numbers.
	_rotation_mgr.update_fouls_from_box_score(game["box_score"])

	# Home substitutions.
	var home_subs: Array = _rotation_mgr.get_substitutions(
		"home", game["home_five"], game["fatigue"], quarter, clock_seconds,
		game["home_tactics"]
	)
	for sub in home_subs:
		game = _apply_substitution(game, sub["out"], sub["in"], "home")

	# Away substitutions.
	var away_subs: Array = _rotation_mgr.get_substitutions(
		"away", game["away_five"], game["fatigue"], quarter, clock_seconds,
		game["away_tactics"]
	)
	for sub in away_subs:
		game = _apply_substitution(game, sub["out"], sub["in"], "away")

	return game

func _apply_substitution(
		game:    Dictionary,
		out_id:  int,
		in_id:   int,
		side:    String) -> Dictionary:

	var five_key: String = "home_five" if side == "home" else "away_five"
	var five:     Array  = game[five_key]

	for i in five.size():
		if five[i].id == out_id:
			# Find incoming player in roster via RotationManager.
			var in_player: Player = _rotation_mgr.get_player(in_id, side)
			if in_player != null:
				five[i] = in_player
				# Keep RotationManager's on-court map in sync.
				if _rotation_mgr != null:
					_rotation_mgr.mark_substitution(out_id, in_id)
				# Initialise fatigue for incoming player if not tracked.
				if not game["fatigue"].has(in_id):
					game["fatigue"][in_id] = 0.0
				# Initialise box score entry.
				if not game["box_score"].has(in_id):
					game["box_score"][in_id] = _empty_stat_line(in_id)
				# Log the substitution event.
				game["play_by_play"].append({
					"quarter":             game["current_quarter"],
					"clock_seconds":       0,
					"team":                side,
					"event":               "substitution",
					"primary_player_id":   in_id,
					"secondary_player_id": out_id,
					"result":              "subbed_in",
					"home_score":          game["home_score"],
					"away_score":          game["away_score"],
					"text":                "",
				})
			break

	game[five_key] = five
	return game

# ===========================================================================
# PRE-GAME MOTIVATION BONUS
# ===========================================================================

## _apply_motivation_bonus
## Applies the coach's pre-game team talk bonus as a temporary attribute
## modifier. Stored in game["motivation_modifier"] and read by
## _build_possession_state when computing effective attribute values.
## In practice this is a small flat boost that fades after Q1.
func _apply_motivation_bonus(game: Dictionary) -> void:
	# The bonus is stored so PossessionSim/ShotResolver can read it.
	# We store it per-team so both coaches' talks are tracked independently.
	game["home_motivation"] = game["home_tactics"].motivation_bonus
	game["away_motivation"] = game["away_tactics"].motivation_bonus

# ===========================================================================
# FINALISATION
# ===========================================================================

## _finalise_box_score
## Calculates plus/minus and derived team stats after the game ends.
func _finalise_box_score(game: Dictionary) -> Dictionary:
	var home_score: int = game["home_score"]
	var away_score: int = game["away_score"]

	# Plus/minus: players on the winning team get a positive score,
	# losing team players get negative. Proportional to score diff.
	# (Full on/off plus/minus requires tracking which players were on court
	#  during each scoring run — deferred to a future stats pass.)
	var diff: int = home_score - away_score
	for player_id in game["box_score"]:
		var line:     Dictionary = game["box_score"][player_id]
		var is_home:  bool       = _is_home_player(game, player_id)
		line["plus_minus"] = diff if is_home else -diff

	# Team-level aggregates.
	game["home_team_stats"] = _calc_team_stats(game, true)
	game["away_team_stats"] = _calc_team_stats(game, false)

	return game

func _calc_team_stats(game: Dictionary, is_home: bool) -> Dictionary:
	var total_to: int  = 0
	var total_oreb: int = 0
	var total_dreb: int = 0
	var total_fouls: int = 0
	var fgm: int = 0
	var fga: int = 0

	for player_id in game["box_score"]:
		if _is_home_player(game, player_id) != is_home:
			continue
		var line: Dictionary = game["box_score"][player_id]
		total_to   += line.get("turnovers", 0)
		total_oreb += line.get("oreb", 0)
		total_dreb += line.get("dreb", 0)
		total_fouls += line.get("fouls", 0)
		fgm        += line.get("fgm", 0)
		fga        += line.get("fga", 0)

	var score: int = game["home_score"] if is_home else game["away_score"]
	var poss:  int = game["home_possessions"] if is_home else game["away_possessions"]
	var off_rtg: float = (float(score) / maxf(1.0, float(poss))) * 100.0

	return {
		"turnovers":  total_to,
		"oreb":       total_oreb,
		"dreb":       total_dreb,
		"fouls":      total_fouls,
		"fg_pct":     (float(fgm) / maxf(1.0, float(fga))),
		"off_rating": off_rtg,
	}

# ===========================================================================
# MATCH RESULT BUILDER
# ===========================================================================

## _build_match_result
## Assembles the final MatchResult dictionary from game state.
## This is the structure that WorldState, the UI, and the stats DB consume.
func _build_match_result(game: Dictionary, schedule_entry: Dictionary) -> Dictionary:
	return {
		# Identity
		"home_team_id":   game["home_team_id"],
		"away_team_id":   game["away_team_id"],
		"league_id":      game["league_id"],
		"date_day":       game["date_day"],
		"date_month":     game["date_month"],
		"date_year":      game["date_year"],

		# Scores
		"home_score":     game["home_score"],
		"away_score":     game["away_score"],
		"home_quarters":  game["home_quarters"],
		"away_quarters":  game["away_quarters"],

		# Player stats — the full box score
		"player_stats":   game["box_score"],

		# Team aggregates
		"home_team_stats": game.get("home_team_stats", {}),
		"away_team_stats": game.get("away_team_stats", {}),

		# Play-by-play log (for match day UI)
		"play_by_play":   game["play_by_play"],

		# Metadata
		"simulated":          false,   # false = full engine (true = QuickSim)
		"overtime_periods":   game["overtime_periods"],
		"game_seed":          game_seed,
	}

# ===========================================================================
# PLAYER SELECTION HELPERS
# ===========================================================================

## Selects the ballhandler to start a possession — the PG, or if no PG
## is on court, the player with the highest ball_handling.
func _select_ballhandler(offense_five: Array) -> Player:
	# Prefer PG.
	for p in offense_five:
		if p.position == Player.Position.PG:
			return p
	# Fall back to best ball handler.
	var best:    Player = offense_five[0]
	var best_bh: float  = -INF
	for p in offense_five:
		var v: float = float(p.ball_handling)
		if v > best_bh:
			best_bh = v
			best    = p
	return best

## Gets the primary defender using the defensive team's CoachTactics.
func _get_primary_defender_from_tactics(
		ballhandler:    Player,
		defense_five:   Array,
		defense_tactics: CoachTactics) -> Player:

	# Build a minimal state dict so CoachTactics.get_defender_for works.
	var fake_state: Dictionary = {"coach_tactics": defense_tactics}
	return defense_tactics.get_defender_for(ballhandler.id, defense_five)

## Positional fallback when no tactics object is available.
func _fallback_defender(ballhandler: Player, defense_five: Array) -> Player:
	if defense_five.is_empty():
		return ballhandler
	for p in defense_five:
		if p.position == ballhandler.position:
			return p
	return defense_five[0]

## Builds a starting five from the roster using the coach's depth chart.
## Falls back to position-based selection if depth chart is empty.
func _build_starting_five(roster: Array, coach: Coach) -> Array:
	var five: Array = []
	var positions: Array = ["PG", "SG", "SF", "PF", "C"]

	for pos in positions:
		var chart: Array = coach.depth_chart.get(pos, [])
		var found: Player = null

		# Try depth chart order.
		for pid in chart:
			for p in roster:
				if p.id == pid:
					found = p
					break
			if found != null:
				break

		# Fall back to best available at position.
		if found == null:
			var pos_enum: int = _pos_string_to_enum(pos)
			var best_ovr: int = -1
			for p in roster:
				if int(p.position) == pos_enum:
					var ovr: int = p.get_overall()
					if ovr > best_ovr:
						best_ovr = ovr
						found    = p

		if found != null and found not in five:
			five.append(found)

	# If still short (e.g. unusual roster composition), fill with best remaining.
	if five.size() < 5:
		for p in roster:
			if p not in five:
				five.append(p)
			if five.size() >= 5:
				break

	return five

func _pos_string_to_enum(pos: String) -> int:
	match pos:
		"PG": return Player.Position.PG
		"SG": return Player.Position.SG
		"SF": return Player.Position.SF
		"PF": return Player.Position.PF
		"C":  return Player.Position.C
	return Player.Position.PG

func _is_home_player(game: Dictionary, player_id: int) -> bool:
	for p in game["home_five"]:
		if p.id == player_id:
			return true
	# Also check via box score origin — home five may have changed due to subs.
	# RotationManager tracks this; for now use the starting five as proxy.
	return false

# ===========================================================================
# BOX SCORE HELPERS
# ===========================================================================

func _empty_stat_line(player_id: int) -> Dictionary:
	return {
		"player_id":  player_id,
		"minutes":    0.0,
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
		"plus_minus": 0,
		"on_court":   true,
	}

# ===========================================================================
# SIGNAL HELPERS
# ===========================================================================

func _emit_quarter_end(game: Dictionary, quarter: int) -> void:
	EventBus.quarter_ended.emit({
		"quarter":    quarter,
		"home_score": game["home_score"],
		"away_score": game["away_score"],
		"home_team_id": game["home_team_id"],
		"away_team_id": game["away_team_id"],
		# Half-time hook — UI listens for quarter == 2 to show team talk UI.
		"is_half_time": quarter == 2,
		"is_game_end":  false,
	})
