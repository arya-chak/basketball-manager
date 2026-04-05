class_name PlayerGenerator
extends RefCounted

# ---------------------------------------------------------------------------
# Constants — generation parameters
# ---------------------------------------------------------------------------

const VISIBLE_ATTR_STD_DEV: float = 2.0
const HIDDEN_ATTR_STD_DEV:  float = 2.5
const HIDDEN_ATTR_MEAN:     float = 8.0
const SECONDARY_SKILL_MULT: float = 0.6   # Secondary biases are 60% of primary
const SAME_SKILL_WEIGHT:    float = 0.6   # Reduced weight for same primary+secondary

# ---------------------------------------------------------------------------
# Tier means — baseline for all visible attributes before biases
# ---------------------------------------------------------------------------

const TIER_MEANS = {
	Player.Tier.FRINGE:    7,
	Player.Tier.ROTATION:  10,
	Player.Tier.STARTER:   13,
	Player.Tier.STAR:      16,
	Player.Tier.SUPERSTAR: 18
}

# ---------------------------------------------------------------------------
# Tier distribution weights by league context
# ---------------------------------------------------------------------------

const NBA_TIER_WEIGHTS = {
	Player.Tier.FRINGE:    0.20,
	Player.Tier.ROTATION:  0.40,
	Player.Tier.STARTER:   0.28,
	Player.Tier.STAR:      0.10,
	Player.Tier.SUPERSTAR: 0.02
}

const G_LEAGUE_TIER_WEIGHTS = {
	Player.Tier.FRINGE:    0.45,
	Player.Tier.ROTATION:  0.38,
	Player.Tier.STARTER:   0.14,
	Player.Tier.STAR:      0.03,
	Player.Tier.SUPERSTAR: 0.00
}

const DRAFT_TIER_WEIGHTS = {
	Player.Tier.FRINGE:    0.30,
	Player.Tier.ROTATION:  0.35,
	Player.Tier.STARTER:   0.22,
	Player.Tier.STAR:      0.11,
	Player.Tier.SUPERSTAR: 0.02
}

# ---------------------------------------------------------------------------
# Archetype probability by tier — chance a player has a defined archetype
# ---------------------------------------------------------------------------

const ARCHETYPE_CHANCE = {
	Player.Tier.FRINGE:    0.20,
	Player.Tier.ROTATION:  0.45,
	Player.Tier.STARTER:   0.70,
	Player.Tier.STAR:      0.90,
	Player.Tier.SUPERSTAR: 1.00
}

# ---------------------------------------------------------------------------
# Skill group identifiers
# ---------------------------------------------------------------------------

enum Skill {
	PASSING,
	SHOT_CREATING,
	THREE_POINT,
	DRIVING,
	DEFENDING,
	REBOUNDING,
	POST
}

# ---------------------------------------------------------------------------
# Primary skill availability by position
# ---------------------------------------------------------------------------

const POSITION_AVAILABLE_SKILLS = {
	Player.Position.PG: [Skill.PASSING, Skill.SHOT_CREATING, Skill.THREE_POINT, Skill.DRIVING, Skill.DEFENDING],
	Player.Position.SG: [Skill.PASSING, Skill.SHOT_CREATING, Skill.THREE_POINT, Skill.DRIVING, Skill.DEFENDING],
	Player.Position.SF: [Skill.PASSING, Skill.SHOT_CREATING, Skill.THREE_POINT, Skill.DRIVING, Skill.DEFENDING, Skill.REBOUNDING, Skill.POST],
	Player.Position.PF: [Skill.THREE_POINT, Skill.DRIVING, Skill.DEFENDING, Skill.REBOUNDING, Skill.POST],
	Player.Position.C:  [Skill.THREE_POINT, Skill.DRIVING, Skill.DEFENDING, Skill.REBOUNDING, Skill.POST]
}

# ---------------------------------------------------------------------------
# Primary skill weights by position
# ---------------------------------------------------------------------------

