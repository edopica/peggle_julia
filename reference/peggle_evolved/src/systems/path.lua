-- Structured, deterministic 2D paths for static level authoring.
--
-- Paths are deliberately data-driven: the public segment vocabulary is small
-- enough to reproduce in the future Julia simulator and does not permit
-- arbitrary Lua callbacks.

local Path = {}
local Path_mt = { __index = Path }

local LENGTH_TOLERANCE = 0.001
local MAX_DEPTH = 20
local POINT_EPSILON = 1e-7
local SPEED_EPSILON = 1e-10
local TWO_PI = math.pi * 2
-- The table brackets inversion; interpolation alone is inaccurate when cubic
-- parameter speed varies. Refine only within one small table interval.
local CUBIC_TABLE_STEPS = 256
-- Per-cubic distance error budget in pixels (excluding floating-point roundoff).
-- Half bounds accumulated integration error; the rest bounds local inversion.
-- A secant crossing one cubic join allows 2 * this budget / dt speed error.
local CUBIC_DISTANCE_TOLERANCE = 1e-7

local function finite(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

local function fail(message, level)
	error("Path: " .. message, (level or 1) + 1)
end

local function number(value, name)
	if not finite(value) then fail(name .. " must be a finite number", 2) end
	return value
end

local function point(value, name)
	if type(value) ~= "table" then fail(name .. " must be a point table", 2) end
	local x = value.x
	local y = value.y
	if x == nil then x = value[1] end
	if y == nil then y = value[2] end
	return { x = number(x, name .. ".x"), y = number(y, name .. ".y") }
end

local function distance(a, b)
	local dx, dy = b.x - a.x, b.y - a.y
	return math.sqrt(dx * dx + dy * dy)
end

local function lerp_point(a, b, t)
	return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }
end

local function normalize(x, y, context)
	local length = math.sqrt(x * x + y * y)
	if length <= SPEED_EPSILON then fail(context .. " has a cusp or zero tangent", 2) end
	return x / length, y / length
end

local function line_position(segment, t)
	return lerp_point(segment.p0, segment.p1, t)
end

local function arc_position(segment, t)
	local theta = segment.theta_start + segment.sweep * t
	return {
		x = segment.center.x + segment.radius * math.cos(theta),
		y = segment.center.y + segment.radius * math.sin(theta),
	}
end

local function cubic_position(segment, t)
	-- de Casteljau evaluation avoids the cancellation of expanded Bernstein
	-- polynomials near segment endpoints.
	local a = lerp_point(segment.p0, segment.c1, t)
	local b = lerp_point(segment.c1, segment.c2, t)
	local c = lerp_point(segment.c2, segment.p1, t)
	local d = lerp_point(a, b, t)
	local e = lerp_point(b, c, t)
	return lerp_point(d, e, t)
end

local function cubic_derivatives(segment, t)
	local mt = 1 - t
	local dx = 3 * (mt * mt * (segment.c1.x - segment.p0.x)
		+ 2 * mt * t * (segment.c2.x - segment.c1.x)
		+ t * t * (segment.p1.x - segment.c2.x))
	local dy = 3 * (mt * mt * (segment.c1.y - segment.p0.y)
		+ 2 * mt * t * (segment.c2.y - segment.c1.y)
		+ t * t * (segment.p1.y - segment.c2.y))
	local ddx = 6 * (mt * (segment.c2.x - 2 * segment.c1.x + segment.p0.x)
		+ t * (segment.p1.x - 2 * segment.c2.x + segment.c1.x))
	local ddy = 6 * (mt * (segment.c2.y - 2 * segment.c1.y + segment.p0.y)
		+ t * (segment.p1.y - 2 * segment.c2.y + segment.c1.y))
	return dx, dy, ddx, ddy
end

