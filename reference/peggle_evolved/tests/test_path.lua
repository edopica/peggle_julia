-- Structured path tests: exact primitives, cubic distance evaluation, input
-- validation, and deterministic Archimedean spiral compilation.
local Path = require("src.systems.path")

local function near(actual, expected, epsilon, message)
	epsilon = epsilon or 1e-9
	assert_true(math.abs(actual - expected) <= epsilon,
		(message or "values differ") .. string.format(
			" (expected %.17g, got %.17g, epsilon %.3g)", expected, actual, epsilon))
end

local function expect_error(fn, pattern)
	local ok, err = pcall(fn)
	assert_false(ok, "expected an error")
	assert_true(tostring(err):find(pattern, 1, true) ~= nil,
		"error contains '" .. pattern .. "': " .. tostring(err))
end

local function cubic_point(segment, t)
	local mt = 1 - t
	local b0 = mt * mt * mt
	local b1 = 3 * mt * mt * t
	local b2 = 3 * mt * t * t
	local b3 = t * t * t
	return segment.p0.x * b0 + segment.c1.x * b1
			+ segment.c2.x * b2 + segment.p1.x * b3,
		segment.p0.y * b0 + segment.c1.y * b1
			+ segment.c2.y * b2 + segment.p1.y * b3
end

local function assert_same_segment(a, b)
	assert_eq(a.kind, b.kind)
	for _, field in ipairs({ "p0", "c1", "c2", "p1" }) do
		assert_eq(a[field].x, b[field].x, field .. ".x is deterministic")
		assert_eq(a[field].y, b[field].y, field .. ".y is deterministic")
	end
	assert_eq(a.length, b.length, "segment length is deterministic")
end

-- Four cubic quarters of the unit circle. Each interior join and the seam are
-- tangent-continuous by construction. The reversed path traverses clockwise.
local function unit_circle_cubics()
	local k = 4 / 3 * math.tan(math.pi / 8)
	local forward = {
		{ kind = "cubic", p0 = { 1, 0 }, c1 = { 1, k }, c2 = { k, 1 }, p1 = { 0, 1 } },
		{ kind = "cubic", p0 = { 0, 1 }, c1 = { -k, 1 }, c2 = { -1, k }, p1 = { -1, 0 } },
		{ kind = "cubic", p0 = { -1, 0 }, c1 = { -1, -k }, c2 = { -k, -1 }, p1 = { 0, -1 } },
		{ kind = "cubic", p0 = { 0, -1 }, c1 = { k, -1 }, c2 = { 1, -k }, p1 = { 1, 0 } },
	}
	local reversed = {}
	for i = #forward, 1, -1 do
		local segment = forward[i]
		reversed[#reversed + 1] = {
			kind = "cubic",
			p0 = segment.p1, c1 = segment.c2, c2 = segment.c1, p1 = segment.p0,
		}
	end
	return Path.new({ segments = forward, closed = true }),
		Path.new({ segments = reversed, closed = true })
end

