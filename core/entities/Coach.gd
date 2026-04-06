class_name Coach
extends RefCounted

# ---------------------------------------------------------------------------
# Coach.gd
# The coach entity. Stores identity, reputation, coaching attributes,
# style choices, personality, and persistent tactical preferences.
#
# Coaching attributes are stored as integers 1–5, mapped to descriptive
# labels for UI display (Poor / Average / Good / Very Good / Outstanding).
# This matches the design spec — the player never sees a raw number.
#
# This entity is loaded into WorldState at game start (player's coach)
# and also instantiated for every AI head coach in the league.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

enum CoachingStyle {
	OFFENSIVE_MASTERMIND,
	DEFENSIVE_ARCHITECT,
	PLAYER_DEVELOPER,
	PACE_AND_SPACE,
	SYSTEM_BUILDER,
	PLAYERS_COACH,
	ANALYST,
	ENTERTAINER,
}

enum Personality {
	DRIVEN,
	DISCIPLINED,
	PLAYERS_ADVOCATE,
	RESILIENT,
	INSPIRATIONAL,
	ACCOMPLISHED,
}

# Offensive philosophy — drives PossessionSim initiation weights.
enum OffensePhilosophy {
	PACE_AND_SPACE,    # High tempo, threes, spread floor
	ISO_HEAVY,         # Star player isolation; fewer ball-movement events
	POST_UP,           # Route through the post; bigs get touches
	BALL_MOVEMENT,     # Motion, swing passes, high assist rate
	TRANSITION_FIRST,  # Push pace off every defensive rebound / steal
}

# Defensive philosophy — drives assignment model and help coverage.
enum DefensePhilosophy {
	MAN_TO_MAN,        # Default positional matching
	ZONE_2_3,          # Zone shell; no individual assignments; open corners
	SWITCHING,         # Switch all screens; mismatch exposure
	PACK_THE_PAINT,    # Collapse interior; concede perimeter deliberately
	PRESS,             # Full-court; high steal upside, bust-out risk
}

# Attribute level descriptors — used for UI display only.
const ATTR_LABELS: Array = ["Poor", "Average", "Good", "Very Good", "Outstanding"]

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

var id: int             = -1
var first_name: String  = ""
var last_name: String   = ""
var age: int            = 40
var nationality: String = "American"
var is_player_coach: bool = false   # True for the human player's coach

# ---------------------------------------------------------------------------
# Reputation
# ---------------------------------------------------------------------------

var reputation: int       = 0    # 0–100 global reputation
var nba_reputation: int   = 0    # Tier-specific reputations (don't directly
var g_league_reputation: int = 0 # transfer — built independently)
var career_wins: int      = 0
var career_losses: int    = 0
var playoff_appearances: int = 0
var championships: int    = 0

# ---------------------------------------------------------------------------
# Current job
# ---------------------------------------------------------------------------

var team_id: String       = ""
var league_id: String     = ""
var contract_years: int   = 0
var contract_salary: float = 0.0
var seasons_at_club: int  = 0

# ---------------------------------------------------------------------------
# COACHING ATTRIBUTES (1–5)
# Set by creation choices; can improve over time through experience.
# ---------------------------------------------------------------------------

var offensive_systems: int      = 2   # Quality of offensive schemes run
var defensive_systems: int      = 2   # Quality of defensive schemes run
var player_development: int     = 2   # Accelerates player growth
var scouting: int               = 2   # Accuracy of player evaluation
var motivation: int             = 2   # Pre/post-game team talk effectiveness
var tactical_flexibility: int   = 2   # Mismatch detection; mid-game adjustments
var fitness_conditioning: int   = 2   # Player stamina degradation rate
var working_with_youth: int     = 2   # Development bonus for young players

# ---------------------------------------------------------------------------
# MENTAL ATTRIBUTES (1–5)
# ---------------------------------------------------------------------------

var adaptability: int     = 2    # Adjusting to new rosters and situations
var authority: int        = 2    # Locker room control; player discipline
var determination: int    = 2    # Keeps pressure from affecting performance
var people_management: int = 2   # Player relationships; morale management
var motivating: int       = 2    # In-game player shouts effectiveness

# ---------------------------------------------------------------------------
# Style & personality — set during coach creation, immutable after.
# Up to 3 styles, up to 2 personalities.
# ---------------------------------------------------------------------------

var styles: Array       = []   # Array of CoachingStyle enum values
var personalities: Array = []  # Array of Personality enum values

