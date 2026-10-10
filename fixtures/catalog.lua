-- M1 fixture catalog: targeted reference cases for the Julia port.
--
-- A fixture is either a legal aim-grid shot evaluated through the pinned
-- engine (`kind = "shot"`, zero additional delay) or a boundary scenario from
-- fixtures/scenarios.lua (`kind = "scenario"`). Expected records are captured
-- by running the pinned reference under LÖVE and are written to
-- fixtures/expected/<id>.json. Never hand-edit expected values.
--
-- The matrix assessment (why these categories, and the absence of the
-- upstream "42-case matrix") is documented in wiki/context/fixtures.md.
--
-- Fields:
--   id         stable identifier (file name)
--   category   primary matrix category
--   kind       "shot" or "scenario"
--   level      level module name (shot only)
--   aim_index  0..1800 legal grid index (shot only)
--   balls      simultaneous launched balls, default 1 (shot only)
--   completion "bench" (default) or "clearing" (shot only)
--   max_steps  fixed-step cap (shot only, default 3600)
--   trace      capture a gameplay event trace (shot only; off by default)
--   note       why this case exists

return {
	version = 1,
	fixtures = {
		-- ------------------------------------------------------------------
		-- Grazes and zero-gap line metadata
		-- ------------------------------------------------------------------
		{
			id = "slide_rail_graze",
			category = "graze",
			kind = "shot",
			level = "slide",
			aim_index = 900,
			trace = true,
			note = "straight drop grazes every zero-gap rail peg; awards slide; line metadata id/index/gap",
		},
		{
			id = "slide_slide_style",
			category = "style",
			kind = "shot",
			level = "slide",
			aim_index = 406,
			trace = true,
			note = "left arc lands on the layout; awards slide style across a longer contact chain",
		},
		{
			id = "slide_line_metadata",
			category = "line_metadata",
			kind = "shot",
			level = "slide",
			aim_index = 503,
			note = "line groups exercised without trace capture (summary parity case)",
		},

		-- ------------------------------------------------------------------
		-- Completion, clearing, bucket
		-- ------------------------------------------------------------------
		{
			id = "completion_miss_fell_out",
			category = "completion",
			kind = "shot",
			level = "long_shot",
			aim_index = 900,
			note = "simplest completion path: no peg contact, falls out of the scene",
		},
		{
			id = "clearing_cascade",
			category = "clearing",
			kind = "shot",
			level = "circle_level",
			aim_index = 53,
			completion = "clearing",
			max_steps = 7200,
			trace = true,
			note = "end-of-turn clearing cascade to the next ready-to-aim boundary",
		},
		{
			id = "bucket_catch",
			category = "bucket",
			kind = "shot",
			level = "circle_level",
			aim_index = 61,
			note = "clean bucket catch with no style award",
		},

		-- ------------------------------------------------------------------
		-- Fever and green powers
		-- ------------------------------------------------------------------
		{
			id = "super_long_shot_fever",
			category = "fever",
			kind = "shot",
			level = "super_long_shot",
			aim_index = 1736,
			note = "hits the level's only red peg; triggers fever and awards super long shot",
		},
		{
			id = "long_shot_style_fever",
			category = "style",
			kind = "shot",
			level = "long_shot",
			aim_index = 1736,
			trace = true,
			note = "awards long shot, triggers fever, and spawns green power balls",
		},
		{
			id = "power_green_spawn",
			category = "power",
			kind = "shot",
			level = "circle_level",
			aim_index = 53,
			note = "green peg hit spawns two power balls; no style award",
		},

		-- ------------------------------------------------------------------
		-- Style awards
		-- ------------------------------------------------------------------
		{
			id = "double_long_shot_style",
			category = "style",
			kind = "shot",
			level = "double_long_shot",
			aim_index = 633,
			note = "awards double long shot, long shot, and super long shot in one shot",
		},
		{
			id = "lucky_bounce_style",
			category = "style",
			kind = "shot",
			level = "lucky_bounce",
			aim_index = 1046,
			note = "bucket bounce then catch; awards lucky bounce",
		},
		{
			id = "off_the_wall_style",
			category = "style",
			kind = "shot",
			level = "off_the_wall",
			aim_index = 7,
			note = "side-wall bounce followed by a scoring peg; awards off the wall",
		},

		-- ------------------------------------------------------------------
		-- Multiball and dense annular
		-- ------------------------------------------------------------------
		{
			id = "multiball_slide_3",
			category = "multiball",
			kind = "shot",
			level = "slide",
			aim_index = 900,
			balls = 3,
			trace = true,
			note = "three simultaneous balls on the rail; ball-ball and bucket interactions",
		},
		{
			id = "squiggly_annular_drop",
			category = "shape_boundary",
			kind = "shot",
			level = "squiggly_circle",
			aim_index = 900,
			trace = true,
			note = "natural contact against dense zero-gap annular pieces",
		},

		-- ------------------------------------------------------------------
		-- Targeted boundary scenarios (physics/engine seam)
		-- ------------------------------------------------------------------
		{
			id = "probe_graze_gap_0_25",
			category = "shape_boundary",
			kind = "scenario",
			note = "circle graze band: 0.25 px past tangent (scoring graze)",
		},
		{
			id = "probe_graze_gap_0_50",
			category = "shape_boundary",
			kind = "scenario",
			note = "circle graze band: exactly graze_tolerance (boundary)",
		},
		{
			id = "probe_graze_gap_0_75",
			category = "shape_boundary",
			kind = "scenario",
			note = "circle graze band: 0.75 px past tangent (miss)",
		},
		{
			id = "probe_rectangle_corner_rotated",
			category = "shape_boundary",
			kind = "scenario",
			note = "swept corner of a rotated rectangle: path along local -y at 3 px outside the bottom-left corner, single sweep (TOI 0.9997, bouncing) on the corner point",
		},
		{
			id = "probe_annular_outer_surface",
			category = "shape_boundary",
			kind = "scenario",
			note = "radial approach to an annular outer surface",
		},
		{
			id = "probe_annular_inner_surface",
			category = "shape_boundary",
			kind = "scenario",
			note = "radial approach to an annular inner surface",
		},
		{
			id = "probe_annular_cap_crossing",
			category = "shape_boundary",
			kind = "scenario",
			note = "swept annular cap crossing: perpendicular approach 0.2 rad outside the start cap at band radius 45, single sweep (TOI 0.71, bouncing) at cap radius 44.1",
		},
		{
			id = "probe_near_tie_equal_toi",
			category = "near_tie",
			kind = "scenario",
			note = "two pegs at equal TOI; reducer must keep candidate-index order",
		},
		{
			id = "probe_depenetration_inner_wall",
			category = "overlap_correction",
			kind = "scenario",
			note = "inner-wall overlap nudges the ball back into the hole",
		},
		{
			id = "probe_depenetration_band_exit",
			category = "overlap_correction",
			kind = "scenario",
			note = "band overlap exits through the nearer surface",
		},
		{
			id = "probe_ball_ball_impulse",
			category = "multiball",
			kind = "scenario",
			note = "equal-mass head-on ball-ball impulse",
		},
	},
}
