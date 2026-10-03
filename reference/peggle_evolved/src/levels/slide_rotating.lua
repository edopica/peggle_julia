-- Slide style-shot search level with a rotating arc.
--
-- A variant of src/levels/slide.lua that exercises the circuit peg-movement
-- system on a zero-gap slide surface:
--
--   * slide_rail   — a vertical line of touching circle pegs 16.25 px to the
--                    left of the launch column (unchanged, static).
--   * slide_bricks — an oblique line of touching rectangle pegs left of the
--                    rail (unchanged, static).
--   * slide_arc    — a parenthesis of touching annular pegs whose opening
--                    faces up-left toward the launch. The whole arc is attached
--                    to a single `rotate` circuit: every annular peg shares the
--                    arc center as its origin, so one common angular offset
--                    rotates the entire parenthesis rigidly around that center.
--
-- The arc center is pushed right of the rail so the rotating annulus clears
-- the static rail for a full revolution (the arc's outer radius would
-- otherwise sweep through the rail pegs). All arc pegs MUST share the same
-- phase: the `rotate` primitive applies one angular offset per circuit, and
-- differing phases would shear the zero-gap seams apart.
--
-- A run of five adjacent scored indices on any one line awards the slide style.
local Path = require("src.systems.path")
local Lines = require("src.systems.lines")
local Peg = require("src.entities.peg")

local virtual_width = 1200
local launch_x = virtual_width / 2

-- Vertical line of zero-gap circle pegs offset into the graze band.
local rail = Path.new({
	{ kind = "line", p0 = { launch_x - 16.25, 220 }, p1 = { launch_x - 16.25, 980 } },
})
local line_pegs = Lines.generate({
	id = "slide_rail",
	path = rail,
	peg = { kind = "circle", radius = 10 },
	gap = 0,
})

-- Oblique line of zero-gap rectangle pegs to the left of the rail.
local bricks = Path.new({
	{ kind = "line", p0 = { 170, 760 }, p1 = { 510, 1160 } },
})
local brick_pegs = Lines.generate({
	id = "slide_bricks",
	path = bricks,
	peg = { kind = "rectangle", width = 35, height = 18 },
	gap = 0,
})

-- Parenthesis of zero-gap annular pegs. Its center is offset to the right of
-- the rail so the full rotating sweep (outer radius 250) clears the rail.
local arc = Path.new({
	{ kind = "arc", center = { 900, 720 }, radius = 240,
		theta_start = -math.pi / 4, sweep = math.pi },
})
local arc_pegs = Lines.generate({
	id = "slide_arc",
	path = arc,
	peg = { kind = "annular", thickness = 20, max_length = 40 },
	gap = 0,
})

-- One shared circuit rotates every arc sector about the common arc center.
-- `rotate` returns (dx=0, dy=0, da = time * speed_angular); `Peg.set_transform`
-- rebuilds each annular sector from `base_theta_start + da`, so the whole
-- parenthesis spins rigidly. speed_angular = 1 rad/s gives a ~6.3 s revolution.
local level_circuits = {
	slide_arc_spin = {
		kind = "rotate",
		speed = 1,
		speed_angular = 1,
	},
}
for _, p in ipairs(arc_pegs) do
	p.motion = { circuit = "slide_arc_spin", phase = 0 }
end

local pegs = {}
for _, p in ipairs(line_pegs) do
	table.insert(pegs, p)
end
for _, p in ipairs(brick_pegs) do
	table.insert(pegs, p)
end
for _, p in ipairs(arc_pegs) do
	table.insert(pegs, p)
end
-- A lone anchor peg well away from the lines (no reds: fever cannot interrupt
-- a run mid-slide).
table.insert(pegs, Peg.new(1000, 400, "blue", 10))

return {
	pegs = pegs,
	level_circuits = level_circuits,
	type_counts = { red = 0, green = 0 },
	level_seed = 1,
	name = "Slide Rotating",
	virtual_width = virtual_width,
	virtual_height = 1900,
}
