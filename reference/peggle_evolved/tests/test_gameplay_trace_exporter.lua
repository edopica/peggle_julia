-- GameplayTraceExporter tests (determinism + exportability).
local GameplayTraceExporter = require("src.systems.gameplay_trace_exporter")
local Config = require("src.config")

-- Patch io to capture output without writing files.
local function capture_init()
	local captured = {}
	local orig_open = io.open
	io.open = function(name, mode)
		-- Return a fake file object that records writes.
		local buf = {}
		local f = {
			write = function(_, s) table.insert(buf, s) end,
			close = function() table.insert(captured, table.concat(buf)) end,
			flush = function() end,
			read = function() return nil end,
		}
		captured._file = f
		return f
	end
	return captured, function() io.open = orig_open end
end

return {
	test_deterministic_encoding_object_keys_sorted = function()
		local json = GameplayTraceExporter.to_json({ b = 1, a = 2, c = 3 })
		-- Keys must be sorted alphabetically.
		assert_true(json:find('"a":2') ~= nil)
		assert_true(json:find('"b":1') ~= nil)
		assert_true(json:find('"c":3') ~= nil)
		-- a should come before b before c.
		assert_true(json:find("a") < json:find('"b"'))
		assert_true(json:find('"b"') < json:find('"c"'))
	end,

	test_byte_identical_for_same_input = function()
		local rec = {
			step = 1, shot_id = 1,
			raw_events = { { type = "ball_contacted_peg", ball_id = 1, impact_x = 12.5 } },
			derived_events = { { type = "peg_scored", peg_id = 3 } },
			requested_commands = { { type = "award_style_points", points = 1000 } },
			applied_commands = {},
			snapshot = { step_id = 1, shot_id = 1, balls = { { id = 1, x = 1.5 } } },
		}
		local j1 = GameplayTraceExporter.to_json(rec)
		local j2 = GameplayTraceExporter.to_json(rec)
		assert_eq(j1, j2, "same input must produce byte-identical output")
	end,

	test_full_precision_numbers = function()
		local v = 1.0 / 3.0
		local j = GameplayTraceExporter.to_json({ x = v })
		-- Should contain the full-precision representation, not a truncated one.
		assert_true(j:find(string.format("%.17g", v)) ~= nil, "full precision number")
	end,

	test_no_table_addresses = function()
		local j = GameplayTraceExporter.to_json({ type = "x" })
		assert_true(j:find("table:") == nil, "no table address")
		-- A function in a payload is defensively encoded as null.
		local j2 = GameplayTraceExporter.to_json({ f = function() end })
		-- functions become null; never a function address string.
		assert_true(j2:find("function:") == nil, "no function address")
	end,

	test_invalid_json_numbers_emitted_as_null = function()
		local j = GameplayTraceExporter.to_json({ inf = math.huge, nan = 0 / 0 })
		assert_true(j:find('"inf":null') ~= nil, "infinity -> null")
		assert_true(j:find('"nan":null') ~= nil, "nan -> null")
	end,

	test_arrays_preserve_order = function()
		local j = GameplayTraceExporter.to_json({ 3, 1, 2 })
		assert_eq(j, "[3,1,2]")
	end,

	test_nested_tables = function()
		local j = GameplayTraceExporter.to_json({ a = { 1, 2 }, b = { c = 3 } })
		assert_true(j:find('"a":[1,2]', 1, true) ~= nil, "nested array")
		assert_true(j:find('"b":{"c":3}', 1, true) ~= nil, "nested object")
	end,

	test_export_step_writes_jsonl = function()
		local captured, restore = capture_init()
		GameplayTraceExporter.init("dummy.jsonl")
		assert_true(GameplayTraceExporter.file ~= nil)
		GameplayTraceExporter.export_step({
			step = 1, shot_id = 1,
			raw_events = {}, derived_events = {},
			requested_commands = {}, applied_commands = {},
			snapshot = nil,
		})
		GameplayTraceExporter.close()
		assert_true(#captured > 0, "output was captured")
		-- The header line + one step line.
		local combined = table.concat(captured, "\n")
		assert_true(combined:find('"kind":"gameplay_trace"') ~= nil)
		assert_true(combined:find('"kind":"step"') ~= nil)
		restore()
		GameplayTraceExporter.file = nil
	end,

	test_schema_version_present = function()
		local j = GameplayTraceExporter.to_json({ schema_version = 1 })
		assert_true(j:find('"schema_version":1') ~= nil)
	end,

	test_empty_arrays = function()
		local j = GameplayTraceExporter.to_json({ a = {}, b = {} })
		assert_eq(j, '{"a":[],"b":[]}')
	end,
}
