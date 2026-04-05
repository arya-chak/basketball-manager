class_name ContractGenerator
extends RefCounted

# ---------------------------------------------------------------------------
# Salary ranges by tier — as percentage of cap
# ---------------------------------------------------------------------------

const SALARY_RANGES = {
	Player.Tier.SUPERSTAR: { "min": 0.30, "max": 0.35 },
	Player.Tier.STAR:      { "min": 0.20, "max": 0.28 },
	Player.Tier.STARTER:   { "min": 0.08, "max": 0.18 },
	Player.Tier.ROTATION:  { "min": 0.03, "max": 0.07 },
	Player.Tier.FRINGE:    { "min": 0.018,"max": 0.030 }
}

# Age modifier on base salary percentage
const AGE_MODIFIERS = [
	{ "max_age": 24, "modifier": 0.85 },   # Young — signed cheap
	{ "max_age": 28, "modifier": 1.00 },   # Prime — full value
	{ "max_age": 31, "modifier": 1.10 },   # Peak but declining
	{ "max_age": 34, "modifier": 0.90 },   # Aging discount
	{ "max_age": 99, "modifier": 0.70 }    # Veteran minimum territory
]

# Years remaining ranges by tier
const YEARS_REMAINING = {
	Player.Tier.SUPERSTAR: { "min": 2, "max": 5 },
	Player.Tier.STAR:      { "min": 2, "max": 4 },
	Player.Tier.STARTER:   { "min": 1, "max": 4 },
	Player.Tier.ROTATION:  { "min": 1, "max": 3 },
	Player.Tier.FRINGE:    { "min": 1, "max": 2 }
}

# Escalation rates
const BIRD_ESCALATION_RATE:     float = 0.08
const NON_BIRD_ESCALATION_RATE: float = 0.05
const ROOKIE_ESCALATION_RATE:   float = 0.08
const G_LEAGUE_ANNUAL_SALARY:   int   = 40000

# ---------------------------------------------------------------------------
# WORLD GEN — generates a staggered contract for an existing roster player
# Simulates that players are at various points in their existing deals
# ---------------------------------------------------------------------------

func generate_world_gen_contract(
	player: Player,
	team: Team,
	cap_figure: int,
	is_g_league: bool = false
) -> Dictionary:

	# G League players get flat 1-year deals — no escalation, no staggering
	if is_g_league:
		return _generate_g_league_contract(player, team)

	# Determine years remaining based on tier and age
	var years_remaining = _get_years_remaining(player.tier, player.age)

	# Determine total deal length — years remaining + years already served
	var years_served = randi_range(0, 4 - years_remaining)
	var total_years  = years_remaining + years_served

	# Determine bird rights based on years served
	var bird_rights = "non"
	if years_served >= 3:
		bird_rights = "full"
	elif years_served >= 2:
		bird_rights = "early"

	var escalation_rate = get_escalation_rate(bird_rights)

	# Calculate year-1 salary (what the player originally signed for)
	var current_year_salary = _get_base_salary(player, cap_figure)
	var year1_salary = _backtrack_to_year1(
		current_year_salary, years_served, escalation_rate
	)

	# Build salary schedule from year 1
	var all_years = build_salary_schedule(year1_salary, total_years, escalation_rate)

	# Slice to remaining years only
	var remaining_salaries = all_years.slice(years_served)

	return {
		"player_id":          player.id,
		"team_id":            team.id,
		"salaries":           remaining_salaries,
		"total_years":        total_years,
		"years_remaining":    years_remaining,
		"is_two_way":         false,
		"is_rookie_scale":    false,
		"team_option_year":   0,
		"player_option_year": 0,
		"bird_rights":        bird_rights,
		"escalation_rate":    escalation_rate
	}

# ---------------------------------------------------------------------------
# FREE AGENCY — generates contract from agreed terms
# Called by FreeAgency system after player accepts offer
# ---------------------------------------------------------------------------

func generate_free_agent_contract(
	player: Player,
	team: Team,
	annual_salary: int,
	years: int,
	bird_rights: String
) -> Dictionary:

	var escalation_rate = get_escalation_rate(bird_rights)
	var salaries        = build_salary_schedule(annual_salary, years, escalation_rate)

	return {
		"player_id":          player.id,
		"team_id":            team.id,
		"salaries":           salaries,
		"total_years":        years,
		"years_remaining":    years,
		"is_two_way":         false,
		"is_rookie_scale":    false,
		"team_option_year":   0,
		"player_option_year": 0,
		"bird_rights":        bird_rights,
		"escalation_rate":    escalation_rate
	}

