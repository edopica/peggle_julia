-- ===========================================================================
-- ContactEvents: render-only collision-event queue.
--
-- Physics.update reports every physical collision (swept impacts, discrete
-- overlap pop-outs, end-of-frame de-penetrations; pegs, walls, extra
-- circles). Each event retains everything the renderer needs to present the
-- exact moment of contact later: sim/path step, frame_t, exact impact ball
-- center, peg identity/shape, peg transform at TOI, collision normal, and
-- incoming/outgoing velocity. Events live here — independently of
-- ball.draw_path — and are never cleared when Physics.update builds the next
-- draw_path.
--
-- The module is strictly read-only with respect to physics: it never touches
-- ball.x/y, velocities, time_remaining, iteration, RNG state, scoring, or
-- replay serialization. All it does is (a) optionally log per-draw samples
-- (--present-debug) and (b) when presentation is enabled, override the
-- *drawn* position of a ball (and the TOI transform of the involved peg) for
-- exactly one rendered frame per collision, and gate peg lighting on
-- peg.visual_hit so lighting begins on the same rendered frame as contact.
--
-- Presentation rules:
--   * Only swept bounces (kind == "sweep" and did_bounce) are presentable.
--     Settle/continuous contacts (did_bounce == false) are not presented:
--     they follow normal interpolation and light pegs immediately.
--     Graze-only visual hits never generate forced contact frames;
--     overlap/depenetrate events are retained for instrumentation but never
--     presented.
--   * An event is due when its path step has passed
--     (ball.draw_path.path_step > event.path_step) or when the current draw
--     alpha crosses the collision's frame_t on the event's own step.
--   * At most one event per ball is presented per frame (queue order is
--     chronological); each event is presented at most once and consumed only
--     after that frame finishes drawing.
--   * The queue is bounded (MAX_PENDING, FIFO drop) so pathological
--     multi-step-before-draw bursts cannot grow it without limit.
-- ===========================================================================

local ImpactGeometry = require("src.systems.impact_geometry")

local ContactEvents = {
	-- When false, the module only records/logs; rendering is untouched.
	-- Override with the CLI flag `--contact-present off` (A/B diagnostics).
	presentation_enabled = true,

	debug = false,
	file = nil,

	queue = {},          -- pending events (insertion order = chronological)
	dropped = 0,         -- cumulative FIFO drops from the bounded queue

	active_by_ball = {}, -- ball -> event presented this frame
	active_by_peg = {},  -- peg  -> event presented this frame
	pending_pegs = {},   -- peg  -> true (unpresented presentable events)

	current_step = 0,    -- sim step being recorded (set by the Engine)
	next_id = 0,
}

local MAX_PENDING = 64

-- Bounded free list of recycled event tables. Queue removal points release
-- tables here when no presentation map can still reference them (dead-ball
-- prune, end_frame consumption). FIFO drops are never recycled: while a frame
-- is in progress the dropped event may still be held by active_by_ball /
-- active_by_peg, and recycling it would alias the active map to a later event.
-- A released table has every field cleared, so the pool never retains a
-- ball/peg reference or stale presentation state.
local event_pool = {}
local POOL_CAP = MAX_PENDING

local function acquire_event()
	local n = #event_pool
	if n > 0 then
		local ev = event_pool[n]
		event_pool[n] = nil
		return ev
	end
	return {}
end

