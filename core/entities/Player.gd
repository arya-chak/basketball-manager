class_name Player
extends RefCounted

# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

enum Position { PG, SG, SF, PF, C }
enum Tier { FRINGE, ROTATION, STARTER, STAR, SUPERSTAR }

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

var id: int = -1
var first_name: String = ""
var last_name: String = ""
var age: int = 0
var position: Position = Position.PG
var tier: Tier = Tier.ROTATION
var nationality: String = "American"
var is_free_agent: bool = false
var is_draft_prospect: bool = false
var draft_year: int = 0
var team_id: int = -1
var league_id: String = ""

# ---------------------------------------------------------------------------
# SCORING (13) — all visible
# ---------------------------------------------------------------------------

var close_shot: int = 10           # Finishing around the rim (non-dunk)
var layup: int = 10                # Layup technique and touch
var driving_dunk: int = 10         # Dunking off the dribble
var standing_dunk: int = 10        # Dunking from a standing position
var post_hook: int = 10            # Hook shot in the post
var post_fade: int = 10            # Fadeaway from the post
var post_control: int = 10         # Body control and footwork in the post
var mid_range: int = 10            # Mid-range jump shot
var three_point: int = 10          # Three-point shooting
var free_throw: int = 10           # Free throw shooting
var draw_foul: int = 10            # Ability to draw fouls on shots
var hands: int = 10                # Catching, ball security, loose ball recovery
var shot_iq: int = 10              # Shot selection — when to shoot vs pass

# ---------------------------------------------------------------------------
# PLAYMAKING (6) — all visible
# ---------------------------------------------------------------------------

var ball_handling: int = 10        # Dribbling skill and ball security
var speed_with_ball: int = 10      # Movement speed while dribbling
var pass_accuracy: int = 10        # Precision and weight of passes
var pass_vision: int = 10          # Seeing open teammates and passing lanes
var pass_iq: int = 10              # Decision-making on the ball — pick and roll reads, skip passes
var off_ball_movement: int = 10    # Cutting, screening, relocating without the ball

# ---------------------------------------------------------------------------
# DEFENSE (8) — all visible
# ---------------------------------------------------------------------------

var perimeter_defense: int = 10    # Guarding ball handlers and shooters on the perimeter
var interior_defense: int = 10     # Defending at the rim and in the paint
var help_defense_iq: int = 10      # Rotating, helping, and recovering on defense
var pass_perception: int = 10      # Reading passing lanes, deflections, anticipating passes
var steal: int = 10                # Pickpocketing, strip attempts
var block: int = 10                # Shotblocking ability and timing
var defensive_iq: int = 10         # Overall defensive awareness, positioning, schemes
var defensive_consistency: int = 10 # Sustaining defensive effort and focus across possessions

# ---------------------------------------------------------------------------
# REBOUNDING (2) — all visible
# ---------------------------------------------------------------------------

var offensive_rebounding: int = 10 # Crashing the offensive glass, tip-ins
var defensive_rebounding: int = 10 # Boxing out, securing defensive boards

# ---------------------------------------------------------------------------
# ATHLETICISM (7) — all visible
# ---------------------------------------------------------------------------

var speed: int = 10                # Straight-line running speed
var agility: int = 10              # Lateral quickness, change of direction
var strength: int = 10             # Physical power — contact, boxing out, post play
var vertical: int = 10             # Jumping ability — affects dunking, rebounding, blocking
var stamina: int = 10              # In-game endurance; degrades across quarters
var hustle: int = 10               # Effort on loose balls, charges, extra possessions
var overall_durability: int = 10   # Resistance to wear across a full season

# ---------------------------------------------------------------------------
# MENTAL (9) — all visible
# ---------------------------------------------------------------------------

var anticipation: int = 10         # Reading plays before they develop; reacting to cues
var composure: int = 10            # Performing under pressure; not affected by crowd or stakes
var concentration: int = 10        # Sustaining focus; affects error rate late in games
var decision_making: int = 10      # General reads — when to drive, kick out, trap, switch
var determination: int = 10        # Refusing to quit in-game; effort when losing or fatigued
var flair: int = 10                # Improvised plays, high-risk/reward moves, crowd appeal
var leadership: int = 10           # Inspiring teammates; affects team morale and cohesion
var teamwork: int = 10             # Willingness to make the right pass; playing within the system
var work_ethic: int = 10           # Effort in practice; drives development speed

# ---------------------------------------------------------------------------
# HIDDEN (9) — never shown to player; scouts reference indirectly in reports
# ---------------------------------------------------------------------------

var coachability: int = 10         # Receptiveness to coaching; affects scheme fit and improvement
var consistency: int = 10          # Form stability; prevents unexpected performance dips
var natural_fitness: int = 10      # Recovery speed between games; conditioning
var versatility: int = 10          # Ability to play out of natural position; learning new roles
var adaptability: int = 10         # Adjusting to new teams, cities, cultures after a move
var injury_proneness: int = 10     # HIGH = bad (FM model); likelihood of suffering injuries
var important_matches: int = 10    # HIGH = rises to the occasion; LOW = nerves in big games
var potential: int = 10            # Overall growth ceiling marker; derived from delta system

