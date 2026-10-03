-- ===========================================================================
-- MotionSchema: load-time validation for peg motion assignments.
--
-- The peg array (level_data.pegs) is the only source of peg ownership.
-- Circuit definitions live in level_circuits and do NOT contain pegs.
-- Each moving peg carries `peg.motion = { circuit = <id>, phase = <number> }`.
--
-- All validation happens during level setup; invalid motion data raises a
-- clear load-time error instead of failing mid-simulation. Circuit ids are
-- iterated in sorted order so error reporting is deterministic.
-- ===========================================================================

local CircuitPrimitives = require("src.systems.circuit_primitives")
local Path = require("src.systems.path")

local MotionSchema = {}

-- Required numeric parameters per primitive kind.
local REQUIRED_PARAMS = {
	ellipse = { "amp_x", "amp_y" },
	cos_ellipse = { "amp_x", "amp_y" },
	oscillate_x = { "amp" },
	oscillate_y = { "amp" },
	rotate = {},
	line = { "amp" },
	-- speed is a required finite px/s rate for path circuits; phase and
	-- motion.time are distances in pixels.
	path = { "speed" },
}

-- Primitive kinds with required parameters (used to decide what to check).
local KNOWN_KINDS = CircuitPrimitives.primitives

local function is_finite_number(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function fail(fmt, ...)
	error(string.format("Motion schema error: " .. fmt, ...), 0)
end

-- Validate a single circuit definition. Raises on invalid data.
local function validate_circuit(id, def)
	if type(def) ~= "table" then
		fail("circuit %q is not a table", tostring(id))
	end
	if def.pegs ~= nil then
		fail("circuit %q contains a 'pegs' array; circuit definitions do not own pegs", tostring(id))
	end
	-- A circuit is defined either by a 'kind' primitive or (legacy) by a
	-- path_fn function -- never both. eval_transform gives path_fn
	-- precedence, so a mixed definition would silently ignore kind.
	if def.kind ~= nil and def.path_fn ~= nil then
		fail("circuit %q defines both a 'kind' primitive and a 'path_fn' function; "
			.. "use exactly one path definition", tostring(id))
	end
	if def.kind == nil then
		-- Legacy path_fn definitions remain runnable (temporary support);
		-- the caller emits a one-time migration warning.
		if type(def.path_fn) ~= "function" then
			fail("circuit %q has no 'kind' primitive", tostring(id))
		end
	end
	if def.kind ~= nil and KNOWN_KINDS[def.kind] == nil then
		fail("circuit %q has unknown primitive kind %q", tostring(id), tostring(def.kind))
	end
	for _, param in ipairs(def.kind and (REQUIRED_PARAMS[def.kind] or {}) or {}) do
		if not is_finite_number(def[param]) then
			fail("circuit %q (kind %q) requires numeric parameter %q",
				tostring(id), def.kind, param)
		end
	end
	-- Absolute path primitives require a compiled, closed Path all of whose
	-- joins (including the closing seam) pass the shared geometry contract.
	-- Sampling itself retains clamped Path:at_distance behavior; the motion
	-- primitive wraps the argument.
	if def.kind == "path" then
		if not Path.is_path(def.path) then
			fail("circuit %q (kind \"path\") requires def.path to be a compiled Path",
				tostring(id))
		end
		if def.path.closed ~= true then
			fail("circuit %q (kind \"path\") requires a closed path", tostring(id))
		end
		local ok, detail = def.path:validate_joins()
		if not ok then
			fail("circuit %q (kind \"path\") has a %s discontinuity between segments %d and %d%s (error %.3g > tolerance %.3g)",
				tostring(id), detail.kind, detail.from_segment, detail.to_segment,
				detail.seam and " (closing seam)" or "", detail.error, detail.tolerance)
		end
	end
	-- Primitive option fields read during eval: frequency (oscillate_*),
	-- angle (line), speed_angular (rotate). Validated whenever present.
	for _, field in ipairs({ "frequency", "angle", "speed_angular" }) do
		local v = def[field]
		if v ~= nil and not is_finite_number(v) then
			fail("circuit %q has invalid %s value %s (must be a finite number)",
				tostring(id), field, tostring(v))
		end
	end
	-- rotate is a boolean switch read by the ellipse primitives
	-- (p.rotate and t or 0); only true/false are valid.
	if def.rotate ~= nil and type(def.rotate) ~= "boolean" then
		fail("circuit %q has invalid rotate value %s (must be a boolean)",
			tostring(id), tostring(def.rotate))
	end
	for k, v in pairs(def) do
		if type(v) == "number" and not is_finite_number(v) then
			fail("circuit %q has non-finite numeric field %q", tostring(id), tostring(k))
		end
	end
	for _, field in ipairs({ "speed", "duration_time", "pause_time" }) do
		local v = def[field]
		if v ~= nil and (not is_finite_number(v) or v < 0) then
			fail("circuit %q has invalid %s value %s (must be a finite number >= 0)",
				tostring(id), field, tostring(v))
		end
	end
	if (def.duration_time or 0) > 0 and (def.pause_time or 0) <= 0 then
		fail("circuit %q is timed (duration_time > 0) but has no explicit pause policy (pause_time > 0)",
			tostring(id))
	end
end

-- Validate the full motion schema of a level:
--   pegs           array of pegs (level_data.pegs)
--   level_circuits table of circuit definitions keyed by id
-- Raises on the first invalid item. Emits one warning per legacy path_fn
-- circuit definition.
function MotionSchema.validate(pegs, level_circuits)
	pegs = pegs or {}
	level_circuits = level_circuits or {}

	local ids = {}
	for id in pairs(level_circuits) do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
	for _, id in ipairs(ids) do
		local def = level_circuits[id]
		validate_circuit(id, def)
		if def.kind == nil and type(def.path_fn) == "function" then
			print("WARNING: circuit " .. tostring(id)
				.. " uses path_fn instead of kind — migrate to primitive")
		end
	end

	local LEGACY_FIELDS = { "circuit_id", "circuit_t", "circuit_state", "circuit_timer" }
	for i, peg in ipairs(pegs) do
		local legacy = {}
		for _, field in ipairs(LEGACY_FIELDS) do
			if peg[field] ~= nil then
				table.insert(legacy, field)
			end
		end
		if #legacy > 0 and peg.motion ~= nil then
			fail("peg %d mixes legacy circuit fields (%s) with peg.motion",
				i, table.concat(legacy, "/"))
		end
		if #legacy > 0 then
			fail("peg %d uses legacy circuit assignment fields (%s); use peg.motion = { circuit = ..., phase = ... }",
				i, table.concat(legacy, "/"))
		end
		if peg.motion ~= nil then
			if type(peg.motion) ~= "table" then
				fail("peg %d has a non-table motion assignment", i)
			end
			local cid = peg.motion.circuit
			if type(cid) ~= "string" then
				fail("peg %d motion table has no valid circuit reference", i)
			end
			if level_circuits[cid] == nil then
				fail("peg %d references circuit %q which does not exist in level_circuits", i, cid)
			end
			if peg.motion.phase ~= nil and not is_finite_number(peg.motion.phase) then
				fail("peg %d motion phase is not a finite number", i)
			end
		end
	end
end

-- True when a peg moves along a circuit.
function MotionSchema.is_moving(peg)
	return peg.motion ~= nil and peg.motion.circuit ~= nil
end

-- True when a circuit definition is an absolute path circuit that satisfies
-- the closed-path approval gate. Boundary filtering uses this as its narrow
-- exemption: only approved closed-path motion may keep an off-screen base.
-- The structural checks repeat here so a caller that skipped
-- MotionSchema.validate cannot bypass the boundary pass with malformed data.
function MotionSchema.is_closed_path_circuit(def)
	return type(def) == "table"
		and CircuitPrimitives.is_absolute(def)
		and Path.is_path(def.path)
		and def.path.closed == true
end

return MotionSchema
