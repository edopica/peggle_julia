local Config = require("src.config")
local ContactEvents = require("src.systems.contact_events")
local Peg = {}

-- Resolve a peg type definition, falling back to the default if unknown.
local function typeDef(type)
	return Config.peg_types[type] or Config.peg_types[Config.default_peg_type]
end

function Peg.new(x, y, type, radius)
	return {
		x = x,
		y = y,
		base_x = x,
		base_y = y,
		vx = 0,
		vy = 0,
		radius = radius or Config.peg_radius,
		type = type or Config.default_peg_type,
		hit = false, -- true once the ball has touched it (lights up)
	}
end

function Peg.new_rectangle(x, y, type, width, height, angle)
	return {
		x = x,
		y = y,
		base_x = x,
		base_y = y,
		base_angle = angle or 0,
		vx = 0,
		vy = 0,
		width = width or Config.peg_rect_width,
		height = height or Config.peg_rect_height,
		angle = angle or 0,
		shape = "rectangle",
		type = type or Config.default_peg_type,
		hit = false,
	}
end

-- Annular polygon vertex count. A full turn keeps the historical
-- max(16, floor(r_out * 0.4)) resolution (roughly 15.7 px of arc per
-- segment); a partial sector scales that count down with its angular span so
-- narrow generated pieces keep the same physical chord resolution instead of
-- carrying hundreds of near-duplicate vertices into overlap SAT and drawing.
-- The count is fixed at construction because the sector's span never changes.
local MIN_ANNULAR_SEGMENTS = 4
local function annular_segments(r_out, span)
	local full = math.max(16, math.floor(r_out * 0.4))
	if span == nil then return full end
	local scaled = math.ceil(math.abs(span) / (math.pi * 2) * full)
	if scaled < MIN_ANNULAR_SEGMENTS then scaled = MIN_ANNULAR_SEGMENTS end
	if scaled > full then scaled = full end
	return scaled
end

local function annular_polygon_len(r_in, r_out, span)
	local segments = annular_segments(r_out, span)
	if r_in == 0 then
		return 2 * (segments + 1) + 2
	end
	return 4 * (segments + 1)
end

-- Rebuild the full annular collision/draw geometry at the given rotation
-- offset (da). Mutates the preallocated corner/normal/polygon buffers in
-- place: no per-step allocation. Callers that only translate should use the
-- in-place translation path in Peg.set_transform instead.
local function rebuild_annular_geometry(peg, angle)
	local theta_start = peg.base_theta_start + angle
	local theta_end_abs = peg.base_theta_end_abs + angle
	peg.theta_start = theta_start
	peg.theta_end_abs = theta_end_abs

	local r_in = peg.r_in
	local r_out = peg.r_out
	local x = peg.x
	local y = peg.y

	local cos_s, sin_s = math.cos(theta_start), math.sin(theta_start)
	local cos_e, sin_e = math.cos(theta_end_abs), math.sin(theta_end_abs)

	local c1, c2, c3, c4 = peg.corners[1], peg.corners[2], peg.corners[3], peg.corners[4]
	c1.x = x + r_in * cos_s;  c1.y = y + r_in * sin_s
	c2.x = x + r_out * cos_s; c2.y = y + r_out * sin_s
	c3.x = x + r_in * cos_e;  c3.y = y + r_in * sin_e
	c4.x = x + r_out * cos_e; c4.y = y + r_out * sin_e

	peg.normal_start.x = sin_s;  peg.normal_start.y = -cos_s
	peg.normal_end.x = -sin_e;   peg.normal_end.y = cos_e

	local polygon = peg.polygon
	local segments = peg.segments
	local span = theta_end_abs - theta_start
	local idx = 0
	for i = 0, segments do
		local angle_p = theta_start + span * (i / segments)
		idx = idx + 1; polygon[idx] = x + r_out * math.cos(angle_p)
		idx = idx + 1; polygon[idx] = y + r_out * math.sin(angle_p)
	end
	if r_in == 0 then
		idx = idx + 1; polygon[idx] = x
		idx = idx + 1; polygon[idx] = y
	else
		for i = segments, 0, -1 do
			local angle_p = theta_start + span * (i / segments)
			idx = idx + 1; polygon[idx] = x + r_in * math.cos(angle_p)
			idx = idx + 1; polygon[idx] = y + r_in * math.sin(angle_p)
		end
	end
end

function Peg.new_annular(x, y, type, r_in, r_out, theta_start, theta_end)
	local theta_end_abs = theta_end
	while theta_end_abs <= theta_start do
		theta_end_abs = theta_end_abs + math.pi * 2
	end

	local peg = {
		x = x,
		y = y,
		base_x = x,
		base_y = y,
		base_theta_start = theta_start,
		base_theta_end_abs = theta_end_abs,
		vx = 0,
		vy = 0,
		r_in = r_in,
		r_out = r_out,
		theta_start = theta_start,
		theta_end_abs = theta_end_abs,
		segments = annular_segments(r_out, theta_end_abs - theta_start),
		shape = "annular",
		type = type or Config.default_peg_type,
		hit = false,
	}

	peg.corners = {
		{ x = 0, y = 0 },
		{ x = 0, y = 0 },
		{ x = 0, y = 0 },
		{ x = 0, y = 0 },
	}
	peg.normal_start = { x = 0, y = 0 }
	peg.normal_end = { x = 0, y = 0 }
	peg.polygon = {}
	local polygon_len = annular_polygon_len(r_in, r_out, theta_end_abs - theta_start)
	for i = 1, polygon_len do
		peg.polygon[i] = 0
	end
	peg.prev_rot = 0
	rebuild_annular_geometry(peg, 0)

	return peg