# ---------------------------------------------------------------------------
# Potential deltas — per-attribute hidden growth ceilings
# potential_deltas[attr_name] = how many more points this attribute can grow
# ---------------------------------------------------------------------------

var potential_deltas: Dictionary = {}

# ---------------------------------------------------------------------------
# Scout knowledge — 0.0 = unknown, 1.0 = fully scouted
# ---------------------------------------------------------------------------

var scout_knowledge: float = 0.0

# ---------------------------------------------------------------------------
# Attribute category constants — used for iteration, UI grouping, DB writes
# ---------------------------------------------------------------------------

const SCORING_ATTRS: Array = [
	"close_shot", "layup", "driving_dunk", "standing_dunk",
	"post_hook", "post_fade", "post_control",
	"mid_range", "three_point", "free_throw",
	"draw_foul", "hands", "shot_iq"
]

const PLAYMAKING_ATTRS: Array = [
	"ball_handling", "speed_with_ball", "pass_accuracy",
	"pass_vision", "pass_iq", "off_ball_movement"
]

const DEFENSE_ATTRS: Array = [
	"perimeter_defense", "interior_defense", "help_defense_iq",
	"pass_perception", "steal", "block", "defensive_iq", "defensive_consistency"
]

const REBOUNDING_ATTRS: Array = [
	"offensive_rebounding", "defensive_rebounding"
]

const ATHLETICISM_ATTRS: Array = [
	"speed", "agility", "strength", "vertical",
	"stamina", "hustle", "overall_durability"
]

const MENTAL_ATTRS: Array = [
	"anticipation", "composure", "concentration", "decision_making",
	"determination", "flair", "leadership", "teamwork", "work_ethic"
]

const HIDDEN_ATTRS: Array = [
	"coachability", "consistency", "natural_fitness", "versatility",
	"adaptability", "injury_proneness", "important_matches", "potential"
]

# All visible attributes (44) — what scouts can assess with noise
const VISIBLE_ATTRS: Array = SCORING_ATTRS + PLAYMAKING_ATTRS + DEFENSE_ATTRS \
	+ REBOUNDING_ATTRS + ATHLETICISM_ATTRS + MENTAL_ATTRS

# All 53 attribute names in order — canonical list for DB writes and full iteration
const ALL_ATTR_NAMES: Array = SCORING_ATTRS + PLAYMAKING_ATTRS + DEFENSE_ATTRS \
	+ REBOUNDING_ATTRS + ATHLETICISM_ATTRS + MENTAL_ATTRS + HIDDEN_ATTRS

# ---------------------------------------------------------------------------
# Identity helpers
# ---------------------------------------------------------------------------

func get_full_name() -> String:
	return "%s %s" % [first_name, last_name]

func get_position_string() -> String:
	return Position.keys()[position]

func get_tier_string() -> String:
	return Tier.keys()[tier]

# ---------------------------------------------------------------------------
# Attribute access
# get_all_attributes() returns all 53 as a flat Dictionary
# Used by match engine, development system, and DB persistence
# ---------------------------------------------------------------------------

func get_all_attributes() -> Dictionary:
	var result: Dictionary = {}
	for attr in ALL_ATTR_NAMES:
		result[attr] = get(attr)
	return result

func get_category_attributes(category: String) -> Dictionary:
	var result: Dictionary = {}
	var names: Array = []
	match category:
		"scoring":     names = SCORING_ATTRS
		"playmaking":  names = PLAYMAKING_ATTRS
		"defense":     names = DEFENSE_ATTRS
		"rebounding":  names = REBOUNDING_ATTRS
		"athleticism": names = ATHLETICISM_ATTRS
		"mental":      names = MENTAL_ATTRS
		"hidden":      names = HIDDEN_ATTRS
	for attr in names:
		result[attr] = get(attr)
	return result

# ---------------------------------------------------------------------------
# Scout-visible attributes
# Hidden attrs are NEVER returned regardless of scout_knowledge.
# Noise range: ±6 at 0.0 knowledge, ±0 at 1.0 knowledge.
# ---------------------------------------------------------------------------

func get_scouted_attributes() -> Dictionary:
	var result: Dictionary = {}
	for attr in VISIBLE_ATTRS:
		var true_val: int = get(attr)
		var max_noise: int = roundi(6.0 * (1.0 - scout_knowledge))
		var noise: int = randi_range(-max_noise, max_noise)
		result[attr] = clampi(true_val + noise, 1, 20)
	return result

# ---------------------------------------------------------------------------
# Potential peak for a single attribute (internal/dev system use only)
# ---------------------------------------------------------------------------

func get_potential_peak(attr_name: String) -> int:
	var current = get(attr_name)
	if current == null:
		return 10
	var delta = potential_deltas.get(attr_name, 0)
	return clampi(current + delta, 1, 20)

# ---------------------------------------------------------------------------
# Overall rating — position-weighted, for display only
# Simulation ALWAYS uses individual attributes directly, never OVR
# ---------------------------------------------------------------------------

func get_overall() -> int:
	return _weighted_overall(get_all_attributes())

