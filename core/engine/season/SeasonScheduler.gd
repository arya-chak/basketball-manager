class_name SeasonScheduler
extends RefCounted

# ---------------------------------------------------------------------------
# SeasonScheduler.gd
# The daily season loop. Processes one game day at a time.
#
# Called by GameManager when the player advances time. Checks WorldState.schedule
# for games on the current date, routes each game to the correct engine,
# collects results, and emits signals for the UI to respond to.
#
# Two simulation paths:
#   MatchEngine  — full possession-by-possession sim for the player's game.
#                  Returns rich MatchResult with play_by_play.
#   QuickSim     — lightweight result generator for all other games.
#                  Returns MatchResult-compatible dict with simulated: true.
#
# The player's team is identified via WorldState.coach.team_id.
# If the player's team has no game today, all games use QuickSim.
# If the player's team has a game, that game uses MatchEngine, all others
# use QuickSim first so the player can see other scores before their game.
#
# Weekly tasks:
#   - Standings rebuild (every 7 days)
#   - Injury tick
#   - Player development tick
#
# Season-end detection:
#   - When all 82 regular season games per team are played, emits
#     regular_season_complete signal and transitions to play-in/playoffs.
# ---------------------------------------------------------------------------

# How many days between forced standings rebuilds.
const STANDINGS_REBUILD_INTERVAL: int = 7

# ---------------------------------------------------------------------------
# Engine instances — created once, reused across the season.
# ---------------------------------------------------------------------------
var _match_engine: MatchEngine  = MatchEngine.new()
var _quick_sim:    QuickSim     = QuickSim.new()

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------

# Days since last standings rebuild.
var _days_since_standings_rebuild: int = 0

# Cache of player's team id — read from WorldState.coach at process_day() time.
var _player_team_id: String = ""

# Running seed for QuickSim — incremented each matchday so games vary.
var _quick_sim_seed: int = 0

# ===========================================================================
# PUBLIC ENTRY POINT — called by GameManager on every time advance
# ===========================================================================

## process_day
## Processes all games scheduled for the current WorldState date.
## Returns a MatchdayResult dictionary the UI can read immediately.
##
## MatchdayResult:
## {
##   "date":              Dictionary { day, month, year }
##   "player_game":       MatchResult or null   (full engine result)
##   "other_results":     Array of MatchResult  (QuickSim results)
##   "games_today":       int
##   "season_complete":   bool
## }
func process_day() -> Dictionary:
	var day:   int = WorldState.current_day
	var month: int = WorldState.current_month
	var year:  int = WorldState.current_year

	_player_team_id = WorldState.coach.get("team_id", "")

	# Gather today's unplayed games.
	var todays_games: Array = _get_todays_games(day, month, year)

	var matchday_result: Dictionary = {
		"date":            {"day": day, "month": month, "year": year},
		"player_game":     null,
		"other_results":   [],
		"games_today":     todays_games.size(),
		"season_complete": false,
	}

	if todays_games.is_empty():
		# No games today — still run weekly tasks if needed.
		_run_weekly_tasks()
		return matchday_result

	# Separate player game from background games.
	var player_game:      Dictionary = {}
	var background_games: Array      = []

	for game in todays_games:
		if _is_player_game(game):
			player_game = game
		else:
			background_games.append(game)

	# --- Simulate background games first (QuickSim) ---
	_quick_sim_seed += 1
	_quick_sim.seed_rng(_quick_sim_seed)

	for game in background_games:
		var result: Dictionary = _simulate_quick(game)
		matchday_result["other_results"].append(result)
		_mark_played(game)

	# --- Simulate player's game (MatchEngine) ---
	if not player_game.is_empty():
		var result: Dictionary = _simulate_full(player_game)
		matchday_result["player_game"] = result
		_mark_played(player_game)

	# --- Weekly maintenance tasks ---
	_days_since_standings_rebuild += 1
	if _days_since_standings_rebuild >= STANDINGS_REBUILD_INTERVAL:
		_run_weekly_tasks()
		_days_since_standings_rebuild = 0

	# --- Check season completion ---
	if _is_regular_season_complete():
		matchday_result["season_complete"] = true
		_handle_regular_season_end()

	# --- Emit matchday signal ---
	EventBus.matchday_complete.emit(matchday_result)

	return matchday_result

# ===========================================================================
# ADVANCE TIME — convenience wrapper called by GameManager
# ===========================================================================

