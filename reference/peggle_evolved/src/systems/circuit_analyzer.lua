-- CircuitAnalyzer: static-vs-moving and moving-vs-moving overlap checks.
--
-- Coordinates:
--   * Relative primitives (ellipse, oscillate_*, line, rotate) evaluate to
--     offsets; their sampling positions add the peg base.
--   * Absolute primitives (kind "path") evaluate to world-space positions;
--     their envelopes and sampled positions never add a peg base.
--     CircuitPrimitives.is_absolute is the single classification point.
--
-- Time:
--   * motion_argument = phase + elapsed * speed, including move/pause state
--     semantics (a paused interval does not advance the argument).
--   * A moving path's traversal horizon is path:length() / speed, scaled by
--     the move/pause duty cycle. Zero-speed paths have no finite traversal
--     period and are checked at their fixed initial phases.
--   * Different circuits do not necessarily share a finite common period, so
--     the analyzer samples a finite horizon (returned in the diagnostics
--     table) rather than implying exhaustive coverage.
--
-- Same-path pairs:
--   * Every peg on one path circuit advances by the same distance at any
--     instant, so pairwise separation depends only on the common advance.
--     A dense arc-length sweep detects pairs that start apart but overlap
--     later in the cycle. Pairs on other circuits keep their existing
--     initial-phase check.

local OverlapDetector = require("src.systems.overlap_detector")
local Peg = require("src.entities.peg")
local Circuits = require("src.systems.circuits")
local CircuitPrimitives = require("src.systems.circuit_primitives")

local CircuitAnalyzer = {}

local DEFAULT_HORIZON = math.pi * 2
local STEADY_SAMPLES = 200
local DYNAMIC_SAMPLES_PER_SECOND = 8
local MIN_COARSE_STEPS = 16
local MAX_COARSE_STEPS = 512
local MIN_PATH_SAMPLES = 64
local MAX_PATH_SAMPLES = 4096
local PATH_SAMPLE_STEP = 8

-- Conservative world-space envelope of a compiled path. Cubic control points
-- and arc cardinal points bound every sampled point, so no part of the loop
-- can fall outside the returned box.
local function path_envelope(path)
	local min_x, max_x = math.huge, -math.huge
	local min_y, max_y = math.huge, -math.huge
	local function add(x, y)
		if x < min_x then min_x = x end
		if x > max_x then max_x = x end
		if y < min_y then min_y = y end
		if y > max_y then max_y = y end
	end
	for _, segment in ipairs(path.segments) do
		add(segment.p0.x, segment.p0.y)
		add(segment.p1.x, segment.p1.y)
		if segment.kind == "cubic" then
			add(segment.c1.x, segment.c1.y)
			add(segment.c2.x, segment.c2.y)
		elseif segment.kind == "arc" then
			add(segment.center.x + segment.radius, segment.center.y)
			add(segment.center.x - segment.radius, segment.center.y)
			add(segment.center.x, segment.center.y + segment.radius)
			add(segment.center.x, segment.center.y - segment.radius)
		end
	end
	return {
		min_dx = min_x, max_dx = max_x,
		min_dy = min_y, max_dy = max_y,
		absolute = true,
	}
end

-- Sample the circuit's motion envelope.
function CircuitAnalyzer.characterize_circuit(circuit_id, circuit)
	if CircuitPrimitives.is_absolute(circuit) then
		return path_envelope(circuit.path)
	end

	local min_dx, max_dx = math.huge, -math.huge
	local min_dy, max_dy = math.huge, -math.huge

	-- Sample 200 points over [0, 2*pi] (relative primitive argument range).
	local steps = STEADY_SAMPLES
	for i = 0, steps do
		local t = (i / steps) * (math.pi * 2)
		local dx, dy, da
		if circuit.path_fn then
			dx, dy, da = circuit.path_fn(t)
		else
			dx, dy, da = CircuitPrimitives.eval(circuit, t)
		end
		dx = dx or 0
		dy = dy or 0
		if dx < min_dx then min_dx = dx end
		if dx > max_dx then max_dx = dx end
		if dy < min_dy then min_dy = dy end
		if dy > max_dy then max_dy = dy end
	end

	return {
		min_dx = min_dx, max_dx = max_dx,
		min_dy = min_dy, max_dy = max_dy,
		absolute = false,
	}
