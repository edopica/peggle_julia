-- BallState unit tests.
local BallState = require("src.systems.ball_state")
local GameplayEvents = require("src.systems.gameplay_events")
local GameplayCommands = require("src.systems.gameplay_commands")
local Config = require("src.config")

local function make_ball(id, vx, vy, launched)
	return {
		id = id, x = 100, y = 100, prev_x = 100, prev_y = 100,
		vx = vx or 0, vy = vy or 0, radius = 6,
		launched = (launched == nil) and true or launched,
	}
end

-- Run one step of BallState over a fresh events/commands pair.
local function run_step(bs, balls, dt, emit_scored)
	local ev = GameplayEvents.new()
	local cmds = GameplayCommands.new()
	ev:begin_step(1, 1)
	if emit_scored then
		ev:emit_raw("ball_contacted_peg", { ball_id = 1, peg_id = 1 })
		ev:seal_raw()
		ev:emit_derived("peg_scored", { peg_id = 1, ball_id = 1 })
	else
		ev:seal_raw()
	end
	bs:process_step(ev, cmds, balls, dt or Config.fixed_dt)
	ev:finish_step()
	return ev, cmds
end

local function has_derived(ev, type)
	for _, e in ipairs(ev:derived()) do
		if e.type == type then return true end
	end
	return false
end

local function has_command(cmds, type)
	for _, c in ipairs(cmds:all()) do
		if c.type == type then return true end
	end
	return false
end

