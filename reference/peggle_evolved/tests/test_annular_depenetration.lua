-- Annular side-aware depenetration regression tests.
--
-- Regression: the discrete annular overlap check and the end-of-frame
-- depenetrate fallback treated every ball in the catch zone as if it were
-- outside the wall. A ball touching the inner surface of a thin annular
-- border (a hole) was pushed outward by 2*radius+thickness, teleporting it
-- to the far side of the wall.
local Physics = require("src.systems.physics")
local Ball = require("src.entities.ball")
local Peg = require("src.entities.peg")
local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")

local function step(ball, pegs)
	Physics.update({ ball }, {}, {}, pegs, Config.fixed_dt)
end

local function radial_distance(ball, cx, cy)
	local dx, dy = ball.x - cx, ball.y - cy
	return math.sqrt(dx * dx + dy * dy)
end

return {
	setup = function()
		LevelManager.virtual_width = 1200
		LevelManager.virtual_height = 1900
		Config.virtual_width = 1200
		Config.virtual_height = 1900
		Config.gravity = 0
	end,

	test_inner_wall_overlap_never_pushes_through_the_border = function()
		-- Large-radius, tiny-span border: the failing replays' geometry.
		-- The ball rests 0.03 px into the inner wall; the old code measured
		-- the penetration against r_out and pushed it out to r_out + radius.
		local cx, cy = 600, 950
		local r_in, r_out = 8724.9, 8744.9
		local span = 0.0014
		local peg = Peg.new_annular(cx, cy, "blue", r_in, r_out, -span / 2, span / 2)
		local ball = Ball.new(cx + r_in - Config.ball_radius + 0.03, cy)
		ball.launched = true

		local before = radial_distance(ball, cx, cy)
		step(ball, { peg })
		local after = radial_distance(ball, cx, cy)

		assert_true(after <= r_in,
			"inner-wall overlap must stay inside the hole, got dist " .. tostring(after))
		assert_true(before - after < 1,
			"inner-wall nudge stays sub-pixel, moved " .. tostring(before - after))
	end,

	test_band_overlap_exits_through_the_nearer_surface = function()
		local cx, cy = 600, 950
		local r_in, r_out = 100, 120
		local peg = Peg.new_annular(cx, cy, "blue", r_in, r_out, -0.05, 0.05)

		local inner_ball = Ball.new(cx + 105, cy)
		inner_ball.launched = true
		step(inner_ball, { peg })
		local inner_dist = radial_distance(inner_ball, cx, cy)
		assert_true(inner_dist < r_in,
			"band center nearer the hole exits inward, got dist " .. tostring(inner_dist))

		local outer_ball = Ball.new(cx + 115, cy)
		outer_ball.launched = true
		step(outer_ball, { peg })
		local outer_dist = radial_distance(outer_ball, cx, cy)
		assert_true(outer_dist > r_out,
			"band center nearer the rim exits outward, got dist " .. tostring(outer_dist))
	end,

	test_ball_clear_of_the_inner_wall_is_untouched = function()
		local cx, cy = 600, 950
		local peg = Peg.new_annular(cx, cy, "blue", 100, 120, -0.05, 0.05)
		local ball = Ball.new(cx + 90, cy)
		ball.launched = true
		local before = radial_distance(ball, cx, cy)
		step(ball, { peg })
		assert_eq(ball.x, cx + 90)
		assert_eq(ball.y, cy)
		assert_eq(radial_distance(ball, cx, cy), before)
	end,
}