end

local function circuit_speed(circuit)
	if circuit.speed ~= nil then return circuit.speed end
	if CircuitPrimitives.is_absolute(circuit) then return 0 end
	return 1
end

-- The primitive argument after `elapsed` seconds of motion, matching
-- Circuits.advance_motion for a state that starts "moving" with timer 0.
-- A paused portion of a cycle contributes no advance.
function CircuitAnalyzer.motion_argument(circuit, phase, elapsed)
	local speed = circuit_speed(circuit)
	local duration = circuit.duration_time or 0
	if duration > 0 then
		local pause = circuit.pause_time or 0
		local cycle = duration + pause
		local cycles = math.floor(elapsed / cycle)
		local remainder = elapsed - cycles * cycle
		local moving = remainder < duration and remainder or duration
		return phase + speed * (cycles * duration + moving)
	end
	return phase + speed * elapsed
end

-- Wall-clock seconds needed to advance one full closed-path loop, including
-- move/pause cycles. Returns nil for non-path circuits and zero-speed paths
-- (a stationary path has no finite traversal period).
function CircuitAnalyzer.period(circuit)
	if not CircuitPrimitives.is_absolute(circuit) then return nil end
	local speed = circuit_speed(circuit)
	if speed <= 0 then return nil end
	local moving_time = circuit.path:length() / speed
	local duration = circuit.duration_time or 0
	if duration > 0 then
		moving_time = moving_time * (duration + (circuit.pause_time or 0)) / duration
	end
	return moving_time
end

-- Earliest wall-clock time reaching a nonnegative advance. At a held boundary
-- this selects the start of the pause, not the start of the next moving cycle.
-- Stationary circuits return the analysis sentinel 0, not a traversal time.
function CircuitAnalyzer.elapsed_for_advance(circuit, advance)
	local speed = circuit_speed(circuit)
	if speed <= 0 then return 0 end
	local duration = circuit.duration_time or 0
	local moving_time = advance / speed
	if duration > 0 then
		local pause = circuit.pause_time or 0
		local cycles = math.max(0, math.ceil(moving_time / duration) - 1)
		local remainder = moving_time - cycles * duration
		return cycles * (duration + pause) + remainder
	end
	return moving_time
end

local function clamp(val, min, max)
	if val < min then return min end
	if val > max then return max end
	return val
end

-- A peg's envelope origin: absolute envelopes are already world coordinates.
local function envelope_origin(envelope, peg)
	if envelope.absolute then return 0, 0 end
	return peg.base_x, peg.base_y
end

-- Fast envelope check for static vs dynamic
local function envelope_overlap_static(static_peg, circ_peg, envelope)
	local br_s = OverlapDetector.get_bounding_radius(static_peg)
	local br_c = OverlapDetector.get_bounding_radius(circ_peg)

	local sx, sy = static_peg.x, static_peg.y
	local ox, oy = envelope_origin(envelope, circ_peg)

	local closest_x = ox + clamp(sx - ox, envelope.min_dx, envelope.max_dx)
	local closest_y = oy + clamp(sy - oy, envelope.min_dy, envelope.max_dy)

	local dist_sq = (sx - closest_x)^2 + (sy - closest_y)^2
	local r_sum = br_s + br_c

	return dist_sq < r_sum * r_sum
end

-- Fast envelope check for dynamic vs dynamic
local function envelope_overlap_dynamic(peg1, env1, peg2, env2)
	local br1 = OverlapDetector.get_bounding_radius(peg1)
	local br2 = OverlapDetector.get_bounding_radius(peg2)

	local o1x, o1y = envelope_origin(env1, peg1)
	local o2x, o2y = envelope_origin(env2, peg2)

	local min1_x, max1_x = o1x + env1.min_dx, o1x + env1.max_dx
	local min1_y, max1_y = o1y + env1.min_dy, o1y + env1.max_dy

	local min2_x, max2_x = o2x + env2.min_dx, o2x + env2.max_dx
	local min2_y, max2_y = o2y + env2.min_dy, o2y + env2.max_dy

	-- Rect-rect overlap check for envelopes expanded by bounding radii
	local r_sum = br1 + br2
	if min1_x - r_sum > max2_x then return false end
	if max1_x + r_sum < min2_x then return false end
	if min1_y - r_sum > max2_y then return false end
	if max1_y + r_sum < min2_y then return false end

	return true
