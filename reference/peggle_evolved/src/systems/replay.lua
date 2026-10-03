-- ===========================================================================
-- Replay: shot capture and load (last-shot replay files).
--
-- Capture format (schema_version 2):
--   return {
--       schema_version = 2,
--       level_name = "level1",
--       isFever = false,
--       hitCounter = 5,
--       redPegsHitAmount = 3,
--       currentMultiplier = 2,
--       pegs = {
--           { original_index = 1, type = "blue", hit = false,
--             base_x = 600, base_y = 200, base_angle = 0,
--             x = 600, y = 200, angle = 0, vx = 0, vy = 0, va = 0,
--             line = { id = "main_slide", index = 3, count = 12,
--                      closed = false, gap = 0 },
--             motion = { circuit = "c1", phase = 1.4, time = 1.4,
--                        state = "moving", timer = 0 } },
--       },
--       bucket = { phase = 0.3, x = 731.87654321012349 },
--       balls = { { id = 1, x = 100, y = 50, vx = 10, vy = 20 } },
--   }
--
-- Per-peg `line` metadata (phase-3 lines) is optional: it is written when the
-- level generated the peg from a line and validated structurally on load;
-- the restore path keeps the level's own metadata. Older captures without it
-- (and levels without lines) remain loadable.
--
-- bucket.x is captured when present (post-fix files) so the restored bucket
-- starts at its captured position with prev_x = x (no first-step jump).
-- Older files without it keep the pre-fix restore (position from Bucket.new).
--
-- Scoring-progress fields (schema_version 2): hitCounter is the global
-- peg-hit counter (hit_order continuity for the clearing cascade),
-- redPegsHitAmount counts hit red pegs this level, and currentMultiplier is
-- the score multiplier at capture time (isFever == (currentMultiplier == 100)).
-- Legacy schema-2 captures without redPegsHitAmount/currentMultiplier read as
-- 0 red pegs hit and multiplier 1 (pre-fix defaults).
--
-- Every peg carries its base transform, its current transform, and its
-- per-step velocities. Moving pegs additionally carry their runtime motion
-- state. base_angle is always the declared base rotation (never the current
-- applied rotation — fixes the pre-refactor capture bug).
--
-- Legacy captures (no schema_version, flat circuit_id/circuit_t/circuit_state/
-- circuit_timer fields) remain loadable; conversion happens in
-- Engine:applyReplayState.
-- ===========================================================================

local Replay = {}

local SCHEMA_VERSION = 2

-- Field lists the restore path reads; Replay.validate type-checks these.
-- Absent fields are fine (nil keeps its per-format fallback), present
-- fields must carry the listed type.
local PEG_NUM_FIELDS = { "x", "y", "angle", "base_x", "base_y", "base_angle", "vx", "vy", "va", "hit_order" }
local MOTION_NUM_FIELDS = { "phase", "time", "timer" }
local MOTION_STR_FIELDS = { "circuit", "state" }
local SCORING_NUM_FIELDS = { "hitCounter", "redPegsHitAmount", "currentMultiplier" }
local BALL_NUM_FIELDS = { "x", "y", "vx", "vy" }
-- Optional per-peg authoring line metadata (phase-3 lines). Captured for
-- completeness when the level used Lines.generate; restore keeps the level's
-- own peg.line metadata, so the table is validated structurally and ignored
-- by the restore path (older captures without it stay loadable).
local LINE_STR_FIELDS = { "id" }
local LINE_NUM_FIELDS = { "index", "count", "gap" }

-- Describe a value for error messages; strings are quoted so the offending
-- value is identifiable (schema_version "2" vs 2).
local function describe(v)
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function optional_number_field(t, label, f)
	local v = t[f]
	if v ~= nil and type(v) ~= "number" then
		return nil, label .. "." .. f .. " must be a number, got " .. describe(v)
	end
	return true
end

local function optional_string_field(t, label, f)
	local v = t[f]
	if v ~= nil and type(v) ~= "string" then
		return nil, label .. "." .. f .. " must be a string, got " .. describe(v)
	end
	return true
end

local function required_number_field(t, label, f)
	local v = t[f]
	if type(v) ~= "number" then
		return nil, label .. "." .. f .. " must be a number, got " .. describe(v)
	end
	return true
end

