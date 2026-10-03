-- GameplayEvents unit tests.
local GameplayEvents = require("src.systems.gameplay_events")

return {
	test_sequence_starts_at_1_each_step = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		ev:emit_raw("a", {})
		ev:emit_raw("b", {})
		assert_eq(ev:raw()[1].sequence, 1)
		assert_eq(ev:raw()[2].sequence, 2)
		ev:seal_raw()
		ev:emit_derived("d", {})
		assert_eq(ev:derived()[1].sequence, 3)
		ev:finish_step()

		ev:begin_step(2, 1)
		ev:emit_raw("a", {})
		assert_eq(ev:raw()[1].sequence, 1, "sequence should reset each step")
		ev:seal_raw()
		ev:finish_step()
	end,

	test_sequence_strictly_increasing = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		for i = 1, 5 do ev:emit_raw("t", { n = i }) end
		ev:seal_raw()
		for i = 1, 3 do ev:emit_derived("d", { n = i }) end
		local all = ev:all()
		for i = 2, #all do
			assert_true(all[i].sequence > all[i - 1].sequence, "strictly increasing")
		end
		ev:finish_step()
	end,

	test_insertion_order_preserved = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		ev:emit_raw("x", { k = 1 })
		ev:emit_raw("x", { k = 2 })
		ev:emit_raw("y", { k = 3 })
		ev:seal_raw()
		ev:emit_derived("z", { k = 4 })
		local all = ev:all()
		assert_eq(#all, 4)
		assert_eq(all[1].type, "x"); assert_eq(all[1].k, 1)
		assert_eq(all[2].type, "x"); assert_eq(all[2].k, 2)
		assert_eq(all[3].type, "y"); assert_eq(all[3].k, 3)
		assert_eq(all[4].type, "z"); assert_eq(all[4].k, 4)
		ev:finish_step()
	end,

	test_raw_after_seal_errors = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		ev:emit_raw("a", {})
		ev:seal_raw()
		local ok, err = pcall(function() ev:emit_raw("b", {}) end)
		assert_false(ok, "emit_raw after seal should error")
		assert_true(err:find("after seal_raw") ~= nil, "error message")
		ev:finish_step()
	end,

	test_derived_after_raw = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		ev:emit_raw("a", {})
		ev:seal_raw()
		ev:emit_derived("d", {})
		local all = ev:all()
		assert_eq(all[1].phase, "raw")
		assert_eq(all[2].phase, "derived")
		ev:finish_step()
	end,

	test_empty_step_valid = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		ev:seal_raw()
		assert_eq(#ev:all(), 0)
		local snap = ev:snapshot()
		assert_eq(snap.event_count, 0)
		ev:finish_step()
	end,

	test_no_leak_between_steps = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		ev:emit_raw("a", {})
		ev:seal_raw()
		ev:finish_step()
		ev:begin_step(2, 1)
		assert_eq(#ev:all(), 0, "no leak into next step")
		ev:seal_raw()
		ev:finish_step()
	end,

	test_no_leak_between_instances = function()
		local a = GameplayEvents.new()
		local b = GameplayEvents.new()
		a:begin_step(1, 1)
		a:emit_raw("a", {})
		b:begin_step(1, 1)
		assert_eq(#b:all(), 0, "instances are independent")
		assert_eq(#a:all(), 1)
		a:seal_raw(); a:finish_step()
		b:seal_raw(); b:finish_step()
	end,

	test_snapshot_no_live_refs = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 5)
		-- A live table reference as a field would be a bug; the snapshot should
		-- still only contain exportable data. We pass only scalars here.
		ev:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, impact_x = 12.5, did_bounce = true,
		})
		ev:seal_raw()
		local snap = ev:snapshot()
		assert_eq(snap.step, 1)
		assert_eq(snap.shot_id, 5)
		-- Verify the event has no function/userdata/thread fields.
		local function check(v, path)
			local t = type(v)
			if t == "function" or t == "userdata" or t == "thread" then
				error("non-exportable value at " .. path .. ": " .. t)
			elseif t == "table" then
				for k, vv in pairs(v) do check(k, path .. ".key")
					check(vv, path .. (type(k) == "string" and ("." .. k) or ("[" .. tostring(k) .. "]")))
				end
			end
		end
		for _, e in ipairs(snap.raw) do check(e, "event") end
		ev:emit_derived("peg_scored", { peg_id = 3 })
		for _, e in ipairs(ev:snapshot().derived) do check(e, "derived") end
		ev:finish_step()
	end,

	test_staged_events_flush_at_next_step = function()
		local ev = GameplayEvents.new()
		-- Stage an event outside any open step.
		ev:stage("ball_launched", { ball_id = 1, x = 100 })
		ev:begin_step(1, 7)
		local raw = ev:raw()
		assert_eq(#raw, 1, "staged event flushed at begin_step")
		assert_eq(raw[1].type, "ball_launched")
		assert_eq(raw[1].step, 1)
		assert_eq(raw[1].shot_id, 7)
		assert_eq(raw[1].ball_id, 1)
		ev:seal_raw()
		ev:finish_step()
	end,

	test_envelope_fields = function()
		local ev = GameplayEvents.new()
		ev:begin_step(42, 9)
		ev:emit_raw("ball_contacted_peg", { ball_id = 2 })
		local e = ev:raw()[1]
		assert_eq(e.schema_version, 1)
		assert_eq(e.step, 42)
		assert_eq(e.shot_id, 9)
		assert_eq(e.phase, "raw")
		assert_eq(e.type, "ball_contacted_peg")
		assert_eq(e.ball_id, 2)
		ev:seal_raw()
		ev:finish_step()
	end,

	-- ===================================================================
	-- Payload ownership & validation (§3.3)
	-- ===================================================================

	test_payload_copied_at_emit = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local payload = { ball_id = 1, impact_x = 10 }
		ev:emit_raw("ball_contacted_peg", payload)
		-- Mutating the caller's table after emit must not change the journal.
		payload.ball_id = 999
		payload.impact_x = -1
		payload.injected = "nope"
		local stored = ev:raw()[1]
		assert_eq(stored.ball_id, 1, "journal owns its copy")
		assert_eq(stored.impact_x, 10)
		assert_eq(stored.injected, nil)
		ev:seal_raw()
		ev:finish_step()
	end,

	test_nested_payload_copied_recursively = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local nested = { 1, 2, 3 }
		ev:emit_raw("x", { source_sequences = nested })
		nested[1] = 999
		nested[4] = 4
		local stored = ev:raw()[1]
		assert_eq(stored.source_sequences[1], 1, "nested array deep-copied")
		assert_eq(#stored.source_sequences, 3)
		assert_true(stored.source_sequences ~= nested, "no reference retained")
		ev:seal_raw()
		ev:finish_step()
	end,

	test_derived_payload_copied = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		ev:seal_raw()
		local payload = { peg_id = 5 }
		ev:emit_derived("peg_scored", payload)
		payload.peg_id = 999
		assert_eq(ev:derived()[1].peg_id, 5)
		ev:finish_step()
	end,

	test_staged_payload_copied_at_stage_time = function()
		local ev = GameplayEvents.new()
		local payload = { ball_id = 1, x = 100 }
		ev:stage("ball_launched", payload)
		payload.ball_id = 999
		payload.x = -100
		ev:begin_step(1, 1)
		assert_eq(ev:raw()[1].ball_id, 1, "staged payload copied at stage time")
		assert_eq(ev:raw()[1].x, 100)
		ev:seal_raw()
		ev:finish_step()
	end,

	test_reject_function_value = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local ok, err = pcall(function()
			ev:emit_raw("bad", { cb = function() end })
		end)
		assert_false(ok, "function payload rejected")
		assert_true(tostring(err):find("unsupported value type 'function'") ~= nil, tostring(err))
		ev:finish_step()
	end,

	test_reject_userdata_value = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local ok, err = pcall(function()
			ev:emit_raw("bad", { handle = io.stdout })
		end)
		assert_false(ok, "userdata payload rejected")
		assert_true(tostring(err):find("unsupported value type") ~= nil, tostring(err))
		ev:finish_step()
	end,

	test_reject_non_finite_numbers = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local ok_nan = pcall(function() ev:emit_raw("bad", { x = 0 / 0 }) end)
		assert_false(ok_nan, "NaN rejected")
		local ok_pinf = pcall(function() ev:emit_raw("bad", { x = math.huge }) end)
		assert_false(ok_pinf, "+inf rejected")
		local ok_ninf = pcall(function() ev:emit_raw("bad", { x = -math.huge }) end)
		assert_false(ok_ninf, "-inf rejected")
		assert_eq(#ev:raw(), 0, "no partial event appended")
		ev:finish_step()
	end,

	test_reject_cyclic_table = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local cyc = { a = 1 }
		cyc.self = cyc
		local ok, err = pcall(function() ev:emit_raw("bad", { loop = cyc }) end)
		assert_false(ok, "cyclic table rejected")
		assert_true(tostring(err):find("cyclic") ~= nil, tostring(err))
		ev:finish_step()
	end,

	test_reject_unsupported_key_types = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local ok = pcall(function() ev:emit_raw("bad", { [true] = 1 }) end)
		assert_false(ok, "boolean key rejected")
		local ok2 = pcall(function() ev:emit_raw("bad", { [{}] = 1 }) end)
		assert_false(ok2, "table key rejected")
		ev:finish_step()
	end,

	test_entity_table_copied_by_value = function()
		-- A live entity-shaped table (like a ball) passed as a payload field is
		-- deep-copied: the journal never aliases the entity.
		local ev = GameplayEvents.new()
		ev:begin_step(1, 1)
		local ball = { id = 1, x = 50, y = 60, vx = 0, vy = 0 }
		ev:emit_raw("inspect", { ball = ball })
		ball.x = 9999
		assert_eq(ev:raw()[1].ball.x, 50, "entity table copied by value")
		assert_true(ev:raw()[1].ball ~= ball, "no live reference retained")
		ev:seal_raw()
		ev:finish_step()
	end,

	test_snapshot_independent_of_journal = function()
		local ev = GameplayEvents.new()
		ev:begin_step(1, 5)
		ev:emit_raw("ball_contacted_peg", { ball_id = 1, meta = { a = 1 } })
		ev:seal_raw()
		ev:emit_derived("peg_scored", { peg_id = 3 })
		local snap1 = ev:snapshot()
		-- Mutate the returned snapshot in every way: journal must not change.
		snap1.raw[1].ball_id = 999
		snap1.raw[1].meta.a = 999
		table.insert(snap1.raw, { type = "injected" })
		table.insert(snap1.derived, { type = "injected" })
		assert_eq(ev:raw()[1].ball_id, 1, "journal unaffected by snapshot mutation")
		assert_eq(ev:raw()[1].meta.a, 1)
		assert_eq(#ev:raw(), 1)
		assert_eq(#ev:derived(), 1)
		-- A second snapshot must be independent of the first.
		local snap2 = ev:snapshot()
		assert_eq(snap2.raw[1].ball_id, 1)
		assert_eq(snap2.raw[1].meta.a, 1)
		assert_eq(#snap2.raw, 1)
		assert_eq(#snap2.derived, 1)
		ev:finish_step()
	end,
}