end

local function get_peg_at_time(base_peg, circuit, t)
	-- deep copy base peg conceptually, but we only need position & polygon transformed
	-- To avoid deep copy overhead, we create a temporary peg
	local p = {}
	for k, v in pairs(base_peg) do p[k] = v end
	-- Annular transforms mutate geometry buffers; samples must own them.
	if p.shape == "annular" then
		p.corners, p.polygon = {}, {}
		for i, corner in ipairs(base_peg.corners) do
			p.corners[i] = { x = corner.x, y = corner.y }
		end
		for i, value in ipairs(base_peg.polygon) do p.polygon[i] = value end
		p.normal_start = { x = base_peg.normal_start.x, y = base_peg.normal_start.y }
		p.normal_end = { x = base_peg.normal_end.x, y = base_peg.normal_end.y }
	end

	local dx, dy, da = Circuits.eval_transform(circuit, t)
	local new_x, new_y
	if CircuitPrimitives.is_absolute(circuit) then
		new_x, new_y = dx, dy
	else
		new_x, new_y = p.base_x + dx, p.base_y + dy
	end
	local new_angle = (p.base_angle or 0) + (da or 0)

	Peg.set_transform(p, new_x, new_y, new_angle)
	return p
end

-- Authoring-time accessors: a moving peg declares its circuit assignment and
-- initial path position in peg.motion.
local function peg_circuit_id(p)
	return p.motion and p.motion.circuit or nil
end

local function peg_phase(p)
	return p.motion and (p.motion.phase or 0) or 0
end

-- Hierarchical time-domain sampling
-- Returns true if overlap found, overlap amount, min_gap, time of overlap
function CircuitAnalyzer.check_dynamic_overlap(peg1, c1_def, peg2, c2_def, horizon)
	-- peg2 can be static if c2_def is nil
	horizon = horizon or DEFAULT_HORIZON

	local t_start = 0
	local t_end = horizon
	local coarse_steps = math.ceil(horizon * DYNAMIC_SAMPLES_PER_SECOND)
	if coarse_steps < MIN_COARSE_STEPS then coarse_steps = MIN_COARSE_STEPS end
	if coarse_steps > MAX_COARSE_STEPS then coarse_steps = MAX_COARSE_STEPS end

	local min_gap = math.huge
	local overlap_found = false
	local max_overlap = -math.huge
	local best_t = 0

	local function check_at_t(t)
		local p1_t = CircuitAnalyzer.motion_argument(c1_def, peg_phase(peg1), t)
		local p1_inst = get_peg_at_time(peg1, c1_def, p1_t)

		local p2_inst = peg2
		if c2_def then
			local p2_t = CircuitAnalyzer.motion_argument(c2_def, peg_phase(peg2), t)
			p2_inst = get_peg_at_time(peg2, c2_def, p2_t)
		end

		-- BR fast rejection
		local br1 = OverlapDetector.get_bounding_radius(p1_inst)
		local br2 = OverlapDetector.get_bounding_radius(p2_inst)
		local d_sq = (p1_inst.x - p2_inst.x)^2 + (p1_inst.y - p2_inst.y)^2
		local r_sum = br1 + br2

		local gap_approx = math.sqrt(d_sq) - r_sum
		if gap_approx < min_gap then
			min_gap = gap_approx
		end

		if d_sq < r_sum * r_sum then
			-- Refined overlap check
			local overlap = OverlapDetector.check_overlap(p1_inst, p2_inst)
			if overlap > 0 then
				if overlap > max_overlap then
					max_overlap = overlap
					best_t = t
				end
				return true, overlap
			else
				if -overlap < min_gap then
					min_gap = -overlap
				end
			end
		end
		return false, 0
	end

	for i = 0, coarse_steps - 1 do
		local t0 = t_start + (i / coarse_steps) * (t_end - t_start)
		local t1 = t_start + ((i+1) / coarse_steps) * (t_end - t_start)

		local o0_found, o0 = check_at_t(t0)
		local o1_found, o1 = check_at_t(t1)

		if o0_found or o1_found or min_gap < 10.0 then -- If they get close, refine
			-- Binary search between t0 and t1
			local refine_steps = 5 -- limits dt down to ~0.01
			local rt0, rt1 = t0, t1
			for r = 1, refine_steps do
				local mid = (rt0 + rt1) / 2
				local o_mid_found, o_mid = check_at_t(mid)
				if o_mid_found then
					overlap_found = true
				end
				-- Heuristic: go towards the one that is closer
				if o0 > o1 then
					rt1 = mid
					o1 = o_mid
				else
					rt0 = mid
					o0 = o_mid
				end
			end
			if overlap_found then
				return true, max_overlap, min_gap, best_t
			end
		end
	end

	return overlap_found, max_overlap, min_gap, best_t
