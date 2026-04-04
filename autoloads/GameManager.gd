extends Node

enum GameMode { NONE, CAREER, TEAM }

var current_mode: GameMode = GameMode.NONE

func new_game(config: Dictionary) -> void:
	# config contains: mode, coach_name, team_id, active_leagues
	current_mode = config.get("mode", GameMode.CAREER)

	# Set up coach
	WorldState.coach = {
		"first_name": config.get("first_name", "Coach"),
		"last_name": config.get("last_name", ""),
		"age": config.get("age", 35),
		"reputation": 20.0,
		"specialty": config.get("specialty", "Balanced"),
		"current_team_id": config.get("team_id", -1),
		"seasons_coached": 0,
		"career_wins": 0,
		"career_losses": 0,
		"championships": 0
	}

	# Set active leagues
	WorldState.active_leagues = config.get("active_leagues", ["nba", "g_league"])

	# Reset date to start of season
	WorldState.current_day = 1
	WorldState.current_month = 10
	WorldState.current_year = 2025
	WorldState.current_season = 2025
	WorldState.current_season_stage = "preseason"
	WorldState.game_loaded = true

	EventBus.notification_posted.emit("Welcome, Coach %s!" % WorldState.coach["last_name"], "info")
	EventBus.screen_change_requested.emit("hub")

func save_game() -> void:
	# Will expand this later with full serialization
	print("Saving game...")

func load_game() -> void:
	print("Loading game...")

func quit_to_menu() -> void:
	WorldState.game_loaded = false
	current_mode = GameMode.NONE
	EventBus.screen_change_requested.emit("main_menu")
