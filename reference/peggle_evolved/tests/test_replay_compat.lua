-- Replay compatibility tests (§3.2): ball-ID capture/preservation, old-format
-- captures, active-shot identity for in-progress replay shots.
local H = require("tests.helpers.engine_helpers")
local Peg = require("src.entities.peg")
local Ball = require("src.entities.ball")
local Replay = require("src.systems.replay")
local Circuits = require("src.systems.circuits")
local Bucket = require("src.entities.bucket")
local LevelManager = require("src.systems.level_manager")
local Config = require("src.config")

local CAPTURE_FILE = "temp/test_replay_capture.lua"
local SCORING_CAPTURE_FILE = "/tmp/opencode/test_replay_scoring.lua"

local function near(a, b, eps)
	eps = eps or 1e-9
	return math.abs(a - b) <= eps
end

local function fresh_engine()
	local eng = H.new_engine()
	H.setup_engine(eng, {
		Peg.new(600, 200, "blue", 20),
		Peg.new(300, 500, "red", 20),
	}, { red = 1, green = 0 }, 1)
	return eng
end

local function make_replay_data(with_ids)
	local balls = {}
	for i = 1, 2 do
		local rb = { x = 100 * i, y = 50, vx = 10, vy = 20 }
		if with_ids then rb.id = 40 + i end
		table.insert(balls, rb)
	end
	return {
		level_name = "test",
		isFever = false,
		pegs = {
			{ original_index = 1, type = "blue", hit = false },
			{ original_index = 2, type = "red", hit = true },
		},
		bucket = { phase = 0.5 },
		balls = balls,
	}
end

-- A valid schema-2 replay body matching the fresh_engine board (2 pegs);
-- callers override fields to exercise the validator.
local function schema2_replay(overrides)
	local t = {
		schema_version = 2,
		level_name = "test",
		isFever = false,
		pegs = {
			{ original_index = 1, type = "blue", hit = false,
			  base_x = 600, base_y = 200, x = 600, y = 200 },
			{ original_index = 2, type = "red", hit = true,
			  base_x = 300, base_y = 500, x = 300, y = 500 },
		},
		bucket = { phase = 0.5 },
		balls = { { id = 10, x = 100, y = 50, vx = 10, vy = 20 } },
	}
	if overrides then
		for k, v in pairs(overrides) do
			t[k] = v
		end
	end
	return t
end

-- Dirty an engine with non-default state so a failed applyReplayState can be
-- proven to leave every touched surface untouched.
local function dirty_engine(eng)
	local b = eng:registerBall(Ball.new(100, 50))
	eng.active_balls = { b }
	eng.live_ball_ids = { [b.id] = b }
	eng.live_id_by_ball = { [b] = b.id }
	eng.pegs[1].hit = true
	eng.pegs[1].type = "red"
	eng.bucket.phase = 0.75
	eng.isFever = true
	eng.feverBuckets.buckets[1].active = true
	eng.bonusScore = 500
	eng.styleScore = 200
	eng.clearQueue = { { hit_order = 1 } }
	eng.clearTimer = 0.5
	eng.scoredThisStep = true
	return {
		active = eng.active_balls,
		next_id = eng.next_ball_id,
		pegs = eng.pegs,
		peg_hit = eng.pegs[1].hit,
		peg_type = eng.pegs[1].type,
		phase = eng.bucket.phase,
		is_fever = eng.isFever,
		fever_active = eng.feverBuckets.buckets[1].active,
		bonus = eng.bonusScore,
		style = eng.styleScore,
		clear_queue = eng.clearQueue,
		clear_timer = eng.clearTimer,
		scored = eng.scoredThisStep,
	}
end

local function assert_engine_unchanged(eng, prev)
	assert_true(eng.active_balls == prev.active, "active_balls unchanged")
	assert_eq(eng.next_ball_id, prev.next_id, "next_ball_id unchanged")
	assert_true(eng.pegs == prev.pegs, "pegs unchanged")
	assert_eq(eng.pegs[1].hit, prev.peg_hit, "peg hit unchanged")
	assert_eq(eng.pegs[1].type, prev.peg_type, "peg type unchanged")
	assert_eq(eng.bucket.phase, prev.phase, "bucket phase unchanged")
	assert_eq(eng.isFever, prev.is_fever, "fever state unchanged")
	assert_eq(eng.feverBuckets.buckets[1].active, prev.fever_active,
		"fever bucket active unchanged")
	assert_eq(eng.bonusScore, prev.bonus, "bonusScore unchanged")
	assert_eq(eng.styleScore, prev.style, "styleScore unchanged")
	assert_true(eng.clearQueue == prev.clear_queue, "clearQueue unchanged")
	assert_eq(eng.clearTimer, prev.clear_timer, "clearTimer unchanged")
	assert_eq(eng.scoredThisStep, prev.scored, "scoredThisStep unchanged")
	assert_eq(eng.used_ball_ids[10], nil, "replay ball id 10 not consumed")
end

-- Level with `reds` red pegs (and blue fillers); colors come from the
-- seeded shuffle, so red pegs are located by scanning the board.
local function multi_red_engine(reds, seed)
	local eng = H.new_engine()
	local pegs = {}
	for i = 1, reds + 3 do
		table.insert(pegs, Peg.new(120 + 90 * i, 200 + (i % 2) * 140, "blue", 20))
	end
	H.setup_engine(eng, pegs, { red = reds, green = 0 }, seed or 1)
	return eng
end

local function red_indexes(eng)
	local out = {}
	for _, p in ipairs(eng.pegs) do
		if p.type == "red" then table.insert(out, p.original_index) end
	end
	return out
end

-- Hit the given pegs through the authoritative reducer (raw contact events).
local function hit_pegs(eng, indexes)
	eng.events:begin_step(eng.sim_step_id + 1, 1)
	for _, idx in ipairs(indexes) do
		eng.events:emit_raw("ball_contacted_peg", {
			ball_id = 1, peg_id = idx, contact_kind = "sweep",
		})
	end
	eng:reducePegContacts()
end

-- Write a schema-2 capture of the engine's scoring state to a temp file,
-- load it back, and restore it onto a fresh engine with the same level.
local function round_trip_scoring_state(eng, reds)
	Replay.capture(SCORING_CAPTURE_FILE, {
		level_name = "test",
		isFever = eng.isFever,
		hitCounter = eng.hitCounter,
		redPegsHitAmount = eng.redPegsHitAmount,
		currentMultiplier = eng.currentMultiplier,
		pegs = eng.pegs,
		bucket = eng.bucket,
		balls = { { id = 1, x = 100, y = 50, vx = 10, vy = 20 } },
	})
	local data = Replay.load(SCORING_CAPTURE_FILE)
	assert_true(data ~= nil, "scoring capture loads")
	assert_true(Replay.is_schema_2(data), "schema_version 2")
	local eng2 = multi_red_engine(reds)
	eng2:applyReplayState(data)
	return data, eng2
end

