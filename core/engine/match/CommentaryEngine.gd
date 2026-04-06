class_name CommentaryEngine
extends RefCounted

# ---------------------------------------------------------------------------
# CommentaryEngine.gd
# Converts structured play_events entries into human-readable play-by-play
# text. Called by MatchEngine after each possession completes.
#
# Design principles:
#   - Pure formatting: no simulation logic, no attribute reads, no DB access.
#   - Stateless: each call to generate_text() is independent.
#   - Varied: multiple template pools per event type; selected by RNG so the
#     same event never reads identically twice in a row.
#   - Attribute-aware flavour: Flair, clutch context, and score margin
#     influence template selection but never the outcome.
#   - Player names: resolved from WorldState at call time. CommentaryEngine
#     never stores player references.
#
# Usage:
#   var engine := CommentaryEngine.new()
#   engine.seed_rng(game_seed + 3)
#   for event in play_by_play:
#       event["text"] = engine.generate_text(event)
# ---------------------------------------------------------------------------

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func seed_rng(seed_value: int) -> void:
	_rng.seed = seed_value

# ===========================================================================
# PUBLIC ENTRY POINT
# ===========================================================================

## generate_text
## Produces a display string for a single play_by_play event entry.
## Returns an empty string for events that don't produce visible text
## (e.g. internal chain events that are filtered by the UI).
func generate_text(event: Dictionary) -> String:
	var ev:   String = event.get("event", "")
	var res:  String = event.get("result", "")
	var p1:   String = _name(event.get("primary_player_id", -1))
	var p2:   String = _name(event.get("secondary_player_id", -1))
	var clutch: bool = event.get("is_clutch", false)
	var open: float  = event.get("openness", 0.5)
	var shot: String = event.get("shot_type", "")

	match ev:
		# ── INITIATIONS ─────────────────────────────────────────────────────
		"iso":
			return _pick([
				"%s isolates on the perimeter." % p1,
				"%s calls for space and goes one-on-one." % p1,
				"%s with the ball, defenders back off." % p1,
			])

		"pick_and_roll_ballhandler":
			return _pick([
				"%s uses the screen from %s." % [p1, p2],
				"%s comes off %s's pick at the top." % [p1, p2],
				"%s attacks off the screen set by %s." % [p1, p2],
			])

		"pick_and_roll_to_roller":
			return _pick([
				"%s turns the corner and finds %s rolling to the rim." % [p1, p2],
				"%s feeds %s on the roll!" % [p1, p2],
				"%s hits %s cutting hard to the basket." % [p1, p2],
			])

		"pick_and_pop":
			return _pick([
				"%s pops to the arc — %s finds him." % [p2, p1],
				"%s screens and pops. %s delivers." % [p2, p1],
				"%s kicks it out to %s at the three-point line." % [p1, p2],
			])

		"pick_and_pop_no_pass":
			return _pick([
				"%s uses the screen but keeps it himself." % p1,
				"%s doesn't find %s and attacks on his own." % [p1, p2],
			])

		"post_entry":
			return _pick([
				"%s feeds %s in the post." % [p1, p2],
				"%s gets it down low to %s." % [p1, p2],
				"%s with the entry pass. %s has deep position." % [p1, p2],
			])

		"post_entry_deflected":
			return _pick([
				"%s tries the entry pass but %s gets a hand on it!" % [p1, p2],
				"Turnover! %s's pass into the post is deflected by %s." % [p1, p2],
			])

		"motion_entry":
			return _pick([
				"%s swings it to %s on the wing." % [p1, p2],
				"%s finds %s cutting to the corner." % [p1, p2],
				"%s with the pass. %s sets up on the wing." % [p1, p2],
			])

		"transition":
			if clutch:
				return _pick([
					"%s pushes the pace in a huge moment!" % p1,
					"%s in transition — this could be critical!" % p1,
				])
			return _pick([
				"%s pushes it up the floor." % p1,
				"%s in transition!" % p1,
				"%s leads the break." % p1,
				"%s with the fast break opportunity." % p1,
			])

		# ── NON-TERMINAL EVENTS ─────────────────────────────────────────────
		"drive_kick":
			return _pick([
				"%s drives and kicks to %s." % [p1, p2],
				"%s attacks the lane and finds %s open." % [p1, p2],
				"%s collapses the defense and dumps it to %s." % [p1, p2],
			])

		"drive_kick_turnover":
			return _pick([
				"Turnover! %s's drive is stripped by %s." % [p1, p2],
				"%s reaches in and steals the ball from %s!" % [p2, p1],
				"Stripped! %s loses it to %s on the drive." % [p1, p2],
			])

		"swing_pass":
			return _pick([
				"%s swings it to %s." % [p1, p2],
				"%s moves it — %s on the wing." % [p1, p2],
				"Ball movement. %s to %s." % [p1, p2],
			])

		"swing_pass_intercepted":
			return _pick([
				"Intercepted! %s reads the pass and takes it." % p2,
				"%s jumps the passing lane! Turnover by %s." % [p2, p1],
				"Stolen! %s anticipates %s's swing pass." % [p2, p1],
			])

		"skip_pass":
			return _pick([
				"%s skips it across the court to %s." % [p1, p2],
				"%s with the skip pass — %s on the weak side." % [p1, p2],
				"%s finds %s on the skip." % [p1, p2],
			])

		"skip_pass_intercepted":
			return _pick([
				"Intercepted! %s reads the skip pass from %s." % [p2, p1],
				"Turnover! %s gambles on the skip and wins." % p2,
			])

		"hand_off":
			return _pick([
				"%s with the dribble hand-off to %s." % [p1, p2],
				"%s hands off to %s coming by." % [p1, p2],
				"DHO — %s receives from %s." % [p2, p1],
			])

		"hand_off_stolen":
			return _pick([
				"Turnover! %s jumps the hand-off and steals it!" % p2,
				"%s anticipates the DHO and picks off the ball!" % p2,
			])

		"cut":
			return _pick([
				"%s cuts backdoor and %s finds him!" % [p2, p1],
				"%s with a beautiful cut — %s delivers." % [p2, p1],
				"%s sets up the cut and threads the needle to %s." % [p1, p2],
			])

		"cut_missed":
			return ""   # Silent — the cut just wasn't seen, no visible text needed.

		"screen_pass":
			return _pick([
				"%s sets the screen. %s curls off and receives." % [p1, p2],
				"Off-ball screen from %s frees up %s." % [p1, p2],
				"%s's screen creates a look for %s." % [p1, p2],
			])

		"screen_no_pass":
			return ""   # Silent — screen was set but ball didn't move.

		"switch_mismatch_created":
			return _pick([
				"The defense switches — %s now has a mismatch on %s." % [p2, p1],
				"Switch! %s is being guarded by %s — a potential mismatch." % [p2, p1],
			])

		# ── FLAIR PLAYS ──────────────────────────────────────────────────────
		"flair_no_look":
			return _pick([
				"%s with a no-look pass to %s!" % [p1, p2],
				"Oh! %s doesn't even look — finds %s anyway." % [p1, p2],
				"No-look from %s to %s — the crowd loves it!" % [p1, p2],
			])

		"flair_euro_step":
			return _pick([
				"%s with the euro step!" % p1,
				"%s dances through the paint with a beautiful euro step." % p1,
				"%s sells the defender with the step-through." % p1,
			])

		"flair_alley_oop":
			return _pick([
				"%s lobs it up for %s — alley-oop!" % [p1, p2],
				"%s throws the lob! %s goes up to get it!" % [p1, p2],
				"Oop! %s to %s!" % [p1, p2],
			])

		"flair_turnover":
			return _pick([
				"Turnover! %s tries something fancy and loses the ball." % p1,
				"%s gets too creative — gives it away." % p1,
				"Too flashy. %s turns it over trying to make a play." % p1,
			])

		# ── SHOT RESOLUTION ──────────────────────────────────────────────────
		"shot_resolution":
			return _shot_text(event, p1, p2, shot, res, open, clutch)

		# ── FREE THROWS ──────────────────────────────────────────────────────
		"free_throw":
			return _ft_text(event, p1)

		# ── REBOUNDS ────────────────────────────────────────────────────────
		"rebound":
			return _rebound_text(event, p1)

		# ── FOULS ───────────────────────────────────────────────────────────
		"foul_non_shooting":
			return _pick([
				"Foul on %s." % p2,
				"%s is whistled for a personal foul on %s." % [p2, p1],
				"Referee stops play — foul called on %s." % p2,
			])

		# ── SUBSTITUTIONS ───────────────────────────────────────────────────
		"substitution":
			return "%s checks in for %s." % [p1, p2]

		# ── DEFENSIVE REBOUND (from PossessionSim) ──────────────────────────
		"defensive_rebound":
			return _pick([
				"%s secures the defensive board." % p1,
				"%s pulls it down." % p1,
				"%s with the rebound." % p1,
			])

		"offensive_rebound":
			return _pick([
				"%s tips it to himself — second chance!" % p1,
				"%s crashes the glass and keeps the possession alive!" % p1,
				"Offensive rebound by %s!" % p1,
			])

	return ""