end

-- Dense same-path sweep. Every peg on the circuit advances by the same
-- distance at any instant (pauses hold that advance for all of them), so
-- sampling the common advance spans one loop, but can miss between samples.
-- Positions for every peg are precomputed once per sample, then every pair
-- shares one linear scan. The reported best_t converts the advance back to
-- wall-clock time through the move/pause schedule.
local function sweep_same_path(family, circuit, report)
	local path = circuit.path
	local length = path:length()
	local samples = math.ceil(length / PATH_SAMPLE_STEP)
	if samples < MIN_PATH_SAMPLES then samples = MIN_PATH_SAMPLES end
	if samples > MAX_PATH_SAMPLES then samples = MAX_PATH_SAMPLES end

	local count = #family
	local xs, ys, radii = {}, {}, {}
	for i = 1, count do
		xs[i], ys[i] = {}, {}
		radii[i] = OverlapDetector.get_bounding_radius(family[i])
	end

	for k = 0, samples - 1 do
		local advance = length * (k / samples)
		local slot = k + 1
		for i = 1, count do
			local s = (peg_phase(family[i]) + advance) % length
			if s < 0 then s = s + length end
			local x, y = path:at_distance(s)
			xs[i][slot] = x
			ys[i][slot] = y
		end
	end

	for i = 1, count - 1 do
		local xi, yi = xs[i], ys[i]
		for j = i + 1, count do
			local xj, yj = xs[j], ys[j]
			local r_sum = radii[i] + radii[j]
			local circles = OverlapDetector.get_shape_type(family[i]) == "circle"
				and OverlapDetector.get_shape_type(family[j]) == "circle"
			local best_gap, best_k = math.huge, 0
			for k = 1, samples do
				local dx = xi[k] - xj[k]
				local dy = yi[k] - yj[k]
				local gap = math.sqrt(dx * dx + dy * dy) - r_sum
				if not circles and gap <= 0.01 then
					local advance = length * ((k - 1) / samples)
					local p1 = get_peg_at_time(family[i], circuit, peg_phase(family[i]) + advance)
					local p2 = get_peg_at_time(family[j], circuit, peg_phase(family[j]) + advance)
					gap = -OverlapDetector.check_overlap(p1, p2)
				end
				if gap < best_gap then
					best_gap = gap
					best_k = k
				end
			end
			if best_gap <= 0.01 then
				local best_advance = length * ((best_k - 1) / samples)
				local best_t = CircuitAnalyzer.elapsed_for_advance(circuit, best_advance)
				local overlap = -best_gap
				local tier = overlap > 0.01 and "ERROR" or "WARN"
				report(tier, family[i], family[j], overlap, true, best_t, best_gap)
			end
		end
	end
end

-- Initial-phase check for a pair on the same circuit (existing behavior for
-- relative primitives and stationary paths).
local function check_same_circuit_initial(p1, p2, c_def, report)
	local p1_inst = get_peg_at_time(p1, c_def, peg_phase(p1))
	local p2_inst = get_peg_at_time(p2, c_def, peg_phase(p2))

	local overlap = OverlapDetector.check_overlap(p1_inst, p2_inst)
	if overlap > 0.01 then
		report("ERROR", p1, p2, overlap, true, 0)
	elseif overlap >= -0.01 then
		report("WARN", p1, p2, overlap, true, 0)
	end
end