# ---------------------------------------------------------------------------
# Preferred philosophies — derived from styles at creation,
# but the player can adjust them from the tactics screen.
# These are the persistent defaults that CoachTactics reads at match start.
# ---------------------------------------------------------------------------

var preferred_offense: OffensePhilosophy = OffensePhilosophy.BALL_MOVEMENT
var preferred_defense: DefensePhilosophy = DefensePhilosophy.MAN_TO_MAN

# ---------------------------------------------------------------------------
# Persistent tactical preferences
# Saved between matches; overridable per game from the tactics screen.
# ---------------------------------------------------------------------------

var pref_pace_target: float       = 1.0    # 0.8 (slow) – 1.2 (push pace)
var pref_hunt_mismatches: bool    = true
var pref_switch_on_screens: bool  = false
var pref_paint_protection: bool   = false
var pref_press_full_court: bool   = false

# Per-position minutes targets — set in the squad screen.
# Dictionary: position string -> target minutes per game (0–48)
var minutes_targets: Dictionary = {
	"PG": 32, "SG": 32, "SF": 30, "PF": 28, "C": 26
}

# Depth chart — ordered list of player IDs per position.
# RotationManager reads this to determine substitution order.
# Dictionary: position string -> Array of player_ids (starter first)
var depth_chart: Dictionary = {
	"PG": [], "SG": [], "SF": [], "PF": [], "C": []
}

# ---------------------------------------------------------------------------
# Attribute label helpers (for UI)
# ---------------------------------------------------------------------------

func get_attr_label(value: int) -> String:
	return ATTR_LABELS[clampi(value - 1, 0, 4)]

func get_offensive_systems_label() -> String:  return get_attr_label(offensive_systems)
func get_defensive_systems_label() -> String:  return get_attr_label(defensive_systems)
func get_tactical_flexibility_label() -> String: return get_attr_label(tactical_flexibility)
func get_motivation_label() -> String:         return get_attr_label(motivation)

# ---------------------------------------------------------------------------
# Derived sim-facing values
# These convert the 1–5 descriptive attributes into float multipliers
# used by CoachTactics when building the match state.
# ---------------------------------------------------------------------------

## Returns a 0.0–1.0 quality score for how well the coach runs their offense.
## High Offensive Systems = philosophy weights are clean and reliable.
## Low = significant noise drift from the intended system.
func get_offense_execution_quality() -> float:
	return (offensive_systems - 1) / 4.0

## Returns a 0.0–1.0 quality score for defensive scheme execution.
func get_defense_execution_quality() -> float:
	return (defensive_systems - 1) / 4.0

## Returns a 0.0–1.0 score for how well the coach reads and exploits mismatches.
## Gates both mismatch detection rate and exploitation weight in PossessionSim.
func get_tactical_read_quality() -> float:
	return (tactical_flexibility - 1) / 4.0

## Returns a flat motivation bonus (0.0–3.0) applied to all player attributes
## at match start. Represents pre-game team talk quality.
## Scales with both Motivation and Motivating attributes.
func get_motivation_bonus() -> float:
	return ((motivation + motivating) - 2) * 0.375   # Range: 0.0 – 3.0

## Returns a stamina drain modifier — fitness_conditioning reduces fatigue rate.
## 1.0 = baseline drain. High conditioning = less fatigue across quarters.
func get_stamina_drain_modifier() -> float:
	return 1.0 - (fitness_conditioning - 1) * 0.08   # Range: 0.68 – 1.0

# ---------------------------------------------------------------------------
# Style application — called at creation to set philosophies and attr bonuses.
# Each style adds to attributes and may set a preferred philosophy.
# Fewer styles = deeper focus (bonuses applied fully).
# More styles = versatile but diluted (bonuses halved at 3 styles).
# ---------------------------------------------------------------------------

