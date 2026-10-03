local Config = require("src.config")
local Peg = require("src.entities.peg")

local pegs = {}

local function add_triangle(cx, cy)
	-- A 3-peg triangle pointing up
	table.insert(pegs, Peg.new(cx, cy))
	table.insert(pegs, Peg.new(cx - 20, cy + 34))
	table.insert(pegs, Peg.new(cx + 20, cy + 34))
end

-- Create 4 triangle groups spaced roughly ~500px apart in a zigzag
-- Distance between these centers is sqrt(400^2 + 300^2) = 500px, which is > 400px.
add_triangle(400, 300)
add_triangle(800, 600)
add_triangle(400, 900)
add_triangle(800, 1200)

return {
	pegs = pegs,
	level_circuits = {},
	type_counts = {
		red = 12,
		green = 0,
	},
	name = "Double Long Shot",
	virtual_width = 1200,
	virtual_height = 1900,
}
