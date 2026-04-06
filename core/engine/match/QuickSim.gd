class_name QuickSim
extends RefCounted

# ---------------------------------------------------------------------------
# QuickSim.gd
# Lightweight background game result generator.
#
# Produces a MatchResult-compatible dictionary for games the player is NOT
# watching. Designed to simulate an entire 30-game matchday in well under
# a frame (~1ms per game target).
#
# Does NOT use PossessionSim, ShotResolver, or RotationManager.
# Instead: derives team strength ratings from roster OVR, applies modifiers,
# rolls a score using a normal distribution (matching the design spec), and
# generates a sparse box score with key counting stats.
#
# Output is identical in structure to MatchEngine._build_match_result() so
# WorldState.record_match_result() and EventBus.match_simulated consume it
# without knowing which engine produced it. The "simulated" flag is set to
# true to distinguish it from full-engine results.
#
# Score distribution rationale (from design doc):
#   Basketball scores are high and clustered — Normal distribution, not Poisson.
#   NBA mean ≈ 113 points, std dev ≈ 11. Both teams drawn from this distribution
#   with adjustments for relative team strength and home court.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Score distribution parameters — calibrated to NBA averages.
# ---------------------------------------------------------------------------
const SCORE_MEAN:        float = 113.0
const SCORE_STD_DEV:     float = 11.0

# Home court advantage in raw points (≈3.5 points on average).
const HOME_COURT_PTS:    float = 3.5

# Strength modifier scale: OVR diff of 10 ≈ ±7 points per game.
const STRENGTH_SCALE:    float = 0.7

# Overtime probability when scores are within 3 after 4Q (crude approximation).
const OT_CHANCE:         float = 0.06
const OT_EXTRA_POINTS:   float = 6.0   # Each OT period adds ~6 pts to each team

# Quarter split weights — how total score distributes across quarters.
# Slight variance per quarter; must sum to 1.0.
const QUARTER_WEIGHTS: Array = [0.255, 0.245, 0.255, 0.245]

# ---------------------------------------------------------------------------
# Box score generation parameters.
# QuickSim generates realistic-looking counting stats for each player
# from their relevant attributes rather than running a full possession chain.
# ---------------------------------------------------------------------------

# Minutes targets by starter/bench status.
const STARTER_MINUTES: float  = 30.0
const BENCH_MINUTES:   float  = 14.0

# Stat generation scales — tuned to produce plausible per-36 rates.
const PTS_PER_OVR_SCALE:  float = 0.22    # Points per minute of overall rating
const REB_SCALE:          float = 0.012   # Rebounds per minute
const AST_SCALE:          float = 0.010   # Assists per minute
const STL_SCALE:          float = 0.004
const BLK_SCALE:          float = 0.003
const TO_SCALE:           float = 0.005
const FOUL_SCALE:         float = 0.006

# FG attempt rate and percentages — derived from attributes, not fixed.
const FGA_PER_MIN:        float = 0.55    # Attempts per minute for primary scorers
const FG_BASE_PCT:        float = 0.46    # League-average field goal percentage
const THREE_ATTEMPT_RATE: float = 0.36    # Fraction of FGA that are threes
const THREE_BASE_PCT:     float = 0.36    # Three-point base percentage
const FT_RATE:            float = 0.25    # FTA per FGA
const FT_BASE_PCT:        float = 0.78

# ---------------------------------------------------------------------------
# RNG — seeded per matchday for deterministic results.
# ---------------------------------------------------------------------------
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func seed_rng(seed_value: int) -> void:
	_rng.seed = seed_value

# ===========================================================================
# PUBLIC ENTRY POINT
# ===========================================================================