return {
	setup = function()
		LevelManager.virtual_width = 1200
		LevelManager.virtual_height = 1900
		Config.virtual_width = 1200
		Config.virtual_height = 1900
	end,

	test_capture_includes_ball_ids = function()
		local eng = fresh_engine()
		local b1 = eng:registerBall(Ball.new(100, 50))
		local b2 = eng:registerBall(Ball.new(200, 50))
		Replay.capture(CAPTURE_FILE, {
			level_name = "test",
			isFever = false,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = { b1, b2 },
		})
		local data = Replay.load(CAPTURE_FILE)
		assert_true(data ~= nil, "capture loads")
		assert_eq(data.balls[1].id, b1.id, "captured id preserved")
		assert_eq(data.balls[2].id, b2.id)
	end,

	test_max_integer_ball_id_round_trips_exactly = function()
		local MAX_ID = 9007199254740991
		local eng = fresh_engine()
		Replay.capture(CAPTURE_FILE, {
			level_name = "test",
			isFever = false,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = {
				{ x = 100, y = 50, vx = 10, vy = 20 },
				{ id = MAX_ID, x = 200, y = 50, vx = 10, vy = 20 },
			},
		})
		-- The file must carry the full 16 digits: tostring's short form
		-- (9.007199254741e+15) would change the ball identity on load.
		local f = io.open(CAPTURE_FILE, "r")
		local text = f:read("*a")
		f:close()
		assert_true(text:find("9007199254740991", 1, true) ~= nil,
			"file contains the full id digits, not a shortened form")
		assert_true(text:find("9.007199254741e+15", 1, true) == nil,
			"no shortened float form written for the id")
		local data = Replay.load(CAPTURE_FILE)
		assert_true(data ~= nil, "capture loads")
		assert_eq(data.balls[1].id, nil, "nil id stays absent in the capture")
		assert_eq(data.balls[2].id, MAX_ID, "2^53-1 ball id round-trips exactly")
		-- Restore onto a fresh engine: the nil-id ball gets the deterministic
		-- first automatic id; the max-integer id is kept intact.
		local eng2 = fresh_engine()
		eng2:applyReplayState(data)
		assert_eq(eng2.active_balls[1].id, 1, "nil-id ball gets deterministic allocated id")
		assert_eq(eng2.active_balls[2].id, MAX_ID, "restored id keeps full precision")
	end,

	test_apply_preserves_captured_ids = function()
		local eng = fresh_engine()
		eng:applyReplayState(make_replay_data(true))
		assert_eq(eng.active_balls[1].id, 41)
		assert_eq(eng.active_balls[2].id, 42)
		-- Allocator advanced past captured ids: a later power spawn cannot
		-- reuse them.
		local spawned = eng:registerBall(Ball.new(0, 0))
		assert_eq(spawned.id, 43, "power spawn gets fresh id after replay ids")
	end,

	test_apply_allocates_deterministic_ids_for_old_format = function()
		local eng = fresh_engine()
		-- Old captures have no id fields.
		eng:applyReplayState(make_replay_data(false))
		assert_eq(eng.active_balls[1].id, 1, "old capture: ids allocated in ball order")
		assert_eq(eng.active_balls[2].id, 2)
		local spawned = eng:registerBall(Ball.new(0, 0))
		assert_eq(spawned.id, 3)
	end,

	test_apply_establishes_nonzero_shot_id = function()
		local eng = fresh_engine()
		eng:applyReplayState(make_replay_data(true))
		assert_true(eng.shot_id > 0, "replay shot runs under nonzero shot_id")
		assert_eq(eng.shot_initial_step, eng.sim_step_id + 1,
			"deterministic shot_initial_step")
	end,

	test_apply_resets_processors_for_loaded_shot = function()
		local eng = fresh_engine()
		-- Dirty the processors as if a previous shot was mid-recognition.
		eng.styleShots.bucket_bounced[1] = 5
		eng.ballState.no_score_timer = 7.5
		eng.ballState.all_idle_latch = true
		eng:applyReplayState(make_replay_data(true))
		assert_eq(eng.styleShots.bucket_bounced[1], nil, "StyleShots reset")
		assert_eq(eng.ballState.no_score_timer, 0, "BallState reset")
		assert_false(eng.ballState.all_idle_latch)
	end,

	test_apply_does_not_stage_fake_ball_launched = function()
		local eng = fresh_engine()
		eng:applyReplayState(make_replay_data(true))
		assert_eq(#eng.events.staged, 0, "no fake ball_launched staged")
		-- And after a step begins, no ball_launched raw event appears.
		eng.events:begin_step(eng.sim_step_id + 1, eng.shot_id)
		for _, e in ipairs(eng.events:raw()) do
			assert_true(e.type ~= "ball_launched", "no ball_launched for in-progress shot")
		end
		eng.events:seal_raw()
		eng.events:finish_step()
	end,

	test_apply_restores_peg_and_bucket_state = function()
		local eng = fresh_engine()
		eng:applyReplayState(make_replay_data(true))
		assert_eq(#eng.pegs, 2)
		assert_eq(eng.pegs[2].hit, true, "captured hit state restored")
		assert_eq(eng.bucket.phase, 0.5, "bucket phase restored")
		assert_true(eng.active_balls[1].launched, "replay balls are launched")
	end,

	test_bucket_state_capture_restore_round_trip_via_file = function()
		-- Drive the bucket into mid-oscillation through the live update path,
		-- then capture through the real engine fields (bucket = eng.bucket,
		-- as Engine:launchBalls does) and restore onto a fresh engine.
		local eng = fresh_engine()
		for _ = 1, 5000 do
			Bucket.update(eng.bucket, Config.fixed_dt)
			if math.abs(eng.bucket.x - 600) > 10 then break end
		end
		assert_true(near(eng.bucket.x, 600, 10) == false, "bucket is mid-oscillation")
		local phase, x = eng.bucket.phase, eng.bucket.x

		local ball = eng:registerBall(Ball.new(100, 50))
		Replay.capture(CAPTURE_FILE, {
			level_name = "test",
			isFever = false,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = { ball },
		})
		local data = Replay.load(CAPTURE_FILE)
		assert_true(data ~= nil, "capture loads")
		assert_true(near(data.bucket.phase, phase, 1e-9), "captured phase matches engine")
		assert_true(near(data.bucket.x, x, 1e-9), "captured x matches engine")

		local eng2 = fresh_engine()
		eng2:applyReplayState(data)
		assert_true(near(eng2.bucket.phase, phase, 1e-9),
			"restored phase matches the capture")
		assert_true(near(eng2.bucket.x, x, 1e-9),
			"restored x matches the capture")
		assert_eq(eng2.bucket.prev_x, eng2.bucket.x,
			"prev_x = restored x: no first-step interpolation jump")
	end,

	test_capture_writes_bucket_phase_x_with_full_precision = function()
		-- Synthetic bucket whose phase needs more digits than tostring's
		-- %.14g keeps: the capture text must carry the %.17g form so the
		-- restored oscillation resumes bit-exactly.
		local PHASE = "0.12345678901234559"
		local X = "731.87654321012349"
		local phase, x = tonumber(PHASE), tonumber(X)
		assert_true(string.format("%.17g", phase) == PHASE,
			"fixture phase round-trips through %.17g")
		assert_true(string.format("%.17g", x) == X,
			"fixture x round-trips through %.17g")
		local eng = fresh_engine()
		eng.bucket.phase = phase
		eng.bucket.x = x
		Replay.capture(CAPTURE_FILE, {
			level_name = "test",
			isFever = false,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = {},
		})
		local f = io.open(CAPTURE_FILE, "r")
		local text = f:read("*a")
		f:close()
		assert_true(text:find(PHASE, 1, true) ~= nil,
			"file contains the full %.17g phase digits")
		assert_true(text:find(X, 1, true) ~= nil,
			"file contains the full %.17g x digits")
		assert_true(text:find(string.format("%.14g", phase), 1, true) == nil,
			"no shortened %.14g form written for the phase")
		local data = Replay.load(CAPTURE_FILE)
		assert_true(data ~= nil, "capture loads")
		assert_eq(data.bucket.phase, phase, "phase round-trips exactly")
		assert_eq(data.bucket.x, x, "x round-trips exactly")
	end,

	test_bucket_x_absent_keeps_default_position = function()
		-- Legacy and pre-x schema-2 files carry bucket = { phase = ... } only:
		-- the restore keeps the pre-fix behavior — phase applied, x/prev_x
		-- left at the Bucket.new() defaults.
		local eng = fresh_engine()
		eng:applyReplayState(make_replay_data(false))
		assert_eq(eng.bucket.phase, 0.5, "legacy phase restored")
		assert_eq(eng.bucket.x, 600, "no captured x: default center kept")
		assert_eq(eng.bucket.prev_x, 600)

		local eng2 = fresh_engine()
		eng2:applyReplayState(schema2_replay())
		assert_eq(eng2.bucket.phase, 0.5, "schema-2 phase restored")
		assert_eq(eng2.bucket.x, 600, "schema-2 without x: default center kept")
		assert_eq(eng2.bucket.prev_x, 600)
	end,

	test_old_capture_end_to_end_via_file = function()
		-- Write an old-format capture (no ball ids) and load it through the
		-- same Replay.load path the bench uses.
		local f = io.open(CAPTURE_FILE, "w")
		f:write([[return {
	level_name = "test",
	isFever = false,
	pegs = {
		{original_index=1, type="blue", hit=false},
	},
	bucket = {phase=0},
	balls = {
		{x=100, y=50, vx=0, vy=800},
	},
}]])
		f:close()
		local 		data = Replay.load(CAPTURE_FILE)
		assert_true(data ~= nil)
		assert_eq(data.balls[1].id, nil, "old format has no ids")
		local eng = fresh_engine()
		eng:applyReplayState(data)
		assert_eq(eng.active_balls[1].id, 1, "deterministic id allocated")
		assert_true(eng.shot_id > 0)
	end,

	test_duplicate_ids_leave_engine_unchanged = function()
		local eng = fresh_engine()

		-- Deliberately dirty the Engine with non-default state.
		local old_b1 = eng:registerBall(Ball.new(100, 50))
		local old_b2 = eng:registerBall(Ball.new(200, 50))
		eng.active_balls = { old_b1, old_b2 }
		eng.live_ball_ids = { [old_b1.id] = old_b1, [old_b2.id] = old_b2 }
		eng.live_id_by_ball = { [old_b1] = old_b1.id, [old_b2] = old_b2.id }
		eng.used_ball_ids[old_b1.id] = true
		eng.used_ball_ids[old_b2.id] = true
		eng.next_ball_id = 3

		eng.pegs[1].hit = true
		eng.pegs[1].type = "red"
		eng.bucket.phase = 0.75
		eng.isFever = true
		eng.feverBuckets.buckets[1].active = true
		eng.bonusScore = 500
		eng.styleScore = 200
		eng.clearQueue = { { hit_order = 1 } }
		eng.clearTimer = 0.5
		eng.scoredThisStep = true
		eng.shot_id = 5
		eng.shot_initial_step = 100
		eng.shot_final_step = 150
		eng.shot_end_reason = "fell_out"
		eng.last_removal_reason = "fell_out"
		eng.current_shot_timeline = { {} }
		eng.styleShots.bucket_bounced[1] = 5
		eng.ballState.no_score_timer = 7.5
		eng.ballState.all_idle_latch = true
		eng.events:stage("ball_launched", { ball_id = 1, x = 0, y = 0, vx = 0, vy = 0 })

		local hud_calls = 0
		eng.callbacks.onHUDRefresh = function() hud_calls = hud_calls + 1 end

		-- Record all pre-existing state references.
		local prev_active = eng.active_balls
		local prev_live_ids = eng.live_ball_ids
		local prev_live_by_ball = eng.live_id_by_ball
		local prev_next = eng.next_ball_id
		local prev_pegs = eng.pegs
		local prev_circle_pegs = eng.circle_pegs
		local prev_rect_pegs = eng.rect_pegs
		local prev_annular_pegs = eng.annular_pegs
		local prev_peg_by_id = eng.peg_by_id
		local prev_bucket_phase = eng.bucket.phase
		local prev_is_fever = eng.isFever
		local prev_fever_active = eng.feverBuckets.buckets[1].active
		local prev_bonus = eng.bonusScore
		local prev_style = eng.styleScore
		local prev_clear_queue = eng.clearQueue
		local prev_clear_timer = eng.clearTimer
		local prev_scored = eng.scoredThisStep
		local prev_shot_id = eng.shot_id
		local prev_shot_init = eng.shot_initial_step
		local prev_shot_final = eng.shot_final_step
		local prev_shot_end = eng.shot_end_reason
		local prev_last_rem = eng.last_removal_reason
		local prev_timeline = eng.current_shot_timeline
		local prev_ss_bucket = eng.styleShots.bucket_bounced[1]
		local prev_bs_timer = eng.ballState.no_score_timer
		local prev_bs_latch = eng.ballState.all_idle_latch
		local prev_staged = #eng.events.staged

		-- Apply a replay with two different balls using the same ID.
		local ok, err = pcall(function()
			eng:applyReplayState({
				level_name = "test", isFever = false,
				pegs = {
					{ original_index = 1, type = "blue", hit = false,
					  circuit_state = nil, circuit_timer = 0, circuit_t = 0,
					  base_x = 600, base_y = 200, base_angle = 0 },
					{ original_index = 2, type = "red", hit = false,
					  circuit_state = nil, circuit_timer = 0, circuit_t = 0,
					  base_x = 300, base_y = 500, base_angle = 0 },
				},
				bucket = { phase = 0 },
				balls = {
					{ id = 10, x = 100, y = 50, vx = 10, vy = 20 },
					{ id = 10, x = 200, y = 50, vx = 10, vy = 20 },
				},
			})
		end)
		assert_false(ok, "duplicate replay IDs rejected")
		assert_true(tostring(err):find("already consumed") ~= nil
			or tostring(err):find("duplicate") ~= nil, tostring(err))

		-- Assert NO Engine state changed.
		assert_true(eng.active_balls == prev_active, "active_balls unchanged")
		assert_true(eng.live_ball_ids == prev_live_ids, "live_ball_ids unchanged")
		assert_true(eng.live_id_by_ball == prev_live_by_ball, "live_id_by_ball unchanged")
		assert_eq(eng.next_ball_id, prev_next, "next_ball_id unchanged")
		assert_true(eng.used_ball_ids[10] == nil, "id 10 not consumed")
		assert_true(eng.pegs == prev_pegs, "pegs unchanged")
		assert_true(eng.circle_pegs == prev_circle_pegs, "circle_pegs unchanged")
		assert_true(eng.rect_pegs == prev_rect_pegs, "rect_pegs unchanged")
		assert_true(eng.annular_pegs == prev_annular_pegs, "annular_pegs unchanged")
		assert_true(eng.peg_by_id == prev_peg_by_id, "peg_by_id unchanged")
		assert_eq(eng.bucket.phase, prev_bucket_phase, "bucket phase unchanged")
		assert_eq(eng.isFever, prev_is_fever, "fever state unchanged")
		assert_eq(eng.feverBuckets.buckets[1].active, prev_fever_active, "fever bucket active unchanged")
		assert_eq(eng.bonusScore, prev_bonus, "bonusScore unchanged")
		assert_eq(eng.styleScore, prev_style, "styleScore unchanged")
		assert_true(eng.clearQueue == prev_clear_queue, "clearQueue unchanged")
		assert_eq(eng.clearTimer, prev_clear_timer, "clearTimer unchanged")
		assert_eq(eng.scoredThisStep, prev_scored, "scoredThisStep unchanged")
		assert_eq(eng.shot_id, prev_shot_id, "shot_id unchanged")
		assert_eq(eng.shot_initial_step, prev_shot_init, "shot_initial_step unchanged")
		assert_eq(eng.shot_final_step, prev_shot_final, "shot_final_step unchanged")
		assert_eq(eng.shot_end_reason, prev_shot_end, "shot_end_reason unchanged")
		assert_eq(eng.last_removal_reason, prev_last_rem, "last_removal_reason unchanged")
		assert_true(eng.current_shot_timeline == prev_timeline, "current_shot_timeline unchanged")
		assert_eq(eng.styleShots.bucket_bounced[1], prev_ss_bucket, "StyleShots state unchanged")
		assert_eq(eng.ballState.no_score_timer, prev_bs_timer, "BallState no_score_timer unchanged")
		assert_eq(eng.ballState.all_idle_latch, prev_bs_latch, "BallState all_idle_latch unchanged")
		assert_eq(#eng.events.staged, prev_staged, "staged events unchanged")
		assert_eq(hud_calls, 0, "onHUDRefresh not called on failure")
	end,

	test_invalid_id_after_leading_missing_id = function()
		local eng = fresh_engine()

		-- Dirty non-default state.
		local old_b = eng:registerBall(Ball.new(100, 50))
		eng.active_balls = { old_b }
		eng.pegs[1].hit = true
		eng.bucket.phase = 0.5
		eng.bonusScore = 100
		eng.styleScore = 50
		eng.clearQueue = { {} }

		local prev_active = eng.active_balls
		local prev_next = eng.next_ball_id
		local prev_pegs = eng.pegs
		local prev_bucket_phase = eng.bucket.phase
		local prev_bonus = eng.bonusScore
		local prev_style = eng.styleScore
		local prev_clear_queue = eng.clearQueue
		local prev_used10 = eng.used_ball_ids[1]

		local ok, err = pcall(function()
			eng:applyReplayState({
				level_name = "test", isFever = false,
				pegs = { { original_index = 1, type = "blue", hit = false,
				  circuit_state = nil, circuit_timer = 0, circuit_t = 0,
				  base_x = 600, base_y = 200, base_angle = 0 } },
				bucket = { phase = 0 },
				balls = {
					{ x = 100, y = 50, vx = 10, vy = 20 },
					{ id = 0, x = 200, y = 50, vx = 10, vy = 20 },
				},
			})
		end)
		assert_false(ok, "invalid id after missing-id must fail")
		assert_true(tostring(err):find("positive") ~= nil, tostring(err))

		-- Assert no state changed.
		assert_true(eng.active_balls == prev_active, "active_balls unchanged")
		assert_eq(eng.next_ball_id, prev_next, "next_ball_id unchanged")
		assert_true(eng.used_ball_ids[prev_next] == nil, "no auto ID consumed")
		assert_true(eng.pegs == prev_pegs, "pegs unchanged")
		assert_eq(eng.bucket.phase, prev_bucket_phase, "bucket phase unchanged")
		assert_eq(eng.bonusScore, prev_bonus, "bonusScore unchanged")
		assert_eq(eng.styleScore, prev_style, "styleScore unchanged")
		assert_true(eng.clearQueue == prev_clear_queue, "clearQueue unchanged")
	end,

	test_already_consumed_replay_id_rejected = function()
		local eng = fresh_engine()

		-- Consume id 42 in the permanent identity namespace.
		eng.used_ball_ids[42] = true
		eng.next_ball_id = 43
		assert_true(eng.used_ball_ids[42], "id 42 pre-consumed")

		-- Dirty state.
		eng.bonusScore = 300
		eng.styleScore = 100
		eng.bucket.phase = 0.6
		eng.pegs[1].hit = true
		eng.clearQueue = { {} }

		local prev_next = eng.next_ball_id
		local prev_bonus = eng.bonusScore
		local prev_style = eng.styleScore
		local prev_bucket_phase = eng.bucket.phase
		local prev_pegs = eng.pegs
		local prev_clear_queue = eng.clearQueue

		local ok, err = pcall(function()
			eng:applyReplayState({
				level_name = "test", isFever = false,
				pegs = { { original_index = 1, type = "blue", hit = false,
				  circuit_state = nil, circuit_timer = 0, circuit_t = 0,
				  base_x = 600, base_y = 200, base_angle = 0 } },
				bucket = { phase = 0 },
				balls = {
					{ id = 42, x = 100, y = 50, vx = 10, vy = 20 },
				},
			})
		end)
		assert_false(ok, "already-consumed replay id rejected")
		assert_true(tostring(err):find("already consumed") ~= nil, tostring(err))

		-- Assert no state changed.
		assert_eq(eng.next_ball_id, prev_next, "next_ball_id unchanged")
		assert_eq(eng.bonusScore, prev_bonus, "bonusScore unchanged")
		assert_eq(eng.styleScore, prev_style, "styleScore unchanged")
		assert_eq(eng.bucket.phase, prev_bucket_phase, "bucket phase unchanged")
		assert_true(eng.pegs == prev_pegs, "pegs unchanged")
		assert_true(eng.clearQueue == prev_clear_queue, "clearQueue unchanged")
	end,

	test_max_boundary_exhaustion_rejected = function()
		local eng = fresh_engine()
		eng.next_ball_id = 9007199254740991 + 1

		local ok, err = pcall(function()
			eng:applyReplayState({
				level_name = "test", isFever = false,
				pegs = { { original_index = 1, type = "blue", hit = false,
				  circuit_state = nil, circuit_timer = 0, circuit_t = 0,
				  base_x = 600, base_y = 200, base_angle = 0 } },
				bucket = { phase = 0 },
				balls = {
					{ id = 9007199254740991, x = 100, y = 50, vx = 10, vy = 20 },
					{ x = 200, y = 50, vx = 10, vy = 20 },
				},
			})
		end)
		assert_false(ok, "exhaustion failure")
		assert_true(tostring(err):find("exhausted") ~= nil
			or tostring(err):find("no valid automatic") ~= nil, tostring(err))

		-- Max ID not partially installed.
		assert_true(eng.used_ball_ids[9007199254740991] == nil, "max id not consumed")
		assert_eq(eng.next_ball_id, 9007199254740991 + 1, "next_ball_id unchanged")
		assert_eq(eng.shot_id, 0, "shot_id unchanged")
		assert_eq(#eng.pegs, 2, "pegs unchanged")
	end,

	test_schema2_capture_round_trip_with_motion = function()
		-- Build an engine with one moving peg, advance one step so the
		-- runtime motion state and velocities are nonzero, then capture,
		-- load, and restore onto a fresh engine.
		local eng = fresh_engine()
		local p = Peg.new(600, 200, "blue", 20)
		p.motion = { circuit = "c1", phase = 0.25 }
		H.setup_engine(eng, { p }, { red = 0, green = 0 }, 1)
		eng.level_circuits = { c1 = { kind = "oscillate_x", amp = 100, speed = 1.5 } }
		Circuits.initialize(eng.pegs, eng.level_circuits)
		Circuits.update(eng.pegs, eng.level_circuits, 1 / 60)

		local ball = eng:registerBall(Ball.new(100, 50))
		Replay.capture(CAPTURE_FILE, {
			level_name = "test",
			isFever = false,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = { ball },
		})
		local data = Replay.load(CAPTURE_FILE)
		assert_true(data ~= nil, "capture loads")
		assert_true(Replay.is_schema_2(data), "schema_version 2")
		local rp = data.pegs[1]
		assert_eq(rp.motion.circuit, "c1")
		assert_eq(rp.motion.phase, 0.25)
		assert_eq(rp.motion.time, p.motion.time, "runtime time captured")
		assert_eq(rp.motion.state, p.motion.state)
		assert_eq(rp.x, p.x, "current transform captured")
		assert_eq(rp.vx, p.vx, "velocity captured")

		-- Restore onto a fresh engine with the same level.
		local eng2 = fresh_engine()
		local p2 = Peg.new(600, 200, "blue", 20)
		p2.motion = { circuit = "c1", phase = 0.25 }
		H.setup_engine(eng2, { p2 }, { red = 0, green = 0 }, 1)
		eng2.level_circuits = { c1 = { kind = "oscillate_x", amp = 100, speed = 1.5 } }
		Circuits.initialize(eng2.pegs, eng2.level_circuits)
		eng2:applyReplayState(data)

		local q = eng2.pegs[1]
		assert_eq(q.motion.time, p.motion.time, "runtime time restored")
		assert_eq(q.motion.state, p.motion.state, "state restored")
		assert_eq(q.motion.timer, p.motion.timer, "timer restored")
		assert_eq(q.x, p.x, "position restored")
		assert_eq(q.vx, p.vx, "velocity restored")
		assert_eq(q.prev_x, q.x, "no first-step interpolation jump")

		-- Advancing one step continues from the restored time (no teleport).
		Circuits.update(eng2.pegs, eng2.level_circuits, 1 / 60)
		assert_true(eng2.pegs[1].motion.time > p.motion.time,
			"motion continues from restored time")
	end,

	test_legacy_moving_peg_restored_via_circuit_eval = function()
		local eng = fresh_engine()
		local p = Peg.new(600, 200, "blue", 20)
		p.motion = { circuit = "c1", phase = 0 }
		H.setup_engine(eng, { p }, { red = 0, green = 0 }, 1)
		eng.level_circuits = { c1 = { kind = "oscillate_x", amp = 100, speed = 1 } }
		Circuits.initialize(eng.pegs, eng.level_circuits)

		eng:applyReplayState({
			level_name = "test", isFever = false,
			pegs = { { original_index = 1, type = "blue", hit = false,
				circuit_state = "paused", circuit_timer = 0.3, circuit_t = 1.0,
				base_x = 600, base_y = 200, base_angle = 0 } },
			bucket = { phase = 0 },
			balls = { { x = 100, y = 50, vx = 10, vy = 20 } },
		})

		local q = eng.pegs[1]
		assert_eq(q.motion.circuit, "c1", "legacy record uses level assignment")
		assert_eq(q.motion.time, 1.0, "circuit_t becomes motion.time")
		assert_eq(q.motion.state, "paused", "circuit_state becomes motion.state")
		assert_eq(q.motion.timer, 0.3, "circuit_timer becomes motion.timer")
		local dx, dy = Circuits.eval_transform(eng.level_circuits.c1, 1.0)
		assert_eq(q.x, 600 + dx, "transform re-derived at circuit_t")
		assert_eq(q.y, 200 + dy)
		assert_eq(q.vx, 0, "legacy velocities zeroed")
		assert_eq(q.vy, 0)
		assert_eq(q.prev_x, q.x, "no first-step interpolation jump")
	end,

	test_legacy_static_peg_restored_at_base = function()
		local eng = fresh_engine()
		eng:applyReplayState({
			level_name = "test", isFever = false,
			pegs = { { original_index = 1, type = "blue", hit = true,
				circuit_state = nil, circuit_timer = 0, circuit_t = 0,
				base_x = 600, base_y = 200, base_angle = 0 } },
			bucket = { phase = 0 },
			balls = { { x = 100, y = 50, vx = 10, vy = 20 } },
		})
		local q = eng.pegs[1]
		assert_eq(q.hit, true, "captured hit restored")
		assert_true(q.motion == nil, "no motion created for static peg")
		assert_eq(q.x, 600)
		assert_eq(q.y, 200)
		assert_eq(q.vx, 0)
	end,

	test_legacy_rotating_annular_not_double_rotated = function()
		-- Old captures of rotating annular pegs wrote the current applied
		-- rotation into base_angle (annular pegs had no declared base_angle
		-- field pre-refactor). The legacy restore must not install that baked
		-- value as the base and then re-add the circuit rotation on top: the
		-- level's declared base rotation is authoritative, so the restored
		-- angle is declared base + da(circuit_t) exactly once.
		local eng = H.new_engine()
		local p = Peg.new_annular(500, 400, "blue", 15, 25, math.rad(-90), math.rad(-30))
		p.motion = { circuit = "c1", phase = 0.5 }
		H.setup_engine(eng, { p }, { red = 0, green = 0 }, 1)
		eng.level_circuits = { c1 = { kind = "rotate", speed = 1, speed_angular = 2 } }
		Circuits.initialize(eng.pegs, eng.level_circuits)

		-- Legacy capture of the annular mid-rotation: at circuit_t = 1.0 the
		-- applied rotation is 2.0 rad, and old captures stored that current
		-- angle in base_angle (the declared base was nil/0).
		eng:applyReplayState({
			level_name = "test", isFever = false,
			pegs = { { original_index = 1, type = "blue", hit = false,
				circuit_state = "moving", circuit_timer = 0, circuit_t = 1.0,
				base_x = 500, base_y = 400, base_angle = 2.0 } },
			bucket = { phase = 0 },
			balls = { { x = 100, y = 50, vx = 10, vy = 20 } },
		})

		local q = eng.pegs[1]
		assert_eq(q.motion.circuit, "c1", "legacy record uses level assignment")
		assert_eq(q.motion.time, 1.0, "circuit_t becomes motion.time")
		assert_eq(q.motion.state, "moving")
		assert_eq(q.motion.timer, 0)
		local _, _, da = Circuits.eval_transform(eng.level_circuits.c1, 1.0)
		assert_true(near(q.angle, da, 1e-9),
			"rotation applied once: captured 2.0 rad baked base must not be doubled")
		assert_true(q.base_angle == nil,
			"captured base_angle not installed; level's declared base kept")
		assert_true(near(q.theta_start, q.base_theta_start + q.angle, 1e-9),
			"theta_start rebuilt from declared base + applied rotation")
		assert_true(near(q.theta_end_abs, q.base_theta_end_abs + q.angle, 1e-9),
			"theta_end_abs rebuilt from declared base + applied rotation")
		assert_eq(q.x, 500)
		assert_eq(q.y, 400)
		assert_eq(q.vx, 0)
		assert_eq(q.vy, 0)
		assert_eq(q.va, 0)
		assert_eq(q.prev_angle, q.angle, "no first-step interpolation jump")

		-- The next step continues from the restored rotation (declared base
		-- 0 + advancing da), not from a snapped-back or doubled rotation.
		Circuits.update(eng.pegs, eng.level_circuits, 1 / 60)
		local _, _, da2 = Circuits.eval_transform(eng.level_circuits.c1, q.motion.time)
		assert_true(near(q.angle, da2, 1e-9),
			"rotation continues from the restored time")
		assert_true(q.angle > 2.0, "rotation advanced past the restored angle")
	end,

	-- ===================================================================
	-- Scoring-progress round trip (redPegsHitAmount/currentMultiplier)
	-- ===================================================================

	test_capture_writes_scoring_progress_fields = function()
		local eng = multi_red_engine(7)
		local reds = red_indexes(eng)
		hit_pegs(eng, { reds[1], reds[2], reds[3] })
		assert_eq(eng.redPegsHitAmount, 3, "three red pegs hit")
		assert_eq(eng.currentMultiplier, 2, "3/7 reds is the 2x band")
		assert_false(eng.isFever)
		Replay.capture(SCORING_CAPTURE_FILE, {
			level_name = "test",
			isFever = eng.isFever,
			hitCounter = eng.hitCounter,
			redPegsHitAmount = eng.redPegsHitAmount,
			currentMultiplier = eng.currentMultiplier,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = { { id = 1, x = 100, y = 50, vx = 10, vy = 20 } },
		})
		local data = Replay.load(SCORING_CAPTURE_FILE)
		assert_true(data ~= nil)
		assert_eq(data.redPegsHitAmount, 3, "redPegsHitAmount captured")
		assert_eq(data.currentMultiplier, 2, "currentMultiplier captured")
		assert_eq(data.hitCounter, 3, "hitCounter captured")
	end,

	test_apply_restores_scoring_progress = function()
		local eng = multi_red_engine(7)
		local reds = red_indexes(eng)
		hit_pegs(eng, { reds[1], reds[2], reds[3] })
		local data, eng2 = round_trip_scoring_state(eng, 7)
		assert_eq(data.isFever, false)
		assert_eq(eng2.redPegsHitAmount, 3, "restored red-peg count")
		assert_eq(eng2.currentMultiplier, 2, "restored multiplier")
		assert_false(eng2.isFever, "restored non-fever")
		-- A fresh engine started at 0 hit red pegs with multiplier 1; the
		-- restore must carry the prior level progress across.
		assert_eq(eng2.totalRedPegs, 7)
	end,

	test_restored_scoring_progress_applies_to_subsequent_hits = function()
		local eng = multi_red_engine(7)
		local reds = red_indexes(eng)
		hit_pegs(eng, { reds[1], reds[2], reds[3] })
		local _, eng2 = round_trip_scoring_state(eng, 7)
		-- Hit a fourth red peg after the restore: the shot must score at the
		-- restored multiplier band (4/7 is still 2x), not restart at 1x.
		assert_eq(eng2.pegs[reds[4]].type, "red")
		hit_pegs(eng2, { reds[4] })
		assert_eq(eng2.redPegsHitAmount, 4, "counter continues from restored value")
		assert_eq(eng2.currentMultiplier, 2, "4/7 reds is still the 2x band")
		assert_eq(eng2.pegs[reds[4]].multiplier_at_hit, 2,
			"subsequent hit scored at the restored multiplier")
		assert_eq(eng2.pegs[reds[4]].hit_order, 4, "hit_order continues after restored counter")
	end,

	test_fever_replay_restores_fever_with_active_buckets = function()
		local eng = multi_red_engine(5)
		local reds = red_indexes(eng)
		hit_pegs(eng, reds)
		assert_true(eng.isFever, "all reds hit triggers fever")
		assert_eq(eng.currentMultiplier, 100)
		local data, eng2 = round_trip_scoring_state(eng, 5)
		assert_eq(data.redPegsHitAmount, 5, "fever capture records full red count")
		assert_eq(data.currentMultiplier, 100, "fever capture records multiplier 100")
		assert_true(data.isFever, "fever capture records isFever")
		assert_eq(eng2.redPegsHitAmount, 5)
		assert_eq(eng2.currentMultiplier, 100, "fever restore keeps multiplier 100")
		assert_true(eng2.isFever, "fever restore keeps isFever")
		assert_true(eng2.feverBuckets.top > eng2.feverBuckets.target_top,
			"fever buckets raised after restore")
		assert_true(eng2.feverBuckets.animating, "fever bucket raise animation started")
	end,

	test_schema2_without_scoring_fields_keeps_old_defaults = function()
		local eng = multi_red_engine(7)
		-- A schema-2 file written before the scoring-progress fields existed.
		eng:applyReplayState({
			schema_version = 2,
			level_name = "test", isFever = false,
			pegs = eng.pegs,
			bucket = { phase = 0 },
			balls = { { id = 1, x = 100, y = 50, vx = 10, vy = 20 } },
		})
		assert_eq(eng.redPegsHitAmount, 0, "no field: defaults to zero red pegs")
		assert_eq(eng.currentMultiplier, 1, "no field: defaults to multiplier 1")
		assert_false(eng.isFever)
	end,

	test_schema2_fever_without_scoring_fields_keeps_captured_activation = function()
		local eng = multi_red_engine(7)
		-- Pre-fix fever captures carried isFever without any red-peg count;
		-- restoring them keeps the captured fever flag and bucket activation.
		eng:applyReplayState({
			schema_version = 2,
			level_name = "test", isFever = true,
			pegs = eng.pegs,
			bucket = { phase = 0 },
			balls = { { id = 1, x = 100, y = 50, vx = 10, vy = 20 } },
		})
		assert_true(eng.isFever, "old fever capture keeps isFever")
		assert_true(eng.feverBuckets.top > eng.feverBuckets.target_top,
			"old fever capture activates buckets")
		assert_eq(eng.currentMultiplier, 1, "old capture has no multiplier data")
	end,

	test_inconsistent_fever_flag_normalized_from_red_count = function()
		-- isFever=false with all reds hit cannot occur live: the count is
		-- authoritative and must restore as fever.
		local eng = multi_red_engine(5)
		Replay.capture(SCORING_CAPTURE_FILE, {
			level_name = "test",
			isFever = false,
			hitCounter = 5,
			redPegsHitAmount = 5,
			currentMultiplier = 100,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = { { id = 1, x = 100, y = 50, vx = 10, vy = 20 } },
		})
		local data = Replay.load(SCORING_CAPTURE_FILE)
		assert_true(data ~= nil, "capture loads")
		local eng2 = multi_red_engine(5)
		eng2:applyReplayState(data)
		assert_eq(eng2.redPegsHitAmount, 5)
		assert_eq(eng2.currentMultiplier, 100, "normalized to fever multiplier")
		assert_true(eng2.isFever, "normalized isFever matches the red count")
		assert_true(eng2.feverBuckets.top > eng2.feverBuckets.target_top,
			"buckets activated through the fever transition")
	end,

	test_inconsistent_multiplier_normalized_from_red_count = function()
		-- A captured multiplier that disagrees with the red-peg fraction
		-- (e.g. isFever=true recorded at multiplier 1) must be overridden.
		local eng = multi_red_engine(7)
		eng:applyReplayState({
			schema_version = 2,
			level_name = "test", isFever = true,
			hitCounter = 3,
			redPegsHitAmount = 3,
			currentMultiplier = 1,
			pegs = eng.pegs,
			bucket = { phase = 0 },
			balls = { { id = 1, x = 100, y = 50, vx = 10, vy = 20 } },
		})
		assert_eq(eng.redPegsHitAmount, 3)
		assert_eq(eng.currentMultiplier, 2, "multiplier re-derived from the red count")
		assert_false(eng.isFever, "fever flag consistent with the multiplier")
	end,

	-- ===================================================================
	-- Strict schema validation (Replay.validate / Replay.is_schema_2)
	-- ===================================================================

	test_validate_accepts_legacy_and_exact_schema_2 = function()
		local ok, err = Replay.validate(make_replay_data(false))
		assert_true(ok, "legacy capture (no schema_version) accepted: " .. tostring(err))
		assert_false(Replay.is_schema_2(make_replay_data(false)),
			"legacy capture is not schema 2")
		ok, err = Replay.validate(schema2_replay())
		assert_true(ok, "schema_version 2 accepted: " .. tostring(err))
		assert_true(Replay.is_schema_2(schema2_replay()))
		-- Numeric 2.0 is the same integer as 2 in Lua.
		ok, err = Replay.validate(schema2_replay({ schema_version = 2.0 }))
		assert_true(ok, "numeric schema_version 2.0 accepted: " .. tostring(err))
		assert_true(Replay.is_schema_2(schema2_replay({ schema_version = 2.0 })))
		-- A structurally empty board is still schema 2.
		ok = Replay.validate({ schema_version = 2, level_name = "test", pegs = {} })
		assert_true(ok, "schema 2 with an empty peg board accepted")
		-- Non-table data is rejected, not crashed on.
		ok, err = Replay.validate(nil)
		assert_false(ok)
		assert_true(tostring(err):find("must be a table") ~= nil, tostring(err))
	end,

	test_validate_rejects_unsupported_schema_versions = function()
		for _, version in ipairs({ 3, 4, 1, 0, 2.5, 1.5, "2", true, false }) do
			local ok, err = Replay.validate({ schema_version = version })
			assert_false(ok, "schema_version " .. tostring(version) .. " rejected")
			assert_true(tostring(err):find("schema_version") ~= nil, tostring(err))
			assert_false(Replay.is_schema_2({ schema_version = version }),
				"is_schema_2 false for version " .. tostring(version))
		end
		-- The error message names the offending value.
		local _, err = Replay.validate({ schema_version = 3 })
		assert_true(tostring(err):find("schema_version 3") ~= nil, tostring(err))
		_, err = Replay.validate({ schema_version = 2.5 })
		assert_true(tostring(err):find("schema_version 2.5") ~= nil, tostring(err))
		_, err = Replay.validate({ schema_version = "2" })
		assert_true(tostring(err):find('schema_version "2"') ~= nil, tostring(err))
		-- is_schema_2 stays total (never raises) on garbage input.
		assert_false(Replay.is_schema_2(nil))
		assert_false(Replay.is_schema_2("2"))
		assert_false(Replay.is_schema_2(5))
		assert_false(Replay.is_schema_2({}))
		assert_false(Replay.is_schema_2({ schema_version = nil }))
	end,

	test_apply_bad_schema_version_leaves_engine_unchanged = function()
		for _, version in ipairs({ 3, 1, 2.5, "2" }) do
			local eng = fresh_engine()
			local prev = dirty_engine(eng)
			local ok, err = pcall(function()
				eng:applyReplayState(schema2_replay({ schema_version = version }))
			end)
			assert_false(ok, "schema_version " .. tostring(version) .. " rejected on apply")
			local m = tostring(err)
			assert_true(m:find("schema_version") ~= nil, m)
			-- The old comparator raised a raw "attempt to compare" error after
			-- the fever commit; the validator must fail cleanly instead.
			assert_true(m:find("attempt to compare") == nil, m)
			assert_engine_unchanged(eng, prev)
		end
	end,

	test_apply_rejects_malformed_schema2_fields_before_mutation = function()
		local cases = {
			{ label = "pegs not a table",
			  patch = { pegs = "nonsense" },
			  expect = "pegs to be a table" },
			{ label = "peg entry not a table",
			  patch = { pegs = { "nonsense" } },
			  expect = "must be a table, got" },
			{ label = "peg original_index wrong type",
			  patch = { pegs = { { original_index = "x", type = "blue", hit = false } } },
			  expect = "original_index must be a number" },
			{ label = "missing level_name",
			  drop = { "level_name" },
			  expect = "level_name" },
			{ label = "peg type missing",
			  patch = { pegs = { { original_index = 1, hit = false } } },
			  expect = "type must be a string" },
			{ label = "peg hit wrong type",
			  patch = { pegs = { { original_index = 1, type = "blue", hit = "false" } } },
			  expect = "hit must be a boolean" },
			{ label = "peg x wrong type",
			  patch = { pegs = { { original_index = 1, type = "blue", hit = false,
			      x = "600" } } },
			  expect = ".x must be a number" },
			{ label = "peg motion not a table",
			  patch = { pegs = { { original_index = 1, type = "blue", hit = false,
			      motion = 5 } } },
			  expect = "motion must be a table" },
			{ label = "bucket not a table",
			  patch = { bucket = "nope" },
			  expect = "bucket must be a table" },
			{ label = "balls not a table",
			  patch = { balls = 42 },
			  expect = "balls must be a table" },
			{ label = "ball x wrong type",
			  patch = { balls = { { id = 1, x = "100", y = 50, vx = 1, vy = 1 } } },
			  expect = "must be a number" },
			{ label = "hitCounter wrong type",
			  patch = { hitCounter = "36" },
			  expect = "hitCounter must be a number" },
			{ label = "isFever wrong type",
			  patch = { isFever = "yes" },
			  expect = "isFever must be a boolean" },
		}
		for _, c in ipairs(cases) do
			local data = schema2_replay(c.patch)
			if c.drop then
				for _, f in ipairs(c.drop) do data[f] = nil end
			end
			local eng = fresh_engine()
			local prev = dirty_engine(eng)
			local ok, err = pcall(function()
				eng:applyReplayState(data)
			end)
			assert_false(ok, c.label .. ": rejected before any engine mutation")
			assert_true(tostring(err):find(c.expect) ~= nil,
				c.label .. ": " .. tostring(err))
			assert_engine_unchanged(eng, prev)
		end
	end,

	test_schema2_capture_round_trip_with_line_metadata = function()
		-- A peg carrying authoring line metadata round-trips through
		-- capture -> load -> validate with every field intact.
		local eng = fresh_engine()
		eng.pegs[1].line = { id = "rail", index = 2, count = 8, closed = false, gap = 0 }
		eng.pegs[2].line = { id = "ring", index = 8, count = 8, closed = true, gap = 3.5 }
		eng.pegs[2].hit = true
		local ball = eng:registerBall(Ball.new(100, 50))
		Replay.capture(CAPTURE_FILE, {
			level_name = "test",
			isFever = false,
			pegs = eng.pegs,
			bucket = eng.bucket,
			balls = { ball },
		})
		local data = Replay.load(CAPTURE_FILE)
		assert_true(data ~= nil, "capture loads")
		assert_true(Replay.is_schema_2(data), "schema_version 2")
		local ok, err = Replay.validate(data)
		assert_true(ok, "line metadata validates: " .. tostring(err))
		local r1, r2 = data.pegs[1], data.pegs[2]
		assert_eq(r1.line.id, "rail")
		assert_eq(r1.line.index, 2)
		assert_eq(r1.line.count, 8)
		assert_false(r1.line.closed)
		assert_eq(r1.line.gap, 0)
		assert_eq(r2.line.id, "ring")
		assert_true(r2.line.closed)
		assert_eq(r2.line.gap, 3.5)
		-- The restore path treats the level as the source of truth for line
		-- metadata (level peg tables are authoritative), so the loaded table
		-- validates structurally and the level's own pegs are not replaced.
		local eng2 = fresh_engine()
		eng2:applyReplayState(data)
		assert_eq(eng2.pegs[1].line, nil,
			"restore keeps the level's own line metadata")
		assert_eq(eng2.pegs[2].hit, true, "captured hit state still restored")
	end,

	test_validate_rejects_malformed_line_tables = function()
		local cases = {
			{ label = "line not a table",
			  patch = { pegs = { { original_index = 1, type = "blue",
			      hit = false, line = "rail" } } },
			  expect = "line must be a table" },
			{ label = "line.id wrong type",
			  patch = { pegs = { { original_index = 1, type = "blue",
			      hit = false, line = { id = 2 } } } },
			  expect = "line.id must be a string" },
			{ label = "line.index wrong type",
			  patch = { pegs = { { original_index = 1, type = "blue",
			      hit = false, line = { id = "rail", index = "2" } } } },
			  expect = "line.index must be a number" },
			{ label = "line.count wrong type",
			  patch = { pegs = { { original_index = 1, type = "blue",
			      hit = false, line = { id = "rail", index = 2, count = "8" } } } },
			  expect = "line.count must be a number" },
			{ label = "line.closed wrong type",
			  patch = { pegs = { { original_index = 1, type = "blue",
			      hit = false, line = { id = "rail", index = 2, count = 8,
			        closed = "false" } } } },
			  expect = "line.closed must be a boolean" },
			{ label = "line.gap wrong type",
			  patch = { pegs = { { original_index = 1, type = "blue",
			      hit = false, line = { id = "rail", index = 2, count = 8,
			        closed = false, gap = "0" } } } },
			  expect = "line.gap must be a number" },
		}
		for _, c in ipairs(cases) do
			local eng = fresh_engine()
			local prev = dirty_engine(eng)
			local ok, err = pcall(function()
				eng:applyReplayState(schema2_replay(c.patch))
			end)
			assert_false(ok, c.label .. ": rejected before any engine mutation")
			assert_true(tostring(err):find(c.expect) ~= nil,
				c.label .. ": " .. tostring(err))
			assert_engine_unchanged(eng, prev)
		end
	end,

	test_legacy_captures_with_line_fields_accepted = function()
		-- Files written before the schema-2 validator (no schema_version)
		-- carry whatever fields existed; a stray line table in one must not
		-- break loading, and a line-less board stays untouched.
		local data = make_replay_data(false)
		data.pegs[1].line = { id = "old", index = 1, count = 2, closed = false, gap = 0 }
		local ok, err = Replay.validate(data)
		assert_true(ok, "legacy capture with line table accepted: " .. tostring(err))
	end,

	test_path_replay_continuation_matches_through_seam_and_pause = function()
		local Path = require("src.systems.path")
		local path = Path.new({ segments = {
			{ kind = "arc", center = { x = 500, y = 400 }, radius = 100,
				theta_start = 0, sweep = math.pi * 2 },
		}, closed = true })
		local length = path:length()
		local defs = { conveyor = { kind = "path", path = path, speed = 240,
			duration_time = 0.4, pause_time = 0.2 } }

		local function build_engine()
			local eng = H.new_engine()
			local a = Peg.new(0, 0, "blue", 20)
			a.motion = { circuit = "conveyor", phase = length - 110 }
			local b = Peg.new(0, 0, "blue", 20)
			b.motion = { circuit = "conveyor", phase = 20 }
			H.setup_engine(eng, { a, b }, { red = 0, green = 0 }, 1)
			eng.level_circuits = defs
			Circuits.initialize(eng.pegs, eng.level_circuits)
			return eng
		end

		local uninterrupted = build_engine()
		local dt = 1 / 60
		local capture_step = 30
		local total_steps = 120

		for _ = 1, capture_step do
			Circuits.update(uninterrupted.pegs, defs, dt)
		end
		assert_true(uninterrupted.pegs[1].motion.time < length, "capture precedes the seam")
		assert_eq(uninterrupted.pegs[1].motion.state, "paused", "capture preserves a held boundary")
		local ball = uninterrupted:registerBall(Ball.new(600, 350))
		ball.launched, ball.vy = true, 250
		uninterrupted.active_balls = { ball }
		uninterrupted.shot_id = 1
		local capture_file = "temp/test_path_replay_capture.lua"
		Replay.capture(capture_file, {
			level_name = "test",
			isFever = false,
			pegs = uninterrupted.pegs,
			bucket = uninterrupted.bucket,
			balls = { ball },
		})
		local data = Replay.load(capture_file)
		assert_true(data ~= nil, "path capture loads")

		local resumed = build_engine()
		resumed:applyReplayState(data)
		for i, peg in ipairs(uninterrupted.pegs) do
			local q = resumed.pegs[i]
			assert_eq(q.motion.time, peg.motion.time, "captured path time restored")
			assert_eq(q.motion.state, peg.motion.state, "pause state restored")
			assert_eq(q.motion.timer, peg.motion.timer, "cycle timer restored")
			assert_eq(q.x, peg.x, "captured position restored")
			assert_eq(q.y, peg.y)
		end

		local original_steps = H.make_recorder(uninterrupted)
		local resumed_steps = H.make_recorder(resumed)
		local saw_seam_crossing, saw_resume = false, false
		for _ = capture_step + 1, total_steps do
			local before = resumed.pegs[1].motion.time
			for _, engine in ipairs({ uninterrupted, resumed }) do
				engine.sim_step_id = engine.sim_step_id + 1
				engine:savePreviousState()
				engine:stepSimulation(dt)
			end
			if before < length and resumed.pegs[1].motion.time >= length then
				saw_seam_crossing = true
			end
			if resumed.pegs[1].motion.state == "moving" then saw_resume = true end
			assert_eq(#resumed.active_balls, #uninterrupted.active_balls)
			for i, original in ipairs(uninterrupted.active_balls) do
				for _, field in ipairs({ "x", "y", "vx", "vy" }) do
					assert_eq(resumed.active_balls[i][field], original[field], "continued ball " .. field)
				end
			end
			for i, peg in ipairs(uninterrupted.pegs) do
				local q = resumed.pegs[i]
				assert_eq(q.motion.time, peg.motion.time,
					"phase progression matches across the seam and pauses")
				assert_eq(q.motion.state, peg.motion.state)
				assert_eq(q.motion.timer, peg.motion.timer)
				assert_eq(q.x, peg.x, "continued transform matches")
				assert_eq(q.y, peg.y)
			end
		end

		local contacts = 0
		for i, step in ipairs(original_steps) do
			local restored = resumed_steps[i]
			assert_eq(#restored.raw_events, #step.raw_events)
			for j, event in ipairs(step.raw_events) do
				for key, value in pairs(event) do
					assert_eq(restored.raw_events[j][key], value, "continued event " .. key)
				end
				if event.type == "ball_contacted_peg" then contacts = contacts + 1 end
			end
		end
		assert_true(contacts > 0, "restored physics exercises real peg contacts")
		assert_true(saw_resume, "restored pause resumes")
		assert_true(saw_seam_crossing, "the resumed window crosses the seam")
	end,
}
