class_name LeagueLoader
extends RefCounted

# ---------------------------------------------------------------------------
# Progress signal — listened to by loading screen UI when built
# For now also prints to console
# ---------------------------------------------------------------------------

signal load_progress(pct: float, message: String)

# ---------------------------------------------------------------------------
# Internal references
# ---------------------------------------------------------------------------

var _generator: PlayerGenerator
var _contract_gen: ContractGenerator

# ---------------------------------------------------------------------------
# ENTRY POINT — called by GameManager.new_game()
# config contains: active_leagues, start_season
# ---------------------------------------------------------------------------

func load_world(config: Dictionary) -> void:
	_generator    = PlayerGenerator.new()
	_contract_gen = ContractGenerator.new()

	var active_leagues = config.get("active_leagues", ["nba", "g_league"])
	var start_season   = config.get("start_season", 2025)

	_emit_progress(0.0, "Loading league configurations...")
	_load_all_configs(active_leagues)

	_emit_progress(0.08, "Initialising salary cap...")
	_initialise_caps()

	_emit_progress(0.12, "Setting up TV deal schedule...")
	WorldState.initialise_tv_spike_schedule(start_season)

	_emit_progress(0.18, "Building NBA teams...")
	var nba_teams = _build_nba_teams()

	_emit_progress(0.28, "Building G League teams...")
	var g_league_teams = _build_g_league_teams()

	_emit_progress(0.35, "Assigning draft picks...")
	_assign_initial_picks(nba_teams, start_season)

	_emit_progress(0.40, "Generating NBA rosters...")
	var all_players: Array = []
	var all_contracts: Array = []
	_generate_nba_rosters(nba_teams, all_players, all_contracts)

	_emit_progress(0.58, "Generating G League rosters...")
	_generate_g_league_rosters(g_league_teams, nba_teams, all_players, all_contracts)

	_emit_progress(0.68, "Generating draft class...")
	var draft_prospects = _generate_draft_class(start_season + 1)
	all_players.append_array(draft_prospects)

	_emit_progress(0.74, "Enforcing cap compliance...")
	_enforce_all_caps(nba_teams, all_contracts)
	_recalculate_salary_totals(nba_teams, all_contracts)

	_emit_progress(0.80, "Saving players to database...")
	Database.save_players_batch(all_players)

	_emit_progress(0.85, "Saving teams to database...")
	var all_teams = nba_teams + g_league_teams
	Database.save_teams_batch(all_teams)

	_emit_progress(0.88, "Saving contracts to database...")
	_save_contracts_batch(all_contracts)

	_emit_progress(0.92, "Recording tenure history...")
	_start_all_tenures(all_players, start_season)

	_emit_progress(0.96, "Building standings...")
	WorldState.rebuild_all_standings()

	_emit_progress(1.0, "World generation complete.")
	EventBus.notification_posted.emit(
		"Welcome, Coach. The season is about to begin.", "info"
	)

# ---------------------------------------------------------------------------
# STEP 1 — Load JSON configs into WorldState.league_configs
# ---------------------------------------------------------------------------

func _load_all_configs(active_leagues: Array) -> void:
	var file_map = {
		"nba": {
			"cap_rules":    "res://data/leagues/nba/nba_cap_rules.json",
			"calendar":     "res://data/leagues/nba/nba_calendar.json",
			"progression":  "res://data/leagues/nba/nba_progression.json",
			"expectations": "res://data/leagues/nba/nba_expectations.json",
			"teams":        "res://data/leagues/nba/nba_teams.json"
		},
		"g_league": {
			"teams": "res://data/leagues/g_league/g_league_teams.json"
		}
	}

	for league_id in active_leagues:
		if not file_map.has(league_id):
			push_warning("LeagueLoader: no config files registered for '%s'" % league_id)
			continue

		var league_data: Dictionary = {}
		for key in file_map[league_id]:
			var path = file_map[league_id][key]
			var parsed = _read_json(path)
			if parsed != null:
				league_data[key] = parsed
			else:
				push_error("LeagueLoader: failed to load '%s'" % path)

		WorldState.league_configs[league_id] = league_data

# ---------------------------------------------------------------------------
# STEP 2 — Initialise salary caps per league
# ---------------------------------------------------------------------------

func _initialise_caps() -> void:
	# NBA cap comes from nba_cap_rules.json
	var nba_config = WorldState.league_configs.get("nba", {})
	var cap_rules  = nba_config.get("cap_rules", {})
	var nba_cap    = cap_rules.get("cap", {}).get("starting_value", 136000000)

	WorldState.league_salary_caps["nba"]      = nba_cap
	WorldState.current_salary_cap             = nba_cap

	# G League flat salary — stored in g_league teams config
	var gl_config  = WorldState.league_configs.get("g_league", {})
	var gl_teams   = gl_config.get("teams", {})
	var gl_salary  = gl_teams.get("salary_scale", {}).get("annual_salary", 40000)
	WorldState.league_salary_caps["g_league"] = gl_salary

