extends Node

var db: SQLite

func _ready() -> void:
	db = SQLite.new()
	db.path = "user://basketball_manager.db"
	db.verbosity_level = SQLite.QUIET
	db.open_db()
	_create_schema()

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

func _create_schema() -> void:

	# Players — identity
	db.query("
		CREATE TABLE IF NOT EXISTS players (
			id                INTEGER PRIMARY KEY AUTOINCREMENT,
			first_name        TEXT,
			last_name         TEXT,
			age               INTEGER,
			position          TEXT,
			tier              TEXT DEFAULT 'ROTATION',
			team_id           TEXT,
			league_id         TEXT,
			nationality       TEXT,
			is_free_agent     INTEGER DEFAULT 0,
			is_draft_prospect INTEGER DEFAULT 0,
			draft_year        INTEGER,
			primary_skill     INTEGER DEFAULT -1,
			secondary_skill   INTEGER DEFAULT -1
		)
	")

	# Player attributes — all 53
	db.query("
		CREATE TABLE IF NOT EXISTS player_attributes (
			player_id                INTEGER PRIMARY KEY,
			close_shot               INTEGER DEFAULT 10,
			layup                    INTEGER DEFAULT 10,
			driving_dunk             INTEGER DEFAULT 10,
			standing_dunk            INTEGER DEFAULT 10,
			post_hook                INTEGER DEFAULT 10,
			post_fade                INTEGER DEFAULT 10,
			post_control             INTEGER DEFAULT 10,
			mid_range                INTEGER DEFAULT 10,
			three_point              INTEGER DEFAULT 10,
			free_throw               INTEGER DEFAULT 10,
			draw_foul                INTEGER DEFAULT 10,
			hands                    INTEGER DEFAULT 10,
			shot_iq                  INTEGER DEFAULT 10,
			ball_handling            INTEGER DEFAULT 10,
			speed_with_ball          INTEGER DEFAULT 10,
			pass_accuracy            INTEGER DEFAULT 10,
			pass_vision              INTEGER DEFAULT 10,
			pass_iq                  INTEGER DEFAULT 10,
			off_ball_movement        INTEGER DEFAULT 10,
			perimeter_defense        INTEGER DEFAULT 10,
			interior_defense         INTEGER DEFAULT 10,
			help_defense_iq          INTEGER DEFAULT 10,
			pass_perception          INTEGER DEFAULT 10,
			steal                    INTEGER DEFAULT 10,
			block                    INTEGER DEFAULT 10,
			defensive_iq             INTEGER DEFAULT 10,
			defensive_consistency    INTEGER DEFAULT 10,
			offensive_rebounding     INTEGER DEFAULT 10,
			defensive_rebounding     INTEGER DEFAULT 10,
			speed                    INTEGER DEFAULT 10,
			agility                  INTEGER DEFAULT 10,
			strength                 INTEGER DEFAULT 10,
			vertical                 INTEGER DEFAULT 10,
			stamina                  INTEGER DEFAULT 10,
			hustle                   INTEGER DEFAULT 10,
			overall_durability       INTEGER DEFAULT 10,
			anticipation             INTEGER DEFAULT 10,
			composure                INTEGER DEFAULT 10,
			concentration            INTEGER DEFAULT 10,
			decision_making          INTEGER DEFAULT 10,
			determination            INTEGER DEFAULT 10,
			flair                    INTEGER DEFAULT 10,
			leadership               INTEGER DEFAULT 10,
			teamwork                 INTEGER DEFAULT 10,
			work_ethic               INTEGER DEFAULT 10,
			coachability             INTEGER DEFAULT 8,
			consistency              INTEGER DEFAULT 8,
			natural_fitness          INTEGER DEFAULT 8,
			versatility              INTEGER DEFAULT 8,
			adaptability             INTEGER DEFAULT 8,
			injury_proneness         INTEGER DEFAULT 8,
			important_matches        INTEGER DEFAULT 8,
			potential                INTEGER DEFAULT 8,
			FOREIGN KEY (player_id) REFERENCES players(id)
		)
	")

	# Potential deltas
	db.query("
		CREATE TABLE IF NOT EXISTS potential_deltas (
			player_id  INTEGER,
			attribute  TEXT,
			delta      INTEGER DEFAULT 0,
			PRIMARY KEY (player_id, attribute),
			FOREIGN KEY (player_id) REFERENCES players(id)
		)
	")

	# Player tenure — one row per stint at a team
	# Tracks Bird rights eligibility and career history for UI
	db.query("
		CREATE TABLE IF NOT EXISTS player_tenure (
			id                   INTEGER PRIMARY KEY AUTOINCREMENT,
			player_id            INTEGER,
			team_id              TEXT,
			league_id            TEXT,
			season_start         INTEGER,
			season_end           INTEGER,
			games_played         INTEGER DEFAULT 0,
			games_started        INTEGER DEFAULT 0,
			consecutive_seasons  INTEGER DEFAULT 0,
			FOREIGN KEY (player_id) REFERENCES players(id)
		)
	")

	# Teams — persisted state (identity comes from JSON, runtime state saved here)
	db.query("
		CREATE TABLE IF NOT EXISTS teams (
			id                       TEXT PRIMARY KEY,
			full_name                TEXT,
			city                     TEXT,
			abbreviation             TEXT,
			conference               TEXT,
			division                 TEXT,
			arena                    TEXT,
			prestige                 INTEGER DEFAULT 50,
			market_size              TEXT DEFAULT 'medium',
			owner_name               TEXT,
			tax_willingness          REAL DEFAULT 0.5,
			spending_aggressiveness  REAL DEFAULT 0.5,
			patience                 REAL DEFAULT 0.5,
			ambition                 REAL DEFAULT 0.5,
			will_tank                INTEGER DEFAULT 0,
			roster_ids               TEXT DEFAULT '[]',
			two_way_ids              TEXT DEFAULT '[]',
			current_salary_total     INTEGER DEFAULT 0,
			trade_exceptions         TEXT DEFAULT '[]',
			bae_used_last_year       INTEGER DEFAULT 0,
			tax_seasons              TEXT DEFAULT '[]',
			wins                     INTEGER DEFAULT 0,
			losses                   INTEGER DEFAULT 0,
			home_wins                INTEGER DEFAULT 0,
			home_losses              INTEGER DEFAULT 0,
			away_wins                INTEGER DEFAULT 0,
			away_losses              INTEGER DEFAULT 0,
			streak                   INTEGER DEFAULT 0,
			points_for               REAL DEFAULT 0.0,
			points_against           REAL DEFAULT 0.0,
			conference_rank          INTEGER DEFAULT 0,
			division_rank            INTEGER DEFAULT 0,
			owned_picks              TEXT DEFAULT '[]',
			current_pressure         REAL DEFAULT 0.0,
			expectation_tier         TEXT DEFAULT 'playoff_team',
			consecutive_missed_seasons INTEGER DEFAULT 0
		)
	")

	# Contracts
	db.query("
		CREATE TABLE IF NOT EXISTS contracts (
			id                INTEGER PRIMARY KEY AUTOINCREMENT,
			player_id         INTEGER,
			team_id           TEXT,
			salary_year_1     INTEGER DEFAULT 0,
			salary_year_2     INTEGER DEFAULT 0,
			salary_year_3     INTEGER DEFAULT 0,
			salary_year_4     INTEGER DEFAULT 0,
			salary_year_5     INTEGER DEFAULT 0,
			total_years       INTEGER DEFAULT 1,
			years_remaining   INTEGER DEFAULT 1,
			is_two_way        INTEGER DEFAULT 0,
			is_rookie_scale   INTEGER DEFAULT 0,
			team_option_year  INTEGER DEFAULT 0,
			player_option_year INTEGER DEFAULT 0,
			bird_rights       TEXT DEFAULT 'non',
			escalation_rate   REAL DEFAULT 0.05,
			FOREIGN KEY (player_id) REFERENCES players(id),
			FOREIGN KEY (team_id)   REFERENCES teams(id)
		)
	")

	# Match results
	db.query("
		CREATE TABLE IF NOT EXISTS match_results (
			id           INTEGER PRIMARY KEY AUTOINCREMENT,
			home_team_id TEXT,
			away_team_id TEXT,
			home_score   INTEGER,
			away_score   INTEGER,
			date_day     INTEGER,
			date_month   INTEGER,
			date_year    INTEGER,
			league_id    TEXT,
			simulated    INTEGER DEFAULT 1
		)
	")

	# Coach
	db.query("
		CREATE TABLE IF NOT EXISTS coach (
			id                INTEGER PRIMARY KEY,
			first_name        TEXT,
			last_name         TEXT,
			age               INTEGER,
			reputation        REAL DEFAULT 20.0,
			specialty         TEXT,
			current_team_id   TEXT,
			seasons_coached   INTEGER DEFAULT 0,
			career_wins       INTEGER DEFAULT 0,
			career_losses     INTEGER DEFAULT 0,
			championships     INTEGER DEFAULT 0
		)
	")

	print("Database schema ready.")

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

func query(sql: String) -> Array:
	db.query(sql)
	return db.query_result

func query_with_bindings(sql: String, bindings: Array) -> Array:
	db.query_with_bindings(sql, bindings)
	return db.query_result

func close() -> void:
	db.close_db()

# ---------------------------------------------------------------------------
# PLAYER — save
# ---------------------------------------------------------------------------

func save_player(player: Player) -> int:
	db.query_with_bindings("
		INSERT INTO players (
			first_name, last_name, age, position, tier,
			team_id, league_id, nationality,
			is_free_agent, is_draft_prospect, draft_year,
			primary_skill, secondary_skill
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	", [
		player.first_name, player.last_name, player.age,
		player.get_position_string(), player.get_tier_string(),
		player.team_id, player.league_id, player.nationality,
		1 if player.is_free_agent    else 0,
		1 if player.is_draft_prospect else 0,
		player.draft_year,
		player.get_meta("primary_skill",   -1),
		player.get_meta("secondary_skill", -1)
	])

	var id_result = query("SELECT last_insert_rowid() AS id")
	var new_id    = id_result[0]["id"] if id_result.size() > 0 else -1
	player.id     = new_id

	# Build attribute INSERT dynamically from ALL_ATTR_NAMES
	var attr_names   = Player.ALL_ATTR_NAMES
	var attr_vals    = []
	var placeholders = []
	for attr in attr_names:
		attr_vals.append(player.get(attr))
		placeholders.append("?")

	var cols_sql = "player_id, " + ", ".join(attr_names)
	var vals_sql = "?, "         + ", ".join(placeholders)
	db.query_with_bindings(
		"INSERT INTO player_attributes (%s) VALUES (%s)" % [cols_sql, vals_sql],
		[new_id] + attr_vals
	)

	# Potential deltas
	for attr in player.potential_deltas:
		db.query_with_bindings(
			"INSERT INTO potential_deltas (player_id, attribute, delta) VALUES (?, ?, ?)",
			[new_id, attr, player.potential_deltas[attr]]
		)

	return new_id

func save_players_batch(players: Array) -> Array:
	var ids: Array = []
	db.query("BEGIN TRANSACTION")
	for player in players:
		ids.append(save_player(player))
	db.query("COMMIT")
	return ids

# ---------------------------------------------------------------------------
# PLAYER — load
# ---------------------------------------------------------------------------

func load_player(player_id: int) -> Player:
	var player_rows = query_with_bindings(
		"SELECT * FROM players WHERE id = ?", [player_id]
	)
	if player_rows.is_empty():
		return null

	var attr_rows = query_with_bindings(
		"SELECT * FROM player_attributes WHERE player_id = ?", [player_id]
	)
	if attr_rows.is_empty():
		return null

	var p = Player.new()
	p.from_dict(player_rows[0], attr_rows[0])
	p.set_meta("primary_skill",   player_rows[0].get("primary_skill",   -1))
	p.set_meta("secondary_skill", player_rows[0].get("secondary_skill", -1))

	var delta_rows = query_with_bindings(
		"SELECT attribute, delta FROM potential_deltas WHERE player_id = ?", [player_id]
	)
	for row in delta_rows:
		p.potential_deltas[row["attribute"]] = row["delta"]

	return p

func load_team_players(team_id: String) -> Array:
	var id_rows = query_with_bindings(
		"SELECT id FROM players WHERE team_id = ? AND is_free_agent = 0", [team_id]
	)
	var players: Array = []
	for row in id_rows:
		var p = load_player(row["id"])
		if p:
			players.append(p)
	return players

func load_free_agents(league_id: String = "") -> Array:
	var rows: Array = []
	if league_id.is_empty():
		rows = query("SELECT id FROM players WHERE is_free_agent = 1")
	else:
		rows = query_with_bindings(
			"SELECT id FROM players WHERE is_free_agent = 1 AND league_id = ?",
			[league_id]
		)
	var players: Array = []
	for row in rows:
		var p = load_player(row["id"])
		if p:
			players.append(p)
	return players

func load_draft_class(year: int) -> Array:
	var rows = query_with_bindings(
		"SELECT id FROM players WHERE is_draft_prospect = 1 AND draft_year = ?", [year]
	)
	var players: Array = []
	for row in rows:
		var p = load_player(row["id"])
		if p:
			players.append(p)
	return players

# ---------------------------------------------------------------------------
# PLAYER — update
# ---------------------------------------------------------------------------

func update_player_attribute(player_id: int, attr: String, value: int) -> void:
	if attr not in Player.ALL_ATTR_NAMES:
		push_error("Database: unknown attribute '%s'" % attr)
		return
	db.query_with_bindings(
		"UPDATE player_attributes SET %s = ? WHERE player_id = ?" % attr,
		[value, player_id]
	)

func update_potential_delta(player_id: int, attr: String, delta: int) -> void:
	db.query_with_bindings("
		INSERT OR REPLACE INTO potential_deltas (player_id, attribute, delta)
		VALUES (?, ?, ?)
	", [player_id, attr, delta])

func transfer_player(player_id: int, new_team_id: String, new_league_id: String) -> void:
	db.query_with_bindings("
		UPDATE players SET team_id = ?, league_id = ?, is_free_agent = 0
		WHERE id = ?
	", [new_team_id, new_league_id, player_id])

func release_player(player_id: int) -> void:
	db.query_with_bindings(
		"UPDATE players SET team_id = '', is_free_agent = 1 WHERE id = ?",
		[player_id]
	)

# ---------------------------------------------------------------------------
# PLAYER TENURE
# ---------------------------------------------------------------------------

func start_tenure(player_id: int, team_id: String,
				  league_id: String, season: int) -> void:
	# Close any open tenure first
	db.query_with_bindings("
		UPDATE player_tenure SET season_end = ?
		WHERE player_id = ? AND season_end IS NULL
	", [season - 1, player_id])

	# Get consecutive seasons from previous stint at same team
	var prev = query_with_bindings("
		SELECT consecutive_seasons FROM player_tenure
		WHERE player_id = ? AND team_id = ?
		ORDER BY season_end DESC LIMIT 1
	", [player_id, team_id])

	var consecutive = 0
	if not prev.is_empty() and prev[0].get("season_end") == season - 1:
		# Was here last season — increment
		consecutive = prev[0].get("consecutive_seasons", 0) + 1
	else:
		consecutive = 1

	db.query_with_bindings("
		INSERT INTO player_tenure
			(player_id, team_id, league_id, season_start, consecutive_seasons)
		VALUES (?, ?, ?, ?, ?)
	", [player_id, team_id, league_id, season, consecutive])

func end_tenure(player_id: int, season: int) -> void:
	db.query_with_bindings("
		UPDATE player_tenure SET season_end = ?
		WHERE player_id = ? AND season_end IS NULL
	", [season, player_id])

func update_tenure_games(player_id: int, team_id: String,
						 season: int, played: bool, started: bool) -> void:
	var played_inc = 1 if played else 0
	var started_inc = 1 if started else 0
	db.query_with_bindings("
		UPDATE player_tenure
		SET games_played  = games_played  + ?,
		    games_started = games_started + ?
		WHERE player_id = ? AND team_id = ? AND season_start = ?
		  AND season_end IS NULL
	", [played_inc, started_inc, player_id, team_id, season])

func get_consecutive_seasons(player_id: int, team_id: String) -> int:
	# Used by Team.get_bird_rights()
	var rows = query_with_bindings("
		SELECT consecutive_seasons FROM player_tenure
		WHERE player_id = ? AND team_id = ? AND season_end IS NULL
		LIMIT 1
	", [player_id, team_id])
	if rows.is_empty():
		return 0
	return rows[0].get("consecutive_seasons", 0)

func get_player_career_history(player_id: int) -> Array:
	# Returns full career timeline for player history UI
	return query_with_bindings("
		SELECT pt.*, t.full_name as team_name, t.abbreviation
		FROM player_tenure pt
		LEFT JOIN teams t ON pt.team_id = t.id
		WHERE pt.player_id = ?
		ORDER BY pt.season_start ASC
	", [player_id])

func get_years_in_league(player_id: int) -> int:
	# Total seasons in any league — used for veteran minimum tier
	var rows = query_with_bindings("
		SELECT COUNT(DISTINCT season_start) as seasons
		FROM player_tenure
		WHERE player_id = ? AND league_id = 'nba'
	", [player_id])
	if rows.is_empty():
		return 0
	return rows[0].get("seasons", 0)

# ---------------------------------------------------------------------------
# TEAM — save and load
# ---------------------------------------------------------------------------

func save_team(team: Team) -> void:
	var d = team.to_dict()
	db.query_with_bindings("
		INSERT OR REPLACE INTO teams (
			id, full_name, city, abbreviation, conference, division, arena,
			prestige, market_size, owner_name,
			tax_willingness, spending_aggressiveness, patience, ambition, will_tank,
			roster_ids, two_way_ids, current_salary_total,
			trade_exceptions, bae_used_last_year, tax_seasons,
			wins, losses, home_wins, home_losses, away_wins, away_losses,
			streak, points_for, points_against, conference_rank, division_rank,
			owned_picks, current_pressure, expectation_tier, consecutive_missed_seasons
		) VALUES (
			?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
			?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
			?, ?, ?, ?, ?, ?
		)
	", [
		d["id"], d["full_name"], d["city"], d["abbreviation"],
		d["conference"], d["division"], d["arena"],
		d["prestige"], d["market_size"], d["owner_name"],
		d["tax_willingness"], d["spending_aggressiveness"],
		d["patience"], d["ambition"], d["will_tank"],
		d["roster_ids"], d["two_way_ids"], d["current_salary_total"],
		d["trade_exceptions"], d["bae_used_last_year"], d["tax_seasons"],
		d["wins"], d["losses"], d["home_wins"], d["home_losses"],
		d["away_wins"], d["away_losses"], d["streak"],
		d["points_for"], d["points_against"],
		d["conference_rank"], d["division_rank"],
		d["owned_picks"], d["current_pressure"],
		d["expectation_tier"], d["consecutive_missed_seasons"]
	])

func load_team(team_id: String) -> Team:
	var rows = query_with_bindings(
		"SELECT * FROM teams WHERE id = ?", [team_id]
	)
	if rows.is_empty():
		return null
	var t = Team.new()
	t.from_dict(rows[0])
	return t

func load_all_teams() -> Array:
	var rows = query("SELECT id FROM teams")
	var teams: Array = []
	for row in rows:
		var t = load_team(row["id"])
		if t:
			teams.append(t)
	return teams

func save_teams_batch(teams: Array) -> void:
	db.query("BEGIN TRANSACTION")
	for team in teams:
		save_team(team)
	db.query("COMMIT")

func update_team_standings(team_id: String, won: bool, home: bool,
						   scored: int, conceded: int) -> void:
	var win_inc  = 1 if won  else 0
	var loss_inc = 0 if won  else 1

	if home:
		db.query_with_bindings("
			UPDATE teams SET
				wins         = wins + ?,
				losses       = losses + ?,
				home_wins    = home_wins + ?,
				home_losses  = home_losses + ?,
				points_for   = points_for + ?,
				points_against = points_against + ?
			WHERE id = ?
		", [win_inc, loss_inc, win_inc, loss_inc, scored, conceded, team_id])
	else:
		db.query_with_bindings("
			UPDATE teams SET
				wins         = wins + ?,
				losses       = losses + ?,
				away_wins    = away_wins + ?,
				away_losses  = away_losses + ?,
				points_for   = points_for + ?,
				points_against = points_against + ?
			WHERE id = ?
		", [win_inc, loss_inc, win_inc, loss_inc, scored, conceded, team_id])

# ---------------------------------------------------------------------------
# CONTRACTS
# ---------------------------------------------------------------------------

func save_contract(player_id: int, team_id: String,
				   salaries: Array, is_two_way: bool,
				   is_rookie_scale: bool, team_option_year: int,
				   player_option_year: int, bird_rights: String,
				   escalation_rate: float) -> void:

	# Pad salaries array to 5 years
	while salaries.size() < 5:
		salaries.append(0)

	db.query_with_bindings("
		INSERT INTO contracts (
			player_id, team_id,
			salary_year_1, salary_year_2, salary_year_3,
			salary_year_4, salary_year_5,
			total_years, years_remaining,
			is_two_way, is_rookie_scale,
			team_option_year, player_option_year,
			bird_rights, escalation_rate
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	", [
		player_id, team_id,
		salaries[0], salaries[1], salaries[2], salaries[3], salaries[4],
		salaries.size(), salaries.size(),
		1 if is_two_way       else 0,
		1 if is_rookie_scale  else 0,
		team_option_year, player_option_year,
		bird_rights, escalation_rate
	])

func get_contract(player_id: int) -> Dictionary:
	var rows = query_with_bindings(
		"SELECT * FROM contracts WHERE player_id = ? AND years_remaining > 0 LIMIT 1",
		[player_id]
	)
	if rows.is_empty():
		return {}
	return rows[0]

func advance_contracts_one_year(team_id: String) -> void:
	# Called each offseason — reduces years_remaining and expires old deals
	db.query_with_bindings("
		UPDATE contracts SET years_remaining = years_remaining - 1
		WHERE team_id = ? AND years_remaining > 0
	", [team_id])
	db.query_with_bindings("
		DELETE FROM contracts WHERE team_id = ? AND years_remaining <= 0
	", [team_id])
