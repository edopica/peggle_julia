-- Ball-ball collision tests.
--
-- Covers the swept equal-mass collision response between launched balls:
--   * head-on balls bounce and never tunnel/pass through each other
--   * momentum is conserved by the split impulse
--   * a ball catching another from behind transfers momentum
--   * coincident spawns (green power multiball) separate deterministically
--   * a raw ball_contact_ball event is emitted with both ball ids
--   * the simulation is deterministic across repeated runs
--   * a single launched ball emits no ball-ball contacts
--   * Config.ball_ball_collisions = false restores legacy pass-through
local Physics = require("src.systems.physics")
local Ball = require("src.entities.ball")
local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")
local GameplayEvents = require("src.systems.gameplay_events")
local ContactEvents = require("src.systems.contact_events")

local R = Config.ball_radius

local function make_ball(x, y, vx, vy, id)
	local b = Ball.new(x, y)
	b.launched = true
	b.vx = vx or 0
	b.vy = vy or 0
	b.id = id
	return b
end

local function step(balls, sink, step_id)
	if sink then
		sink:begin_step(step_id or 1, 1)
	end
	Physics.update(balls, {}, {}, {}, Config.fixed_dt, nil, sink)
end

local function raw_of_type(sink, event_type)
	local out = {}
	for _, ev in ipairs(sink:raw()) do
		if ev.type == event_type then
			table.insert(out, ev)
		end
	end
	return out
end