# ---------------------------------------------------------------------------
# STEP 3 — Build NBA Team objects from nba_teams.json
# ---------------------------------------------------------------------------

func _build_nba_teams() -> Array:
	var nba_config  = WorldState.league_configs.get("nba", {})
	var teams_data  = nba_config.get("teams", {})
	var teams_array = teams_data.get("teams", [])
	var result: Array = []

	for data in teams_array:
		var team = _build_nba_team_from_data(data)
		WorldState.register_team(team)
		result.append(team)

	return result

func _build_nba_team_from_data(data: Dictionary) -> Team:
	var team                     = Team.new()
	team.id                      = data.get("id", "")
	team.full_name               = data.get("full_name", "")
	team.city                    = data.get("city", "")
	team.abbreviation            = data.get("abbreviation", "")
	team.conference              = data.get("conference", "")
	team.division                = data.get("division", "")
	team.arena                   = data.get("arena", "")
	team.prestige                = data.get("prestige", 50)
	team.market_size             = data.get("market_size", "medium")

	var owner                    = data.get("owner", {})
	team.owner_name              = owner.get("name", "")
	team.tax_willingness         = owner.get("tax_willingness", 0.5)
	team.spending_aggressiveness = owner.get("spending_aggressiveness", 0.5)
	team.patience                = owner.get("patience", 0.5)
	team.ambition                = owner.get("ambition", 0.5)
	team.will_tank               = owner.get("will_tank", false)

	# Initial expectation tier — rough proxy from prestige
	# Full calculation happens each preseason
	team.expectation_tier = _prestige_to_expectation_tier(team.prestige)

	return team

func _prestige_to_expectation_tier(prestige: int) -> String:
	if prestige >= 90:   return "title_contender"
	elif prestige >= 78: return "deep_run"
	elif prestige >= 68: return "playoff_team"
	elif prestige >= 58: return "play_in"
	elif prestige >= 50: return "development"
	else:                return "tank"

# ---------------------------------------------------------------------------
# STEP 4 — Build G League Team objects from g_league_teams.json
# ---------------------------------------------------------------------------

func _build_g_league_teams() -> Array:
	var gl_config   = WorldState.league_configs.get("g_league", {})
	var teams_data  = gl_config.get("teams", {})
	var teams_array = teams_data.get("teams", [])
	var result: Array = []

	for data in teams_array:
		var team = _build_g_league_team_from_data(data)
		WorldState.register_team(team)
		result.append(team)

	return result

func _build_g_league_team_from_data(data: Dictionary) -> Team:
	var team              = Team.new()
	team.id               = data.get("id", "")
	team.full_name        = data.get("full_name", "")
	team.city             = data.get("city", "")
	team.abbreviation     = data.get("abbreviation", "")
	team.conference       = "G League"
	team.division         = "G League"
	team.arena            = data.get("arena", "")
	team.market_size      = "small"
	team.expectation_tier = "development"

	# Prestige derived from NBA affiliate
	var affiliate_id = data.get("nba_affiliate_id", "")
	var nba_team     = WorldState.get_team(affiliate_id)
	team.prestige    = roundi(nba_team.prestige * 0.4) if nba_team else 20

	# Owner personality inherited from NBA affiliate
	if nba_team:
		team.owner_name              = nba_team.owner_name
		team.tax_willingness         = nba_team.tax_willingness
		team.spending_aggressiveness = nba_team.spending_aggressiveness
		team.patience                = nba_team.patience
		team.ambition                = nba_team.ambition * 0.6  # Lower ambition in G League
		team.will_tank               = false

	# Store affiliate link as metadata
	team.set_meta("nba_affiliate_id", affiliate_id)

	return team

# ---------------------------------------------------------------------------
# STEP 5 — Assign initial draft picks (5 years, both rounds) to all NBA teams
# ---------------------------------------------------------------------------

func _assign_initial_picks(nba_teams: Array, start_season: int) -> void:
	for team in nba_teams:
		for year in range(start_season, start_season + 5):
			for round in [1, 2]:
				var pick = team.create_unprotected_pick(year, round)
				team.owned_picks.append(pick)

# ---------------------------------------------------------------------------
# STEP 6 — Generate NBA rosters and contracts
# Fills all_players and all_contracts arrays in place
# ---------------------------------------------------------------------------

