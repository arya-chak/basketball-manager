class_name Team
extends RefCounted

# ---------------------------------------------------------------------------
# Identity — set at game start from nba_teams.json, static
# ---------------------------------------------------------------------------

var id: String = ""              # Abbreviation e.g. "BOS"
var full_name: String = ""
var city: String = ""
var abbreviation: String = ""
var conference: String = ""      # "East" or "West"
var division: String = ""        # "Atlantic", "Central" etc
var arena: String = ""
var prestige: int = 50           # 1-100, affects FA attraction and scouting
var market_size: String = ""     # "small", "medium", "large"

# ---------------------------------------------------------------------------
# Owner — mostly static, can change on ownership event
# ---------------------------------------------------------------------------

var owner_name: String = ""
var tax_willingness: float = 0.5         # 0.0-1.0
var spending_aggressiveness: float = 0.5 # 0.0-1.0
var patience: float = 0.5                # 0.0-1.0 — affects firing threshold
var ambition: float = 0.5                # 0.0-1.0 — affects expectation tier
var will_tank: bool = false

# ---------------------------------------------------------------------------
# Roster — player IDs only, full Player objects live in WorldState.all_players
# ---------------------------------------------------------------------------

var roster_ids: Array = []       # NBA roster, max 15
var two_way_ids: Array = []      # Two-way contracts, max 2

# ---------------------------------------------------------------------------
# Financials
# ---------------------------------------------------------------------------

var current_salary_total: int = 0
var trade_exceptions: Array = [] # [{amount: int, expiry_year: int, pick_id: String}]
var bae_used_last_year: bool = false
var tax_seasons: Array = []      # List of years the team paid luxury tax

# ---------------------------------------------------------------------------
# Standings
# ---------------------------------------------------------------------------

var wins: int = 0
var losses: int = 0
var home_wins: int = 0
var home_losses: int = 0
var away_wins: int = 0
var away_losses: int = 0
var streak: int = 0              # Positive = win streak, negative = losing streak
var points_for: float = 0.0
var points_against: float = 0.0
var conference_rank: int = 0
var division_rank: int = 0

# ---------------------------------------------------------------------------
# Draft picks owned
# Each pick: {
#   id: String            e.g. "BOS_2027_R1"
#   year: int
#   round: int            1 or 2
#   original_team_id: String
#   current_owner_id: String
#   protection_schedule: Array of {year, type, threshold, range_start, range_end}
#   if_triggers: String   "roll", "convert_to_second", "unprotected", "revert"
#   max_rolls: int
#   rolls_used: int
#   fallback: String
# }
# ---------------------------------------------------------------------------

var owned_picks: Array = []

# ---------------------------------------------------------------------------
# Coaching pressure system
# ---------------------------------------------------------------------------

var current_pressure: float = 0.0
var expectation_tier: String = "playoff_team"
var consecutive_missed_seasons: int = 0

# ---------------------------------------------------------------------------
# Identity helpers
# ---------------------------------------------------------------------------

func get_display_name() -> String:
	return full_name

func get_short_name() -> String:
	return "%s %s" % [city, abbreviation]

# ---------------------------------------------------------------------------
# CAP HELPERS
# All cap figures read from WorldState which holds the current year's cap
# ---------------------------------------------------------------------------

func _get_current_cap() -> int:
	return WorldState.current_salary_cap

func _get_tax_threshold() -> int:
	# Tax threshold = cap * 1.10
	return roundi(_get_current_cap() * 1.10)

func _get_first_apron() -> int:
	# First apron = tax threshold * 1.053
	return roundi(_get_tax_threshold() * 1.053)

func _get_second_apron() -> int:
	# Second apron = tax threshold * 1.105
	return roundi(_get_tax_threshold() * 1.105)

func get_cap_space() -> int:
	return maxi(0, _get_current_cap() - current_salary_total)

func get_tax_space() -> int:
	return maxi(0, _get_tax_threshold() - current_salary_total)

