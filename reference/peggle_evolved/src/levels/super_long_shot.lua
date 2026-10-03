local Config = require("src.config")
local Peg = require("src.entities.peg")

local pegs = {}

-- Distance between these two is 750px >= 700px (super_long_shot_distance)
table.insert(pegs, Peg.new(200, 200))
table.insert(pegs, Peg.new(200, 950))

return {
	pegs = pegs,
	level_circuits = {},
	type_counts = {
		red = 1,
		green = 1,
	},
	name = "Test Super Long Shot",
	virtual_width = 1200,
	virtual_height = 1900,
}