const PRIMARY_SKILL_WEIGHTS = {
	Player.Position.PG: {
		Skill.PASSING:       0.30,
		Skill.SHOT_CREATING: 0.25,
		Skill.DRIVING:       0.20,
		Skill.THREE_POINT:   0.15,
		Skill.DEFENDING:     0.10
	},
	Player.Position.SG: {
		Skill.THREE_POINT:   0.30,
		Skill.SHOT_CREATING: 0.25,
		Skill.DRIVING:       0.20,
		Skill.PASSING:       0.15,
		Skill.DEFENDING:     0.10
	},
	Player.Position.SF: {
		Skill.DRIVING:       0.25,
		Skill.THREE_POINT:   0.20,
		Skill.SHOT_CREATING: 0.15,
		Skill.DEFENDING:     0.15,
		Skill.POST:          0.10,
		Skill.REBOUNDING:    0.10,
		Skill.PASSING:       0.05
	},
	Player.Position.PF: {
		Skill.REBOUNDING:    0.25,
		Skill.POST:          0.25,
		Skill.DRIVING:       0.20,
		Skill.DEFENDING:     0.20,
		Skill.THREE_POINT:   0.10
	},
	Player.Position.C: {
		Skill.POST:          0.30,
		Skill.REBOUNDING:    0.25,
		Skill.DEFENDING:     0.25,
		Skill.DRIVING:       0.10,
		Skill.THREE_POINT:   0.10
	}
}

# ---------------------------------------------------------------------------
# Position attribute biases
# Applied to every player of that position regardless of archetype
# ---------------------------------------------------------------------------

const POSITION_BIASES = {
	Player.Position.PG: {
		# Playmaking
		"ball_handling":        +4,
		"speed_with_ball":      +3,
		"pass_vision":          +4,
		"pass_iq":              +3,
		"pass_accuracy":        +3,
		"off_ball_movement":    +1,
		# Scoring
		"three_point":          +2,
		"shot_iq":              +2,
		"mid_range":            +1,
		"close_shot":           +1,
		"layup":                +2,
		"driving_dunk":         +1,
		"standing_dunk":        -3,
		"post_hook":            -3,
		"post_fade":            -3,
		"post_control":         -4,
		# Defense
		"perimeter_defense":    +2,
		"steal":                +2,
		"pass_perception":      +2,
		"interior_defense":     -3,
		"block":                -4,
		# Rebounding
		"offensive_rebounding": -3,
		"defensive_rebounding": -2,
		# Athleticism
		"speed":                +3,
		"agility":              +3,
		"strength":             -3,
		# Mental
		"decision_making":      +2,
		"teamwork":             +1,
		"anticipation":         +1
	},
	Player.Position.SG: {
		# Scoring
		"three_point":          +4,
		"mid_range":            +3,
		"shot_iq":              +3,
		"off_ball_movement":    +3,
		"free_throw":           +2,
		"draw_foul":            +2,
		"layup":                +1,
		"close_shot":           +1,
		"driving_dunk":         +1,
		"standing_dunk":        -2,
		"post_hook":            -2,
		"post_fade":            -2,
		"post_control":         -3,
		# Playmaking
		"ball_handling":        +1,
		"speed_with_ball":      +1,
		# Defense
		"perimeter_defense":    +2,
		"interior_defense":     -2,
		"block":                -3,
		# Rebounding
		"offensive_rebounding": -2,
		"defensive_rebounding": -1,
		# Athleticism
		"speed":                +2,
		"agility":              +2,
		"strength":             -2
	},
	Player.Position.SF: {
		# Scoring — balanced, slight bias toward wing scoring
		"three_point":          +2,
		"close_shot":           +2,
		"mid_range":            +1,
		"shot_iq":              +1,
		"layup":                +1,
		"driving_dunk":         +1,
		"post_hook":            +1,
		"post_control":         +1,
		# Defense — versatile, covers both perimeter and help
		"perimeter_defense":    +2,
		"help_defense_iq":      +2,
		"defensive_iq":         +1,
		# Rebounding — moderate
		"defensive_rebounding": +1,
		"offensive_rebounding": +1,
		# Athleticism — well-rounded
		"speed":                +1,
		"strength":             +1,
		"vertical":             +1
		# No significant negatives — SF is the balanced position
	},
	Player.Position.PF: {
		# Scoring — post and close range
		"close_shot":           +3,
		"post_hook":            +4,
		"post_fade":            +3,
		"post_control":         +4,
		"standing_dunk":        +3,
		"driving_dunk":         +2,
		"offensive_rebounding": +4,
		"three_point":          -2,
		"mid_range":            -1,
		# Playmaking — limited
		"ball_handling":        -3,
		"speed_with_ball":      -2,
		"pass_vision":          -3,
		# Defense
		"interior_defense":     +3,
		"block":                +2,
		"help_defense_iq":      +2,
		"perimeter_defense":    -2,
		# Rebounding
		"defensive_rebounding": +4,
		# Athleticism
		"strength":             +4,
		"vertical":             +2,
		"speed":                -2,
		"agility":              -2
	},
	Player.Position.C: {
		# Scoring — post and rim only
		"standing_dunk":        +4,
		"post_hook":            +5,
		"post_fade":            +3,
		"post_control":         +5,
		"close_shot":           +3,
		"driving_dunk":         +1,
		"three_point":          -5,
		"mid_range":            -4,
		"layup":                -1,
		# Playmaking — very limited
		"ball_handling":        -5,
		"speed_with_ball":      -4,
		"pass_vision":          -4,
		"pass_iq":              -3,
		"off_ball_movement":    -2,
		# Defense
		"interior_defense":     +5,
		"block":                +5,
		"help_defense_iq":      +3,
		"perimeter_defense":    -4,
		"steal":                -2,
		# Rebounding
		"offensive_rebounding": +5,
		"defensive_rebounding": +5,
		# Athleticism
		"strength":             +5,
		"vertical":             +3,
		"speed":                -4,
		"agility":              -4
	}
}

