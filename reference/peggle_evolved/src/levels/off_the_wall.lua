local Config = require("src.config")
local Peg = require("src.entities.peg")

local pegs = {}

-- Left column of pegs near the left wall
for y = 100, 450, 50 do
	table.insert(pegs, Peg.new(40, y))
end

-- Right column of pegs near the right wall
for y = 100, 450, 50 do
	table.insert(pegs, Peg.new(840, y))
end

return {
	pegs = pegs,
	type_counts = {
		red = 10,
		green = 2,
	},
	virtual_width = 880,
	virtual_height = 550,
}