local function split_cubic_points(p0, c1, c2, p1)
	local a = lerp_point(p0, c1, 0.5)
	local b = lerp_point(c1, c2, 0.5)
	local c = lerp_point(c2, p1, 0.5)
	local d = lerp_point(a, b, 0.5)
	local e = lerp_point(b, c, 0.5)
	local m = lerp_point(d, e, 0.5)
	return p0, a, d, m, m, e, c, p1
end

local function cubic_length_recursive(p0, c1, c2, p1, tolerance, depth)
	local chord = distance(p0, p1)
	local polygon = distance(p0, c1) + distance(c1, c2) + distance(c2, p1)
	local estimate = (chord + polygon) * 0.5
	if (polygon - chord) * 0.5 <= tolerance then
		return estimate
	end
	if depth >= MAX_DEPTH then
		fail("cubic length subdivision exceeded maximum depth " .. MAX_DEPTH, 2)
	end
	local l0, l1, l2, lm, r0, r1, r2, r3 = split_cubic_points(p0, c1, c2, p1)
	return cubic_length_recursive(l0, l1, l2, lm, tolerance * 0.5, depth + 1)
		+ cubic_length_recursive(r0, r1, r2, r3, tolerance * 0.5, depth + 1)
end

local function cubic_subsegment(segment, t)
	if t <= 0 then return segment.p0, segment.p0, segment.p0, segment.p0 end
	if t >= 1 then return segment.p0, segment.c1, segment.c2, segment.p1 end
	local a = lerp_point(segment.p0, segment.c1, t)
	local b = lerp_point(segment.c1, segment.c2, t)
	local c = lerp_point(segment.c2, segment.p1, t)
	local d = lerp_point(a, b, t)
	local e = lerp_point(b, c, t)
	local p = lerp_point(d, e, t)
	return segment.p0, a, d, p
end

-- Arc length of the parameter interval [t0, t1] of a cubic segment. Splits
-- the full curve at t1, then at t0 / t1 (de Casteljau is parameter-affine),
-- so the recursive estimator only sees the requested sub-curve.
local function cubic_length_between(segment, t0, t1, tolerance)
	if t1 <= t0 then return 0 end
	if t0 <= 0 and t1 >= 1 then
		return cubic_length_recursive(segment.p0, segment.c1, segment.c2, segment.p1,
			tolerance, 0)
	end
	local p0, c1, c2, p1 = cubic_subsegment(segment, t1)
	local u = t0 / t1
	if u <= 0 then
		return cubic_length_recursive(p0, c1, c2, p1, tolerance, 0)
	end
	local a = lerp_point(p0, c1, u)
	local b = lerp_point(c1, c2, u)
	local c = lerp_point(c2, p1, u)
	local d = lerp_point(a, b, u)
	local e = lerp_point(b, c, u)
	local m = lerp_point(d, e, u)
	return cubic_length_recursive(m, e, c, p1, tolerance, 0)
end

-- Build the uniform-parameter cumulative arc-length table for one cubic and
-- set segment.length from its total. Split the integration budget across all
-- intervals so prefix errors stay within half the cubic distance tolerance.
local function build_cubic_length_table(segment)
	local steps = CUBIC_TABLE_STEPS
	local interval_tolerance = CUBIC_DISTANCE_TOLERANCE * 0.5 / steps
	local table_s = { 0 }
	local total = 0
	for i = 1, steps do
		total = total + cubic_length_between(segment, (i - 1) / steps, i / steps,
			interval_tolerance)
		table_s[i + 1] = total
	end
	segment.table_s = table_s
	segment.length = total
end

local function quadratic_roots(a, b, c)
	local roots = {}
	if math.abs(a) <= SPEED_EPSILON then
		if math.abs(b) > SPEED_EPSILON then roots[1] = -c / b end
		return roots
	end
	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then return roots end
	local root = math.sqrt(math.max(0, discriminant))
	roots[1] = (-b - root) / (2 * a)
	if root > SPEED_EPSILON then roots[2] = (-b + root) / (2 * a) end
	return roots