function CircuitAnalyzer.analyze(pegs, level_circuits, report)
	local envelopes = {}
	local horizon = DEFAULT_HORIZON
	for cid, circ in pairs(level_circuits) do
		envelopes[cid] = CircuitAnalyzer.characterize_circuit(cid, circ)
		local period = CircuitAnalyzer.period(circ)
		if period and period > horizon then
			horizon = period
		end
	end

	local static_pegs = {}
	local circuit_pegs = {}

	for _, p in ipairs(pegs) do
		local cid = peg_circuit_id(p)
		if cid and level_circuits[cid] then
			table.insert(circuit_pegs, p)
		else
			table.insert(static_pegs, p)
		end
	end

	-- Group moving absolute-path pegs by circuit. These pairs get a
	-- time-domain sweep; all other same-circuit pairs keep the initial-phase
	-- check.
	local path_families = {}
	for _, p in ipairs(circuit_pegs) do
		local cid = peg_circuit_id(p)
		local def = level_circuits[cid]
		if CircuitPrimitives.is_absolute(def) and (def.speed or 0) > 0 then
			local family = path_families[cid]
			if not family then
				family = {}
				path_families[cid] = family
			end
			table.insert(family, p)
		end
	end

	local family_ids = {}
	for cid in pairs(path_families) do
		table.insert(family_ids, cid)
	end
	table.sort(family_ids, function(a, b) return tostring(a) < tostring(b) end)

	-- A: Same-circuit pegs without a moving path family: check at initial
	-- phases. Moving path families are handled by the dense sweep below.
	for i = 1, #circuit_pegs do
		local p1 = circuit_pegs[i]
		local cid = peg_circuit_id(p1)
		local c_def = level_circuits[cid]
		if not (CircuitPrimitives.is_absolute(c_def) and (c_def.speed or 0) > 0) then
			for j = i + 1, #circuit_pegs do
				local p2 = circuit_pegs[j]
				if cid == peg_circuit_id(p2) then
					check_same_circuit_initial(p1, p2, c_def, report)
				end
			end
		end
	end

	-- A2: Same-path pairs over the full traversal cycle.
	for _, cid in ipairs(family_ids) do
		local family = path_families[cid]
		if #family > 1 then
			sweep_same_path(family, level_circuits[cid], report)
		end
	end

	-- B & C & D: Envelopes + time-domain
	for i, c_peg in ipairs(circuit_pegs) do
		local cid = peg_circuit_id(c_peg)
		local env = envelopes[cid]
		local c_def = level_circuits[cid]
		local c_horizon = CircuitAnalyzer.period(c_def) or DEFAULT_HORIZON

		-- Dynamic vs Static
		for _, s_peg in ipairs(static_pegs) do
			if envelope_overlap_static(s_peg, c_peg, env) then
				local is_overlap, amount, min_gap, best_t = CircuitAnalyzer.check_dynamic_overlap(c_peg, c_def, s_peg, nil, c_horizon)
				if is_overlap then
					if amount > 0.01 then
						report("ERROR", c_peg, s_peg, amount, true, best_t, min_gap)
					elseif amount >= -0.01 then
						report("WARN", c_peg, s_peg, amount, true, best_t, min_gap)
					end
				end
			end
		end

		-- Dynamic vs Dynamic (different circuits)
		for j = i+1, #circuit_pegs do
			local c_peg2 = circuit_pegs[j]
			local cid2 = peg_circuit_id(c_peg2)
			if cid ~= cid2 then
				local env2 = envelopes[cid2]
				local c_def2 = level_circuits[cid2]

				if envelope_overlap_dynamic(c_peg, env, c_peg2, env2) then
					local c2_horizon = CircuitAnalyzer.period(c_def2) or DEFAULT_HORIZON
					local pair_horizon = c_horizon > c2_horizon and c_horizon or c2_horizon
					local is_overlap, amount, min_gap, best_t = CircuitAnalyzer.check_dynamic_overlap(c_peg, c_def, c_peg2, c_def2, pair_horizon)
					if is_overlap then
						if amount > 0.01 then
							report("ERROR", c_peg, c_peg2, amount, true, best_t, min_gap)
						elseif amount >= -0.01 then
							report("WARN", c_peg, c_peg2, amount, true, best_t, min_gap)
						end
					end
				end
			end
		end
	end

	local family_count = 0
	for _, family in pairs(path_families) do
		family_count = family_count + 1
	end

	return {
		horizon = horizon,
		path_families = family_count,
	}
end

return CircuitAnalyzer