## advance_to_next_game
## Advances the clock day by day until a game day is reached.
## Returns the matchday result for that day.
## Used when the player clicks "Next Game" in the UI.
func advance_to_next_game() -> Dictionary:
	var max_advance: int = 14   # Safety cap — never skip more than 2 weeks.
	var result: Dictionary = {}

	for _i in max_advance:
		Clock.advance_day()
		var todays_games: Array = _get_todays_games(
			WorldState.current_day,
			WorldState.current_month,
			WorldState.current_year
		)

		if _has_player_game(todays_games):
			result = process_day()
			break
		elif not todays_games.is_empty():
			# Background games today — process them silently then keep going.
			_process_background_only(todays_games)
		else:
			_run_weekly_tasks_if_due()

	return result

## advance_to_next_day
## Advances exactly one day and processes whatever is on that date.
## Used when the player clicks "Continue" (advance one day at a time).
func advance_to_next_day() -> Dictionary:
	Clock.advance_day()
	return process_day()

## simulate_rest_of_season
## Simulates all remaining regular season games via QuickSim.
## Used for "sim rest of season" functionality.
## Returns when regular_season_complete is true.
func simulate_rest_of_season() -> void:
	var max_days: int = 200   # Hard cap — full season is ~172 days.
	var days_run: int = 0

	while not _is_regular_season_complete() and days_run < max_days:
		Clock.advance_day()
		var todays_games: Array = _get_todays_games(
			WorldState.current_day,
			WorldState.current_month,
			WorldState.current_year
		)

		if not todays_games.is_empty():
			# Force QuickSim even for player's team.
			_quick_sim_seed += 1
			_quick_sim.seed_rng(_quick_sim_seed)
			for game in todays_games:
				_simulate_quick(game)
				_mark_played(game)

		_run_weekly_tasks_if_due()
		days_run += 1

	if _is_regular_season_complete():
		_handle_regular_season_end()

# ===========================================================================
# GAME RETRIEVAL
# ===========================================================================

## _get_todays_games
## Returns all unplayed schedule entries for the given date.
func _get_todays_games(day: int, month: int, year: int) -> Array:
	var result: Array = []
	for entry in WorldState.schedule:
		if entry.get("played", false):
			continue
		if entry["date_day"]   == day   and \
		   entry["date_month"] == month and \
		   entry["date_year"]  == year:
			result.append(entry)
	return result

func _is_player_game(game: Dictionary) -> bool:
	if _player_team_id.is_empty():
		return false
	return game["home_team_id"] == _player_team_id \
		or game["away_team_id"] == _player_team_id

func _has_player_game(games: Array) -> bool:
	for game in games:
		if _is_player_game(game):
			return true
	return false

func _mark_played(game: Dictionary) -> void:
	# Mark in WorldState.schedule directly — these are references.
	game["played"] = true

# ===========================================================================
# SIMULATION ROUTING
# ===========================================================================

## _simulate_full
## Runs the player's game through MatchEngine.
func _simulate_full(game: Dictionary) -> Dictionary:
	var home_team: Team  = WorldState.get_team(game["home_team_id"])
	var away_team: Team  = WorldState.get_team(game["away_team_id"])

	if home_team == null or away_team == null:
		push_error("SeasonScheduler: missing team for full sim — falling back to QuickSim")
		return _simulate_quick(game)

	# Load rosters from WorldState.
	var home_roster: Array = WorldState.get_roster_players(game["home_team_id"])
	var away_roster: Array = WorldState.get_roster_players(game["away_team_id"])

	# Load coaches.
	var home_coach: Coach = _get_team_coach(game["home_team_id"])
	var away_coach: Coach = _get_team_coach(game["away_team_id"])

	# Use the player's own coach object for their team.
	if game["home_team_id"] == _player_team_id:
		home_coach = _get_player_coach()
	elif game["away_team_id"] == _player_team_id:
		away_coach = _get_player_coach()

	# Seed the match engine from date + teams for reproducibility.
	_match_engine.game_seed = _game_seed(game)

	return _match_engine.simulate_game(
		home_team, away_team,
		home_coach, away_coach,
		home_roster, away_roster,
		game
	)

## _simulate_quick
## Runs a background game through QuickSim.
func _simulate_quick(game: Dictionary) -> Dictionary:
	var home_team: Team = WorldState.get_team(game["home_team_id"])
	var away_team: Team = WorldState.get_team(game["away_team_id"])

	if home_team == null or away_team == null:
		push_warning("SeasonScheduler: missing team for QuickSim — skipping")
		return {}

	var home_roster: Array = WorldState.get_roster_players(game["home_team_id"])
	var away_roster: Array = WorldState.get_roster_players(game["away_team_id"])
	var home_coach:  Coach = _get_team_coach(game["home_team_id"])
	var away_coach:  Coach = _get_team_coach(game["away_team_id"])

	return _quick_sim.simulate_game(
		home_team, away_team,
		home_roster, away_roster,
		game,
		home_coach, away_coach
	)

