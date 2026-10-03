-- ===========================================================================
-- BallState: per-ball lifecycle, idle, and no-score detection.
--
-- Owns the gameplay idle / stall / no-score timers that previously lived
-- directly in Engine.stepSimulation. Emits derived events and pushes a
-- `start_midturn_clearing` command when a mid-turn clear should begin.
--
-- Responsibilities:
--   * Per-ball idle tracking: a launched ball whose speed stays below
--     Config.ball_still_speed for Config.clear_still_time becomes idle
--     (`ball_became_idle` derived event on each transition into idle).
--   * Wake hysteresis: an IDLE ball reactivates only when its speed reaches
--     Config.ball_still_speed * Config.ball_wake_speed_multiplier. In the
--     hysteresis band (>= still, < wake) an idle ball stays idle, so a ball
--     hovering near the threshold does not flap. `ball_reactivated` fires
--     exactly once per idle-to-moving transition.
--   * `all_balls_became_idle` derived event when every launched ball is idle (latched
--     so it does not fire every step; the latch resets when a ball reactivates
--     or a new ball is spawned). One `start_midturn_clearing` command is
--     pushed per all-idle episode (on the same latch transition), not every
--     step — the Engine's application is idempotent.
--   * No-score timer: reset to 0 on every `peg_scored` event. When it reaches
--     Config.clear_no_score_time, emit `no_score_timeout_reached` (once per interval)
--     and push `start_midturn_clearing`.
--   * Style points do NOT reset the no-score timer.
--
-- A ball moved by an external moving object is not falsely declared idle:
-- idle is judged on the ball's own velocity magnitude (a ball carried by a
-- moving peg receives velocity from the contact response, so it is not idle).
--
-- Per-ball state is tracked across steps within a shot and reset on shot
-- start/completion.
-- ===========================================================================

local Config = require("src.config")

local BallState = {}
local BallState_mt = { __index = BallState }

function BallState.new()
	local self = setmetatable({}, BallState_mt)
	self:reset_shot()
	return self
end

function BallState:reset_shot()
	self.idle = {}             -- ball_id -> bool (currently in idle phase)
	self.idle_timer = {}      -- ball_id -> seconds below still speed
	self.reacted = {}          -- ball_id -> bool (reactivated since last idle entry)
	self.all_idle_latch = false
	self.no_score_timer = 0
	self.no_score_timeout_fired = false
end

local function ball_speed(b)
	return math.sqrt(b.vx * b.vx + b.vy * b.vy)
end

-- Process one completed fixed step.
--   events      = GameplayEvents instance (sealed; raw + derived available)
--   commands    = GameplayCommands instance
--   active_balls= engine.active_balls (launched balls only are considered)
--   dt          = fixed dt
--   opts        = optional overrides.
-- Returns nothing; pushes commands / emits derived events as needed.
--
-- NOTE: BallState emits derived events, so it must run AFTER seal_raw and
-- after the peg_scored derived events have been appended (so it can observe
-- them). The Engine calls this in the derived phase.
function BallState:process_step(events, commands, active_balls, dt, opts)
	opts = opts or {}
	local still_speed = opts.ball_still_speed or Config.ball_still_speed or 18
	local clear_still = opts.clear_still_time or Config.clear_still_time or 0.6
	local clear_no_score = opts.clear_no_score_time or Config.clear_no_score_time or 10.5
	-- Wake hysteresis: an idle ball must exceed still_speed * multiplier to
	-- reactivate (configurable; not hard-coded).
	local wake_mult = opts.ball_wake_speed_multiplier
		or Config.ball_wake_speed_multiplier or 1.5
	local wake_speed = still_speed * wake_mult

	-- Determine which balls are launched (only these are considered).
	local launched = {}
	for _, b in ipairs(active_balls) do
		if b.launched then
			table.insert(launched, b)
		end
	end

	-- Did any peg score this step? (resets no-score timer)
	local scored_this_step = false
	for _, ev in ipairs(events:derived()) do
		if ev.type == "peg_scored" then
			scored_this_step = true
			break
		end
	end

	if scored_this_step then
		self.no_score_timer = 0
		self.no_score_timeout_fired = false
	else
		self.no_score_timer = self.no_score_timer + dt
	end

	-- Per-ball idle tracking with wake hysteresis.
	local all_idle = #launched > 0
	for _, b in ipairs(launched) do
		local bid = b.id
		local speed = ball_speed(b)
		if self.idle[bid] then
			-- Idle: reactivate only above the wake threshold (hysteresis).
			if speed >= wake_speed then
				self.idle[bid] = false
				self.idle_timer[bid] = 0
				all_idle = false
				if not self.reacted[bid] then
					self.reacted[bid] = true
					events:emit_derived("ball_reactivated", { ball_id = bid })
				end
			end
			-- In the hysteresis band the ball stays idle (no timer change).
		else
			if speed >= still_speed then
				-- Active: any sustained slow-down restarts from zero.
				self.idle_timer[bid] = 0
				all_idle = false
			else
				self.idle_timer[bid] = (self.idle_timer[bid] or 0) + dt
				if self.idle_timer[bid] >= clear_still then
					self.idle[bid] = true
					-- A new idle->moving transition may reactivate again later.
					self.reacted[bid] = false
					events:emit_derived("ball_became_idle", { ball_id = bid })
				else
					-- Slow but not yet idle: prevents all-idle.
					all_idle = false
				end
			end
		end
	end

	-- All-idle latch: emit the event and push the clearing command exactly
	-- once per all-idle episode (not every step).
	if #launched > 0 and all_idle then
		if not self.all_idle_latch then
			self.all_idle_latch = true
			events:emit_derived("all_balls_became_idle", {})
			commands:push("start_midturn_clearing", { reason = "all_balls_became_idle" })
		end
	else
		-- A non-idle ball (or no launched balls) resets the episode latch.
		self.all_idle_latch = false
	end

	-- No-score timeout: emit once per interval, push midturn clearing.
	if self.no_score_timer >= clear_no_score and not self.no_score_timeout_fired then
		self.no_score_timeout_fired = true
		events:emit_derived("no_score_timeout_reached", {
			elapsed = self.no_score_timer,
		})
		commands:push("start_midturn_clearing", { reason = "no_score_timeout_reached" })
	end
end

-- Reset the idle/no-score timers (called after a mid-turn clear completes so
-- the ball can play on, or when a stall condition fires with no hit pegs).
function BallState:reset_timers()
	self.idle = {}
	self.idle_timer = {}
	self.reacted = {}
	self.all_idle_latch = false
	self.no_score_timer = 0
	self.no_score_timeout_fired = false
end

-- Notify that a new ball was spawned (resets all-idle latch).
function BallState:on_ball_spawned()
	self.all_idle_latch = false
end

-- Notify that a ball was removed.
function BallState:on_ball_removed(ball_id)
	self.idle[ball_id] = nil
	self.idle_timer[ball_id] = nil
	self.reacted[ball_id] = nil
end

return BallState