# ---------------------------------------------------------------------------
# Skill group attribute biases — primary skill applies full values,
# secondary applies * SECONDARY_SKILL_MULT (0.6)
# ---------------------------------------------------------------------------

const SKILL_BIASES = {
	Skill.PASSING: {
		"pass_vision":          +5,
		"pass_iq":              +5,
		"pass_accuracy":        +4,
		"ball_handling":        +4,
		"speed_with_ball":      +3,
		"decision_making":      +2,
		"teamwork":             +2,
		"three_point":          -1,
		"post_hook":            -2,
		"post_fade":            -2,
		"post_control":         -2
	},
	Skill.SHOT_CREATING: {
		"mid_range":            +5,
		"shot_iq":              +5,
		"draw_foul":            +4,
		"close_shot":           +3,
		"layup":                +3,
		"flair":                +2,
		"ball_handling":        +2,
		"pass_vision":          -1,
		"interior_defense":     -2,
		"block":                -2
	},
	Skill.THREE_POINT: {
		"three_point":          +6,
		"off_ball_movement":    +5,
		"free_throw":           +4,
		"shot_iq":              +2,
		"ball_handling":        -1,
		"post_hook":            -3,
		"post_control":         -3,
		"interior_defense":     -2
	},
	Skill.DRIVING: {
		"driving_dunk":         +5,
		"layup":                +5,
		"close_shot":           +4,
		"speed_with_ball":      +4,
		"agility":              +3,
		"draw_foul":            +3,
		"three_point":          -2,
		"post_hook":            -2,
		"post_fade":            -2,
		"pass_vision":          -1
	},
	Skill.DEFENDING: {
		"perimeter_defense":    +5,
		"defensive_iq":         +5,
		"steal":                +4,
		"pass_perception":      +4,
		"defensive_consistency":+4,
		"help_defense_iq":      +3,
		"anticipation":         +3,
		"concentration":        +2,
		"shot_iq":              -1,
		"three_point":          -2,
		"mid_range":            -2
	},
	Skill.REBOUNDING: {
		"offensive_rebounding": +6,
		"defensive_rebounding": +6,
		"hustle":               +4,
		"vertical":             +3,
		"strength":             +3,
		"determination":        +2,
		"ball_handling":        -3,
		"three_point":          -3,
		"pass_vision":          -2
	},
	Skill.POST: {
		"post_hook":            +5,
		"post_fade":            +5,
		"post_control":         +6,
		"standing_dunk":        +4,
		"strength":             +4,
		"close_shot":           +3,
		"draw_foul":            +2,
		"three_point":          -4,
		"ball_handling":        -3,
		"speed_with_ball":      -3,
		"pass_vision":          -2
	}
}

# ---------------------------------------------------------------------------
# Age ranges by league
# ---------------------------------------------------------------------------

const NBA_AGE_RANGE       = [19, 38]
const G_LEAGUE_AGE_RANGE  = [19, 30]
const DRAFT_AGE_RANGE     = [18, 22]

