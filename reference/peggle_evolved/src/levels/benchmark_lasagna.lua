local Peg = require("src.entities.peg")

local pegs = {}

local level_circuits = {
	layer_1_move = {
		speed = 1.5,
		kind = "oscillate_x",
		amp = 150,
	},
	layer_2_wave = {
		speed = 2.0,
		kind = "oscillate_y",
		amp = 30,
		frequency = 3,
	},
	layer_3_rotate = {
		speed = 1.0,
		kind = "rotate",
		speed_angular = 2,
	},
}

-- 7 lasagna blocks to fill the high height. Pegs are emitted per circuit
-- layer (matching the normalized peg order).
for block_index = 1, 7 do
	local block_y = 200 + (block_index - 1) * 240
	-- Layer 1: rectangles moving horizontally back and forth
	local y1 = block_y
	for x = 200, 1000, 100 do
		local peg = Peg.new_rectangle(x, y1, nil, 40, 15)
		peg.motion = {
			circuit = "layer_1_move",
			phase = (block_index % 2 == 0) and math.pi or 0,
		}
		table.insert(pegs, peg)
	end
end

for block_index = 1, 7 do
	local block_y = 200 + (block_index - 1) * 240
	-- Layer 2: circular pegs following a wave pattern
	local y2 = block_y + 80
	for x = 150, 1050, 60 do
		local wy = y2 + math.sin(x / 50) * 20
		local peg = Peg.new(x, wy, nil, 12)
		peg.motion = {
			circuit = "layer_2_wave",
			phase = x / 60 + ((block_index % 2 == 0) and (math.pi / 3) or 0),
		}
		table.insert(pegs, peg)
	end
end

for block_index = 1, 7 do
	local block_y = 200 + (block_index - 1) * 240
	-- Layer 3: annular pegs rotating on themselves
	local y3 = block_y + 175
	for x = 200, 1000, 120 do
		local peg = Peg.new_annular(x, y3, nil, 15, 25, math.rad(-90), math.rad(-30))
		peg.motion = { circuit = "layer_3_rotate", phase = x / 120 }
		table.insert(pegs, peg)
	end
end

return {
	name = "Benchmark Lasagna",
	type_counts = { red = 50, green = 5 },
	level_circuits = level_circuits,
	pegs = pegs,
	level_seed = 1234,
}
