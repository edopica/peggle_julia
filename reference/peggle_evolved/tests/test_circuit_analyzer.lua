-- CircuitAnalyzer tests: absolute path envelopes, same-path time-domain
-- sweeps, finite horizon reporting, and zero-speed path handling.
local CircuitAnalyzer = require("src.systems.circuit_analyzer")
local Path = require("src.systems.path")
local Peg = require("src.entities.peg")

local function near(a, b, eps)
	eps = eps or 1e-9
	assert_true(math.abs(a - b) <= eps,
		string.format("expected %.17g, got %.17g (tolerance %.3g)", b, a, eps))
end

local function circle_path(center_x, center_y, radius)
	return Path.new({ segments = {
		{ kind = "arc", center = { x = center_x, y = center_y }, radius = radius,
			theta_start = 0, sweep = math.pi * 2 },
	}, closed = true })
end

-- Stadium loop: two 60px straights 8px apart joined by radius-4 caps. Points
-- 10px apart in arc length are 10px apart on the straights but only ~7.6px
-- apart on a cap, so a 10px-spaced pair with 9px combined radius is separated
-- on the straights and overlaps while both traverse a cap.
local function stadium_path()
	return Path.new({ segments = {
		{ kind = "line", p0 = { 0, 0 }, p1 = { 60, 0 } },
		{ kind = "arc", center = { 60, 4 }, radius = 4,
			theta_start = -math.pi / 2, sweep = math.pi },
		{ kind = "line", p0 = { 60, 8 }, p1 = { 0, 8 } },
		{ kind = "arc", center = { 0, 4 }, radius = 4,
			theta_start = math.pi / 2, sweep = math.pi },
	}, closed = true })
end

local function path_peg(path, phase, radius, circuit)
	local x, y = path:at_distance(phase % path:length())
	local peg = Peg.new(x, y, "blue", radius or 10)
	peg.motion = { circuit = circuit or "c1", phase = phase }
	return peg
end

local function collect_reports()
	local reports = {}
	return reports, function(tier, p1, p2, overlap, is_dyn, best_t, min_gap)
		reports[#reports + 1] = {
			tier = tier, p1 = p1, p2 = p2, overlap = overlap,
			is_dyn = is_dyn, best_t = best_t, min_gap = min_gap,
		}
	end
end

