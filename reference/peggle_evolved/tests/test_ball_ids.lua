-- Stable ball-ID allocation tests: Engine:registerBall/unregisterBall
-- contract with permanent identity namespace, validation, and atomicity.
local H = require("tests.helpers.engine_helpers")
local Ball = require("src.entities.ball")
local Peg = require("src.entities.peg")
local LevelManager = require("src.systems.level_manager")
local Config = require("src.config")

local function fresh_engine()
	local eng = H.new_engine()
	H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
	return eng
end

return {
	setup = function()
		LevelManager.virtual_width = 1200
		LevelManager.virtual_height = 1900
		Config.virtual_width = 1200
		Config.virtual_height = 1900
	end,

	-- 1. Automatic IDs start at 1 for a new Engine and increment
	--    deterministically.
	test_auto_ids_start_at_1_and_increment = function()
		local eng = fresh_engine()
		local b1 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b1.id, 1)
		assert_eq(eng.next_ball_id, 2)
		local b2 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b2.id, 2)
		assert_eq(eng.next_ball_id, 3)
		local b3 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b3.id, 3)
		assert_eq(eng.next_ball_id, 4)
	end,

	-- Verify IDs are positive finite integers (not addresses, strings, etc.).
	test_ball_ids_are_positive_integers = function()
		local eng = fresh_engine()
		for _ = 1, 10 do
			local b = eng:registerBall(Ball.new(0, 0))
			assert_true(type(b.id) == "number" and b.id > 0 and b.id == math.floor(b.id),
				"positive integer id")
			assert_true(b.id <= 9007199254740991, "within safe integer range")
		end
	end,

	-- 2. Registering an explicit ID advances later automatic allocation.
	test_explicit_id_advances_allocator = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0)
		b.id = 5
		eng:registerBall(b)
		assert_eq(eng.next_ball_id, 6, "allocator advanced past explicit id 5")
		local fresh = eng:registerBall(Ball.new(0, 0))
		assert_eq(fresh.id, 6, "next auto gets 6")
	end,

	-- 3. Multiple explicit IDs arriving out of order result in automatic
	--    allocation above the maximum consumed ID.
	test_out_of_order_explicit_ids = function()
		local eng = fresh_engine()
		local b10 = Ball.new(0, 0); b10.id = 10
		eng:registerBall(b10)
		assert_eq(eng.next_ball_id, 11)

		local b2 = Ball.new(0, 0); b2.id = 2
		eng:registerBall(b2)
		assert_eq(eng.next_ball_id, 11, "allocator not rewound by lower id")

		local b7 = Ball.new(0, 0); b7.id = 7
		eng:registerBall(b7)
		assert_eq(eng.next_ball_id, 11)

		local auto = eng:registerBall(Ball.new(0, 0))
		assert_eq(auto.id, 11, "auto allocation above max consumed (10)")
	end,

	-- 4. Re-registering the same currently live ball is idempotent.
	test_same_ball_twice_is_idempotent = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		assert_eq(b.id, 1)
		eng:registerBall(b)
		eng:registerBall(b)
		assert_eq(b.id, 1)
		assert_eq(eng.next_ball_id, 2, "re-registering same ball does not advance allocator")
		local b2 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b2.id, 2, "next ball still gets 2")
	end,

	-- 5. Two different live balls with the same ID are rejected.
	test_duplicate_live_id_rejected = function()
		local eng = fresh_engine()
		local b1 = Ball.new(0, 0); b1.id = 7
		eng:registerBall(b1)
		local b2 = Ball.new(0, 0); b2.id = 7
		local ok, err = pcall(function() eng:registerBall(b2) end)
		assert_false(ok, "duplicate live id rejected")
		-- Either "duplicate live ball id" or "already consumed" is valid;
		-- both checks prevent reuse.
		local msg = tostring(err)
		assert_true(msg:find("duplicate live ball id") ~= nil
			or msg:find("already consumed") ~= nil, msg)
	end,

	-- 6. An ID cannot be reused after unregisterBall.
	test_id_not_reusable_after_unregister = function()
		local eng = fresh_engine()
		local b1 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b1.id, 1)
		eng:unregisterBall(b1)
		-- Try to register a different ball with the same id 1.
		local b2 = Ball.new(0, 0); b2.id = 1
		local ok, err = pcall(function() eng:registerBall(b2) end)
		assert_false(ok, "id 1 already consumed, cannot be reused")
		assert_true(tostring(err):find("already consumed") ~= nil, tostring(err))
		-- Autos still skip over consumed IDs.
		local b3 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b3.id, 2, "auto allocation skips consumed id 1")
	end,

	-- 7. resetTurn does not reuse IDs from the prior turn.
	test_reset_turn_does_not_reuse_ids = function()
		local eng = fresh_engine()
		-- Register balls as resetTurn would.
		local b1 = Ball.new(100, 50); b1.id = 41
		local b2 = Ball.new(200, 50); b2.id = 42
		eng:resetTurn({ b1, b2 })
		assert_eq(eng.next_ball_id, 43)
		-- Simulate end of turn: unregister balls.
		eng:unregisterBall(b1)
		eng:unregisterBall(b2)
		-- Next resetTurn with new balls -- IDs 41, 42 are consumed.
		local b3 = Ball.new(100, 50); b3.id = 41
		local ok = pcall(function()
			local turn = { b3 }
			eng.live_ball_ids = {}
			eng.live_id_by_ball = {}
			for _, bb in ipairs(turn) do eng:registerBall(bb) end
		end)
		assert_false(ok, "id 41 cannot be reused in next turn")
	end,

	-- 8. setupLevel does not reset the identity namespace but does clear
	--    all live mappings, including those not in active_balls.
	test_setup_level_does_not_reset_identity = function()
		local eng = fresh_engine()
		local b1 = eng:registerBall(Ball.new(0, 0)) -- id 1
		local b2 = eng:registerBall(Ball.new(0, 0)) -- id 2
		assert_eq(eng.next_ball_id, 3, "next_ball_id advanced to 3")
		-- Call setupLevel (the real production path).
		eng:setupLevel("level1")
		assert_eq(eng.next_ball_id, 3, "next_ball_id preserved across setupLevel")
		assert_true(eng.used_ball_ids[1], "id 1 still consumed after setupLevel")
		assert_true(eng.used_ball_ids[2], "id 2 still consumed after setupLevel")
		-- Live registries must be empty.
		assert_true(next(eng.live_ball_ids) == nil, "live_ball_ids empty after setupLevel")
		assert_true(next(eng.live_id_by_ball) == nil, "live_id_by_ball empty after setupLevel")
		assert_eq(#eng.active_balls, 0, "active_balls empty after setupLevel")
		-- New auto-allocation after setupLevel gets 3.
		local b = eng:registerBall(Ball.new(0, 0))
		assert_eq(b.id, 3, "auto id after setupLevel is above consumed")
	end,

	-- 9. A different newly constructed Engine may start again at ID 1.
	test_independent_allocation_across_engines = function()
		local e1 = fresh_engine()
		local e2 = fresh_engine()
		local a1 = e1:registerBall(Ball.new(0, 0))
		local b1 = e2:registerBall(Ball.new(0, 0))
		assert_eq(a1.id, 1)
		assert_eq(b1.id, 1, "separate engine instances start at 1")
		e1:registerBall(Ball.new(0, 0))
		assert_eq(e2.next_ball_id, 2, "no cross-instance leakage")
	end,

	-- 10. Changing ball.id after registration is detected (both registerBall
	--     and unregisterBall check).
	test_changing_id_after_registration_detected_on_reregister = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		assert_eq(b.id, 1)
		b.id = 99
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "mutation detected on re-registration")
		assert_true(tostring(err):find("ball id changed") ~= nil, tostring(err))
	end,

	test_changing_id_after_registration_detected_on_unregister = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		assert_eq(b.id, 1)
		b.id = 99
		local ok, err = pcall(function() eng:unregisterBall(b) end)
		assert_false(ok, "mutation detected on unregistration")
		assert_true(tostring(err):find("ball id changed") ~= nil, tostring(err))
	end,

	-- 11. Each invalid ID class is rejected.
	test_reject_invalid_id_zero = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 0
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "id 0 rejected")
		assert_true(tostring(err):find("positive") ~= nil, tostring(err))
	end,

	test_reject_invalid_id_negative = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = -5
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "negative id rejected")
		assert_true(tostring(err):find("positive") ~= nil, tostring(err))
	end,

	test_reject_invalid_id_fractional = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 3.5
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "fractional id rejected")
		assert_true(tostring(err):find("integer") ~= nil, tostring(err))
	end,

	test_reject_invalid_id_string = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = "hello"
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "string id rejected")
		assert_true(tostring(err):find("number") ~= nil, tostring(err))
	end,

	test_reject_invalid_id_nan = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 0 / 0
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "NaN id rejected")
		assert_true(tostring(err):find("NaN") ~= nil, tostring(err))
	end,

	test_reject_invalid_id_pos_inf = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = math.huge
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "positive infinity rejected")
		assert_true(tostring(err):find("positive infinity") ~= nil, tostring(err))
	end,

	test_reject_invalid_id_neg_inf = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = -math.huge
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "negative infinity rejected")
		assert_true(tostring(err):find("negative infinity") ~= nil, tostring(err))
	end,

	-- 12. Failed registration leaves allocator and registries unchanged.
	test_failed_registration_atomic = function()
		local eng = fresh_engine()
		local b1 = eng:registerBall(Ball.new(0, 0)) -- id 1, next = 2
		assert_eq(eng.next_ball_id, 2)

		-- Failed: duplicate live id (already registered ball id 1, different table).
		local b2 = Ball.new(0, 0); b2.id = 1
		pcall(function() eng:registerBall(b2) end)

		-- State unchanged.
		assert_eq(eng.next_ball_id, 2, "allocator unchanged after failure")
		assert_true(eng.live_ball_ids[1] == b1, "live mapping for id 1 unchanged")
		assert_true(eng.live_id_by_ball[b1] == 1, "reverse mapping unchanged")
		assert_true(eng.live_id_by_ball[b2] == nil, "failed ball not mapped")

		-- Can still register a valid ball.
		local b3 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b3.id, 2, "auto allocation still works after failure")
	end,

	-- 13. IDs not derived from table identity.
	test_ids_not_derived_from_table_identity = function()
		local eng = fresh_engine()
		local b1 = eng:registerBall(Ball.new(0, 0))
		local b2 = eng:registerBall(Ball.new(0, 0))
		assert_true(b1.id ~= b2.id)
		assert_eq(b1.id + 1, b2.id, "sequential allocation, not addresses")
	end,

	-- Auto allocation continues from the advanced next_ball_id; it does not
	-- rewind to fill gaps below consumed explicit IDs. The skip-gap safety
	-- loop is tested by placing next_ball_id directly on a consumed entry.
	test_auto_allocation_above_consumed_explicit = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 5
		eng:registerBall(b)
		eng:unregisterBall(b)
		-- ID 5 is consumed. next_ball_id was advanced to 6.
		-- Auto allocation continues monotonically from next_ball_id.
		local b2 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b2.id, 6, "auto allocation beyond consumed explicit id 5")

		-- Skip-gap safety: place next_ball_id on a consumed slot and verify
		-- the while loop advances past it.
		eng.used_ball_ids[10] = true
		eng.next_ball_id = 10
		local b3 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b3.id, 11, "auto allocation skips consumed next_ball_id")
	end,

	-- =====================================================================
	-- Maximum-ID and allocator-exhaustion safety tests.
	-- =====================================================================

	-- 14. Maximum explicit ID is valid.
	test_max_explicit_id_valid = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 9007199254740991
		local registered = eng:registerBall(b)
		assert_eq(registered.id, 9007199254740991, "max explicit id accepted")
		assert_true(eng.live_ball_ids[9007199254740991] == b, "live mapping for max id")
		assert_true(eng.live_id_by_ball[b] == 9007199254740991, "reverse mapping for max id")
		assert_true(eng.used_ball_ids[9007199254740991] == true, "max id marked consumed")
		assert_eq(eng.next_ball_id, 9007199254740991 + 1, "allocator advanced past max, sentinel state")
	end,

	-- 15. Automatic allocation after consuming the maximum ID fails.
	test_auto_after_max_exhaustion = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 9007199254740991
		eng:registerBall(b)

		local b2 = Ball.new(0, 0)
		local ok, err = pcall(function() eng:registerBall(b2) end)
		assert_false(ok, "auto allocation after max must fail")
		assert_true(tostring(err):find("allocator exhausted") ~= nil
			or tostring(err):find("no valid automatic"), tostring(err))
		assert_true(b2.id == nil, "failed ball has no id")
	end,

	-- 16. Automatic exhaustion failure is atomic.
	test_auto_exhaustion_atomic = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 9007199254740991
		eng:registerBall(b)

		local next_before = eng.next_ball_id
		local b2 = Ball.new(0, 0)
		pcall(function() eng:registerBall(b2) end)

		assert_eq(eng.next_ball_id, next_before, "next_ball_id unchanged by failed auto")
		assert_true(b2.id == nil, "failed ball id is nil")
		assert_true(eng.used_ball_ids[9007199254740991 + 1] == nil, "no out-of-range key inserted into used_ball_ids")
		assert_true(eng.live_ball_ids[9007199254740991 + 1] == nil, "no out-of-range key in live_ball_ids")
		assert_true(eng.live_id_by_ball[b2] == nil, "failed ball not in reverse mapping")

		-- The maximum-ID ball remains correctly mapped.
		assert_true(eng.live_ball_ids[9007199254740991] == b, "max-id ball still in live mapping")
		assert_true(eng.live_id_by_ball[b] == 9007199254740991, "max-id ball reverse mapping intact")
	end,

	-- 17. Repeated automatic exhaustion attempts fail deterministically
	--     without corrupting state.
	test_repeated_auto_exhaustion = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 9007199254740991
		eng:registerBall(b)

		local state_after_first = {
			next = eng.next_ball_id,
			used_max_plus = eng.used_ball_ids[9007199254740991 + 1],
			live_max_plus = eng.live_ball_ids[9007199254740991 + 1],
		}

		local b1 = Ball.new(0, 0)
		local ok1 = pcall(function() eng:registerBall(b1) end)
		local b2 = Ball.new(0, 0)
		local ok2 = pcall(function() eng:registerBall(b2) end)

		assert_false(ok1, "first auto failure")
		assert_false(ok2, "second auto failure")
		assert_eq(eng.next_ball_id, state_after_first.next, "next_ball_id same after both failures")
		assert_true(eng.used_ball_ids[9007199254740991 + 1] == state_after_first.used_max_plus, "used_ball_ids unchanged")
		assert_true(eng.live_ball_ids[9007199254740991 + 1] == state_after_first.live_max_plus, "live_ball_ids unchanged")
		assert_true(b1.id == nil, "first failed ball has nil id")
		assert_true(b2.id == nil, "second failed ball has nil id")
	end,

	-- 18. When next_ball_id points at an already-consumed MAX_BALL_ID,
	--     the scan reaches beyond the valid domain and exhausts cleanly.
	test_consumed_max_skip_boundary = function()
		local eng = fresh_engine()
		eng.used_ball_ids[9007199254740991] = true
		eng.next_ball_id = 9007199254740991

		local b = Ball.new(0, 0)
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "auto with frontier on consumed max must fail")
		assert_true(tostring(err):find("allocator exhausted") ~= nil
			or tostring(err):find("no valid automatic"), tostring(err))
		assert_true(b.id == nil, "failed ball has no id")
		assert_eq(eng.next_ball_id, 9007199254740991, "next_ball_id preserved at frontier")
		assert_true(eng.used_ball_ids[9007199254740991 + 1] == nil, "no out-of-range key in used_ball_ids")
		assert_true(eng.live_ball_ids[9007199254740991 + 1] == nil, "no out-of-range key in live_ball_ids")
	end,

	-- 19. Existing ordinary behavior remains intact.
	test_ordinary_behavior_preserved = function()
		local eng = fresh_engine()

		local b1 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b1.id, 1)
		local b2 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b2.id, 2)
		local b3 = eng:registerBall(Ball.new(0, 0))
		assert_eq(b3.id, 3)

		local explicit = Ball.new(0, 0); explicit.id = 42
		eng:registerBall(explicit)
		assert_eq(eng.next_ball_id, 43, "explicit advances allocator")

		eng:unregisterBall(b1)
		local reused_attempt = Ball.new(0, 0); reused_attempt.id = 1
		local ok, err = pcall(function() eng:registerBall(reused_attempt) end)
		assert_false(ok, "id 1 cannot be reused")
		assert_true(tostring(err):find("already consumed") ~= nil, tostring(err))

		local fresh = eng:registerBall(Ball.new(0, 0))
		assert_eq(fresh.id, 43, "auto after explicit 42 gets 43")
	end,

	-- =====================================================================
	-- nil-ID mutation detection tests.
	-- =====================================================================

	-- 20. nil mutation is detected on unregistration.
	test_nil_mutation_detected_on_unregister = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		local registered_id = b.id
		assert_eq(registered_id, 1)

		b.id = nil
		local ok, err = pcall(function() eng:unregisterBall(b) end)
		assert_false(ok, "nil mutation must be detected on unregistration")
		assert_true(tostring(err):find("ball id changed") ~= nil, tostring(err))
	end,

	-- 21. Failed unregistration is atomic (nil mutation).
	test_nil_mutation_unregister_atomic = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		local registered_id = b.id
		local next_before = eng.next_ball_id

		b.id = nil
		pcall(function() eng:unregisterBall(b) end)

		assert_eq(eng.live_ball_ids[registered_id], b,
			"live_ball_ids still points to the ball")
		assert_eq(eng.live_id_by_ball[b], registered_id,
			"live_id_by_ball still equals original ID")
		assert_true(eng.used_ball_ids[registered_id] == true,
			"used_ball_ids[id] remains true")
		assert_eq(eng.next_ball_id, next_before,
			"next_ball_id unchanged")
	end,

	-- 22. Recovery is possible after nil mutation.
	test_recovery_after_nil_mutation = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		local registered_id = b.id

		b.id = nil
		pcall(function() eng:unregisterBall(b) end)

		b.id = registered_id
		eng:unregisterBall(b)

		assert_true(eng.live_ball_ids[registered_id] == nil,
			"live mapping removed after recovery")
		assert_true(eng.live_id_by_ball[b] == nil,
			"reverse mapping removed after recovery")
		assert_true(eng.used_ball_ids[registered_id] == true,
			"ID remains permanently consumed")
	end,

	-- 23. nil mutation is detected on re-registration.
	test_nil_mutation_detected_on_reregister = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		local registered_id = b.id
		local next_before = eng.next_ball_id

		b.id = nil
		local ok, err = pcall(function() eng:registerBall(b) end)
		assert_false(ok, "nil mutation must be detected on re-registration")
		assert_true(tostring(err):find("ball id changed") ~= nil, tostring(err))

		-- State unchanged.
		assert_eq(eng.live_ball_ids[registered_id], b,
			"live mapping unchanged after failed re-registration")
		assert_eq(eng.live_id_by_ball[b], registered_id,
			"reverse mapping unchanged")
		assert_eq(eng.next_ball_id, next_before,
			"allocator unchanged")
		assert_true(b.id == nil, "ball id field remains nil")
		b.id = registered_id
	end,

	-- 24. Existing numeric-mutation behavior remains intact.
	test_numeric_id_mutation_still_detected = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		assert_eq(b.id, 1)

		-- Mutation to a different numeric ID is rejected on unregister.
		b.id = 99
		local ok1, err1 = pcall(function() eng:unregisterBall(b) end)
		assert_false(ok1, "numeric mutation detected on unregister")
		assert_true(tostring(err1):find("ball id changed") ~= nil, tostring(err1))

		-- Restore.
		b.id = 1

		-- Mutation to a different numeric ID is rejected on re-register.
		b.id = 99
		local ok2, err2 = pcall(function() eng:registerBall(b) end)
		assert_false(ok2, "numeric mutation detected on re-register")
		assert_true(tostring(err2):find("ball id changed") ~= nil, tostring(err2))

		-- Restore and unregister cleanly.
		b.id = 1
		eng:unregisterBall(b)
	end,

	-- 25. unregisterBall(nil) remains a no-op.
	test_unregister_nil_is_noop = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		local next_before = eng.next_ball_id

		eng:unregisterBall(nil)

		assert_eq(eng.live_ball_ids[b.id], b, "live mapping intact")
		assert_eq(eng.live_id_by_ball[b], b.id, "reverse mapping intact")
		assert_eq(eng.next_ball_id, next_before, "allocator unchanged")
	end,

	-- 26. Unregistering an unregistered object remains a no-op.
	test_unregister_unregistered_is_noop = function()
		local eng = fresh_engine()
		local b = Ball.new(0, 0); b.id = 999
		local next_before = eng.next_ball_id

		eng:unregisterBall(b) -- never registered

		assert_eq(eng.next_ball_id, next_before, "allocator unchanged")
		assert_true(eng.live_id_by_ball[b] == nil, "not in reverse map")
	end,

	-- 27. Re-registering the same correctly identified live ball remains idempotent.
	test_same_ball_reregister_from_nil_path = function()
		local eng = fresh_engine()
		local b = eng:registerBall(Ball.new(0, 0))
		local registered_id = b.id

		-- Set to nil, attempt unregister (should fail), restore, re-register.
		b.id = nil
		pcall(function() eng:unregisterBall(b) end)
		b.id = registered_id
		eng:registerBall(b) -- idempotent re-registration
		assert_eq(b.id, registered_id, "id preserved")
		assert_eq(eng.next_ball_id, registered_id + 1, "allocator unchanged by idempotent call")
	end,

	-- =====================================================================
	-- setupLevel stale live mapping cleanup tests.
	-- =====================================================================

	-- 28. setupLevel clears live mappings for registered balls not in
	--     active_balls (the stale live mapping defect).
	test_setup_level_clears_stale_live_mappings = function()
		local eng = fresh_engine()

		-- Register three distinct balls.
		local b1 = eng:registerBall(Ball.new(0, 0)) -- id 1
		local b2 = eng:registerBall(Ball.new(0, 0)) -- id 2
		local b3 = eng:registerBall(Ball.new(0, 0)) -- id 3

		-- Place only b1 and b2 into active_balls.
		eng.active_balls = { b1, b2 }
		-- b3 is deliberately NOT in active_balls.

		local id1, id2, id3 = b1.id, b2.id, b3.id
		local next_before = eng.next_ball_id
		assert_eq(id1, 1)
		assert_eq(id2, 2)
		assert_eq(id3, 3)
		assert_eq(next_before, 4)

		-- Record that all three are consumed.
		assert_true(eng.used_ball_ids[id1], "id 1 consumed")
		assert_true(eng.used_ball_ids[id2], "id 2 consumed")
		assert_true(eng.used_ball_ids[id3], "id 3 consumed")

		-- All three are live before setupLevel.
		assert_true(eng.live_ball_ids[id1] == b1, "b1 live before setupLevel")
		assert_true(eng.live_ball_ids[id2] == b2, "b2 live before setupLevel")
		assert_true(eng.live_ball_ids[id3] == b3, "b3 live before setupLevel")
		assert_true(eng.live_id_by_ball[b1] == id1, "b1 reverse mapping before")
		assert_true(eng.live_id_by_ball[b2] == id2, "b2 reverse mapping before")
		assert_true(eng.live_id_by_ball[b3] == id3, "b3 reverse mapping before")

		-- Call the real Engine:setupLevel path used by existing tests.
		eng:setupLevel("level1")

		-- Assert active_balls is empty.
		assert_eq(#eng.active_balls, 0, "active_balls empty after setupLevel")

		-- Assert live registries are empty — this includes b3 which was
		-- never in active_balls.
		assert_true(next(eng.live_ball_ids) == nil,
			"live_ball_ids empty after setupLevel")
		assert_true(next(eng.live_id_by_ball) == nil,
			"live_id_by_ball empty after setupLevel")

		-- All three old IDs remain permanently consumed.
		assert_true(eng.used_ball_ids[id1], "id 1 still consumed after setupLevel")
		assert_true(eng.used_ball_ids[id2], "id 2 still consumed after setupLevel")
		assert_true(eng.used_ball_ids[id3], "id 3 still consumed after setupLevel")

		-- next_ball_id did not rewind.
		assert_eq(eng.next_ball_id, next_before,
			"next_ball_id did not rewind across setupLevel")

		-- Register a fresh automatic ball after setup.
		local fresh = eng:registerBall(Ball.new(0, 0))
		assert_eq(fresh.id, next_before,
			"fresh auto ball receives expected next id above all consumed")

		-- Attempt to re-register old b3 with its retained consumed id.
		local ok, err = pcall(function() eng:registerBall(b3) end)
		assert_false(ok, "old ball with consumed id rejected after setupLevel")
		assert_true(tostring(err):find("already consumed") ~= nil, tostring(err))
		assert_eq(eng.next_ball_id, next_before + 1,
			"allocator not corrupted by failed re-registration")
		assert_true(eng.live_ball_ids[fresh.id] == fresh,
			"fresh ball still in live mapping")
		assert_true(eng.live_id_by_ball[b3] == nil,
			"old ball not in reverse mapping after rejection")
	end,

	-- 29. Ordinary active balls are cleared by setupLevel (sanity).
	test_setup_level_clears_ordinary_active_balls = function()
		local eng = fresh_engine()
		local b1 = eng:registerBall(Ball.new(0, 0)) -- id 1
		local b2 = eng:registerBall(Ball.new(0, 0)) -- id 2
		eng.active_balls = { b1, b2 }

		eng:setupLevel("level1")

		assert_eq(#eng.active_balls, 0)
		assert_true(next(eng.live_ball_ids) == nil)
		assert_true(next(eng.live_id_by_ball) == nil)
		assert_true(eng.used_ball_ids[1])
		assert_true(eng.used_ball_ids[2])
		assert_eq(eng.next_ball_id, 3)
	end,

	-- =====================================================================
	-- resetTurn failure-atomic tests (Phase 1 identity hardening).
	-- =====================================================================

	-- 31. Duplicate explicit ID after a valid first entry: batch
	--     planning must fail before any state mutation and leave all
	--     pre-call state intact.
	test_reset_turn_duplicate_id_rollback = function()
		local eng = fresh_engine()

		local old_b1 = Ball.new(100, 50); old_b1.id = 41
		local old_b2 = Ball.new(200, 50); old_b2.id = 42
		eng.active_balls = { old_b1, old_b2 }
		eng.live_ball_ids = { [41] = old_b1, [42] = old_b2 }
		eng.live_id_by_ball = { [old_b1] = 41, [old_b2] = 42 }
		eng.used_ball_ids[41] = true
		eng.used_ball_ids[42] = true
		eng.next_ball_id = 43

		eng.clearQueue = { { hit_order = 1 } }
		eng.clearTimer = 0.5
		eng.turnPegsHit = { { type = "blue" } }
		eng.scoredThisStep = true
		eng.bonusScore = 500
		eng.styleScore = 200
		eng.shot_end_reason = "fell_out"
		eng.last_removal_reason = "fell_out"
		eng.current_shot_timeline = { {} }
		eng.shot_id = 5
		eng.shot_initial_step = 100
		eng.shot_final_step = 150

		local hud_calls = 0
		eng.callbacks.onHUDRefresh = function() hud_calls = hud_calls + 1 end

		local prev_active = eng.active_balls
		local prev_live_ids = eng.live_ball_ids
		local prev_live_by_ball = eng.live_id_by_ball
		local prev_next = eng.next_ball_id
		local prev_clear_queue = eng.clearQueue
		local prev_clear_timer = eng.clearTimer
		local prev_turn_hits = eng.turnPegsHit
		local prev_scored = eng.scoredThisStep
		local prev_bonus = eng.bonusScore
		local prev_style = eng.styleScore
		local prev_shot_end = eng.shot_end_reason
		local prev_last_rem = eng.last_removal_reason
		local prev_timeline = eng.current_shot_timeline
		local prev_shot_id = eng.shot_id
		local prev_shot_init = eng.shot_initial_step
		local prev_shot_final = eng.shot_final_step

		local b1 = Ball.new(100, 50); b1.id = 20
		local b2 = Ball.new(200, 50); b2.id = 20

		local ok, err = pcall(function() eng:resetTurn({ b1, b2 }) end)
		assert_false(ok, "resetTurn with duplicate ids must fail")
		assert_true(tostring(err):find("already consumed") ~= nil
			or tostring(err):find("duplicate") ~= nil, tostring(err))

		assert_true(eng.active_balls == prev_active, "active_balls unchanged")
		assert_true(eng.live_ball_ids == prev_live_ids, "live_ball_ids unchanged")
		assert_true(eng.live_id_by_ball == prev_live_by_ball, "live_id_by_ball unchanged")
		assert_eq(eng.next_ball_id, prev_next, "next_ball_id unchanged")
		assert_true(eng.used_ball_ids[20] == nil, "id 20 not consumed")
		assert_true(eng.live_id_by_ball[b1] == nil, "b1 not in reverse mapping")
		assert_true(eng.live_id_by_ball[b2] == nil, "b2 not in reverse mapping")
		assert_true(eng.live_ball_ids[20] == nil, "id 20 not in live mapping")
		assert_eq(b1.id, 20, "b1 explicit id preserved")
		assert_eq(b2.id, 20, "b2 explicit id preserved")

		assert_true(eng.clearQueue == prev_clear_queue, "clearQueue unchanged")
		assert_eq(eng.clearTimer, prev_clear_timer, "clearTimer unchanged")
		assert_true(eng.turnPegsHit == prev_turn_hits, "turnPegsHit unchanged")
		assert_eq(eng.scoredThisStep, prev_scored, "scoredThisStep unchanged")
		assert_eq(eng.bonusScore, prev_bonus, "bonusScore unchanged")
		assert_eq(eng.styleScore, prev_style, "styleScore unchanged")
		assert_eq(eng.shot_end_reason, prev_shot_end, "shot_end_reason unchanged")
		assert_eq(eng.last_removal_reason, prev_last_rem, "last_removal_reason unchanged")
		assert_true(eng.current_shot_timeline == prev_timeline, "current_shot_timeline unchanged")
		assert_eq(eng.shot_id, prev_shot_id, "shot_id unchanged")
		assert_eq(eng.shot_initial_step, prev_shot_init, "shot_initial_step unchanged")
		assert_eq(eng.shot_final_step, prev_shot_final, "shot_final_step unchanged")
		assert_eq(hud_calls, 0, "onHUDRefresh not called on failure")
	end,

	-- 32. Automatic entry followed by an invalid explicit entry: the
	--     first candidate must retain id == nil and no automatic ID
	--     may be consumed.
	test_reset_turn_auto_then_invalid_explicit = function()
		local eng = fresh_engine()
		local old_b = Ball.new(100, 50); old_b.id = 5
		eng.active_balls = { old_b }
		eng.live_ball_ids = { [5] = old_b }
		eng.live_id_by_ball = { [old_b] = 5 }
		eng.used_ball_ids[5] = true
		eng.next_ball_id = 6

		eng.turnPegsHit = { { type = "red" } }
		eng.bonusScore = 100
		eng.styleScore = 50
		eng.scoredThisStep = true
		eng.clearQueue = { {} }
		eng.shot_end_reason = "fell_out"
		eng.shot_id = 3
		eng.shot_initial_step = 10
		eng.shot_final_step = 20

		local prev_next = eng.next_ball_id
		local prev_active = eng.active_balls

		local auto_ball = Ball.new(0, 0)        -- id == nil
		local bad_ball = Ball.new(0, 0); bad_ball.id = 0

		local ok, err = pcall(function() eng:resetTurn({ auto_ball, bad_ball }) end)
		assert_false(ok, "resetTurn with auto then invalid must fail")
		assert_true(tostring(err):find("positive") ~= nil, tostring(err))

		assert_true(auto_ball.id == nil, "auto ball still has nil id after failure")
		assert_eq(bad_ball.id, 0, "bad ball id unchanged")
		assert_true(eng.active_balls == prev_active, "active_balls unchanged")
		assert_eq(eng.next_ball_id, prev_next, "next_ball_id unchanged")
		assert_true(eng.live_id_by_ball[auto_ball] == nil, "auto ball not in reverse mapping")
		assert_true(eng.live_id_by_ball[bad_ball] == nil, "bad ball not in reverse mapping")
		assert_true(eng.used_ball_ids[6] == nil, "no auto id 6 consumed")
	end,

	-- 33. Allocator exhaustion must fail the batch before replacing the
	--     current turn.
	test_reset_turn_auto_exhaustion_rollback = function()
		local eng = fresh_engine()
		local old_b = Ball.new(100, 50); old_b.id = 1
		eng.active_balls = { old_b }
		eng.live_ball_ids = { [1] = old_b }
		eng.live_id_by_ball = { [old_b] = 1 }
		eng.used_ball_ids[1] = true
		eng.next_ball_id = 9007199254740991 + 1  -- exhausted frontier

		eng.clearQueue = { { hit_order = 1 } }
		eng.turnPegsHit = { { type = "green" } }
		eng.bonusScore = 300
		eng.styleScore = 100

		local prev_next = eng.next_ball_id
		local prev_active = eng.active_balls

		local auto_ball = Ball.new(0, 0)  -- id == nil

		local ok, err = pcall(function() eng:resetTurn({ auto_ball }) end)
		assert_false(ok, "resetTurn with exhausted allocator must fail")
		assert_true(tostring(err):find("exhausted") ~= nil
			or tostring(err):find("no valid automatic") ~= nil, tostring(err))

		assert_true(auto_ball.id == nil, "auto ball still has nil id")
		assert_true(eng.active_balls == prev_active, "active_balls unchanged")
		assert_eq(eng.next_ball_id, prev_next, "next_ball_id unchanged")
		assert_true(eng.live_id_by_ball[auto_ball] == nil, "auto ball not registered")
		assert_eq(eng.bonusScore, 300, "bonusScore unchanged")
		assert_eq(eng.clearQueue and #eng.clearQueue, 1, "clearQueue intact")
	end,

	-- 34. Valid mixed batch: explicit + auto + explicit + auto,
	--     deterministic sequential allocation.
	test_reset_turn_valid_mixed_batch = function()
		local eng = fresh_engine()

		local explicit_40 = Ball.new(100, 50); explicit_40.id = 40
		local missing_1 = Ball.new(200, 50)
		local explicit_50 = Ball.new(300, 50); explicit_50.id = 50
		local missing_2 = Ball.new(400, 50)

		local ok, err = pcall(function()
			eng:resetTurn({ explicit_40, missing_1, explicit_50, missing_2 })
		end)
		assert_true(ok, "valid mixed batch succeeds: " .. tostring(err))

		assert_eq(explicit_40.id, 40, "explicit 40 preserved")
		assert_eq(missing_1.id, 41, "first auto gets 41")
		assert_eq(explicit_50.id, 50, "explicit 50 preserved")
		assert_eq(missing_2.id, 51, "second auto gets 51 (above 50)")

		assert_eq(#eng.active_balls, 4, "four active balls")
		assert_true(eng.active_balls[1] == explicit_40, "active[1] order")
		assert_true(eng.active_balls[2] == missing_1, "active[2] order")
		assert_true(eng.active_balls[3] == explicit_50, "active[3] order")
		assert_true(eng.active_balls[4] == missing_2, "active[4] order")

		-- Live mappings consistent.
		assert_true(eng.live_ball_ids[40] == explicit_40, "live map for 40")
		assert_true(eng.live_ball_ids[41] == missing_1, "live map for 41")
		assert_true(eng.live_ball_ids[50] == explicit_50, "live map for 50")
		assert_true(eng.live_ball_ids[51] == missing_2, "live map for 51")
		assert_eq(eng.live_id_by_ball[explicit_40], 40, "reverse map 40")
		assert_eq(eng.live_id_by_ball[missing_1], 41, "reverse map 41")
		assert_eq(eng.live_id_by_ball[explicit_50], 50, "reverse map 50")
		assert_eq(eng.live_id_by_ball[missing_2], 51, "reverse map 51")

		assert_true(eng.used_ball_ids[40], "40 consumed")
		assert_true(eng.used_ball_ids[41], "41 consumed")
		assert_true(eng.used_ball_ids[50], "50 consumed")
		assert_true(eng.used_ball_ids[51], "51 consumed")
		assert_eq(eng.next_ball_id, 52, "next_ball_id at 52")
	end,

	-- 35. Existing behavior: old turn IDs remain permanently consumed
	--     across a successful resetTurn.
	test_reset_turn_old_ids_remain_consumed = function()
		local eng = fresh_engine()
		local b = Ball.new(100, 50); b.id = 41
		eng:resetTurn({ b })
		assert_true(eng.used_ball_ids[41], "id 41 consumed")
		assert_eq(eng.next_ball_id, 42)

		local b2 = Ball.new(100, 50); b2.id = 41
		local ok, err = pcall(function() eng:resetTurn({ b2 }) end)
		assert_false(ok, "id 41 cannot be reused in next resetTurn")
		assert_true(tostring(err):find("already consumed") ~= nil, tostring(err))
		assert_true(eng.used_ball_ids[41], "id 41 still consumed after failure")
	end,

	-- 36. Valid resetTurn with explicit IDs performs gameplay resets
	--     and fires one HUD refresh.
	test_reset_turn_valid_performs_gameplay_resets = function()
		local eng = fresh_engine()

		eng.clearQueue = { { hit_order = 1 } }
		eng.clearTimer = 0.8
		eng.turnPegsHit = { { type = "blue" } }
		eng.scoredThisStep = true
		eng.bonusScore = 500
		eng.styleScore = 200
		eng.shot_end_reason = "fell_out"
		eng.last_removal_reason = "fell_out"
		eng.current_shot_timeline = { {} }
		eng.shot_id = 5
		eng.shot_initial_step = 100
		eng.shot_final_step = 150

		local hud_calls = 0
		eng.callbacks.onHUDRefresh = function() hud_calls = hud_calls + 1 end

		local b = Ball.new(100, 50); b.id = 99
		eng:resetTurn({ b })

		-- Gameplay state reset.
		assert_true(eng.clearQueue == nil, "clearQueue nil after successful reset")
		assert_eq(eng.clearTimer, 0, "clearTimer 0")
		assert_eq(#eng.turnPegsHit, 0, "turnPegsHit empty")
		assert_false(eng.scoredThisStep, "scoredThisStep false")
		assert_eq(eng.bonusScore, 0, "bonusScore 0")
		assert_eq(eng.styleScore, 0, "styleScore 0")
		assert_true(eng.shot_end_reason == nil, "shot_end_reason nil")
		assert_true(eng.last_removal_reason == nil, "last_removal_reason nil")
		assert_true(eng.current_shot_timeline == nil, "current_shot_timeline nil")
		-- shot_id is NOT reset by resetTurn (only at launch).
		assert_eq(eng.shot_id, 5, "shot_id preserved (reset at launch only)")

		assert_eq(hud_calls, 1, "one onHUDRefresh call after successful reset")
		assert_eq(#eng.active_balls, 1, "one active ball")
		assert_eq(b.id, 99, "explicit id preserved")
		assert_true(eng.used_ball_ids[99], "id 99 consumed")
	end,

	-- 37. Default ball is created when initial_balls is nil.
	test_reset_turn_default_ball_created = function()
		local eng = fresh_engine()
		eng:resetTurn()
		assert_eq(#eng.active_balls, 1, "one default ball")
		assert_true(eng.active_balls[1] ~= nil, "default ball exists")
		assert_eq(eng.active_balls[1].id, 1, "default ball gets auto id 1")
		assert_true(eng.live_ball_ids[1] == eng.active_balls[1], "live map for default ball")
		assert_eq(eng.next_ball_id, 2, "next_ball_id advanced")
	end,

	-- 38. Separate Engine instances remain independent across resetTurn.
	test_separate_engines_independent_reset_turn = function()
		local e1 = fresh_engine()
		local e2 = fresh_engine()

		local b1 = Ball.new(100, 50); b1.id = 10
		e1:resetTurn({ b1 })
		local b2 = Ball.new(100, 50); b2.id = 10
		e2:resetTurn({ b2 })

		assert_eq(e1.next_ball_id, 11, "e1 next = 11")
		assert_eq(e2.next_ball_id, 11, "e2 next = 11 (independent)")

		-- Each consumes its own namespace.
		assert_true(e1.used_ball_ids[10], "e1 consumed 10")
		assert_true(e2.used_ball_ids[10], "e2 consumed 10")

		local e1_auto = Ball.new(0, 0)
		local e2_auto = Ball.new(0, 0)
		e1:registerBall(e1_auto)
		e2:registerBall(e2_auto)
		assert_eq(e1_auto.id, 11, "e1 auto gets 11")
		assert_eq(e2_auto.id, 11, "e2 auto gets 11 (independent)")
	end,

	-- 39. Mixed batch with nil initial_balls: explicit + auto.
	test_reset_turn_valid_mixed_with_explicit = function()
		local eng = fresh_engine()
		local explicit = Ball.new(200, 50); explicit.id = 100
		local auto = Ball.new(300, 50)

		eng:resetTurn({ explicit, auto })

		assert_eq(explicit.id, 100, "explicit 100 preserved")
		assert_eq(auto.id, 101, "auto gets 101")
		assert_eq(eng.next_ball_id, 102, "next_ball_id at 102")
		assert_eq(#eng.active_balls, 2)
		assert_true(eng.live_ball_ids[100] == explicit)
		assert_true(eng.live_ball_ids[101] == auto)
		assert_true(eng.used_ball_ids[100])
		assert_true(eng.used_ball_ids[101])
	end,

	-- 30. Separate Engine instances remain independent after setupLevel.
	test_separate_engines_independent_after_setup = function()
		local e1 = fresh_engine()
		local e2 = fresh_engine()

		e1:registerBall(Ball.new(0, 0)) -- id 1 in e1
		e2:registerBall(Ball.new(0, 0)) -- id 1 in e2
		e1:setupLevel("level1")
		e2:setupLevel("level1")

		-- Each engine's live registries are independently empty.
		assert_true(next(e1.live_ball_ids) == nil)
		assert_true(next(e1.live_id_by_ball) == nil)
		assert_true(next(e2.live_ball_ids) == nil)
		assert_true(next(e2.live_id_by_ball) == nil)

		-- But consumed IDs are per-instance and still present.
		assert_true(e1.used_ball_ids[1])
		assert_true(e2.used_ball_ids[1])

		-- New auto allocation in each engine succeeds with its own namespace.
		local b1 = e1:registerBall(Ball.new(0, 0))
		local b2 = e2:registerBall(Ball.new(0, 0))
		assert_eq(b1.id, 2)
		assert_eq(b2.id, 2)
	end,
}