## simulate_game
## Produces a MatchResult-compatible dictionary for a background game.
## home_roster / away_roster: full Array of Player (15-man).
## schedule_entry: Dictionary with date fields and league_id.
## home_coach / away_coach: Coach objects (for pace and philosophy modifiers).
func simulate_game(
		home_team:      Team,
		away_team:      Team,
		home_roster:    Array,
		away_roster:    Array,
		schedule_entry: Dictionary,
		home_coach:     Coach = null,
		away_coach:     Coach = null) -> Dictionary:

	# --- Derive team strength ratings ---
	var home_strength: float = _calc_team_strength(home_roster)
	var away_strength: float = _calc_team_strength(away_roster)

	# --- Derive pace modifier from coaches ---
	var home_pace: float = home_coach.pref_pace_target if home_coach != null else 1.0
	var away_pace: float = away_coach.pref_pace_target if away_coach != null else 1.0
	var pace_mod:  float = (home_pace + away_pace) * 0.5   # Avg pace of the game

	# --- Roll scores ---
	var scores: Dictionary = _roll_scores(home_strength, away_strength, pace_mod)
	var home_score: int    = scores["home"]
	var away_score: int    = scores["away"]
	var ot_periods: int    = scores["ot"]

	# --- Generate quarter splits ---
	var home_quarters: Array = _split_quarters(home_score, ot_periods)
	var away_quarters: Array = _split_quarters(away_score, ot_periods)

	# --- Generate sparse box scores ---
	var home_starters: Array = _pick_starters(home_roster, home_coach)
	var away_starters: Array = _pick_starters(away_roster, away_coach)

	var box_score: Dictionary = {}
	_generate_team_box(box_score, home_roster, home_starters, home_score, true)
	_generate_team_box(box_score, away_roster, away_starters, away_score, false)

	# --- Team aggregates ---
	var home_team_stats: Dictionary = _calc_quick_team_stats(box_score, home_roster)
	var away_team_stats: Dictionary = _calc_quick_team_stats(box_score, away_roster)

	# --- Report to WorldState ---
	WorldState.record_match_result(
		home_team.id,
		away_team.id,
		home_score,
		away_score,
		schedule_entry.get("league_id", "nba")
	)

	# --- Emit signal ---
	EventBus.match_simulated.emit({
		"home_team_id": home_team.id,
		"away_team_id": away_team.id,
		"home_score":   home_score,
		"away_score":   away_score,
		"league_id":    schedule_entry.get("league_id", "nba"),
	})

	# --- Build result ---
	return {
		# Identity
		"home_team_id":   home_team.id,
		"away_team_id":   away_team.id,
		"league_id":      schedule_entry.get("league_id", "nba"),
		"date_day":       schedule_entry.get("date_day", 1),
		"date_month":     schedule_entry.get("date_month", 10),
		"date_year":      schedule_entry.get("date_year", 2025),

		# Scores
		"home_score":     home_score,
		"away_score":     away_score,
		"home_quarters":  home_quarters,
		"away_quarters":  away_quarters,

		# Player stats — sparse but structurally identical to full box score
		"player_stats":   box_score,

		# Team aggregates
		"home_team_stats": home_team_stats,
		"away_team_stats": away_team_stats,

		# Play-by-play — empty for background games
		"play_by_play":   [],

		# Metadata
		"simulated":        true,   # Flags this as a QuickSim result
		"overtime_periods": ot_periods,
		"game_seed":        _rng.seed,
	}

# ===========================================================================
# SCORE GENERATION
# ===========================================================================

## _calc_team_strength
## Derives a single float rating from roster OVR, weighted toward starters.
## Starters contribute 70% of the rating, bench 30%.
func _calc_team_strength(roster: Array) -> float:
	if roster.is_empty():
		return 70.0   # Fallback

	# Sort by OVR descending — top 5 are treated as starters.
	var sorted: Array = roster.duplicate()
	sorted.sort_custom(func(a, b): return a.get_overall() > b.get_overall())

	var starter_sum: float = 0.0
	var bench_sum:   float = 0.0

	for i in sorted.size():
		var ovr: float = float(sorted[i].get_overall())
		if i < 5:
			starter_sum += ovr
		else:
			bench_sum   += ovr

	var starter_avg: float = starter_sum / 5.0
	var bench_count: float = maxf(1.0, float(sorted.size()) - 5.0)
	var bench_avg:   float = bench_sum / bench_count

	return starter_avg * 0.70 + bench_avg * 0.30