func is_over_cap() -> bool:
	return current_salary_total > _get_current_cap()

func is_over_tax() -> bool:
	return current_salary_total > _get_tax_threshold()

func is_over_first_apron() -> bool:
	return current_salary_total > _get_first_apron()

func is_over_second_apron() -> bool:
	return current_salary_total > _get_second_apron()

func is_repeater() -> bool:
	# Repeater = paid tax in 3 of previous 4 seasons
	var current_year = WorldState.current_season
	var lookback = [current_year - 1, current_year - 2,
					current_year - 3, current_year - 4]
	var tax_count = 0
	for year in lookback:
		if year in tax_seasons:
			tax_count += 1
	return tax_count >= 3

func get_luxury_tax_bill() -> int:
	if not is_over_tax():
		return 0

	var overage = current_salary_total - _get_tax_threshold()
	var tax_bill = 0
	var repeater = is_repeater()

	# Tax brackets from nba_cap_rules.json
	# Stored here for runtime use — loaded once via LeagueLoader
	var brackets = [
		{ "end": 5000000,   "rate": 1.50 },
		{ "end": 10000000,  "rate": 1.75 },
		{ "end": 15000000,  "rate": 2.50 },
		{ "end": 20000000,  "rate": 3.25 },
		{ "end": 25000000,  "rate": 3.75 },
		{ "end": 999000000, "rate": 4.25 }
	]

	var remaining = overage
	var bracket_start = 0

	for bracket in brackets:
		if remaining <= 0:
			break
		var bracket_size = bracket["end"] - bracket_start
		var taxable = mini(remaining, bracket_size)
		var rate = bracket["rate"]
		if repeater:
			rate += 1.00  # Repeater surcharge
		tax_bill += roundi(taxable * rate)
		remaining -= taxable
		bracket_start = bracket["end"]

	return tax_bill

# ---------------------------------------------------------------------------
# EXCEPTION HELPERS
# ---------------------------------------------------------------------------

func get_available_exceptions() -> Array:
	var exceptions: Array = []

	if not is_over_cap():
		return exceptions  # Under cap teams just sign freely

	if not is_over_first_apron():
		# Full MLE available to teams over cap but under first apron
		exceptions.append({
			"type": "full_mle",
			"amount": get_full_mle(),
			"max_years": 4
		})

	elif not is_over_second_apron():
		# Tax MLE for teams between first and second apron
		exceptions.append({
			"type": "tax_mle",
			"amount": get_tax_mle(),
			"max_years": 3
		})

	# BAE — available if not used last year and not over first apron
	if not bae_used_last_year and not is_over_first_apron():
		exceptions.append({
			"type": "bae",
			"amount": get_bae(),
			"max_years": 2
		})

	# Trade exceptions
	var current_year = WorldState.current_season
	for te in trade_exceptions:
		if te["expiry_year"] >= current_year:
			exceptions.append({
				"type": "trade_exception",
				"amount": te["amount"],
				"max_years": 1,
				"expiry_year": te["expiry_year"]
			})

	return exceptions

func get_full_mle() -> int:
	return roundi(_get_current_cap() * 0.090)

func get_tax_mle() -> int:
	return roundi(_get_current_cap() * 0.050)

func get_bae() -> int:
	return roundi(_get_current_cap() * 0.030)

func get_veteran_minimum(experience_years: int) -> int:
	if experience_years <= 2:
		return roundi(_get_current_cap() * 0.018)
	elif experience_years <= 6:
		return roundi(_get_current_cap() * 0.028)
	else:
		return roundi(_get_current_cap() * 0.038)

func get_max_contract_value(experience_years: int) -> int:
	if experience_years <= 5:
		return roundi(_get_current_cap() * 0.25)
	elif experience_years <= 9:
		return roundi(_get_current_cap() * 0.30)
	else:
		return roundi(_get_current_cap() * 0.35)

# ---------------------------------------------------------------------------
# ROSTER HELPERS
# ---------------------------------------------------------------------------

