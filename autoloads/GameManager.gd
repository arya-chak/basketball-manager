extends Node

# ---------------------------------------------------------------------------
# GameManager.gd
# The top-level game orchestrator. Singleton autoload.
#
# Responsibilities:
#   - New game setup: coach creation, LeagueLoader, ScheduleGenerator
#   - Time advancement: routes player input to SeasonScheduler
#   - Season rollover: end-of-season sequence, offseason, new season start
#   - Save / load: serialises WorldState to DB and restores it
#   - Screen transitions: requests UI changes via EventBus
#
# Everything that crosses system boundaries lives here. Individual engines
# (MatchEngine, SeasonScheduler, etc.) never call each other directly —
# GameManager is the wiring layer between them.
# ---------------------------------------------------------------------------

enum GameMode { NONE, CAREER }

var current_mode: GameMode = GameMode.NONE

# SeasonScheduler instance — lives for the lifetime of a loaded game.
var _season_scheduler: SeasonScheduler = null

# ---------------------------------------------------------------------------
# SIGNALS (received from EventBus, wired in _ready)
# ---------------------------------------------------------------------------

func _ready() -> void:
	EventBus.regular_season_complete.connect(_on_regular_season_complete)
	EventBus.offseason_started.connect(_on_offseason_started)

# ===========================================================================
# NEW GAME
# ===========================================================================

## new_game
## Full new game setup. Expects a config dictionary from the UI:
## {
##   "first_name":      String,
##   "last_name":       String,
##   "age":             int,
##   "team_id":         String,
##   "active_leagues":  Array,    -- e.g. ["nba", "g_league"]
##   "styles":          Array,    -- Coach.CoachingStyle enum values (up to 3)
##   "personalities":   Array,    -- Coach.Personality enum values (up to 2)
##   "qualification":   int,      -- 0=none, 1=bronze, 2=silver, 3=gold
##   "playing_career":  int,      -- rep bonus per manager creation step
##   "non_playing_bonus": float,
##   "preferred_offense": int,    -- Coach.OffensePhilosophy
##   "preferred_defense": int,    -- Coach.DefensePhilosophy
##   "depth_chart":     Dictionary,
##   "minutes_targets": Dictionary,
## }
func new_game(config: Dictionary) -> void:
	current_mode = GameMode.CAREER

	# --- Build coach entity from creation config ---
	var coach: Coach = _build_coach_from_config(config)
	WorldState.coach = coach.to_dict()

	# --- Set active leagues ---
	WorldState.active_leagues = config.get("active_leagues", ["nba"])

	# --- Reset calendar to preseason ---
	WorldState.current_day          = 25   # Training camp starts Sep 25
	WorldState.current_month        = 9
	WorldState.current_year         = 2025
	WorldState.current_season       = 2025
	WorldState.current_season_stage = "preseason"
	WorldState.is_offseason         = false
	WorldState.game_loaded          = true
	WorldState.schedule             = []

	# --- World generation ---
	EventBus.notification_posted.emit("Generating world...", "system")
	var loader := LeagueLoader.new()
	loader.load_progress.connect(_on_load_progress)
	loader.load_world({
		"active_leagues": WorldState.active_leagues,
		"start_season":   WorldState.current_season,
	})

	# --- Generate season schedule ---
	EventBus.notification_posted.emit("Building schedule...", "system")
	_generate_and_save_schedule()

	# --- Initialise season scheduler ---
	_season_scheduler = SeasonScheduler.new()

	# --- Welcome message ---
	var team_name: String = _get_team_name(coach.team_id)
	EventBus.notification_posted.emit(
		"Welcome, Coach %s. You are now the head coach of the %s." \
			% [coach.last_name, team_name],
		"info"
	)

	EventBus.new_season_started.emit(WorldState.current_season)
	EventBus.screen_change_requested.emit("hub")

# ---------------------------------------------------------------------------
# Coach builder — translates creation UI config into a Coach entity.
# ---------------------------------------------------------------------------