func get_potential_overall() -> int:
	var peak_attrs = get_all_attributes()
	for attr in potential_deltas:
		if peak_attrs.has(attr):
			peak_attrs[attr] = clampi(peak_attrs[attr] + potential_deltas[attr], 1, 20)
	return _weighted_overall(peak_attrs)

func _weighted_overall(attrs: Dictionary) -> int:
	var weights = _get_position_weights()
	var total: float = 0.0
	var weight_sum: float = 0.0
	for attr in weights:
		if attrs.has(attr):
			total += attrs[attr] * weights[attr]
			weight_sum += weights[attr]
	if weight_sum == 0.0:
		return 10
	return roundi(total / weight_sum)

func _get_position_weights() -> Dictionary:
	match position:
		Position.PG:
			return {
				"ball_handling": 3.0, "speed_with_ball": 2.5, "pass_vision": 3.0,
				"pass_iq": 2.5, "pass_accuracy": 2.0, "decision_making": 2.5,
				"three_point": 2.0, "shot_iq": 2.0, "perimeter_defense": 1.5,
				"speed": 2.0, "agility": 2.0, "anticipation": 1.5,
				"teamwork": 1.5, "stamina": 1.0
			}
		Position.SG:
			return {
				"three_point": 3.0, "mid_range": 2.0, "shot_iq": 2.5,
				"off_ball_movement": 2.5, "ball_handling": 1.5, "speed_with_ball": 1.5,
				"perimeter_defense": 2.0, "speed": 1.5, "agility": 1.5,
				"free_throw": 1.5, "draw_foul": 1.5, "stamina": 1.0
			}
		Position.SF:
			return {
				"three_point": 2.0, "close_shot": 2.0, "shot_iq": 2.0,
				"perimeter_defense": 2.0, "help_defense_iq": 2.0,
				"defensive_rebounding": 1.5, "strength": 1.5, "speed": 1.5,
				"vertical": 1.5, "anticipation": 1.5, "determination": 1.0,
				"stamina": 1.0
			}
		Position.PF:
			return {
				"close_shot": 2.0, "post_hook": 2.0, "post_control": 2.0,
				"offensive_rebounding": 2.5, "defensive_rebounding": 2.5,
				"interior_defense": 2.5, "strength": 2.5, "block": 2.0,
				"vertical": 2.0, "help_defense_iq": 2.0, "three_point": 1.5
			}
		Position.C:
			return {
				"interior_defense": 3.0, "defensive_rebounding": 3.0,
				"offensive_rebounding": 2.5, "block": 2.5, "strength": 2.5,
				"standing_dunk": 2.0, "post_hook": 2.0, "post_control": 2.0,
				"vertical": 2.0, "help_defense_iq": 2.0, "free_throw": 1.0
			}
		_:
			return {}

# ---------------------------------------------------------------------------
# Serialization — flat dicts for DB writes
# ---------------------------------------------------------------------------

func to_identity_dict() -> Dictionary:
	return {
		"id":                id,
		"first_name":        first_name,
		"last_name":         last_name,
		"age":               age,
		"position":          get_position_string(),
		"tier":              get_tier_string(),
		"team_id":           team_id,
		"league_id":         league_id,
		"nationality":       nationality,
		"is_free_agent":     1 if is_free_agent else 0,
		"is_draft_prospect": 1 if is_draft_prospect else 0,
		"draft_year":        draft_year
	}

func to_attributes_dict() -> Dictionary:
	var attrs = get_all_attributes()
	attrs["player_id"] = id
	return attrs

# ---------------------------------------------------------------------------
# Deserialization — populate from DB rows
# ---------------------------------------------------------------------------

func from_dict(player_row: Dictionary, attr_row: Dictionary) -> void:
	id                = player_row.get("id", -1)
	first_name        = player_row.get("first_name", "")
	last_name         = player_row.get("last_name", "")
	age               = player_row.get("age", 0)
	position          = _parse_position(player_row.get("position", "PG"))
	tier              = _parse_tier(player_row.get("tier", "ROTATION"))
	team_id           = player_row.get("team_id", -1)
	league_id         = player_row.get("league_id", "")
	nationality       = player_row.get("nationality", "American")
	is_free_agent     = player_row.get("is_free_agent", 0) == 1
	is_draft_prospect = player_row.get("is_draft_prospect", 0) == 1
	draft_year        = player_row.get("draft_year", 0)

	# Load all 53 attributes in one loop using ALL_ATTR_NAMES
	for attr in ALL_ATTR_NAMES:
		set(attr, attr_row.get(attr, 10))

func _parse_position(s: String) -> Position:
	match s:
		"PG": return Position.PG
		"SG": return Position.SG
		"SF": return Position.SF
		"PF": return Position.PF
		"C":  return Position.C
		_:    return Position.PG

func _parse_tier(s: String) -> Tier:
	match s:
		"FRINGE":    return Tier.FRINGE
		"ROTATION":  return Tier.ROTATION
		"STARTER":   return Tier.STARTER
		"STAR":      return Tier.STAR
		"SUPERSTAR": return Tier.SUPERSTAR
		_:           return Tier.ROTATION
