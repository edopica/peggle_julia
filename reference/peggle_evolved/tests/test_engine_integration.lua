-- Engine / Physics integration tests: peg scoring reduction, multiball, ordering.
local H = require("tests.helpers.engine_helpers")
local Peg = require("src.entities.peg")
local Ball = require("src.entities.ball")
local Config = require("src.config")
local LevelManager = require("src.systems.level_manager")

-- File-local helpers (test functions are called as plain functions, no self).
local function steps_of(eng, shot_id)
	local tl = eng.shot_timelines[shot_id or 1]
	return (tl and tl.steps) or {}
end

-- Build an engine with one peg, synthesize raw contact event(s) with the
-- given contact_kind(s), and run the authoritative reducer on them.
local function reduce_with_kinds(kinds, peg_setup)
	local eng = H.new_engine()
	H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
	local peg = eng.pegs[1]
	if peg_setup then peg_setup(peg) end
	eng.events:begin_step(1, 1)
	for i, kind in ipairs(kinds) do
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = kind,
			impact_x = 600, impact_y = 180, did_bounce = kind == "sweep",
		})
	end
	eng:reducePegContacts()
	return eng, peg
end

-- Build an engine whose pegs form one line (as Lines.generate would emit),
-- so the reducer can exercise shared-boundary collapse against real metadata.
local function line_chain_engine(count, gap, closed)
	closed = closed or false
	local eng = H.new_engine()
	local pegs = {}
	for i = 1, count do
		local p = Peg.new(300 + i * 40, 400, "blue", 20)
		p.line = { id = "chain", index = i, count = count, closed = closed, gap = gap or 0 }
		table.insert(pegs, p)
	end
	H.setup_engine(eng, pegs, { red = 0, green = 0 }, 1)
	return eng
end

-- Run Engine:setupLevel against an inline level table by temporarily
-- replacing LevelManager.load. Always restores the original loader.
local function setup_with_fake_level(level_data)
	local orig_load = LevelManager.load
	LevelManager.load = function() return level_data end
	local eng = H.new_engine()
	local ok, err = pcall(eng.setupLevel, eng, "fake_level")
	LevelManager.load = orig_load
	return ok, err, eng
end

local function count_derived(steps, type)
	local n = 0
	for _, rec in ipairs(steps) do
		for _, e in ipairs(rec.derived_events) do
			if e.type == type then n = n + 1 end
		end
	end
	return n
