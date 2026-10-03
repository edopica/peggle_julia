-- SimulationSnapshot unit tests using a minimal fake engine.
local SimulationSnapshot = require("src.systems.simulation_snapshot")

local function fake_peg(i, t)
	return {
		original_index = i, type = t or "blue", shape = "circle",
		hit = false, hit_order = nil, multiplier_at_hit = nil,
		x = i * 10, y = i * 5, base_x = i * 10, base_y = i * 5,
		base_angle = 0, angle = 0, vx = 0, vy = 0, va = 0,
		radius = 10, circuit_id = nil, circuit_t = nil,
		circuit_state = nil, circuit_timer = nil,
	}
end

local function fake_engine()
	return {
		sim_step_id = 37,
		shot_id = 3,
		level_name = "test",
		isFever = false,
		currentMultiplier = 2,
		hitCounter = 4,
		totalRedPegs = 10,
		redPegsHitAmount = 2,
		bonusScore = 100,
		styleScore = 50,
		turnPegsHit = { fake_peg(1), fake_peg(2) },
		clearQueue = nil,
		clearingIsEndOfTurn = false,
		clearTimer = 0,
		active_balls = {
			{ id = 1, x = 5, y = 6, prev_x = 4, prev_y = 5, vx = 1, vy = 2,
				radius = 6, launched = true },
			{ id = 2, x = 50, y = 60, prev_x = 49, prev_y = 59, vx = 3, vy = 4,
				radius = 6, launched = true, scoredFever = true },
		},
		pegs = { fake_peg(1, "red"), fake_peg(2, "blue"), fake_peg(3, "purple") },
		bucket = { x = 100, prev_x = 99, top = 500, hole = 70, edge = 12,
			height = 26, phase = 1.2 },
		feverBuckets = {
			top = 500, height = 40, animating = false,
			buckets = { { x = 10, width = 200, value = 10000 } },
			dividers = { { x = 0, y = 500, radius = 40 } },
		},
	}
end

local function assert_exportable(v, path)
	local t = type(v)
	if t == "function" or t == "userdata" or t == "thread" then
		error("non-exportable at " .. path .. ": " .. t)
	elseif t == "table" then
		for k, vv in pairs(v) do
			assert_exportable(k, path .. ".key")
			assert_exportable(vv, path .. tostring(k))
		end
	end
end

