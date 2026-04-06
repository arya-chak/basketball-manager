class_name ScheduleGenerator
extends RefCounted

# ---------------------------------------------------------------------------
# ScheduleGenerator.gd
# Generates a full 82-game regular season schedule for all NBA teams.
#
# Called once by GameManager at new game creation (or season rollover).
# Output is a flat Array of game entry Dictionaries saved to WorldState.schedule
# and persisted to the DB via Database.save_schedule().
#
# Each game entry:
# {
#   "home_team_id":  String,
#   "away_team_id":  String,
#   "date_day":      int,
#   "date_month":    int,
#   "date_year":     int,
#   "league_id":     String,
#   "played":        bool,     # false until simulated
# }
#
# Algorithm:
#   Phase 1 — Build matchup list from the NBA scheduling formula
#   Phase 2 — Assign home/away for inter-conference pairs
#   Phase 3 — Place matchups onto calendar dates with constraint checking
#   Phase 4 — Validate, fix violations, save
#
# NBA scheduling formula (82 games per team):
#   Division (4 opponents):             4 games each = 16
#   Intra-conf non-division (10 opp):   6 × 4 games + 4 × 3 games = 36
#   Inter-conference (15 opponents):    2 games each (1H, 1A) = 30
#   Total: 82
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Season window — matches nba_calendar.json
# ---------------------------------------------------------------------------
const SEASON_START_MONTH: int = 10
const SEASON_START_DAY:   int = 20
const SEASON_END_MONTH:   int = 4
const SEASON_END_DAY:     int = 10

# Marquee dates — fixed game slots regardless of normal scheduling.
const CHRISTMAS_MONTH:    int = 12
const CHRISTMAS_DAY:      int = 25
const CHRISTMAS_GAMES:    int = 5   # Always 5 games on Christmas

# ---------------------------------------------------------------------------
# Scheduling constraints
# ---------------------------------------------------------------------------

# Maximum back-to-backs allowed per team per week (7-day window).
const MAX_B2B_PER_WEEK:   int = 2

# Maximum games per team in any 7-day rolling window.
const MAX_GAMES_PER_WEEK: int = 5

# Max games scheduled on any single calendar date (real NBA: ~15 on busy nights).
const MAX_GAMES_PER_DAY:  int = 15

# Min games on a typical game day (some dates only have a few).
const MIN_GAMES_PER_DAY:  int = 2

# How many times to retry placing a matchup before relaxing constraints.
const PLACEMENT_RETRIES:  int = 40

# ---------------------------------------------------------------------------
# Schedule formula constants
# ---------------------------------------------------------------------------
const GAMES_VS_DIVISION:         int = 4   # Per opponent (4 opponents)
const GAMES_VS_CONF_4X:          int = 4   # 6 non-div conf opponents get 4 games
const GAMES_VS_CONF_3X:          int = 3   # 4 non-div conf opponents get 3 games
const CONF_4X_COUNT:             int = 6   # How many get the 4-game treatment
const GAMES_VS_OTHER_CONF:       int = 2   # Per opponent, 1H + 1A

# ---------------------------------------------------------------------------
# RNG — seeded per season for reproducible schedules.
# ---------------------------------------------------------------------------
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# ---------------------------------------------------------------------------
# Internal state — cleared between generate() calls.
# ---------------------------------------------------------------------------

# team_id -> Dictionary with conference, division, all opponent ids
var _team_data: Dictionary = {}

# All valid calendar dates in the season window as [month, day] pairs.
var _season_dates: Array = []

# Per-team game tracking during placement.
# team_id -> Array of [month, day] pairs (dates they play)
var _team_schedule: Dictionary = {}

# Per-date game count.
# "MM_DD" -> int
var _date_game_count: Dictionary = {}

# The league_id being generated.
var _league_id: String = "nba"

# ===========================================================================
# PUBLIC ENTRY POINT
# ===========================================================================



# ===========================================================================
# TEAM DATA PARSING
# ===========================================================================