func _build_coach_from_config(config: Dictionary) -> Coach:
	var coach := Coach.new()

	coach.first_name    = config.get("first_name", "Coach")
	coach.last_name     = config.get("last_name", "")
	coach.age           = config.get("age", 40)
	coach.nationality   = config.get("nationality", "American")
	coach.is_player_coach = true
	coach.team_id       = config.get("team_id", "")
	coach.league_id     = "nba"
	coach.contract_years = 3
	coach.seasons_at_club = 0

	# Apply creation steps.
	coach.apply_qualification(config.get("qualification", 0))
	coach.apply_styles(config.get("styles", []))
	coach.apply_personalities(config.get("personalities", []))

	# Philosophy overrides from the creation UI.
	if config.has("preferred_offense"):
		coach.preferred_offense = config["preferred_offense"]
	if config.has("preferred_defense"):
		coach.preferred_defense = config["preferred_defense"]

	# Tactical preferences.
	if config.has("pref_hunt_mismatches"):
		coach.pref_hunt_mismatches = config["pref_hunt_mismatches"]
	if config.has("pref_switch_on_screens"):
		coach.pref_switch_on_screens = config["pref_switch_on_screens"]

	# Depth chart and minutes targets from squad screen (may be empty at creation).
	if config.has("depth_chart"):
		coach.depth_chart = config["depth_chart"]
	if config.has("minutes_targets"):
		coach.minutes_targets = config["minutes_targets"]

	# Starting reputation from playing career + non-playing background.
	var playing_bonus: float     = float(config.get("playing_career_bonus", 0))
	var non_playing_bonus: float = float(config.get("non_playing_bonus", 0))
	var recognition_mult: float  = float(config.get("recognition_multiplier", 1.0))
	var qual_bonus: float        = _qualification_rep_bonus(config.get("qualification", 0))
	var personality_mult: float  = 1.1 if Coach.Personality.ACCOMPLISHED in coach.personalities \
		else 1.0

	coach.reputation = roundi(
		(playing_bonus + non_playing_bonus * recognition_mult + qual_bonus)
		* personality_mult
	)
	coach.reputation = clampi(coach.reputation, 0, 100)

	return coach

func _qualification_rep_bonus(tier: int) -> float:
	match tier:
		3: return 20.0
		2: return 12.0
		1: return 6.0
	return 0.0

# ---------------------------------------------------------------------------
# Schedule generation helper.
# ---------------------------------------------------------------------------

func _generate_and_save_schedule() -> void:
	var nba_config: Dictionary = WorldState.league_configs.get("nba", {})
	var teams_data: Array      = nba_config.get("teams", {}).get("teams", [])

	if teams_data.is_empty():
		push_error("GameManager: no NBA team data found for schedule generation.")
		return

	var generator := ScheduleGenerator.new()
	var schedule:   Array = generator.generate(
		teams_data,
		WorldState.current_season,
		"nba",
		WorldState.current_season   # Season year as RNG seed — reproducible.
	)

	WorldState.schedule = schedule
	_save_schedule_to_db(schedule)

func _save_schedule_to_db(schedule: Array) -> void:
	Database.query("BEGIN TRANSACTION")
	for entry in schedule:
		Database.query_with_bindings(
			"INSERT OR IGNORE INTO schedule
				(home_team_id, away_team_id, date_day, date_month, date_year,
				 league_id, played, game_type, marquee)
			 VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)",
			[
				entry["home_team_id"], entry["away_team_id"],
				entry["date_day"], entry["date_month"], entry["date_year"],
				entry.get("league_id", "nba"),
				entry.get("game_type", "regular"),
				1 if entry.get("marquee", false) else 0,
			]
		)
	Database.query("COMMIT")

# ===========================================================================
# TIME ADVANCEMENT — called by UI buttons
# ===========================================================================