func get_roster_size() -> int:
	return roster_ids.size()

func has_roster_space() -> bool:
	return roster_ids.size() < 15

func has_two_way_space() -> bool:
	return two_way_ids.size() < 2

func get_bird_rights(player_id: int) -> String:
	# Queries player_tenure via Database to get consecutive seasons
	var consecutive = Database.get_consecutive_seasons(player_id, id)
	if consecutive >= 3:
		return "full"
	elif consecutive >= 2:
		return "early"
	else:
		return "non"

func add_player(player_id: int, is_two_way: bool = false) -> void:
	if is_two_way:
		if has_two_way_space():
			two_way_ids.append(player_id)
	else:
		if has_roster_space():
			roster_ids.append(player_id)
	EventBus.roster_changed.emit(id)

func remove_player(player_id: int) -> void:
	roster_ids.erase(player_id)
	two_way_ids.erase(player_id)
	EventBus.roster_changed.emit(id)

func get_salary_for_player(player_id: int) -> int:
	var result = Database.query_with_bindings(
		"SELECT salary FROM contracts WHERE player_id = ? AND team_id = ?",
		[player_id, id]
	)
	if result.is_empty():
		return 0
	return result[0].get("salary", 0)

# ---------------------------------------------------------------------------
# DRAFT PICK HELPERS
# ---------------------------------------------------------------------------

func get_picks_by_year(year: int) -> Array:
	var result: Array = []
	for pick in owned_picks:
		if pick["year"] == year:
			result.append(pick)
	return result

func get_pick_by_id(pick_id: String) -> Dictionary:
	for pick in owned_picks:
		if pick["id"] == pick_id:
			return pick
	return {}

func will_pick_convey(pick: Dictionary, lottery_position: int) -> bool:
	# Find this year's protection from the schedule
	var current_year = WorldState.current_season
	var protection = _get_current_protection(pick, current_year)

	if protection["type"] == "unprotected":
		return true

	elif protection["type"] == "top_n":
		# Conveys only if pick falls outside the top N
		return lottery_position > protection["threshold"]

	elif protection["type"] == "range":
		# Conveys only if pick falls outside the protected range
		return lottery_position < protection["range_start"] \
			or lottery_position > protection["range_end"]

	elif protection["type"] == "lottery":
		# Conveys only if team makes playoffs (not in lottery)
		return lottery_position == -1  # -1 = not in lottery = playoff team

	return true  # Default to conveying if unknown type

func _get_current_protection(pick: Dictionary, year: int) -> Dictionary:
	var schedule = pick.get("protection_schedule", [])
	for entry in schedule:
		if entry["year"] == year:
			return entry
	# If no entry for this year, check if fully unprotected
	return { "type": "unprotected", "threshold": 0 }

func advance_pick_protection(pick: Dictionary) -> Dictionary:
	# Called when a pick's protection triggers — roll it forward
	pick["rolls_used"] += 1
	pick["year"] += 1

	if pick["rolls_used"] >= pick["max_rolls"]:
		# Max rolls reached — apply fallback
		var fallback = pick.get("fallback", "unprotected")
		match fallback:
			"convert_to_second":
				pick["round"] = 2
				pick["protection_schedule"] = []
				# Update pick ID to reflect round change
				pick["id"] = "%s_%d_R2" % [pick["original_team_id"], pick["year"]]
			"unprotected":
				pick["protection_schedule"] = [{
					"year": pick["year"],
					"type": "unprotected",
					"threshold": 0
				}]
			"revert":
				# Pick returns to original team
				owned_picks.erase(pick)
				var original_team = WorldState.get_team_by_id(pick["original_team_id"])
				if original_team:
					original_team.owned_picks.append(pick)

	return pick

func generate_pick_id(year: int, round: int) -> String:
	return "%s_%d_R%d" % [id, year, round]