## _process_background_only
## Silently simulates a day of games with no player involvement.
func _process_background_only(todays_games: Array) -> void:
	_quick_sim_seed += 1
	_quick_sim.seed_rng(_quick_sim_seed)
	for game in todays_games:
		_simulate_quick(game)
		_mark_played(game)

# ===========================================================================
# SEASON COMPLETION
# ===========================================================================

## _is_regular_season_complete
## Returns true when all 82 regular season games per team have been played.
## Uses the schedule array directly — no DB query needed.
func _is_regular_season_complete() -> bool:
	# Quick check: if any game in the regular season window is unplayed, not done.
	for entry in WorldState.schedule:
		if not entry.get("played", false):
			return false
	return true

## _handle_regular_season_end
## Transitions season stage and emits the completion signal.
func _handle_regular_season_end() -> void:
	WorldState.current_season_stage = "play_in"
	WorldState.rebuild_all_standings()

	EventBus.regular_season_complete.emit({
		"season": WorldState.current_season,
		"standings": WorldState.standings,
	})

	EventBus.notification_posted.emit(
		"The regular season is over. The play-in tournament begins!", "info"
	)

# ===========================================================================
# WEEKLY MAINTENANCE TASKS
# ===========================================================================

## _run_weekly_tasks
## Runs all maintenance tasks that happen on a weekly cadence:
##   - Standings rebuild
##   - Injury tick (deferred to InjuryEngine when built)
##   - Player development tick (deferred to PlayerDev when built)
##   - Trade deadline check
##   - AI team actions (trades, waives — deferred)
func _run_weekly_tasks() -> void:
	# Standings rebuild.
	for league_id in WorldState.active_leagues:
		WorldState.rebuild_standings(league_id)

	# Trade deadline check.
	_check_trade_deadline()

	# Placeholder hooks for systems not yet built.
	# InjuryEngine.tick_week()
	# PlayerDev.tick_week()
	# AITeamManager.run_weekly_actions()

func _run_weekly_tasks_if_due() -> void:
	_days_since_standings_rebuild += 1
	if _days_since_standings_rebuild >= STANDINGS_REBUILD_INTERVAL:
		_run_weekly_tasks()
		_days_since_standings_rebuild = 0

## _check_trade_deadline
## Flags the trade deadline day and fires the appropriate signal.
func _check_trade_deadline() -> void:
	var m: int = WorldState.current_month
	var d: int = WorldState.current_day

	# Trade deadline: Feb 6 (from nba_calendar.json).
	if m == 2 and d >= 6 and d <= 8:
		if WorldState.current_season_stage == "regular":
			EventBus.notification_posted.emit(
				"The NBA trade deadline has passed.", "info"
			)

# ===========================================================================
# COACH / TEAM HELPERS
# ===========================================================================

## _get_team_coach
## Returns a Coach object for an AI-controlled team.
## For now generates a default coach — full AI coach generation is deferred.
func _get_team_coach(team_id: String) -> Coach:
	var coach: Coach = Coach.new()
	# Set basic defaults — AI coaches will get proper attributes when
	# CoachGenerator is built. For now they run the default philosophy.
	coach.team_id            = team_id
	coach.offensive_systems  = 3
	coach.defensive_systems  = 3
	coach.tactical_flexibility = 3
	coach.motivation         = 3
	coach.preferred_offense  = Coach.OffensePhilosophy.BALL_MOVEMENT
	coach.preferred_defense  = Coach.DefensePhilosophy.MAN_TO_MAN
	return coach

## _get_player_coach
## Returns the player's Coach entity from WorldState.
func _get_player_coach() -> Coach:
	# WorldState.coach is currently a Dictionary — convert to Coach object.
	# When Coach entity is fully integrated into WorldState this becomes a
	# direct reference. For now, build from the dict.
	var coach: Coach = Coach.new()
	var d: Dictionary = WorldState.coach
	if d.is_empty():
		return coach
	coach.from_dict(d)
	return coach

# ===========================================================================
# SEED GENERATION
# ===========================================================================

## _game_seed
## Produces a deterministic seed for a specific game so MatchEngine results
## are reproducible (same game always produces the same outcome if re-run).
func _game_seed(game: Dictionary) -> int:
	var s: String = "%s_%s_%d_%d_%d" % [
		game["home_team_id"],
		game["away_team_id"],
		game["date_day"],
		game["date_month"],
		game["date_year"],
	]
	var h: int = 0
	for i in s.length():
		h = (h * 31 + s.unicode_at(i)) & 0x7FFFFFFF
	return h