local function release_event(ev)
	if #event_pool >= POOL_CAP then
		return
	end
	ev.id = nil
	ev.ball = nil
	ev.path_step = nil
	ev.frame_t = nil
	ev.exact_x = nil
	ev.exact_y = nil
	ev.peg = nil
	ev.type = nil
	ev.kind = nil
	ev.nx = nil
	ev.ny = nil
	ev.vin_x = nil
	ev.vin_y = nil
	ev.vout_x = nil
	ev.vout_y = nil
	ev.presentable = nil
	ev.presented = nil
	ev.present_frame = nil
	ev.peg_index = nil
	ev.shape = nil
	ev.px = nil
	ev.py = nil
	ev.pangle = nil
	ev.ptheta = nil
	ev.due_step_passed = nil
	ev.due_alpha_crossed = nil
	event_pool[#event_pool + 1] = ev
end

-- Empty a map/list table in place (no allocation). Order-independent: only
-- the resulting empty table is observable.
local function clear_map(t)
	local k = next(t)
	while k ~= nil do
		t[k] = nil
		k = next(t, k)
	end
end

-- Persistent per-frame scratch maps (reused in place to avoid reallocating
-- hashes every rendered frame).
local newest_by_ball = {}
local latest_by_ball = {}
local latest_order = {}

-- Stable run-local ball ids without mutating ball tables.
local ball_ids = setmetatable({}, { __mode = "k" })
local next_ball_id = 0

local function ball_id(ball)
	local id = ball_ids[ball]
	if not id then
		next_ball_id = next_ball_id + 1
		id = next_ball_id
		ball_ids[ball] = id
	end
	return id
end

local function fmt(n)
	return string.format("%.12g", n)
end

-- JSON scalar for values that may be nil.
local function jval(v)
	if v == nil then
		return "null"
	end
	return tostring(v)
end

-- ---------------------------------------------------------------------------
-- Debug log lifecycle
-- ---------------------------------------------------------------------------

function ContactEvents.init_log(filename)
	ContactEvents.debug = true
	filename = filename or "temp/present_log.jsonl"
	ContactEvents.file = io.open(filename, "w")
	if ContactEvents.file then
		print("ContactEvents: logging presentation samples to " .. filename)
	else
		print("ContactEvents: FAILED to open " .. filename)
		ContactEvents.debug = false
	end
end

function ContactEvents.close()
	if ContactEvents.file then
		ContactEvents.file:close()
		ContactEvents.file = nil
	end
end

-- ---------------------------------------------------------------------------
-- Recording (called from Physics.update; cheap even when not debugging)
-- ---------------------------------------------------------------------------

function ContactEvents.set_step(step_id)
	ContactEvents.current_step = step_id
end

function ContactEvents.clear()
	clear_map(ContactEvents.active_by_ball)
	clear_map(ContactEvents.active_by_peg)
	clear_map(ContactEvents.pending_pegs)

	-- Fresh-module semantics: drop pending events (do not recycle them into
	-- the pool) and reset the pool free list; only the pool storage remains.
	for i = 1, #ContactEvents.queue do
		ContactEvents.queue[i] = nil
	end
	for i = 1, #event_pool do
		event_pool[i] = nil
	end

	ContactEvents.dropped = 0
end

-- data = { iter, toi, type, peg, overlap, isx, isy, move_x, move_y, window,
--          total_dt, vin_x, vin_y, vout_x, vout_y, nx, ny, kind }
function ContactEvents.record_collision(ball, data)
	ContactEvents.next_id = ContactEvents.next_id + 1

	local ev = acquire_event()
	ev.id = ContactEvents.next_id
	ev.ball = ball
	ev.path_step = ContactEvents.current_step
	ev.frame_t = ((data.total_dt - data.window) + data.toi * data.window) / data.total_dt
	ev.exact_x = data.isx + data.move_x * data.toi
	ev.exact_y = data.isy + data.move_y * data.toi
	ev.peg = data.peg
	ev.type = data.type
	ev.kind = data.kind
	ev.nx = data.nx
	ev.ny = data.ny
	ev.vin_x = data.vin_x
	ev.vin_y = data.vin_y
	ev.vout_x = data.vout_x
	ev.vout_y = data.vout_y
	ev.presentable = (data.kind == "sweep" and data.did_bounce == true)
	ev.presented = false
	ev.present_frame = nil
	ev.due_step_passed = nil
	ev.due_alpha_crossed = nil

	if data.peg then
		local px, py, pa, ptheta = ImpactGeometry.peg_transform_at_toi(data.peg, data.window, data.toi)
		ev.peg_index = data.peg.original_index or 0
		ev.shape = data.peg.shape or "circle"
		ev.px, ev.py, ev.pangle, ev.ptheta = px, py, pa, ptheta
	else
		ev.peg_index = 0
		ev.shape = (data.type == "wall") and "wall" or data.type
		ev.px = nil
		ev.py = nil
		ev.pangle = nil
		ev.ptheta = nil
	end

	if #ContactEvents.queue >= MAX_PENDING then
		-- Never recycle the dropped event: it may still be referenced by the
		-- active presentation maps until end_frame clears them.
		table.remove(ContactEvents.queue, 1)
		ContactEvents.dropped = ContactEvents.dropped + 1
	end
	table.insert(ContactEvents.queue, ev)
end

-- ---------------------------------------------------------------------------
-- Per-draw frame handling (called from Engine:draw)
-- ---------------------------------------------------------------------------

local function is_ball_active(engine, ball)
	for _, b in ipairs(engine.active_balls) do
		if b == ball then
			return true
		end
	end
	return false
end

-- due, step_passed, alpha_crossed
local function event_due(ev, alpha)
	local path = ev.ball.draw_path
	if not path then
		return false, false, false
	end
	local ps = path.path_step
	if not ps then
		return false, false, false
	end
	if ps > ev.path_step then
		return true, true, false
	end
	if ps == ev.path_step and alpha >= ev.frame_t then
		return true, false, true
	end
	return false, false, false
end

function ContactEvents.begin_frame(engine, alpha)
	-- Prune events whose ball left the simulation (caught / fell out / reset).
	local i = 1
	while i <= #ContactEvents.queue do
		if is_ball_active(engine, ContactEvents.queue[i].ball) then
			i = i + 1
		else
			release_event(table.remove(ContactEvents.queue, i))
		end
	end

	clear_map(ContactEvents.active_by_ball)
	clear_map(ContactEvents.active_by_peg)
	clear_map(ContactEvents.pending_pegs)

	if not ContactEvents.presentation_enabled then
		if ContactEvents.debug then
			ContactEvents.log_frame(engine, alpha)
		end
		return
	end

	-- Pegs with unpresented presentable events stay dark until contact.
	for _, ev in ipairs(ContactEvents.queue) do
		if ev.presentable and not ev.presented and ev.peg then
			ContactEvents.pending_pegs[ev.peg] = true
		end
	end

	-- Activate the most recent due event per ball. In dense continuous contact
	-- (e.g. a ball rolling around an annular arc) several impacts are recorded
	-- per simulation step — far more than the single presentation a rendered
	-- frame can show. Presenting the *earliest* due event makes the ball trail
	-- the queue by many steps and visibly jump between stale impact centers.
	-- Instead, consume every due event but override the ball's position only
	-- when the newest contact for that ball is itself due. If a newer contact
	-- is still pending, the ball is in ongoing contact, so it is drawn on its
	-- smooth interpolated path rather than snapped back to a stale impact.
	clear_map(newest_by_ball)
	for _, ev in ipairs(ContactEvents.queue) do
		if ev.presentable and not ev.presented then
			newest_by_ball[ev.ball] = ev
		end
	end

	clear_map(latest_by_ball)
	for i = #latest_order, 1, -1 do
		latest_order[i] = nil
	end
	for _, ev in ipairs(ContactEvents.queue) do
		if ev.presentable and not ev.presented then
			local due, step_passed, alpha_crossed = event_due(ev, alpha)
			if due then
				ev.presented = true
				ev.present_frame = engine.render_frame_id
				ev.due_step_passed = step_passed
				ev.due_alpha_crossed = alpha_crossed
				if ev.peg then
					ev.peg.visual_hit = true
				end
				if ev == newest_by_ball[ev.ball] then
					if not latest_by_ball[ev.ball] then
						table.insert(latest_order, ev.ball)
					end
					latest_by_ball[ev.ball] = ev
				end
			end
		end
	end
	for _, ball in ipairs(latest_order) do
		local ev = latest_by_ball[ball]
		ContactEvents.active_by_ball[ball] = ev
		if ev.peg then
			ContactEvents.active_by_peg[ev.peg] = ev
		end
	end

	if ContactEvents.debug then
		ContactEvents.log_frame(engine, alpha)
	end
end

function ContactEvents.end_frame()
	-- Consume events only after their presentation frame finished drawing.
	-- Non-presentable events (overlap/depenetrate) exist for instrumentation
	-- only and are never presented, so drop them here too; retaining them
	-- leaks queue slots and can FIFO-evict real swept impacts.
	clear_map(ContactEvents.active_by_ball)
	clear_map(ContactEvents.active_by_peg)
	local i = 1
	while i <= #ContactEvents.queue do
		local ev = ContactEvents.queue[i]
		if ev.presented or not ev.presentable then
			table.remove(ContactEvents.queue, i)
			release_event(ev)
		else
			i = i + 1
		end
	end
end

-- ---------------------------------------------------------------------------
-- Render queries (hot path; empty queue = single nil lookup)
-- ---------------------------------------------------------------------------

-- If the ball has an active contact presentation this frame, returns the
-- exact impact center to draw at; otherwise nil.
function ContactEvents.ball_override(ball)
	local ev = ContactEvents.active_by_ball[ball]
	if ev then
		return ev.exact_x, ev.exact_y
	end
	return nil
end

-- If the peg is involved in an active contact presentation this frame,
-- returns the event holding the peg's TOI transform; otherwise nil.
function ContactEvents.peg_override(peg)
	return ContactEvents.active_by_peg[peg]
end

-- Peg lighting (render state). peg.hit stays the gameplay state; a peg with a
-- pending presentable contact stays dark until the contact frame, where
-- begin_frame sets peg.visual_hit. Grazes and non-presentable hits have no
-- pending event, so they light immediately like before.
function ContactEvents.should_light(peg)
	if peg.visual_hit then
		return true
	end
	if peg.hit and not ContactEvents.pending_pegs[peg] then
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- PHASE 1 presentation logging (one JSONL record per Engine:draw)
-- ---------------------------------------------------------------------------

function ContactEvents.log_frame(engine, alpha)
	local file = ContactEvents.file
	if not file then
		return
	end

	-- Lazy requires (break module cycles; loaded long before first draw).
	local Ball = require("src.entities.ball")
	local Peg = require("src.entities.peg")
	local Screen = require("src.systems.screen")

	local f = { "{" }
	table.insert(f, '"render_frame":' .. engine.render_frame_id)
	table.insert(f, ',"sim_step":' .. engine.sim_step_id)
	table.insert(f, ',"steps_since_last_draw":' .. engine.steps_since_last_draw)
	table.insert(f, ',"accumulator":' .. fmt(engine.accumulator))
	table.insert(f, ',"alpha":' .. fmt(alpha))
	table.insert(f, ',"dt":' .. fmt(love.timer.getDelta()))
	local vsync = nil
	if love.window.getVSync then
		vsync = love.window.getVSync()
	end
	table.insert(f, ',"vsync":' .. jval(vsync))
	table.insert(f, ',"qsize":' .. #ContactEvents.queue)
	table.insert(f, ',"qdropped":' .. ContactEvents.dropped)

	-- Actual sampled ball positions (pure sample + presented position).
	table.insert(f, ',"balls":[')
	for bi, b in ipairs(engine.active_balls) do
		if bi > 1 then
			table.insert(f, ",")
		end
		local sx, sy = Ball.sampleDrawPosition(b, alpha)
		local dx, dy = sx, sy
		local ox, oy = ContactEvents.ball_override(b)
		if ox then
			dx, dy = ox, oy
		end
		local ps = (b.draw_path and b.draw_path.path_step) or -1
		table.insert(f, '{"id":' .. ball_id(b)
			.. ',"x":' .. fmt(dx) .. ',"y":' .. fmt(dy)
			.. ',"sx":' .. fmt(sx) .. ',"sy":' .. fmt(sy)
			.. ',"path_step":' .. ps
			.. ',"launched":' .. tostring(not not b.launched) .. "}")
	end
	table.insert(f, "]")

	-- Per pending/presented event: actual sampled peg transform and the
	-- signed world/screen surface separation at this presented frame.
	table.insert(f, ',"events":[')
	for ei, ev in ipairs(ContactEvents.queue) do
		if ei > 1 then
			table.insert(f, ",")
		end
		local bx, by = ev.exact_x, ev.exact_y
		if is_ball_active(engine, ev.ball) then
			bx, by = Ball.sampleDrawPosition(ev.ball, alpha)
			local ox, oy = ContactEvents.ball_override(ev.ball)
			if ox then
				bx, by = ox, oy
			end
		end

		table.insert(f, '{"id":' .. ev.id)
		table.insert(f, ',"ball":' .. ball_id(ev.ball))
		table.insert(f, ',"step":' .. ev.path_step)
		table.insert(f, ',"frame_t":' .. fmt(ev.frame_t))
		table.insert(f, ',"type":"' .. ev.type .. '"')
		table.insert(f, ',"kind":"' .. ev.kind .. '"')
		table.insert(f, ',"shape":"' .. ev.shape .. '"')
		table.insert(f, ',"ex":' .. fmt(ev.exact_x) .. ',"ey":' .. fmt(ev.exact_y))
		table.insert(f, ',"presented":' .. tostring(not not ev.presented))
		table.insert(f, ',"present_frame":' .. jval(ev.present_frame))
		table.insert(f, ',"due_step":' .. tostring(not not ev.due_step_passed))
		table.insert(f, ',"due_alpha":' .. tostring(not not ev.due_alpha_crossed))

		local sep_w = nil
		if ev.type == "wall" then
			sep_w = ImpactGeometry.wall_separation(ev.nx, ev.ny, bx, by, ev.ball.radius)
			table.insert(f, ',"peg":0')
		elseif ev.peg then
			local px, py, pa, pt
			local oev = ContactEvents.peg_override(ev.peg)
			if oev then
				px, py, pa, pt = oev.px, oev.py, oev.pangle, oev.ptheta
			else
				px, py, pa, pt = Peg.sampleDrawTransform(ev.peg, alpha)
			end
			sep_w = ImpactGeometry.surface_separation(ev.peg, px, py, pa or (ev.peg.angle or 0), pt, bx, by, ev.ball.radius)
			table.insert(f, ',"peg":' .. ev.peg_index)
			table.insert(f, ',"px":' .. fmt(px) .. ',"py":' .. fmt(py))
			table.insert(f, ',"pa":' .. fmt(pa or 0))
			if pt then
				table.insert(f, ',"pt":' .. fmt(pt))
			end
			table.insert(f, ',"lit":' .. tostring(ContactEvents.should_light(ev.peg)))
		else
			table.insert(f, ',"peg":0')
		end
		if sep_w then
			table.insert(f, ',"sep_w":' .. fmt(sep_w))
			table.insert(f, ',"sep_s":' .. fmt(sep_w * Screen.scale))
		end
		table.insert(f, "}")
	end
	table.insert(f, "]")

	table.insert(f, "}\n")
	file:write(table.concat(f))
end

return ContactEvents