func apply_styles(chosen_styles: Array) -> void:
	styles = chosen_styles
	var dilution: float = 1.0 if chosen_styles.size() <= 2 else 0.6

	for style in chosen_styles:
		match style:
			CoachingStyle.OFFENSIVE_MASTERMIND:
				offensive_systems    = clampi(offensive_systems + roundi(2 * dilution), 1, 5)
				tactical_flexibility = clampi(tactical_flexibility + roundi(1 * dilution), 1, 5)
				# No philosophy lock — mastermind adapts to personnel.

			CoachingStyle.DEFENSIVE_ARCHITECT:
				defensive_systems    = clampi(defensive_systems + roundi(2 * dilution), 1, 5)
				tactical_flexibility = clampi(tactical_flexibility + roundi(1 * dilution), 1, 5)
				if preferred_defense == DefensePhilosophy.MAN_TO_MAN:
					preferred_defense = DefensePhilosophy.MAN_TO_MAN  # Stays man, runs it well.

			CoachingStyle.PLAYER_DEVELOPER:
				player_development  = clampi(player_development + roundi(2 * dilution), 1, 5)
				working_with_youth  = clampi(working_with_youth + roundi(2 * dilution), 1, 5)

			CoachingStyle.PACE_AND_SPACE:
				offensive_systems   = clampi(offensive_systems + roundi(1 * dilution), 1, 5)
				preferred_offense   = OffensePhilosophy.PACE_AND_SPACE
				pref_pace_target    = minf(pref_pace_target + 0.15 * dilution, 1.2)

			CoachingStyle.SYSTEM_BUILDER:
				defensive_systems   = clampi(defensive_systems + roundi(1 * dilution), 1, 5)
				tactical_flexibility = clampi(tactical_flexibility + roundi(1 * dilution), 1, 5)
				# System builders run rigid schemes — low noise in execution.

			CoachingStyle.PLAYERS_COACH:
				people_management   = clampi(people_management + roundi(2 * dilution), 1, 5)
				motivating          = clampi(motivating + roundi(2 * dilution), 1, 5)

			CoachingStyle.ANALYST:
				tactical_flexibility = clampi(tactical_flexibility + roundi(2 * dilution), 1, 5)
				scouting             = clampi(scouting + roundi(1 * dilution), 1, 5)
				pref_hunt_mismatches = true   # Analysts always hunt mismatches.

			CoachingStyle.ENTERTAINER:
				offensive_systems   = clampi(offensive_systems + roundi(1 * dilution), 1, 5)
				motivating          = clampi(motivating + roundi(1 * dilution), 1, 5)
				preferred_offense   = OffensePhilosophy.PACE_AND_SPACE
				pref_pace_target    = minf(pref_pace_target + 0.10 * dilution, 1.2)

func apply_personalities(chosen_personalities: Array) -> void:
	personalities = chosen_personalities
	for p in chosen_personalities:
		match p:
			Personality.DRIVEN:
				authority     = clampi(authority + 1, 1, 5)
				determination = clampi(determination + 1, 1, 5)

			Personality.DISCIPLINED:
				authority          = clampi(authority + 1, 1, 5)
				preferred_defense  = DefensePhilosophy.MAN_TO_MAN  # Disciplined = tight man.
				pref_switch_on_screens = false

			Personality.PLAYERS_ADVOCATE:
				people_management  = clampi(people_management + 1, 1, 5)
				motivating         = clampi(motivating + 1, 1, 5)

			Personality.RESILIENT:
				determination  = clampi(determination + 1, 1, 5)
				adaptability   = clampi(adaptability + 1, 1, 5)

			Personality.INSPIRATIONAL:
				motivating = clampi(motivating + 1, 1, 5)
				authority  = clampi(authority + 1, 1, 5)

			Personality.ACCOMPLISHED:
				adaptability = clampi(adaptability + 1, 1, 5)
				# Reputation multiplier handled by the creation formula, not here.

# ---------------------------------------------------------------------------
# Qualification bonus — called at creation with the chosen qualification tier.
# 0 = none, 1 = bronze, 2 = silver, 3 = gold
# ---------------------------------------------------------------------------

func apply_qualification(tier: int) -> void:
	match tier:
		0:  # No qualifications — attrs stay at Poor–Average
			pass
		1:  # Bronze — Average across the board
			offensive_systems    = maxi(offensive_systems, 2)
			defensive_systems    = maxi(defensive_systems, 2)
			tactical_flexibility = maxi(tactical_flexibility, 2)
			motivation           = maxi(motivation, 2)
			scouting             = maxi(scouting, 2)
		2:  # Silver — most attrs Average–Good
			offensive_systems    = maxi(offensive_systems, 3)
			defensive_systems    = maxi(defensive_systems, 3)
			tactical_flexibility = maxi(tactical_flexibility, 2)
			motivation           = maxi(motivation, 3)
			scouting             = maxi(scouting, 2)
			fitness_conditioning = maxi(fitness_conditioning, 2)
		3:  # Gold — all coaching attrs Good–Very Good
			offensive_systems    = maxi(offensive_systems, 3)
			defensive_systems    = maxi(defensive_systems, 3)
			tactical_flexibility = maxi(tactical_flexibility, 3)
			motivation           = maxi(motivation, 3)
			scouting             = maxi(scouting, 3)
			fitness_conditioning = maxi(fitness_conditioning, 3)
			player_development   = maxi(player_development, 3)
			working_with_youth   = maxi(working_with_youth, 3)

