-- Circuits initialize/update tests: runtime motion state, secant velocities,
-- pause cycles with overshoot, annular rotation handling, and absolute path
-- primitives.
local Circuits = require("src.systems.circuits")
local Peg = require("src.entities.peg")
local Path = require("src.systems.path")

local ELLIPSE = { kind = "ellipse", amp_x = 100, amp_y = 50 }

local function near(a, b, eps)
	eps = eps or 1e-9
	return math.abs(a - b) <= eps
end

local function circle_path(radius, center)
	return Path.new({ segments = {
		{ kind = "arc", center = center or { x = 0, y = 0 }, radius = radius,
			theta_start = 0, sweep = math.pi * 2 },
	}, closed = true })
end

local function path_circuit(path, speed, extra)
	local def = { kind = "path", path = path, speed = speed }
	if extra then
		for k, v in pairs(extra) do def[k] = v end
	end
	return { c1 = def }
end

local function path_peg(phase, x, y)
	local p = Peg.new(x or 0, y or 0, "blue", 10)
	p.motion = { circuit = "c1", phase = phase }
	return p
end

local function moving_circle(phase)
	local p = Peg.new(500, 400, "blue", 10)
	p.motion = { circuit = "c1", phase = phase }
	return p
end

local function make_level(extra)
	local defs = { c1 = ELLIPSE }
	if extra then defs.c1 = extra end
	return defs
end