## _roll_scores
## Generates final scores using a normal distribution.
## Each team's raw score is drawn independently, then adjusted for
## relative strength and home court before rounding.
func _roll_scores(
		home_strength: float,
		away_strength: float,
		pace_mod:      float) -> Dictionary:

	# Strength delta — positive means home team is stronger.
	var strength_delta: float = (home_strength - away_strength) * STRENGTH_SCALE

	# Draw raw scores from normal distribution.
	# Pace modifier scales the mean — faster games have more points.
	var adjusted_mean: float = SCORE_MEAN * pace_mod

	var home_raw: float = _normal(adjusted_mean + strength_delta * 0.5 + HOME_COURT_PTS,
								  SCORE_STD_DEV)
	var away_raw: float = _normal(adjusted_mean - strength_delta * 0.5,
								  SCORE_STD_DEV)

	var home_score: int = roundi(clampf(home_raw, 85.0, 145.0))
	var away_score: int = roundi(clampf(away_raw, 85.0, 145.0))

	# Ties are illegal — nudge by 1 if tied after rounding.
	if home_score == away_score:
		if _rng.randf() < 0.5:
			home_score += 1
		else:
			away_score += 1

	# Overtime — small chance if scores are very close.
	var ot_periods: int = 0
	if abs(home_score - away_score) <= 3 and _rng.randf() < OT_CHANCE:
		ot_periods = 1
		# OT adds points to both teams; winner is determined by who scores more.
		var home_ot: int = roundi(_normal(OT_EXTRA_POINTS, 2.5))
		var away_ot: int = roundi(_normal(OT_EXTRA_POINTS, 2.5))
		home_score += home_ot
		away_score += away_ot
		# Ensure no ties after OT.
		if home_score == away_score:
			if _rng.randf() < 0.5: home_score += 1
			else:                   away_score += 1

	return {"home": home_score, "away": away_score, "ot": ot_periods}

## _split_quarters
## Distributes a final score across 4 quarters (ignoring OT for split display).
## Uses weighted random splits with slight variance per quarter.
func _split_quarters(total_score: int, ot_periods: int) -> Array:
	# Subtract estimated OT contribution before splitting regular quarters.
	var reg_score: int = total_score
	if ot_periods > 0:
		reg_score = maxi(total_score - roundi(OT_EXTRA_POINTS), 70)

	var quarters: Array = [0, 0, 0, 0]
	var remaining: int  = reg_score

	for i in 3:   # First 3 quarters get a weighted random split.
		var weight:    float = QUARTER_WEIGHTS[i]
		var variance:  float = _rng.randf_range(-0.03, 0.03)
		var q_score:   int   = roundi(float(reg_score) * (weight + variance))
		q_score            = clampi(q_score, 18, 40)
		quarters[i]        = q_score
		remaining         -= q_score

	# Q4 gets the remainder — clamp to plausible range.
	quarters[3] = clampi(remaining, 18, 45)

	return quarters

# ===========================================================================
# BOX SCORE GENERATION
# ===========================================================================

## _pick_starters
## Returns the top 5 players by OVR as the simulated starting lineup.
## Uses depth chart if coach is provided and charts are populated.
func _pick_starters(roster: Array, coach: Coach) -> Array:
	if coach != null:
		# Try depth chart.
		var five: Array  = []
		var positions:   Array = ["PG", "SG", "SF", "PF", "C"]
		for pos in positions:
			var chart: Array = coach.depth_chart.get(pos, [])
			for pid in chart:
				for p in roster:
					if p.id == pid and p not in five:
						five.append(p)
						break
				if five.size() == positions.find(pos) + 1:
					break

		if five.size() == 5:
			return five

	# Fallback: top 5 by OVR.
	var sorted: Array = roster.duplicate()
	sorted.sort_custom(func(a, b): return a.get_overall() > b.get_overall())
	return sorted.slice(0, 5)

