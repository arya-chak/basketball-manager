extends Node

# Current game date
var current_day: int = 1
var current_month: int = 10    # Season starts in October
var current_year: int = 2025
var current_season: int = 2025

# Active leagues (set during new game setup)
var active_leagues: Array = []

# Loaded data caches (populated at game start)
var all_teams: Dictionary = {}       # team_id -> team data dict
var all_players: Dictionary = {}     # player_id -> player data dict
var standings: Dictionary = {}       # league_id -> Array of team standings
var schedule: Array = []             # Array of all scheduled matches

# Coach (player's avatar)
var coach: Dictionary = {}

# Game state flags
var game_loaded: bool = false
var is_offseason: bool = false
var current_season_stage: String = "preseason"  # preseason, regular, playoffs, offseason

func get_date_string() -> String:
	var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
				  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d, %d" % [months[current_month - 1], current_day, current_year]

func get_team(team_id: int) -> Dictionary:
	return all_teams.get(team_id, {})

func get_player(player_id: int) -> Dictionary:
	return all_players.get(player_id, {})

func get_standings(league_id: String) -> Array:
	return standings.get(league_id, [])

func update_team_record(team_id: int, won: bool) -> void:
	if all_teams.has(team_id):
		if won:
			all_teams[team_id]["wins"] += 1
		else:
			all_teams[team_id]["losses"] += 1
		EventBus.roster_changed.emit(team_id)

func get_player_team(player_id: int) -> int:
	var player = get_player(player_id)
	return player.get("team_id", -1)