return {
	test_initialize_sets_runtime_motion_state = function()
		local p = moving_circle(1.5)
		Circuits.initialize({ p }, make_level())
		assert_eq(p.motion.time, 1.5, "time starts at declared phase")
		assert_eq(p.motion.state, "moving")
		assert_eq(p.motion.timer, 0)
		local dx, dy = Circuits.eval_transform(ELLIPSE, 1.5)
		assert_true(near(p.x, 500 + dx), "x at phase")
		assert_true(near(p.y, 400 + dy), "y at phase")
		assert_eq(p.vx, 0)
		assert_eq(p.vy, 0)
		assert_eq(p.va, 0)
		assert_eq(p.prev_x, p.x, "prev transform initialized")
	end,

	test_update_advances_time_and_computes_secant_velocity = function()
		local p = moving_circle(0)
		local dt = 1 / 60
		Circuits.initialize({ p }, make_level())
		local sx, sy = p.x, p.y
		Circuits.update({ p }, make_level(), dt)
		assert_true(near(p.motion.time, dt), "time advanced by speed * dt")
		local dx0, dy0 = Circuits.eval_transform(ELLIPSE, 0)
		local dx1, dy1 = Circuits.eval_transform(ELLIPSE, dt)
		assert_true(near(p.x, 500 + dx1), "x at new time")
		assert_true(near(p.vx, (dx1 - dx0) / dt), "secant vx")
		assert_true(near(p.vy, (dy1 - dy0) / dt), "secant vy")
		assert_true(near(p.x - sx, p.vx * dt), "movement consistent with velocity")
	end,

	test_pause_freezes_time_and_zeroes_velocity = function()
		local defs = make_level({ kind = "ellipse", amp_x = 100, amp_y = 50,
			speed = 1, duration_time = 0.2, pause_time = 0.2 })
		local p = moving_circle(0)
		Circuits.initialize({ p }, defs)
		local dt = 0.05
		for _ = 1, 4 do
			Circuits.update({ p }, defs, dt)
		end
		assert_eq(p.motion.state, "paused", "moved for duration_time then paused")
		assert_true(near(p.motion.time, 0.2), "time advanced to duration")
		local x_before, y_before = p.x, p.y
		Circuits.update({ p }, defs, dt)
		assert_true(near(p.motion.time, 0.2), "time frozen while paused")
		assert_eq(p.x, x_before)
		assert_eq(p.y, y_before)
		assert_eq(p.vx, 0, "paused step has zero velocity")
		assert_eq(p.vy, 0)
	end,

	test_pause_to_move_transition_carries_overshoot = function()
		local defs = make_level({ kind = "oscillate_x", amp = 100,
			speed = 1, duration_time = 0.2, pause_time = 0.13 })
		local p = moving_circle(0)
		Circuits.initialize({ p }, defs)
		local dt = 0.05
		-- Move for 0.2s (4 steps), then pause; step into pause twice (0.1s),
		-- third paused step overshoots pause_time by 0.02s.
		for _ = 1, 4 do Circuits.update({ p }, defs, dt) end
		assert_eq(p.motion.state, "paused")
		for _ = 1, 3 do Circuits.update({ p }, defs, dt) end
		assert_eq(p.motion.state, "moving", "resumed after pause_time")
		assert_true(near(p.motion.timer, 0.02, 1e-9), "overshoot kept on timer")
		assert_true(near(p.motion.time, 0.2 + 0.02, 1e-9),
			"overshoot advanced path time")
	end,

	test_move_to_pause_transition_keeps_overshoot = function()
		local defs = make_level({ kind = "oscillate_x", amp = 100,
			speed = 1, duration_time = 0.13, pause_time = 0.2 })
		local p = moving_circle(0)
		Circuits.initialize({ p }, defs)
		local dt = 0.05
		for _ = 1, 3 do Circuits.update({ p }, defs, dt) end
		assert_eq(p.motion.state, "paused", "duration exceeded mid-step")
		assert_true(near(p.motion.timer, 0.02, 1e-9),
			"overshoot counts toward pause")
		assert_true(near(p.motion.time, 0.13, 1e-9),
			"pause-overshoot portion not added to path time")
	end,

	test_large_step_crosses_multiple_boundaries = function()
		local defs = make_level({ kind = "oscillate_x", amp = 100,
			speed = 1, duration_time = 0.1, pause_time = 0.1 })
		local p = moving_circle(0)
		Circuits.initialize({ p }, defs)
		-- dt = 0.45 spans move 0.1 / pause 0.1 / move 0.1 / pause 0.1 / move
		-- 0.05 in a single update call.
		Circuits.update({ p }, defs, 0.45)
		assert_eq(p.motion.state, "moving", "cycle ends mid-move")
		assert_true(near(p.motion.time, 0.25, 1e-9),
			"time advanced only during moving portions")
		assert_true(near(p.motion.timer, 0.05, 1e-9),
			"move time since last boundary kept on timer")
	end,

	test_annular_rotation_applies_angle = function()
		local defs = { c1 = { kind = "rotate", speed = 1, speed_angular = 2 } }
		local p = Peg.new_annular(500, 400, "blue", 30, 60, 0, math.pi)
		p.motion = { circuit = "c1", phase = 0 }
		Circuits.initialize({ p }, defs)
		assert_eq(p.angle, 0)
		local dt = 0.1
		Circuits.update({ p }, defs, dt)
		assert_true(near(p.angle, 0.2, 1e-9), "angle advanced by speed_angular * dt")
		assert_true(near(p.theta_start, p.base_theta_start + 0.2, 1e-9),
			"annular geometry rebuilt at applied rotation")
		assert_true(near(p.va, 2, 1e-9), "angular secant velocity")
		assert_true(#p.polygon > 0, "polygon present")
	end,

	test_annular_returns_to_zero_rotation = function()
		-- A rotation applied and then removed must rebuild the geometry at
		-- zero (prev_rot tracking), not leave stale rotated corners.
		local p = Peg.new_annular(500, 400, "blue", 30, 60, 0, math.pi)
		p.base_angle = 0
		Peg.set_transform(p, 500, 400, 0.5)
		assert_true(near(p.angle, 0.5, 1e-9))
		Peg.set_transform(p, 500, 400, 0)
		assert_true(near(p.angle, 0, 1e-9))
		assert_true(near(p.theta_start, p.base_theta_start, 1e-9),
			"theta_start back at base after returning to zero")
		assert_true(near(p.theta_end_abs, p.base_theta_end_abs, 1e-9))
	end,

	test_static_pegs_untouched = function()
		local p = Peg.new(100, 100, "blue", 10)
		Circuits.initialize({ p }, make_level())
		Circuits.update({ p }, make_level(), 1 / 60)
		assert_eq(p.x, 100)
		assert_eq(p.y, 100)
		assert_eq(p.vx, 0)
		assert_true(p.motion == nil, "no motion table created")
	end,

	test_eval_transform_returns_zero_offset_for_defaults = function()
		local dx, dy, da = Circuits.eval_transform({ path_fn = function() end }, 3)
		assert_eq(dx, 0)
		assert_eq(dy, 0)
		assert_eq(da, 0)
	end,

	test_path_primitive_is_absolute_and_ignores_peg_base = function()
		local path = circle_path(100)
		local defs = path_circuit(path, 50)
		assert_true(Circuits.is_absolute(defs.c1), "path is the absolute primitive")
		assert_false(Circuits.is_absolute(ELLIPSE), "relative primitive stays relative")

		-- Far-away base: absolute positioning must place the peg on the path.
		local p = path_peg(0, 777, -333)
		Circuits.initialize({ p }, defs)
		assert_true(near(p.x, 100), "initialized at path x, not base + offset")
		assert_true(near(p.y, 0), "initialized at path y, not base + offset")
		assert_eq(p.vx, 0)
		assert_eq(p.vy, 0)
		assert_true(near(p.base_x, 777), "declared base is preserved")

		local dt = 1 / 60
		local start_x, start_y = p.x, p.y
		Circuits.update({ p }, defs, dt)
		local expected_x, expected_y = path:at_distance((50 * dt) % path:length())
		assert_true(near(p.x, expected_x, 1e-9), "step-end position follows path")
		assert_true(near(p.y, expected_y, 1e-9), "step-end position follows path")
		assert_true(near(p.vx, (p.x - start_x) / dt, 1e-9), "secant vx")
		assert_true(near(p.vy, (p.y - start_y) / dt, 1e-9), "secant vy")
	end,

	test_path_phase_wraps_negative_and_multi_loop = function()
		local path = circle_path(100)
		local defs = path_circuit(path, 10)
		local length = path:length()
		local phase = 137
		local expected_x, expected_y = path:at_distance(phase)
		for _, wrapped in ipairs({ phase - length, phase + length, phase + 3 * length }) do
			local p = path_peg(wrapped, 500, 500)
			Circuits.initialize({ p }, defs)
			assert_true(near(p.x, expected_x, 1e-9),
				"phase " .. wrapped .. " wraps to the same position")
			assert_true(near(p.y, expected_y, 1e-9),
				"phase " .. wrapped .. " wraps to the same position")
		end
	end,

	test_path_zero_speed_is_stationary = function()
		local path = circle_path(100)
		local defs = path_circuit(path, 0)
		local p = path_peg(42, 500, 500)
		Circuits.initialize({ p }, defs)
		local x, y = p.x, p.y
		for _ = 1, 10 do
			Circuits.update({ p }, defs, 1 / 60)
		end
		assert_eq(p.x, x, "zero speed keeps the position")
		assert_eq(p.y, y)
		assert_eq(p.vx, 0, "zero speed has zero velocity")
		assert_eq(p.vy, 0)
		assert_eq(p.motion.time, 42, "path time does not advance")
	end,

	test_path_seam_crossing_secant_stays_bounded = function()
		local path = circle_path(100)
		local length = path:length()
		local speed = 250
		local defs = path_circuit(path, speed)
		local dt = 1 / 60
		local phase = length - 0.5
		local p = path_peg(phase, 0, 0)
		Circuits.initialize({ p }, defs)
		local start_x, start_y = p.x, p.y
		Circuits.update({ p }, defs, dt)

		local traveled = speed * dt
		local moved = math.sqrt((p.x - start_x) ^ 2 + (p.y - start_y) ^ 2)
		assert_true(moved <= traveled + 1e-9,
			"seam displacement cannot exceed traveled distance")
		local velocity = math.sqrt(p.vx * p.vx + p.vy * p.vy)
		assert_true(velocity <= speed + 1e-9,
			"seam secant velocity stays bounded by the path speed")

		local expected_x, expected_y = path:at_distance((phase + traveled) % length)
		assert_true(near(p.x, expected_x, 1e-9), "wrapped sample point")
		assert_true(near(p.y, expected_y, 1e-9), "wrapped sample point")
	end,

	test_uneven_cubic_seam_secant_stays_bounded = function()
		local path = Path.new({ closed = true, segments = {
			{ kind = "arc", center = {1000, 100}, radius = 100,
				theta_start = -math.pi / 2, sweep = math.pi },
			{ kind = "line", p0 = {1000, 200}, p1 = {0, 200} },
			{ kind = "arc", center = {0, 100}, radius = 100,
				theta_start = math.pi / 2, sweep = math.pi },
			{ kind = "cubic", p0 = {0, 0}, c1 = {0.001, 0},
				c2 = {0.002, 0}, p1 = {1000, 0} },
		} })
		assert_true(path:validate_joins())
		local speed, dt = 170, 1 / 60
		local defs = path_circuit(path, speed)
		for i = 1, 100 do
			local p = path_peg(path:length() - speed * dt * i / 100, 0, 0)
			Circuits.initialize({ p }, defs)
			Circuits.update({ p }, defs, dt)
			assert_true(math.sqrt(p.vx^2 + p.vy^2)
				<= speed + 2 * Path.CUBIC_DISTANCE_TOLERANCE / dt,
				"cubic seam secant respects the distance error budget")
		end
	end,

	test_path_pause_cycle_preserves_phase_across_seam = function()
		local path = circle_path(100)
		local length = path:length()
		local speed = 100
		local defs = path_circuit(path, speed, { duration_time = 0.1, pause_time = 0.1 })
		-- Phase 5px before the seam: after the 0.1s move phase the peg has
		-- advanced 10px, crossing the seam by 5px, then pauses there.
		local phase = length - 5
		local p = path_peg(phase, 0, 0)
		Circuits.initialize({ p }, defs)

		Circuits.update({ p }, defs, 0.1)
		assert_eq(p.motion.state, "paused", "move phase ends after duration_time")
		assert_true(near(p.motion.time, phase + 10, 1e-9), "path time crossed the seam")
		local expected_x, expected_y = path:at_distance((phase + 10) % length)
		assert_true(near(p.x, expected_x, 1e-9), "position follows wrapped distance")
		assert_true(near(p.y, expected_y, 1e-9))

		local paused_x, paused_y = p.x, p.y
		Circuits.update({ p }, defs, 0.05)
		assert_eq(p.motion.state, "paused", "still paused inside pause_time")
		assert_eq(p.x, paused_x, "pause holds the seam-crossed position")
		assert_eq(p.y, paused_y)
		assert_eq(p.vx, 0, "paused step has zero velocity")

		Circuits.update({ p }, defs, 0.05)
		assert_eq(p.motion.state, "moving", "resumes after pause_time")
		assert_true(near(p.motion.time, phase + 10, 1e-9),
			"pause does not advance phase")
		assert_eq(p.x, paused_x, "resume starts from the held position")
	end,
}
