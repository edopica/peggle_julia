-- Step record ownership tests: verify that finalized step records are detached
-- from the working journal and that onStepFinalized callback isolation holds.
local H = require("tests.helpers.engine_helpers")
local Peg = require("src.entities.peg")
local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")

-- Recursively check that a value contains no functions, userdata, or threads.
local function has_no_live_refs(v, path)
	local t = type(v)
	if t == "function" or t == "userdata" or t == "thread" then
		return false, "live reference at " .. path .. ": " .. t
	elseif t == "table" then
		for k, vv in pairs(v) do
			local ok, err = has_no_live_refs(k, path .. ".key")
			if not ok then return false, err end
			ok, err = has_no_live_refs(vv, path .. "." .. tostring(k))
			if not ok then return false, err end
		end
	end
	return true
end

return {
	setup = function()
		LevelManager.virtual_width = 1200
		LevelManager.virtual_height = 1900
		Config.virtual_width = 1200
		Config.virtual_height = 1900
		Config.gravity = 1000
		Config.launch_speed = 800
	end,

	-- 1. Producer-side payload mutation after emit does not change the journal.
	--    (Confirms existing behavior is preserved.)
	test_producer_payload_ownership_end_to_end = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.shot_id = 1
		eng.events:begin_step(1, 1)
		local payload = { ball_id = 1, impact_x = 10, meta = { a = 1 } }
		eng.events:emit_raw("ball_contacted_peg", payload)
		payload.ball_id = 999
		payload.impact_x = -1
		payload.meta.a = 999
		payload.injected = "nope"
		local stored = eng.events:raw()[1]
		assert_eq(stored.ball_id, 1, "journal owns its copy — ball_id unchanged")
		assert_eq(stored.impact_x, 10)
		assert_eq(stored.meta.a, 1)
		assert_eq(stored.injected, nil)
		eng.events:seal_raw()
		eng.events:finish_step()
	end,

	-- 2. snapshot() independence: mutating returned snapshot does not change
	--    the journal.
	test_snapshot_independent_of_journal = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.shot_id = 1
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", { ball_id = 1, meta = { a = 1 } })
		eng.events:seal_raw()
		eng.events:emit_derived("peg_scored", { peg_id = 3 })
		local snap = eng.events:snapshot()
		snap.raw[1].ball_id = 999
		snap.raw[1].meta.a = 999
		table.insert(snap.raw, { type = "injected" })
		table.insert(snap.derived, { type = "injected" })
		assert_eq(eng.events:raw()[1].ball_id, 1)
		assert_eq(eng.events:raw()[1].meta.a, 1)
		assert_eq(#eng.events:raw(), 1)
		assert_eq(#eng.events:derived(), 1)
		eng.events:finish_step()
	end,

	-- 3. Finalized step record arrays are distinct from the journal's current
	--    arrays.
	test_step_record_not_alias_journal_arrays = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		local rec = eng.current_shot_timeline[1]
		assert_true(rec ~= nil, "step recorded")
		assert_true(rec.raw_events ~= eng.events:raw(),
			"record raw_events distinct from journal raw array")
		assert_true(rec.derived_events ~= eng.events:derived(),
			"record derived_events distinct from journal derived array")
	end,

	-- 4. Journal mutation after finalization does not affect the retained
	--    record; the record was built from a detached snapshot.
	test_journal_mutation_does_not_affect_retained = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		local rec = eng.current_shot_timeline[1]
		-- Mutate the journal's events (still in the current-step arrays).
		if eng.events:raw()[1] then
			eng.events:raw()[1].ball_id = 99999
			eng.events:raw()[1].did_bounce = not eng.events:raw()[1].did_bounce
		end
		if eng.events:derived()[1] then
			eng.events:derived()[1].peg_id = 99999
		end
		-- The retained record must hold the original values.
		assert_eq(rec.raw_events[1].ball_id, 1,
			"retained ball_id unaffected by journal mutation")
		assert_eq(rec.raw_events[1].did_bounce, true,
			"retained did_bounce unaffected by journal mutation")
		if rec.derived_events[1] then
			assert_eq(rec.derived_events[1].peg_id, 1,
				"retained peg_scored unaffected by journal mutation")
		end
	end,

	-- 5. A retained step record survives a subsequent step without change.
	test_retained_record_survives_next_step = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		-- Step 1.
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		local rec1 = eng.current_shot_timeline[1]
		local raw1_len = #rec1.raw_events
		local raw1_ball_id = rec1.raw_events[1] and rec1.raw_events[1].ball_id
		-- Step 2: a different step that creates new journal arrays.
		eng.sim_step_id = 2
		eng.events:begin_step(2, 1)
		eng.commands:begin_step(2, 1)
		eng.events:seal_raw()
		eng:finalizeStep(Config.fixed_dt)
		-- Step 1 retained record must be unchanged.
		assert_eq(#rec1.raw_events, raw1_len, "retained raw length unchanged")
		assert_eq(rec1.raw_events[1].ball_id, raw1_ball_id,
			"retained event data unchanged after next step")
		assert_eq(rec1.step, 1, "retained step id unchanged")
	end,

	-- 6. Callback mutation of step_record does not affect the retained
	--    timeline record.
	test_callback_isolated_from_timeline = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		local cb_record = nil
		eng.callbacks.onStepFinalized = function(_, rec)
			cb_record = rec
			-- Mutate every reachable part of the callback's record.
			rec.step = 99999
			rec.shot_id = 99999
			if rec.raw_events[1] then
				rec.raw_events[1].ball_id = 99999
				rec.raw_events[1].did_bounce = not rec.raw_events[1].did_bounce
			end
			if #rec.derived_events > 0 then
				rec.derived_events[1].peg_id = 99999
			end
			rec.raw_events[99] = { type = "injected_raw" }
			rec.derived_events[99] = { type = "injected_derived" }
			rec.requested_commands[99] = { type = "injected_cmd" }
			rec.applied_commands[99] = { type = "injected_applied" }
			if rec.snapshot then
				rec.snapshot.step_id = 99999
			end
		end
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		local retained = eng.current_shot_timeline[1]
		assert_true(retained ~= nil, "retained record exists")
		-- All original values must be intact.
		assert_eq(retained.step, 1, "step intact")
		assert_eq(retained.shot_id, 1, "shot_id intact")
		if retained.raw_events[1] then
			assert_eq(retained.raw_events[1].ball_id, 1, "event ball_id intact")
			assert_eq(retained.raw_events[1].did_bounce, true, "event did_bounce intact")
		end
		assert_eq(#retained.raw_events, 1, "raw_events length intact")
		assert_eq(retained.raw_events[99], nil, "no injected raw event in retained")
		assert_eq(retained.derived_events[99], nil, "no injected derived event in retained")
		assert_eq(retained.requested_commands[99], nil, "no injected command in retained")
		assert_eq(retained.applied_commands[99], nil, "no injected applied cmd in retained")
	end,

	-- 7. Distinct identity: callback record and retained record are different
	--    objects, and their internal arrays and event tables are distinct.
	test_callback_and_retained_distinct_identity = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		local cb_record = nil
		eng.callbacks.onStepFinalized = function(_, rec)
			cb_record = rec
		end
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		local retained = eng.current_shot_timeline[1]
		assert_true(cb_record ~= nil, "callback received a record")
		assert_true(cb_record ~= retained,
			"callback record is distinct object from retained")
		assert_true(cb_record.raw_events ~= retained.raw_events,
			"callback raw_events array distinct from retained")
		assert_true(cb_record.derived_events ~= retained.derived_events,
			"callback derived_events array distinct from retained")
		if #retained.raw_events > 0 and #cb_record.raw_events > 0 then
			assert_true(cb_record.raw_events[1] ~= retained.raw_events[1],
				"callback event tables distinct from retained event tables")
		end
		if #retained.derived_events > 0 and #cb_record.derived_events > 0 then
			assert_true(cb_record.derived_events[1] ~= retained.derived_events[1],
				"callback derived event tables distinct from retained")
		end
	end,

	-- 8. Callback command record mutation does not affect retained command records.
	test_callback_command_mutation_isolated = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		eng.callbacks.onStepFinalized = function(_, rec)
			rec.requested_commands[99] = { type = "injected" }
			rec.applied_commands[99] = { type = "injected" }
			if rec.requested_commands[1] then
				rec.requested_commands[1].step = 99999
			end
			if rec.applied_commands[1] then
				rec.applied_commands[1].status = "mutated"
			end
		end
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		local retained = eng.current_shot_timeline[1]
		assert_eq(retained.requested_commands[99], nil,
			"no injected requested command in retained")
		assert_eq(retained.applied_commands[99], nil,
			"no injected applied command in retained")
		if retained.requested_commands[1] then
			assert_eq(retained.requested_commands[1].step, 1,
				"retained command step unchanged")
		end
	end,

	-- 9. Callback mutation of step_record does not change the journal.
	test_callback_isolated_from_journal = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.callbacks.onStepFinalized = function(_, rec)
			rec.raw_events[99] = { type = "injected" }
			if rec.raw_events[1] then
				rec.raw_events[1].ball_id = 99999
			end
			rec.derived_events[99] = { type = "injected" }
		end
		eng.shot_id = 1
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		-- Journal must be completely unaffected by callback mutation.
		assert_eq(#eng.events:raw(), 1, "journal raw length unchanged")
		assert_eq(eng.events:raw()[1].ball_id, 1,
			"journal event ball_id unchanged")
		assert_eq(#eng.events:derived(), 1, "journal derived length unchanged")
	end,

	-- 10. No-consumer fast path: when retention, trace, and callback are all
	--     disabled, snapshot() is NOT called and no step record is built.
	test_no_consumer_fast_path = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = false
		eng.current_shot_timeline = nil
		eng.trace_exporter = nil
		eng.callbacks.onStepFinalized = nil
		local snapshot_calls = 0
		local orig_snapshot = eng.events.snapshot
		eng.events.snapshot = function(self)
			snapshot_calls = snapshot_calls + 1
			return orig_snapshot(self)
		end
		eng.shot_id = 1
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:seal_raw()
		eng:finalizeStep(Config.fixed_dt)
		assert_eq(snapshot_calls, 0,
			"snapshot() not called in no-consumer path")
		eng.events.snapshot = orig_snapshot
	end,

	-- 11. When only onStepFinalized is active, snapshot() IS called to build
	--     the detached record (the callback is a consumer), but simulation
	--     snapshot capture is still skipped (snapshot = nil).
	test_callback_alone_triggers_event_snapshot = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = false
		eng.current_shot_timeline = nil
		eng.trace_exporter = nil
		local cb_called = false
		local cb_snapshot_val = "NOT_SET"
		eng.callbacks.onStepFinalized = function(_, rec)
			cb_called = true
			cb_snapshot_val = rec.snapshot
		end
		local snapshot_calls = 0
		local orig_snapshot = eng.events.snapshot
		eng.events.snapshot = function(self)
			snapshot_calls = snapshot_calls + 1
			return orig_snapshot(self)
		end
		eng.shot_id = 1
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:seal_raw()
		eng:finalizeStep(Config.fixed_dt)
		assert_eq(snapshot_calls, 1,
			"event snapshot() called when callback consumer exists")
		assert_true(cb_called, "callback was called")
		assert_eq(cb_snapshot_val, nil,
			"simulation snapshot is nil when callback is the only consumer")
		eng.events.snapshot = orig_snapshot
	end,

	-- 12. Empty steps (no raw or derived events) produce valid detached records.
	test_empty_step_detachment = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:seal_raw()
		eng:finalizeStep(Config.fixed_dt)
		local rec = eng.current_shot_timeline[1]
		assert_true(rec ~= nil, "empty step produces a record")
		assert_eq(#rec.raw_events, 0, "empty raw_events")
		assert_eq(#rec.derived_events, 0, "empty derived_events")
		assert_eq(rec.step, 1)
		assert_eq(rec.shot_id, 1)
		assert_true(rec.raw_events ~= eng.events:raw(),
			"empty raw_events distinct from journal array")
		assert_true(rec.derived_events ~= eng.events:derived(),
			"empty derived_events distinct from journal array")
	end,

	-- 13. Retained and callback step records contain only exportable plain data
	--     (no functions, userdata, threads).
	test_no_live_references_in_retained_and_callback = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		local cb_rec = nil
		eng.callbacks.onStepFinalized = function(_, rec)
			cb_rec = rec
		end
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "sweep",
			impact_x = 600, impact_y = 200, did_bounce = true,
		})
		eng:reducePegContacts()
		eng:finalizeStep(Config.fixed_dt)
		local rec = eng.current_shot_timeline[1]
		local ok, err = has_no_live_refs(rec, "retained_record")
		assert_true(ok, "retained record: " .. (err or "clean"))
		ok, err = has_no_live_refs(cb_rec, "callback_record")
		assert_true(ok, "callback record: " .. (err or "clean"))
	end,

	-- 14. Event ordering and sequence numbers are preserved by detachment.
	test_event_ordering_preserved = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.shot_id = 1
		eng.current_shot_timeline = {}
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("a", { n = 1 })
		eng.events:emit_raw("b", { n = 2 })
		eng.events:emit_raw("c", { n = 3 })
		eng.events:seal_raw()
		eng.events:emit_derived("d", { n = 4 })
		eng.events:emit_derived("e", { n = 5 })
		eng:finalizeStep(Config.fixed_dt)
		local rec = eng.current_shot_timeline[1]
		-- All raw events still have phase = "raw".
		for _, e in ipairs(rec.raw_events) do
			assert_eq(e.phase, "raw")
		end
		-- All derived events still have phase = "derived".
		for _, e in ipairs(rec.derived_events) do
			assert_eq(e.phase, "derived")
		end
		-- Sequences are strictly increasing and contiguous.
		local seqs = {}
		for _, e in ipairs(rec.raw_events) do
			table.insert(seqs, e.sequence)
		end
		for _, e in ipairs(rec.derived_events) do
			table.insert(seqs, e.sequence)
		end
		assert_eq(#seqs, 5, "all 5 events present")
		for i = 2, #seqs do
			assert_true(seqs[i] > seqs[i - 1],
				"sequences strictly increasing")
			assert_eq(seqs[i], seqs[i - 1] + 1,
				"sequences contiguous")
		end
		-- Types preserved in order.
		assert_eq(rec.raw_events[1].type, "a")
		assert_eq(rec.raw_events[2].type, "b")
		assert_eq(rec.raw_events[3].type, "c")
		assert_eq(rec.derived_events[1].type, "d")
		assert_eq(rec.derived_events[2].type, "e")
	end,
}