return {
	test_snapshot_only_exportable = function()
		local snap = SimulationSnapshot.capture(fake_engine())
		assert_exportable(snap, "snap")
		assert_eq(snap.schema_version, 2)
	end,

	test_balls_stable_order = function()
		local snap = SimulationSnapshot.capture(fake_engine())
		assert_eq(#snap.balls, 2)
		assert_eq(snap.balls[1].id, 1)
		assert_eq(snap.balls[2].id, 2)
		assert_eq(snap.balls[2].scored_fever, true)
	end,

	test_pegs_original_index_order = function()
		local snap = SimulationSnapshot.capture(fake_engine())
		assert_eq(#snap.pegs, 3)
		assert_eq(snap.pegs[1].original_index, 1)
		assert_eq(snap.pegs[2].original_index, 2)
		assert_eq(snap.pegs[3].original_index, 3)
	end,

	test_full_precision_retained = function()
		local e = fake_engine()
		e.active_balls[1].x = 12.34567890123456789
		local snap = SimulationSnapshot.capture(e)
		assert_eq(snap.balls[1].x, 12.34567890123456789)
	end,

	test_snapshot_does_not_mutate_state = function()
		local e = fake_engine()
		local x_before = e.active_balls[1].x
		local hit_before = e.pegs[1].hit
		SimulationSnapshot.capture(e)
		assert_eq(e.active_balls[1].x, x_before)
		assert_eq(e.pegs[1].hit, hit_before)
	end,

	test_snapshot_valid_after_live_changes = function()
		local e = fake_engine()
		local snap = SimulationSnapshot.capture(e)
		-- Mutate live entities after capture.
		e.active_balls[1].x = 9999
		e.pegs[1].hit = true
		-- The captured snapshot retains the old values.
		assert_eq(snap.balls[1].x, 5)
		assert_eq(snap.pegs[1].hit, false)
	end,

	test_no_live_refs_in_snapshot = function()
		local e = fake_engine()
		local snap = SimulationSnapshot.capture(e)
		-- Mutate a live entity; snapshot should not reflect it (proves copy).
		e.active_balls[1].id = 777
		assert_eq(snap.balls[1].id, 1, "snapshot has no live reference to ball")
		e.pegs[2].hit = true
		assert_eq(snap.pegs[2].hit, false, "snapshot has no live reference to peg")
	end,

	test_separate_engines_independent = function()
		local s1 = SimulationSnapshot.capture(fake_engine())
		local s2 = SimulationSnapshot.capture(fake_engine())
		assert_eq(s1.step_id, 37)
		assert_eq(s2.step_id, 37)
		-- Mutating s1 must not affect s2.
		s1.balls[1].x = -1
		assert_eq(s2.balls[1].x, 5)
	end,

	test_turn_pegs_hit_are_ids = function()
		local snap = SimulationSnapshot.capture(fake_engine())
		assert_eq(#snap.turn_pegs_hit, 2)
		assert_eq(snap.turn_pegs_hit[1], 1)
		assert_eq(snap.turn_pegs_hit[2], 2)
	end,

	test_rect_and_annular_shapes = function()
		local e = fake_engine()
		local r = fake_peg(4, "red"); r.shape = "rectangle"; r.width = 30; r.height = 12
		r.radius = nil
		local a = fake_peg(5, "blue"); a.shape = "annular"; a.r_in = 5; a.r_out = 20
		a.theta_start = 0; a.theta_end_abs = 1.57; a.radius = nil
		e.pegs = { r, a }
		local snap = SimulationSnapshot.capture(e)
		assert_eq(snap.pegs[1].shape, "rectangle")
		assert_eq(snap.pegs[1].width, 30)
		assert_eq(snap.pegs[2].shape, "annular")
		assert_eq(snap.pegs[2].r_out, 20)
	end,

	test_motion_sub_table_and_flat_fields = function()
		local e = fake_engine()
		local p = fake_peg(1, "red")
		p.motion = { circuit = "c1", phase = 0.5, time = 1.25, state = "paused", timer = 0.3 }
		e.pegs = { p }
		local snap = SimulationSnapshot.capture(e)
		local s = snap.pegs[1]
		assert_eq(s.motion.circuit, "c1")
		assert_eq(s.motion.phase, 0.5)
		assert_eq(s.motion.time, 1.25)
		assert_eq(s.motion.state, "paused")
		assert_eq(s.motion.timer, 0.3)
		-- Flat trace-compatibility fields derived from motion.
		assert_eq(s.circuit_id, "c1")
		assert_eq(s.circuit_t, 1.25)
		assert_eq(s.circuit_state, "paused")
		assert_eq(s.circuit_timer, 0.3)
	end,

	test_static_peg_motion_fields_nil = function()
		local e = fake_engine()
		local snap = SimulationSnapshot.capture(e)
		local s = snap.pegs[1]
		assert_eq(s.motion, nil, "no motion sub-table for static peg")
		assert_eq(s.circuit_id, nil)
		assert_eq(s.circuit_t, nil)
		assert_eq(s.circuit_state, nil)
		assert_eq(s.circuit_timer, nil)
	end,

	test_line_metadata_copied_by_value = function()
		local e = fake_engine()
		local p = fake_peg(1, "red")
		p.line = { id = "rail", index = 3, count = 12, closed = false, gap = 0 }
		e.pegs = { p }
		local snap = SimulationSnapshot.capture(e)
		local s = snap.pegs[1]
		assert_eq(s.line.id, "rail")
		assert_eq(s.line.index, 3)
		assert_eq(s.line.count, 12)
		assert_false(s.line.closed)
		assert_eq(s.line.gap, 0)
		-- No live reference: mutating the source line metadata must not
		-- affect the captured table.
		p.line.index = 99
		assert_eq(s.line.index, 3, "snapshot line metadata is a by-value copy")
	end,

	test_line_metadata_nil_for_plain_pegs = function()
		local snap = SimulationSnapshot.capture(fake_engine())
		assert_eq(snap.pegs[1].line, nil, "plain pegs carry no line metadata")
	end,
}
