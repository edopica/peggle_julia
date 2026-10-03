-- Regression tests for the render-only contact presenter's handling of dense
-- contact. When a ball is in continuous contact (e.g. rolling around an
-- annular arc) impacts are recorded faster than the one presentation a
-- rendered frame can show. The presenter must never draw the ball at a stale
-- impact center, and must not leak non-presentable events in its queue.
local ContactEvents = require("src.systems.contact_events")

local function make_ball()
	return { radius = 6, draw_path = { path_step = 0 } }
end

local function record(ball, x, y, overrides)
	local data = {
		total_dt = 1, window = 1, toi = 0.5,
		isx = x, isy = y, move_x = 0, move_y = 0,
		type = "wall", kind = "sweep", did_bounce = true,
		nx = 0, ny = 1, vin_x = 0, vin_y = 0, vout_x = 0, vout_y = 0,
	}
	for k, v in pairs(overrides or {}) do data[k] = v end
	ContactEvents.record_collision(ball, data)
end

return {
	test_presents_newest_due_contact_not_stale_backlog = function()
		ContactEvents.clear()
		ContactEvents.presentation_enabled = true
		local ball = make_ball()
		local engine = { active_balls = { ball }, render_frame_id = 1 }

		-- Dense continuous contact: two impacts per step across ten steps.
		for step = 1, 10 do
			ball.draw_path.path_step = step
			ContactEvents.set_step(step)
			record(ball, step * 10, 0)
			record(ball, step * 10 + 5, 0)
		end

		-- Draw the latest step with alpha past every frame_t so all are due.
		ball.draw_path.path_step = 10
		ContactEvents.begin_frame(engine, 1.0)
		local x = ContactEvents.ball_override(ball)
		assert_true(x ~= nil, "ball should be overridden at a due contact")
		assert_eq(x, 105, "newest contact is presented, not the oldest backlog")

		ContactEvents.end_frame()
		assert_eq(#ContactEvents.queue, 0, "queue is drained after presentation")
	end,

	test_does_not_snap_to_stale_contact_while_newer_contact_pends = function()
		ContactEvents.clear()
		ContactEvents.presentation_enabled = true
		local ball = make_ball()
		local engine = { active_balls = { ball }, render_frame_id = 1 }

		-- Step 1 impact (now passed) ...
		ContactEvents.set_step(1)
		record(ball, 100, 0)
		-- ... followed by a newer step 2 impact at frame_t 0.9, not yet due.
		ContactEvents.set_step(2)
		record(ball, 200, 0, { toi = 0.9 })
		ball.draw_path.path_step = 2

		ContactEvents.begin_frame(engine, 0.1)
		assert_true(ContactEvents.ball_override(ball) == nil,
			"ball follows its interpolated path while a newer contact pends")

		ContactEvents.end_frame()
		assert_eq(#ContactEvents.queue, 1, "only the pending newer contact remains")
	end,

	test_non_presentable_events_do_not_leak = function()
		ContactEvents.clear()
		ContactEvents.presentation_enabled = true
		local ball = make_ball()
		local engine = { active_balls = { ball }, render_frame_id = 1 }

		ball.draw_path.path_step = 1
		ContactEvents.set_step(1)
		record(ball, 0, 0, { kind = "depenetrate", type = "peg", toi = 0 })

		ContactEvents.begin_frame(engine, 1.0)
		ContactEvents.end_frame()
		assert_eq(#ContactEvents.queue, 0, "depenetrate events do not leak")
	end,

	test_settle_contacts_are_not_presentable = function()
		ContactEvents.clear()
		ContactEvents.presentation_enabled = true
		local ball = make_ball()
		local engine = { active_balls = { ball }, render_frame_id = 1 }

		-- A swept contact that did not bounce (continuous/settle contact)
		-- must not force an exact-contact draw override.
		ball.draw_path.path_step = 1
		ContactEvents.set_step(1)
		record(ball, 50, 0, { did_bounce = false })

		ContactEvents.begin_frame(engine, 1.0)
		assert_true(ContactEvents.ball_override(ball) == nil,
			"settle contacts do not override the drawn ball position")

		ContactEvents.end_frame()
		assert_eq(#ContactEvents.queue, 0, "settle contacts do not leak")
	end,
}
