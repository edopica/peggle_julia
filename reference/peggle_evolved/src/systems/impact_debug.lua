-- ===========================================================================
-- ImpactDebug: read-only instrumentation for Physics.update collisions.
--
-- Enabled via the CLI flag `--impact-debug [FILE]` (default
-- temp/impact_log.jsonl). When disabled (default), every public function is a
-- no-op so the physics hot path is unaffected. The module never mutates any
-- ball/peg state — it only observes, so dynamics are identical on or off.
--
-- Per physical collision (swept impact, discrete overlap pop-out, and
-- end-of-frame de-penetration) one JSONL record is written with:
--   frame, iter          simulation frame + substep iteration
--   ball                 stable ball id (weak-table keyed, run-local)
--   type, kind, peg, shape, circuit
--   toi, frame_t         normalized TOI (iteration window / whole fixed step)
--   step_x, step_y       ball position at fixed-step start
--   ic_x, ic_y           exact impact-center position at TOI
--   peg_x, peg_y, peg_a  peg transform at TOI (start-transform + relative
--                        motion model: end-of-step transform back-extrapolated
--                        by v * window * (1 - toi))
--   sep                  surface separation at TOI under that model
--   sep_end / sep_prev   same separation but against the raw end-of-step and
--                        start-of-step peg transforms (moving-peg model check)
--   vin_*, vout_*        impact velocity before/after the impulse
--   fin_x, fin_y         ball position at the end of the fixed step
--   draw_min_sep, draw_min_alpha
--                        minimum surface separation of the rendered
--                        (Ball.draw / Peg.draw interpolated) positions over
--                        alpha in [0,1]
-- A persistent marker is appended for every exact impact center and drawn by
-- Engine:draw via ImpactDebug.drawMarkers().
-- ===========================================================================

local LevelManager = require("src.systems.level_manager")
local ImpactGeometry = require("src.systems.impact_geometry")
local Ball = require("src.entities.ball")
local Peg = require("src.entities.peg")

local peg_transform_at_toi = ImpactGeometry.peg_transform_at_toi
local surface_separation = ImpactGeometry.surface_separation
local wall_separation = ImpactGeometry.wall_separation

local ImpactDebug = {
	enabled = false,
	file = nil,
	frame = 0,
	markers = {},
}

-- Stable run-local ball ids without mutating ball tables.
local ball_ids = setmetatable({}, { __mode = "k" })
local next_ball_id = 0

-- Per-ball context for the fixed step currently being processed.
local cur = nil

local function fmt(n)
	return string.format("%.12g", n)
end

function ImpactDebug.init(filename)
	ImpactDebug.enabled = true
	ImpactDebug.frame = 0
	ImpactDebug.markers = {}
	ball_ids = setmetatable({}, { __mode = "k" })
	next_ball_id = 0
	filename = filename or "temp/impact_log.jsonl"
	ImpactDebug.file = io.open(filename, "w")
	if ImpactDebug.file then
		print("ImpactDebug: logging collisions to " .. filename)
	else
		print("ImpactDebug: FAILED to open " .. filename)
		ImpactDebug.enabled = false
	end
end

function ImpactDebug.close()
	if ImpactDebug.file then
		ImpactDebug.file:close()
		ImpactDebug.file = nil
	end
end

local function ball_id(ball)
	local id = ball_ids[ball]
	if not id then
		next_ball_id = next_ball_id + 1
		id = next_ball_id
		ball_ids[ball] = id
	end
	return id
end

-- ---------------------------------------------------------------------------
-- Rendered-position separation (Ball.draw / Peg.draw interpolation)
-- ---------------------------------------------------------------------------

local function clamp01(a)
	if a < 0 then return 0 elseif a > 1 then return 1 end
	return a
end

-- Instrumentation samples the exact same calculations as the renderer.
local function ball_draw_pos(ball, alpha)
	return Ball.sampleDrawPosition(ball, alpha)
end

local function peg_draw_transform(peg, alpha)
	return Peg.sampleDrawTransform(peg, alpha)
end