func _parse_team_data(teams_config: Array) -> void:
	_team_data.clear()

	# Group teams by conference and division.
	# teams_config is the "teams" array from nba_teams.json.
	var by_conference: Dictionary = {}   # conf -> Array of team_ids
	var by_division:   Dictionary = {}   # division -> Array of team_ids

	for team in teams_config:
		var tid:  String = team["id"]
		var conf: String = team["conference"]
		var div:  String = team["division"]

		_team_data[tid] = {
			"id":         tid,
			"conference": conf,
			"division":   div,
		}

		if not by_conference.has(conf):
			by_conference[conf] = []
		by_conference[conf].append(tid)

		if not by_division.has(div):
			by_division[div] = []
		by_division[div].append(tid)

	# Compute opponent lists for each team.
	for tid in _team_data:
		var conf: String = _team_data[tid]["conference"]
		var div:  String = _team_data[tid]["division"]

		var division_opponents:    Array = []
		var conf_nondiv_opponents: Array = []
		var other_conf_opponents:  Array = []

		for other_tid in _team_data:
			if other_tid == tid:
				continue
			var other_conf: String = _team_data[other_tid]["conference"]
			var other_div:  String = _team_data[other_tid]["division"]

			if other_div == div:
				division_opponents.append(other_tid)
			elif other_conf == conf:
				conf_nondiv_opponents.append(other_tid)
			else:
				other_conf_opponents.append(other_tid)

		_team_data[tid]["division_opponents"]    = division_opponents
		_team_data[tid]["conf_nondiv_opponents"] = conf_nondiv_opponents
		_team_data[tid]["other_conf_opponents"]  = other_conf_opponents

# ===========================================================================
# SEASON DATE LIST
# ===========================================================================

func _build_season_dates(season_year: int) -> void:
	_season_dates.clear()
	_date_game_count.clear()

	# Season: Oct 20 (season_year) → Apr 10 (season_year + 1).
	# Walk month by month.
	var months_in_season: Array = [
		[10, season_year],
		[11, season_year],
		[12, season_year],
		[1,  season_year + 1],
		[2,  season_year + 1],
		[3,  season_year + 1],
		[4,  season_year + 1],
	]

	for entry in months_in_season:
		var month:  int = entry[0]
		var year:   int = entry[1]
		var days:   int = _days_in_month(month, year)

		var start_day: int = 1
		var end_day:   int = days

		if month == SEASON_START_MONTH and year == season_year:
			start_day = SEASON_START_DAY
		if month == SEASON_END_MONTH and year == season_year + 1:
			end_day = SEASON_END_DAY

		for d in range(start_day, end_day + 1):
			_season_dates.append([month, d])
			_date_game_count[_date_key(month, d)] = 0

# ===========================================================================
# MATCHUP LIST BUILDER
# ===========================================================================