return {
	setup = function()
		LevelManager.virtual_width = 1200
		LevelManager.virtual_height = 1900
		Config.virtual_width = 1200
		Config.virtual_height = 1900
		Config.gravity = 0
		Config.ball_ball_collisions = true
		ContactEvents.clear()
	end,

	test_head_on_balls_bounce_without_tunneling = function()
		local a = make_ball(300, 900, 800, 0, 1)
		local b = make_ball(360, 900, -800, 0, 2)
		local balls = { a, b }
		local sink = GameplayEvents.new()
		local bounced = false
		local min_gap = math.huge

		for i = 1, 20 do
			step(balls, sink, i)
			local gap = b.x - a.x
			if gap < min_gap then min_gap = gap end
			if a.vx < -1 and b.vx > 1 then bounced = true end
		end

		assert_true(bounced, "head-on balls reverse direction")
		assert_true(min_gap > 2 * R - 1.5,
			"balls never interpenetrate/pass through (min gap " .. tostring(min_gap) .. ")")
		assert_true(a.x < b.x, "head-on order is preserved after the bounce")
	end,

	test_momentum_is_conserved = function()
		local a = make_ball(300, 900, 800, 0, 1)
		local b = make_ball(360, 900, 0, 0, 2)
		local balls = { a, b }
		local sink = GameplayEvents.new()

		for i = 1, 20 do
			step(balls, sink, i)
		end

		assert_true(b.vx > 600, "resting target takes most of the momentum, got " .. tostring(b.vx))
		assert_true(a.vx > 0 and a.vx < 200,
			"striker retains a small forward velocity, got " .. tostring(a.vx))
		assert_true(math.abs((a.vx + b.vx) - 800) < 1e-6,
			"total momentum is conserved, got " .. tostring(a.vx + b.vx))
	end,

	test_catch_up_transfers_momentum_without_overlap = function()
		local a = make_ball(300, 900, 800, 0, 1)
		local b = make_ball(360, 900, 100, 0, 2)
		local balls = { a, b }
		local sink = GameplayEvents.new()
		local min_gap = math.huge

		for i = 1, 20 do
			step(balls, sink, i)
			local gap = b.x - a.x
			if gap < min_gap then min_gap = gap end
		end

		assert_true(b.vx > a.vx, "leader ends up faster than the striker")
		assert_true(math.abs((a.vx + b.vx) - 900) < 1e-6,
			"momentum is conserved in the catch-up case")
		assert_true(min_gap > 2 * R - 1.5,
			"catch-up never overlaps, min gap " .. tostring(min_gap))
	end,

	test_coincident_spawn_separates = function()
		-- Green power spawns two balls at the same point with diverging
		-- velocities. They must separate along the relative motion without
		-- producing NaN or a zero-length normal.
		local a = make_ball(600, 900, 150, -200, 1)
		local b = make_ball(600, 900, -150, -200, 2)
		local balls = { a, b }
		local sink = GameplayEvents.new()

		step(balls, sink, 1)

		local dx = a.x - b.x
		local dy = a.y - b.y
		local dist = math.sqrt(dx * dx + dy * dy)
		assert_true(dist >= 2 * R - 0.5,
			"coincident spawns separate within one step, got " .. tostring(dist))
		assert_true(a.x > b.x, "the +vx ball ends to the right")
		assert_true(a.x == a.x and a.y == a.y and b.x == b.x and b.y == b.y,
			"no NaN is produced")
	end,

	test_event_reports_both_balls = function()
		local a = make_ball(300, 900, 800, 0, 1)
		local b = make_ball(360, 900, -800, 0, 2)
		local balls = { a, b }
		local sink = GameplayEvents.new()

		local contact = nil
		for i = 1, 20 do
			step(balls, sink, i)
			for _, ev in ipairs(raw_of_type(sink, "ball_contact_ball")) do
				if ev.ball_id == a.id and contact == nil then
					contact = ev
				end
			end
		end

		assert_true(contact ~= nil, "ball_contact_ball was emitted")
		assert_eq(contact.other_ball_id, b.id, "other_ball_id names the second ball")
		assert_true(contact.did_bounce, "head-on impact is a real bounce")
		assert_eq(contact.contact_kind, "sweep", "impact kind is a swept contact")
		assert_true(contact.other_outgoing_vx - contact.outgoing_vx > 0,
			"outgoing velocities separate along the normal")
	end,

	test_slow_contact_settles_without_bounce_flag = function()
		local a = make_ball(300, 900, 60, 0, 1)
		local b = make_ball(360, 900, 0, 0, 2)
		local balls = { a, b }
		local sink = GameplayEvents.new()
		local contact = nil

		for i = 1, 60 do
			step(balls, sink, i)
			for _, ev in ipairs(raw_of_type(sink, "ball_contact_ball")) do
				if ev.contact_kind == "sweep" and contact == nil then
					contact = ev
				end
			end
		end

		assert_true(contact ~= nil, "a swept ball-ball contact occurred")
		assert_false(contact.did_bounce,
			"sub-threshold relative speed is a settling contact, not a bounce")
	end,

	test_repeated_runs_are_deterministic = function()
		local function run()
			local a = make_ball(300, 900, 800, -100, 1)
			local b = make_ball(360, 900, -800, 50, 2)
			local balls = { a, b }
			local sink = GameplayEvents.new()
			local trace = {}
			for i = 1, 30 do
				step(balls, sink, i)
				table.insert(trace, { a.x, a.y, a.vx, a.vy, b.x, b.y, b.vx, b.vy })
			end
			return trace
		end

		local t1 = run()
		local t2 = run()
		for i = 1, #t1 do
			for j = 1, #t1[i] do
				assert_eq(t1[i][j], t2[i][j], "step " .. i .. " component " .. j .. " matches")
			end
		end
	end,

	test_single_ball_emits_no_ball_contacts = function()
		local a = make_ball(300, 900, 800, 0, 1)
		local balls = { a }
		local sink = GameplayEvents.new()

		for i = 1, 30 do
			step(balls, sink, i)
		end

		assert_eq(#raw_of_type(sink, "ball_contact_ball"), 0,
			"a lone ball never reports ball-ball contacts")
	end,

	test_disabled_flag_restores_pass_through = function()
		Config.ball_ball_collisions = false
		local a = make_ball(300, 900, 800, 0, 1)
		local b = make_ball(360, 900, -800, 0, 2)
		local balls = { a, b }
		local sink = GameplayEvents.new()

		for i = 1, 4 do
			step(balls, sink, i)
		end
		Config.ball_ball_collisions = true

		assert_true(a.x > b.x, "with collisions disabled the balls pass through")
		assert_eq(#raw_of_type(sink, "ball_contact_ball"), 0,
			"no ball-ball events while disabled")
	end,
}
