-- GameplayCommands unit tests.
local GameplayCommands = require("src.systems.gameplay_commands")

return {
	test_sequence_and_envelope = function()
		local c = GameplayCommands.new()
		c:begin_step(5, 2)
		c:push("award_style_points", { points = 100 })
		c:push("start_midturn_clearing", { reason = "all_balls_became_idle" })
		local all = c:all()
		assert_eq(#all, 2)
		assert_eq(all[1].sequence, 1)
		assert_eq(all[2].sequence, 2)
		assert_eq(all[1].step, 5)
		assert_eq(all[1].shot_id, 2)
		assert_eq(all[1].type, "award_style_points")
		assert_eq(all[1].points, 100)
		c:clear()
	end,

	test_clear_between_steps = function()
		local c = GameplayCommands.new()
		c:begin_step(1, 1)
		c:push("x", {})
		c:clear()
		c:begin_step(2, 1)
		assert_eq(#c:all(), 0, "no leak between steps")
		c:clear()
	end,

	test_applied_snapshot = function()
		local c = GameplayCommands.new()
		c:begin_step(1, 1)
		c:push("award_style_points", { points = 50 })
		local cmd = c:all()[1]
		c:record_applied(cmd)
		local applied = c:applied_snapshot()
		assert_eq(#applied, 1)
		assert_eq(applied[1].points, 50)
		c:clear()
	end,

	test_instance_isolation = function()
		local a = GameplayCommands.new()
		local b = GameplayCommands.new()
		a:begin_step(1, 1)
		a:push("x", {})
		b:begin_step(1, 1)
		assert_eq(#b:all(), 0)
		assert_eq(#a:all(), 1)
		a:clear(); b:clear()
	end,

	test_snapshot_is_copy = function()
		local c = GameplayCommands.new()
		c:begin_step(1, 1)
		c:push("award_style_points", { points = 10 })
		local snap = c:snapshot()
		snap[1].points = 999
		-- Mutating the snapshot must not affect the original.
		assert_eq(c:all()[1].points, 10, "snapshot is an independent copy")
		c:clear()
	end,

	-- ===================================================================
	-- Payload ownership & applied statuses (§3.3, §3.6)
	-- ===================================================================

	test_push_deep_copies_array_payload = function()
		local c = GameplayCommands.new()
		c:begin_step(1, 1)
		local seqs = { 3, 7 }
		c:push("award_style_points", { style = "double_long_shot", source_sequences = seqs })
		seqs[1] = 999
		seqs[3] = 5
		local cmd = c:all()[1]
		assert_eq(cmd.source_sequences[1], 3, "array payload deep-copied at push")
		assert_eq(#cmd.source_sequences, 2)
		assert_true(cmd.source_sequences ~= seqs, "no reference retained")
		c:clear()
	end,

	test_push_rejects_invalid_payload = function()
		local c = GameplayCommands.new()
		c:begin_step(1, 1)
		local ok = pcall(function() c:push("bad", { x = math.huge }) end)
		assert_false(ok, "non-finite number rejected")
		local ok2 = pcall(function() c:push("bad", { f = function() end }) end)
		assert_false(ok2, "function rejected")
		assert_eq(#c:all(), 0, "rejected push leaves buffer untouched")
		c:clear()
	end,

	test_applied_records_status = function()
		local c = GameplayCommands.new()
		c:begin_step(1, 1)
		c:push("start_midturn_clearing", { reason = "all_balls_became_idle" })
		c:push("start_midturn_clearing", { reason = "all_balls_became_idle" })
		c:record_applied(c:all()[1], "applied")
		c:record_applied(c:all()[2], "ignored_duplicate")
		local applied = c:applied_snapshot()
		assert_eq(#applied, 2)
		assert_eq(applied[1].status, "applied")
		assert_eq(applied[2].status, "ignored_duplicate")
		c:clear()
	end,

	test_applied_snapshot_independent = function()
		local c = GameplayCommands.new()
		c:begin_step(1, 1)
		c:push("award_style_points", { points = 10, source_sequences = { 1, 2 } })
		c:record_applied(c:all()[1], "applied")
		local snap = c:applied_snapshot()
		snap[1].points = 999
		snap[1].source_sequences[1] = 999
		snap[1].status = "mutated"
		local snap2 = c:applied_snapshot()
		assert_eq(snap2[1].points, 10, "applied snapshot is independent")
		assert_eq(snap2[1].source_sequences[1], 1)
		assert_eq(snap2[1].status, "applied")
		c:clear()
	end,
}
