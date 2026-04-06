extends Node

# ---------------------------------------------------------------------------
# Calendar
# ---------------------------------------------------------------------------

var current_day: int = 1
var current_month: int = 10   # Season starts in October
var current_year: int = 2025
var current_season: int = 2025
var current_season_stage: String = "preseason"  # preseason, regular, playoffs, offseason
var is_offseason: bool = false

# ---------------------------------------------------------------------------
# Active leagues
# ---------------------------------------------------------------------------

var active_leagues: Array = []   # e.g. ["nba", "g_league"]

# ---------------------------------------------------------------------------
# In-memory caches — populated at game start by LeagueLoader
# Team objects and Player objects live here for the lifetime of the session
# DB is the persistent store; these are the runtime working copies
# ---------------------------------------------------------------------------

var all_teams: Dictionary = {}     # team_id (String) -> Team
var all_players: Dictionary = {}   # player_id (int)  -> Player

# ---------------------------------------------------------------------------
# Standings — rebuilt weekly, not after every game
# standings[league_id] = Array of Dictionaries sorted by win pct, each:
# {
#   team_id, wins, losses, win_pct, point_diff,
#   conference, division, streak, games_behind
# }
# ---------------------------------------------------------------------------

var standings: Dictionary = {}
var standings_dirty: bool = false   # Flagged true after any match result

# ---------------------------------------------------------------------------
# Schedule — full season of matches loaded at season start
# Each entry: {home_team_id, away_team_id, date_day, date_month, date_year, league_id}
# ---------------------------------------------------------------------------

var schedule: Array = []

# ---------------------------------------------------------------------------
# Draft
# ---------------------------------------------------------------------------

var current_draft_class: Array = []   # Array of Player objects
var draft_pick_order: Array = []      # Final lottery order for draft night

# ---------------------------------------------------------------------------
# Salary cap — current season's cap figure, updated each offseason
# ---------------------------------------------------------------------------

var current_salary_cap: int = 136000000
var league_salary_caps: Dictionary = {}   # league_id -> current cap figure

# ---------------------------------------------------------------------------
# TV deal spike tracking
# Spike year is randomised at game start within the cycle window
# ---------------------------------------------------------------------------

var tv_spike_year: int = 0
var tv_cycle_start_year: int = 0
var tv_spike_warned_one: bool = false   # Two-seasons-out warning fired
var tv_spike_warned_two: bool = false   # One-season-out warning fired

# ---------------------------------------------------------------------------
# League config cache — raw JSON dicts loaded once at game start
# league_configs["nba"] = { "cap_rules": {...}, "calendar": {...}, ... }
# ---------------------------------------------------------------------------

var league_configs: Dictionary = {}

# ---------------------------------------------------------------------------
# Coach — the player's avatar
# Stored as a Dictionary until Coach entity is fully integrated into
# WorldState as a typed object. Expected keys:
#   team_id, league_id, offensive_systems, defensive_systems,
#   tactical_flexibility, motivation, motivating, fitness_conditioning,
#   preferred_offense, preferred_defense, pref_pace_target,
#   pref_hunt_mismatches, pref_switch_on_screens, pref_paint_protection,
#   pref_press_full_court, depth_chart, minutes_targets
# ---------------------------------------------------------------------------

var coach: Dictionary = {}

# ---------------------------------------------------------------------------
# Game state flags
# ---------------------------------------------------------------------------

var game_loaded: bool = false

# ---------------------------------------------------------------------------
# DATE HELPERS
# ---------------------------------------------------------------------------

func get_date_string() -> String:
	var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
				  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d, %d" % [months[current_month - 1], current_day, current_year]

func get_season_string() -> String:
	# NBA seasons span two calendar years e.g. "2025-26"
	return "%d-%s" % [current_season, str(current_season + 1).right(2)]

# ---------------------------------------------------------------------------
# TEAM ACCESSORS
# ---------------------------------------------------------------------------

func get_team(team_id: String) -> Team:
	return all_teams.get(team_id, null)

func get_team_by_id(team_id: String) -> Team:
	# Alias used by pick revert logic in Team.gd
	return get_team(team_id)

