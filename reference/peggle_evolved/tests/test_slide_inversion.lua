-- SlideInversion unit + integration tests.
--
-- The processor detects a pendulum apex (velocity reversal) while a ball is
-- sliding on a zero-gap generated line and asks the Engine to remove the
-- lowest already-hit peg(s) of that line.
local SlideInversion = require("src.systems.slide_inversion")
local GameplayEvents = require("src.systems.gameplay_events")
local GameplayCommands = require("src.systems.gameplay_commands")
local Config = require("src.config")
local H = require("tests.helpers.engine_helpers")
local Ball = require("src.entities.ball")

local ARC_LINE = { id = "arc", index = 1, count = 3, closed = false, gap = 0 }
local OTHER_LINE = { id = "rail", index = 1, count = 3, closed = false, gap = 0 }

local function make_ball(id, vx, vy)
	return {
		id = id, x = 0, y = 0, prev_x = 0, prev_y = 0,
		vx = vx, vy = vy, radius = 6, launched = true,
	}
end

-- Run one processor step. `contacts` is a list of { peg_id, line? } and
-- `scored` a list of { peg_id, impact_y, line? }.
local function run_step(si, ball, contacts, scored, opts)
	local ev = GameplayEvents.new()
	local cmds = GameplayCommands.new()
	ev:begin_step(1, 1)
	for _, c in ipairs(contacts or {}) do
		ev:emit_raw("ball_contacted_peg", {
			ball_id = ball.id,
			peg_id = c.peg_id,
			line = c.line or ARC_LINE,
			-- Surface normal (peg -> ball). Defaults to the right face of a
			-- vertical line, so the tangential sign equals sign(vy).
			normal_x = c.normal_x or 1,
			normal_y = c.normal_y or 0,
			did_bounce = c.did_bounce or false,
		})
	end
	ev:seal_raw()
	for _, s in ipairs(scored or {}) do
		ev:emit_derived("peg_scored", {
			ball_id = ball.id,
			peg_id = s.peg_id,
			impact_y = s.impact_y,
			line = s.line or ARC_LINE,
		})
	end
	si:process_step(ev, cmds, { ball }, Config.fixed_dt, opts)
	ev:finish_step()
	return cmds
end

local function find_cmd(cmds, cmd_type)
	for _, c in ipairs(cmds:all()) do
		if c.type == cmd_type then return c end
	end
	return nil
end

local function three_hits(y1, y2, y3)
	return {
		{ peg_id = 11, impact_y = y1 },
		{ peg_id = 12, impact_y = y2 },
		{ peg_id = 13, impact_y = y3 },
	}
end

local CONTACTS = { { peg_id = 11 }, { peg_id = 12 }, { peg_id = 13 } }

