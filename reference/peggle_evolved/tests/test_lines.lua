local Path = require("src.systems.path")
local Lines = require("src.systems.lines")
local Config = require("src.config")
local Peg = require("src.entities.peg")

local function near(a, b, epsilon)
	epsilon = epsilon or 1e-6
	return math.abs(a - b) <= epsilon
end

local function expect_error(fn, fragment)
	local ok, message = pcall(fn)
	assert_false(ok, "expected an error")
	assert_true(tostring(message):find(fragment, 1, true) ~= nil,
		"expected error containing '" .. fragment .. "', got: " .. tostring(message))
end

local function distance(a, b)
	local dx, dy = b.x - a.x, b.y - a.y
	return math.sqrt(dx * dx + dy * dy)
end

local function same_point(a, b, epsilon)
	return near(a.x, b.x, epsilon) and near(a.y, b.y, epsilon)
end

local function caps_touch(a, b, epsilon)
	local a1, a2 = a.corners[3], a.corners[4]
	local b1, b2 = b.corners[1], b.corners[2]
	return (same_point(a1, b1, epsilon) and same_point(a2, b2, epsilon))
		or (same_point(a1, b2, epsilon) and same_point(a2, b1, epsilon))
end

local function straight(length)
	return Path.new({ { kind = "line", p0 = { 0, 0 }, p1 = { length, 0 } } })
end

local function full_circle(radius, clockwise)
	return Path.new({
		segments = { {
			kind = "arc", center = { x = 300, y = 400 }, radius = radius,
			theta_start = 0, sweep = (clockwise and -1 or 1) * math.pi * 2,
		} },
		closed = true,
	})
end

local closed_circle = full_circle

-- ===========================================================================
-- Shared curved closed-path fixtures
-- ===========================================================================

-- Smooth convex closed cubic loop: a circle approximated by Hermite cubics.
-- The standard control distance (4/3) tan(step/4) r keeps each segment within
-- a fraction of a pixel of the circle, so every join and the seam are smooth
-- and convex.
local function convex_loop_path(count)
	local center = { x = 300, y = 400 }
	local radius = 200
	local step = math.pi * 2 / count
	local scale = (4 / 3) * math.tan(step / 4) * radius
	local points, tangents = {}, {}
	for i = 0, count - 1 do
		local theta = i * step
		points[i] = { x = center.x + radius * math.cos(theta),
			y = center.y + radius * math.sin(theta) }
		tangents[i] = { x = -math.sin(theta), y = math.cos(theta) }
	end
	points[count], tangents[count] = points[0], tangents[0]
	local segments = {}
	for i = 0, count - 1 do
		local p0, p1 = points[i], points[i + 1]
		local t0, t1 = tangents[i], tangents[i + 1]
		segments[#segments + 1] = {
			kind = "cubic",
			p0 = { x = p0.x, y = p0.y },
			c1 = { x = p0.x + t0.x * scale, y = p0.y + t0.y * scale },
			c2 = { x = p1.x - t1.x * scale, y = p1.y - t1.y * scale },
			p1 = { x = p1.x, y = p1.y },
		}
	end
	return Path.new({ segments = segments, closed = true })
end

-- Exact 96-segment fixture for the polar outline r(theta) = 350 + 30 sin(6t).
-- Analytic polar derivatives author the cubic endpoint tangents; the closing
-- sample reuses sample 0 so the seam has bit-identical endpoint and tangent
-- values.
local function polar_squiggle_segments(count)
	local center = { x = 600, y = 950 }
	local base_radius, amplitude, waves = 350, 30, 6
	local step = math.pi * 2 / count
	local function sample(theta)
		local radius = base_radius + amplitude * math.sin(waves * theta)
		local dr = amplitude * waves * math.cos(waves * theta)
		local c, s = math.cos(theta), math.sin(theta)
		return { x = center.x + radius * c, y = center.y + radius * s },
			{ x = dr * c - radius * s, y = dr * s + radius * c }
	end
	local points, tangents = {}, {}
	for i = 0, count - 1 do points[i], tangents[i] = sample(i * step) end
	points[count], tangents[count] = points[0], tangents[0]
	local segments = {}
	for i = 0, count - 1 do
		local p0, p1 = points[i], points[i + 1]
		local t0, t1 = tangents[i], tangents[i + 1]
		segments[#segments + 1] = {
			kind = "cubic",
			p0 = { x = p0.x, y = p0.y },
			c1 = { x = p0.x + t0.x * step / 3, y = p0.y + t0.y * step / 3 },
			c2 = { x = p1.x - t1.x * step / 3, y = p1.y - t1.y * step / 3 },
			p1 = { x = p1.x, y = p1.y },
		}
	end
	return segments
end

local function squiggle_path(count)
	return Path.new({ segments = polar_squiggle_segments(count or 96), closed = true })
end

