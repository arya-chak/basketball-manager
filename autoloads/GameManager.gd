extends Node

enum GameMode { NONE, CAREER, TEAM }

var current_mode: GameMode = GameMode.NONE

func new_game(config: Dictionary) -> void:
	current_mode = config.get("mode", GameMode.CAREER)

	# Set up coach avatar
	WorldState.coach = {
		"first_name":      config.get("first_name", "Coach"),
		"last_name":       config.get("last_name", ""),
		"age":             config.get("age", 35),
		"reputation":      20.0,
		"specialty":       config.get("specialty", "Balanced"),
		"current_team_id": config.get("team_id", ""),
		"seasons_coached": 0,
		"career_wins":     0,
		"career_losses":   0,
		"championships":   0
	}

	# Set active leagues
	WorldState.active_leagues = config.get("active_leagues", ["nba", "g_league"])

	# Reset calendar to season start
	WorldState.current_day          = 1
	WorldState.current_month        = 10
	WorldState.current_year         = 2025
	WorldState.current_season       = 2025
	WorldState.current_season_stage = "preseason"
	WorldState.game_loaded          = true

	# Run world generation via LeagueLoader
	var loader = LeagueLoader.new()
	loader.load_progress.connect(_on_load_progress)
	loader.load_world({
		"active_leagues": WorldState.active_leagues,
		"start_season":   WorldState.current_season
	})

	EventBus.notification_posted.emit(
		"Welcome, Coach %s!" % WorldState.coach["last_name"], "info"
	)
	EventBus.screen_change_requested.emit("hub")

func _on_load_progress(pct: float, message: String) -> void:
	# Will route to loading screen UI when built
	# For now just re-emit on EventBus for any listener
	EventBus.notification_posted.emit(
		"Loading: %s" % message, "system"
	)

func save_game() -> void:
	print("Saving game...")
	# Save all teams and players back to DB
	Database.query("BEGIN TRANSACTION")
	for team in WorldState.all_teams.values():
		Database.save_team(team)
	Database.query("COMMIT")

func load_game() -> void:
	print("Loading game...")

func quit_to_menu() -> void:
	WorldState.game_loaded = false
	current_mode           = GameMode.NONE
	EventBus.screen_change_requested.emit("main_menu")
