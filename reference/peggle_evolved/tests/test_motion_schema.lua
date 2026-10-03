-- MotionSchema validation tests: load-time motion assignment rules.
local MotionSchema = require("src.systems.motion_schema")
local Peg = require("src.entities.peg")
local Path = require("src.systems.path")

local function expect_error(fn, pattern)
	local ok, err = pcall(fn)
	assert_false(ok, "expected an error")
	assert_true(tostring(err):find(pattern, 1, true) ~= nil,
		"error contains '" .. pattern .. "': " .. tostring(err))
end

local ELLIPSE = { kind = "ellipse", amp_x = 10, amp_y = 5 }

local function circle_path()
	return Path.new({ segments = {
		{ kind = "arc", center = { 0, 0 }, radius = 10, theta_start = 0,
			sweep = math.pi * 2 },
	}, closed = true })
end

local function cornered_closed_path()
	return Path.new({ segments = {
		{ kind = "line", p0 = { 0, 0 }, p1 = { 10, 0 } },
		{ kind = "line", p0 = { 10, 0 }, p1 = { 0, 10 } },
		{ kind = "line", p0 = { 0, 10 }, p1 = { 0, 0 } },
	}, closed = true })
end

local PATH_CIRCUIT = { kind = "path", path = circle_path(), speed = 100 }