-- Exact reversed traversal: reverse segment order and swap cubic endpoints
-- and control points. The curve itself is unchanged.
local function reverse_path(path)
	local reversed = {}
	for i = #path.segments, 1, -1 do
		local segment = path.segments[i]
		reversed[#reversed + 1] = {
			kind = "cubic",
			p0 = { x = segment.p1.x, y = segment.p1.y },
			c1 = { x = segment.c2.x, y = segment.c2.y },
			c2 = { x = segment.c1.x, y = segment.c1.y },
			p1 = { x = segment.p0.x, y = segment.p0.y },
		}
	end
	return Path.new({ segments = reversed, closed = true })
end

-- Distance to analytic centerline arcs, independently of Path inversion and
-- the fitter. Distance to their union is 1-Lipschitz. The cubic derivative
-- control hull bounds travel between samples, including the half-step margin.
local function bounded_centerline_error(path, pegs)
	local worst = 0
	for _, segment in ipairs(path.segments) do
		local speed_bound = 3 * math.max(distance(segment.p0, segment.c1),
			distance(segment.c1, segment.c2), distance(segment.c2, segment.p1))
		local intervals = math.max(1, math.ceil(speed_bound / 0.1))
		for i = 0, intervals do
			local t = i / intervals
			local u = 1 - t
			local px = u^3 * segment.p0.x + 3*u*u*t * segment.c1.x
				+ 3*u*t*t * segment.c2.x + t^3 * segment.p1.x
			local py = u^3 * segment.p0.y + 3*u*u*t * segment.c1.y
				+ 3*u*t*t * segment.c2.y + t^3 * segment.p1.y
			local best = math.huge
			for _, peg in ipairs(pegs) do
				local dx, dy = px - peg.x, py - peg.y
				local radius = (peg.r_in + peg.r_out) / 2
				local angle = math.atan2(dy, dx)
				if (angle - peg.theta_start) % (2 * math.pi) <= peg.theta_end_abs - peg.theta_start then
					best = math.min(best, math.abs(math.sqrt(dx*dx + dy*dy) - radius))
				else
					for _, endpoint in ipairs({ peg.theta_start, peg.theta_end_abs }) do
						local ex, ey = dx - radius * math.cos(endpoint), dy - radius * math.sin(endpoint)
						best = math.min(best, math.sqrt(ex*ex + ey*ey))
					end
				end
			end
			worst = math.max(worst, best + speed_bound / (2 * intervals))
		end
	end
	return worst
end