return {
	setup = function()
		Config.slide_invert_contact_timeout = 0.3
		Config.slide_invert_tangent_epsilon = 2.0
		Config.slide_invert_lowest_tie = 1.0
	end,

	test_inversion_removes_lowest_hit_peg = function()
		local si = SlideInversion.new()
		local b = make_ball(1, 0, 300)
		run_step(si, b, CONTACTS, three_hits(100, 200, 150))
		b.vx, b.vy = 0, 50
		run_step(si, b, CONTACTS, nil)
		b.vx, b.vy = 0, -300
		local cmds = run_step(si, b, CONTACTS, nil)
		local cmd = find_cmd(cmds, "remove_slide_pegs")
		assert_true(cmd ~= nil, "inversion pushes remove_slide_pegs")
		assert_eq(#cmd.peg_ids, 1, "exactly the lowest peg is removed")
		assert_eq(cmd.peg_ids[1], 12, "lowest impact_y wins")
		assert_eq(cmd.line_id, "arc", "command carries the slide line")
	end,

	test_tied_lowest_removes_both = function()
		local si = SlideInversion.new()
		local b = make_ball(1, 0, 300)
		run_step(si, b, CONTACTS, three_hits(100, 200.0, 200.5))
		b.vx, b.vy = 0, 50
		run_step(si, b, CONTACTS, nil)
		b.vx, b.vy = 0, -300
		local cmds = run_step(si, b, CONTACTS, nil)
		local cmd = find_cmd(cmds, "remove_slide_pegs")
		assert_true(cmd ~= nil, "inversion pushes remove_slide_pegs")
		assert_eq(#cmd.peg_ids, 2, "both tied lowest pegs are removed")
		assert_eq(cmd.peg_ids[1], 12)
		assert_eq(cmd.peg_ids[2], 13)
	end,

	test_same_direction_slowdown_does_not_trigger = function()
		local si = SlideInversion.new()
		local b = make_ball(1, 0, 300)
		run_step(si, b, CONTACTS, three_hits(100, 200, 150))
		b.vx, b.vy = 0, 50
		run_step(si, b, CONTACTS, nil)
		b.vx, b.vy = 0, 300 -- speeds up in the same direction
		local cmds = run_step(si, b, CONTACTS, nil)
		assert_true(find_cmd(cmds, "remove_slide_pegs") == nil,
			"no inversion when the direction is unchanged")
	end,

	test_bounce_reversal_does_not_trigger = function()
		local si = SlideInversion.new()
		local b = make_ball(1, 0, 300)
		run_step(si, b, CONTACTS, three_hits(100, 200, 150))
		b.vx, b.vy = 0, 50
		run_step(si, b, CONTACTS, nil)
		b.vx, b.vy = 0, -300
		local bounced = {
			{ peg_id = 11, did_bounce = true },
			{ peg_id = 12, did_bounce = true },
			{ peg_id = 13, did_bounce = true },
		}
		local cmds = run_step(si, b, bounced, nil)
		assert_true(find_cmd(cmds, "remove_slide_pegs") == nil,
			"a genuine bounce is not a pendulum inversion")
	end,

	test_contact_timeout_clears_slide = function()
		local si = SlideInversion.new()
		local b = make_ball(1, 0, 300)
		run_step(si, b, CONTACTS, three_hits(100, 200, 150))
		-- No contact for longer than the timeout.
		local steps = math.ceil(Config.slide_invert_contact_timeout / Config.fixed_dt) + 2
		for _ = 1, steps do
			run_step(si, b, {}, nil)
		end
		b.vx, b.vy = 0, -300
		local cmds = run_step(si, b, CONTACTS, nil)
		assert_true(find_cmd(cmds, "remove_slide_pegs") == nil,
			"a new slide after a gap starts fresh (no inversion)")
	end,

	test_switching_lines_restarts_tracking = function()
		local si = SlideInversion.new()
		local b = make_ball(1, 0, 300)
		run_step(si, b, CONTACTS, three_hits(100, 200, 150))
		b.vx, b.vy = 0, 50
		run_step(si, b, CONTACTS, nil)
		b.vx, b.vy = 0, -300
		local other = {
			{ peg_id = 11, line = OTHER_LINE },
			{ peg_id = 12, line = OTHER_LINE },
		}
		local cmds = run_step(si, b, other, nil)
		assert_true(find_cmd(cmds, "remove_slide_pegs") == nil,
			"a different line does not inherit the previous direction")
	end,

	test_removed_peg_is_not_selected_twice = function()
		local si = SlideInversion.new()
		local b = make_ball(1, 0, 300)
		run_step(si, b, CONTACTS, three_hits(100, 200, 150))
		b.vx, b.vy = 0, 50
		run_step(si, b, CONTACTS, nil)
		b.vx, b.vy = 0, -300
		local first = run_step(si, b, CONTACTS, nil)
		assert_eq(#find_cmd(first, "remove_slide_pegs").peg_ids, 1)
		-- Second apex: the lowest remaining hit peg (impact_y 150) is removed.
		b.vx, b.vy = 0, -50
		run_step(si, b, CONTACTS, nil)
		b.vx, b.vy = 0, 300
		local second = run_step(si, b, CONTACTS, nil)
		local cmd = find_cmd(second, "remove_slide_pegs")
		assert_true(cmd ~= nil, "second inversion removes the next lowest")
		assert_eq(#cmd.peg_ids, 1)
		assert_eq(cmd.peg_ids[1], 13, "already-removed peg is skipped")
	end,

	test_slide_level_removal_preserves_score = function()
		Config.gravity = 1000
		local data = require("src.levels.slide")
		-- The level module is cached and other tests mutate its peg tables
		-- (hit/type). Work on fresh copies so this test is order-independent.
		local pegs = {}
		for i, p in ipairs(data.pegs) do
			local c = {}
			for k, v in pairs(p) do c[k] = v end
			c.hit = nil
			c.hit_order = nil
			c.multiplier_at_hit = nil
			c.original_index = nil
			pegs[i] = c
		end
		local eng = H.new_engine()
		H.setup_engine(eng, pegs, { red = 0, green = 0 }, 1)
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
		eng.slideInversion:reset_shot()

		for _ = 1, 60 * 30 do
			eng.sim_step_id = eng.sim_step_id + 1
			eng:savePreviousState()
			eng:stepSimulation(Config.fixed_dt)
			if eng.shot_end_reason == "__handled" then break end
			if #eng.active_balls == 0 then break end
		end

		local removed = {}
		for _, rec in ipairs(recorder) do
			for _, e in ipairs(rec.derived_events) do
				if e.type == "slide_peg_removed" then table.insert(removed, e) end
			end
		end

		assert_true(#removed > 0, "the trapped shot removes at least one peg")
		for _, e in ipairs(removed) do
			assert_eq(e.line_id, "slide_arc", "the removed peg is on the arc")
			assert_true(eng.peg_by_id[e.peg_id] == nil, "removed peg left the board")
			local in_turn = false
			for _, p in ipairs(eng.turnPegsHit) do
				if p.original_index == e.peg_id then in_turn = true break end
			end
			assert_true(in_turn, "removed peg keeps its score in turnPegsHit")
		end
	end,
}