## _build_matchup_list
## Returns an Array of matchup Dictionaries — one per game (not per series).
## Each entry: { home: team_id, away: team_id, type: String }
## "type" is used for commentary and marquee selection.
## Home/away alternates within multi-game series using a deterministic rule.
func _build_matchup_list() -> Array:
	var matchups: Array = []

	# Track which pairs have already been processed to avoid double-counting.
	var processed: Dictionary = {}

	for tid in _team_data:
		var data: Dictionary = _team_data[tid]

		# --- Division games: 4 per opponent ---
		for opp in data["division_opponents"]:
			var pair_key: String = _pair_key(tid, opp)
			if processed.has(pair_key):
				continue
			processed[pair_key] = true

			# 4 games: 2 home, 2 away for each team.
			matchups.append_array(_make_series(tid, opp, 2, 2, "division"))

		# --- Intra-conference non-division: 4 or 3 games ---
		# The 6 opponents who get 4 games are determined by a deterministic
		# rotation based on sorted opponent list — consistent within a season,
		# varies across seasons via the RNG seed.
		# Within a conference of 15 teams, each team has 10 non-div opponents.
		# Each pair's game count must be agreed — use the lower team_id alphabetically
		# as the "decider" so both sides see the same split.
		var conf_nondiv: Array = data["conf_nondiv_opponents"].duplicate()
		# Shuffle deterministically using the pair of team ids as seed offset.
		_shuffle_with_seed(conf_nondiv, _rng.seed + _str_hash(tid))

		var four_game_opps: Array = conf_nondiv.slice(0, CONF_4X_COUNT)
		var three_game_opps: Array = conf_nondiv.slice(CONF_4X_COUNT)

		for opp in four_game_opps:
			var pair_key: String = _pair_key(tid, opp)
			if processed.has(pair_key):
				continue
			processed[pair_key] = true
			# 4 games: split 2H/2A or 1H/3A alternating — use coin flip per pair.
			if _rng.randf() < 0.5:
				matchups.append_array(_make_series(tid, opp, 2, 2, "conference"))
			else:
				matchups.append_array(_make_series(opp, tid, 2, 2, "conference"))

		for opp in three_game_opps:
			var pair_key: String = _pair_key(tid, opp)
			if processed.has(pair_key):
				continue
			processed[pair_key] = true
			# 3 games: 2H/1A or 1H/2A — alternate who gets the extra home game.
			if _rng.randf() < 0.5:
				matchups.append_array(_make_series(tid, opp, 2, 1, "conference"))
			else:
				matchups.append_array(_make_series(tid, opp, 1, 2, "conference"))

		# --- Inter-conference: 2 games (1H, 1A) per opponent ---
		for opp in data["other_conf_opponents"]:
			var pair_key: String = _pair_key(tid, opp)
			if processed.has(pair_key):
				continue
			processed[pair_key] = true
			# Randomly assign who gets the home game.
			if _rng.randf() < 0.5:
				matchups.append(_make_game(tid, opp, "interconf"))
				matchups.append(_make_game(opp, tid, "interconf"))
			else:
				matchups.append(_make_game(opp, tid, "interconf"))
				matchups.append(_make_game(tid, opp, "interconf"))

	return matchups

## _make_series
## Creates home_count home games and away_count away games for team A vs team B.
func _make_series(
		team_a:     String,
		team_b:     String,
		home_count: int,
		away_count: int,
		game_type:  String) -> Array:
	var games: Array = []
	for _i in home_count:
		games.append(_make_game(team_a, team_b, game_type))
	for _i in away_count:
		games.append(_make_game(team_b, team_a, game_type))
	return games

func _make_game(home: String, away: String, game_type: String) -> Dictionary:
	return {
		"home":      home,
		"away":      away,
		"type":      game_type,
		"marquee":   false,
		"played":    false,
	}

# ===========================================================================
# MARQUEE GAME EXTRACTION
# ===========================================================================

## _extract_marquee_matchups
## Pulls out games to be pinned to specific dates (Christmas, Opening Night).
## These are removed from the main matchup list and placed first.
func _extract_marquee_matchups(matchups: Array, season_year: int) -> Array:
	var pinned: Array = []

	# Opening Night: first 2–3 games of the season (Oct 20 or 21).
	# Pin any matchup involving high-prestige teams.
	var opening_count: int = 0
	for i in matchups.size():
		if opening_count >= 2:
			break
		var m: Dictionary = matchups[i]
		# Simple heuristic: divisional or interconf games between any teams work
		# for opening night — real NBA curates these but we just take early entries.
		matchups[i]["marquee"]        = true
		matchups[i]["marquee_month"]  = SEASON_START_MONTH
		matchups[i]["marquee_day"]    = SEASON_START_DAY
		pinned.append(matchups[i])
		opening_count += 1

	# Christmas Day: 5 games on Dec 25.
	var christmas_count: int = 0
	for i in matchups.size():
		if christmas_count >= CHRISTMAS_GAMES:
			break
		var m: Dictionary = matchups[i]
		if m.get("marquee", false):
			continue
		matchups[i]["marquee"]       = true
		matchups[i]["marquee_month"] = CHRISTMAS_MONTH
		matchups[i]["marquee_day"]   = CHRISTMAS_DAY
		pinned.append(matchups[i])
		christmas_count += 1

	# Remove pinned games from main list.
	matchups = matchups.filter(func(m): return not m.get("marquee", false))

	return pinned