func create_unprotected_pick(year: int, round: int) -> Dictionary:
	return {
		"id": generate_pick_id(year, round),
		"year": year,
		"round": round,
		"original_team_id": id,
		"current_owner_id": id,
		"protection_schedule": [
			{ "year": year, "type": "unprotected", "threshold": 0,
			  "range_start": 0, "range_end": 0 }
		],
		"if_triggers": "roll",
		"max_rolls": 0,
		"rolls_used": 0,
		"fallback": "unprotected"
	}

# ---------------------------------------------------------------------------
# STANDINGS HELPERS
# ---------------------------------------------------------------------------

func get_record_string() -> String:
	return "%d-%d" % [wins, losses]

func get_win_pct() -> float:
	var total = wins + losses
	if total == 0:
		return 0.0
	return float(wins) / float(total)

func get_last_10_string(recent_results: Array) -> String:
	# recent_results = last 10 match outcomes as bools (true = win)
	var w = 0
	for result in recent_results:
		if result:
			w += 1
	return "%d-%d" % [w, 10 - w]

func get_streak_string() -> String:
	if streak > 0:
		return "W%d" % streak
	elif streak < 0:
		return "L%d" % absi(streak)
	return "-"

func get_point_differential() -> float:
	var total = wins + losses
	if total == 0:
		return 0.0
	return (points_for - points_against) / float(total)

func update_record(won: bool, home: bool, scored: int, conceded: int) -> void:
	if won:
		wins += 1
		streak = maxi(1, streak + 1) if streak > 0 else 1
		if home:
			home_wins += 1
		else:
			away_wins += 1
	else:
		losses += 1
		streak = mini(-1, streak - 1) if streak < 0 else -1
		if home:
			home_losses += 1
		else:
			away_losses += 1

	points_for += scored
	points_against += conceded

func reset_standings() -> void:
	wins = 0
	losses = 0
	home_wins = 0
	home_losses = 0
	away_wins = 0
	away_losses = 0
	streak = 0
	points_for = 0.0
	points_against = 0.0

# ---------------------------------------------------------------------------
# COACHING PRESSURE HELPERS
# ---------------------------------------------------------------------------

func get_firing_threshold() -> int:
	# base 8 + patience modifier (0-8 range)
	return 8 + roundi(patience * 8)

func add_pressure(amount: float) -> void:
	current_pressure += amount
	if current_pressure >= get_firing_threshold():
		EventBus.coach_fired.emit(id)

func relieve_pressure(amount: float) -> void:
	current_pressure = maxf(0.0, current_pressure - amount)

func apply_season_verdict(verdict: String, won_championship: bool,
						  reached_finals: bool) -> void:
	if won_championship:
		current_pressure = 0.0
		consecutive_missed_seasons = 0
		return

	if reached_finals:
		current_pressure = floorf(current_pressure / 2.0)
		consecutive_missed_seasons = 0
		return

	match verdict:
		"overachieve":
			relieve_pressure(3.0)
			consecutive_missed_seasons = 0
		"meet":
			relieve_pressure(1.0)
			consecutive_missed_seasons = 0
		"underachieve_slight":
			add_pressure(2.0)
			consecutive_missed_seasons += 1
		"underachieve_significant":
			add_pressure(4.0)
			consecutive_missed_seasons += 1
		"catastrophic":
			add_pressure(7.0)
			consecutive_missed_seasons += 1

func get_expectation_tier_index() -> int:
	# Used for tier shifting by owner ambition modifier
	var tiers = ["tank", "development", "play_in",
				 "playoff_team", "deep_run", "title_contender"]
	return tiers.find(expectation_tier)

func set_expectation_tier_by_index(index: int) -> void:
	var tiers = ["tank", "development", "play_in",
				 "playoff_team", "deep_run", "title_contender"]
	index = clampi(index, 0, tiers.size() - 1)
	expectation_tier = tiers[index]

# ---------------------------------------------------------------------------
# TRADE EXCEPTION HELPERS
# ---------------------------------------------------------------------------