# ===========================================================================
# SHOT TEXT
# ===========================================================================

func _shot_text(
		event:  Dictionary,
		p1:     String,
		p2:     String,
		shot:   String,
		result: String,
		open:   float,
		clutch: bool) -> String:

	var points: int  = event.get("points", 0)
	var is_three: bool = shot == "three_point"
	var wide_open: bool = open >= 0.75
	var contested: bool = open <= 0.30

	match result:
		"made":
			if clutch and is_three:
				return _pick([
					"%s buries the three in the clutch! %s hits it!" % [p1, p1],
					"BIG SHOT! %s from deep — it's good!" % p1,
					"%s with a clutch three! Money!" % p1,
				])
			if clutch:
				return _pick([
					"%s converts in the clutch! %s with the basket!" % [p1, p1],
					"%s comes through when it matters! Good!" % p1,
					"Clutch bucket by %s!" % p1,
				])
			if is_three and wide_open:
				return _pick([
					"%s is wide open from deep — SPLASH!" % p1,
					"%s catches and fires — good!" % p1,
					"Open three for %s — he buries it." % p1,
				])
			if is_three:
				return _pick([
					"%s pulls up for the three — it's good!" % p1,
					"%s from downtown — splash!" % p1,
					"%s knocks it down from three." % p1,
				])
			match shot:
				"driving_dunk":
					return _pick([
						"%s throws it down!" % p1,
						"%s with the emphatic dunk!" % p1,
						"DUNK! %s hammers it home." % p1,
					])
				"standing_dunk":
					return _pick([
						"%s powers it in." % p1,
						"%s dunks it over the defense!" % p1,
					])
				"layup":
					if wide_open:
						return _pick([
							"%s lays it in untouched." % p1,
							"%s with an easy layup." % p1,
						])
					return _pick([
						"%s finishes through contact!" % p1,
						"%s scoops it in." % p1,
						"%s with the tough layup — good!" % p1,
					])
				"post_hook":
					return _pick([
						"%s drops in the hook!" % p1,
						"%s with the hook shot — it falls!" % p1,
						"%s rises for the hook — good!" % p1,
					])
				"post_fade":
					return _pick([
						"%s fades away — it's good!" % p1,
						"%s drains the fadeaway." % p1,
						"%s with a beautiful fade — got it." % p1,
					])
				"mid_range":
					if contested:
						return _pick([
							"%s pulls up over the outstretched hand — it drops!" % p1,
							"%s hits the tough mid-range." % p1,
						])
					return _pick([
						"%s pulls up from mid-range — good." % p1,
						"%s with the elbow jumper — it's good!" % p1,
						"%s drains the mid-range." % p1,
					])
				"close_shot":
					return _pick([
						"%s finishes around the rim." % p1,
						"%s with the tough finish — it's good!" % p1,
					])
			return "%s scores!" % p1

		"missed":
			if is_three and wide_open:
				return _pick([
					"%s had it wide open from three — it rattles out." % p1,
					"%s bricks the open three." % p1,
					"%s open from deep — no good." % p1,
				])
			if is_three:
				return _pick([
					"%s fires from deep — no good." % p1,
					"%s's three-point attempt is off the mark." % p1,
					"%s misses from downtown." % p1,
				])
			match shot:
				"layup":
					if contested:
						return _pick([
							"%s can't convert through the traffic." % p1,
							"%s's layup rattles out." % p1,
						])
					return _pick([
						"%s misses the layup." % p1,
						"%s can't finish — no good." % p1,
					])
				"driving_dunk":
					return _pick([
						"%s can't throw it down — the shot rims out." % p1,
						"%s's dunk attempt is rejected by the rim." % p1,
					])
				"post_hook":
					return _pick([
						"%s's hook doesn't fall." % p1,
						"%s misses the hook shot." % p1,
					])
				"post_fade":
					return _pick([
						"%s's fadeaway is short." % p1,
						"%s fades away but misses." % p1,
					])
				"mid_range":
					return _pick([
						"%s pulls up but it's off." % p1,
						"%s's mid-range attempt is long." % p1,
					])
			return "%s's shot is no good." % p1

		"blocked":
			if p2 != "?":
				return _pick([
					"BLOCKED by %s!" % p2,
					"%s rejects %s's shot!" % [p2, p1],
					"%s gets a piece of it — blocked!" % p2,
					"%s swats it away!" % p2,
				])
			return "The shot is blocked!"

		"and_one":
			if is_three:
				return _pick([
					"FOUR POINT PLAY! %s hits the three AND draws the foul!" % p1,
					"%s completes the four-point play!" % p1,
				])
			if clutch:
				return _pick([
					"AND ONE! %s converts through the foul in the clutch!" % p1,
					"And one! %s scores AND draws the foul — huge play!" % p1,
				])
			return _pick([
				"AND ONE! %s scores through the contact!" % p1,
				"%s draws the foul and makes it! And one!" % p1,
				"%s gets the bucket and the foul!" % p1,
			])

		"foul_shooting":
			match shot:
				"three_point":
					return _pick([
						"%s is fouled on the three-point attempt. Three shots." % p1,
						"Foul! %s goes to the line for three." % p1,
					])
				_:
					return _pick([
						"%s is fouled on the shot. Two shots." % p1,
						"Foul! %s heads to the line." % p1,
						"%s draws the shooting foul. Two free throws." % p1,
					])

	return ""

