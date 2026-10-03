-- Deterministic path-to-peg authoring.
--
-- Generated pegs are ordinary Peg entities. A line is not a runtime collider
-- or a motion circuit; it is exhausted into an ipairs-ordered peg array while
-- the level file is loaded.

local Path = require("src.systems.path")
local Peg = require("src.entities.peg")
local OverlapDetector = require("src.systems.overlap_detector")

local Lines = {}

local EPSILON = 1e-7
local OVERLAP_EPSILON = 0.01
-- Maximum world-space mismatch, in pixels, between the cap endpoints of two
-- zero-gap neighboring annular pieces. It is independent of curve_tolerance:
-- approximation error controls how far the centerline may bow away from the
-- source curve, while this tolerance only measures whether the emitted pieces
-- actually share their boundary. It must absorb floating-point rounding
-- (about 1e-12 px at world coordinates near 1000) and the 1e-7 px positional
-- slack Path.new allows between source segments, while staying far below the
-- 0.01 px annular_cap_epsilon used by the collision system so that a
-- tolerance-passing join cannot leak or show a crack.
local CONTACT_TOLERANCE = 1e-4
local MAX_BIARC_DEPTH = 20
local BIARC_ERROR_SAMPLES = 256
local TWO_PI = math.pi * 2

local function finite(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

local function fail(message, level)
	error("Lines: " .. message, (level or 1) + 1)
end

local function positive(value, name)
	if not finite(value) or value <= 0 then fail(name .. " must be a positive finite number", 2) end
	return value
end

local function nonnegative(value, name)
	if not finite(value) or value < 0 then fail(name .. " must be a non-negative finite number", 2) end
	return value
end

local function point_at(path, s)
	local x, y, tangent, curvature = path:at_distance(s)
	return { x = x, y = y }, tangent, curvature
end

local function point_distance(a, b)
	local dx, dy = b.x - a.x, b.y - a.y
	return math.sqrt(dx * dx + dy * dy)
end

local function normalize(x, y)
	local length = math.sqrt(x * x + y * y)
	if length <= EPSILON then return nil end
	return { x = x / length, y = y / length }
end

local function dot(a, b)
	return a.x * b.x + a.y * b.y
end

local function lerp(a, b, t)
	return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }
end

local function cubic_position(segment, t)
	local a = lerp(segment.p0, segment.c1, t)
	local b = lerp(segment.c1, segment.c2, t)
	local c = lerp(segment.c2, segment.p1, t)
	return lerp(lerp(a, b, t), lerp(b, c, t), t)
end

local function cubic_derivative(segment, t)
	local mt = 1 - t
	return {
		x = 3 * (mt * mt * (segment.c1.x - segment.p0.x)
			+ 2 * mt * t * (segment.c2.x - segment.c1.x)
			+ t * t * (segment.p1.x - segment.c2.x)),
		y = 3 * (mt * mt * (segment.c1.y - segment.p0.y)
			+ 2 * mt * t * (segment.c2.y - segment.c1.y)
			+ t * t * (segment.p1.y - segment.c2.y)),
	}
end

local function cubic_range(segment, t0, t1)
	local p0, p1 = cubic_position(segment, t0), cubic_position(segment, t1)
	local d0, d1 = cubic_derivative(segment, t0), cubic_derivative(segment, t1)
	local scale = (t1 - t0) / 3
	return {
		kind = "cubic",
		p0 = p0,
		c1 = { x = p0.x + d0.x * scale, y = p0.y + d0.y * scale },
		c2 = { x = p1.x - d1.x * scale, y = p1.y - d1.y * scale },
		p1 = p1,
	}
end

local function signed_angle_delta(start_angle, end_angle, sign)
	if sign > 0 then return (end_angle - start_angle) % TWO_PI end
	return -((start_angle - end_angle) % TWO_PI)
end

local function arc_tangent(arc, at_end)
	local theta = arc.theta_start + (at_end and arc.sweep or 0)
	local sign = arc.sweep >= 0 and 1 or -1
	return { x = -math.sin(theta) * sign, y = math.cos(theta) * sign }
end

local function arc_from_start_tangent(p0, p1, tangent)
	local normal = { x = -tangent.y, y = tangent.x }
	local chord = { x = p1.x - p0.x, y = p1.y - p0.y }
	local denominator = 2 * dot(chord, normal)
	if math.abs(denominator) <= 1e-12 then return nil end
	local lambda = dot(chord, chord) / denominator
	local center = { x = p0.x + normal.x * lambda, y = p0.y + normal.y * lambda }
	local radius = math.abs(lambda)
	if not finite(radius) or radius <= EPSILON then return nil end
	local start_angle = math.atan2(p0.y - center.y, p0.x - center.x)
	local end_angle = math.atan2(p1.y - center.y, p1.x - center.x)
	local radial = { x = (p0.x - center.x) / radius, y = (p0.y - center.y) / radius }
	local ccw_tangent = { x = -radial.y, y = radial.x }
	local sign = dot(ccw_tangent, tangent) >= 0 and 1 or -1
	local sweep = signed_angle_delta(start_angle, end_angle, sign)
	if math.abs(sweep) <= EPSILON or math.abs(sweep) >= TWO_PI - EPSILON then return nil end
	return { center = center, radius = radius, theta_start = start_angle, sweep = sweep }