func add_trade_exception(amount: int, current_year: int) -> void:
	trade_exceptions.append({
		"amount": amount,
		"expiry_year": current_year + 1  # One-year expiry
	})

func purge_expired_exceptions(current_year: int) -> void:
	trade_exceptions = trade_exceptions.filter(
		func(te): return te["expiry_year"] >= current_year
	)

# ---------------------------------------------------------------------------
# SERIALIZATION
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"id":                      id,
		"full_name":               full_name,
		"city":                    city,
		"abbreviation":            abbreviation,
		"conference":              conference,
		"division":                division,
		"arena":                   arena,
		"prestige":                prestige,
		"market_size":             market_size,
		"owner_name":              owner_name,
		"tax_willingness":         tax_willingness,
		"spending_aggressiveness": spending_aggressiveness,
		"patience":                patience,
		"ambition":                ambition,
		"will_tank":               1 if will_tank else 0,
		"roster_ids":              JSON.stringify(roster_ids),
		"two_way_ids":             JSON.stringify(two_way_ids),
		"current_salary_total":    current_salary_total,
		"trade_exceptions":        JSON.stringify(trade_exceptions),
		"bae_used_last_year":      1 if bae_used_last_year else 0,
		"tax_seasons":             JSON.stringify(tax_seasons),
		"wins":                    wins,
		"losses":                  losses,
		"home_wins":               home_wins,
		"home_losses":             home_losses,
		"away_wins":               away_wins,
		"away_losses":             away_losses,
		"streak":                  streak,
		"points_for":              points_for,
		"points_against":          points_against,
		"conference_rank":         conference_rank,
		"division_rank":           division_rank,
		"owned_picks":             JSON.stringify(owned_picks),
		"current_pressure":        current_pressure,
		"expectation_tier":        expectation_tier,
		"consecutive_missed_seasons": consecutive_missed_seasons
	}

func from_dict(data: Dictionary) -> void:
	id                      = data.get("id", "")
	full_name               = data.get("full_name", "")
	city                    = data.get("city", "")
	abbreviation            = data.get("abbreviation", "")
	conference              = data.get("conference", "")
	division                = data.get("division", "")
	arena                   = data.get("arena", "")
	prestige                = data.get("prestige", 50)
	market_size             = data.get("market_size", "medium")
	owner_name              = data.get("owner_name", "")
	tax_willingness         = data.get("tax_willingness", 0.5)
	spending_aggressiveness = data.get("spending_aggressiveness", 0.5)
	patience                = data.get("patience", 0.5)
	ambition                = data.get("ambition", 0.5)
	will_tank               = data.get("will_tank", 0) == 1
	current_salary_total    = data.get("current_salary_total", 0)
	bae_used_last_year      = data.get("bae_used_last_year", 0) == 1
	wins                    = data.get("wins", 0)
	losses                  = data.get("losses", 0)
	home_wins               = data.get("home_wins", 0)
	home_losses             = data.get("home_losses", 0)
	away_wins               = data.get("away_wins", 0)
	away_losses             = data.get("away_losses", 0)
	streak                  = data.get("streak", 0)
	points_for              = data.get("points_for", 0.0)
	points_against          = data.get("points_against", 0.0)
	conference_rank         = data.get("conference_rank", 0)
	division_rank           = data.get("division_rank", 0)
	current_pressure        = data.get("current_pressure", 0.0)
	expectation_tier        = data.get("expectation_tier", "playoff_team")
	consecutive_missed_seasons = data.get("consecutive_missed_seasons", 0)

	# Parse JSON-serialized arrays
	roster_ids       = JSON.parse_string(data.get("roster_ids", "[]"))
	two_way_ids      = JSON.parse_string(data.get("two_way_ids", "[]"))
	trade_exceptions = JSON.parse_string(data.get("trade_exceptions", "[]"))
	tax_seasons      = JSON.parse_string(data.get("tax_seasons", "[]"))
	owned_picks      = JSON.parse_string(data.get("owned_picks", "[]"))