## advance_to_next_game
## Moves time forward to the player's next scheduled game and simulates it.
## Returns the MatchdayResult for the UI to display.
func advance_to_next_game() -> Dictionary:
	if _season_scheduler == null or not WorldState.game_loaded:
		return {}
	if WorldState.current_season_stage != "regular":
		push_warning("GameManager: advance_to_next_game called outside regular season.")
		return {}
	return _season_scheduler.advance_to_next_game()

## advance_one_day
## Moves time forward exactly one day and processes whatever is scheduled.
## Used for granular day-by-day control (e.g. during free agency window).
func advance_one_day() -> Dictionary:
	if _season_scheduler == null or not WorldState.game_loaded:
		return {}
	return _season_scheduler.advance_to_next_day()

## simulate_rest_of_season
## Fast-forwards all remaining regular season games via QuickSim.
## Blocking call — notifies UI when complete.
func simulate_rest_of_season() -> void:
	if _season_scheduler == null or not WorldState.game_loaded:
		return
	EventBus.notification_posted.emit("Simulating rest of season...", "system")
	_season_scheduler.simulate_rest_of_season()

## process_today
## Processes all games on the current date without advancing the clock.
## Useful if the game was loaded mid-day or after a save/load.
func process_today() -> Dictionary:
	if _season_scheduler == null or not WorldState.game_loaded:
		return {}
	return _season_scheduler.process_day()

# ===========================================================================
# SEASON COMPLETION HANDLING
# ===========================================================================

func _on_regular_season_complete(data: Dictionary) -> void:
	# Regular season is over — trigger the play-in / playoff flow.
	WorldState.rebuild_all_standings()
	EventBus.notification_posted.emit(
		"The regular season is complete. Standings are final.", "info"
	)
	# PlayoffEngine.start_play_in() will be called here when built.
	EventBus.screen_change_requested.emit("standings")

func _on_offseason_started() -> void:
	# Offseason has begun — run end-of-season maintenance.
	_run_end_of_season()

func _run_end_of_season() -> void:
	# Cap advancement and trade exception purge are handled by
	# WorldState.begin_offseason() which Clock.gd calls automatically.
	# GameManager handles the cross-system coordination here.

	# Reset schedule for next season.
	WorldState.schedule = []

	# Increment season counter.
	WorldState.current_season += 1

	# Check TV deal spike warnings for the new season.
	WorldState.check_tv_spike_warnings(WorldState.current_season)

	EventBus.notification_posted.emit(
		"Welcome to the %s offseason. Free agency opens July 1." \
			% WorldState.get_season_string(),
		"info"
	)

## start_new_season
## Called when the player advances through the offseason and into preseason.
## Generates the new season's schedule and resets season state.
func start_new_season() -> void:
	WorldState.begin_new_season()

	# Generate new 82-game schedule for the upcoming season.
	_generate_and_save_schedule()

	# Re-initialise the season scheduler for the new calendar.
	_season_scheduler = SeasonScheduler.new()

	EventBus.notification_posted.emit(
		"The %s season is underway. Training camp opens September 25." \
			% WorldState.get_season_string(),
		"info"
	)
	EventBus.screen_change_requested.emit("hub")

# ===========================================================================
# SAVE / LOAD
# ===========================================================================

## save_game
## Persists all mutable WorldState data back to the DB.
## Schedule is already DB-backed via _save_schedule_to_db().
## Players and teams are updated incrementally throughout the session,
## so this is a final consistency flush.
func save_game() -> void:
	if not WorldState.game_loaded:
		return

	EventBus.notification_posted.emit("Saving...", "system")

	Database.query("BEGIN TRANSACTION")

	# Flush all teams.
	for team in WorldState.all_teams.values():
		Database.save_team(team)

	# Flush all players (attribute changes from development, injuries etc).
	for player in WorldState.all_players.values():
		Database.save_player(player)

	# Save coach state.
	_save_coach()

	# Save WorldState meta (season, date, cap).
	_save_world_meta()

	# Mark all played schedule entries.
	_flush_schedule_played_flags()

	Database.query("COMMIT")

	EventBus.notification_posted.emit("Game saved.", "info")

