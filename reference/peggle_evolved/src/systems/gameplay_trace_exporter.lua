-- ===========================================================================
-- GameplayTraceExporter: canonical versioned JSONL gameplay trace.
--
-- Writes one JSON object per fixed step:
--   schema_version, step, shot_id,
--   raw_events, derived_events, requested_commands, applied_commands,
--   snapshot (full authoritative state)
--
-- The encoder is deterministic: object keys are emitted in sorted order, and
-- numbers use full precision (%.17g) so two runs of the same replay under the
-- same runtime/config/seed produce byte-identical traces. No table addresses,
-- functions, userdata, or live entity references ever appear.
--
-- Separate from the existing TraceExporter (entity positions). Both can run.
-- ===========================================================================

local GameplayTraceExporter = {
	file = nil,
	steps_written = 0,
	include_snapshot = true,
}

local SCHEMA_VERSION = 1

-- Deterministic JSON encoding. Only strings/numbers/booleans/nil/arrays/tables
-- of those are supported. Object keys sorted lexicographically; arrays (1..n)
-- preserve order.
local function encode(v, out)
	local t = type(v)
	if t == "nil" then
		out[#out + 1] = "null"
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			-- Invalid JSON numbers: emit null to keep the trace valid.
			out[#out + 1] = "null"
		elseif v == math.floor(v) and math.abs(v) < 1e15 then
			out[#out + 1] = tostring(math.floor(v))
		else
			out[#out + 1] = string.format("%.17g", v)
		end
	elseif t == "string" then
		local s = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
			:gsub('\r', '\\r'):gsub('\t', '\\t'):gsub('\b', '\\b')
			:gsub('\f', '\\f')
		out[#out + 1] = '"'
		out[#out + 1] = s
		out[#out + 1] = '"'
	elseif t == "table" then
		-- An array is a table whose keys are exactly 1..n (no gaps, no string
		-- keys). An empty table is treated as an empty array. Everything else
		-- is an object (keys emitted in sorted order).
		local n = #v
		local count = 0
		local all_int = true
		for k in pairs(v) do
			count = count + 1
			if type(k) ~= "number" then
				all_int = false
			end
		end
		local is_array = (count == n) and all_int

		if is_array then
			out[#out + 1] = "["
			for i = 1, n do
				if i > 1 then out[#out + 1] = "," end
				encode(v[i], out)
			end
			out[#out + 1] = "]"
		else
			-- Object: sorted keys.
			local keys = {}
			for k in pairs(v) do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			out[#out + 1] = "{"
			for i, k in ipairs(keys) do
				if i > 1 then out[#out + 1] = "," end
				encode(tostring(k), out)
				out[#out + 1] = ":"
				encode(v[k], out)
			end
			out[#out + 1] = "}"
		end
	else
		-- functions/userdata/threads: skip defensively (should never happen).
		out[#out + 1] = "null"
	end
end

local function to_json(val)
	local out = {}
	encode(val, out)
	return table.concat(out)
end

function GameplayTraceExporter.init(filename, opts)
	opts = opts or {}
	GameplayTraceExporter.steps_written = 0
	GameplayTraceExporter.include_snapshot = opts.include_snapshot ~= false
	GameplayTraceExporter.file = io.open(filename, "w")
	if GameplayTraceExporter.file then
		-- Trace header line (schema version + config fingerprint).
		local header = {
			schema_version = SCHEMA_VERSION,
			kind = "gameplay_trace",
			include_snapshot = GameplayTraceExporter.include_snapshot,
		}
		GameplayTraceExporter.file:write(to_json(header) .. "\n")
		print("GameplayTraceExporter: writing canonical trace to " .. filename)
	else
		print("GameplayTraceExporter: FAILED to open " .. filename)
	end
end

-- Export one completed step record.
--   step_record = {
--     step, shot_id, raw_events, derived_events,
--     requested_commands, applied_commands, snapshot (or nil)
--   }
function GameplayTraceExporter.export_step(step_record)
	local f = GameplayTraceExporter.file
	if not f then return end
	local rec = {
		schema_version = SCHEMA_VERSION,
		kind = "step",
		step = step_record.step,
		shot_id = step_record.shot_id,
		raw_events = step_record.raw_events,
		derived_events = step_record.derived_events,
		requested_commands = step_record.requested_commands,
		applied_commands = step_record.applied_commands,
	}
	if GameplayTraceExporter.include_snapshot and step_record.snapshot then
		rec.snapshot = step_record.snapshot
	end
	f:write(to_json(rec) .. "\n")
	GameplayTraceExporter.steps_written = GameplayTraceExporter.steps_written + 1
end

function GameplayTraceExporter.close()
	if GameplayTraceExporter.file then
		GameplayTraceExporter.file:close()
		GameplayTraceExporter.file = nil
		print("GameplayTraceExporter: closed (" ..
			GameplayTraceExporter.steps_written .. " steps written).")
	end
end

-- Expose the encoder for tests / external use.
GameplayTraceExporter.to_json = to_json

return GameplayTraceExporter