-- Full-precision float formatting: round-trips IEEE-754 doubles exactly
-- through the Lua parser (tostring's %.14g can lose determinism bits).
local function num(v)
	return string.format("%.17g", v)
end

-- Serialize a capture to the Lua source string that Replay.load reads back.
-- The caller passes live engine tables (pegs/bucket/balls); serialization must
-- happen at capture time so the saved file reflects launch state, not the
-- post-shot state those tables mutate into.
function Replay.serialize(data)
	local t = { "return {" }
	table.insert(t, string.format("\tschema_version = %d,", SCHEMA_VERSION))
	table.insert(t, string.format("\tlevel_name = %q,", data.level_name))
	table.insert(t, string.format("\tisFever = %s,", tostring(data.isFever)))

	table.insert(t, "\tpegs = {")
	for _, peg in ipairs(data.pegs) do
		local fields = {
			string.format("original_index=%d", peg.original_index),
			string.format("type=%q", peg.type),
			string.format("hit=%s", tostring(peg.hit)),
			string.format("hit_order=%s", peg.hit_order and num(peg.hit_order) or "nil"),
			string.format("base_x=%s", num(peg.base_x or peg.x)),
			string.format("base_y=%s", num(peg.base_y or peg.y)),
			string.format("base_angle=%s", num(peg.base_angle or 0)),
			string.format("x=%s", num(peg.x)),
			string.format("y=%s", num(peg.y)),
			string.format("angle=%s", num(peg.angle or 0)),
			string.format("vx=%s", num(peg.vx or 0)),
			string.format("vy=%s", num(peg.vy or 0)),
			string.format("va=%s", num(peg.va or 0)),
		}
		if peg.line then
			local l = peg.line
			-- Optional authoring metadata (phase-3 lines). Written only when
			-- the level generated the peg from a line; older files without
			-- the field (and line-less levels) stay loadable.
			table.insert(fields, string.format(
				"line={id=%q, index=%d, count=%d, closed=%s, gap=%s}",
				tostring(l.id),
				math.floor(l.index),
				math.floor(l.count),
				tostring(l.closed),
				num(l.gap or 0)))
		end
		if peg.motion then
			local m = peg.motion
			table.insert(fields, string.format(
				"motion={circuit=%q, phase=%s, time=%s, state=%q, timer=%s}",
				tostring(m.circuit),
				num(m.phase or 0),
				num(m.time or 0),
				tostring(m.state or "moving"),
				num(m.timer or 0)))
		end
		table.insert(t, "\t\t{" .. table.concat(fields, ", ") .. "},")
	end
	table.insert(t, "\t},")

	table.insert(t, string.format("\thitCounter = %d,", data.hitCounter or 0))
	table.insert(t, string.format("\tredPegsHitAmount = %s,", num(data.redPegsHitAmount or 0)))
	table.insert(t, string.format("\tcurrentMultiplier = %s,", num(data.currentMultiplier or 1)))

	-- Bucket phase must round-trip exactly (num, not tostring) so the
	-- oscillation resumes from the captured instant; x is captured when the
	-- source carries it (live buckets always do).
	local bucket = data.bucket
	if bucket and bucket.x ~= nil then
		table.insert(t, string.format("\tbucket = {phase=%s, x=%s},",
			num(bucket.phase or 0), num(bucket.x)))
	else
		table.insert(t, string.format("\tbucket = {phase=%s},",
			num(bucket and bucket.phase or 0)))
	end

	table.insert(t, "\tballs = {")
	for _, ball in ipairs(data.balls) do
		-- Stable ball IDs are captured when present (post-Phase-2 captures):
		-- through num() so large IDs near 2^53-1 round-trip exactly
		-- (tostring's %.14g shortens them, changing the ball identity).
		-- Absent IDs stay nil (id=nil): the loader allocates deterministic
		-- IDs in ball order.
		table.insert(t, string.format("\t\t{id=%s, x=%s, y=%s, vx=%s, vy=%s},",
			ball.id and num(ball.id) or "nil",
			num(ball.x), num(ball.y), num(ball.vx), num(ball.vy)))
	end
	table.insert(t, "\t}")
	table.insert(t, "}")

	return table.concat(t, "\n")
end

-- Write a serialized capture to filename. Returns true, or nil plus an error
-- message when the file cannot be opened (e.g. a missing parent directory).
function Replay.write(filename, contents)
	local f, err = io.open(filename, "w")
	if not f then
		return nil, err or ("failed to open " .. filename .. " for writing")
	end
	f:write(contents)
	f:close()
	return true
end

function Replay.capture(filename, data)
	return Replay.write(filename, Replay.serialize(data))
end

function Replay.load(filename)
	local chunk, err = loadfile(filename)
	if not chunk then
		print("Failed to load replay:", err)
		return nil
	end
	return chunk()
end

-- True only when the capture uses the schema_version 2 motion format:
-- schema_version must be the exact integer 2 (numeric; "2", 2.5, or 3 are
-- not schema 2). Total on any input: never errors on garbage data.
function Replay.is_schema_2(data)
	return type(data) == "table" and data.schema_version == SCHEMA_VERSION
end

-- ===========================================================================
-- Strict structural validation. Returns true, or nil, error_message naming
-- the offending field/value. Engine:applyReplayState runs this before ANY
-- state mutation, so a malformed capture fails atomically.
--
--   * No schema_version field: legacy capture. Field conversion stays fully
--     permissive (every field is optional); only the container shapes the
--     restore path iterates/indexes are guarded against mid-restore crashes
--     (pegs/bucket must be tables, peg entries must be tables carrying a
--     numeric original_index).
--   * schema_version == the exact integer 2: strict schema-2 checks for
--     every field the restore path reads (see field lists above).
--   * Any other schema_version (future integers, fractions, strings,
--     booleans, ...) is rejected with the offending value named.
-- ===========================================================================
function Replay.validate(data)
	if type(data) ~= "table" then
		return nil, "replay data must be a table, got " .. type(data)
	end

	local version = data.schema_version
	if version ~= nil and (type(version) ~= "number" or version ~= SCHEMA_VERSION) then
		return nil, "unsupported schema_version " .. describe(version)
			.. " (expected the exact integer 2, or no schema_version field"
			.. " for a legacy capture)"
	end

	if version == nil then
		if data.pegs ~= nil and type(data.pegs) ~= "table" then
			return nil, "replay pegs must be a table, got " .. describe(data.pegs)
		end
		if data.bucket ~= nil and type(data.bucket) ~= "table" then
			return nil, "replay bucket must be a table, got " .. describe(data.bucket)
		end
		for i, rp in ipairs(data.pegs or {}) do
			local label = "replay pegs[" .. i .. "]"
			if type(rp) ~= "table" then
				return nil, label .. " must be a table, got " .. describe(rp)
			end
			if type(rp.original_index) ~= "number" then
				return nil, label .. ".original_index must be a number, got "
					.. describe(rp.original_index)
			end
		end
		return true
	end

	if type(data.level_name) ~= "string" then
		return nil, "schema 2 replay requires level_name to be a string, got "
			.. describe(data.level_name)
	end
	local pegs = data.pegs
	if type(pegs) ~= "table" then
		return nil, "schema 2 replay requires pegs to be a table, got "
			.. describe(pegs)
	end
	for i, rp in ipairs(pegs) do
		local label = "schema 2 replay pegs[" .. i .. "]"
		if type(rp) ~= "table" then
			return nil, label .. " must be a table, got " .. describe(rp)
		end
		if type(rp.original_index) ~= "number" then
			return nil, label .. ".original_index must be a number, got "
				.. describe(rp.original_index)
		end
		if type(rp.type) ~= "string" then
			return nil, label .. ".type must be a string, got " .. describe(rp.type)
		end
		if type(rp.hit) ~= "boolean" then
			return nil, label .. ".hit must be a boolean, got " .. describe(rp.hit)
		end
		for _, f in ipairs(PEG_NUM_FIELDS) do
			local ok, err = optional_number_field(rp, label, f)
			if not ok then return nil, err end
		end
		-- Optional line metadata (phase-3 lines): structural type checks only.
		-- The restore path keeps the level's own peg.line, so no semantic
		-- reconciliation happens here.
		local line = rp.line
		if line ~= nil then
			if type(line) ~= "table" then
				return nil, label .. ".line must be a table, got " .. describe(line)
			end
			for _, f in ipairs(LINE_STR_FIELDS) do
				local ok, err = optional_string_field(line, label .. ".line", f)
				if not ok then return nil, err end
			end
			for _, f in ipairs(LINE_NUM_FIELDS) do
				local ok, err = optional_number_field(line, label .. ".line", f)
				if not ok then return nil, err end
			end
			if line.closed ~= nil and type(line.closed) ~= "boolean" then
				return nil, label .. ".line.closed must be a boolean, got "
					.. describe(line.closed)
			end
		end
		local motion = rp.motion
		if motion ~= nil then
			if type(motion) ~= "table" then
				return nil, label .. ".motion must be a table, got " .. describe(motion)
			end
			for _, f in ipairs(MOTION_NUM_FIELDS) do
				local ok, err = optional_number_field(motion, label .. ".motion", f)
				if not ok then return nil, err end
			end
			for _, f in ipairs(MOTION_STR_FIELDS) do
				local ok, err = optional_string_field(motion, label .. ".motion", f)
				if not ok then return nil, err end
			end
		end
	end
	for _, f in ipairs(SCORING_NUM_FIELDS) do
		local ok, err = optional_number_field(data, "schema 2 replay", f)
		if not ok then return nil, err end
	end
	if data.isFever ~= nil and type(data.isFever) ~= "boolean" then
		return nil, "schema 2 replay isFever must be a boolean, got "
			.. describe(data.isFever)
	end
	local bucket = data.bucket
	if bucket ~= nil then
		if type(bucket) ~= "table" then
			return nil, "schema 2 replay bucket must be a table, got " .. describe(bucket)
		end
		local ok, err = optional_number_field(bucket, "schema 2 replay bucket", "phase")
		if not ok then return nil, err end
		-- x is optional (older files lack it and fall back to Bucket.new).
		ok, err = optional_number_field(bucket, "schema 2 replay bucket", "x")
		if not ok then return nil, err end
	end
	local balls = data.balls
	if balls ~= nil then
		if type(balls) ~= "table" then
			return nil, "schema 2 replay balls must be a table, got " .. describe(balls)
		end
		for i, rb in ipairs(balls) do
			local label = "schema 2 replay balls[" .. i .. "]"
			if type(rb) ~= "table" then
				return nil, label .. " must be a table, got " .. describe(rb)
			end
			for _, f in ipairs(BALL_NUM_FIELDS) do
				local ok, err = required_number_field(rb, label, f)
				if not ok then return nil, err end
			end
			local ok, err = optional_number_field(rb, label, "id")
			if not ok then return nil, err end
		end
	end
	return true
end

return Replay