func _save_coach() -> void:
	var d: Dictionary = WorldState.coach
	if d.is_empty():
		return
	Database.query_with_bindings(
		"INSERT OR REPLACE INTO coaches
			(id, first_name, last_name, age, team_id, league_id,
			 reputation, career_wins, career_losses, seasons_at_club,
			 offensive_systems, defensive_systems, tactical_flexibility,
			 motivation, player_development, fitness_conditioning,
			 working_with_youth, scouting, adaptability, authority,
			 determination, people_management, motivating,
			 preferred_offense, preferred_defense, pref_pace_target,
			 pref_hunt_mismatches, pref_switch_on_screens,
			 pref_paint_protection, pref_press_full_court,
			 is_player_coach)
		 VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
		         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		[
			d.get("first_name", ""),        d.get("last_name", ""),
			d.get("age", 40),               d.get("team_id", ""),
			d.get("league_id", "nba"),      d.get("reputation", 0),
			d.get("career_wins", 0),        d.get("career_losses", 0),
			d.get("seasons_at_club", 0),
			d.get("offensive_systems", 2),  d.get("defensive_systems", 2),
			d.get("tactical_flexibility", 2), d.get("motivation", 2),
			d.get("player_development", 2), d.get("fitness_conditioning", 2),
			d.get("working_with_youth", 2), d.get("scouting", 2),
			d.get("adaptability", 2),       d.get("authority", 2),
			d.get("determination", 2),      d.get("people_management", 2),
			d.get("motivating", 2),
			d.get("preferred_offense", 0),  d.get("preferred_defense", 0),
			d.get("pref_pace_target", 1.0),
			1 if d.get("pref_hunt_mismatches", true) else 0,
			1 if d.get("pref_switch_on_screens", false) else 0,
			1 if d.get("pref_paint_protection", false) else 0,
			1 if d.get("pref_press_full_court", false) else 0,
			1,   # is_player_coach always true for the player's coach
		]
	)

func _save_world_meta() -> void:
	Database.query_with_bindings(
		"INSERT OR REPLACE INTO world_meta
			(id, current_day, current_month, current_year,
			 current_season, current_season_stage, salary_cap,
			 tv_spike_year, tv_cycle_start_year)
		 VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)",
		[
			WorldState.current_day,   WorldState.current_month,
			WorldState.current_year,  WorldState.current_season,
			WorldState.current_season_stage,
			WorldState.current_salary_cap,
			WorldState.tv_spike_year, WorldState.tv_cycle_start_year,
		]
	)

func _flush_schedule_played_flags() -> void:
	# Update played = 1 for all entries that have been simulated.
	for entry in WorldState.schedule:
		if entry.get("played", false):
			Database.query_with_bindings(
				"UPDATE schedule SET played = 1
				 WHERE home_team_id = ? AND away_team_id = ?
				   AND date_day = ? AND date_month = ? AND date_year = ?",
				[
					entry["home_team_id"], entry["away_team_id"],
					entry["date_day"], entry["date_month"], entry["date_year"],
				]
			)