# Physical attributes peak and degrade after this age
const PHYSICAL_PEAK_AGE   = 26
const MENTAL_PEAK_AGE     = 30

# ---------------------------------------------------------------------------
# Name banks
# ---------------------------------------------------------------------------

const FIRST_NAMES = [
	"James", "Marcus", "DeShawn", "Tyler", "Jordan", "Malik", "Kevin", "Chris",
	"Anthony", "Darius", "Jamal", "Devon", "Trevon", "Isaiah", "Brandon",
	"Elijah", "Cameron", "Jaylen", "Draymond", "Talen", "Nico", "Cade",
	"Tre", "Scottie", "Franz", "Paolo", "Victor", "Alperen", "Jalen", "Chet",
	"Ausar", "Amen", "Gradey", "Keyonte", "Dereck", "Bilal", "Kris",
	"Naji", "Svi", "Bismack", "Goga", "Deni", "Killian", "Leandro",
	"Terence", "Wendell", "Oshae", "Thaddeus", "Damian", "CJ", "Anfernee",
	"Zion", "Ja", "Luka", "Trae", "Shai", "Evan", "Miles", "Precious",
	"Ochai", "Keegan", "Bennedict", "Jaden", "Mark", "Jabari", "Patrick"
]

const LAST_NAMES = [
	"Johnson", "Williams", "Brown", "Davis", "Miller", "Wilson", "Moore",
	"Taylor", "Anderson", "Jackson", "Harris", "Martin", "Thompson", "White",
	"Robinson", "Walker", "Hall", "Young", "Allen", "Wright", "King", "Scott",
	"Green", "Baker", "Adams", "Nelson", "Carter", "Mitchell", "Perez", "Roberts",
	"Turner", "Phillips", "Campbell", "Parker", "Evans", "Edwards", "Collins",
	"Stewart", "Morris", "Morgan", "Reed", "Cook", "Bell", "Murphy", "Bailey",
	"Rivera", "Cooper", "Richardson", "Cox", "Howard", "Ward", "Torres", "Peterson",
	"Gray", "Ramirez", "Watson", "Brooks", "Kelly", "Sanders", "Price",
	"Bennett", "Wood", "Barnes", "Ross", "Henderson", "Coleman", "Jenkins", "Perry",
	"Butler", "Bridges", "Holiday", "George", "Leonard", "Durant", "Curry"
]

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func generate_nba_player(position: Player.Position, team_id: int) -> Player:
	var tier = _roll_tier(NBA_TIER_WEIGHTS)
	var age  = randi_range(NBA_AGE_RANGE[0], NBA_AGE_RANGE[1])
	return _build_player(position, tier, age, team_id, "nba", false)

func generate_g_league_player(position: Player.Position, team_id: int) -> Player:
	var tier = _roll_tier(G_LEAGUE_TIER_WEIGHTS)
	var age  = randi_range(G_LEAGUE_AGE_RANGE[0], G_LEAGUE_AGE_RANGE[1])
	return _build_player(position, tier, age, team_id, "g_league", false)

func generate_draft_prospect(draft_year: int) -> Player:
	var positions = [Player.Position.PG, Player.Position.SG, Player.Position.SF,
					 Player.Position.PF, Player.Position.C]
	var position  = positions[randi() % positions.size()]
	var tier      = _roll_tier(DRAFT_TIER_WEIGHTS)
	var age       = randi_range(DRAFT_AGE_RANGE[0], DRAFT_AGE_RANGE[1])
	var p         = _build_player(position, tier, age, -1, "draft", true)
	p.draft_year  = draft_year
	return p

func generate_full_nba_roster(team_id: int) -> Array:
	# 15-man roster with realistic position distribution
	# 2 PG, 2 SG, 3 SF, 3 PF, 2 C + 3 flex spots (wing/big mix)
	var slots = [
		Player.Position.PG, Player.Position.PG,
		Player.Position.SG, Player.Position.SG,
		Player.Position.SF, Player.Position.SF, Player.Position.SF,
		Player.Position.PF, Player.Position.PF, Player.Position.PF,
		Player.Position.C,  Player.Position.C,
		Player.Position.SG, Player.Position.SF, Player.Position.PF  # flex
	]
	var roster: Array = []
	for pos in slots:
		roster.append(generate_nba_player(pos, team_id))
	return roster

