-- Bounce settling regression tests.
--
-- Covers the stateless settling mechanic added to Physics.update:
--   * bounce_min_normal_speed: sub-threshold normal approach is a settling
--     contact (did_bounce=false, reduced restitution) rather than a bounce.
--
-- Also guards the slide level against the previous "bounces forever" behavior.
local H = require("tests.helpers.engine_helpers")
local Ball = require("src.entities.ball")
local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")

local function step_until_wall(eng, ball, max_steps)
	local recorder = H.make_recorder(eng)
	local wall_ev
	for _ = 1, max_steps do
		eng.sim_step_id = eng.sim_step_id + 1
		eng:savePreviousState()
		eng:stepSimulation(Config.fixed_dt)
		for _, rec in ipairs(recorder) do
			for _, ev in ipairs(rec.raw_events) do
				if ev.type == "ball_contact_wall" then wall_ev = ev end
			end
		end
		if wall_ev then break end
	end
	return wall_ev
end

local function new_wall_engine()
	local eng = H.new_engine()
	H.setup_engine(eng, {}, { red = 0, green = 0 }, 1)
	return eng
end

local function launch_left(eng, vx)
	local b = Ball.new(16, 900)
	b.launched = true
	b.vx = vx
	b.vy = 0
	eng:registerBall(b)
	eng.active_balls = { b }
	eng.shot_id = 1
	eng.styleShots:reset_shot()
	eng.ballState:reset_shot()
	return b
end

return {
	setup = function()
		LevelManager.virtual_width = 1200
		LevelManager.virtual_height = 1900
		Config.virtual_width = 1200
		Config.virtual_height = 1900
		Config.gravity = 1000
		Config.launch_speed = 800
	end,

	test_low_speed_contact_settles_without_a_bounce = function()
		Config.gravity = 0
		local eng = new_wall_engine()
		local b = launch_left(eng, -60)
		local ev = step_until_wall(eng, b, 60)
		assert_true(ev ~= nil, "ball reached the left wall")
		assert_false(ev.did_bounce, "sub-threshold contact is not classified as a bounce")
		assert_true(b.vx > 0, "ball is pushed off the wall")
		assert_true(math.abs(b.vx) < Config.bounce_min_normal_speed,
			"settling rebound stays below the threshold, got " .. tostring(b.vx))
		Config.gravity = 1000
	end,

	test_high_speed_contact_still_bounces = function()
		Config.gravity = 0
		local eng = new_wall_engine()
		local b = launch_left(eng, -300)
		local ev = step_until_wall(eng, b, 30)
		assert_true(ev ~= nil, "ball reached the left wall")
		assert_true(ev.did_bounce, "super-threshold contact is a real bounce")
		assert_true(b.vx > 100, "ball rebounds strongly off the wall, got " .. tostring(b.vx))
		Config.gravity = 1000
	end,

	test_slide_level_trap_angle_settles_quickly = function()
		-- Regression: angle 45 used to bounce 170+ times over ~14 s as the ball
		-- oscillated in the arc's concave bowl. With settling the bounce count
		-- and turn length are both bounded.
		Config.gravity = 1000
		local data = require("src.levels.slide")
		local eng = H.new_engine()
		H.setup_engine(eng, data.pegs, { red = 0, green = 0 }, 1)
		local recorder = H.make_recorder(eng)
		local ang = math.rad(45)
		local b = Ball.new(600, 50)
		b.launched = true
		b.vx = math.cos(ang) * 800
		b.vy = math.sin(ang) * 800
		eng:registerBall(b)
		eng.active_balls = { b }
		eng.shot_id = 1
		eng.styleShots:reset_shot()
		eng.ballState:reset_shot()

		local bounces = 0
		local steps = 0
		for i = 1, 60 * 30 do
			eng.sim_step_id = eng.sim_step_id + 1
			eng:savePreviousState()
			eng:stepSimulation(Config.fixed_dt)
			steps = i
			if eng.shot_end_reason == "__handled" then break end
			if #eng.active_balls == 0 then break end
		end
		for _, rec in ipairs(recorder) do
			for _, ev in ipairs(rec.raw_events) do
				if ev.did_bounce then bounces = bounces + 1 end
			end
		end

		assert_true(steps < 60 * 30, "trap angle turn ends before the 30 s cap")
		assert_true(bounces < 60, "trap angle bounce count is bounded, got " .. bounces)
	end,
}