func get_all_teams_list() -> Array:
	return all_teams.values()

func get_teams_in_conference(conference: String) -> Array:
	var result: Array = []
	for team in all_teams.values():
		if team.conference == conference:
			result.append(team)
	return result

func get_teams_in_division(division: String) -> Array:
	var result: Array = []
	for team in all_teams.values():
		if team.division == division:
			result.append(team)
	return result

func register_team(team: Team) -> void:
	all_teams[team.id] = team

func get_player_team_object(player_id: int) -> Team:
	var player = get_player(player_id)
	if player == null:
		return null
	return get_team(player.team_id)

# ---------------------------------------------------------------------------
# PLAYER ACCESSORS
# ---------------------------------------------------------------------------

func get_player(player_id: int) -> Player:
	return all_players.get(player_id, null)

func get_players_on_team(team_id: String) -> Array:
	var team = get_team(team_id)
	if team == null:
		return []
	var result: Array = []
	for pid in team.roster_ids:
		var p = get_player(pid)
		if p:
			result.append(p)
	return result

func get_two_way_players(team_id: String) -> Array:
	var team = get_team(team_id)
	if team == null:
		return []
	var result: Array = []
	for pid in team.two_way_ids:
		var p = get_player(pid)
		if p:
			result.append(p)
	return result

func register_player(player: Player) -> void:
	all_players[player.id] = player

# ---------------------------------------------------------------------------
# ROSTER HELPER — used by SeasonScheduler and MatchEngine
# Returns the full active roster (main roster + two-way) for a team.
# ---------------------------------------------------------------------------

func get_roster_players(team_id: String) -> Array:
	var team: Team = get_team(team_id)
	if team == null:
		return []
	var result: Array = []
	for pid in team.roster_ids:
		var p: Player = get_player(pid)
		if p:
			result.append(p)
	# Include two-way players — they can play in NBA games (up to 50 days).
	for pid in team.two_way_ids:
		var p: Player = get_player(pid)
		if p:
			result.append(p)
	return result

# ---------------------------------------------------------------------------
# MATCH RESULT — records result in memory and DB, marks standings dirty
# Called by MatchEngine after every simulated game
# ---------------------------------------------------------------------------

func record_match_result(
	home_team_id: String,
	away_team_id: String,
	home_score: int,
	away_score: int,
	league_id: String
) -> void:

	var home_won = home_score > away_score
	var home_team = get_team(home_team_id)
	var away_team = get_team(away_team_id)

	# Update in-memory Team objects
	if home_team:
		home_team.update_record(home_won, true, home_score, away_score)
	if away_team:
		away_team.update_record(not home_won, false, away_score, home_score)

	# Persist to DB
	Database.update_team_standings(home_team_id, home_won, true, home_score, away_score)
	Database.update_team_standings(away_team_id, not home_won, false, away_score, home_score)

	# Log match result
	Database.query_with_bindings("
		INSERT INTO match_results
			(home_team_id, away_team_id, home_score, away_score,
			 date_day, date_month, date_year, league_id, simulated)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
	", [home_team_id, away_team_id, home_score, away_score,
		current_day, current_month, current_year, league_id])

	# Mark standings as needing a rebuild
	standings_dirty = true

	EventBus.match_simulated.emit({
		"home_team_id": home_team_id,
		"away_team_id": away_team_id,
		"home_score":   home_score,
		"away_score":   away_score,
		"league_id":    league_id
	})

# ---------------------------------------------------------------------------
# STANDINGS — rebuilt weekly via Clock.gd, not after every game
# ---------------------------------------------------------------------------