func _generate_nba_rosters(
	nba_teams: Array,
	all_players: Array,
	all_contracts: Array
) -> void:

	var cap = WorldState.league_salary_caps.get("nba", 136000000)

	for team in nba_teams:
		var roster = _generator.generate_full_nba_roster(team.id)

		for player in roster:
			player.league_id = "nba"
			team.roster_ids.append(player.id)   # ID assigned after DB save — placeholder
			WorldState.register_player(player)
			all_players.append(player)

			var contract = _contract_gen.generate_world_gen_contract(
				player, team, cap, false
			)
			all_contracts.append(contract)

# ---------------------------------------------------------------------------
# STEP 7 — Generate G League rosters and contracts
# ---------------------------------------------------------------------------

func _generate_g_league_rosters(
	g_league_teams: Array,
	nba_teams: Array,
	all_players: Array,
	all_contracts: Array
) -> void:

	for gl_team in g_league_teams:
		var affiliate_id = gl_team.get_meta("nba_affiliate_id", "")
		var roster       = _generator.generate_full_g_league_roster(gl_team.id)

		for player in roster:
			player.league_id = "g_league"
			gl_team.roster_ids.append(player.id)
			WorldState.register_player(player)
			all_players.append(player)

			var contract = _contract_gen.generate_world_gen_contract(
				player, gl_team, 0, true  # is_g_league = true
			)
			all_contracts.append(contract)

# ---------------------------------------------------------------------------
# STEP 8 — Generate draft class for next season
# ---------------------------------------------------------------------------

func _generate_draft_class(draft_year: int) -> Array:
	var prospects = _generator.generate_draft_class(draft_year)
	for p in prospects:
		WorldState.register_player(p)
	WorldState.current_draft_class = prospects
	return prospects

# ---------------------------------------------------------------------------
# STEP 9 — Enforce cap compliance on all NBA teams
# ---------------------------------------------------------------------------

func _enforce_all_caps(nba_teams: Array, all_contracts: Array) -> void:
	var cap = WorldState.league_salary_caps.get("nba", 136000000)

	for team in nba_teams:
		# Filter contracts belonging to this team
		var team_contracts = all_contracts.filter(
			func(c): return c["team_id"] == team.id
		)

		var corrected = _contract_gen.enforce_cap_compliance(
			team, team_contracts, cap
		)

		# Write corrections back into all_contracts
		for corrected_contract in corrected:
			for i in range(all_contracts.size()):
				if all_contracts[i]["player_id"] == corrected_contract["player_id"]:
					all_contracts[i] = corrected_contract
					break

# ---------------------------------------------------------------------------
# STEP 10 — Recalculate salary totals on each team after compliance pass
# ---------------------------------------------------------------------------

func _recalculate_salary_totals(nba_teams: Array, all_contracts: Array) -> void:
	for team in nba_teams:
		var total = 0
		for contract in all_contracts:
			if contract["team_id"] != team.id:
				continue
			if contract.get("is_two_way", false):
				continue  # Two-ways don't count against cap
			var salaries = contract.get("salaries", [])
			if not salaries.is_empty():
				total += salaries[0]
		team.current_salary_total = total

# ---------------------------------------------------------------------------
# STEP 11 — Save contracts to DB in one batch transaction
# ---------------------------------------------------------------------------

func _save_contracts_batch(all_contracts: Array) -> void:
	Database.query("BEGIN TRANSACTION")
	for contract in all_contracts:
		Database.save_contract(
			contract["player_id"],
			contract["team_id"],
			contract["salaries"],
			contract.get("is_two_way", false),
			contract.get("is_rookie_scale", false),
			contract.get("team_option_year", 0),
			contract.get("player_option_year", 0),
			contract.get("bird_rights", "non"),
			contract.get("escalation_rate", 0.05)
		)
	Database.query("COMMIT")

# ---------------------------------------------------------------------------
# STEP 12 — Start tenure records for all rostered players
# Must run after players are saved to DB (they need real IDs)
# ---------------------------------------------------------------------------

func _start_all_tenures(all_players: Array, season: int) -> void:
	Database.query("BEGIN TRANSACTION")
	for player in all_players:
		if player.is_draft_prospect:
			continue  # Prospects don't have tenure yet
		if player.team_id == "" or player.team_id == "-1":
			continue  # Free agents skipped
		Database.start_tenure(
			player.id,
			player.team_id,
			player.league_id,
			season
		)
	Database.query("COMMIT")

# ---------------------------------------------------------------------------
# UTILITIES
# ---------------------------------------------------------------------------

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("LeagueLoader: file not found — %s" % path)
		return null
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("LeagueLoader: could not open — %s" % path)
		return null
	var text   = file.get_as_text()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		push_error("LeagueLoader: JSON parse error — %s" % path)
		return null
	return parsed

func _emit_progress(pct: float, message: String) -> void:
	load_progress.emit(pct, message)
	print("[LeagueLoader] %.0f%% — %s" % [pct * 100, message])