return {
	test_valid_moving_pegs_pass = function()
		local pegs = {
			Peg.new(100, 100, "blue", 10),
			Peg.new(200, 100, "red", 10),
		}
		pegs[1].motion = { circuit = "c1", phase = 0.5 }
		MotionSchema.validate(pegs, { c1 = ELLIPSE })
		assert_true(true)
	end,

	test_static_pegs_without_motion_pass = function()
		MotionSchema.validate({ Peg.new(100, 100, "blue", 10) }, {})
		assert_true(true)
	end,

	test_circuit_def_with_pegs_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, pegs = {} } })
		end, "do not own pegs")
	end,

	test_legacy_circuit_id_rejected = function()
		local p = Peg.new(100, 100, "blue", 10)
		p.circuit_id = "c1"
		expect_error(function()
			MotionSchema.validate({ p }, { c1 = ELLIPSE })
		end, "legacy circuit assignment fields")
	end,

	test_mixed_legacy_and_motion_rejected = function()
		local p = Peg.new(100, 100, "blue", 10)
		p.circuit_id = "c1"
		p.motion = { circuit = "c1", phase = 0 }
		expect_error(function()
			MotionSchema.validate({ p }, { c1 = ELLIPSE })
		end, "mixes legacy circuit fields")
	end,

	test_unknown_circuit_reference_rejected = function()
		local p = Peg.new(100, 100, "blue", 10)
		p.motion = { circuit = "nope", phase = 0 }
		expect_error(function()
			MotionSchema.validate({ p }, { c1 = ELLIPSE })
		end, "does not exist")
	end,

	test_non_table_motion_rejected = function()
		local p = Peg.new(100, 100, "blue", 10)
		p.motion = "c1"
		expect_error(function()
			MotionSchema.validate({ p }, { c1 = ELLIPSE })
		end, "non-table motion")
	end,

	test_motion_without_circuit_rejected = function()
		local p = Peg.new(100, 100, "blue", 10)
		p.motion = { phase = 0 }
		expect_error(function()
			MotionSchema.validate({ p }, { c1 = ELLIPSE })
		end, "no valid circuit reference")
	end,

	test_unknown_primitive_kind_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "spiral" } })
		end, "unknown primitive kind")
	end,

	test_missing_required_params_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "ellipse" } })
		end, "requires numeric parameter")
	end,

	test_non_finite_numeric_field_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, speed = math.huge } })
		end, "non-finite numeric field")
	end,

	test_negative_speed_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, speed = -1 } })
		end, "invalid speed")
	end,

	test_timed_circuit_requires_pause_time = function()
		expect_error(function()
			MotionSchema.validate({}, {
				c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, duration_time = 2 },
			})
		end, "pause_time")
	end,

	test_timed_circuit_with_pause_passes = function()
		MotionSchema.validate({}, {
			c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, duration_time = 2, pause_time = 1 },
		})
		assert_true(true)
	end,

	test_path_fn_circuit_passes_with_warning = function()
		MotionSchema.validate({}, { c1 = { path_fn = function(t) return t, 0, 0 end } })
		assert_true(true)
	end,

	test_kind_with_path_fn_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, {
				c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, path_fn = true },
			})
		end, "defines both")
	end,

	test_kind_with_function_path_fn_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, {
				c1 = { kind = "line", amp = 1, path_fn = function(t) return t, 0, 0 end },
			})
		end, "defines both")
	end,

	test_oscillate_frequency_string_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "oscillate_x", amp = 1, frequency = "fast" } })
		end, "frequency")
	end,

	test_oscillate_frequency_table_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "oscillate_y", amp = 1, frequency = {} } })
		end, "frequency")
	end,

	test_rotate_speed_angular_table_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "rotate", speed_angular = {} } })
		end, "speed_angular")
	end,

	test_line_angle_string_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "line", amp = 1, angle = "x" } })
		end, "angle")
	end,

	test_ellipse_rotate_string_rejected = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, rotate = "yes" } })
		end, "rotate")
	end,

	test_valid_primitive_option_fields_pass = function()
		MotionSchema.validate({}, {
			c1 = { kind = "ellipse", amp_x = 1, amp_y = 1, rotate = true },
			c2 = { kind = "cos_ellipse", amp_x = 1, amp_y = 1, rotate = false },
			c3 = { kind = "oscillate_x", amp = 1, frequency = 2 },
			c4 = { kind = "oscillate_y", amp = 1, frequency = 0.25 },
			c5 = { kind = "line", amp = 1, angle = 0.5 },
			c6 = { kind = "rotate", speed_angular = 3 },
		})
		assert_true(true)
	end,

	test_legacy_flat_fields_each_rejected = function()
		for _, field in ipairs({ "circuit_id", "circuit_t", "circuit_state", "circuit_timer" }) do
			local p = Peg.new(100, 100, "blue", 10)
			p[field] = 1
			expect_error(function()
				MotionSchema.validate({ p }, {})
			end, "legacy circuit assignment fields")
		end
	end,

	test_legacy_flat_fields_each_mixed_with_motion_rejected = function()
		for _, field in ipairs({ "circuit_id", "circuit_t", "circuit_state", "circuit_timer" }) do
			local p = Peg.new(100, 100, "blue", 10)
			p[field] = 1
			p.motion = { circuit = "c1", phase = 0 }
			expect_error(function()
				MotionSchema.validate({ p }, { c1 = ELLIPSE })
			end, "mixes legacy circuit fields")
		end
	end,

	test_non_finite_phase_rejected = function()
		local p = Peg.new(100, 100, "blue", 10)
		p.motion = { circuit = "c1", phase = 0 / 0 }
		expect_error(function()
			MotionSchema.validate({ p }, { c1 = ELLIPSE })
		end, "phase")
	end,

	test_is_moving_helper = function()
		local moving = Peg.new(100, 100, "blue", 10)
		moving.motion = { circuit = "c1", phase = 0 }
		assert_true(MotionSchema.is_moving(moving))
		assert_false(MotionSchema.is_moving(Peg.new(100, 100, "blue", 10)))
	end,

	test_path_circuit_with_closed_smooth_path_passes = function()
		local pegs = { Peg.new(10, 0, "blue", 2) }
		pegs[1].motion = { circuit = "c1", phase = 3 }
		MotionSchema.validate(pegs, { c1 = PATH_CIRCUIT })
		assert_true(true)
	end,

	test_path_circuit_requires_compiled_path = function()
		expect_error(function()
			MotionSchema.validate({}, {
				c1 = { kind = "path", path = { segments = {} }, speed = 10 },
			})
		end, "compiled Path")
	end,

	test_path_circuit_requires_closed_path = function()
		local open = Path.new({ segments = {
			{ kind = "line", p0 = { 0, 0 }, p1 = { 10, 0 } },
		}, closed = false })
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "path", path = open, speed = 10 } })
		end, "closed path")
	end,

	test_path_circuit_rejects_non_smooth_joins = function()
		expect_error(function()
			MotionSchema.validate({}, {
				c1 = { kind = "path", path = cornered_closed_path(), speed = 10 },
			})
		end, "discontinuity")
	end,

	test_path_circuit_requires_speed = function()
		expect_error(function()
			MotionSchema.validate({}, { c1 = { kind = "path", path = circle_path() } })
		end, "requires numeric parameter")
	end,

	test_path_circuit_rejects_negative_or_non_finite_speed = function()
		expect_error(function()
			MotionSchema.validate({}, {
				c1 = { kind = "path", path = circle_path(), speed = -1 },
			})
		end, "invalid speed")
		expect_error(function()
			MotionSchema.validate({}, {
				c1 = { kind = "path", path = circle_path(), speed = math.huge },
			})
		end, "requires numeric parameter")
	end,

	test_path_phase_may_be_negative_or_beyond_length = function()
		local pegs = { Peg.new(0, 0, "blue", 2) }
		pegs[1].motion = { circuit = "c1", phase = -500 }
		local pegs2 = { Peg.new(0, 0, "blue", 2) }
		pegs2[1].motion = { circuit = "c1", phase = 500 }
		MotionSchema.validate(pegs, { c1 = PATH_CIRCUIT })
		MotionSchema.validate(pegs2, { c1 = PATH_CIRCUIT })
		assert_true(true)
	end,

	test_is_closed_path_circuit_helper = function()
		assert_true(MotionSchema.is_closed_path_circuit(PATH_CIRCUIT))
		assert_false(MotionSchema.is_closed_path_circuit(ELLIPSE))
		assert_false(MotionSchema.is_closed_path_circuit(nil))
		assert_false(MotionSchema.is_closed_path_circuit({ kind = "path" }))
		assert_false(MotionSchema.is_closed_path_circuit({
			kind = "path", path = { segments = {}, closed = true }, speed = 1,
		}))
		local open = Path.new({ segments = {
			{ kind = "line", p0 = { 0, 0 }, p1 = { 10, 0 } },
		}, closed = false })
		assert_false(MotionSchema.is_closed_path_circuit({ kind = "path", path = open, speed = 1 }))
	end,
}