func rebuild_standings(league_id: String) -> void:
	var teams = all_teams.values().filter(
		func(t): return t.league_id == league_id or _team_in_league(t, league_id)
	)

	# Build raw list
	var raw: Array = []
	for team in teams:
		raw.append({
			"team_id":     team.id,
			"full_name":   team.full_name,
			"conference":  team.conference,
			"division":    team.division,
			"wins":        team.wins,
			"losses":      team.losses,
			"win_pct":     team.get_win_pct(),
			"point_diff":  team.get_point_differential(),
			"streak":      team.get_streak_string(),
			"home_record": "%d-%d" % [team.home_wins, team.home_losses],
			"away_record": "%d-%d" % [team.away_wins, team.away_losses]
		})

	# Sort: win_pct descending, point_diff as tiebreaker
	raw.sort_custom(func(a, b):
		if a["win_pct"] != b["win_pct"]:
			return a["win_pct"] > b["win_pct"]
		return a["point_diff"] > b["point_diff"]
	)

	# Assign ranks and games behind leader
	var leader_wins   = raw[0]["wins"]   if raw.size() > 0 else 0
	var leader_losses = raw[0]["losses"] if raw.size() > 0 else 0

	for i in range(raw.size()):
		raw[i]["rank"] = i + 1
		raw[i]["games_behind"] = _calc_games_behind(
			leader_wins, leader_losses,
			raw[i]["wins"], raw[i]["losses"]
		)

	standings[league_id] = raw
	standings_dirty = false

func rebuild_all_standings() -> void:
	for league_id in active_leagues:
		rebuild_standings(league_id)

func get_standings(league_id: String) -> Array:
	if standings_dirty or not standings.has(league_id):
		rebuild_standings(league_id)
	return standings.get(league_id, [])

func get_conference_standings(league_id: String, conference: String) -> Array:
	var all_stand = get_standings(league_id)
	return all_stand.filter(func(row): return row["conference"] == conference)

func get_division_standings(league_id: String, division: String) -> Array:
	var all_stand = get_standings(league_id)
	return all_stand.filter(func(row): return row["division"] == division)

func get_playoff_picture(league_id: String, conference: String) -> Dictionary:
	# Returns top 10 seeds for play-in/playoff picture
	var conf_standings = get_conference_standings(league_id, conference)
	return {
		"direct_playoff": conf_standings.slice(0, 6),   # Seeds 1-6
		"play_in":        conf_standings.slice(6, 10),  # Seeds 7-10
		"eliminated":     conf_standings.slice(10)
	}

func _team_in_league(team: Team, league_id: String) -> bool:
	# Teams are tagged by league_id on their Player records but Team itself
	# belongs to a league via the config. For NBA, check the config.
	var config = league_configs.get(league_id, {})
	var team_list = config.get("teams", [])
	for t in team_list:
		if t.get("id") == team.id:
			return true
	return false

func _calc_games_behind(leader_w: int, leader_l: int,
						team_w: int, team_l: int) -> float:
	return float((leader_w - team_w) + (team_l - leader_l)) / 2.0

# ---------------------------------------------------------------------------
# CAP HELPERS
# ---------------------------------------------------------------------------

func get_league_cap() -> int:
	return current_salary_cap

func advance_cap(growth_rate: float) -> void:
	current_salary_cap = roundi(current_salary_cap * (1.0 + growth_rate))
	EventBus.notification_posted.emit(
		"Salary cap updated to $%s" % _format_currency(current_salary_cap), "info"
	)

func apply_tv_spike(jump_pct: float) -> void:
	var old_cap = current_salary_cap
	current_salary_cap = roundi(current_salary_cap * (1.0 + jump_pct))
	var jump_display = "%d%%" % roundi(jump_pct * 100)

	# This message will route through the news engine when it exists
	# For now it posts directly via EventBus
	EventBus.notification_posted.emit(
		"NBA finalizes landmark TV deal. Cap jumps from $%s to $%s (%s increase)." % [
			_format_currency(old_cap),
			_format_currency(current_salary_cap),
			jump_display
		], "league_news"
	)

# ---------------------------------------------------------------------------
# TV DEAL SPIKE — checked each new season via Clock.gd hook
# ---------------------------------------------------------------------------

func initialise_tv_spike_schedule(start_year: int) -> void:
	tv_cycle_start_year = start_year
	# Spike fires 8-10 years into the cycle — randomised at game start
	var cycle_length = randi_range(8, 10)
	tv_spike_year = start_year + cycle_length
	tv_spike_warned_one = false
	tv_spike_warned_two = false