func generate_full_g_league_roster(team_id: int) -> Array:
	var slots = [
		Player.Position.PG, Player.Position.PG,
		Player.Position.SG, Player.Position.SG,
		Player.Position.SF, Player.Position.SF,
		Player.Position.PF, Player.Position.PF,
		Player.Position.C,  Player.Position.C
	]
	var roster: Array = []
	for pos in slots:
		roster.append(generate_g_league_player(pos, team_id))
	return roster

func generate_draft_class(draft_year: int, count: int = 60) -> Array:
	var prospects: Array = []
	for i in range(count):
		prospects.append(generate_draft_prospect(draft_year))
	return prospects

# ---------------------------------------------------------------------------
# Core player builder
# ---------------------------------------------------------------------------

func _build_player(
	position: Player.Position,
	tier: Player.Tier,
	age: int,
	team_id: int,
	league_id: String,
	is_prospect: bool
) -> Player:

	var p             = Player.new()
	p.position        = position
	p.tier            = tier
	p.age             = age
	p.team_id         = team_id
	p.league_id       = league_id
	p.is_draft_prospect = is_prospect
	p.is_free_agent   = false
	p.first_name      = FIRST_NAMES[randi() % FIRST_NAMES.size()]
	p.last_name       = LAST_NAMES[randi() % LAST_NAMES.size()]

	# Roll archetype (may return nulls if no archetype)
	var primary_skill   = -1
	var secondary_skill = -1
	if randf() < ARCHETYPE_CHANCE[tier]:
		primary_skill   = _roll_primary_skill(position)
		secondary_skill = _roll_secondary_skill(position, primary_skill)

	# Store archetype on player for reference by other systems
	p.set_meta("primary_skill",   primary_skill)
	p.set_meta("secondary_skill", secondary_skill)

	# Generate visible attributes
	_generate_visible_attributes(p, primary_skill, secondary_skill)

	# Generate hidden attributes (flat distribution, independent of tier)
	_generate_hidden_attributes(p)

	# Age-based physical degradation
	_apply_age_degradation(p)

	# Per-attribute potential deltas
	_generate_potential_deltas(p)

	# Derive overall potential marker
	p.potential = _calculate_potential_marker(p)

	return p

# ---------------------------------------------------------------------------
# Visible attribute generation
# ---------------------------------------------------------------------------

func _generate_visible_attributes(p: Player, primary_skill: int, secondary_skill: int) -> void:
	var tier_mean: float   = float(TIER_MEANS[p.tier])
	var pos_biases: Dictionary = POSITION_BIASES.get(p.position, {})

	# Build combined skill bias (primary full + secondary at 60%)
	var skill_bias: Dictionary = {}
	if primary_skill >= 0:
		var pb: Dictionary = SKILL_BIASES.get(primary_skill, {})
		for attr in pb:
			skill_bias[attr] = skill_bias.get(attr, 0) + pb[attr]

	if secondary_skill >= 0:
		var sb: Dictionary = SKILL_BIASES.get(secondary_skill, {})
		for attr in sb:
			skill_bias[attr] = skill_bias.get(attr, 0) + roundi(sb[attr] * SECONDARY_SKILL_MULT)

	# Generate each visible attribute
	var visible_attrs = Player.SCORING_ATTRS + Player.PLAYMAKING_ATTRS \
		+ Player.DEFENSE_ATTRS + Player.REBOUNDING_ATTRS \
		+ Player.ATHLETICISM_ATTRS + Player.MENTAL_ATTRS

	for attr in visible_attrs:
		var mean = tier_mean \
			+ float(pos_biases.get(attr, 0)) \
			+ float(skill_bias.get(attr, 0))
		var value = _normal_sample(mean, VISIBLE_ATTR_STD_DEV)
		p.set(attr, clampi(value, 1, 20))

# ---------------------------------------------------------------------------
# Hidden attribute generation — flat distribution, independent of tier
# Injury proneness: high = bad, so no positional bias needed
# ---------------------------------------------------------------------------

func _generate_hidden_attributes(p: Player) -> void:
	for attr in Player.HIDDEN_ATTRS:
		if attr == "potential":
			continue  # Derived later from delta system
		var value = _normal_sample(HIDDEN_ATTR_MEAN, HIDDEN_ATTR_STD_DEV)
		p.set(attr, clampi(value, 1, 20))

# ---------------------------------------------------------------------------
# Age degradation — physical attrs decay after peak age
# ---------------------------------------------------------------------------