# ===========================================================================
# FREE THROW TEXT
# ===========================================================================

func _ft_text(event: Dictionary, shooter: String) -> String:
	var result:   String = event.get("result", "")
	var ft_num:   int    = event.get("ft_number", 1)
	var ft_total: int    = event.get("ft_total", 2)
	var is_last:  bool   = ft_num == ft_total
	var is_clutch: bool  = event.get("is_clutch", false)

	if result == "made":
		if is_clutch and is_last:
			return _pick([
				"%s buries the free throw — ice in his veins." % shooter,
				"%s hits it when it matters most. %d for %d." % [shooter, ft_num, ft_total],
			])
		return _pick([
			"%s converts. %d of %d." % [shooter, ft_num, ft_total],
			"%s hits the free throw. %d/%d." % [shooter, ft_num, ft_total],
			"Good. %s makes it. %d for %d." % [shooter, ft_num, ft_total],
		])
	else:
		if is_clutch and is_last:
			return _pick([
				"%s MISSES the free throw! Huge miss in the clutch!" % shooter,
				"%s can't make it — the crowd erupts!" % shooter,
			])
		return _pick([
			"%s misses. %d of %d." % [shooter, ft_num, ft_total],
			"Off the rim — %s misses the free throw." % shooter,
			"No good. %s can't convert. %d/%d." % [shooter, ft_num, ft_total],
		])