return {
	test_uneven_cubic_inverse_distance_accuracy = function()
		for _, reverse in ipairs({ false, true }) do
			local path = Path.new({ { kind = "cubic", p0 = { 0, 0 },
				c1 = { reverse and 999.998 or 0.001, 0 },
				c2 = { reverse and 999.999 or 0.002, 0 }, p1 = { 1000, 0 } } })
			for i = 1, 1000 do
				local s = 1000 * (i - 0.5) / 1000
				local x = path:at_distance(s)
				near(x, s, Path.CUBIC_DISTANCE_TOLERANCE)
				assert_eq(path:at_distance(s), x, "inversion is deterministic")
			end
			for _, s in ipairs({ 1e-8, 1e-5, 994.16349503145, 1000 - 1e-8 }) do
				near(path:at_distance(s), s, Path.CUBIC_DISTANCE_TOLERANCE)
			end
		end
	end,

	test_exact_line_evaluation_and_clamping = function()
		local path = Path.new({
			{ kind = "line", p0 = { 1, 2 }, p1 = { 4, 6 } },
		})
		assert_true(Path.is_path(path))
		near(path:length(), 5)

		local x, y, tangent, curvature = path:at_distance(2.5)
		near(x, 2.5)
		near(y, 4)
		near(tangent.x, 0.6)
		near(tangent.y, 0.8)
		near(curvature, 0)

		local before_x, before_y = path:at_distance(-100)
		local after_x, after_y = path:at_distance(100)
		near(before_x, 1)
		near(before_y, 2)
		near(after_x, 4)
		near(after_y, 6)
	end,

	test_exact_counterclockwise_arc_frame = function()
		local path = Path.new({
			{ kind = "arc", center = { x = 3, y = -2 }, radius = 10,
				theta_start = 0, sweep = math.pi / 2 },
		})
		near(path:length(), 5 * math.pi)
		local x, y, tangent, curvature = path:at_distance(path:length() * 0.5)
		local root_half = math.sqrt(0.5)
		near(x, 3 + 10 * root_half)
		near(y, -2 + 10 * root_half)
		near(tangent.x, -root_half)
		near(tangent.y, root_half)
		near(curvature, 0.1)
	end,

	test_exact_clockwise_arc_has_signed_curvature = function()
		local path = Path.new({
			{ kind = "arc", center = { 0, 0 }, radius = 4,
				theta_start = math.pi / 2, sweep = -math.pi / 2 },
		})
		local x, y, tangent, curvature = path:at_distance(path:length())
		near(x, 4)
		near(y, 0, 1e-12)
		near(tangent.x, 0, 1e-12)
		near(tangent.y, -1)
		near(curvature, -0.25)
	end,

	test_cubic_length_matches_analytic_parabola = function()
		-- This cubic is the exact polynomial x=t, y=t^2. Its length on [0,1]
		-- is sqrt(5)/2 + asinh(2)/4.
		local path = Path.new({
			{ kind = "cubic", p0 = { 0, 0 }, c1 = { 1 / 3, 0 },
				c2 = { 2 / 3, 1 / 3 }, p1 = { 1, 1 } },
		})
		local expected = math.sqrt(5) * 0.5
			+ math.log(2 + math.sqrt(5)) * 0.25
		near(path:length(), expected, Path.LENGTH_TOLERANCE,
			"cubic arc-length estimate respects its public tolerance")
	end,

	test_cubic_distance_inversion_uses_arc_length = function()
		-- This arch is symmetric, so half of its arc length is exactly t=0.5.
		-- A raw parameter-based implementation happens to pass the midpoint but
		-- the quarter-distance checks below distinguish it from raw t.
		local path = Path.new({
			{ kind = "cubic", p0 = { 0, 0 }, c1 = { 0, 10 },
				c2 = { 10, 10 }, p1 = { 10, 0 } },
		})
		local x, y, tangent, curvature = path:at_distance(path:length() * 0.5)
		near(x, 5, 2e-4)
		near(y, 7.5, 2e-4)
		near(tangent.x, 1, 2e-4)
		near(tangent.y, 0, 2e-4)
		assert_true(curvature < 0, "arch bends clockwise at its midpoint")

		local qx, qy = path:at_distance(path:length() * 0.25)
		-- At raw t=.25 the point is (1.5625, 5.625). Equal arc length lies
		-- farther along this curve, around (1.059, 4.836).
		assert_true(math.abs(qx - 1.5625) > 0.2, "quarter distance is not raw t=.25")
		near(qx, 1.059, 0.01)
		near(qy, 4.836, 0.01)
		-- This arch has exact speed 30*(2*t^2 - 2*t + 1), so its
		-- integrated distance provides an independent curved-cubic oracle.
		for i = 1, 100 do
			local t = (i - 0.5) / 100
			local s = 30 * (t - t^2 + 2 * t^3 / 3)
			local expected_x, expected_y = cubic_point(path.segments[1], t)
			local actual_x, actual_y = path:at_distance(s)
			assert_true(math.sqrt((actual_x - expected_x)^2 + (actual_y - expected_y)^2)
				<= Path.CUBIC_DISTANCE_TOLERANCE, "curved inverse respects the distance budget")
		end
	end,

	test_composite_join_is_continuous_and_owned_by_next_segment = function()
		local path = Path.new({ segments = {
			{ kind = "line", p0 = { 0, 0 }, p1 = { 2, 0 } },
			{ kind = "line", p0 = { 2, 0 }, p1 = { 2, 3 } },
		}, closed = false })
		near(path:length(), 5)
		local x, y, tangent = path:at_distance(2)
		near(x, 2)
		near(y, 0)
		near(tangent.x, 0)
		near(tangent.y, 1)
	end,

	test_validate_joins_accepts_smooth_closed_cubic_paths = function()
		local forward, reversed = unit_circle_cubics()
		assert_true(forward:validate_joins(), "smooth closed path passes including the seam")
		assert_true(reversed:validate_joins(), "reversed smooth path passes equivalent checks")
		assert_true(forward:validate_joins({ tangent_tolerance = 1e-9 }),
			"explicit tolerance preserves smooth agreement")
	end,

	test_validate_joins_fails_interior_corner_with_segment_indices = function()
		local path = Path.new({ segments = {
			{ kind = "line", p0 = { 0, 0 }, p1 = { 2, 0 } },
			{ kind = "line", p0 = { 2, 0 }, p1 = { 2, 3 } },
		}, closed = false })
		local ok, issue = path:validate_joins()
		assert_false(ok)
		assert_eq(issue.from_segment, 1)
		assert_eq(issue.to_segment, 2)
		assert_false(issue.seam)
		assert_eq(issue.kind, "tangent")
		near(issue.error, 1)
		near(issue.tolerance, 1e-6)
		-- The rejected path still samples with existing join ownership.
		local x, y, tangent = path:at_distance(2)
		near(x, 2)
		near(y, 0)
		near(tangent.x, 0)
		near(tangent.y, 1)
	end,

	test_validate_joins_reports_seam_corner_with_final_and_first_segments = function()
		local path = Path.new({ segments = {
			{ kind = "cubic", p0 = { 0, 0 }, c1 = { 1, 0 }, c2 = { 2, -1 }, p1 = { 2, 0 } },
			{ kind = "cubic", p0 = { 2, 0 }, c1 = { 2, 1 }, c2 = { -1, 1 }, p1 = { 0, 0 } },
		}, closed = true })
		local ok, issue = path:validate_joins()
		assert_false(ok)
		assert_eq(issue.from_segment, 2)
		assert_eq(issue.to_segment, 1)
		assert_true(issue.seam, "the failure is the closing seam, not the interior join")
		assert_eq(issue.kind, "tangent")
		assert_true(issue.error > 0.2, "seam tangents differ substantially")
	end,

	test_validate_joins_checks_single_closed_segment_seam = function()
		local arc = Path.new({ segments = {
			{ kind = "arc", center = { 0, 0 }, radius = 5,
				theta_start = 0.3, sweep = 2 * math.pi },
		}, closed = true })
		assert_true(arc:validate_joins({ tangent_tolerance = 1e-9 }),
			"a full-circle closed arc passes its seam check")

		local loop = Path.new({ segments = {
			{ kind = "cubic", p0 = { 0, 0 }, c1 = { 1, 0 }, c2 = { 0, 1 }, p1 = { 0, 0 } },
		}, closed = true })
		local ok, issue = loop:validate_joins()
		assert_false(ok)
		assert_eq(issue.from_segment, 1)
		assert_eq(issue.to_segment, 1)
		assert_true(issue.seam)
		assert_eq(issue.kind, "tangent")
	end,

	test_validate_joins_skips_open_single_segment = function()
		local line = Path.new({ { kind = "line", p0 = { 0, 0 }, p1 = { 1, 0 } } })
		assert_true(line:validate_joins())
		local arc = Path.new({ { kind = "arc", center = { 0, 0 }, radius = 2,
			theta_start = 0, sweep = 1 } })
		assert_true(arc:validate_joins())
	end,

	test_validate_joins_rejects_opposite_tangents_at_coincident_endpoints = function()
		local path = Path.new({ segments = {
			{ kind = "line", p0 = { 0, 0 }, p1 = { 1, 0 } },
			{ kind = "line", p0 = { 1, 0 }, p1 = { 0, 0 } },
		}, closed = true })
		local ok, issue = path:validate_joins()
		assert_false(ok)
		assert_eq(issue.kind, "tangent")
		assert_eq(issue.from_segment, 1)
		assert_eq(issue.to_segment, 2)
		near(issue.error, 2, 1e-12)
	end,

	test_validate_joins_accepts_discontinuous_curvature = function()
		local path = Path.new({ segments = {
			{ kind = "arc", center = { 0, 0 }, radius = 10,
				theta_start = 0, sweep = math.pi / 2 },
			{ kind = "arc", center = { 0, 5 }, radius = 5,
				theta_start = math.pi / 2, sweep = math.pi / 2 },
		} })
		assert_true(path:validate_joins(), "equal tangents pass despite a curvature jump")
		local join_length = path.segments[1].length
		local _, _, _, before_curvature = path:at_distance(join_length - 1e-6)
		local _, _, _, after_curvature = path:at_distance(join_length)
		near(before_curvature, 0.1, 1e-9)
		near(after_curvature, 0.2, 1e-9)
	end,

	test_validate_joins_accepts_inflected_cubic = function()
		local path = Path.new({ {
			kind = "cubic", p0 = { 0, 0 }, c1 = { 1, 1 }, c2 = { 2, -1 }, p1 = { 3, 0 },
		} })
		assert_true(path:validate_joins())
		local _, _, _, early_curvature = path:at_distance(path:length() * 0.25)
		local _, _, _, late_curvature = path:at_distance(path:length() * 0.75)
		assert_true(early_curvature < 0, "inflected cubic bends one way before the inflection")
		assert_true(late_curvature > 0, "inflected cubic bends the other way after the inflection")
	end,

	test_validate_joins_rejects_invalid_options = function()
		local path = Path.new({ { kind = "line", p0 = { 0, 0 }, p1 = { 1, 0 } } })
		expect_error(function()
			path:validate_joins({ tangent_tolerance = math.huge })
		end, "finite number")
		expect_error(function()
			path:validate_joins({ tangent_tolerance = 0 / 0 })
		end, "finite number")
		expect_error(function()
			path:validate_joins({ tangent_tolerance = -1e-9 })
		end, "must not be negative")
		expect_error(function()
			path:validate_joins({ tangent_tolerance = 1 })
		end, "must be less than 1")
		expect_error(function()
			path:validate_joins({ tangent_tolerance = 1.5 })
		end, "must be less than 1")
		expect_error(function()
			path:validate_joins("options")
		end, "options must be a table")
	end,

	test_validate_joins_is_repeatable_and_read_only = function()
		local path = Path.new({ segments = {
			{ kind = "line", p0 = { 0, 0 }, p1 = { 2, 0 } },
			{ kind = "line", p0 = { 2, 0 }, p1 = { 2, 3 } },
		}, closed = false })
		local samples = {}
		for i = 0, 10 do
			local x, y, tangent, curvature = path:at_distance(path:length() * i / 10)
			samples[i] = { x, y, tangent.x, tangent.y, curvature }
		end
		local first_ok, first_issue = path:validate_joins()
		local second_ok, second_issue = path:validate_joins()
		assert_false(first_ok)
		assert_false(second_ok)
		assert_eq(first_issue.from_segment, second_issue.from_segment)
		assert_eq(first_issue.to_segment, second_issue.to_segment)
		assert_eq(first_issue.seam, second_issue.seam)
		assert_eq(first_issue.kind, second_issue.kind)
		assert_eq(first_issue.error, second_issue.error)
		assert_eq(first_issue.tolerance, second_issue.tolerance)
		assert_eq(#path.segments, 2)
		for i = 0, 10 do
			local x, y, tangent, curvature = path:at_distance(path:length() * i / 10)
			assert_eq(x, samples[i][1])
			assert_eq(y, samples[i][2])
			assert_eq(tangent.x, samples[i][3])
			assert_eq(tangent.y, samples[i][4])
			assert_eq(curvature, samples[i][5])
		end
	end,

	test_malformed_and_discontinuous_paths_are_rejected = function()
		expect_error(function() Path.new({}) end, "requires at least one segment")
		expect_error(function()
			Path.new({ { kind = "line", p0 = { 0, 0 }, p1 = { 0, 0 } } })
		end, "zero length")
		expect_error(function()
			Path.new({ { kind = "arc", center = { 0, 0 }, radius = -1,
				theta_start = 0, sweep = 1 } })
		end, "radius must be positive")
		expect_error(function()
			Path.new({ { kind = "line", p0 = { 0, 0 }, p1 = { math.huge, 1 } } })
		end, "finite number")
		expect_error(function()
			Path.new({
				{ kind = "line", p0 = { 0, 0 }, p1 = { 1, 0 } },
				{ kind = "line", p0 = { 2, 0 }, p1 = { 3, 0 } },
			})
		end, "discontinuous")
		expect_error(function()
			Path.new({ segments = {
				{ kind = "line", p0 = { 0, 0 }, p1 = { 1, 0 } },
			}, closed = true })
		end, "open seam")
	end,

	test_cubic_cusp_is_rejected = function()
		-- x'(t)=3(2t-1)^2 and y'(t)=0, so the tangent is zero at t=.5.
		expect_error(function()
			Path.new({
				{ kind = "cubic", p0 = { 0, 0 }, c1 = { 1, 0 },
					c2 = { 0, 0 }, p1 = { 1, 0 } },
			})
		end, "cusp or zero tangent")
	end,

	test_spiral_compilation_endpoints_and_error = function()
		local tolerance = 0.05
		local theta_start, sweep = 0.2, 1.8
		local r_start, r_end = 10, 20
		local center = { x = 7, y = -4 }
		local path = Path.archimedean_spiral({
			center = center,
			theta_start = theta_start,
			sweep = sweep,
			r_start = r_start,
			r_end = r_end,
			curve_tolerance = tolerance,
		})
		assert_eq(path.source_kind, "spiral")
		assert_true(#path.segments > 1, "curved spiral is adaptively subdivided")
		for _, segment in ipairs(path.segments) do assert_eq(segment.kind, "cubic") end

		local sx, sy = path:at_distance(0)
		local ex, ey = path:at_distance(path:length())
		near(sx, center.x + r_start * math.cos(theta_start), 1e-9)
		near(sy, center.y + r_start * math.sin(theta_start), 1e-9)
		near(ex, center.x + r_end * math.cos(theta_start + sweep), 1e-9)
		near(ey, center.y + r_end * math.sin(theta_start + sweep), 1e-9)

		local radial_rate = (r_end - r_start) / sweep
		for _, segment in ipairs(path.segments) do
			local first_theta = math.atan2(segment.p0.y - center.y, segment.p0.x - center.x)
			local last_theta = math.atan2(segment.p1.y - center.y, segment.p1.x - center.x)
			for i = 0, 16 do
				local t = i / 16
				local theta = first_theta + (last_theta - first_theta) * t
				local radius = r_start + radial_rate * (theta - theta_start)
				local expected_x = center.x + radius * math.cos(theta)
				local expected_y = center.y + radius * math.sin(theta)
				local actual_x, actual_y = cubic_point(segment, t)
				local error_distance = math.sqrt((actual_x - expected_x)^2
					+ (actual_y - expected_y)^2)
				assert_true(error_distance <= tolerance,
					string.format("spiral error %.9g exceeds tolerance %.9g", error_distance, tolerance))
			end
		end
	end,

	test_spiral_compilation_is_deterministic = function()
		local definition = {
			center = { 2, 3 }, theta_start = -0.5, sweep = 2,
			r_start = 8, r_end = 15, curve_tolerance = 0.1,
		}
		local first = Path.archimedean_spiral(definition)
		local second = Path.archimedean_spiral(definition)
		assert_eq(#first.segments, #second.segments)
		assert_eq(first:length(), second:length())
		for i, segment in ipairs(first.segments) do
			assert_same_segment(segment, second.segments[i])
		end
		for i = 0, 20 do
			local distance = first:length() * i / 20
			local ax, ay, at, ac = first:at_distance(distance)
			local bx, by, bt, bc = second:at_distance(distance)
			assert_eq(ax, bx)
			assert_eq(ay, by)
			assert_eq(at.x, bt.x)
			assert_eq(at.y, bt.y)
			assert_eq(ac, bc)
		end
	end,

	test_malformed_spirals_are_rejected = function()
		expect_error(function()
			Path.archimedean_spiral({ r_start = 10, r_end = 20, sweep = 0 })
		end, "sweep must be nonzero")
		expect_error(function()
			Path.archimedean_spiral({ r_start = 10, r_end = -1, sweep = 1 })
		end, "endpoint radii must be positive")
		expect_error(function()
			Path.archimedean_spiral({ r_start = 10, r_end = 20, sweep = 1,
				curve_tolerance = 0 })
		end, "curve_tolerance must be positive")
	end,

	test_sparse_segment_arrays_are_rejected = function()
		expect_error(function()
			Path.new({
				[1] = { kind = "line", p0 = { 0, 0 }, p1 = { 1, 0 } },
				[3] = { kind = "line", p0 = { 1, 0 }, p1 = { 2, 0 } },
			})
		end, "contiguous")
	end,

	test_dense_multi_segment_array_constructs = function()
		local path = Path.new({
			{ kind = "line", p0 = { 0, 0 }, p1 = { 2, 0 } },
			{ kind = "line", p0 = { 2, 0 }, p1 = { 2, 3 } },
		})
		assert_eq(#path.segments, 2)
		near(path:length(), 5)
	end,

	test_overflowing_segment_length_is_rejected = function()
		expect_error(function()
			Path.new({ { kind = "line", p0 = { 0, 0 }, p1 = { 1e308, 0 } } })
		end, "finite")
	end,

	test_finite_line_still_constructs = function()
		local path = Path.new({ { kind = "line", p0 = { 0, 0 }, p1 = { 3, 4 } } })
		near(path:length(), 5)
	end,
}