# ===========================================================================
# PLACEMENT — MARQUEE GAMES
# ===========================================================================

func _place_marquee_games(
		pinned:    Array,
		scheduled: Array,
		season_year: int) -> Array:

	for m in pinned:
		var month: int = m.get("marquee_month", SEASON_START_MONTH)
		var day:   int = m.get("marquee_day",   SEASON_START_DAY)
		var year:  int = season_year if month >= SEASON_START_MONTH else season_year + 1

		var entry: Dictionary = {
			"home_team_id": m["home"],
			"away_team_id": m["away"],
			"date_day":     day,
			"date_month":   month,
			"date_year":    year,
			"league_id":    _league_id,
			"played":       false,
			"game_type":    m.get("type", "regular"),
			"marquee":      true,
		}

		scheduled.append(entry)
		_team_schedule[m["home"]].append([month, day])
		_team_schedule[m["away"]].append([month, day])
		_date_game_count[_date_key(month, day)] = \
			_date_game_count.get(_date_key(month, day), 0) + 1

	return scheduled

# ===========================================================================
# PLACEMENT — REMAINING MATCHUPS (GREEDY)
# ===========================================================================

## _place_remaining
## Assigns each unscheduled matchup to the earliest valid date.
## Iterates through all matchups; for each, scans forward from the midpoint
## of the season to spread load evenly, then falls back to any valid date.
func _place_remaining(matchups: Array, scheduled: Array) -> Array:
	# Sort matchups: division games first (they need more spread),
	# then conference, then inter-conference.
	var sorted_matchups: Array = matchups.duplicate()
	sorted_matchups.sort_custom(func(a, b):
		var order: Dictionary = {"division": 0, "conference": 1, "interconf": 2}
		return order.get(a["type"], 1) < order.get(b["type"], 1)
	)

	# Track how far through the date list we last placed a game per team,
	# to nudge placement forward and spread games across the season.
	var team_date_cursor: Dictionary = {}
	for tid in _team_data:
		team_date_cursor[tid] = 0

	for matchup in sorted_matchups:
		var home: String = matchup["home"]
		var away: String = matchup["away"]

		var placed: bool = false
		var relaxed: bool = false

		# Start scanning from the later of the two teams' cursors.
		var start_idx: int = maxi(
			team_date_cursor.get(home, 0),
			team_date_cursor.get(away, 0)
		)
		start_idx = clampi(start_idx, 0, _season_dates.size() - 1)

		for attempt in PLACEMENT_RETRIES:
			# On the first half of attempts, scan forward from cursor.
			# On the second half, scan from the beginning (relax cursor preference).
			var scan_start: int = start_idx if attempt < PLACEMENT_RETRIES / 2 else 0

			if attempt == PLACEMENT_RETRIES - 5:
				relaxed = true   # Last 5 attempts: relax back-to-back constraint.

			for date_idx in range(scan_start, _season_dates.size()):
				var date:  Array = _season_dates[date_idx]
				var month: int   = date[0]
				var day:   int   = date[1]

				if _is_valid_date(home, away, month, day, relaxed):
					var year: int = _season_year_for_month(month)
					var entry: Dictionary = {
						"home_team_id": home,
						"away_team_id": away,
						"date_day":     day,
						"date_month":   month,
						"date_year":    year,
						"league_id":    _league_id,
						"played":       false,
						"game_type":    matchup.get("type", "regular"),
						"marquee":      false,
					}

					scheduled.append(entry)
					_team_schedule[home].append([month, day])
					_team_schedule[away].append([month, day])
					_date_game_count[_date_key(month, day)] = \
						_date_game_count.get(_date_key(month, day), 0) + 1

					# Advance cursors past this date.
					team_date_cursor[home] = date_idx + 1
					team_date_cursor[away] = date_idx + 1

					placed = true
					break

			if placed:
				break

		if not placed:
			push_warning("ScheduleGenerator: could not place matchup %s vs %s" % [home, away])

	return scheduled

