-- Slide style-shot search level.
--
-- The launcher ball drops from (600, 50) straight down. Three zero-gap
-- generated lines offer slide surfaces:
--
--   * slide_rail   — a vertical line of touching circle pegs 16.25 px to the
--                    left of the launch column. The ball's center passes each
--                    peg with a constant 0.25 px miss inside the graze window
--                    (radius sums 16 px; graze tolerance 0.5 px), so it scores
--                    the whole line through non-bouncing grazes.
--   * slide_bricks — an oblique line of touching rectangle pegs left of the
--                    rail; the ball can be aimed to land above the row and
--                    slide along its top faces.
--   * slide_arc    — a parenthesis of touching annular pegs right of the rail,
--                    rotated so its opening faces up-left toward the launch;
--                    the ball can be shot through the opening and slide along
--                    the concave inner face.
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

-- Parenthesis of zero-gap annular pegs to the right, rotated so its opening
-- faces up-left toward the launch (theta = -45deg .. +135deg).
local arc = Path.new({
	{ kind = "arc", center = { 780, 720 }, radius = 240,
		theta_start = -math.pi / 4, sweep = math.pi },
})
local arc_pegs = Lines.generate({
	id = "slide_arc",
	path = arc,
	peg = { kind = "annular", thickness = 20, max_length = 40 },
	gap = 0,
})

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
table.insert(pegs, Peg.new(900, 400, "blue", 10))

return {
	pegs = pegs,
	type_counts = { red = 0, green = 0 },
	level_seed = 1,
	name = "Slide",
	virtual_width = virtual_width,
	virtual_height = 1900,
}