return {
	test_numeric_assertions_reject_wrong_results = function()
		assert_false(pcall(near, -123456, 15), "near must fail, not return false")
	end,

	test_same_path_rectangles_use_shape_overlap_at_each_sample = function()
		local path = circle_path(500, 500, 20)
		for _, angle in ipairs({ 0, math.pi / 2 }) do
			local pegs = {}
			for i, phase in ipairs({ 0, path:length() / 2 }) do
				local x, y = path:at_distance(phase)
				pegs[i] = Peg.new_rectangle(x, y, "blue", angle == 0 and 60 or 54, 2,
					i == 2 and angle or 0)
				pegs[i].motion = { circuit = "c1", phase = phase }
			end
			local reports, report = collect_reports()
			CircuitAnalyzer.analyze(pegs, { c1 = { kind = "path", path = path, speed = 10 } }, report)
			if angle == 0 then
				assert_eq(#reports, 1)
				assert_eq(reports[1].tier, "ERROR")
				near(reports[1].overlap, 2)
			else
				assert_eq(#reports, 0, "separated shapes must not produce a warning")
			end
		end
	end,

	test_same_path_annular_samples_preserve_source_geometry = function()
		local path = circle_path(500, 500, 20)
		local peg = Peg.new_annular(520, 500, "blue", 0, 25, 0, math.pi / 2)
		peg.motion = { circuit = "c1", phase = 0 }
		local other = path_peg(path, 5, 10)
		local polygon = {}
		for i, value in ipairs(peg.polygon) do polygon[i] = value end
		local corner_x, corner_y = peg.corners[1].x, peg.corners[1].y
		local reports, report = collect_reports()
		CircuitAnalyzer.analyze({ peg, other },
			{ c1 = { kind = "path", path = path, speed = 10 } }, report)
		assert_true(#reports > 0, "mixed annular/circle candidates receive narrow-phase checks")
		for i, value in ipairs(polygon) do assert_eq(peg.polygon[i], value) end
		assert_eq(peg.corners[1].x, corner_x)
		assert_eq(peg.corners[1].y, corner_y)
	end,
	test_path_envelope_is_absolute_world_bounds = function()
		local path = circle_path(500, 600, 100)
		local circuit = { kind = "path", path = path, speed = 100 }
		local envelope = CircuitAnalyzer.characterize_circuit("c1", circuit)
		assert_true(envelope.absolute, "path envelopes are absolute")
		near(envelope.min_dx, 400)
		near(envelope.max_dx, 600)
		near(envelope.min_dy, 500)
		near(envelope.max_dy, 700)

		local relative = CircuitAnalyzer.characterize_circuit("c2",
			{ kind = "oscillate_x", amp = 50, speed = 1 })
		assert_false(relative.absolute, "relative primitives stay relative")
		near(relative.min_dx, -50)
		near(relative.max_dx, 50)
	end,

	test_absolute_positions_do_not_add_peg_base = function()
		-- The moving peg's declared base is far away; only the path point is
		-- real. A static peg exactly on the path must still be detected.
		local path = circle_path(500, 600, 100)
		local circuit = { kind = "path", path = path, speed = 100 }
		local moving = path_peg(path, 0, 10)
		moving.base_x, moving.base_y = 2000, 2000
		local static = Peg.new(600, 600, "blue", 10)

		local reports, report = collect_reports()
		CircuitAnalyzer.analyze({ moving, static }, { c1 = circuit }, report)
		assert_true(#reports >= 1, "a static overlap on the path is reported")
		assert_true(reports[1].overlap > 0, "the report is an overlap")
	end,

	test_same_path_pair_overlap_detected_later_in_cycle = function()
		local path = stadium_path()
		local circuit = { kind = "path", path = path, speed = 100 }
		local first = path_peg(path, 20, 4.5)
		local second = path_peg(path, 30, 4.5)

		local start_distance = math.sqrt(
			(first.x - second.x) ^ 2 + (first.y - second.y) ^ 2)
		assert_true(start_distance > 9,
			"the pair starts apart at its initial phases")

		local reports, report = collect_reports()
		CircuitAnalyzer.analyze({ first, second }, { c1 = circuit }, report)
		assert_true(#reports >= 1, "the later overlap is detected")
		assert_eq(reports[1].tier, "ERROR", "the detected overlap is an error")
		assert_true(reports[1].overlap > 0, "actual overlap amount is positive")
		assert_true(reports[1].best_t > 0.05, "detected after the initial phases")
	end,

	test_same_path_pair_with_constant_separation_is_silent = function()
		-- On a circle every 10px-spaced pair stays ~9.999px apart, above the
		-- 9px combined radius, for the whole cycle.
		local path = circle_path(0, 0, 100)
		local circuit = { kind = "path", path = path, speed = 100 }
		local first = path_peg(path, 20, 4.5)
		local second = path_peg(path, 30, 4.5)
		local reports, report = collect_reports()
		CircuitAnalyzer.analyze({ first, second }, { c1 = circuit }, report)
		assert_eq(#reports, 0, "constant separation produces no report")
	end,

	test_pause_cycles_hold_positions_but_keep_the_sweep = function()
		-- A timed path repeats the same spatial configurations; the overlap on
		-- a cap must still be found within the finite horizon.
		local path = stadium_path()
		local circuit = { kind = "path", path = path, speed = 100,
			duration_time = 0.2, pause_time = 0.2 }
		local first = path_peg(path, 20, 4.5)
		local second = path_peg(path, 30, 4.5)
		local reports, report = collect_reports()
		CircuitAnalyzer.analyze({ first, second }, { c1 = circuit }, report)
		assert_true(#reports >= 1, "the overlap is detected across pause cycles")
	end,

	test_analyze_reports_finite_horizon = function()
		local path = circle_path(0, 0, 100)
		local circuit = { kind = "path", path = path, speed = 10 }
		local diagnostics = CircuitAnalyzer.analyze({}, { c1 = circuit }, function() end)
		local expected = path:length() / 10
		near(diagnostics.horizon, expected, 1e-9)
		near(CircuitAnalyzer.period(circuit), expected, 1e-9)
	end,

	test_zero_speed_path_has_no_period_and_checks_fixed_phases = function()
		local path = circle_path(0, 0, 100)
		assert_true(CircuitAnalyzer.period({ kind = "path", path = path, speed = 0 }) == nil)
		assert_true(CircuitAnalyzer.period({ kind = "oscillate_x", amp = 1 }) == nil)

		local circuit = { kind = "path", path = path, speed = 0 }
		local first = path_peg(path, 50, 10)
		local second = path_peg(path, 50 - path:length(), 10)
		local reports, report = collect_reports()
		CircuitAnalyzer.analyze({ first, second }, { c1 = circuit }, report)
		assert_true(#reports >= 1, "stationary path pegs are checked at their phases")
	end,

	test_motion_argument_includes_pause_semantics = function()
		local circuit = { kind = "path", path = circle_path(0, 0, 100),
			speed = 100, duration_time = 0.2, pause_time = 0.3 }
		-- Moving portion advances at speed.
		near(CircuitAnalyzer.motion_argument(circuit, 5, 0.1), 5 + 10)
		-- Paused portion does not advance.
		near(CircuitAnalyzer.motion_argument(circuit, 5, 0.3), 5 + 20)
		-- Next cycle advances again.
		near(CircuitAnalyzer.motion_argument(circuit, 5, 0.5 + 0.1), 5 + 30)
		-- Relative primitives keep the historical default speed of 1.
		near(CircuitAnalyzer.motion_argument({ kind = "oscillate_x", amp = 1 }, 2, 3), 5)
	end,

	test_elapsed_for_advance_inverts_the_pause_schedule = function()
		local circuit = { kind = "path", path = circle_path(0, 0, 100),
			speed = 100, duration_time = 0.2, pause_time = 0.3 }
		near(CircuitAnalyzer.elapsed_for_advance(circuit, 10), 0.1)
		near(CircuitAnalyzer.elapsed_for_advance(circuit, 20), 0.2)
		near(CircuitAnalyzer.elapsed_for_advance(circuit, 30), 0.6)
		near(CircuitAnalyzer.elapsed_for_advance(circuit, 40), 0.7)
		near(CircuitAnalyzer.elapsed_for_advance(circuit, 60), 1.2)
		near(CircuitAnalyzer.elapsed_for_advance(circuit, 20 - 1e-6), 0.2 - 1e-8)
		near(CircuitAnalyzer.elapsed_for_advance(circuit, 20 + 1e-6), 0.5 + 1e-8)
		for _, advance in ipairs({ 0, 7.5, 20, 45, 130 }) do
			local elapsed = CircuitAnalyzer.elapsed_for_advance(circuit, advance)
			near(CircuitAnalyzer.motion_argument(circuit, 0, elapsed), advance, 1e-9)
		end
	end,
}
