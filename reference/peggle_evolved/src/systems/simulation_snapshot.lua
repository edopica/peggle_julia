-- ===========================================================================
-- SimulationSnapshot: deterministic in-memory authoritative state capture.
--
-- Reusable independently of JSON export. Produces a plain-data table (only
-- strings/numbers/booleans/nil/arrays/tables of the same) representing the
-- complete authoritative state of an Engine at the moment of capture.
--
-- No live entity references are retained: balls/pegs/bucket are copied by
-- value (scalars only). Order is stable: balls in active_balls order, pegs in
-- original_index order. Creation does not mutate simulation state.
-- ===========================================================================

local SimulationSnapshot = {}
local SimulationSnapshot_mt = { __index = SimulationSnapshot }

local SCHEMA_VERSION = 2

local function copy_scalar(v)
	local t = type(v)
	if t == "number" or t == "string" or t == "boolean" or v == nil then
		return v
	elseif t == "table" then
		local out = {}
		-- Array part first, in order.
		for i, iv in ipairs(v) do
			out[i] = copy_scalar(iv)
		end
		-- Non-array keys (deterministic: sorted by key string).
		local keys = {}
		for k in pairs(v) do
			if type(k) ~= "number" or k > #v then
				table.insert(keys, k)
			end
		end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do
			out[k] = copy_scalar(v[k])
		end
		return out
	end
	-- Reject functions/userdata/threads by emitting nil (defensive).
	return nil
end

local function copy_ball(b)
	return {
		id = b.id,
		x = b.x,
		y = b.y,
		prev_x = b.prev_x,
		prev_y = b.prev_y,
		vx = b.vx,
		vy = b.vy,
		radius = b.radius,
		launched = b.launched,
		scored_fever = b.scoredFever or nil,
	}
end

local function copy_peg(p)
	-- Flat legacy-named fields are derived from peg.motion for trace
	-- compatibility; the authoritative `motion` sub-table is included too.
	local motion = nil
	if p.motion then
		motion = {
			circuit = p.motion.circuit,
			phase = p.motion.phase,
			time = p.motion.time,
			state = p.motion.state,
			timer = p.motion.timer,
		}
	end
	-- Line authoring metadata (phase-3 lines): plain scalar sub-table or nil.
	local line = nil
	if p.line then
		line = {
			id = p.line.id,
			index = p.line.index,
			count = p.line.count,
			closed = p.line.closed,
			gap = p.line.gap,
		}
	end
	local s = {
		original_index = p.original_index,
		type = p.type,
		shape = p.shape or "circle",
		line = line,
		hit = p.hit,
		hit_order = p.hit_order,
		multiplier_at_hit = p.multiplier_at_hit,
		x = p.x,
		y = p.y,
		base_x = p.base_x,
		base_y = p.base_y,
		base_angle = p.base_angle,
		angle = p.angle,
		vx = p.vx or 0,
		vy = p.vy or 0,
		va = p.va or 0,
		circuit_id = motion and motion.circuit or nil,
		circuit_t = motion and motion.time or nil,
		circuit_state = motion and motion.state or nil,
		circuit_timer = motion and motion.timer or nil,
		motion = motion,
	}
	if not p.shape or p.shape == "circle" then
		s.radius = p.radius
	elseif p.shape == "rectangle" then
		s.width = p.width
		s.height = p.height
	elseif p.shape == "annular" then
		s.r_in = p.r_in
		s.r_out = p.r_out
		s.theta_start = p.theta_start
		s.theta_end_abs = p.theta_end_abs
	end
	return s
end

local function copy_bucket(b)
	if not b then return nil end
	return {
		x = b.x,
		prev_x = b.prev_x,
		top = b.top,
		hole = b.hole,
		edge = b.edge,
		height = b.height,
		phase = b.phase,
	}
end

local function copy_fever(f)
	if not f then return nil end
	local buckets = {}
	for _, slot in ipairs(f.buckets or {}) do
		table.insert(buckets, { x = slot.x, width = slot.width, value = slot.value })
	end
	local dividers = {}
	for _, d in ipairs(f.dividers or {}) do
		table.insert(dividers, { x = d.x, y = d.y, radius = d.radius })
	end
	return {
		top = f.top,
		height = f.height,
		animating = f.animating,
		buckets = buckets,
		dividers = dividers,
	}
end

-- Capture the full authoritative snapshot of an Engine instance.
function SimulationSnapshot.capture(engine)
	local balls = {}
	for _, b in ipairs(engine.active_balls) do
		table.insert(balls, copy_ball(b))
	end

	-- Pegs in original_index order (engine.pegs is maintained in that order).
	local pegs = {}
	for _, p in ipairs(engine.pegs) do
		table.insert(pegs, copy_peg(p))
	end

	local snap = {
		schema_version = SCHEMA_VERSION,
		step_id = engine.sim_step_id,
		shot_id = engine.shot_id,
		level_name = engine.level_name,
		is_fever = engine.isFever,
		current_multiplier = engine.currentMultiplier,
		hit_counter = engine.hitCounter,
		total_red_pegs = engine.totalRedPegs,
		red_pegs_hit_amount = engine.redPegsHitAmount,
		bonus_score = engine.bonusScore,
		style_score = engine.styleScore or 0,
		turn_peg_count = #(engine.turnPegsHit or {}),
		clearing_active = engine.clearQueue ~= nil,
		clearing_is_end_of_turn = engine.clearingIsEndOfTurn,
		clear_timer = engine.clearTimer,
		balls = balls,
		pegs = pegs,
		bucket = copy_bucket(engine.bucket),
		fever_buckets = copy_fever(engine.feverBuckets),
	}

	-- Turn pegs hit: list of peg_ids (original_index) in hit order.
	local turn_pegs = {}
	for _, p in ipairs(engine.turnPegsHit or {}) do
		table.insert(turn_pegs, p.original_index)
	end
	snap.turn_pegs_hit = turn_pegs

	return snap
end

return SimulationSnapshot
