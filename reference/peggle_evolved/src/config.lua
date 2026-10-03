local Config = {
	-- Level
	current_level_name = "level1",
	-- Display
	window_width = 1920,
	window_height = 1080,
	fullscreen = true,
	virtual_width = 1200,
	virtual_height = 1900,
	background_color = { 0.1, 0.1, 0.15 },

	-- Physics simulation
	fixed_dt = 1 / 60,
	gravity = 1000,
	restitution = 0.8, -- Global bounce factor
	wall_damping = 0.8, -- Speed retained when hitting a wall
	bounce_min_normal_speed = 200, -- px/s: normal approach below which a contact settles (not classified as a bounce)
	settle_restitution = 0.2, -- reduced restitution for settling contacts (non-zero so wedges still eject)
	graze_tolerance = 0.5, -- Pixels of visual overlap to count as a hit without interrupting trajectory
	toi_epsilon = 1e-9, -- near-simultaneous tie-break window (seconds)
	safe_t_margin = 0.001, -- time pulled back from impact to avoid re-sticking
	overlap_push_margin = 0.1, -- extra pixels to push out when overlapping
	annular_cap_epsilon = 0.01, -- tolerance for cap endpoint radius check
	rotation_sweep_arc_px = 0.5, -- max surface arc (px) a rotating peg may travel per sweep slice
	rotation_sweep_max_slices = 32, -- cap on sweep sub-steps per rotating peg per iteration

	-- Ball settings
	ball_radius = 6,
	ball_color = { 0.9, 0.9, 0.9 },
	launch_speed = 800,
	-- Ball-ball collisions: launched balls are swept against each other as
	-- equal-mass circles. Set false to restore the legacy pass-through
	-- behavior (A/B diagnostics).
	ball_ball_collisions = true,
	ball_ball_restitution = 0.8, -- restitution for ball-ball impacts

	-- Aim settings
	aim_angle_limit = math.rad(180 / 2), -- 85 degrees left and right from straight down
	aim_fine_adjust_speed = math.rad(30), -- radians per second for arrow keys
	aim_wheel_adjust = math.rad(2), -- radians per wheel click
	aim_discretization_steps = 1800, -- finite number of angles in the 180 degree arc (nil to disable)

	-- Peg settings
	peg_radius = 10,
	peg_rect_width = 30,
	peg_rect_height = 12,

	-- Peg types: color shown when unlit, plus point value.
	-- The total score is (sum of hit pegs' values) * (number of hit pegs).
	peg_types = {
		blue = { color = { 0.30, 0.55, 1.00 }, value = 10 },
		red = { color = { 1.00, 0.30, 0.30 }, value = 100 },
		purple = { color = { 0.70, 0.30, 1.00 }, value = 500 },
		green = { color = { 0.30, 1.00, 0.45 }, value = 10 },
	},
	default_peg_type = "blue",

	-- How many blue pegs are promoted to purple at the start of each turn.
	-- If fewer blue pegs remain in the queue, all remaining are promoted.
	purple_pegs_per_turn = 1,

	-- How far an unlit peg color is blended toward white when it lights up on hit.
	peg_lit_blend = 0.6,

	-- End-of-turn clearing: lit pegs vanish (in hit order) once the turn stalls.
	ball_still_speed = 18, -- speed (px/s) below which the ball counts as "still"
	clear_still_time = 0.6, -- seconds the ball must stay still before clearing
	clear_no_score_time = 10.5, -- seconds without scoring a point before clearing
	peg_vanish_interval = 0.08, -- delay between each peg vanishing in the cascade
	ball_wake_speed_multiplier = 1.5, -- an idle ball must exceed ball_still_speed × this to reactivate (wake hysteresis)

	-- Bucket: a catcher that slides back and forth along the (open) floor.
	-- The ball falls through the bottom of the scene; landing in the hole scores a bonus.
	bucket_hole = 70, -- width of the catch opening (the ball fits through here)
	bucket_edge = 12, -- width of each solid side wall (edge size)
	bucket_height = 26, -- vertical size of the bucket
	bucket_accel_multiplier = 0.15, -- multiplier for the level-generated acceleration
	bucket_margin = 30, -- distance from the bottom of the screen to the bucket's top
	bucket_color = { 0.85, 0.72, 0.28 },
	bucket_bonus = 10000, -- extra points awarded for catching the ball
	bucket_incremental_base = 2500, -- points per bucket catch in 1v1 mode (multiplied by catch count)
	fever_bucket_raise_speed = 300, -- px/s, speed at which fever buckets rise from below the screen

	-- Gameplay
	starting_balls = 10, -- balls per player in solo and 1v1 modes

	-- Circuit speedup
	circuit_speedup_multiplier = 5,

	-- How far below the scene the ball must fall before the turn ends (a miss).
	fall_out_margin = 80,

	-- Style-shot recognition thresholds (distances in pixels, points in score).
	-- Distances are measured between consecutive chain-eligible scoring peg
	-- impact positions (not peg centres) for the same ball within a shot.
	long_shot_distance = 400,
	super_long_shot_distance = 700,
	off_the_wall_min_distance = 150, -- min impact distance from a side wall
	long_shot_points = 1000,
	super_long_shot_points = 5000,
	double_long_shot_points = 2000,
	lucky_bounce_points = 2500,
	off_the_wall_points = 5000,

	-- Slide: consecutive scoring contacts on adjacent zero-gap line pegs of
	-- one line, all without an intervening bounce. Awarded once per ball and
	-- line per shot when the run reaches slide_min_pegs scored pegs.
	slide_min_pegs = 5,
	slide_points = 5000,

	-- Slide (valley) direction inversion: when a ball is trapped sliding in a
	-- concave zero-gap line it oscillates like a pendulum. At each apex the
	-- lowest already-hit peg(s) of that line are removed from the board so the
	-- ball falls out instead of scoring extra pegs.
	slide_invert_contact_timeout = 0.3, -- s: no zero-gap contact this long ends the slide
	slide_invert_tangent_epsilon = 2.0, -- px/s: min tangential speed that fixes a direction
	slide_invert_lowest_tie = 1.0, -- px: impact-y tie tolerance for "both lowest"
}

return Config