# ===========================================================================
# CONSTRAINT CHECKING
# ===========================================================================

## _is_valid_date
## Returns true if both teams can play on this date without violating constraints.
func _is_valid_date(
		home:    String,
		away:    String,
		month:   int,
		day:     int,
		relaxed: bool) -> bool:

	# Date must exist in our season window.
	var dk: String = _date_key(month, day)
	if not _date_game_count.has(dk):
		return false

	# Date must not be over-full.
	if _date_game_count.get(dk, 0) >= MAX_GAMES_PER_DAY:
		return false

	# Both teams must be free on this date.
	if _team_plays_on(home, month, day) or _team_plays_on(away, month, day):
		return false

	# Back-to-back check (unless relaxed).
	if not relaxed:
		if _would_create_excessive_b2b(home, month, day):
			return false
		if _would_create_excessive_b2b(away, month, day):
			return false

	# Max games per week check.
	if _games_in_window(home, month, day, 7) >= MAX_GAMES_PER_WEEK:
		return false
	if _games_in_window(away, month, day, 7) >= MAX_GAMES_PER_WEEK:
		return false

	return true

## _team_plays_on
## Returns true if a team already has a game on the given date.
func _team_plays_on(team_id: String, month: int, day: int) -> bool:
	for date in _team_schedule.get(team_id, []):
		if date[0] == month and date[1] == day:
			return true
	return false

## _would_create_excessive_b2b
## Returns true if placing a game on this date would give the team more than
## MAX_B2B_PER_WEEK back-to-backs in the surrounding 7-day window.
func _would_create_excessive_b2b(team_id: String, month: int, day: int) -> bool:
	# A back-to-back occurs when a team plays on consecutive days.
	# Count existing back-to-backs in a ±3 day window around the proposed date.
	var existing_b2b: int = 0
	var dates: Array = _team_schedule.get(team_id, [])

	# Check if playing today would create a back-to-back.
	var abs_day: int = _to_absolute_day(month, day)
	var creates_b2b: bool = false

	for d in dates:
		var other_abs: int = _to_absolute_day(d[0], d[1])
		if abs(other_abs - abs_day) == 1:
			creates_b2b = true
			break

	if not creates_b2b:
		return false

	# It creates a back-to-back — count how many already exist in this week.
	for i in dates.size():
		var d1: int = _to_absolute_day(dates[i][0], dates[i][1])
		if abs(d1 - abs_day) > 7:
			continue
		for j in range(i + 1, dates.size()):
			var d2: int = _to_absolute_day(dates[j][0], dates[j][1])
			if d2 - d1 == 1:
				existing_b2b += 1

	return existing_b2b >= MAX_B2B_PER_WEEK

## _games_in_window
## Returns how many games a team has in the N days before/after the given date.
func _games_in_window(team_id: String, month: int, day: int, window: int) -> int:
	var abs_day: int = _to_absolute_day(month, day)
	var count:   int = 0
	for d in _team_schedule.get(team_id, []):
		var other: int = _to_absolute_day(d[0], d[1])
		if abs(other - abs_day) <= window:
			count += 1
	return count

# ===========================================================================
# VALIDATION
# ===========================================================================

## _validate
## Checks the generated schedule for obvious errors and logs warnings.
## Does not modify the schedule — just reports.
func _validate(scheduled: Array) -> void:
	var game_count: Dictionary = {}   # team_id -> int

	for entry in scheduled:
		var home: String = entry["home_team_id"]
		var away: String = entry["away_team_id"]
		game_count[home] = game_count.get(home, 0) + 1
		game_count[away] = game_count.get(away, 0) + 1

	for team_id in _team_data:
		var count: int = game_count.get(team_id, 0)
		if count != 82:
			push_warning("ScheduleGenerator: %s has %d games (expected 82)" % [team_id, count])

	print("[ScheduleGenerator] Generated %d total games." % scheduled.size())
	print("[ScheduleGenerator] Validation complete.")

