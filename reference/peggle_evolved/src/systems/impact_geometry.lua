-- ===========================================================================
-- ImpactGeometry: pure geometry helpers shared by the collision
-- instrumentation (ImpactDebug) and the render-only contact presenter
-- (ContactEvents). No state, no mutation.
-- ===========================================================================

local LevelManager = require("src.systems.level_manager")

local ImpactGeometry = {}

local function dist_seg_sq(px, py, ax, ay, bx, by)
	local abx, aby = bx - ax, by - ay
	local t = 0
	local denom = abx * abx + aby * aby
	if denom > 0 then
		t = ((px - ax) * abx + (py - ay) * aby) / denom
		if t < 0 then t = 0 elseif t > 1 then t = 1 end
	end
	local cx, cy = ax + abx * t, ay + aby * t
	local dx, dy = px - cx, py - cy
	return dx * dx + dy * dy
end

-- Peg transform at the moment of impact. The physics engine stores the peg's
-- END-of-step transform plus its per-step velocity; broadPhasePass derives the
-- iteration-window-start transform as (x - vx * window). The transform at TOI
-- is therefore end - v * window * (1 - toi).
function ImpactGeometry.peg_transform_at_toi(peg, window, toi)
	local vx, vy, va = peg.vx or 0, peg.vy or 0, peg.va or 0
	local back = window * (1 - toi)
	local px = peg.x - vx * back
	local py = peg.y - vy * back
	local angle = (peg.angle or 0) - va * back
	local theta = peg.theta_start and (peg.theta_start - va * back) or nil
	return px, py, angle, theta
end

-- Signed surface separation between the ball (center icx/icy, radius r) and a
-- peg at the given transform. Positive = gap, negative = penetration.
function ImpactGeometry.surface_separation(peg, px, py, angle, theta_start, icx, icy, r)
	local shape = peg.shape or "circle"
	local dx, dy = icx - px, icy - py
	if shape == "circle" then
		return math.sqrt(dx * dx + dy * dy) - r - peg.radius
	elseif shape == "rectangle" then
		local ca, sa = math.cos(angle), math.sin(angle)
		local lx = dx * ca + dy * sa
		local ly = -dx * sa + dy * ca
		local hw = (peg.half_w or peg.width / 2)
		local hh = (peg.half_h or peg.height / 2)
		local qx = math.abs(lx) - hw
		local qy = math.abs(ly) - hh
		local ox = math.max(qx, 0)
		local oy = math.max(qy, 0)
		local sd = math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0)
		return sd - r
	elseif shape == "annular" then
		local d = math.sqrt(dx * dx + dy * dy)
		local ts = theta_start or peg.theta_start
		local te = peg.theta_end_abs - (peg.theta_start - ts) -- shift span by same delta
		local ang = math.atan2(dy, dx)
		local norm = (ang - ts) % (math.pi * 2)
		local in_arc = norm <= (te - ts + 0.001) or norm >= (math.pi * 2 - 0.001)
		if in_arc then
			if d > peg.r_out then
				return d - peg.r_out - r
			elseif d < peg.r_in then
				return peg.r_in - d - r
			else
				return -math.min(peg.r_out - d, d - peg.r_in) - r
			end
		end
		-- Outside the angular span: nearest solid points lie on the cap segments.
		local cs, ss = math.cos(ts), math.sin(ts)
		local ce, se = math.cos(te), math.sin(te)
		local d1 = dist_seg_sq(icx, icy, px + peg.r_in * cs, py + peg.r_in * ss, px + peg.r_out * cs, py + peg.r_out * ss)
		local d2 = dist_seg_sq(icx, icy, px + peg.r_in * ce, py + peg.r_in * se, px + peg.r_out * ce, py + peg.r_out * se)
		return math.sqrt(math.min(d1, d2)) - r
	end
	return 0
end

function ImpactGeometry.wall_separation(hit_nx, hit_ny, icx, icy, r)
	if hit_nx > 0 then
		return icx - r -- left wall
	elseif hit_nx < 0 then
		return LevelManager.virtual_width - icx - r -- right wall
	else
		return icy - r -- ceiling
	end
end

return ImpactGeometry