# ---------------------------------------------------------------------------
# Full name helper
# ---------------------------------------------------------------------------

func get_full_name() -> String:
	return "%s %s" % [first_name, last_name]

# ---------------------------------------------------------------------------
# Serialization — for DB persistence
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"id":                    id,
		"first_name":            first_name,
		"last_name":             last_name,
		"age":                   age,
		"nationality":           nationality,
		"is_player_coach":       1 if is_player_coach else 0,
		"reputation":            reputation,
		"nba_reputation":        nba_reputation,
		"g_league_reputation":   g_league_reputation,
		"career_wins":           career_wins,
		"career_losses":         career_losses,
		"playoff_appearances":   playoff_appearances,
		"championships":         championships,
		"team_id":               team_id,
		"league_id":             league_id,
		"contract_years":        contract_years,
		"contract_salary":       contract_salary,
		"seasons_at_club":       seasons_at_club,
		# Coaching attrs
		"offensive_systems":     offensive_systems,
		"defensive_systems":     defensive_systems,
		"player_development":    player_development,
		"scouting":              scouting,
		"motivation":            motivation,
		"tactical_flexibility":  tactical_flexibility,
		"fitness_conditioning":  fitness_conditioning,
		"working_with_youth":    working_with_youth,
		# Mental attrs
		"adaptability":          adaptability,
		"authority":             authority,
		"determination":         determination,
		"people_management":     people_management,
		"motivating":            motivating,
		# Philosophies and prefs
		"preferred_offense":     preferred_offense,
		"preferred_defense":     preferred_defense,
		"pref_pace_target":      pref_pace_target,
		"pref_hunt_mismatches":  1 if pref_hunt_mismatches else 0,
		"pref_switch_on_screens": 1 if pref_switch_on_screens else 0,
		"pref_paint_protection": 1 if pref_paint_protection else 0,
		"pref_press_full_court": 1 if pref_press_full_court else 0,
	}

func from_dict(d: Dictionary) -> void:
	id                  = d.get("id", -1)
	first_name          = d.get("first_name", "")
	last_name           = d.get("last_name", "")
	age                 = d.get("age", 40)
	nationality         = d.get("nationality", "American")
	is_player_coach     = d.get("is_player_coach", 0) == 1
	reputation          = d.get("reputation", 0)
	nba_reputation      = d.get("nba_reputation", 0)
	g_league_reputation = d.get("g_league_reputation", 0)
	career_wins         = d.get("career_wins", 0)
	career_losses       = d.get("career_losses", 0)
	playoff_appearances = d.get("playoff_appearances", 0)
	championships       = d.get("championships", 0)
	team_id             = d.get("team_id", "")
	league_id           = d.get("league_id", "")
	contract_years      = d.get("contract_years", 0)
	contract_salary     = d.get("contract_salary", 0.0)
	seasons_at_club     = d.get("seasons_at_club", 0)
	offensive_systems   = d.get("offensive_systems", 2)
	defensive_systems   = d.get("defensive_systems", 2)
	player_development  = d.get("player_development", 2)
	scouting            = d.get("scouting", 2)
	motivation          = d.get("motivation", 2)
	tactical_flexibility = d.get("tactical_flexibility", 2)
	fitness_conditioning = d.get("fitness_conditioning", 2)
	working_with_youth  = d.get("working_with_youth", 2)
	adaptability        = d.get("adaptability", 2)
	authority           = d.get("authority", 2)
	determination       = d.get("determination", 2)
	people_management   = d.get("people_management", 2)
	motivating          = d.get("motivating", 2)
	preferred_offense   = d.get("preferred_offense", OffensePhilosophy.BALL_MOVEMENT)
	preferred_defense   = d.get("preferred_defense", DefensePhilosophy.MAN_TO_MAN)
	pref_pace_target    = d.get("pref_pace_target", 1.0)
	pref_hunt_mismatches   = d.get("pref_hunt_mismatches", 1) == 1
	pref_switch_on_screens = d.get("pref_switch_on_screens", 0) == 1
	pref_paint_protection  = d.get("pref_paint_protection", 0) == 1
	pref_press_full_court  = d.get("pref_press_full_court", 0) == 1