end

-- Translate-only annular geometry update (no polygon reallocation).
local function translate_annular_geometry(peg, dx, dy)
	for _, c in ipairs(peg.corners) do
		c.x = c.x + dx
		c.y = c.y + dy
	end
	for i = 1, #peg.polygon, 2 do
		peg.polygon[i] = peg.polygon[i] + dx
		peg.polygon[i + 1] = peg.polygon[i + 1] + dy
	end
end

-- Set the peg's end transform for this step.
--
-- Contract (used by CCD — see Circuits.update and
-- ImpactGeometry.peg_transform_at_toi): the transform is the step-END
-- position and `peg.angle` is the applied rotation offset for every shape.
-- Per-step velocities are computed by the caller as the secant
-- (end - start) / dt.
function Peg.set_transform(peg, new_x, new_y, new_angle)
	local dx = new_x - peg.x
	local dy = new_y - peg.y
	peg.x = new_x
	peg.y = new_y

	if new_angle ~= nil then
		peg.angle = new_angle
	end

	if peg.shape == "rectangle" then
		local angle = peg.angle or 0
		peg.cos_a = math.cos(angle)
		peg.sin_a = math.sin(angle)
	elseif peg.shape == "annular" then
		-- Rebuild from the base geometry whenever the applied rotation
		-- changes — including returning to zero. This keeps theta_start /
		-- theta_end_abs consistent with peg.angle for every shape. A
		-- translation with unchanged rotation updates geometry in place
		-- (no polygon reallocation).
		local applied = peg.angle or 0
		if applied ~= peg.prev_rot then
			rebuild_annular_geometry(peg, applied)
			peg.prev_rot = applied
		elseif dx ~= 0 or dy ~= 0 then
			translate_annular_geometry(peg, dx, dy)
		end
	end
end

-- Point value of a single peg, based on its type.
-- In-place check that is safe to run.
function Peg.value(peg)
	return typeDef(peg.type).value
end

-- Pure interpolated draw transform for a given alpha. This is exactly the
-- transform Peg.draw uses, factored out so instrumentation and rendering
-- always agree. Returns draw_x, draw_y plus:
--   rectangle: draw_angle (3rd value)
--   annular:   drawn theta_start (4th value; polygon is rotated by the
--              offset from the current peg.theta_start)
function Peg.sampleDrawTransform(peg, alpha)
	alpha = alpha or 1
	local draw_x = (peg.prev_x or peg.x) + (peg.x - (peg.prev_x or peg.x)) * alpha
	local draw_y = (peg.prev_y or peg.y) + (peg.y - (peg.prev_y or peg.y)) * alpha
	if peg.shape == "rectangle" then
		local draw_angle = (peg.prev_angle or peg.angle) + (peg.angle - (peg.prev_angle or peg.angle)) * alpha
		return draw_x, draw_y, draw_angle or 0, nil
	elseif peg.shape == "annular" then
		local prev_da = peg.prev_angle or 0
		local curr_da = peg.angle or 0
		local draw_angle_offset = prev_da + (curr_da - prev_da) * alpha - curr_da
		return draw_x, draw_y, nil, peg.theta_start + draw_angle_offset
	end
	return draw_x, draw_y, nil, nil
end

function Peg.draw(peg, alpha)
	alpha = alpha or 1
	local color = typeDef(peg.type).color
	local r, g, b = color[1], color[2], color[3]

	if ContactEvents.should_light(peg) then
		-- Light up: blend the base color toward white.
		local t = Config.peg_lit_blend
		r = r + (1 - r) * t
		g = g + (1 - g) * t
		b = b + (1 - b) * t
	end

	local draw_x, draw_y, draw_angle, draw_theta = Peg.sampleDrawTransform(peg, alpha)

	-- Render-only contact presentation: for exactly one frame, draw this peg
	-- at its retained time-of-impact transform.
	local oev = ContactEvents.peg_override(peg)
	if oev then
		draw_x, draw_y = oev.px, oev.py
		if oev.pangle then
			draw_angle = oev.pangle
		end
		if oev.ptheta then
			draw_theta = oev.ptheta
		end
	end

	love.graphics.setColor(r, g, b)
	if peg.shape == "rectangle" then
		love.graphics.push()
		love.graphics.translate(draw_x, draw_y)
		love.graphics.rotate(draw_angle or 0)
		love.graphics.rectangle("fill", -peg.width / 2, -peg.height / 2, peg.width, peg.height)
		love.graphics.pop()
	elseif peg.shape == "annular" then
		local draw_angle_offset = (draw_theta or peg.theta_start) - peg.theta_start
		love.graphics.push()
		love.graphics.translate(draw_x, draw_y)
		love.graphics.rotate(draw_angle_offset)
		love.graphics.translate(-peg.x, -peg.y)
		love.graphics.polygon("fill", peg.polygon)
		love.graphics.pop()
	else
		love.graphics.circle("fill", draw_x, draw_y, peg.radius)
	end
end

return Peg