end

local function validate_cubic_tangent(segment)
	local function derivative_coeff(axis)
		local p0, p1, p2, p3 = segment.p0[axis], segment.c1[axis], segment.c2[axis], segment.p1[axis]
		return 3 * (-p0 + 3 * p1 - 3 * p2 + p3),
			6 * (p0 - 2 * p1 + p2), 3 * (p1 - p0)
	end
	local ax, bx, cx = derivative_coeff("x")
	local ay, by, cy = derivative_coeff("y")
	local candidates = { 0, 1 }
	for _, t in ipairs(quadratic_roots(ax, bx, cx)) do candidates[#candidates + 1] = t end
	for _, t in ipairs(quadratic_roots(ay, by, cy)) do candidates[#candidates + 1] = t end
	for _, t in ipairs(candidates) do
		if t >= 0 and t <= 1 then
			local dx, dy = cubic_derivatives(segment, t)
			if dx * dx + dy * dy <= SPEED_EPSILON * SPEED_EPSILON then
				fail("cubic segment has a cusp or zero tangent", 2)
			end
		end
	end
end

local function canonical_segment(raw, index)
	if type(raw) ~= "table" then fail("segment " .. index .. " must be a table", 2) end
	local kind = raw.kind
	if kind == "line" then
		local segment = { kind = kind, p0 = point(raw.p0, "segment " .. index .. ".p0"),
			p1 = point(raw.p1, "segment " .. index .. ".p1") }
		segment.length = distance(segment.p0, segment.p1)
		if not finite(segment.length) then fail("line segment " .. index .. " length is not finite", 2) end
		if segment.length <= POINT_EPSILON then fail("line segment " .. index .. " has zero length", 2) end
		return segment
	elseif kind == "arc" then
		local segment = {
			kind = kind,
			center = point(raw.center, "segment " .. index .. ".center"),
			radius = number(raw.radius, "segment " .. index .. ".radius"),
			theta_start = number(raw.theta_start, "segment " .. index .. ".theta_start"),
			sweep = number(raw.sweep, "segment " .. index .. ".sweep"),
		}
		if segment.radius <= 0 then fail("arc segment " .. index .. " radius must be positive", 2) end
		if math.abs(segment.sweep) <= POINT_EPSILON then fail("arc segment " .. index .. " has zero sweep", 2) end
		if math.abs(segment.sweep) > TWO_PI + POINT_EPSILON then
			fail("arc segment " .. index .. " sweep must not exceed one revolution", 2)
		end
		segment.p0 = arc_position(segment, 0)
		segment.p1 = arc_position(segment, 1)
		segment.length = segment.radius * math.abs(segment.sweep)
		if not finite(segment.length) then fail("arc segment " .. index .. " length is not finite", 2) end
		return segment
	elseif kind == "cubic" then
		local segment = {
			kind = kind,
			p0 = point(raw.p0, "segment " .. index .. ".p0"),
			c1 = point(raw.c1, "segment " .. index .. ".c1"),
			c2 = point(raw.c2, "segment " .. index .. ".c2"),
			p1 = point(raw.p1, "segment " .. index .. ".p1"),
		}
		validate_cubic_tangent(segment)
		build_cubic_length_table(segment)
		if not finite(segment.length) then fail("cubic segment " .. index .. " length is not finite", 2) end
		if segment.length <= POINT_EPSILON then fail("cubic segment " .. index .. " has zero length", 2) end
		return segment
	end
	fail("segment " .. index .. " has unsupported kind " .. tostring(kind), 2)
end

local function segment_position(segment, t)
	if segment.kind == "line" then return line_position(segment, t) end
	if segment.kind == "arc" then return arc_position(segment, t) end
	return cubic_position(segment, t)
end

local function segment_frame(segment, t)
	local p = segment_position(segment, t)
	local dx, dy, ddx, ddy
	if segment.kind == "line" then
		dx, dy = segment.p1.x - segment.p0.x, segment.p1.y - segment.p0.y
		ddx, ddy = 0, 0
	elseif segment.kind == "arc" then
		local theta = segment.theta_start + segment.sweep * t
		dx = -segment.radius * math.sin(theta) * segment.sweep
		dy = segment.radius * math.cos(theta) * segment.sweep
		ddx = -segment.radius * math.cos(theta) * segment.sweep * segment.sweep
		ddy = -segment.radius * math.sin(theta) * segment.sweep * segment.sweep
	else
		dx, dy, ddx, ddy = cubic_derivatives(segment, t)
	end
	local tx, ty = normalize(dx, dy, segment.kind .. " segment")
	local speed2 = dx * dx + dy * dy
	local curvature = (dx * ddy - dy * ddx) / (speed2 * math.sqrt(speed2))
	return p.x, p.y, { x = tx, y = ty }, curvature
end

-- Safeguarded Newton inversion with a distance residual, not a parameter
-- tolerance. Bisection keeps uneven-speed cubics inside the table bracket.
local function cubic_parameter_at_length(segment, target)
	if target <= 0 then return 0 end
	if target >= segment.length then return 1 end
	local table_s = segment.table_s
	local steps = #table_s - 1
	local low, high = 1, steps + 1
	while low < high - 1 do
		local mid = math.floor((low + high) * 0.5)
		if table_s[mid] <= target then low = mid else high = mid end
	end
	local span = table_s[high] - table_s[low]
	if span <= 0 then
		return (low - 1) / steps
	end
	local alpha = (target - table_s[low]) / span
	local start = (low - 1) / steps
	local lo, hi = start, (high - 1) / steps
	local t = (low - 1 + alpha) / steps
	local tolerance = CUBIC_DISTANCE_TOLERANCE * 0.25
	for _ = 1, 64 do
		local residual = table_s[low]
			+ cubic_length_between(segment, start, t, tolerance) - target
		if math.abs(residual) <= tolerance then return t end
		if residual < 0 then lo = t else hi = t end
		local dx, dy = cubic_derivatives(segment, t)
		local next_t = t - residual / math.sqrt(dx * dx + dy * dy)
		if next_t <= lo or next_t >= hi then next_t = (lo + hi) * 0.5 end
		t = next_t
	end
	fail("cubic distance inversion did not converge", 2)
end

local function segment_count(raw_segments)
	if type(raw_segments) ~= "table" then fail("requires at least one segment", 2) end
	local maximum = 0
	local count = 0
	for key in pairs(raw_segments) do
		if not finite(key) or key < 1 or key ~= math.floor(key) then
			fail("segments must be a dense contiguous array", 2)
		end
		if key > maximum then maximum = key end
		count = count + 1
	end
	if count == 0 then fail("requires at least one segment", 2) end
	for i = 1, maximum do
		if raw_segments[i] == nil then fail("segments must be a dense contiguous array", 2) end
	end
	return maximum
end

function Path.new(definition, options)
	if type(definition) ~= "table" then fail("definition must be a table", 2) end
	local raw_segments = definition.segments or definition
	local closed = definition.segments and definition.closed or (options and options.closed)
	local segment_total = segment_count(raw_segments)
	if closed ~= nil and type(closed) ~= "boolean" then fail("closed must be a boolean", 2) end

	local self = setmetatable({ segments = {}, closed = closed == true, cumulative_lengths = { 0 } }, Path_mt)
	local total = 0
	for i = 1, segment_total do
		local raw = raw_segments[i]
		local segment = canonical_segment(raw, i)
		if i > 1 then
			local previous = self.segments[i - 1]
			if distance(previous.p1, segment.p0) > POINT_EPSILON then
				fail("segments " .. (i - 1) .. " and " .. i .. " are discontinuous", 2)
			end
		end
		self.segments[i] = segment
		total = total + segment.length
		self.cumulative_lengths[i + 1] = total
	end
	if self.closed and distance(self.segments[#self.segments].p1, self.segments[1].p0) > POINT_EPSILON then
		fail("closed path has an open seam", 2)
	end
	self.total_length = total
	if not finite(self.total_length) then fail("path total length is not finite", 2) end
	return self
end

function Path:length()
	return self.total_length
end

function Path:at_distance(s)
	number(s, "distance")
	if s < 0 then s = 0 elseif s > self.total_length then s = self.total_length end
	local index = #self.segments
	for i = 1, #self.segments do
		-- Interior joins are owned by the following segment. The total endpoint
		-- remains owned by the final segment.
		if s < self.cumulative_lengths[i + 1]
			or (i == #self.segments and s == self.total_length) then
			index = i
			break
		end
	end
	local segment = self.segments[index]
	local local_s = s - self.cumulative_lengths[index]
	local t
	if segment.kind == "cubic" then
		t = cubic_parameter_at_length(segment, local_s)
	else
		t = local_s / segment.length
	end
	return segment_frame(segment, t)
end

-- Checks tangent (and residual position) agreement at every join the path
-- actually owns: interior joins in segment order, then the closing seam for
-- closed paths. Interior joins belong to the following segment for distance
-- sampling, so endpoint frames are read directly from compiled segments.
function Path:validate_joins(options)
	if options ~= nil and type(options) ~= "table" then
		fail("validate_joins options must be a table", 2)
	end
	local tangent_tolerance = 1e-6
	if options ~= nil and options.tangent_tolerance ~= nil then
		tangent_tolerance = number(options.tangent_tolerance, "tangent_tolerance")
		if tangent_tolerance < 0 then
			fail("tangent_tolerance must not be negative", 2)
		end
		if tangent_tolerance >= 1 then
			fail("tangent_tolerance must be less than 1", 2)
		end
	end
	local count = #self.segments
	local final_from = self.closed and count or count - 1
	for from_segment = 1, final_from do
		local to_segment = from_segment + 1
		local seam = false
		if to_segment > count then
			to_segment = 1
			seam = true
		end
		local from_x, from_y, incoming = segment_frame(self.segments[from_segment], 1)
		local to_x, to_y, outgoing = segment_frame(self.segments[to_segment], 0)
		local dx, dy = to_x - from_x, to_y - from_y
		local position_error = math.sqrt(dx * dx + dy * dy)
		if position_error > POINT_EPSILON then
			return false, {
				from_segment = from_segment,
				to_segment = to_segment,
				seam = seam,
				kind = "position",
				error = position_error,
				tolerance = POINT_EPSILON,
			}
		end
		local cosine = incoming.x * outgoing.x + incoming.y * outgoing.y
		if cosine > 1 then cosine = 1 elseif cosine < -1 then cosine = -1 end
		local tangent_error = 1 - cosine
		if tangent_error > tangent_tolerance then
			return false, {
				from_segment = from_segment,
				to_segment = to_segment,
				seam = seam,
				kind = "tangent",
				error = tangent_error,
				tolerance = tangent_tolerance,
			}
		end
	end
	return true
end

function Path.is_path(value)
	return getmetatable(value) == Path_mt
end

local function spiral_sample(definition, theta)
	local radius = definition.a + definition.b * theta
	local cos_theta, sin_theta = math.cos(theta), math.sin(theta)
	return {
		x = definition.center.x + radius * cos_theta,
		y = definition.center.y + radius * sin_theta,
		dx = definition.b * cos_theta - radius * sin_theta,
		dy = definition.b * sin_theta + radius * cos_theta,
	}
end

local function spiral_cubic(definition, theta0, theta1)
	local p0, p1 = spiral_sample(definition, theta0), spiral_sample(definition, theta1)
	local delta = theta1 - theta0
	return {
		kind = "cubic",
		p0 = { x = p0.x, y = p0.y },
		c1 = { x = p0.x + p0.dx * delta / 3, y = p0.y + p0.dy * delta / 3 },
		c2 = { x = p1.x - p1.dx * delta / 3, y = p1.y - p1.dy * delta / 3 },
		p1 = { x = p1.x, y = p1.y },
	}
end

local function compile_spiral(definition, theta0, theta1, tolerance, depth, output)
	local cubic = spiral_cubic(definition, theta0, theta1)
	local delta = math.abs(theta1 - theta0)
	local r0 = definition.a + definition.b * theta0
	local r1 = definition.a + definition.b * theta1
	-- Cubic Hermite interpolation has error <= h^4/384 times the maximum
	-- fourth-derivative magnitude. For z(theta)=(a+b*theta)e^(i*theta),
	-- |z''''|=sqrt(r^2+16*b^2), whose maximum is at an interval endpoint while
	-- radius stays positive. This is a conservative pointwise geometric bound.
	local derivative4 = math.max(math.sqrt(r0 * r0 + 16 * definition.b * definition.b),
		math.sqrt(r1 * r1 + 16 * definition.b * definition.b))
	local error_bound = delta^4 * derivative4 / 384
	if error_bound <= tolerance then
		output[#output + 1] = cubic
		return
	end
	if depth >= MAX_DEPTH then fail("spiral subdivision exceeded maximum depth " .. MAX_DEPTH, 2) end
	local middle = (theta0 + theta1) * 0.5
	compile_spiral(definition, theta0, middle, tolerance, depth + 1, output)
	compile_spiral(definition, middle, theta1, tolerance, depth + 1, output)
end

function Path.archimedean_spiral(definition)
	if type(definition) ~= "table" then fail("spiral definition must be a table", 2) end
	local theta_start = number(definition.theta_start or 0, "spiral.theta_start")
	local sweep = definition.sweep
	if sweep == nil and definition.turns ~= nil then sweep = definition.turns * TWO_PI end
	sweep = number(sweep, "spiral.sweep")
	if math.abs(sweep) <= POINT_EPSILON then fail("spiral sweep must be nonzero", 2) end
	local r_start = number(definition.r_start, "spiral.r_start")
	local b = definition.b
	if b == nil then
		local r_end = number(definition.r_end, "spiral.r_end")
		b = (r_end - r_start) / sweep
	else
		b = number(b, "spiral.b")
	end
	local center = point(definition.center or { x = 0, y = 0 }, "spiral.center")
	local tolerance = number(definition.curve_tolerance or definition.tolerance or 0.25,
		"spiral.curve_tolerance")
	if tolerance <= 0 then fail("spiral curve_tolerance must be positive", 2) end
	local canonical = {
		center = center,
		b = b,
		a = r_start - b * theta_start,
	}
	local r_end = canonical.a + canonical.b * (theta_start + sweep)
	if r_start <= 0 or r_end <= 0 then fail("spiral endpoint radii must be positive", 2) end
	-- A linear Archimedean radius reaches its minimum at one endpoint.
	local segments = {}
	-- Reserve half of the public budget for a later annular biarc conversion.
	-- The Path itself therefore satisfies a stricter bound than requested.
	local compilation_tolerance = tolerance * 0.5
	compile_spiral(canonical, theta_start, theta_start + sweep, compilation_tolerance, 0, segments)
	local path = Path.new({ segments = segments, closed = false })
	path.source_kind = "spiral"
	path.curve_tolerance = tolerance
	path.approximation_error_bound = compilation_tolerance
	return path
end

Path.LENGTH_TOLERANCE = LENGTH_TOLERANCE
Path.MAX_DEPTH = MAX_DEPTH
Path.POINT_EPSILON = POINT_EPSILON
Path.CUBIC_TABLE_STEPS = CUBIC_TABLE_STEPS
Path.CUBIC_DISTANCE_TOLERANCE = CUBIC_DISTANCE_TOLERANCE

return Path