-- Minimum rendered surface separation over alpha in [0,1].
-- Circle pegs: exact analytic minimum per draw_path segment (both
-- interpolations are linear in alpha within a segment, so |D(alpha)|^2 is a
-- quadratic). Other shapes: dense sampling + golden-section refinement.
local function min_draw_separation(ball, peg)
	local r = ball.radius
	local shape = peg.shape or "circle"

	if shape == "circle" then
		-- Peg center moves linearly over the whole frame.
		local ppx = peg.prev_x or peg.x
		local ppy = peg.prev_y or peg.y
		local pvx = peg.x - ppx
		local pvy = peg.y - ppy

		local best = math.huge
		local best_alpha = 0

		-- Build the list of linear pieces of the ball's drawn path.
		local pieces = {}
		local path = ball.draw_path
		if path and #path > 1 then
			for i = 1, #path - 1 do
				table.insert(pieces, { path[i], path[i + 1] })
			end
		else
			table.insert(pieces, {
				{ x = ball.prev_x or ball.x, y = ball.prev_y or ball.y, t = 0 },
				{ x = ball.x, y = ball.y, t = 1 },
			})
		end

		for _, seg in ipairs(pieces) do
			local p1, p2 = seg[1], seg[2]
			local lo, hi = clamp01(p1.t), clamp01(p2.t)
			if hi >= lo then
				local range = p2.t - p1.t
				-- Ball position as a function of alpha within this piece.
				-- b(alpha) = p1 + (p2 - p1) * (alpha - p1.t)/range  (range>0)
				local bvx, bvy = 0, 0
				if range > 0 then
					bvx = (p2.x - p1.x) / range
					bvy = (p2.y - p1.y) / range
				end
				-- D(alpha) = (p1 - p1.t*bv - peg_prev) + alpha*(bv - pv)
				local d0x = (p1.x - p1.t * bvx) - ppx
				local d0y = (p1.y - p1.t * bvy) - ppy
				local vx = bvx - pvx
				local vy = bvy - pvy
				local vv = vx * vx + vy * vy
				local candidates = { lo, hi }
				if vv > 0 then
					local a = -(d0x * vx + d0y * vy) / vv
					if a > lo and a < hi then
						table.insert(candidates, a)
					end
				end
				for _, a in ipairs(candidates) do
					local dx = d0x + vx * a
					local dy = d0y + vy * a
					local sep = math.sqrt(dx * dx + dy * dy) - r - peg.radius
					if sep < best then
						best = sep
						best_alpha = a
					end
				end
			end
		end
		return best, best_alpha
	end

	-- Rectangles / annulars: sample then refine around the best sample.
	local N = 400
	local function sep_at(a)
		local bx, by = ball_draw_pos(ball, a)
		local px, py, ang, theta = peg_draw_transform(peg, a)
		return surface_separation(peg, px, py, ang or (peg.angle or 0), theta, bx, by, r)
	end
	local best = math.huge
	local best_i = 0
	for i = 0, N do
		local s = sep_at(i / N)
		if s < best then
			best = s
			best_i = i
		end
	end
	-- Golden-section refinement on the bracketing interval.
	local lo = math.max(0, (best_i - 1) / N)
	local hi = math.min(1, (best_i + 1) / N)
	local gr = (math.sqrt(5) - 1) / 2
	local c = hi - gr * (hi - lo)
	local d = lo + gr * (hi - lo)
	local fc, fd = sep_at(c), sep_at(d)
	for _ = 1, 40 do
		if fc < fd then
			hi = d; d = c; fd = fc; c = hi - gr * (hi - lo); fc = sep_at(c)
		else
			lo = c; c = d; fc = fd; d = lo + gr * (hi - lo); fd = sep_at(d)
		end
	end
	local alpha = (lo + hi) / 2
	local s = sep_at(alpha)
	if s < best then
		return s, alpha
	end
	return best, best_i / N
end

-- ---------------------------------------------------------------------------
-- Recording hooks called from Physics.update (no-ops when disabled)
-- ---------------------------------------------------------------------------

function ImpactDebug.begin_frame()
	if not ImpactDebug.enabled then return end
	ImpactDebug.frame = ImpactDebug.frame + 1
end

function ImpactDebug.begin_ball(ball)
	if not ImpactDebug.enabled then return end
	cur = {
		ball = ball,
		id = ball_id(ball),
		sx = ball.x,
		sy = ball.y,
		records = {},
	}
end

-- Called at the collision-resolution site.
--   data = { iter, toi, type, peg, overlap, isx, isy, move_x, move_y, window,
--            total_dt, vin_x, vin_y, vout_x, vout_y, nx, ny, kind }
function ImpactDebug.record_collision(data)
	if not ImpactDebug.enabled or not cur then return end
	table.insert(cur.records, data)

	if data.kind ~= "depenetrate" then
		local icx = data.isx + data.move_x * data.toi
		local icy = data.isy + data.move_y * data.toi
		local color = { 1, 1, 1 }
		if data.type == "wall" then
			color = { 1, 0.9, 0.2 }
		elseif data.peg and data.peg.motion then
			color = { 1, 0.2, 1 }
		elseif data.peg then
			color = { 0.2, 1, 1 }
		end
		table.insert(ImpactDebug.markers, { x = icx, y = icy, color = color })
	end
