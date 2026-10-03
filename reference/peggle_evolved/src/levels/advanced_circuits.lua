-- Advanced Circuits: circle pegs riding one closed conveyor loop.
--
-- The visible segment approximates an exponential from just outside the left
-- wall (lower left) to just outside the upper-right side. The return segment
-- runs outside the right wall, above the ceiling, and outside the left wall,
-- so the loop is continuous with no teleport. All joins (including the seam)
-- are tangent-continuous cubic Hermite segments, checked by MotionSchema.
--
-- Peg phases are distances along the loop, so the pegs keep a fixed
-- arc-length spacing and enter/leave the playfield one after another.

local Path = require("src.systems.path")
local Peg = require("src.entities.peg")

local VIRTUAL_WIDTH = 1200
local VIRTUAL_HEIGHT = 1900

-- Visible exponential: x spans just outside both side walls; y rises from the
-- lower left toward the upper right.
local EXP_X0, EXP_X1 = -60, 1260
local EXP_Y0, EXP_Y1 = 900, 240
local EXP_K = 4
local VISIBLE_SEGMENTS = 8

-- Return waypoints, ordered after the visible exit: outside the right wall,
-- above the ceiling, outside the left wall, then back to the start.
local RETURN_POINTS = {
	{ 1380, -80 },
	{ 1300, -420 },
	{ 750, -600 },
	{ 60, -560 },
	{ -420, -300 },
	{ -520, 260 },
	{ -380, 720 },
}

-- Peg spacing along the loop and conveyor speed.
local PEG_SPACING = 48
local CONVEYOR_SPEED = 170

local function exp_point(u)
	local s = (math.exp(EXP_K * u) - 1) / (math.exp(EXP_K) - 1)
	return EXP_X0 + (EXP_X1 - EXP_X0) * u, EXP_Y0 + (EXP_Y1 - EXP_Y0) * s
end

local function exp_tangent(u)
	local dx = EXP_X1 - EXP_X0
	local dy = (EXP_Y1 - EXP_Y0) * EXP_K * math.exp(EXP_K * u) / (math.exp(EXP_K) - 1)
	local length = math.sqrt(dx * dx + dy * dy)
	return dx / length, dy / length
end

-- Ordered outline: the visible exponential first, then the hidden return.
local outline = {}
for i = 0, VISIBLE_SEGMENTS do
	local u = i / VISIBLE_SEGMENTS
	local x, y = exp_point(u)
	local tx, ty = exp_tangent(u)
	outline[#outline + 1] = { x = x, y = y, tx = tx, ty = ty }
end
for _, point in ipairs(RETURN_POINTS) do
	outline[#outline + 1] = { x = point[1], y = point[2] }
end

-- Return-point tangents use central differences over the closed outline; the
-- visible tangents stay analytic. The seam reuses the exponential start
-- tangent, so the closing join is tangent-continuous by construction.
for i, point in ipairs(outline) do
	if not point.tx then
		local previous = outline[(i - 2) % #outline + 1]
		local following = outline[i % #outline + 1]
		local tx = following.x - previous.x
		local ty = following.y - previous.y
		local length = math.sqrt(tx * tx + ty * ty)
		point.tx = tx / length
		point.ty = ty / length
	end
end

-- Cubic Hermite segments through the outline. Matching tangents at both
-- endpoints keep every join (and the seam) smooth.
local segments = {}
for i = 1, #outline do
	local from = outline[i]
	local to = outline[i % #outline + 1]
	local chord = math.sqrt((to.x - from.x) ^ 2 + (to.y - from.y) ^ 2)
	local scale = chord / 3
	segments[#segments + 1] = {
		kind = "cubic",
		p0 = { x = from.x, y = from.y },
		c1 = { x = from.x + from.tx * scale, y = from.y + from.ty * scale },
		c2 = { x = to.x - to.tx * scale, y = to.y - to.ty * scale },
		p1 = { x = to.x, y = to.y },
	}
end

local conveyor_path = Path.new({ segments = segments, closed = true })
-- Fail fast at load time on a non-smooth loop (also enforced by MotionSchema).
conveyor_path:validate_joins()

-- Pegs are spaced by arc length; each base is its own point on the loop, so
-- hidden-return pegs have genuine off-screen bases.
local loop_length = conveyor_path:length()
local peg_count = math.max(1, math.floor(loop_length / PEG_SPACING))
local pegs = {}
for i = 0, peg_count - 1 do
	local phase = (i / peg_count) * loop_length
	local x, y = conveyor_path:at_distance(phase)
	local peg = Peg.new(x, y, "blue")
	peg.motion = { circuit = "conveyor", phase = phase }
	pegs[#pegs + 1] = peg
end

return {
	pegs = pegs,
	level_circuits = {
		conveyor = {
			kind = "path",
			path = conveyor_path,
			speed = CONVEYOR_SPEED,
		},
	},
	type_counts = {
		red = 10,
		green = 2,
	},
	level_seed = 20260917,
	virtual_width = VIRTUAL_WIDTH,
	virtual_height = VIRTUAL_HEIGHT,
}
