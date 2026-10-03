local Config = require("src.config")
local Peg = require("src.entities.peg")

local pegs = {}

local level_circuits = {
	c1 = {
		kind = "ellipse",
		amp_x = 50,
		amp_y = 50,
		rotate = true,
		speed = 2,
	},
}

for i = 140, 740, 100 do
	table.insert(pegs, Peg.new_rectangle(i, 200))
end
for i = 140, 740, 100 do
	table.insert(pegs, Peg.new(i, 250))
end
for i = 90, 790, 100 do
	table.insert(pegs, Peg.new(i, 300))
end
for i = 90, 790, 100 do
	table.insert(pegs, Peg.new(i, 400))
end
for i = 140, 740, 100 do
	table.insert(pegs, Peg.new(i, 450))
end

-- Left column of annular pegs facing upwards-right
for y = 150, 350, 70 do
	table.insert(pegs, Peg.new_annular(65, y, nil, 15, 30, math.rad(-90), math.rad(-30)))
end

-- Right column of annular pegs facing upwards-left
for y = 150, 350, 70 do
	table.insert(pegs, Peg.new_annular(815, y, nil, 15, 30, math.rad(-150), math.rad(-90)))
end

-- Moving circle pegs (last in the array: normalized peg order is preserved).
for i = 140, 740, 100 do
	local peg = Peg.new(i, 350)
	peg.motion = { circuit = "c1", phase = i / 100 }
	table.insert(pegs, peg)
end

return {
	pegs = pegs,
	level_circuits = level_circuits,
	type_counts = {
		red = 10,
		green = 2,
	},
	level_seed = 345,
	virtual_width = 880,
	virtual_height = 550,
}