return {
	test_closed_annular_caps_cannot_reuse_the_interior_join = function()
		for _, clockwise in ipairs({ false, true }) do
			local pegs = Lines.generate({ id = "two", path = full_circle(100, clockwise),
				peg = { kind = "annular", thickness = 20, max_length = 400 }, gap = 0 })
			assert_eq(#pegs, 2)
			Lines.validate(pegs)
			local p = pegs[1]
			local start = p.theta_start + (clockwise and 0 or 0.05)
			local finish = p.theta_end_abs - (clockwise and 0.05 or 0)
			pegs[1] = Peg.new_annular(p.x, p.y, "blue", p.r_in, p.r_out, start, finish)
			pegs[1].line = p.line
			expect_error(function() Lines.validate(pegs) end, "cap gap")
		end
	end,

	test_single_closed_annular_piece_must_join_its_distinct_caps = function()
		local ring = Peg.new_annular(300, 400, "blue", 90, 110, 0, math.pi * 2)
		ring.line = { id = "single", index = 1, count = 1, closed = true, gap = 0 }
		Lines.validate({ ring })
		local half = Peg.new_annular(300, 400, "blue", 90, 110, 0, math.pi)
		half.line = ring.line
		expect_error(function() Lines.validate({ half }) end, "closing seam")
		half.line.closed = false
		Lines.validate({ half })
	end,
	test_straight_rectangles_have_exact_twenty_pixel_gaps = function()
		local pegs = Lines.generate({
			id = "bricks", path = straight(220),
			peg = { kind = "rectangle", width = 20, height = 12 }, gap = 20,
		})
		assert_eq(#pegs, 6)
		assert_true(near(pegs[1].x - pegs[1].width / 2, 0), "left end centered")
		assert_true(near(pegs[#pegs].x + pegs[#pegs].width / 2, 220), "right end centered")
		for i = 1, #pegs - 1 do
			local clearance = pegs[i + 1].x - pegs[i + 1].width / 2
				- (pegs[i].x + pegs[i].width / 2)
			assert_true(near(clearance, 20), "exact rectangle boundary gap")
		end
	end,

	test_open_rectangle_remainder_is_split_evenly = function()
		local pegs = Lines.generate({
			id = "centered", path = straight(230),
			peg = { kind = "rectangle", width = 20, height = 10 }, gap = 20,
		})
		local left = pegs[1].x - pegs[1].width / 2
		local right = 230 - (pegs[#pegs].x + pegs[#pegs].width / 2)
		assert_true(near(left, right), "equal end remainder")
		assert_true(near(left, 5))
	end,

	test_gapless_rectangles_resize_and_cover_path = function()
		local pegs = Lines.generate({
			id = "solid", path = straight(95),
			peg = { kind = "rectangle", width = 30, height = 10 }, gap = 0,
		})
		assert_eq(#pegs, 4)
		assert_true(pegs[1].width <= 30)
		assert_true(near(pegs[1].x - pegs[1].width / 2, 0))
		assert_true(near(pegs[#pegs].x + pegs[#pegs].width / 2, 95))
		for i = 1, #pegs - 1 do
			assert_true(near(pegs[i].x + pegs[i].width / 2,
				pegs[i + 1].x - pegs[i + 1].width / 2), "neighbor faces touch")
		end
	end,

	test_closed_circumference_circles_have_uniform_minimum_gap = function()
		local pegs = Lines.generate({
			id = "ring", path = full_circle(100),
			peg = { kind = "circle", radius = 10 }, gap = 15,
		})
		assert_eq(#pegs, 17)
		local expected
		for i = 1, #pegs do
			local next_index = i % #pegs + 1
			local clearance = distance(pegs[i], pegs[next_index]) - 20
			assert_true(clearance >= 15 - 1e-6, "requested physical gap")
			if expected then assert_true(near(clearance, expected), "uniform closed gaps")
			else expected = clearance end
		end
	end,

	test_open_curved_circles_use_boundary_clearance_not_arc_spacing = function()
		local path = Path.new({ {
			kind = "arc", center = { 0, 0 }, radius = 80,
			theta_start = 0, sweep = math.pi,
		} })
		local pegs = Lines.generate({
			id = "arc_dots", path = path,
			peg = { kind = "circle", radius = 8 }, gap = 7,
		})
		for i = 1, #pegs - 1 do
			assert_true(near(distance(pegs[i], pegs[i + 1]) - 16, 7, 1e-5),
				"circle boundary gap is solved as a chord")
		end
	end,

	test_gapless_straight_circles_touch_and_cover_both_ends = function()
		local pegs = Lines.generate({
			id = "circle_chain", path = straight(95),
			peg = { kind = "circle", radius = 10 }, gap = 0,
		})
		assert_eq(#pegs, 5)
		assert_true(pegs[1].x - pegs[1].radius <= 0, "first circle covers path start")
		assert_true(pegs[#pegs].x + pegs[#pegs].radius >= 95, "last circle covers path end")
		for i = 1, #pegs - 1 do
			assert_true(near(distance(pegs[i], pegs[i + 1]), 20), "rigid circles touch")
		end
	end,

	test_exact_annular_arc_positive_gap_uses_inner_boundary = function()
		local path = Path.new({ {
			kind = "arc", center = { 0, 0 }, radius = 100,
			theta_start = 0, sweep = math.pi,
		} })
		local pegs = Lines.generate({
			id = "arc_tiles", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 30 }, gap = 10,
		})
		for i = 1, #pegs - 1 do
			local a = pegs[i].corners[3]
			local b = pegs[i + 1].corners[1]
			assert_true(near(distance(a, b), 10, 1e-5), "inner cap endpoints define exact clearance")
		end
	end,

	test_gapless_exact_annular_arc_has_shared_caps = function()
		local path = Path.new({ {
			kind = "arc", center = { 0, 0 }, radius = 100,
			theta_start = math.pi, sweep = -math.pi,
		} })
		local pegs = Lines.generate({
			id = "cw_tiles", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 35 }, gap = 0,
		})
		for i = 1, #pegs - 1 do
			-- Clockwise Peg sectors reverse constructor endpoints, so compare the
			-- physical cap that follows traversal rather than fixed corner indices.
			local shared = false
			for ai = 1, 4 do for bi = 1, 4 do
				if same_point(pegs[i].corners[ai], pegs[i + 1].corners[bi], 1e-6) then shared = true end
			end end
			assert_true(shared, "clockwise annular neighbors share a cap")
		end
	end,

	test_composite_cocircular_arcs_support_positive_annular_gap = function()
		local path = Path.new({
			{ kind = "arc", center = { 0, 0 }, radius = 100,
				theta_start = 0, sweep = math.pi / 2 },
			{ kind = "arc", center = { 0, 0 }, radius = 100,
				theta_start = math.pi / 2, sweep = math.pi / 2 },
		})
		local pegs = Lines.generate({
			id = "composite_arc", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 30 }, gap = 8,
		})
		assert_true(#pegs > 1)
		for i = 1, #pegs - 1 do
			assert_true(near(distance(pegs[i].corners[3], pegs[i + 1].corners[1]), 8, 1e-5))
		end
	end,

	test_gapless_spiral_emits_touching_annular_pegs = function()
		local path = Path.archimedean_spiral({
			center = { x = 400, y = 400 }, r_start = 60, r_end = 140,
			turns = 1.25, curve_tolerance = 0.25,
		})
		local pegs = Lines.generate({
			id = "spiral", path = path,
			peg = { kind = "annular", thickness = 12, max_length = 32 },
			gap = 0, curve_tolerance = 0.25,
		})
		assert_true(#pegs > 10, "spiral was adaptively segmented")
		for i = 1, #pegs - 1 do
			assert_true(caps_touch(pegs[i], pegs[i + 1], 1e-5),
				"annular spiral neighbors share both cap endpoints")
		end
	end,

	test_rejects_tangent_discontinuous_annular_curves = function()
		local path = Path.new({ segments = {
			{ kind = "cubic", p0 = { 0, 0 }, c1 = { 1, 0 }, c2 = { 2, -1 }, p1 = { 2, 0 } },
			{ kind = "cubic", p0 = { 2, 0 }, c1 = { 3, 0 }, c2 = { 4, 1 }, p1 = { 4, 0 } },
		}, closed = false })
		assert_false(path:validate_joins(), "fixture has an interior corner")
		expect_error(function()
			Lines.generate({ id = "cornered", path = path,
				peg = { kind = "annular", thickness = 4, max_length = 8 }, gap = 0 })
		end, "annular curve has a tangent discontinuity")
	end,

	test_metadata_and_generation_order_are_stable = function()
		local spec = {
			id = "stable", path = straight(145),
			peg = { kind = "rectangle", width = 25, height = 10 }, gap = 5,
		}
		local first, second = Lines.generate(spec), Lines.generate(spec)
		assert_eq(#first, #second)
		for i = 1, #first do
			assert_true(near(first[i].x, second[i].x))
			assert_eq(first[i].line.id, "stable")
			assert_eq(first[i].line.index, i)
			assert_eq(first[i].line.count, #first)
			assert_false(first[i].line.closed)
			assert_eq(first[i].line.gap, 5)
		end
		local copied = {}
		for key, value in pairs(first[1].line) do copied[key] = value end
		assert_eq(copied.id, "stable", "metadata remains visible to Lua 5.1 serializers")
		assert_eq(copied.index, 1)
		assert_eq(copied.count, #first)
	end,

	-- ===================================================================
	-- Advanced lines: closed curved annular borders
	-- ===================================================================

	test_contact_tolerance_is_independent_and_subpixel = function()
		-- The cap-contact tolerance must be independent of curve_tolerance and
		-- small enough that a passing join cannot leak or display a crack: it
		-- only needs to absorb geometry rounding from Path.new and the
		-- emitted arcs.
		assert_true(Lines.CONTACT_TOLERANCE > Path.POINT_EPSILON,
			"contact tolerance absorbs positional slack between source segments")
		assert_true(Lines.CONTACT_TOLERANCE < Config.annular_cap_epsilon,
			"contact tolerance stays below the collision cap epsilon")
	end,

	test_convex_closed_cubic_loop_produces_annular_border = function()
		local path = convex_loop_path(8)
		assert_true(path:validate_joins(), "fixture joins are smooth")
		local pegs = Lines.generate({
			id = "convex", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 40 },
			gap = 0, curve_tolerance = 0.25,
		})
		assert_true(#pegs >= 32, "the convex loop carries a full border")
		for i, peg in ipairs(pegs) do
			assert_eq(peg.shape, "annular")
			assert_true(peg.r_in > 0 and peg.r_out > peg.r_in)
			assert_eq(peg.line.id, "convex")
			assert_eq(peg.line.index, i)
			assert_eq(peg.line.count, #pegs)
			assert_true(peg.line.closed)
			assert_eq(peg.line.gap, 0)
		end
		local worst = bounded_centerline_error(path, pegs)
		assert_true(worst <= 0.25,
			"convex border covers the source loop, worst gap " .. tostring(worst))
	end,

	test_squiggle_fixture_generates_complete_annular_border = function()
		local path = squiggle_path(96)
		assert_true(path:validate_joins(), "fixture joins including the seam are smooth")
		local pegs = Lines.generate({
			id = "squiggle", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 40 },
			gap = 0, curve_tolerance = 0.25,
		})
		assert_true(#pegs >= 192, "the 96-segment fixture emits at least two pieces per cubic")
		for i, peg in ipairs(pegs) do
			local arc_length = (peg.r_in + peg.r_out) * 0.5
				* (peg.theta_end_abs - peg.theta_start)
			assert_true(arc_length <= 40 + 1e-6,
				"piece " .. i .. " respects max_length, got " .. tostring(arc_length))
			assert_true(peg.r_in > 0, "piece " .. i .. " has a positive inner radius")
			assert_true(peg.line.index == i and peg.line.count == #pegs)
			assert_true(peg.line.closed)
		end
		-- Independently sample the authored cubics against analytic centerlines.
		local worst = bounded_centerline_error(path, pegs)
		assert_true(worst <= 0.25,
			"squiggle border continuously covers the source loop, worst gap "
				.. tostring(worst))
		-- The authored geometry is a valid level line.
		Lines.validate(pegs)
	end,

	test_reversed_squiggle_has_equivalent_coverage_and_order = function()
		local path = squiggle_path(96)
		local reversed_path = reverse_path(path)
		assert_true(reversed_path:validate_joins(), "reversed fixture stays smooth")
		local forward = Lines.generate({
			id = "squiggle_fwd", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 40 },
			gap = 0, curve_tolerance = 0.25,
		})
		local reversed = Lines.generate({
			id = "squiggle_rev", path = reversed_path,
			peg = { kind = "annular", thickness = 20, max_length = 40 },
			gap = 0, curve_tolerance = 0.25,
		})
		assert_eq(#reversed, #forward, "reversed traversal emits the same piece count")
		for i, peg in ipairs(reversed) do
			assert_eq(peg.line.index, i, "line ordering follows reversed traversal")
			assert_eq(peg.line.count, #reversed)
			assert_true(peg.line.closed)
			local other = forward[#forward - i + 1]
			assert_true(near(peg.x, other.x, 1e-5) and near(peg.y, other.y, 1e-5),
				"reversal preserves each arc center")
			assert_true(near(peg.r_in, other.r_in, 1e-5) and near(peg.r_out, other.r_out, 1e-5))
			for corner = 1, 4 do
				assert_true(same_point(peg.corners[corner], other.corners[corner], 1e-5),
					"reversal preserves each cap endpoint")
			end
		end
		local worst = bounded_centerline_error(path, reversed)
		assert_true(worst <= 0.25,
			"reversed border covers the same source loop, worst gap " .. tostring(worst))
		Lines.validate(reversed)
	end,

	test_closed_seam_corner_fails_with_segment_context = function()
		-- Interior join is smooth; the closing seam has a corner.
		local path = Path.new({ segments = {
			{ kind = "cubic", p0 = { 0, 0 }, c1 = { 0, -50 }, c2 = { 100, -50 }, p1 = { 100, 0 } },
			{ kind = "cubic", p0 = { 100, 0 }, c1 = { 100, 50 }, c2 = { 50, 50 }, p1 = { 0, 0 } },
		}, closed = true })
		expect_error(function()
			Lines.generate({ id = "seam_corner", path = path,
				peg = { kind = "annular", thickness = 4, max_length = 8 }, gap = 0 })
		end, "tangent discontinuity at segments 2 and 1 (closing seam)")
	end,

	test_inflected_and_near_straight_cubics_fit = function()
		local function cap_gap(a, b)
			local best = math.huge
			for a_cap = 0, 1 do
				local a1 = a.corners[a_cap * 2 + 1]
				local a2 = a.corners[a_cap * 2 + 2]
				for b_cap = 0, 1 do
					local b1 = b.corners[b_cap * 2 + 1]
					local b2 = b.corners[b_cap * 2 + 2]
					best = math.min(best,
						math.max(distance(a1, b1), distance(a2, b2)),
						math.max(distance(a1, b2), distance(a2, b1)))
				end
			end
			return best
		end
		local fixtures = {
			inflected = Path.new({ { kind = "cubic", p0 = { 0, 0 },
				c1 = { 100, 0 }, c2 = { 0, 100 }, p1 = { 100, 100 } } }),
			near_straight = Path.new({ { kind = "cubic", p0 = { 0, 0 },
				c1 = { 100, 0.01 }, c2 = { 200, -0.01 }, p1 = { 300, 0 } } }),
		}
		for label, path in pairs(fixtures) do
			local pegs = Lines.generate({ id = label, path = path,
				peg = { kind = "annular", thickness = 20, max_length = 40 },
				gap = 0, curve_tolerance = 0.25 })
			assert_true(#pegs >= 1, label .. " emits pieces")
			for i = 1, #pegs - 1 do
				assert_true(cap_gap(pegs[i], pegs[i + 1]) <= Lines.CONTACT_TOLERANCE,
					label .. " join " .. i .. " shares a cap")
			end
		end
	end,

	test_too_tight_curvature_fails_with_clear_error = function()
		-- Minimum curvature radius is ~9.26 px, below the 10 px half thickness,
		-- so no positive-inner-radius annular border can follow this curve.
		local path = Path.new({ { kind = "cubic", p0 = { 0, 0 },
			c1 = { 200, 0 }, c2 = { -100, 100 }, p1 = { 100, 100 } } })
		expect_error(function()
			Lines.generate({ id = "tight", path = path,
				peg = { kind = "annular", thickness = 20, max_length = 40 },
				gap = 0, curve_tolerance = 0.25 })
		end, "cannot be represented by annular biarcs")
	end,

	test_exhausted_tolerance_produces_clear_error = function()
		local spiral = Path.archimedean_spiral({
			center = { x = 400, y = 400 }, r_start = 60, r_end = 140,
			turns = 1.25, curve_tolerance = 0.25,
		})
		-- The spiral already spent its compilation budget; a biarc budget of
		-- zero must fail instead of silently spending the same budget twice.
		expect_error(function()
			Lines.generate({ id = "exhausted", path = spiral,
				peg = { kind = "annular", thickness = 12, max_length = 32 },
				gap = 0, curve_tolerance = 0.125 })
		end, "already exhausted")
	end,

	test_repeated_squiggle_generation_is_identical = function()
		local spec = { id = "repeat", path = squiggle_path(96),
			peg = { kind = "annular", thickness = 20, max_length = 40 },
			gap = 0, curve_tolerance = 0.25 }
		local first, second = Lines.generate(spec), Lines.generate(spec)
		assert_eq(#first, #second)
		for i = 1, #first do
			assert_eq(first[i].line.index, second[i].line.index)
			assert_true(near(first[i].r_in, second[i].r_in, 0))
			assert_true(near(first[i].r_out, second[i].r_out, 0))
			assert_true(near(first[i].theta_start, second[i].theta_start, 0))
			assert_true(near(first[i].theta_end_abs, second[i].theta_end_abs, 0))
			for c = 1, 4 do
				assert_true(near(first[i].corners[c].x, second[i].corners[c].x, 0))
				assert_true(near(first[i].corners[c].y, second[i].corners[c].y, 0))
			end
		end
	end,

	test_validate_rejects_separated_zero_gap_neighbors = function()
		local pegs = Lines.generate({ id = "ring_sep", path = full_circle(200),
			peg = { kind = "annular", thickness = 20, max_length = 35 }, gap = 0 })
		-- Shift the second piece's leading cap 0.5 px along its traversal
		-- tangent: the border separates without any positive overlap.
		local peg = pegs[2]
		local c1, c2 = peg.corners[1], peg.corners[2]
		local theta = peg.theta_start
		local tx, ty = -math.sin(theta), math.cos(theta)
		c1.x, c1.y = c1.x + tx * 0.5, c1.y + ty * 0.5
		c2.x, c2.y = c2.x + tx * 0.5, c2.y + ty * 0.5
		expect_error(function() Lines.validate(pegs) end, "cap gap")
	end,

	test_validate_rejects_broken_closing_seam_contact = function()
		local pegs = Lines.generate({ id = "ring_seam", path = full_circle(200),
			peg = { kind = "annular", thickness = 20, max_length = 35 }, gap = 0 })
		-- Move the first piece's start cap backwards, away from the last
		-- piece's end cap: the closed seam no longer shares a boundary.
		local peg = pegs[1]
		local c1, c2 = peg.corners[1], peg.corners[2]
		local theta = peg.theta_start
		local tx, ty = -math.sin(theta), math.cos(theta)
		c1.x, c1.y = c1.x - tx * 0.5, c1.y - ty * 0.5
		c2.x, c2.y = c2.x - tx * 0.5, c2.y - ty * 0.5
		expect_error(function() Lines.validate(pegs) end, "closing seam pegs")
	end,

	-- ===================================================================
	-- Phase 3: level-wide metadata validation and boundary attribution
	-- ===================================================================

	test_generated_lines_validate = function()
		local board = {}
		local a = Lines.generate({ id = "circles", path = straight(160),
			peg = { kind = "circle", radius = 10 }, gap = 0 })
		local b = Lines.generate({ id = "ring", path = full_circle(200),
			peg = { kind = "annular", thickness = 20, max_length = 35 }, gap = 0 })
		for _, peg in ipairs(a) do table.insert(board, peg) end
		for _, peg in ipairs(b) do table.insert(board, peg) end
		table.insert(board, { shape = "circle", x = 900, y = 900,
			original_index = 999 })
		Lines.validate(board)
		Lines.validate({})
	end,

	test_validate_rejects_malformed_metadata = function()
		local function board_with(line_mutation)
			local pegs = Lines.generate({ id = "ok", path = straight(80),
				peg = { kind = "circle", radius = 10 }, gap = 0 })
			if line_mutation then line_mutation(pegs) end
			return pegs
		end
		local cases = {
			{ label = "line not a table",
			  mutate = function(p) p[1].line = 5 end,
			  expect = "line metadata must be a table" },
			{ label = "line.id empty",
			  mutate = function(p) p[1].line.id = "" end,
			  expect = "line.id must be a non-empty string" },
			{ label = "line.index not an integer",
			  mutate = function(p) p[1].line.index = 1.5 end,
			  expect = "line.index must be a positive integer" },
			{ label = "line.index zero",
			  mutate = function(p) p[1].line.index = 0 end,
			  expect = "line.index must be a positive integer" },
			{ label = "line.count non-integer",
			  mutate = function(p) p[1].line.count = 3.5 end,
			  expect = "line.count must be a positive integer" },
			{ label = "line.index exceeds count",
			  mutate = function(p) p[1].line.index = 99 end,
			  expect = "exceeds the declared count" },
			{ label = "line.closed wrong type",
			  mutate = function(p) p[1].line.closed = 0 end,
			  expect = "line.closed must be a boolean" },
			{ label = "line.gap negative",
			  mutate = function(p) p[1].line.gap = -1 end,
			  expect = "line.gap must be a non-negative finite number" },
		}
		for _, c in ipairs(cases) do
			expect_error(function()
				Lines.validate(board_with(c.mutate))
			end, c.expect)
		end
		expect_error(function()
			Lines.validate("not a board")
		end, "pegs must be a table")
	end,

	test_validate_rejects_duplicate_and_dropped_indices = function()
		local function pegs_of(count)
			return Lines.generate({ id = "dup", path = straight(count * 19),
				peg = { kind = "circle", radius = 10 }, gap = 0 })
		end
		-- Swap two pegs: indices stop being contiguous in peg order.
		local swapped = pegs_of(4)
		swapped[3].line.index, swapped[4].line.index =
			swapped[4].line.index, swapped[3].line.index
		expect_error(function() Lines.validate(swapped) end,
			"indices are not contiguous")
		-- Drop the last member: indices stay contiguous but the declared
		-- count no longer matches the level.
		local dropped = pegs_of(4)
		table.remove(dropped, #dropped)
		expect_error(function() Lines.validate(dropped) end,
			"declares 4 pegs but the level holds 3")
	end,

	test_validate_rejects_inconsistent_group_metadata = function()
		local function line_of(count)
			return Lines.generate({ id = "group", path = straight(count * 19),
				peg = { kind = "circle", radius = 10 }, gap = 0 })
		end
		local mismatched_count = line_of(4)
		mismatched_count[2].line.count = 6
		expect_error(function() Lines.validate(mismatched_count) end,
			"inconsistent counts")
		local mismatched_gap = line_of(4)
		mismatched_gap[2].line.gap = 2
		expect_error(function() Lines.validate(mismatched_gap) end,
			"inconsistent gap")
		local mismatched_closed = line_of(4)
		mismatched_closed[2].line.closed = true
		expect_error(function() Lines.validate(mismatched_closed) end,
			"inconsistent closed")
	end,

	test_validate_rejects_non_collinear_rectangles = function()
		local pegs = Lines.generate({ id = "rect", path = straight(120),
			peg = { kind = "rectangle", width = 20, height = 12 }, gap = 0 })
		-- Rotate the second rectangle: geometry no longer agrees with the
		-- straight/tangent-aligned contract.
		pegs[2].angle = math.rad(15)
		expect_error(function() Lines.validate(pegs) end,
			"not collinear and tangent-aligned")
	end,

	test_validate_rejects_invalid_annular_geometry = function()
		local path = Path.new({ {
			kind = "arc", center = { 0, 0 }, radius = 100,
			theta_start = 0, sweep = math.pi,
		} })
		local pegs = Lines.generate({ id = "ann", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 30 }, gap = 10 })
		-- Break co-circularity: positive-gap annular members must share one
		-- exact circular center and identical radii.
		pegs[2].x = pegs[2].x + 3
		expect_error(function() Lines.validate(pegs) end,
			"positive-gap annular pegs are not co-circular")
		-- Invalid radii are always rejected.
		local bad_radii = Lines.generate({ id = "ann2", path = path,
			peg = { kind = "annular", thickness = 20, max_length = 30 }, gap = 0 })
		bad_radii[1].r_in = 0
		expect_error(function() Lines.validate(bad_radii) end,
			"invalid radii")
	end,

	test_validate_rejects_non_neighbor_overlap = function()
		-- Hand-move a member over a non-neighbor (authoring error): zero-gap
		-- same-line non-neighbor overlap is not a shared boundary.
		local pegs = Lines.generate({ id = "spread", path = straight(200),
			peg = { kind = "circle", radius = 10 }, gap = 0 })
		assert_true(#pegs >= 5)
		-- Peg 1 at x0; pull peg 3 to within one diameter of peg 1 (its
		-- neighbors stay touching: only the 1-3 pair is non-adjacent).
		pegs[3].x = pegs[1].x + 19
		assert_true(near(pegs[3].x - pegs[1].x, 19))
		expect_error(function() Lines.validate(pegs) end,
			"non-neighbor pegs 1 and 3 overlap")
	end,

	test_validate_rejects_l_shaped_rectangle_sequence = function()
		-- Each consecutive delta is parallel to its own local angle, so an
		-- L-shaped turn must still be rejected: rectangle lines require one
		-- common tangent direction, including the final member's angle.
		local function rect_peg(x, y, angle, index)
			return {
				shape = "rectangle", x = x, y = y, width = 4, height = 4,
				angle = angle,
				line = { id = "L", index = index, count = 3, closed = false, gap = 0 },
			}
		end
		local pegs = {
			rect_peg(0, 0, 0, 1),
			rect_peg(10, 0, math.pi / 2, 2),
			rect_peg(10, 10, math.pi / 2, 3),
		}
		expect_error(function() Lines.validate(pegs) end, "collinear")
	end,

	test_validate_accepts_generated_straight_rectangle_line = function()
		local pegs = Lines.generate({ id = "straight_rect", path = straight(120),
			peg = { kind = "rectangle", width = 20, height = 10 }, gap = 0 })
		Lines.validate(pegs)
	end,

	test_validate_rejects_positive_gap_neighbor_overlap = function()
		local pegs = {
			{ shape = "circle", x = 0, y = 0, radius = 10,
			  line = { id = "pg", index = 1, count = 2, closed = false, gap = 6 } },
			{ shape = "circle", x = 5, y = 0, radius = 10,
			  line = { id = "pg", index = 2, count = 2, closed = false, gap = 6 } },
		}
		expect_error(function() Lines.validate(pegs) end, "overlap")
	end,

	test_validate_rejects_zero_gap_neighbor_overlap = function()
		local pegs = {
			{ shape = "circle", x = 0, y = 0, radius = 10,
			  line = { id = "zg", index = 1, count = 2, closed = false, gap = 0 } },
			{ shape = "circle", x = 5, y = 0, radius = 10,
			  line = { id = "zg", index = 2, count = 2, closed = false, gap = 0 } },
		}
		expect_error(function() Lines.validate(pegs) end, "overlap")
	end,

	test_validate_accepts_exact_contact_zero_gap_neighbors = function()
		local pegs = {
			{ shape = "circle", x = 0, y = 0, radius = 10,
			  line = { id = "contact", index = 1, count = 2, closed = false, gap = 0 } },
			{ shape = "circle", x = 20, y = 0, radius = 10,
			  line = { id = "contact", index = 2, count = 2, closed = false, gap = 0 } },
		}
		Lines.validate(pegs)
	end,

	test_is_intentional_contact_matches_zero_gap_neighbors = function()
		local pegs = Lines.generate({ id = "adj", path = straight(200),
			peg = { kind = "circle", radius = 10 }, gap = 0 })
		assert_true(#pegs >= 4)
		for i = 1, #pegs - 1 do
			assert_true(Lines.is_intentional_contact(pegs[i], pegs[i + 1]),
				"open-line neighbors are intentional contact")
		end
		assert_false(Lines.is_intentional_contact(pegs[1], pegs[3]),
			"non-neighbors are not intentional contact")
		assert_false(Lines.is_intentional_contact(pegs[1], pegs[#pegs]),
			"open line ends do not wrap")

		local ring = Lines.generate({ id = "wrap", path = full_circle(200),
			peg = { kind = "annular", thickness = 20, max_length = 35 }, gap = 0 })
		local n = #ring
		assert_true(Lines.is_intentional_contact(ring[1], ring[n]),
			"closed seam neighbors are intentional contact")
		for i = 2, n - 2 do
			assert_false(Lines.is_intentional_contact(ring[i], ring[i + 2]),
				"closed line skips are not intentional contact")
		end
		-- Positive-gap neighbors do not touch: no intentional boundary.
		local gapped = Lines.generate({ id = "gapped", path = straight(200),
			peg = { kind = "circle", radius = 10 }, gap = 5 })
		assert_false(Lines.is_intentional_contact(gapped[1], gapped[2]))
		-- Pegs on different lines never share an intentional boundary.
		local other = Lines.generate({ id = "other", path = straight(200),
			peg = { kind = "circle", radius = 10 }, gap = 0 })
		assert_false(Lines.is_intentional_contact(pegs[1], other[1]))
		-- Pegs without line metadata are never intentional contact.
		assert_false(Lines.is_intentional_contact(
			{ shape = "circle" }, pegs[1]))
	end,

	test_rejects_unsupported_or_impossible_packings = function()
		local curved = Path.new({ {
			kind = "arc", center = { 0, 0 }, radius = 100,
			theta_start = 0, sweep = math.pi,
		} })
		expect_error(function()
			Lines.generate({ id = "bad_rect", path = curved,
				peg = { kind = "rectangle", width = 20, height = 10 }, gap = 0 })
		end, "straight/collinear")
		expect_error(function()
			Lines.generate({ id = "bad_annular", path = curved,
				peg = { kind = "annular", thickness = 220, max_length = 20 }, gap = 0 })
		end, "inner radius")
		expect_error(function()
			Lines.generate({ id = "short", path = straight(10),
				peg = { kind = "circle", radius = 10 }, gap = 2 })
		end, "shorter than one circle")
		expect_error(function()
			Lines.generate({ id = "curved_touching", path = curved,
				peg = { kind = "circle", radius = 10 }, gap = 0 })
		end, "complete curved-path coverage")
		-- The gapless-curve limitation also applies to closed curved paths;
		-- curved paths require gap > 0.
		expect_error(function()
			Lines.generate({ id = "closed_curved_touching", path = full_circle(100),
				peg = { kind = "circle", radius = 10 }, gap = 0 })
		end, "complete curved-path coverage")
	end,
}