## load_game
## Restores a saved game from the DB into WorldState.
func load_game() -> void:
	EventBus.notification_posted.emit("Loading...", "system")

	# Restore world meta.
	var meta: Array = Database.query("SELECT * FROM world_meta WHERE id = 1")
	if meta.is_empty():
		push_error("GameManager: no save data found.")
		return

	var m: Dictionary = meta[0]
	WorldState.current_day          = m.get("current_day", 1)
	WorldState.current_month        = m.get("current_month", 10)
	WorldState.current_year         = m.get("current_year", 2025)
	WorldState.current_season       = m.get("current_season", 2025)
	WorldState.current_season_stage = m.get("current_season_stage", "preseason")
	WorldState.current_salary_cap   = m.get("salary_cap", 136000000)
	WorldState.tv_spike_year        = m.get("tv_spike_year", 0)
	WorldState.tv_cycle_start_year  = m.get("tv_cycle_start_year", 0)

	# Restore coach.
	var coach_rows: Array = Database.query("SELECT * FROM coaches WHERE is_player_coach = 1")
	if not coach_rows.is_empty():
		var coach := Coach.new()
		coach.from_dict(coach_rows[0])
		WorldState.coach = coach.to_dict()

	# Restore active leagues.
	WorldState.active_leagues = ["nba"]   # TODO: persist active leagues in world_meta

	# Load league configs.
	var loader := LeagueLoader.new()
	loader.load_progress.connect(_on_load_progress)
	loader.load_configs_only(WorldState.active_leagues)

	# Load teams and players into WorldState caches.
	_load_teams_and_players()

	# Load schedule.
	_load_schedule()

	# Initialise season scheduler.
	_season_scheduler = SeasonScheduler.new()

	WorldState.game_loaded  = true
	WorldState.is_offseason = WorldState.current_season_stage == "offseason"

	WorldState.rebuild_all_standings()

	EventBus.notification_posted.emit("Game loaded.", "info")
	EventBus.screen_change_requested.emit("hub")

func _load_teams_and_players() -> void:
	# Load all teams.
	var team_rows: Array = Database.query("SELECT * FROM teams")
	for row in team_rows:
		var team := Team.new()
		team.from_dict(row)
		WorldState.register_team(team)

	# Load all players.
	var player_ids: Array = Database.query("SELECT id FROM players")
	for row in player_ids:
		var player: Player = Database.load_player(row["id"])
		if player:
			WorldState.register_player(player)

func _load_schedule() -> void:
	var rows: Array = Database.query(
		"SELECT * FROM schedule ORDER BY date_year, date_month, date_day"
	)
	WorldState.schedule = []
	for row in rows:
		WorldState.schedule.append({
			"home_team_id": row["home_team_id"],
			"away_team_id": row["away_team_id"],
			"date_day":     row["date_day"],
			"date_month":   row["date_month"],
			"date_year":    row["date_year"],
			"league_id":    row.get("league_id", "nba"),
			"played":       row.get("played", 0) == 1,
			"game_type":    row.get("game_type", "regular"),
			"marquee":      row.get("marquee", 0) == 1,
		})

# ===========================================================================
# COACH TACTICS UPDATE — called from the Tactics/Squad screen
# ===========================================================================

## update_coach_tactics
## Saves updated coach preferences from the UI back to WorldState.coach.
## Tactical changes take effect from the next game.
func update_coach_tactics(changes: Dictionary) -> void:
	for key in changes:
		WorldState.coach[key] = changes[key]
	EventBus.notification_posted.emit("Tactics updated.", "info")

## update_depth_chart
## Saves the updated depth chart from the squad screen.
func update_depth_chart(depth_chart: Dictionary) -> void:
	WorldState.coach["depth_chart"] = depth_chart

## update_minutes_targets
## Saves the updated minutes targets from the squad screen.
func update_minutes_targets(minutes_targets: Dictionary) -> void:
	WorldState.coach["minutes_targets"] = minutes_targets

# ===========================================================================
# QUIT / MENU
# ===========================================================================

func quit_to_menu() -> void:
	WorldState.game_loaded  = false
	WorldState.schedule     = []
	WorldState.all_teams    = {}
	WorldState.all_players  = {}
	WorldState.coach        = {}
	WorldState.standings    = {}
	_season_scheduler       = null
	current_mode            = GameMode.NONE
	EventBus.screen_change_requested.emit("main_menu")

# ===========================================================================
# HELPERS
# ===========================================================================

func _get_team_name(team_id: String) -> String:
	var team: Team = WorldState.get_team(team_id)
	if team != null:
		return team.full_name
	return team_id

func _on_load_progress(pct: float, message: String) -> void:
	EventBus.notification_posted.emit(
		"[%.0f%%] %s" % [pct * 100.0, message], "system"
	)