# ---------------------------------------------------------------------------
# DRAFT NIGHT — generates rookie scale contract from draft slot
# First round: 4-year rookie scale deal, years 3-4 are team options
# Second round: 2-year deal at veteran minimum, year 2 team option
# ---------------------------------------------------------------------------

func generate_rookie_contract(
	player: Player,
	team: Team,
	draft_slot: int,
	cap_figure: int
) -> Dictionary:

	if draft_slot <= 30:
		return _generate_first_round_rookie(player, team, draft_slot, cap_figure)
	else:
		return _generate_second_round_rookie(player, team, cap_figure)

func _generate_first_round_rookie(
	player: Player,
	team: Team,
	slot: int,
	cap_figure: int
) -> Dictionary:

	# Rookie scale salary from nba_cap_rules slot table
	var slot_pct = _get_rookie_scale_pct(slot)
	var year1    = roundi(cap_figure * slot_pct)
	var salaries = build_salary_schedule(year1, 4, ROOKIE_ESCALATION_RATE)

	return {
		"player_id":          player.id,
		"team_id":            team.id,
		"salaries":           salaries,
		"total_years":        4,
		"years_remaining":    4,
		"is_two_way":         false,
		"is_rookie_scale":    true,
		"team_option_year":   3,   # Years 3 and 4 are team options
		"player_option_year": 0,
		"bird_rights":        "non",
		"escalation_rate":    ROOKIE_ESCALATION_RATE
	}

func _generate_second_round_rookie(
	player: Player,
	team: Team,
	cap_figure: int
) -> Dictionary:

	# Second rounders get veteran minimum — rookie tier
	var year1    = roundi(cap_figure * 0.018)
	var salaries = build_salary_schedule(year1, 2, NON_BIRD_ESCALATION_RATE)

	return {
		"player_id":          player.id,
		"team_id":            team.id,
		"salaries":           salaries,
		"total_years":        2,
		"years_remaining":    2,
		"is_two_way":         false,
		"is_rookie_scale":    false,
		"team_option_year":   2,   # Year 2 is team option
		"player_option_year": 0,
		"bird_rights":        "non",
		"escalation_rate":    NON_BIRD_ESCALATION_RATE
	}

# ---------------------------------------------------------------------------
# G LEAGUE CONTRACT — flat 1-year deal, no escalation
# ---------------------------------------------------------------------------

func _generate_g_league_contract(player: Player, team: Team) -> Dictionary:
	return {
		"player_id":          player.id,
		"team_id":            team.id,
		"salaries":           [G_LEAGUE_ANNUAL_SALARY],
		"total_years":        1,
		"years_remaining":    1,
		"is_two_way":         false,
		"is_rookie_scale":    false,
		"team_option_year":   0,
		"player_option_year": 0,
		"bird_rights":        "non",
		"escalation_rate":    0.0
	}

# ---------------------------------------------------------------------------
# TWO-WAY CONTRACT — fixed salary, does not count against cap
# ---------------------------------------------------------------------------

func generate_two_way_contract(player: Player, team: Team) -> Dictionary:
	return {
		"player_id":          player.id,
		"team_id":            team.id,
		"salaries":           [600000],
		"total_years":        1,
		"years_remaining":    1,
		"is_two_way":         true,
		"is_rookie_scale":    false,
		"team_option_year":   0,
		"player_option_year": 0,
		"bird_rights":        "non",
		"escalation_rate":    0.0
	}

# ---------------------------------------------------------------------------
# SALARY SCHEDULE BUILDER
# Builds array of annual salaries with escalation applied year over year
# ---------------------------------------------------------------------------

func build_salary_schedule(
	year1_salary: int,
	total_years: int,
	escalation_rate: float
) -> Array:

	var schedule: Array = []
	var current = float(year1_salary)

	for i in range(total_years):
		schedule.append(roundi(current))
		current *= (1.0 + escalation_rate)

	return schedule

# ---------------------------------------------------------------------------
# ESCALATION RATE by bird rights
# ---------------------------------------------------------------------------

func get_escalation_rate(bird_rights: String) -> float:
	match bird_rights:
		"full":  return BIRD_ESCALATION_RATE
		"early": return BIRD_ESCALATION_RATE
		_:       return NON_BIRD_ESCALATION_RATE

# ---------------------------------------------------------------------------
# CAP COMPLIANCE — adjusts a team's contracts to hit a target payroll
# Called by LeagueLoader after world gen contracts are assigned
# ---------------------------------------------------------------------------

