extends Node

# Days in each month — February handled dynamically for leap years.
const DAYS_IN_MONTH_BASE = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

# Season calendar milestones
const REGULAR_SEASON_START = {"month": 10, "day": 20}
const REGULAR_SEASON_END   = {"month": 4,  "day": 10}
const PLAYOFFS_START       = {"month": 4,  "day": 19}   # Matches nba_calendar.json
const PLAY_IN_START        = {"month": 4,  "day": 13}   # Matches nba_calendar.json
const PLAYOFFS_END         = {"month": 6,  "day": 20}
const DRAFT_DATE           = {"month": 6,  "day": 25}
const FREE_AGENCY_START    = {"month": 7,  "day": 1}
const TRAINING_CAMP_START  = {"month": 9,  "day": 25}

func advance_day() -> void:
	WorldState.current_day += 1

	# Handle month rollover — use dynamic check for leap years.
	var days_in_current: int = _days_in_month(WorldState.current_month, WorldState.current_year)
	if WorldState.current_day > days_in_current:
		WorldState.current_day = 1
		WorldState.current_month += 1

		# Handle year rollover.
		if WorldState.current_month > 12:
			WorldState.current_month = 1
			WorldState.current_year += 1

	EventBus.day_advanced.emit(get_current_date())
	_check_milestones()

func _days_in_month(month: int, year: int) -> int:
	if month == 2 and _is_leap_year(year):
		return 29
	return DAYS_IN_MONTH_BASE[month - 1]

func _is_leap_year(year: int) -> bool:
	return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0

func advance_week() -> void:
	for i in range(7):
		advance_day()

func get_current_date() -> Dictionary:
	return {
		"day": WorldState.current_day,
		"month": WorldState.current_month,
		"year": WorldState.current_year
	}

func _check_milestones() -> void:
	var m: int = WorldState.current_month
	var d: int = WorldState.current_day

	if m == REGULAR_SEASON_START["month"] and d == REGULAR_SEASON_START["day"]:
		if WorldState.current_season_stage != "regular":
			WorldState.current_season_stage = "regular"
			EventBus.notification_posted.emit("The regular season has started!", "info")

	elif m == REGULAR_SEASON_END["month"] and d == REGULAR_SEASON_END["day"]:
		# SeasonScheduler also detects this via schedule completion.
		# Clock provides a calendar-based fallback for edge cases where
		# the schedule finishes on a different date than expected.
		if WorldState.current_season_stage == "regular":
			WorldState.current_season_stage = "play_in"
			EventBus.notification_posted.emit(
				"The regular season is over. The play-in tournament begins!", "info"
			)

	elif m == PLAY_IN_START["month"] and d == PLAY_IN_START["day"]:
		if WorldState.current_season_stage == "regular":
			WorldState.current_season_stage = "play_in"
			EventBus.notification_posted.emit("The play-in tournament has begun!", "info")

	elif m == PLAYOFFS_START["month"] and d == PLAYOFFS_START["day"]:
		if WorldState.current_season_stage in ["regular", "play_in"]:
			WorldState.current_season_stage = "playoffs"
			EventBus.notification_posted.emit("The playoffs have begun!", "info")

	elif m == DRAFT_DATE["month"] and d == DRAFT_DATE["day"]:
		EventBus.notification_posted.emit("Draft night is here!", "info")

	elif m == FREE_AGENCY_START["month"] and d == FREE_AGENCY_START["day"]:
		if not WorldState.is_offseason:
			WorldState.begin_offseason()
			EventBus.notification_posted.emit("Free agency is open!", "info")

	elif m == TRAINING_CAMP_START["month"] and d == TRAINING_CAMP_START["day"]:
		EventBus.notification_posted.emit("Training camp has opened.", "info")

## is_match_day
## Returns true if there are unplayed games in WorldState.schedule for today.
## SeasonScheduler is the authoritative source — this is a lightweight check
## the UI can use to know whether to show a "games today" indicator.
func is_match_day() -> bool:
	if WorldState.current_season_stage != "regular":
		return false
	var m: int = WorldState.current_month
	var d: int = WorldState.current_day
	var y: int = WorldState.current_year
	for entry in WorldState.schedule:
		if not entry.get("played", false) \
				and entry["date_month"] == m \
				and entry["date_day"]   == d \
				and entry["date_year"]  == y:
			return true
	return false

## get_day_of_week
## Returns 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat.
## Kept as a public utility for UI display (e.g. showing "Tuesday, Oct 22").
func get_day_of_week() -> int:
	return _get_day_of_week()

func _get_day_of_week() -> int:
	# Zeller's formula — returns 0=Sun, 1=Mon ... 6=Sat
	var d: int = WorldState.current_day
	var m: int = WorldState.current_month
	var y: int = WorldState.current_year
	if m < 3:
		m += 12
		y -= 1
	var k: int = y % 100
	var j: int = y / 100
	var h: int = (d + int(13 * (m + 1) / 5) + k + int(k / 4) + int(j / 4) - 2 * j) % 7
	return (h + 6) % 7