# ===========================================================================
# REBOUND TEXT
# ===========================================================================

func _rebound_text(event: Dictionary, rebounder: String) -> String:
	var reb_type: String = event.get("rebound_type", "defensive")

	if reb_type == "offensive":
		return _pick([
			"Offensive rebound by %s — second chance!" % rebounder,
			"%s crashes the glass and keeps it alive!" % rebounder,
			"%s tips it back — they get another shot!" % rebounder,
		])
	else:
		return _pick([
			"%s with the defensive rebound." % rebounder,
			"%s pulls it down. Possession change." % rebounder,
			"%s secures the board." % rebounder,
		])

# ===========================================================================
# CLOCK DISPLAY
# ===========================================================================

## format_clock
## Converts remaining clock_seconds in a quarter to a display string.
## e.g. 437 → "7:17", 0 → "0:00"
func format_clock(clock_seconds: int) -> String:
	var seconds: int = clampi(clock_seconds, 0, 720)
	var mins:    int = seconds / 60
	var secs:    int = seconds % 60
	return "%d:%02d" % [mins, secs]

## format_quarter
## Converts quarter number to display string: 1→"1st Qtr", 5→"OT", 6→"2OT"
func format_quarter(quarter: int) -> String:
	match quarter:
		1: return "1st Qtr"
		2: return "2nd Qtr"
		3: return "3rd Qtr"
		4: return "4th Qtr"
		5: return "OT"
		_: return "%dOT" % (quarter - 4)

# ===========================================================================
# FULL MATCH ANNOTATION PASS
# ===========================================================================

## annotate_play_by_play
## Runs through an entire play_by_play array (as returned in MatchResult) and
## fills the "text" field on every entry. Also adds "clock_display" and
## "quarter_display" convenience fields.
## Call this once after MatchEngine returns — before handing the result to the UI.
func annotate_play_by_play(play_by_play: Array) -> void:
	for event in play_by_play:
		event["text"]            = generate_text(event)
		event["clock_display"]   = format_clock(event.get("clock_seconds", 0))
		event["quarter_display"] = format_quarter(event.get("quarter", 1))

# ===========================================================================
# PLAYER NAME RESOLUTION
# ===========================================================================

## _name
## Resolves a player id to a display name string.
## Falls back to "?" if the player is not found (e.g. -1 for no secondary).
func _name(player_id: int) -> String:
	if player_id < 0:
		return "?"
	var player: Player = WorldState.get_player(player_id)
	if player == null:
		return "Player %d" % player_id
	# Use last name only for play-by-play — feels like a real broadcast.
	return player.last_name

# ===========================================================================
# WEIGHTED RANDOM TEMPLATE PICKER
# ===========================================================================

## _pick
## Picks a random entry from an array of template strings.
## Uses the internal RNG so selections are seeded and reproducible.
func _pick(options: Array) -> String:
	if options.is_empty():
		return ""
	return options[_rng.randi() % options.size()]
