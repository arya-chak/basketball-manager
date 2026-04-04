extends Node

# Days in each month (non-leap year)
const DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

# Season calendar milestones
const REGULAR_SEASON_START = {"month": 10, "day": 20}
const REGULAR_SEASON_END   = {"month": 4,  "day": 10}
const PLAYOFFS_START       = {"month": 4,  "day": 15}
const PLAYOFFS_END         = {"month": 6,  "day": 20}
const DRAFT_DATE           = {"month": 6,  "day": 25}
const FREE_AGENCY_START    = {"month": 7,  "day": 1}
const TRAINING_CAMP_START  = {"month": 9,  "day": 25}

func advance_day() -> void:
	WorldState.current_day += 1

	# Handle month rollover
	var days_in_current = DAYS_IN_MONTH[WorldState.current_month - 1]
	if WorldState.current_day > days_in_current:
		WorldState.current_day = 1
		WorldState.current_month += 1

		# Handle year rollover
		if WorldState.current_month > 12:
			WorldState.current_month = 1
			WorldState.current_year += 1

	EventBus.day_advanced.emit(get_current_date())
	_check_milestones()

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
	var m = WorldState.current_month
	var d = WorldState.current_day

	if m == REGULAR_SEASON_START["month"] and d == REGULAR_SEASON_START["day"]:
		WorldState.current_season_stage = "regular"
		EventBus.notification_posted.emit("The regular season has started!", "info")

	elif m == PLAYOFFS_START["month"] and d == PLAYOFFS_START["day"]:
		WorldState.current_season_stage = "playoffs"
		EventBus.notification_posted.emit("The playoffs have begun!", "info")

	elif m == DRAFT_DATE["month"] and d == DRAFT_DATE["day"]:
		EventBus.notification_posted.emit("Draft night is here!", "info")

	elif m == FREE_AGENCY_START["month"] and d == FREE_AGENCY_START["day"]:
		WorldState.is_offseason = true
		EventBus.offseason_started.emit()
		EventBus.notification_posted.emit("Free agency is open!", "info")

	elif m == TRAINING_CAMP_START["month"] and d == TRAINING_CAMP_START["day"]:
		WorldState.is_offseason = false
		EventBus.notification_posted.emit("Training camp has opened.", "info")

func is_match_day() -> bool:
	# Regular season has games Tuesday, Thursday, Saturday, Sunday
	# We'll expand this when the scheduler is built
	var day_of_week = _get_day_of_week()
	return WorldState.current_season_stage == "regular" and day_of_week in [2, 4, 6, 0]

func _get_day_of_week() -> int:
	# Zeller's formula simplified — returns 0=Sun, 1=Mon ... 6=Sat
	var d = WorldState.current_day
	var m = WorldState.current_month
	var y = WorldState.current_year
	if m < 3:
		m += 12
		y -= 1
	var k = y % 100
	var j = y / 100
	var h = (d + int(13 * (m + 1) / 5) + k + int(k / 4) + int(j / 4) - 2 * j) % 7
	return (h + 6) % 7