func check_tv_spike_warnings(season: int) -> void:
	if tv_spike_year == 0:
		return

	var seasons_until_spike = tv_spike_year - season

	if seasons_until_spike == 2 and not tv_spike_warned_one:
		tv_spike_warned_one = true
		EventBus.notification_posted.emit(
			"The NBA's current television deal expires in 2 years. " +
			"League sources expect significant revenue growth. " +
			"Analysts project a notable salary cap increase.",
			"league_news"
		)

	elif seasons_until_spike == 1 and not tv_spike_warned_two:
		var config = league_configs.get("nba", {})
		var prog   = config.get("progression", {})
		var spike  = prog.get("tv_deal_spike", {})
		var min_pct = int(spike.get("cap_jump_pct_min", 0.20) * 100)
		var max_pct = int(spike.get("cap_jump_pct_max", 0.30) * 100)

		tv_spike_warned_two = true
		EventBus.notification_posted.emit(
			"The NBA has entered formal negotiations with broadcast partners. " +
			"Early reports suggest the new TV deal could increase league revenue by " +
			"%d-%d%%. The salary cap is expected to rise significantly next offseason." % [
				min_pct, max_pct
			],
			"league_news"
		)

	elif season == tv_spike_year:
		# Spike fires this offseason — magnitude randomised within range
		var config = league_configs.get("nba", {})
		var prog   = config.get("progression", {})
		var spike  = prog.get("tv_deal_spike", {})
		var min_jump = spike.get("cap_jump_pct_min", 0.20)
		var max_jump = spike.get("cap_jump_pct_max", 0.30)
		var jump_pct = randf_range(min_jump, max_jump)

		apply_tv_spike(jump_pct)

		# Begin next cycle
		tv_cycle_start_year = season
		var next_cycle = randi_range(8, 10)
		tv_spike_year = season + next_cycle
		tv_spike_warned_one = false
		tv_spike_warned_two = false

# ---------------------------------------------------------------------------
# WEEKLY STANDINGS UPDATE — called by Clock.gd at end of each week
# ---------------------------------------------------------------------------

func end_of_week_update() -> void:
	if standings_dirty:
		rebuild_all_standings()

# ---------------------------------------------------------------------------
# OFFSEASON RESET — called when offseason begins
# Resets per-season state, advances cap, purges expired exceptions
# ---------------------------------------------------------------------------

func begin_offseason() -> void:
	is_offseason = true
	current_season_stage = "offseason"

	# Advance cap by base growth rate + variance
	var config = league_configs.get("nba", {})
	var prog   = config.get("progression", {})
	var base   = prog.get("cap_growth", {}).get("annual_base_rate", 0.06)
	var variance = prog.get("cap_growth", {}).get("annual_variance", 0.02)
	var growth = base + randf_range(-variance, variance)

	# TV spike handles its own cap jump — don't double-apply
	if current_season != tv_spike_year:
		advance_cap(growth)

	# Purge expired trade exceptions on all teams
	for team in all_teams.values():
		team.purge_expired_exceptions(current_season)
		team.bae_used_last_year = false   # Reset BAE availability

	# Rebuild standings one final time for end-of-season display
	rebuild_all_standings()
	EventBus.offseason_started.emit()

func begin_new_season() -> void:
	current_season += 1
	current_season_stage = "preseason"
	is_offseason = false

	# Check if TV deal warnings need to fire
	check_tv_spike_warnings(current_season)

	# Reset all team standings for the new season
	for team in all_teams.values():
		team.reset_standings()

	standings_dirty = true
	EventBus.new_season_started.emit(current_season)

# ---------------------------------------------------------------------------
# UTILITY
# ---------------------------------------------------------------------------

func _format_currency(amount: int) -> String:
	# Formats e.g. 136000000 -> "136,000,000"
	var s = str(amount)
	var result = ""
	var count = 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = "," + result
		result = s[i] + result
		count += 1
	return result

func get_date_dict() -> Dictionary:
	return {
		"day":   current_day,
		"month": current_month,
		"year":  current_year
	}