## _generate_team_box
## Generates a sparse stat line for each player on a team.
## total_team_score is used to calibrate point distribution.
func _generate_team_box(
		box_score:        Dictionary,
		roster:           Array,
		starters:         Array,
		total_team_score: int,
		is_home:          bool) -> void:

	var starter_ids: Array = []
	for p in starters:
		starter_ids.append(p.id)

	# Distribute points across players.
	# Stars get more; role players get less. Uses OVR as the weight.
	var point_pool: int = total_team_score
	var weights: Array  = []
	var weight_sum: float = 0.0

	# Only active players (starters + bench who get meaningful minutes) score.
	var active: Array = []
	for p in roster:
		var mins: float = STARTER_MINUTES if p.id in starter_ids else BENCH_MINUTES
		# Only include bench players who'd realistically get minutes.
		if p.id in starter_ids or mins >= 10.0:
			active.append(p)
			var w: float = float(p.get_overall()) * (1.5 if p.id in starter_ids else 0.7)
			weights.append(w)
			weight_sum += w

	# Assign points proportionally with noise.
	var assigned_points: Array = []
	var total_assigned:  int   = 0
	for i in active.size():
		var share: float  = weights[i] / maxf(1.0, weight_sum)
		var pts:   int    = roundi(float(point_pool) * share \
			+ _rng.randf_range(-2.5, 2.5))
		pts = maxi(0, pts)
		assigned_points.append(pts)
		total_assigned += pts

	# Correct rounding drift on the highest scorer.
	var diff: int = total_team_score - total_assigned
	if not assigned_points.is_empty():
		assigned_points[0] = maxi(0, assigned_points[0] + diff)

	# Generate full stat line per player.
	for i in active.size():
		var p:    Player = active[i]
		var pts:  int    = assigned_points[i]
		var mins: float  = STARTER_MINUTES if p.id in starter_ids \
			else _rng.randf_range(8.0, 20.0)

		box_score[p.id] = _generate_player_stats(p, pts, mins, is_home)