end

-- Finalize per-ball records: stamp the end-of-step ball position, compute the
-- verification metrics, and flush JSON lines.
function ImpactDebug.end_ball(ball)
	if not ImpactDebug.enabled or not cur or cur.ball ~= ball then return end

	for _, rec in ipairs(cur.records) do
		local peg = rec.peg
		local icx = rec.isx + rec.move_x * rec.toi
		local icy = rec.isy + rec.move_y * rec.toi
		local frame_t = ((rec.total_dt - rec.window) + rec.toi * rec.window) / rec.total_dt

		local f = {
			'"frame":' .. ImpactDebug.frame,
			'"iter":' .. rec.iter,
			'"ball":' .. cur.id,
			'"type":"' .. rec.type .. '"',
			'"kind":"' .. rec.kind .. '"',
			'"toi":' .. fmt(rec.toi),
			'"frame_t":' .. fmt(frame_t),
			'"step_x":' .. fmt(cur.sx),
			'"step_y":' .. fmt(cur.sy),
			'"ic_x":' .. fmt(icx),
			'"ic_y":' .. fmt(icy),
			'"vin_x":' .. fmt(rec.vin_x),
			'"vin_y":' .. fmt(rec.vin_y),
			'"vout_x":' .. fmt(rec.vout_x),
			'"vout_y":' .. fmt(rec.vout_y),
			'"fin_x":' .. fmt(ball.x),
			'"fin_y":' .. fmt(ball.y),
			'"overlap":' .. fmt(rec.overlap or 0),
		}

		if rec.type == "wall" then
			table.insert(f, '"shape":"wall"')
			table.insert(f, '"sep":' .. fmt(wall_separation(rec.nx, rec.ny, icx, icy, ball.radius)))
		elseif peg then
			local shape = peg.shape or "circle"
			local px, py, pa, ptheta = peg_transform_at_toi(peg, rec.window, rec.toi)
			local sep = surface_separation(peg, px, py, pa, ptheta, icx, icy, ball.radius)
			-- Hypothesis checks against the raw stored transforms:
			-- end-of-step transform treated as static:
			local sep_end = surface_separation(peg, peg.x, peg.y, peg.angle or 0, peg.theta_start, icx, icy, ball.radius)
			-- start-of-step transform treated as static:
			local prev_x = peg.prev_x or peg.x
			local prev_y = peg.prev_y or peg.y
			local prev_a = peg.prev_angle or peg.angle or 0
			local prev_theta = peg.theta_start and (peg.theta_start - (peg.va or 0) * rec.total_dt) or nil
			local sep_prev = surface_separation(peg, prev_x, prev_y, prev_a, prev_theta, icx, icy, ball.radius)

			local dms, dma = min_draw_separation(ball, peg)

			table.insert(f, '"peg":' .. (peg.original_index or 0))
			table.insert(f, '"shape":"' .. shape .. '"')
			table.insert(f, '"circuit":' .. tostring(peg.motion ~= nil))
			table.insert(f, '"peg_x":' .. fmt(px))
			table.insert(f, '"peg_y":' .. fmt(py))
			table.insert(f, '"peg_a":' .. fmt(pa))
			table.insert(f, '"sep":' .. fmt(sep))
			table.insert(f, '"sep_end":' .. fmt(sep_end))
			table.insert(f, '"sep_prev":' .. fmt(sep_prev))
			table.insert(f, '"draw_min_sep":' .. fmt(dms))
			table.insert(f, '"draw_min_alpha":' .. fmt(dma))
		else
			table.insert(f, '"shape":"' .. rec.type .. '"')
		end

		ImpactDebug.file:write("{" .. table.concat(f, ",") .. "}\n")
	end
	ImpactDebug.file:flush()

	cur = nil
end

-- ---------------------------------------------------------------------------
-- Persistent markers drawn from Engine:draw (world coordinates)
-- ---------------------------------------------------------------------------

function ImpactDebug.drawMarkers()
	if not ImpactDebug.enabled then return end
	for _, m in ipairs(ImpactDebug.markers) do
		love.graphics.setColor(m.color[1], m.color[2], m.color[3], 0.9)
		love.graphics.circle("line", m.x, m.y, 3)
		love.graphics.circle("fill", m.x, m.y, 1)
	end
	love.graphics.setColor(1, 1, 1, 1)
end

return ImpactDebug