func enforce_cap_compliance(team: Team, contracts: Array, cap_figure: int) -> Array:
	var total = _sum_current_salaries(contracts)
	var second_apron = roundi(cap_figure * 1.10 * 1.105)

	# Pass 1 — trim if over second apron
	if total > second_apron:
		contracts = _trim_to_apron(contracts, second_apron, team)
		total = _sum_current_salaries(contracts)

	# Pass 2 — bump if significantly under floor (70% of cap)
	var floor = roundi(cap_figure * 0.70)
	if total < floor:
		contracts = _bump_to_floor(contracts, floor, cap_figure)

	return contracts

func _trim_to_apron(
	contracts: Array,
	apron: int,
	team: Team
) -> Array:

	# Sort by salary descending — trim highest non-star players first
	var sorted = contracts.duplicate()
	sorted.sort_custom(func(a, b):
		return _current_salary(a) > _current_salary(b)
	)

	var total = _sum_current_salaries(sorted)

	for i in range(sorted.size()):
		if total <= apron:
			break
		var contract = sorted[i]
		# Don't touch superstar or star contracts
		var player = WorldState.get_player(contract["player_id"])
		if player == null:
			continue
		if player.tier in [Player.Tier.SUPERSTAR, Player.Tier.STAR]:
			continue

		# Convert to veteran minimum
		var vet_min = roundi(WorldState.current_salary_cap * 0.018)
		var old_salary = _current_salary(contract)
		contract["salaries"][0] = vet_min
		total -= (old_salary - vet_min)

	return sorted

func _bump_to_floor(
	contracts: Array,
	floor: int,
	cap_figure: int
) -> Array:

	var total = _sum_current_salaries(contracts)
	var gap   = floor - total

	# Distribute gap across fringe players as small bumps
	for i in range(contracts.size()):
		if total >= floor:
			break
		var contract = contracts[i]
		var player   = WorldState.get_player(contract["player_id"])
		if player == null:
			continue
		if player.tier != Player.Tier.FRINGE:
			continue
		# Bump up by up to 50% of gap, capped at 3% of cap
		var bump = mini(roundi(gap * 0.5), roundi(cap_figure * 0.03))
		contract["salaries"][0] += bump
		total += bump

	return contracts

func _sum_current_salaries(contracts: Array) -> int:
	var total = 0
	for c in contracts:
		total += _current_salary(c)
	return total

func _current_salary(contract: Dictionary) -> int:
	var salaries = contract.get("salaries", [])
	if salaries.is_empty():
		return 0
	return salaries[0]

# ---------------------------------------------------------------------------
# INTERNAL HELPERS
# ---------------------------------------------------------------------------

func _get_base_salary(player: Player, cap_figure: int) -> int:
	var range_data = SALARY_RANGES.get(player.tier, { "min": 0.018, "max": 0.03 })
	var base_pct   = randf_range(range_data["min"], range_data["max"])

	# Apply age modifier
	var age_mod = 1.0
	for entry in AGE_MODIFIERS:
		if player.age <= entry["max_age"]:
			age_mod = entry["modifier"]
			break

	return roundi(cap_figure * base_pct * age_mod)

func _get_years_remaining(tier: Player.Tier, age: int) -> int:
	if age >= 34:
		return 1
	elif age >= 30:
		return randi_range(1, 2)

	var range_data = YEARS_REMAINING.get(tier, { "min": 1, "max": 2 })
	return randi_range(range_data["min"], range_data["max"])

func _backtrack_to_year1(
	current_salary: int,
	years_served: int,
	escalation_rate: float
) -> int:
	# Reverse the escalation to find what year 1 salary was
	var year1 = float(current_salary)
	for i in range(years_served):
		year1 /= (1.0 + escalation_rate)
	return roundi(year1)

func _get_rookie_scale_pct(slot: int) -> float:
	# Matches the rookie scale table in nba_cap_rules.json
	var scale = [
		0.090, 0.086, 0.082, 0.078, 0.074,
		0.068, 0.063, 0.059, 0.055, 0.052,
		0.049, 0.046, 0.044, 0.042, 0.040,
		0.038, 0.036, 0.034, 0.033, 0.032,
		0.031, 0.030, 0.029, 0.028, 0.027,
		0.026, 0.025, 0.024, 0.023, 0.022
	]
	var idx = clampi(slot - 1, 0, scale.size() - 1)
	return scale[idx]
