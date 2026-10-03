-- Squiggly Circle: one continuous annular border around a sinusoidal radius.
--
-- The border follows the authored 96-segment cubic approximation of the polar
-- curve r(theta) = 350 + 30 * sin(6 * theta), centered at (600, 950). The
-- cubics use analytic polar endpoint tangents, and the closing seam reuses
-- the first sample so its endpoint and tangent are bit-identical.
--
-- curve_tolerance describes the authored cubic path, not the ideal polar
-- curve. A claim about the ideal polar curve would require a separate
-- source-error bound.
--
-- The border is zero-gap: Lines.generate proves that every neighboring pair
-- of generated annular pegs shares a full cap, including the closing seam,
-- before the level can load. The generated pegs are ordinary static pegs
-- with the existing scoring and removal behavior.
local Path = require("src.systems.path")
local Lines = require("src.systems.lines")

local CENTER = { x = 600, y = 950 }
local BASE_RADIUS = 350
local AMPLITUDE = 30
local WAVES = 6
local SEGMENTS = 96
local THICKNESS = 20
local MAX_LENGTH = 40
local CURVE_TOLERANCE = 0.25

local function polar_sample(theta)
	local radius = BASE_RADIUS + AMPLITUDE * math.sin(WAVES * theta)
	local dr = AMPLITUDE * WAVES * math.cos(WAVES * theta)
	local c, s = math.cos(theta), math.sin(theta)
	return { x = CENTER.x + radius * c, y = CENTER.y + radius * s }, {
		x = dr * c - radius * s,
		y = dr * s + radius * c,
	}
end

local step = math.pi * 2 / SEGMENTS
local points, tangents = {}, {}
for i = 0, SEGMENTS - 1 do
	points[i], tangents[i] = polar_sample(i * step)
end
points[SEGMENTS], tangents[SEGMENTS] = points[0], tangents[0]

local segments = {}
for i = 0, SEGMENTS - 1 do
	local p0, p1 = points[i], points[i + 1]
	local t0, t1 = tangents[i], tangents[i + 1]
	segments[i + 1] = {
		kind = "cubic",
		p0 = { x = p0.x, y = p0.y },
		c1 = { x = p0.x + t0.x * step / 3, y = p0.y + t0.y * step / 3 },
		c2 = { x = p1.x - t1.x * step / 3, y = p1.y - t1.y * step / 3 },
		p1 = { x = p1.x, y = p1.y },
	}
end

local border_path = Path.new({ segments = segments, closed = true })
-- Fail fast at load time on a non-smooth authored path.
border_path:validate_joins()

local pegs = Lines.generate({
	id = "squiggly_border",
	path = border_path,
	peg = { kind = "annular", thickness = THICKNESS, max_length = MAX_LENGTH },
	gap = 0,
	curve_tolerance = CURVE_TOLERANCE,
})

return {
	pegs = pegs,
	type_counts = { red = 10, green = 2 },
	level_seed = 20260918,
	name = "Squiggly Circle",
	virtual_width = 1200,
	virtual_height = 1900,
}