# ===========================================================================
# DATE UTILITIES
# ===========================================================================

## _to_absolute_day
## Converts month/day to an absolute day number within the season.
## Oct 20 = day 1, Oct 21 = day 2, ... Apr 10 = day 172 (approx).
## Used for back-to-back and window calculations — doesn't need to be exact.
func _to_absolute_day(month: int, day: int) -> int:
	# Days elapsed from season start (Oct 20).
	# Months: Oct=10, Nov=11, Dec=12, Jan=1, Feb=2, Mar=3, Apr=4
	var month_offsets: Dictionary = {
		10: 0,    # Oct: starts at day 0
		11: 31,   # Nov: Oct has 31 days
		12: 61,   # Dec: Oct(31) + Nov(30)
		1:  92,   # Jan: + Dec(31)
		2:  123,  # Feb: + Jan(31)
		3:  151,  # Mar: + Feb(28, non-leap approx)
		4:  182,  # Apr: + Mar(31)
	}
	var base: int = month_offsets.get(month, 0)
	# Subtract season start day for October.
	if month == 10:
		return base + day - SEASON_START_DAY
	return base + day

func _season_year_for_month(month: int) -> int:
	# Months Oct–Dec belong to the start year; Jan–Apr to start year + 1.
	# We read _season_year from WorldState — passed in at generate() time.
	# Store it during generate() for use here.
	return _current_season_year if month >= SEASON_START_MONTH \
		else _current_season_year + 1

var _current_season_year: int = 2025

func _date_key(month: int, day: int) -> String:
	return "%02d_%02d" % [month, day]

func _pair_key(a: String, b: String) -> String:
	# Always put alphabetically first team first so A-vs-B == B-vs-A.
	if a < b:
		return "%s_%s" % [a, b]
	return "%s_%s" % [b, a]

func _days_in_month(month: int, year: int) -> int:
	match month:
		1, 3, 5, 7, 8, 10, 12: return 31
		4, 6, 9, 11:            return 30
		2:
			# Leap year check.
			if (year % 4 == 0 and year % 100 != 0) or year % 400 == 0:
				return 29
			return 28
	return 30

# ===========================================================================
# SHUFFLE HELPERS
# ===========================================================================

func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i]  = arr[j]
		arr[j]  = tmp

func _shuffle_with_seed(arr: Array, seed: int) -> void:
	var local_rng: RandomNumberGenerator = RandomNumberGenerator.new()
	local_rng.seed = seed
	for i in range(arr.size() - 1, 0, -1):
		var j: int = local_rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i]  = arr[j]
		arr[j]  = tmp

func _str_hash(s: String) -> int:
	var h: int = 0
	for i in s.length():
		h = (h * 31 + s.unicode_at(i)) & 0x7FFFFFFF
	return h

# ===========================================================================
# SEASON YEAR TRACKING
# ===========================================================================

## generate
## Generates a full season schedule for all teams in the league config.
## Returns an Array of game entry Dictionaries.
## season_year: the October start year (e.g. 2025 for the 2025-26 season).
func generate(
		teams_config: Array,
		season_year:  int,
		league_id:    String,
		rng_seed:     int = 0) -> Array:

	_current_season_year = season_year
	_league_id           = league_id

	if rng_seed == 0:
		rng_seed = randi()
	_rng.seed = rng_seed

	_parse_team_data(teams_config)
	_build_season_dates(season_year)

	for team_id in _team_data:
		_team_schedule[team_id] = []

	var matchups: Array = _build_matchup_list()
	var pinned:   Array = _extract_marquee_matchups(matchups, season_year)
	var remaining: Array = matchups.duplicate()
	_shuffle(remaining)

	var scheduled: Array = []
	scheduled = _place_marquee_games(pinned, scheduled, season_year)
	scheduled = _place_remaining(remaining, scheduled)

	_validate(scheduled)

	return scheduled