return {
	setup = function()
		Config.ball_still_speed = 18
		Config.clear_still_time = 0.6
		Config.clear_no_score_time = 10.5
	end,

	test_active_to_slow_to_idle = function()
		local bs = BallState.new()
		-- Moving ball, then slow for clear_still_time -> idle.
		run_step(bs, { make_ball(1, 100, 100) })
		assert_false(bs.idle[1], "moving ball not idle")
		-- Below still speed for enough steps.
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		for _ = 1, steps do
			run_step(bs, { make_ball(1, 1, 1) })
		end
		assert_true(bs.idle[1], "ball became idle after sustained slow speed")
	end,

	test_wake_hysteresis_one_reactivated = function()
		local bs = BallState.new()
		-- Drive to idle.
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		for _ = 1, steps do run_step(bs, { make_ball(1, 0, 0) }) end
		assert_true(bs.idle[1])
		-- Wake: moving again.
		local ev = run_step(bs, { make_ball(1, 100, 100) })
		assert_true(has_derived(ev, "ball_reactivated"), "reactivated emitted")
		-- Another moving step must not re-emit reactivated.
		local ev2 = run_step(bs, { make_ball(1, 100, 100) })
		assert_false(has_derived(ev2, "ball_reactivated"), "reactivated only once")
	end,

	test_moving_ball_prevents_all_idle = function()
		local bs = BallState.new()
		local ev = run_step(bs, { make_ball(1, 200, 200) })
		assert_false(has_derived(ev, "all_balls_became_idle"), "moving ball prevents all idle")
	end,

	test_removed_balls_not_considered = function()
		local bs = BallState.new()
		-- One idle ball + one moving. Remove the idle one; all_idle should not
		-- fire because the remaining ball is moving.
		run_step(bs, { make_ball(1, 0, 0), make_ball(2, 100, 100) })
		bs:on_ball_removed(1)
		local ev = run_step(bs, { make_ball(2, 100, 100) })
		assert_false(has_derived(ev, "all_balls_became_idle"))
	end,

	test_newly_spawned_ball_resets_all_idle_latch = function()
		local bs = BallState.new()
		-- Make all balls idle.
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		for _ = 1, steps do run_step(bs, { make_ball(1, 0, 0) }) end
		assert_true(bs.idle[1])
		-- all_idle latch should now be set.
		assert_true(bs.all_idle_latch)
		-- Spawn a new ball -> resets latch; the new ball is moving.
		bs:on_ball_spawned()
		bs.idle[1] = nil -- simulate removal or keep; we add a new moving ball
		local ev = run_step(bs, { make_ball(1, 0, 0), make_ball(2, 200, 200) })
		assert_false(has_derived(ev, "all_balls_became_idle"), "spawn resets latch")
	end,

	test_peg_scoring_resets_no_score_timer = function()
		local bs = BallState.new()
		-- Run many steps scoring pegs: no_score_timer stays 0.
		for _ = 1, 100 do
			run_step(bs, { make_ball(1, 50, 50) }, Config.fixed_dt, true)
		end
		assert_eq(bs.no_score_timer, 0, "peg scoring resets no-score timer")
		assert_false(bs.no_score_timeout_fired)
	end,

	test_style_points_do_not_reset_no_score_timer = function()
		-- BallState only resets on peg_scored; a style_awarded event must not.
		-- We simulate by NOT emitting peg_scored but advancing time; the timer
		-- accumulates. There is no style event path into BallState, so this
		-- confirms BallState does not react to style.
		local bs = BallState.new()
		local ev = GameplayEvents.new()
		local cmds = GameplayCommands.new()
		ev:begin_step(1, 1)
		ev:seal_raw()
		-- A style-derived event (not peg_scored) should be ignored.
		ev:emit_derived("style_awarded", { style = "long_shot", points = 1000 })
		bs:process_step(ev, cmds, { make_ball(1, 50, 50) }, Config.fixed_dt)
		ev:finish_step()
		assert_true(bs.no_score_timer > 0, "style does not reset no-score timer")
	end,

	test_timeout_emits_once_per_interval = function()
		local bs = BallState.new()
		local timeouts = 0
		-- Run well past the no-score threshold without scoring.
		local total = 0
		for _ = 1, 1000 do
			local ev, cmds = run_step(bs, { make_ball(1, 50, 50) }, Config.fixed_dt, false)
			for _, e in ipairs(ev:derived()) do
				if e.type == "no_score_timeout_reached" then timeouts = timeouts + 1 end
			end
			total = total + Config.fixed_dt
			if total > Config.clear_no_score_time * 2 then break end
		end
		assert_eq(timeouts, 1, "no_score_timeout_reached emitted once per interval")
	end,

	test_all_idle_does_not_emit_every_step = function()
		local bs = BallState.new()
		-- Drive to all-idle.
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		for _ = 1, steps do run_step(bs, { make_ball(1, 0, 0) }) end
		-- Continue being idle: all_idle must not re-emit.
		local all_idle_count = 0
		for _ = 1, 5 do
			local ev = run_step(bs, { make_ball(1, 0, 0) })
			for _, e in ipairs(ev:derived()) do
				if e.type == "all_balls_became_idle" then all_idle_count = all_idle_count + 1 end
			end
		end
		assert_eq(all_idle_count, 0, "all_idle latched; not every step")
	end,

	test_ball_moved_by_external_object_not_idle = function()
		-- A ball carried by a moving peg receives velocity from the contact
		-- response; idle is judged on the ball's own velocity magnitude. A
		-- ball with nonzero velocity is not idle even if its position was
		-- externally nudged.
		local bs = BallState.new()
		local b = make_ball(1, 30, 0) -- above still_speed
		b.x = 200 -- externally moved, but velocity is nonzero
		run_step(bs, { b })
		assert_false(bs.idle[1], "nonzero velocity is not idle")
	end,

	test_idle_pushes_midturn_clearing_command = function()
		local bs = BallState.new()
		-- Drive to all-idle; expect a start_midturn_clearing command.
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		local found = false
		for _ = 1, steps do
			local ev, cmds = run_step(bs, { make_ball(1, 0, 0) })
			if has_command(cmds, "start_midturn_clearing") then found = true end
		end
		assert_true(found, "idle pushes start_midturn_clearing")
	end,

	-- ===================================================================
	-- Wake hysteresis & per-episode command cadence (Phase 2 hardening)
	-- ===================================================================

	test_hysteresis_band_keeps_ball_idle = function()
		local bs = BallState.new()
		local wake = Config.ball_still_speed * Config.ball_wake_speed_multiplier
		-- Drive to idle with a fully-still ball.
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		for _ = 1, steps do run_step(bs, { make_ball(1, 0, 0) }) end
		assert_true(bs.idle[1])
		-- Speed inside the hysteresis band [still, wake): stays idle, no event.
		local band_speed = (Config.ball_still_speed + wake) / 2
		local ev = run_step(bs, { make_ball(1, band_speed, 0) })
		assert_true(bs.idle[1], "band speed keeps the ball idle (hysteresis)")
		assert_false(has_derived(ev, "ball_reactivated"), "no reactivation in band")
		-- At/above wake speed: reactivates.
		local ev2 = run_step(bs, { make_ball(1, wake, 0) })
		assert_false(bs.idle[1], "wake speed reactivates")
		assert_true(has_derived(ev2, "ball_reactivated"))
	end,

	test_reactivated_fires_once_per_transition = function()
		local bs = BallState.new()
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		-- First idle episode.
		for _ = 1, steps do run_step(bs, { make_ball(1, 0, 0) }) end
		local ev1 = run_step(bs, { make_ball(1, 200, 0) })
		assert_true(has_derived(ev1, "ball_reactivated"), "first wake fires")
		-- Second idle episode: ball_became_idle must re-fire, then reactivated again.
		local saw_idle2 = false
		for _ = 1, steps do
			local ev = run_step(bs, { make_ball(1, 0, 0) })
			if has_derived(ev, "ball_became_idle") then saw_idle2 = true end
		end
		assert_true(saw_idle2, "ball_became_idle fires on re-entry into idle")
		local ev2 = run_step(bs, { make_ball(1, 200, 0) })
		assert_true(has_derived(ev2, "ball_reactivated"),
			"reactivated fires once per idle-to-moving transition")
	end,

	test_all_idle_pushes_clearing_once_per_episode = function()
		local bs = BallState.new()
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		local push_steps = 0
		for _ = 1, steps + 5 do
			local ev, cmds = run_step(bs, { make_ball(1, 0, 0) })
			if has_command(cmds, "start_midturn_clearing") then
				push_steps = push_steps + 1
			end
		end
		assert_eq(push_steps, 1, "one clearing command per all-idle episode")
	end,

	test_clearing_episode_retriggers_after_timer_reset = function()
		local bs = BallState.new()
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		local function count_pushes()
			local n = 0
			for _ = 1, steps + 2 do
				local ev, cmds = run_step(bs, { make_ball(1, 0, 0) })
				if has_command(cmds, "start_midturn_clearing") then n = n + 1 end
			end
			return n
		end
		assert_eq(count_pushes(), 1, "first episode pushes once")
		-- Engine's no-hit-pegs path resets timers; the episode may re-fire.
		bs:reset_timers()
		assert_eq(count_pushes(), 1, "after reset, a new episode pushes once more")
	end,

	test_ball_idle_fires_on_each_idle_entry = function()
		local bs = BallState.new()
		local steps = math.ceil(Config.clear_still_time / Config.fixed_dt) + 1
		local idle_events = 0
		for _ = 1, steps do
			local ev = run_step(bs, { make_ball(1, 0, 0) })
			if has_derived(ev, "ball_became_idle") then idle_events = idle_events + 1 end
		end
		assert_eq(idle_events, 1, "ball_became_idle fires once on entry")
		-- Staying idle: no repeat.
		for _ = 1, 3 do
			local ev = run_step(bs, { make_ball(1, 0, 0) })
			if has_derived(ev, "ball_became_idle") then idle_events = idle_events + 1 end
		end
		assert_eq(idle_events, 1, "no repeat while continuously idle")
	end,
}