end
local function count_raw(steps, type)
	local n = 0
	for _, rec in ipairs(steps) do
		for _, e in ipairs(rec.raw_events) do
			if e.type == type then n = n + 1 end
		end
	end
	return n
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

	test_single_peg_scored_once = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		assert_eq(count_derived(steps_of(eng), "peg_scored"), 1, "single peg scored exactly once")
	end,

	test_multiple_contacts_one_peg_one_scored = function()
		local eng = H.new_engine()
		local peg = Peg.new(600, 200, "blue", 20)
		H.setup_engine(eng, { peg }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		assert_eq(count_derived(steps_of(eng), "peg_scored"), 1, "multiple contacts -> one peg_scored")
		assert_true(peg.hit, "peg was marked hit")
	end,

	test_already_hit_peg_not_scored_again = function()
		local eng = H.new_engine()
		local pegs = { Peg.new(600, 200, "blue", 20) }
		pegs[1].hit = true
		pegs[1].hit_order = 1
		H.setup_engine(eng, pegs, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 5)
		assert_eq(count_derived(steps_of(eng), "peg_scored"), 0, "already-hit peg not scored again")
	end,

	test_graze_can_score = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(624, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 10)
		assert_eq(count_derived(steps_of(eng), "peg_scored"), 1, "contact scores the peg")
	end,

	test_fever_and_multiplier_before_bucket = function()
		local eng = H.new_engine()
		local pegs = {
			Peg.new(600, 200, "red", 20),
			Peg.new(600, 350, "red", 20),
		}
		H.setup_engine(eng, pegs, { red = 2, green = 0 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		assert_eq(eng.redPegsHitAmount, 2)
		assert_true(eng.isFever, "fever entered after all reds hit")
	end,

	test_green_power_activation_outside_ccd = function()
		local eng = H.new_engine()
		local pegs = { Peg.new(600, 200, "green", 20) }
		H.setup_engine(eng, pegs, { red = 0, green = 1 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local steps = steps_of(eng)
		local ball_ids = {}
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.raw_events) do
				if e.ball_id then ball_ids[e.ball_id] = true end
			end
		end
		local count = 0
		for _ in pairs(ball_ids) do count = count + 1 end
		assert_true(count >= 2, "green power spawned balls with distinct ids")
		assert_eq(count_raw(steps, "ball_spawned"), 2, "two ball_spawned events")
	end,

	test_power_created_ball_begins_physics_next_step = function()
		local eng = H.new_engine()
		local pegs = { Peg.new(600, 200, "green", 20) }
		H.setup_engine(eng, pegs, { red = 0, green = 1 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local steps = steps_of(eng)
		local green_step = nil
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.derived_events) do
				if e.type == "peg_scored" and e.peg_type == "green" then
					green_step = rec.step
				end
			end
		end
		assert_true(green_step ~= nil, "green peg scored")
		local spawned_ids = {}
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.raw_events) do
				if e.type == "ball_spawned" then spawned_ids[e.ball_id] = true end
			end
		end
		local first_contact_step = nil
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.raw_events) do
				if e.type == "ball_contacted_peg" and spawned_ids[e.ball_id] then
					if first_contact_step == nil or rec.step < first_contact_step then
						first_contact_step = rec.step
					end
				end
			end
		end
		if first_contact_step ~= nil then
			assert_true(first_contact_step > green_step,
				"spawned ball physics begins after the green-peg step")
		end
	end,

	test_peg_scored_source_sequence_points_to_raw = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		-- Budget covers settle + no-score timeout + clearing + fall-out.
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local steps = steps_of(eng)
		local raw_seq, scored_src
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.raw_events) do
				if e.type == "ball_contacted_peg" and raw_seq == nil then
					raw_seq = e.sequence
				end
			end
			for _, e in ipairs(rec.derived_events) do
				if e.type == "peg_scored" then scored_src = e.source_sequence end
			end
		end
		assert_true(raw_seq ~= nil, "raw contact present")
		assert_eq(scored_src, raw_seq, "source_sequence points to the raw contact")
	end,

	test_raw_contact_order_preserved = function()
		local eng = H.new_engine()
		local pegs = {
			Peg.new(600, 200, "blue", 20),
			Peg.new(600, 400, "blue", 20),
			Peg.new(600, 600, "blue", 20),
		}
		H.setup_engine(eng, pegs, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		-- Budget covers settle + one no-score timeout cascade per peg + fall-out.
		H.run_shot(eng, 600, 50, 0, 800, 60 * 40)
		local steps = steps_of(eng)
		local ids = {}
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.raw_events) do
				if e.type == "ball_contacted_peg" then
					table.insert(ids, e.peg_id)
				end
			end
		end
		assert_true(#ids >= 1, "at least one contact")
		for i = 2, #ids do
			assert_true(ids[i] >= ids[i - 1], "raw contact order preserved (top to bottom)")
		end
	end,

	test_shot_completed_event_emitted = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.callbacks.onTurnEnd = function(e) e.is_halted = true end
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local found = nil
		for _, rec in ipairs(steps_of(eng)) do
			for _, e in ipairs(rec.derived_events) do
				if e.type == "shot_completed" then found = e end
			end
		end
		assert_true(found ~= nil, "shot_completed emitted")
		assert_true(found.completion_reason ~= nil, "completion_reason present")
		assert_eq(found.shot_id, 1)
		assert_true(found.peg_score ~= nil)
		assert_true(found.total_score ~= nil)
	end,

	test_timeline_step_ordering_stable = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.callbacks.onTurnEnd = function(e) e.is_halted = true end
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local step_ids = {}
		for _, rec in ipairs(steps_of(eng)) do
			table.insert(step_ids, rec.step)
		end
		for i = 2, #step_ids do
			assert_eq(step_ids[i], step_ids[i - 1] + 1, "timeline steps contiguous & ordered")
		end
	end,

	test_timeline_metadata = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.callbacks.onTurnEnd = function(e) e.is_halted = true end
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local tl = eng.shot_timelines[1]
		assert_true(tl ~= nil, "timeline retained")
		assert_eq(tl.shot_id, 1)
		assert_true(tl.initial_step ~= nil)
		assert_true(tl.final_step ~= nil)
		assert_true(tl.completion_reason ~= nil)
		assert_true(tl.step_count > 0)
	end,

	-- ===================================================================
	-- §3.4 Explicit scoring eligibility (contact kinds)
	-- ===================================================================

	test_reducer_sweep_scores = function()
		local eng, peg = reduce_with_kinds({ "sweep" })
		assert_true(peg.hit, "sweep scores")
		assert_eq(#eng.buffered_peg_scored, 1)
	end,

	test_reducer_graze_scores = function()
		-- Non-deflecting graze scored before Phase 1 and must keep scoring.
		local eng, peg = reduce_with_kinds({ "graze" })
		assert_true(peg.hit, "graze scores")
		assert_eq(#eng.buffered_peg_scored, 1)
	end,

	test_reducer_overlap_scores = function()
		-- Discrete overlap pop-out scored before Phase 1 and must keep scoring.
		local eng, peg = reduce_with_kinds({ "overlap" })
		assert_true(peg.hit, "overlap scores")
		assert_eq(#eng.buffered_peg_scored, 1)
	end,

	test_reducer_depenetrate_scores = function()
		-- End-of-step depenetration cleanup DID score previously-unhit pegs
		-- before Phase 1 (git history: old physics hit-callback fired on the
		-- depenetration site). The behavior is preserved.
		local eng, peg = reduce_with_kinds({ "depenetrate" })
		assert_true(peg.hit, "depenetration scores (historical behavior)")
		assert_eq(#eng.buffered_peg_scored, 1)
	end,

	test_reducer_unknown_kind_does_not_score = function()
		local eng, peg = reduce_with_kinds({ "tunnel" })
		assert_false(peg.hit, "unknown contact kind does not score")
		assert_eq(#eng.buffered_peg_scored, 0)
	end,

	test_reducer_already_hit_never_scores = function()
		for _, kind in ipairs({ "sweep", "graze", "overlap", "depenetrate" }) do
			local eng, peg = reduce_with_kinds({ kind }, function(p)
				p.hit = true
				p.hit_order = 1
			end)
			assert_false(eng.buffered_peg_scored[1] ~= nil,
				"already-hit peg never scores (" .. kind .. ")")
		end
	end,

	test_reducer_multiple_kinds_one_peg_scores_once = function()
		local eng, peg = reduce_with_kinds({ "sweep", "graze", "depenetrate" })
		assert_true(peg.hit)
		assert_eq(#eng.buffered_peg_scored, 1, "exactly one peg_scored for one peg")
		assert_eq(eng.buffered_peg_scored[1].contact_kind, "sweep",
			"the first contact in raw order scores")
		assert_eq(eng.buffered_peg_scored[1].source_sequence, 1)
	end,

	test_reducer_missing_peg_does_not_error = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 999, contact_kind = "sweep",
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 0, "contact with removed peg ignored")
	end,

	-- ===================================================================
	-- §3.4b Shared-boundary line reduction (zero-gap seam scoring)
	-- ===================================================================

	test_reducer_collapses_adjacent_line_seam_to_lowest_index = function()
		-- A ball crossing the seam between zero-gap line neighbors can report
		-- simultaneous contacts (same ball, line, CCD iteration) for both:
		-- a resolved winner on one and a graze on the other. Reduction must
		-- collapse them to one score; the lower line index wins.
		local eng = line_chain_engine(4)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "graze", iteration = 2,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "sweep", iteration = 2,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 1, "seam crossing scores once")
		local ps = eng.buffered_peg_scored[1]
		assert_eq(ps.peg_id, 2, "lower line index is the total-order winner")
		assert_eq(ps.peg_id, eng.pegs[2].original_index)
		assert_eq(ps.line.id, "chain")
		assert_eq(ps.line.index, 2)
		assert_eq(ps.iteration, 2)
		assert_true(eng.pegs[2].hit)
		assert_false(eng.pegs[3].hit, "higher line index suppressed")
	end,

	test_reducer_collapses_depenetration_reports_on_adjacent_seam = function()
		-- End-of-step depenetration reports all share iteration 0; two
		-- adjacent zero-gap line neighbors reported in one step collapse.
		local eng = line_chain_engine(4)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "depenetrate", iteration = 0,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 4, contact_kind = "depenetrate", iteration = 0,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 1, "paired depenetration scores once")
		assert_eq(eng.buffered_peg_scored[1].peg_id, 3, "lowest index wins")
	end,

	test_reducer_collapses_closed_line_wrap_seam = function()
		local eng = line_chain_engine(8, 0, true)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 8, contact_kind = "sweep", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "graze", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 1, "closed seam wrap scores once")
		assert_eq(eng.buffered_peg_scored[1].peg_id, 1,
			"closed wrap collapses to index 1")
	end,

	test_reducer_no_collapse_across_different_iterations = function()
		-- Same ball and line but different CCD iterations are sequential
		-- contacts, not one shared-boundary crossing: both score.
		local eng = line_chain_engine(4)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "sweep", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "sweep", iteration = 3,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 2, "different iterations both score")
	end,

	test_reducer_no_collapse_for_nonadjacent_indices = function()
		-- Simultaneous contacts on non-adjacent line indices (physically two
		-- distinct pegs) score independently.
		local eng = line_chain_engine(5)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "graze", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 4, contact_kind = "graze", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 2, "non-adjacent simultaneous scores kept")
	end,

	test_suppressed_seam_peg_scores_on_a_later_step = function()
		-- A peg dropped by a seam collapse in step 1 was never scored, so a
		-- genuine contact on a later step (fresh reduction pass) still scores
		-- it. Within one step the peg's first raw contact is authoritative.
		local eng = line_chain_engine(4)
		-- Step 1: seam crossing collapses to the lower index.
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "graze", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "sweep", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 1, "seam scores once")
		assert_true(eng.pegs[2].hit)
		assert_false(eng.pegs[3].hit, "collapsed peg not scored in step 1")
		-- Step 2: the ball genuinely contacts peg 3 again; it scores now.
		eng.events:begin_step(2, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "sweep", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 1, "later-step contact scores once")
		assert_true(eng.pegs[3].hit, "peg scores on the later genuine contact")
		assert_eq(eng.buffered_peg_scored[1].peg_id, 3)
	end,

	test_reducer_different_lines_do_not_collapse = function()
		-- Two distinct lines contacted simultaneously by one ball are two
		-- independent seams: each scores.
		local eng = H.new_engine()
		local pegs = {
			Peg.new(600, 400, "blue", 20),
			Peg.new(700, 400, "blue", 20),
		}
		pegs[1].line = { id = "a", index = 1, count = 2, closed = false, gap = 0 }
		pegs[2].line = { id = "b", index = 1, count = 2, closed = false, gap = 0 }
		H.setup_engine(eng, pegs, { red = 0, green = 0 }, 1)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, contact_kind = "graze", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "graze", iteration = 1,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 2, "cross-line contacts both score")
	end,

	test_physics_contacts_and_peg_scored_carry_line_metadata = function()
		-- Real physics: a generated line peg's metadata rides through the raw
		-- contact event and the derived peg_scored payload.
		local eng = H.new_engine()
		local p = Peg.new(600, 200, "blue", 20)
		p.line = { id = "rail", index = 4, count = 7, closed = false, gap = 0 }
		H.setup_engine(eng, { p }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local raw_contact, scored
		for _, rec in ipairs(steps_of(eng)) do
			for _, e in ipairs(rec.raw_events) do
				if e.type == "ball_contacted_peg" and not raw_contact then
					raw_contact = e
				end
			end
			for _, e in ipairs(rec.derived_events) do
				if e.type == "peg_scored" and not scored then scored = e end
			end
		end
		assert_true(raw_contact ~= nil, "raw contact emitted")
		assert_eq(raw_contact.line.id, "rail")
		assert_eq(raw_contact.line.index, 4)
		assert_eq(raw_contact.line.count, 7)
		assert_false(raw_contact.line.closed)
		assert_eq(raw_contact.line.gap, 0)
		assert_true(scored ~= nil, "peg_scored emitted")
		assert_eq(scored.line.id, "rail")
		assert_eq(scored.line.index, 4)
		assert_eq(scored.line.count, 7)
		assert_eq(scored.line.gap, 0)
		assert_true(scored.iteration ~= nil, "peg_scored carries the CCD iteration")
	end,

	test_vertical_rail_shot_awards_slide_in_real_physics = function()
		-- The slide.lua geometry: a vertical zero-gap circle rail offset one
		-- quarter pixel inside the graze band of the launch column. The ball
		-- drops straight down, grazing and scoring consecutive line pegs
		-- without any bounce; five adjacent scores award the slide style.
		local Path = require("src.systems.path")
		local Lines = require("src.systems.lines")
		local eng = H.new_engine()
		local rail = Path.new({
			{ kind = "line", p0 = { 583.75, 220 }, p1 = { 583.75, 980 } },
		})
		local pegs = Lines.generate({
			id = "slide_rail", path = rail,
			peg = { kind = "circle", radius = 10 }, gap = 0,
		})
		assert_true(#pegs >= 5, "rail holds at least five line pegs")
		H.setup_engine(eng, pegs, { red = 0, green = 0 }, 1)
		local steps = H.make_recorder(eng)
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)

		-- The five contributing contacts are all non-bouncing line grazes.
		local scored_line = {}
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.derived_events) do
				if e.type == "peg_scored" and e.line then
					table.insert(scored_line, e)
				end
			end
		end
		assert_true(#scored_line >= 5, "at least five line pegs scored")
		local indices = {}
		for _, e in ipairs(scored_line) do
			if not indices[e.line.index] then
				indices[e.line.index] = true
			end
		end
		local adjacent_count = 0
		for i = 1, #scored_line + 1 do
			if indices[i] then
				adjacent_count = adjacent_count + 1
				if adjacent_count >= 5 then break end
			else
				adjacent_count = 0
			end
		end
		assert_true(adjacent_count >= 5,
			"scored indices include five consecutive line members")

		local slide_awarded
		for _, rec in ipairs(steps) do
			for _, e in ipairs(rec.derived_events) do
				if e.type == "style_awarded" and e.style == "slide" then
					slide_awarded = e
				end
			end
		end
		assert_true(slide_awarded ~= nil, "slide style_awarded event exists")
		assert_eq(slide_awarded.line_id, "slide_rail")
		assert_eq(slide_awarded.source_sequences ~= nil and #slide_awarded.source_sequences, 5,
			"award carries five contributing sequences")
		assert_eq(eng.styleScore, Config.slide_points,
			"engine style score includes the slide award")
	end,

	-- ===================================================================
	-- §3.5 Correct shot-completion scoring
	-- ===================================================================

	test_shot_completed_totals_match_authoritative_state = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.retain_shot_timeline = true
		eng.callbacks.onTurnEnd = function(e) e.is_halted = true end
		H.run_shot(eng, 600, 50, 0, 800, 60 * 20)
		local found
		for _, rec in ipairs(steps_of(eng)) do
			for _, e in ipairs(rec.derived_events) do
				if e.type == "shot_completed" then found = e end
			end
		end
		assert_true(found ~= nil)
		assert_eq(found.style_score, eng.styleScore, "event style == engine style")
		assert_eq(found.peg_score, eng:getTurnPegScore(), "event peg score == engine")
		assert_eq(found.bonus_score, eng.bonusScore, "event bonus == engine")
		assert_eq(found.total_score, eng:getTurnScore(),
			"shot_completed.total_score == Engine:getTurnScore()")
		assert_eq(found.total_score,
			found.peg_score + found.bonus_score + found.style_score,
			"total is the sum of components")
	end,

	test_style_award_on_final_step_not_double_counted = function()
		-- Regression (§3.5): a style award earned on the shot's FINAL fixed
		-- step must be counted exactly once. Commands are applied (phase 20)
		-- before shot_completed is emitted (phase 21), so Engine.styleScore
		-- already includes the award; emitShotCompleted must not add it again.
		-- Scenario: bucket bounce (step 1) then bucket catch (step 2) -> the
		-- lucky-bounce award lands on the shot's final step.
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.shot_id = 1
		eng.shot_initial_step = 1
		-- Step 1: bucket bounce (real pipeline: begin -> raw -> finalize).
		eng.sim_step_id = 1
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:emit_raw("bucket_bounced_ball", {
			ball_id = 1, x = 600, y = 1800,
			incoming_vx = 0, incoming_vy = 500,
			outgoing_vx = 0, outgoing_vy = -400,
			bucket_x = 600,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 1, peg_type = "blue",
			peg_shape = "circle", contact_kind = "sweep",
			did_bounce = true, impact_x = 600, impact_y = 1750,
		})
		eng:finalizeStep(Config.fixed_dt)
		-- Step 2: bucket catch; the ball is removed and the shot ends here.
		eng.sim_step_id = 2
		eng.events:begin_step(2, 1)
		eng.commands:begin_step(2, 1)
		eng.events:emit_raw("bucket_caught_ball", {
			ball_id = 1, x = 600, y = 1850,
			incoming_vx = 0, incoming_vy = 500,
			outgoing_vx = 0, outgoing_vy = 500,
			bucket_x = 600,
		})
		eng.active_balls = {}
		eng.last_removal_reason = "bucket_caught"
		eng.shot_end_reason = "bucket_caught"
		eng.shot_end_pending = true
		eng:finalizeStep(Config.fixed_dt)

		assert_eq(eng.styleScore, Config.lucky_bounce_points,
			"lucky bounce applied exactly once")
		local completed
		for _, e in ipairs(eng.events:derived()) do
			if e.type == "shot_completed" then completed = e end
		end
		assert_true(completed ~= nil, "shot_completed emitted on the final step")
		assert_eq(completed.style_score, eng.styleScore,
			"no double count of the final-step award")
		assert_eq(completed.style_score, Config.lucky_bounce_points)
		assert_eq(completed.total_score, eng:getTurnScore(),
			"total equals authoritative turn score")
	end,

	-- ===================================================================
	-- §3.6 Requested vs applied commands
	-- ===================================================================

	test_midturn_clearing_idempotent_with_statuses = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		local peg = eng.pegs[1]
		peg.hit = true
		peg.hit_order = 1
		eng.commands:begin_step(5, 1)
		eng.commands:push("start_midturn_clearing", { reason = "all_balls_became_idle" })
		eng.commands:push("start_midturn_clearing", { reason = "no_score_timeout_reached" })
		eng:applyCommands()
		-- Requested: both requests remain visible.
		assert_eq(#eng.commands:all(), 2, "requested list shows both requests")
		-- Applied: every processed command journaled with a scalar status.
		local applied = eng.commands:applied_snapshot()
		assert_eq(#applied, 2)
		assert_eq(applied[1].status, "applied", "first request applied")
		assert_eq(applied[2].status, "ignored_duplicate",
			"duplicate is journaled as ignored, not as applied")
		-- Clearing initialized at most once.
		assert_true(eng.clearQueue ~= nil, "clearing started")
		assert_eq(#eng.clearQueue, 1, "each hit peg queued exactly once")
	end,

	test_clearing_request_during_active_clearing_is_ignored = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		local peg = eng.pegs[1]
		peg.hit = true
		peg.hit_order = 1
		eng:startClearing(false) -- clearing already active
		local queue_len = #eng.clearQueue
		eng.commands:begin_step(6, 1)
		eng.commands:push("start_midturn_clearing", { reason = "all_balls_became_idle" })
		eng:applyCommands()
		local applied = eng.commands:applied_snapshot()
		assert_eq(applied[1].status, "ignored_duplicate",
			"request during active clearing is ignored")
		assert_eq(#eng.clearQueue, queue_len, "existing cascade untouched")
	end,

	-- ===================================================================
	-- Deferred presentation notification for style awards
	-- ===================================================================

	test_on_style_shot_notified_after_application = function()
		local notifications = {}
		local eng = H.new_engine({
			onStyleShot = function(e, award)
				table.insert(notifications, {
					style = award.style,
					points = award.points,
					ball_id = award.ball_id,
					source_sequences = award.source_sequences,
					style_score_at_notify = e.styleScore,
				})
			end,
		})
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.events:begin_step(1, 1)
		eng.commands:begin_step(1, 1)
		eng.events:seal_raw()
		eng.commands:push("award_style_points", {
			ball_id = 3, style = "long_shot", points = 1000, distance = 450,
			source_sequences = { 1, 2 },
		})
		assert_eq(#notifications, 0, "no notification before application")
		eng:applyCommands()
		assert_eq(#notifications, 1, "exactly one deferred notification")
		assert_eq(notifications[1].style, "long_shot")
		assert_eq(notifications[1].points, 1000)
		assert_eq(notifications[1].ball_id, 3)
		assert_eq(notifications[1].style_score_at_notify, 1000,
			"notification fires AFTER the award is authoritatively applied")
		assert_eq(notifications[1].source_sequences[1], 1)
		-- style_awarded derived event was emitted too.
		local saw
		for _, e in ipairs(eng.events:derived()) do
			if e.type == "style_awarded" then saw = e end
		end
		assert_true(saw ~= nil, "style_awarded derived event emitted")
		assert_eq(saw.points, 1000)
		assert_eq(saw.source_sequences[1], 1)
		eng.events:finish_step()
	end,

	-- ===================================================================
	-- §3.1 Power-spawn IDs after resetTurn-supplied IDs
	-- ===================================================================

	test_power_spawn_id_after_reset_turn_ids = function()
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		local b1 = Ball.new(100, 50); b1.id = 41
		local b2 = Ball.new(200, 50); b2.id = 42
		eng:resetTurn({ b1, b2 })
		-- A power-created ball (unIDed) must not reuse resetTurn-supplied IDs.
		local spawned = eng:registerBall(Ball.new(600, 190))
		assert_eq(spawned.id, 43, "power spawn gets fresh id after resetTurn ids")
	end,

	-- ===================================================================
	-- §3.7 Runtime line-metadata validation in setupLevel
	-- ===================================================================

	test_setup_level_rejects_malformed_line_metadata = function()
		local level_data = {
			virtual_width = 1200, virtual_height = 1900,
			type_counts = { red = 0, green = 0 },
			pegs = {
				{ x = 600, y = 200, type = "blue", radius = 20,
					line = { id = "bad", index = "oops", count = 1, closed = false, gap = 0 } },
			},
		}
		local ok = setup_with_fake_level(level_data)
		assert_false(ok, "setupLevel rejects malformed line metadata")
	end,

	test_setup_level_rejects_stale_line_group_after_boundary_filter = function()
		local level_data = {
			virtual_width = 1200, virtual_height = 1900,
			type_counts = { red = 0, green = 0 },
			pegs = {
				{ x = -100, y = 400, type = "blue", radius = 20,
					line = { id = "stale", index = 1, count = 2, closed = false, gap = 0 } },
				{ x = 400, y = 400, type = "blue", radius = 20,
					line = { id = "stale", index = 2, count = 2, closed = false, gap = 0 } },
			},
		}
		local ok = setup_with_fake_level(level_data)
		assert_false(ok, "setupLevel rejects stale line metadata after filtering")
	end,

	test_setup_level_accepts_valid_zero_gap_circle_line = function()
		local level_data = {
			virtual_width = 1200, virtual_height = 1900,
			type_counts = { red = 0, green = 0 },
			pegs = {
				{ x = 400, y = 400, type = "blue", radius = 20,
					line = { id = "ok", index = 1, count = 2, closed = false, gap = 0 } },
				{ x = 440, y = 400, type = "blue", radius = 20,
					line = { id = "ok", index = 2, count = 2, closed = false, gap = 0 } },
			},
		}
		local ok, err, eng = setup_with_fake_level(level_data)
		assert_true(ok, "valid zero-gap circle line sets up: " .. tostring(err))
		assert_eq(#eng.pegs, 2, "both line pegs survive setup")
	end,

	-- ===================================================================
	-- §3.4c Suppressed seam peg scores from a later independent contact
	-- ===================================================================

	test_suppressed_seam_peg_scores_from_later_independent_contact = function()
		-- Peg 3's only iteration-1 candidate is suppressed by the seam
		-- collapse with peg 2, but its iteration-2 contact is an independent
		-- crossing and must still score.
		local eng = line_chain_engine(4)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "graze", iteration = 1, toi = 0.01,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "graze", iteration = 1, toi = 0.01,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "sweep", iteration = 2, toi = 0.5,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 2,
			"seam-collapsed peg still scores from its later independent contact")
		assert_true(eng.pegs[2].hit, "lower index wins the seam collapse")
		assert_true(eng.pegs[3].hit, "peg 3 scores from its iteration-2 contact")
	end,

	test_same_iteration_duplicate_contacts_suppress_peg_once = function()
		-- Two contacts for peg 3 in the SAME suppressed iteration must not
		-- break the contiguous-run detection or score peg 3 at all.
		local eng = line_chain_engine(4)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "graze", iteration = 1, toi = 0.01,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "graze", iteration = 1, toi = 0.01,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "sweep", iteration = 1, toi = 0.02,
			impact_x = 0, impact_y = 0, did_bounce = true,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 1,
			"same-iteration duplicate contacts stay suppressed")
		assert_true(eng.pegs[2].hit, "lower index wins")
		assert_false(eng.pegs[3].hit, "duplicate-contact peg suppressed")
	end,

	-- ===================================================================
	-- §3.4d Positive-gap neighbors never collapse (regression)
	-- ===================================================================

	test_reducer_positive_gap_neighbors_do_not_collapse = function()
		-- Positive-gap line neighbors are physically distinct contacts; both
		-- score even in the same ball/iteration.
		local eng = line_chain_engine(4, 6)
		eng.events:begin_step(1, 1)
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 2, contact_kind = "graze", iteration = 1, toi = 0.01,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = 3, contact_kind = "graze", iteration = 1, toi = 0.01,
			impact_x = 0, impact_y = 0, did_bounce = false,
		})
		eng:reducePegContacts()
		assert_eq(#eng.buffered_peg_scored, 2,
			"positive-gap neighbors both score")
	end,
}