end

local function fit_biarc(segment)
	local p0, p1 = segment.p0, segment.p1
	local t0d, t1d = cubic_derivative(segment, 0), cubic_derivative(segment, 1)
	local t0 = normalize(t0d.x, t0d.y)
	local t1 = normalize(t1d.x, t1d.y)
	if not t0 or not t1 then return nil end
	local v = { x = p1.x - p0.x, y = p1.y - p0.y }
	local a = 2 * (1 - dot(t0, t1))
	local b = 2 * dot(v, { x = t0.x + t1.x, y = t0.y + t1.y })
	local c = -dot(v, v)
	local d
	if math.abs(a) <= 1e-12 then
		if math.abs(b) <= 1e-12 then return nil end
		d = -c / b
	else
		local discriminant = b * b - 4 * a * c
		if discriminant < 0 then return nil end
		local root = math.sqrt(math.max(0, discriminant))
		local d1, d2 = (-b + root) / (2 * a), (-b - root) / (2 * a)
		d = d1 > EPSILON and d1 or d2
	end
	if not finite(d) or d <= EPSILON then return nil end
	local join = {
		x = (p0.x + p1.x + d * (t0.x - t1.x)) * 0.5,
		y = (p0.y + p1.y + d * (t0.y - t1.y)) * 0.5,
	}
	local first = arc_from_start_tangent(p0, join, t0)
	local reverse = arc_from_start_tangent(p1, join, { x = -t1.x, y = -t1.y })
	if not first or not reverse then return nil end
	local second = {
		center = reverse.center,
		radius = reverse.radius,
		theta_start = reverse.theta_start + reverse.sweep,
		sweep = -reverse.sweep,
	}
	local join_tangent_a, join_tangent_b = arc_tangent(first, true), arc_tangent(second, false)
	if dot(join_tangent_a, join_tangent_b) < 1 - 1e-6 then return nil end
	return first, second
end

local function arc_position(arc, t)
	local theta = arc.theta_start + arc.sweep * t
	return { x = arc.center.x + arc.radius * math.cos(theta),
		y = arc.center.y + arc.radius * math.sin(theta) }
end

local function biarc_error_bound(segment, first, second)
	local edge0 = point_distance(segment.p0, segment.c1)
	local edge1 = point_distance(segment.c1, segment.c2)
	local edge2 = point_distance(segment.c2, segment.p1)
	local cubic_speed_bound = 3 * math.max(edge0, edge1, edge2)
	local worst_bound = 0
	for half = 0, 1 do
		local arc = half == 0 and first or second
		local max_derivative = cubic_speed_bound + 2 * arc.radius * math.abs(arc.sweep)
		local sampled = 0
		for i = 0, BIARC_ERROR_SAMPLES do
			local local_t = i / BIARC_ERROR_SAMPLES
			local cubic_t = (half + local_t) * 0.5
			sampled = math.max(sampled,
				point_distance(cubic_position(segment, cubic_t), arc_position(arc, local_t)))
		end
		-- Each half has equal intervals in the cubic's [0,1] parameter.
		-- |C-A| is Lipschitz with this derivative bound, so every unsampled
		-- point is within M*h/2 of its nearest sample.
		worst_bound = math.max(worst_bound,
			sampled + max_derivative / (4 * BIARC_ERROR_SAMPLES))
	end
	return worst_bound
end

