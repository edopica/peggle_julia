local Config = require("src.config")
local Peg = require("src.entities.peg")

local pegs = {}

local y = 450
local start_x = 140
local end_x = 740
local num_pegs = 15

for i = 0, num_pegs - 1 do
	local x = start_x + (end_x - start_x) * (i / (num_pegs - 1))
	table.insert(pegs, Peg.new(x, y))
end

return {
	pegs = pegs,
	level_circuits = {},
	type_counts = {
		red = 10,
	},
	name = "Lucky Bounce",
	virtual_width = 880,
	virtual_height = 550,
}
