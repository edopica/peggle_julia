-- LevelValidator boundary-pass tests: the narrow closed-path exemption keeps
-- intentional hidden-return bases while every other off-screen peg is still
-- discarded in order.
local Validator = require("src.systems.level_validator")
local LevelManager = require("src.systems.level_manager")
local Path = require("src.systems.path")
local Peg = require("src.entities.peg")
local Config = require("src.config")

local function with_virtual_width(width, fn)
	local previous = LevelManager.virtual_width
	LevelManager.virtual_width = width
	local ok, err = pcall(fn)
	LevelManager.virtual_width = previous
	if not ok then error(err, 0) end
end

local function circle_path(center_x, center_y, radius)
	return Path.new({ segments = {
		{ kind = "arc", center = { x = center_x, y = center_y }, radius = radius,
			theta_start = 0, sweep = math.pi * 2 },
	}, closed = true })
end

local function moving(peg, circuit)
	peg.motion = { circuit = circuit, phase = 0 }
	return peg
end

return {
	test_offscreen_peg_on_closed_path_is_kept = function()
		with_virtual_width(1200, function()
			-- The whole loop is off-screen; the peg's base is a path point.
			local path = circle_path(1400, -200, 100)
			local x, y = path:at_distance(0)
			local peg = moving(Peg.new(x, y, "blue", 10), "c1")
			local defs = { c1 = { kind = "path", path = path, speed = 100 } }
			local kept = Validator.validate_pegs({ peg }, defs)
			assert_eq(#kept, 1, "closed-path peg survives the boundary pass")
			assert_true(kept[1] == peg, "the original peg table is kept")
		end)
	end,

	test_offscreen_peg_without_path_assignment_is_discarded = function()
		with_virtual_width(1200, function()
			local peg = moving(Peg.new(1300, -200, "blue", 10), "c1")
			local defs = { c1 = { kind = "oscillate_x", amp = 10, speed = 1 } }
			local kept = Validator.validate_pegs({ peg }, defs)
			assert_eq(#kept, 0, "relative circuits keep the existing boundary policy")
		end)
	end,

	test_open_path_does_not_exempt = function()
		with_virtual_width(1200, function()
			local open = Path.new({ segments = {
				{ kind = "line", p0 = { 1300, -200 }, p1 = { 1400, -200 } },
			}, closed = false })
			local peg = moving(Peg.new(1300, -200, "blue", 10), "c1")
			local kept = Validator.validate_pegs({ peg },
				{ c1 = { kind = "path", path = open, speed = 100 } })
			assert_eq(#kept, 0, "an open path cannot bypass the boundary pass")
		end)
	end,

	test_malformed_path_does_not_exempt = function()
		with_virtual_width(1200, function()
			local peg = moving(Peg.new(1300, -200, "blue", 10), "c1")
			local kept = Validator.validate_pegs({ peg },
				{ c1 = { kind = "path", path = { closed = true }, speed = 100 } })
			assert_eq(#kept, 0, "a non-Path path table cannot bypass the boundary pass")
		end)
	end,

	test_exemption_preserves_order_and_other_pegs = function()
		with_virtual_width(1200, function()
			local path = circle_path(1400, -200, 100)
			local px, py = path:at_distance(0)
			local first = moving(Peg.new(px, py, "blue", 10), "c1")
			local second = Peg.new(600, 600, "blue", 10)
			local third = moving(Peg.new(-200, -200, "blue", 10), "c1")
			local fourth = Peg.new(100, 900, "blue", 10)
			local defs = { c1 = { kind = "path", path = path, speed = 100 } }
			local kept = Validator.validate_pegs({ first, second, third, fourth }, defs)
			assert_eq(#kept, 4, "both path pegs survive")
			assert_true(kept[1] == first, "order preserved: path peg 1")
			assert_true(kept[2] == second, "order preserved: in-bounds peg")
			assert_true(kept[3] == third, "order preserved: path peg 2")
			assert_true(kept[4] == fourth, "order preserved: final peg")
		end)
	end,

	test_boundary_filter_retains_existing_behavior = function()
		with_virtual_width(1200, function()
			local pegs = {
				Peg.new(600, 600, "blue", 10),      -- in bounds
				Peg.new(-20, 600, "blue", 10),      -- left wall
				Peg.new(1215, 600, "blue", 10),     -- right wall
				Peg.new(600, -5, "blue", 10),       -- ceiling
				Peg.new(600, 2000, "blue", 10),     -- below the floor is allowed
			}
			local kept = Validator.validate_pegs(pegs, {})
			assert_eq(#kept, 2, "only in-bounds and below-floor pegs survive")
			assert_true(kept[1] == pegs[1])
			assert_true(kept[2] == pegs[5])
		end)
	end,

	test_check_initialized_positions_accepts_path_context = function()
		with_virtual_width(1200, function()
			local path = circle_path(1400, -200, 100)
			local x, y = path:at_distance(0)
			local peg = moving(Peg.new(1300, 600, "blue", 10), "c1")
			peg.x, peg.y = x, y
			Validator.check_initialized_positions({ peg },
				{ c1 = { kind = "path", path = path, speed = 100 } })
			Validator.check_initialized_positions({ Peg.new(600, 600, "blue", 10) }, {})
			assert_true(true)
		end)
	end,

	test_default_virtual_width_still_supports_the_helper = function()
		-- Guards against test-order leakage of the shared LevelManager width.
		local previous = LevelManager.virtual_width
		LevelManager.virtual_width = Config.virtual_width
		assert_true(LevelManager.virtual_width > 0)
		LevelManager.virtual_width = previous
	end,
}