local function approximate_cubic(segment, tolerance, thickness, depth, output)
	local first, second = fit_biarc(segment)
	if first and second and first.radius > thickness * 0.5 + EPSILON
		and second.radius > thickness * 0.5 + EPSILON
		and biarc_error_bound(segment, first, second) <= tolerance then
		output[#output + 1] = first
		output[#output + 1] = second
		return
	end
	if depth >= MAX_BIARC_DEPTH then
		fail("cubic cannot be represented by annular biarcs within tolerance " .. tolerance, 2)
	end
	local left = cubic_range(segment, 0, 0.5)
	local right = cubic_range(segment, 0.5, 1)
	approximate_cubic(left, tolerance, thickness, depth + 1, output)
	approximate_cubic(right, tolerance, thickness, depth + 1, output)
end

local function append_annular(pegs, arc, thickness, theta0, sweep, peg_type)
	local r_in, r_out = arc.radius - thickness * 0.5, arc.radius + thickness * 0.5
	if r_in <= 0 then fail("annular inner radius must be positive", 2) end
	local start_angle, end_angle
	if sweep > 0 then
		start_angle, end_angle = theta0, theta0 + sweep
	else
		-- Peg.new_annular stores a positive angular sector. Reversing the
		-- endpoints preserves the body while generation order follows the path.
		start_angle, end_angle = theta0 + sweep, theta0
	end
	pegs[#pegs + 1] = Peg.new_annular(arc.center.x, arc.center.y, peg_type,
		r_in, r_out, start_angle, end_angle)
end

local function emit_arc_covered(pegs, arc, thickness, max_length, peg_type)
	local length = arc.radius * math.abs(arc.sweep)
	local count = math.max(1, math.ceil(length / max_length - EPSILON))
	local sweep = arc.sweep / count
	for i = 0, count - 1 do
		append_annular(pegs, arc, thickness, arc.theta_start + sweep * i, sweep, peg_type)
	end
end

local function exact_arc_path(path)
	local first = path.segments[1]
	if not first or first.kind ~= "arc" then return nil end
	local sweep = 0
	local sign = first.sweep > 0 and 1 or -1
	for _, segment in ipairs(path.segments) do
		if segment.kind ~= "arc"
			or point_distance(segment.center, first.center) > EPSILON
			or math.abs(segment.radius - first.radius) > EPSILON
			or segment.sweep * sign <= 0 then
			return nil
		end
		sweep = sweep + segment.sweep
	end
	if math.abs(sweep) > TWO_PI + EPSILON then return nil end
	return {
		kind = "arc", center = first.center, radius = first.radius,
		theta_start = first.theta_start, sweep = sweep,
		length = first.radius * math.abs(sweep),
	}
end

local function collinear_line_path(path)
	local first = path.segments[1]
	if not first or first.kind ~= "line" or path.closed then return false end
	local direction = normalize(first.p1.x - first.p0.x, first.p1.y - first.p0.y)
	for _, segment in ipairs(path.segments) do
		if segment.kind ~= "line" then return false end
		local current = normalize(segment.p1.x - segment.p0.x, segment.p1.y - segment.p0.y)
		if not current or dot(direction, current) < 1 - 1e-9 then return false end
	end
	return true
end

local function emit_rectangles(path, peg_spec, gap, pegs)
	if not collinear_line_path(path) then
		fail("rectangle pegs require an open straight/collinear path", 2)
	end
	local width = positive(peg_spec.width, "peg.width")
	local height = positive(peg_spec.height, "peg.height")
	local length = path:length()
	local count, actual_width, margin
	if gap == 0 then
		count = math.max(1, math.ceil(length / width - EPSILON))
		actual_width = length / count
		margin = 0
	else
		count = math.floor((length + gap + EPSILON) / (width + gap))
		if count < 1 then fail("path is shorter than one rectangle peg", 2) end
		actual_width = width
		margin = (length - count * width - (count - 1) * gap) * 0.5
	end
	for i = 1, count do
		local s = margin + actual_width * 0.5 + (i - 1) * (actual_width + gap)
		local p, tangent = point_at(path, s)
		pegs[#pegs + 1] = Peg.new_rectangle(p.x, p.y, peg_spec.type,
			actual_width, height, math.atan2(tangent.y, tangent.x))
	end
end

local function advance_chord(path, start_s, target)
	local length = path:length()
	local start = point_at(path, start_s)
	local step = math.max(length / 8192, target / 16)
	local previous_s = start_s
	local s = math.min(length, start_s + step)
	while s <= length + EPSILON do
		local p = point_at(path, s)
		if point_distance(start, p) >= target then
			local low, high = previous_s, s
			for _ = 1, 52 do
				local middle = (low + high) * 0.5
				if point_distance(start, point_at(path, middle)) < target then low = middle else high = middle end
			end
			return (low + high) * 0.5
		end
		if s >= length then break end
		previous_s = s
		s = math.min(length, s + step)
	end
	return nil
end

local function place_open_circles(path, radius, gap)
	local length, target = path:length(), radius * 2 + gap
	if length + EPSILON < radius * 2 then fail("path is shorter than one circle diameter", 2) end
	local count = math.max(1, math.floor((length - radius * 2 + EPSILON) / target) + 1)
	local function positions_for(margin, n)
		local positions = { radius + margin }
		for i = 2, n do
			local next_s = advance_chord(path, positions[i - 1], target)
			if not next_s then return nil end
			positions[i] = next_s
		end
		return positions
	end
	local positions
	while count >= 1 do
		positions = positions_for(0, count)
		if positions and positions[#positions] + radius <= length + EPSILON then break end
		count = count - 1
	end
	if count == 1 then return { length * 0.5 } end
	local low, high = 0, math.max(0, (length - radius * 2) * 0.5)
	for _ = 1, 52 do
		local middle = (low + high) * 0.5
		local candidate = positions_for(middle, count)
		local residual = candidate and (length - (candidate[#candidate] + radius + middle)) or -1
		if residual >= 0 then low, positions = middle, candidate else high = middle end
	end
	return positions
end

local function emit_closed_circles(path, arc, radius, gap, pegs, peg_type)
	if not arc or math.abs(math.abs(arc.sweep) - TWO_PI) > EPSILON then
		local target = radius * 2 + gap
		local maximum = math.floor(path:length() / target + EPSILON)
		for count = maximum, 2, -1 do
			local candidate = {}
			for i = 0, count - 1 do
				local p = point_at(path, path:length() * i / count)
				candidate[#candidate + 1] = Peg.new(p.x, p.y, peg_type, radius)
			end
			local fits = true
			for i = 1, count do
				local clearance = point_distance(candidate[i], candidate[i % count + 1]) - radius * 2
				if clearance < gap - OVERLAP_EPSILON
					or (gap == 0 and math.abs(clearance) > OVERLAP_EPSILON) then
					fits = false
					break
				end
			end
			if fits then
				for i = 1, count do
					for j = i + 1, count do
						local adjacent = j == i + 1 or (i == 1 and j == count)
						if not adjacent and point_distance(candidate[i], candidate[j])
							< radius * 2 - OVERLAP_EPSILON then
							fits = false
							break
						end
					end
					if not fits then break end
				end
			end
			if fits then
				for _, peg in ipairs(candidate) do pegs[#pegs + 1] = peg end
				return
			end
		end
		fail("circle pegs cannot satisfy the requested clearance on this closed path", 2)
	end
	local target = radius * 2 + gap
	if target > arc.radius * 2 + EPSILON then fail("circle peg and gap do not fit the circumference", 2) end
	local minimum_angle = 2 * math.asin(math.min(1, target / (2 * arc.radius)))
	local count = math.floor(TWO_PI / minimum_angle + EPSILON)
	if count < 2 then fail("at least two circle pegs are required on a closed path", 2) end
	local step = arc.sweep / count
	local actual_clearance = 2 * arc.radius * math.sin(math.abs(step) * 0.5) - radius * 2
	if gap == 0 and math.abs(actual_clearance) > OVERLAP_EPSILON then
		fail("rigid circle pegs cannot exactly cover this closed path with gap=0", 2)
	end
	for i = 0, count - 1 do
		local theta = arc.theta_start + step * i
		pegs[#pegs + 1] = Peg.new(arc.center.x + arc.radius * math.cos(theta),
			arc.center.y + arc.radius * math.sin(theta), peg_type, radius)
	end
end

-- Circle pegs with gap == 0 are supported only on open straight/collinear
-- paths. A chain of rigid circles cannot cover a curved path gaplessly:
-- placing each circle tangent to the next along the arc forces either
-- positive boundary gaps or overlaps between neighbors, and silent overlaps
-- are forbidden. Curved paths therefore require gap > 0, and this function
-- fails explicitly with "complete curved-path coverage" otherwise.
local function emit_circles(path, peg_spec, gap, pegs)
	local radius = positive(peg_spec.radius, "peg.radius")
	if path.closed then
		if gap == 0 and not collinear_line_path(path) then
			fail("rigid circle pegs cannot guarantee complete curved-path coverage with gap=0", 2)
		end
		emit_closed_circles(path, exact_arc_path(path), radius, gap, pegs, peg_spec.type)
		return
	end
	if gap == 0 then
		if not collinear_line_path(path) then
			fail("rigid circle pegs cannot guarantee complete curved-path coverage with gap=0", 2)
		end
		local count = math.max(1, math.ceil(path:length() / (radius * 2) - EPSILON))
		local first_s = (path:length() - (count - 1) * radius * 2) * 0.5
		for i = 0, count - 1 do
			local p = point_at(path, first_s + i * radius * 2)
			pegs[#pegs + 1] = Peg.new(p.x, p.y, peg_spec.type, radius)
		end
		return
	end
	for _, s in ipairs(place_open_circles(path, radius, gap)) do
		local p = point_at(path, s)
		pegs[#pegs + 1] = Peg.new(p.x, p.y, peg_spec.type, radius)
	end
end

local function emit_exact_annular(path, arc, peg_spec, gap, pegs)
	local thickness = positive(peg_spec.thickness, "peg.thickness")
	local max_length = positive(peg_spec.max_length, "peg.max_length")
	local r_in = arc.radius - thickness * 0.5
	if r_in <= 0 then fail("annular inner radius must be positive", 2) end
	local magnitude = math.abs(arc.sweep)
	local direction = arc.sweep >= 0 and 1 or -1
	local piece_angle = math.min(magnitude, max_length / arc.radius)
	if gap == 0 then
		local count = math.max(1, math.ceil(magnitude / piece_angle - EPSILON))
		local sweep = arc.sweep / count
		for i = 0, count - 1 do
			append_annular(pegs, arc, thickness, arc.theta_start + sweep * i, sweep, peg_spec.type)
		end
		return
	end
	if gap > 2 * r_in + EPSILON then fail("requested gap is impossible at the annular inner radius", 2) end
	local minimum_gap_angle = 2 * math.asin(math.min(1, gap / (2 * r_in)))
	if path.closed then
		if math.abs(magnitude - TWO_PI) > EPSILON then fail("closed annular path must be a full circle", 2) end
		local count = math.floor(magnitude / (piece_angle + minimum_gap_angle) + EPSILON)
		if count < 1 then fail("annular peg and gap do not fit the closed path", 2) end
		local gap_angle = (magnitude - count * piece_angle) / count
		for i = 0, count - 1 do
			local theta = arc.theta_start + direction * i * (piece_angle + gap_angle)
			append_annular(pegs, arc, thickness, theta, direction * piece_angle, peg_spec.type)
		end
	else
		local count = math.floor((magnitude + minimum_gap_angle + EPSILON)
			/ (piece_angle + minimum_gap_angle))
		if count < 1 then count, piece_angle = 1, magnitude end
		local used = count * piece_angle + (count - 1) * minimum_gap_angle
		local margin = (magnitude - used) * 0.5
		for i = 0, count - 1 do
			local theta = arc.theta_start + direction * (margin + i * (piece_angle + minimum_gap_angle))
			append_annular(pegs, arc, thickness, theta, direction * piece_angle, peg_spec.type)
		end
	end
end

local function emit_biarc_annular(path, peg_spec, gap, tolerance, pegs)
	if gap ~= 0 then fail("annular pegs on cubic/spiral paths currently require gap=0", 2) end
	local thickness = positive(peg_spec.thickness, "peg.thickness")
	local max_length = positive(peg_spec.max_length, "peg.max_length")
	local source_error = path.approximation_error_bound or 0
	local biarc_tolerance = tolerance - source_error
	if biarc_tolerance <= 0 then
		fail("curve_tolerance is already exhausted by the source path approximation", 2)
	end
	local joins_ok, join_issue = path:validate_joins()
	if not joins_ok then
		if join_issue.kind == "position" then
			fail("annular curve is position-discontinuous at segments "
				.. join_issue.from_segment .. " and " .. join_issue.to_segment, 2)
		end
		fail("annular curve has a tangent discontinuity at segments "
			.. join_issue.from_segment .. " and " .. join_issue.to_segment
			.. (join_issue.seam and " (closing seam)" or ""), 2)
	end
	local arcs = {}
	for _, segment in ipairs(path.segments) do
		if segment.kind == "arc" then
			arcs[#arcs + 1] = {
				center = segment.center, radius = segment.radius,
				theta_start = segment.theta_start, sweep = segment.sweep,
			}
		elseif segment.kind == "cubic" then
			approximate_cubic(segment, biarc_tolerance, thickness, 0, arcs)
		else
			fail("annular curves cannot contain straight segments", 2)
		end
	end
	for _, arc in ipairs(arcs) do emit_arc_covered(pegs, arc, thickness, max_length, peg_spec.type) end
end

-- Conservative bounding disk for a generated peg. Used only to skip pairs
-- that are provably separated before the exact polygon overlap check; the
-- disk is not a collision shape. Annular pegs use their emitted polygon
-- (centered on the actual piece), not r_out around the arc center, so
-- same-arc and neighboring pieces stay candidates.
local function peg_bounds(peg)
	local polygon = peg.polygon
	if polygon and #polygon >= 2 then
		local count = #polygon / 2
		local sum_x, sum_y = 0, 0
		for i = 1, count do
			sum_x = sum_x + polygon[(i - 1) * 2 + 1]
			sum_y = sum_y + polygon[(i - 1) * 2 + 2]
		end
		local cx, cy = sum_x / count, sum_y / count
		local max_d2 = 0
		for i = 1, count do
			local dx = polygon[(i - 1) * 2 + 1] - cx
			local dy = polygon[(i - 1) * 2 + 2] - cy
			local d2 = dx * dx + dy * dy
			if d2 > max_d2 then max_d2 = d2 end
		end
		return { x = cx, y = cy, radius = math.sqrt(max_d2) }
	end
	local radius = peg.radius
	if peg.shape == "rectangle" then
		radius = math.sqrt((peg.width / 2) ^ 2 + (peg.height / 2) ^ 2)
	end
	return { x = peg.x, y = peg.y, radius = radius or 0 }
end

local function validate_overlaps(pegs, closed)
	local bounds = {}
	for i = 1, #pegs do bounds[i] = peg_bounds(pegs[i]) end
	for i = 1, #pegs do
		local bound_i = bounds[i]
		for j = i + 1, #pegs do
			local bound_j = bounds[j]
			local dx, dy = bound_j.x - bound_i.x, bound_j.y - bound_i.y
			local reach = bound_i.radius + bound_j.radius + OVERLAP_EPSILON
			-- Bounds that do not intersect cannot contain overlapping shapes, so
			-- only candidate pairs reach the exact polygon detector.
			if dx * dx + dy * dy <= reach * reach then
				local adjacent = j == i + 1 or (closed and i == 1 and j == #pegs)
				local overlap = OverlapDetector.check_overlap(pegs[i], pegs[j])
				if overlap > OVERLAP_EPSILON then
					local relation = adjacent and "neighbor" or "non-neighbor"
					fail("generated " .. relation .. " pegs " .. i .. " and " .. j .. " overlap", 2)
				end
			end
		end
	end
end

local function cap_contact_error(a, a_cap, b, b_cap)
	local a1, a2 = a.corners[a_cap * 2 + 1], a.corners[a_cap * 2 + 2]
	local b1, b2 = b.corners[b_cap * 2 + 1], b.corners[b_cap * 2 + 2]
	-- Inflections reverse the inner/outer endpoint pairing, not entry/exit.
	return math.min(
		math.max(point_distance(a1, b1), point_distance(a2, b2)),
		math.max(point_distance(a1, b2), point_distance(a2, b1)))
end

-- Recover traversal from ordered geometry without persistent metadata. Each
-- piece must leave by the cap opposite its entry. Keep both possible entries
-- at each step so even numerically coincident caps cannot cause a greedy
-- choice to hide a valid traversal. Minimize the worst join error.
local function validate_contacts(pegs, closed, report)
	local count = #pegs
	local best, worst_join = math.huge, 1
	for first_entry = 0, 1 do
		local errors = { [first_entry] = 0 }
		local worst = { [first_entry] = 1 }
		for i = 2, count do
			local next_errors, next_worst = {}, {}
			for entry = 0, 1 do
				for previous = 0, 1 do
					if errors[previous] then
						local gap = cap_contact_error(pegs[i - 1], 1 - previous, pegs[i], entry)
						local error = math.max(errors[previous], gap)
						if not next_errors[entry] or error < next_errors[entry] then
							next_errors[entry] = error
							next_worst[entry] = gap > errors[previous] and i - 1 or worst[previous]
						end
					end
				end
			end
			errors, worst = next_errors, next_worst
		end
		for entry = 0, 1 do
			if errors[entry] then
				local error, index = errors[entry], worst[entry]
				if closed then
					local gap = cap_contact_error(pegs[count], 1 - entry, pegs[1], first_entry)
					if gap > error then error, index = gap, count end
				end
				if error < best then best, worst_join = error, index end
			end
		end
	end
	if best > CONTACT_TOLERANCE then
		report(worst_join, worst_join % count + 1, closed and worst_join == count, best)
	end
end

local function line_metadata(id, index, count, closed, gap)
	-- LuaJIT's Lua 5.1 pairs() ignores __pairs, so a proxy-style frozen table
	-- would silently disappear from generic copies and serializers. Keep the
	-- read-only authoring contract explicit while retaining concrete enumerable
	-- fields for level cloning and the phase-3 snapshot/replay work.
	return { id = id, index = index, count = count, closed = closed, gap = gap }
end

function Lines.generate(spec)
	if type(spec) ~= "table" then fail("spec must be a table", 2) end
	if type(spec.id) ~= "string" or spec.id == "" then fail("id must be a non-empty string", 2) end
	if not Path.is_path(spec.path) then fail("path must be created by Path.new", 2) end
	if type(spec.peg) ~= "table" then fail("peg must be a table", 2) end
	local gap = nonnegative(spec.gap or 0, "gap")
	local tolerance = positive(spec.curve_tolerance or 0.25, "curve_tolerance")
	local pegs = {}
	if spec.peg.kind == "circle" then
		emit_circles(spec.path, spec.peg, gap, pegs)
	elseif spec.peg.kind == "rectangle" then
		emit_rectangles(spec.path, spec.peg, gap, pegs)
	elseif spec.peg.kind == "annular" then
		local arc = exact_arc_path(spec.path)
		if arc then emit_exact_annular(spec.path, arc, spec.peg, gap, pegs)
		else emit_biarc_annular(spec.path, spec.peg, gap, tolerance, pegs) end
	else
		fail("unsupported peg kind " .. tostring(spec.peg.kind), 2)
	end
	if #pegs == 0 then fail("generation produced no pegs", 2) end
	validate_overlaps(pegs, spec.path.closed)
	if spec.peg.kind == "annular" and gap == 0 then
		validate_contacts(pegs, spec.path.closed, function(i, j, seam, cap_gap)
			fail(string.format(
				"generated %s pegs %d and %d have a cap gap of %.6f px (tolerance %.6f)",
				seam and "closing seam" or "neighbor", i, j, cap_gap, CONTACT_TOLERANCE), 2)
		end)
	end
	for index, peg in ipairs(pegs) do
		peg.line = line_metadata(spec.id, index, #pegs, spec.path.closed, gap)
	end
	return pegs
end

-- ===========================================================================
-- Level-wide line validation (phase 3)
-- ===========================================================================

local function is_positive_integer(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
		and value >= 1 and value == math.floor(value)
end

local function collinear_aligned(centers, angles)
	-- Rectangle lines must lie on one straight axis with one common tangent
	-- direction. Checking only that each consecutive delta is parallel to its
	-- own local angle would accept an L-shaped sequence, so instead take the
	-- first angle as the reference, require every angle (including the final
	-- member's) to match it, and require every center delta to advance along
	-- that shared direction.
	local reference = angles[1] or 0
	local ux, uy = math.cos(reference), math.sin(reference)
	for i = 1, #centers do
		local angle = angles[i] or 0
		local ax, ay = math.cos(angle), math.sin(angle)
		if ux * ax + uy * ay < 1 - 1e-6 then return false end
	end
	for i = 1, #centers - 1 do
		local dx = centers[i + 1].x - centers[i].x
		local dy = centers[i + 1].y - centers[i].y
		local length = math.sqrt(dx * dx + dy * dy)
		if length > EPSILON
			and math.abs(dx * uy - dy * ux) > 0.001 * length then
			return false
		end
	end
	return true
end

-- Validate the line metadata carried by a complete level peg array. Runs at
-- load time after Lines.generate produced the arrays; like MotionSchema it
-- hard-fails on the first violation:
--   * malformed metadata (id/index/count/closed/gap field types and ranges),
--   * duplicate or empty line ids,
--   * non-contiguous line indices (generation order not preserved),
--   * line groups whose declared count does not match the level's members,
--   * inconsistent metadata within one line group (count/closed/gap/shape),
--   * unsupported shape/path authoring recoverable from emitted geometry
--     (rectangle lines must stay straight and tangent-aligned; positive-gap
--     annular lines must stay co-circular; inner radii must stay positive),
--   * same-line overlap beyond OVERLAP_EPSILON for any pair; only exact
--     zero-gap neighbor contact (including the closed seam) is tolerated.
--
-- Peg arrays without line metadata validate trivially.
function Lines.validate(pegs)
	if type(pegs) ~= "table" then fail("pegs must be a table", 2) end
	local group_order = {}
	local groups = {}
	local previous_index = {}
	for position, peg in ipairs(pegs) do
		local line = peg.line
		if line ~= nil then
			if type(line) ~= "table" then
				fail("peg " .. position .. " line metadata must be a table", 2)
			end
			if type(line.id) ~= "string" or line.id == "" then
				fail("peg " .. position .. " line.id must be a non-empty string", 2)
			end
			if not is_positive_integer(line.index) then
				fail("peg " .. position .. " line.index must be a positive integer, got "
					.. tostring(line.index), 2)
			end
			if not is_positive_integer(line.count) then
				fail("peg " .. position .. " line.count must be a positive integer, got "
					.. tostring(line.count), 2)
			end
			if line.index > line.count then
				fail("peg " .. position .. " line.index " .. line.index
					.. " exceeds the declared count " .. line.count, 2)
			end
			if type(line.closed) ~= "boolean" then
				fail("peg " .. position .. " line.closed must be a boolean", 2)
			end
			if not finite(line.gap) or line.gap < 0 then
				fail("peg " .. position .. " line.gap must be a non-negative finite number", 2)
			end
			local id = line.id
			local group = groups[id]
			if not group then
				group = {
					count = line.count,
					closed = line.closed,
					gap = line.gap,
					shape = peg.shape or "circle",
					pegs = {},
				}
				groups[id] = group
				table.insert(group_order, id)
			else
				if line.count ~= group.count then
					fail("line " .. id .. " has inconsistent counts ("
						.. group.count .. " and " .. line.count .. ")", 2)
				end
				if line.closed ~= group.closed then
					fail("line " .. id .. " has inconsistent closed metadata", 2)
				end
				if line.gap ~= group.gap then
					fail("line " .. id .. " has inconsistent gap metadata", 2)
				end
				local shape = peg.shape or "circle"
				if shape ~= group.shape then
					fail("line " .. id .. " mixes peg shapes ("
						.. group.shape .. " and " .. shape .. ")", 2)
				end
			end
			local previous = previous_index[id]
			if previous and line.index ~= previous + 1 then
				fail("line " .. id .. " indices are not contiguous in peg order"
					.. " (expected index " .. (previous + 1)
					.. " after " .. previous .. ")", 2)
			end
			previous_index[id] = line.index
			if group.pegs[line.index] then
				fail("line " .. id .. " repeats index " .. line.index, 2)
			end
			group.pegs[line.index] = peg
		end
	end

	for _, id in ipairs(group_order) do
		local group = groups[id]
		local ordered = {}
		local present = 0
		for index, peg in pairs(group.pegs) do
			present = present + 1
			ordered[index] = peg
		end
		if present ~= group.count then
			fail("line " .. id .. " declares " .. group.count
				.. " pegs but the level holds " .. present, 2)
		end
		for i = 1, group.count do
			if not ordered[i] then
				fail("line " .. id .. " is missing index " .. i, 2)
			end
		end

		-- Geometry checks recoverable from the emitted pegs (the authored
		-- path itself is not retained in level data).
		if group.shape == "rectangle" then
			local centers, angles = {}, {}
			for i = 1, group.count do
				centers[i] = ordered[i]
				angles[i] = ordered[i].angle or 0
			end
			if not collinear_aligned(centers, angles) then
				fail("line " .. id .. " rectangles are not collinear"
					.. " and tangent-aligned (straight path required)", 2)
			end
		elseif group.shape == "annular" then
			for i = 1, group.count do
				local peg = ordered[i]
				if not (peg.r_in and peg.r_out)
					or peg.r_in <= 0 or peg.r_out <= peg.r_in then
					fail("line " .. id .. " annular peg " .. i
						.. " has invalid radii (need 0 < r_in < r_out)", 2)
				end
			end
			if group.gap > 0 then
				-- Positive gaps are supported only on exact co-circular arcs.
				local first = ordered[1]
				for i = 2, group.count do
					local peg = ordered[i]
					local dx = peg.x - first.x
					local dy = peg.y - first.y
					if math.abs(dx) > 0.001 or math.abs(dy) > 0.001
						or math.abs(peg.r_in - first.r_in) > 0.001
						or math.abs(peg.r_out - first.r_out) > 0.001 then
						fail("line " .. id .. " positive-gap annular pegs are not"
							.. " co-circular (exact circular arc required)", 2)
					end
				end
			else
				-- Zero-gap annular neighbors must share a full cap, including
				-- the closing seam. This catches curved annular lines whose
				-- emitted pieces separated without overlapping after cloning,
				-- snapshot restoration, or manual editing.
				for i = 1, group.count do
					if type(ordered[i].corners) ~= "table" then
						fail("line " .. id .. " annular peg " .. i
							.. " has no emitted cap geometry", 2)
					end
				end
				validate_contacts(ordered, group.closed, function(i, j, seam, cap_gap)
					fail(string.format(
						"line %s %s pegs %d and %d have a cap gap of %.6f px (tolerance %.6f)",
						id, seam and "closing seam" or "neighbor", i, j,
						cap_gap, CONTACT_TOLERANCE), 2)
				end)
			end
		end

		-- Every same-line pair is checked, not just non-neighbors: positive
		-- gaps must remain gaps and zero-gap neighbors may share only their
		-- exact boundary. The sole tolerated case is contact within
		-- OVERLAP_EPSILON.
		for i = 1, group.count do
			for j = i + 1, group.count do
				local adjacent = j == i + 1
					or (group.closed and i == 1 and j == group.count)
				local overlap = OverlapDetector.check_overlap(ordered[i], ordered[j])
				if overlap > OVERLAP_EPSILON then
					local relation = adjacent and "neighbor" or "non-neighbor"
					fail("line " .. id .. " " .. relation .. " pegs " .. i
						.. " and " .. j .. " overlap by "
						.. string.format("%.4f", overlap), 2)
				end
			end
		end
	end
end

-- True only when the two pegs are zero-gap neighbors on the same generated
-- line: the exact boundary contact the level checker treats as intentional
-- authoring rather than an overlap warning.
function Lines.is_intentional_contact(a, b)
	local la, lb = a and a.line or nil, b and b.line or nil
	if type(la) ~= "table" or type(lb) ~= "table" then return false end
	if la.id ~= lb.id or la.gap ~= 0 or lb.gap ~= 0 then return false end
	if la.index == lb.index then return false end
	if math.abs(la.index - lb.index) == 1 then return true end
	if la.closed and lb.closed and la.count == lb.count then
		local count = la.count
		if count >= 2
			and ((la.index == 1 and lb.index == count)
				or (lb.index == 1 and la.index == count)) then
			return true
		end
	end
	return false
end

Lines.EPSILON = EPSILON
Lines.OVERLAP_EPSILON = OVERLAP_EPSILON
Lines.CONTACT_TOLERANCE = CONTACT_TOLERANCE

return Lines