## _generate_player_stats
## Produces a plausible stat line for a single player given points and minutes.
func _generate_player_stats(
		player:  Player,
		points:  int,
		minutes: float,
		is_home: bool) -> Dictionary:

	# --- Shooting splits from points ---
	# Back-calculate FGA from points and estimated efficiency.
	var true_shooting_pct: float = FG_BASE_PCT \
		+ (float(player.shot_iq) - 10.0) * 0.004 \
		+ (float(player.three_point) - 10.0) * 0.002

	# FGA ≈ points / (2 × TS%) — approximation.
	var fga: int = maxi(0, roundi(float(points) / (2.0 * maxf(0.3, true_shooting_pct))))

	# Three-point attempts — driven by three_point attribute.
	var three_rate: float = clampf(
		THREE_ATTEMPT_RATE + (float(player.three_point) - 10.0) * 0.015, 0.0, 0.70
	)
	var fg3a: int = roundi(float(fga) * three_rate)
	var fg2a: int = maxi(0, fga - fg3a)

	# Makes.
	var three_pct: float = clampf(
		THREE_BASE_PCT + (float(player.three_point) - 10.0) * 0.012, 0.20, 0.55
	)
	var two_pct: float = clampf(
		0.52 + (float(player.close_shot + player.mid_range) / 2.0 - 10.0) * 0.008,
		0.35, 0.70
	)

	var fg3m: int = roundi(float(fg3a) * three_pct + _rng.randf_range(-0.5, 0.5))
	var fg2m: int = roundi(float(fg2a) * two_pct   + _rng.randf_range(-0.5, 0.5))
	fg3m = clampi(fg3m, 0, fg3a)
	fg2m = clampi(fg2m, 0, fg2a)
	var fgm: int = fg2m + fg3m

	# Free throws — fill remaining points.
	var pts_from_field: int = fg2m * 2 + fg3m * 3
	var ft_points:      int = maxi(0, points - pts_from_field)
	var ft_pct:         float = clampf(
		FT_BASE_PCT + (float(player.free_throw) - 10.0) * 0.012, 0.50, 0.98
	)
	var fta: int = roundi(float(ft_points) / maxf(0.5, ft_pct))
	var ftm: int = ft_points   # We know exactly how many he made (derived from pts)
	ftm = clampi(ftm, 0, fta)

	# --- Rebounds ---
	var reb_attr: float = float(player.defensive_rebounding + player.offensive_rebounding) / 2.0
	var total_reb: int  = roundi(minutes * REB_SCALE * (reb_attr / 10.0) \
		+ _rng.randf_range(-1.0, 1.0))
	total_reb = maxi(0, total_reb)
	var oreb: int = roundi(float(total_reb) * 0.25)   # ~25% of boards are offensive
	var dreb: int = total_reb - oreb

	# --- Other counting stats ---
	var pass_factor: float = float(player.pass_vision + player.pass_iq) / 2.0
	var ast: int = roundi(minutes * AST_SCALE * (pass_factor / 10.0) \
		+ _rng.randf_range(-0.5, 0.5))
	ast = maxi(0, ast)

	var stl: int = roundi(minutes * STL_SCALE * (float(player.steal) / 10.0) \
		+ _rng.randf_range(-0.3, 0.3))
	stl = maxi(0, stl)

	var blk: int = roundi(minutes * BLK_SCALE * (float(player.block) / 10.0) \
		+ _rng.randf_range(-0.3, 0.3))
	blk = maxi(0, blk)

	var to: int = roundi(minutes * TO_SCALE * (20.0 - float(player.decision_making)) / 10.0 \
		+ _rng.randf_range(-0.3, 0.3))
	to = maxi(0, to)

	var fouls: int = roundi(minutes * FOUL_SCALE \
		* (20.0 - float(player.defensive_consistency)) / 10.0 \
		+ _rng.randf_range(-0.5, 0.5))
	fouls = clampi(fouls, 0, 6)

	return {
		"player_id":  player.id,
		"minutes":    snappedf(minutes, 0.5),
		"points":     points,
		"rebounds":   total_reb,
		"oreb":       oreb,
		"dreb":       dreb,
		"assists":    ast,
		"steals":     stl,
		"blocks":     blk,
		"turnovers":  to,
		"fouls":      fouls,
		"fgm":        fgm,
		"fga":        fga,
		"fg3m":       fg3m,
		"fg3a":       fg3a,
		"ftm":        ftm,
		"fta":        fta,
		"plus_minus": 0,   # Not calculated in QuickSim
		"on_court":   false,
	}

# ===========================================================================
# TEAM STAT AGGREGATION
# ===========================================================================

func _calc_quick_team_stats(box_score: Dictionary, roster: Array) -> Dictionary:
	var total_to:   int = 0
	var total_oreb: int = 0
	var total_dreb: int = 0
	var total_fouls: int = 0
	var fgm:        int = 0
	var fga:        int = 0
	var total_pts:  int = 0

	for p in roster:
		if not box_score.has(p.id):
			continue
		var line: Dictionary = box_score[p.id]
		total_to    += line.get("turnovers", 0)
		total_oreb  += line.get("oreb", 0)
		total_dreb  += line.get("dreb", 0)
		total_fouls += line.get("fouls", 0)
		fgm         += line.get("fgm", 0)
		fga         += line.get("fga", 0)
		total_pts   += line.get("points", 0)

	return {
		"turnovers":  total_to,
		"oreb":       total_oreb,
		"dreb":       total_dreb,
		"fouls":      total_fouls,
		"fg_pct":     (float(fgm) / maxf(1.0, float(fga))),
		"off_rating": 0.0,   # Not meaningful without possession count
	}

# ===========================================================================
# NORMAL DISTRIBUTION SAMPLER (Box-Muller transform)
# ===========================================================================

func _normal(mean: float, std_dev: float) -> float:
	var u1: float = maxf(_rng.randf(), 0.0001)
	var u2: float = _rng.randf()
	var z:  float = sqrt(-2.0 * log(u1)) * cos(2.0 * PI * u2)
	return mean + z * std_dev