func _apply_age_degradation(p: Player) -> void:
	if p.age <= PHYSICAL_PEAK_AGE:
		return

	var years_past = p.age - PHYSICAL_PEAK_AGE
	# ~0.6 points lost per year past peak, capped at -6
	var penalty = clampi(roundi(years_past * 0.6), 0, 6)

	var physical_attrs = ["speed", "agility", "vertical", "stamina", "driving_dunk"]
	for attr in physical_attrs:
		p.set(attr, clampi(p.get(attr) - penalty, 1, 20))

	# Older players compensate — slight boost to mental attrs
	if p.age >= MENTAL_PEAK_AGE:
		var mental_bonus = clampi(roundi((p.age - MENTAL_PEAK_AGE) * 0.3), 0, 3)
		var mental_attrs = ["anticipation", "decision_making", "pass_iq", "shot_iq", "composure"]
		for attr in mental_attrs:
			p.set(attr, clampi(p.get(attr) + mental_bonus, 1, 20))

# ---------------------------------------------------------------------------
# Delta-based potential generation
# Younger + lower tier = more growth ceiling remaining
# ---------------------------------------------------------------------------

func _generate_potential_deltas(p: Player) -> void:
	var physical_attrs = ["speed", "agility", "vertical", "stamina", "driving_dunk",
						  "strength", "overall_durability", "hustle"]

	for attr in Player.ALL_ATTR_NAMES:
		if attr == "potential":
			continue

		var is_physical = attr in physical_attrs
		var delta_range = _get_delta_range(p.age, p.tier, is_physical)
		p.potential_deltas[attr] = randi_range(delta_range[0], delta_range[1])

func _get_delta_range(age: int, tier: Player.Tier, is_physical: bool) -> Array:
	var peak      = PHYSICAL_PEAK_AGE if is_physical else MENTAL_PEAK_AGE
	var to_peak   = clampi(peak - age, 0, 8)

	var base_max = 0
	match tier:
		Player.Tier.FRINGE:    base_max = 4
		Player.Tier.ROTATION:  base_max = 5
		Player.Tier.STARTER:   base_max = 4
		Player.Tier.STAR:      base_max = 3
		Player.Tier.SUPERSTAR: base_max = 2  # Near ceiling already

	return [0, base_max + to_peak]

func _calculate_potential_marker(p: Player) -> int:
	# Peak overall if all deltas realised
	var peak_ovr = p.get_potential_overall()
	return clampi(peak_ovr - 2, 1, 20)

# ---------------------------------------------------------------------------
# Archetype rollers
# ---------------------------------------------------------------------------

func _roll_primary_skill(position: Player.Position) -> int:
	var weights: Dictionary = PRIMARY_SKILL_WEIGHTS.get(position, {})
	return _roll_weighted(weights)

func _roll_secondary_skill(position: Player.Position, primary: int) -> int:
	var available: Array  = POSITION_AVAILABLE_SKILLS.get(position, [])
	var weights: Dictionary = {}

	for skill in available:
		# Same skill as primary gets reduced weight — allowed but less common
		weights[skill] = SAME_SKILL_WEIGHT if skill == primary else 1.0

	return _roll_weighted(weights)

func _roll_weighted(weights: Dictionary) -> int:
	var total: float = 0.0
	for key in weights:
		total += weights[key]

	var roll = randf() * total
	var cumulative = 0.0
	for key in weights:
		cumulative += weights[key]
		if roll <= cumulative:
			return key

	# Fallback — return last key
	return weights.keys().back()

# ---------------------------------------------------------------------------
# Tier roller
# ---------------------------------------------------------------------------

func _roll_tier(weights: Dictionary) -> Player.Tier:
	var roll       = randf()
	var cumulative = 0.0
	for tier in weights:
		cumulative += weights[tier]
		if roll <= cumulative:
			return tier
	return Player.Tier.ROTATION

# ---------------------------------------------------------------------------
# Normal distribution sampler — Box-Muller transform
# ---------------------------------------------------------------------------

func _normal_sample(mean: float, std_dev: float) -> int:
	var u1 = maxf(randf(), 0.0001)  # Avoid log(0)
	var u2 = randf()
	var z  = sqrt(-2.0 * log(u1)) * cos(2.0 * PI * u2)
	return roundi(mean + z * std_dev)
