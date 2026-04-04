extends Node

var db: SQLite

func _ready() -> void:
	db = SQLite.new()
	db.path = "user://basketball_manager.db"
	db.verbosity_level = SQLite.QUIET
	db.open_db()
	_create_schema()

func _create_schema() -> void:
	# Players table
	db.query("
        CREATE TABLE IF NOT EXISTS players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            first_name TEXT,
            last_name TEXT,
            age INTEGER,
            position TEXT,
            team_id INTEGER,
            league_id TEXT,
            nationality TEXT,
            is_free_agent INTEGER DEFAULT 0,
            is_draft_prospect INTEGER DEFAULT 0,
            draft_year INTEGER
        )
	")

	# Player attributes table (separate for performance)
	db.query("
        CREATE TABLE IF NOT EXISTS player_attributes (
            player_id INTEGER PRIMARY KEY,
            inside_scoring INTEGER,
            mid_range INTEGER,
            three_point INTEGER,
            free_throw INTEGER,
            shot_creation INTEGER,
            off_ball_movement INTEGER,
            passing_vision INTEGER,
            pass_accuracy INTEGER,
            ball_handling INTEGER,
            decision_making INTEGER,
            pick_and_roll_iq INTEGER,
            perimeter_defense INTEGER,
            interior_defense INTEGER,
            help_defense INTEGER,
            stealing INTEGER,
            blocking INTEGER,
            defensive_iq INTEGER,
            offensive_rebounding INTEGER,
            defensive_rebounding INTEGER,
            speed INTEGER,
            quickness INTEGER,
            strength INTEGER,
            vertical INTEGER,
            stamina INTEGER,
            injury_resistance INTEGER,
            basketball_iq INTEGER,
            composure INTEGER,
            work_ethic INTEGER,
            leadership INTEGER,
            coachability INTEGER,
            consistency INTEGER,
            potential INTEGER,
            FOREIGN KEY (player_id) REFERENCES players(id)
        )
	")

	# Teams table
	db.query("
        CREATE TABLE IF NOT EXISTS teams (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            city TEXT,
            abbreviation TEXT,
            league_id TEXT,
            prestige INTEGER DEFAULT 50,
            budget INTEGER DEFAULT 0,
            salary_total INTEGER DEFAULT 0,
            wins INTEGER DEFAULT 0,
            losses INTEGER DEFAULT 0,
            is_player_team INTEGER DEFAULT 0
        )
	")

	# Contracts table
	db.query("
        CREATE TABLE IF NOT EXISTS contracts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            player_id INTEGER,
            team_id INTEGER,
            salary INTEGER,
            years_remaining INTEGER,
            is_two_way INTEGER DEFAULT 0,
            FOREIGN KEY (player_id) REFERENCES players(id),
            FOREIGN KEY (team_id) REFERENCES teams(id)
        )
	")

	# Match results table
	db.query("
        CREATE TABLE IF NOT EXISTS match_results (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            home_team_id INTEGER,
            away_team_id INTEGER,
            home_score INTEGER,
            away_score INTEGER,
            date_day INTEGER,
            date_month INTEGER,
            date_year INTEGER,
            league_id TEXT,
            simulated INTEGER DEFAULT 1
        )
	")

	# Coach table (the player)
	db.query("
        CREATE TABLE IF NOT EXISTS coach (
            id INTEGER PRIMARY KEY,
            first_name TEXT,
            last_name TEXT,
            age INTEGER,
            reputation REAL DEFAULT 20.0,
            specialty TEXT,
            current_team_id INTEGER,
            seasons_coached INTEGER DEFAULT 0,
            career_wins INTEGER DEFAULT 0,
            career_losses INTEGER DEFAULT 0,
            championships INTEGER DEFAULT 0
        )
	")

	print("Database schema ready.")

func query(sql: String) -> Array:
	db.query(sql)
	return db.query_result

func query_with_bindings(sql: String, bindings: Array) -> Array:
	db.query_with_bindings(sql, bindings)
	return db.query_result

func close() -> void:
	db.close_db()
