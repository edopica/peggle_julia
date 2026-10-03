-- ReplayLibrary tests: unique naming, save/load round-trip, list, resolve.
local Replay = require("src.systems.replay")
local ReplayLibrary = require("src.systems.replay_library")

local TEST_DIR = "/tmp/opencode/test_replay_library"

local function reset()
	os.execute("rm -rf " .. TEST_DIR)
	os.execute("mkdir -p " .. TEST_DIR)
	ReplayLibrary.DIR = TEST_DIR
end

local function sample_data(level_name)
	return {
		level_name = level_name or "level1",
		isFever = false,
		hitCounter = 0,
		redPegsHitAmount = 0,
		currentMultiplier = 1,
		pegs = {
			{ original_index = 1, type = "blue", hit = false,
			  base_x = 1, base_y = 2, base_angle = 0, x = 1, y = 2 },
		},
		bucket = { phase = 0, x = 100 },
		balls = { { id = 1, x = 10, y = 20, vx = 1, vy = 2 } },
	}
end

return {
	test_default_name_is_timestamp = function()
		reset()
		local name = ReplayLibrary.defaultName()
		assert_true(name:match("^%d%d%d%d%d%d%d%d_%d%d%d%d%d%d$") ~= nil,
			"default name should be YYYYMMDD_HHMMSS, got " .. tostring(name))
	end,

	test_sanitize_name = function()
		reset()
		assert_eq(ReplayLibrary.sanitizeName("my cool shot!"), "my_cool_shot")
		assert_eq(ReplayLibrary.sanitizeName("already_ok-1"), "already_ok-1")
		assert_eq(ReplayLibrary.sanitizeName("foo.lua"), "foo")
		assert_eq(ReplayLibrary.sanitizeName("!!!"), "")
	end,

	test_save_creates_loadable_capture = function()
		reset()
		local path, err = ReplayLibrary.save(sample_data("level7"))
		assert_true(path ~= nil, "save failed: " .. tostring(err))
		assert_true(ReplayLibrary.fileExists(path), "saved file missing")
		local data = Replay.load(path)
		assert_true(data ~= nil, "saved capture did not load")
		assert_eq(data.level_name, "level7")
		assert_eq(data.schema_version, 2)
		assert_eq(#data.balls, 1)
	end,

	test_save_with_name_appends_label = function()
		reset()
		local path = ReplayLibrary.save(sample_data(), "great shot")
		assert_true(path:match("_great_shot%.lua$") ~= nil,
			"custom label not appended: " .. tostring(path))
	end,

	test_save_with_blank_name_uses_timestamp_only = function()
		reset()
		local path = ReplayLibrary.save(sample_data(), "")
		assert_true(path:match("%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.lua$") ~= nil,
			"blank name should produce timestamp-only file: " .. tostring(path))
	end,

	test_never_overwrites_same_second = function()
		reset()
		local orig = ReplayLibrary.defaultName
		ReplayLibrary.defaultName = function() return "20200101_000000" end
		local p1 = ReplayLibrary.uniquePath("dup")
		Replay.write(p1, "return {}")
		local p2 = ReplayLibrary.uniquePath("dup")
		Replay.write(p2, "return {}")
		local p3 = ReplayLibrary.uniquePath("dup")
		ReplayLibrary.defaultName = orig
		assert_eq(p1, TEST_DIR .. "/20200101_000000_dup.lua")
		assert_eq(p2, TEST_DIR .. "/20200101_000000_dup_2.lua")
		assert_eq(p3, TEST_DIR .. "/20200101_000000_dup_3.lua")
	end,

	test_list_sorted_newest_first = function()
		reset()
		ReplayLibrary.save(sample_data("older"), "a")
		-- Force a known newer filename so ordering is deterministic.
		Replay.write(TEST_DIR .. "/20991231_235959_newest.lua",
			Replay.serialize(sample_data("newest")))
		local entries = ReplayLibrary.list()
		assert_eq(#entries, 2)
		assert_eq(entries[1].name, "20991231_235959_newest")
		assert_eq(entries[1].level_name, "newest")
	end,

	test_resolve_latest = function()
		reset()
		Replay.write(TEST_DIR .. "/20200101_000001.lua",
			Replay.serialize(sample_data("a")))
		Replay.write(TEST_DIR .. "/20200102_000000.lua",
			Replay.serialize(sample_data("b")))
		local path = ReplayLibrary.resolve("latest")
		assert_eq(path, TEST_DIR .. "/20200102_000000.lua")
	end,

	test_resolve_stem_and_explicit_path = function()
		reset()
		local saved = ReplayLibrary.save(sample_data(), "named")
		local stem = saved:match("([^/]+)%.lua$")
		assert_eq(ReplayLibrary.resolve(stem), saved)
		assert_eq(ReplayLibrary.resolve(saved), saved)
	end,

	test_resolve_unique_label_suffix = function()
		reset()
		Replay.write(TEST_DIR .. "/20200101_000001_cool_shot.lua",
			Replay.serialize(sample_data("a")))
		assert_eq(ReplayLibrary.resolve("cool_shot"),
			TEST_DIR .. "/20200101_000001_cool_shot.lua")
	end,

	test_resolve_ambiguous_label_suffix_errors = function()
		reset()
		Replay.write(TEST_DIR .. "/20200101_000001_dup.lua",
			Replay.serialize(sample_data("a")))
		Replay.write(TEST_DIR .. "/20200102_000000_dup.lua",
			Replay.serialize(sample_data("b")))
		local path, err = ReplayLibrary.resolve("dup")
		assert_true(path == nil, "ambiguous label must not resolve")
		assert_true(err ~= nil and err:find("ambiguous") ~= nil, "expected ambiguity error")
	end,

	test_resolve_missing_returns_error = function()
		reset()
		local path, err = ReplayLibrary.resolve("does_not_exist")
		assert_true(path == nil, "missing replay should not resolve")
		assert_true(err ~= nil and err:find("not found") ~= nil, "expected not-found error")
	end,

	test_resolve_empty_library_latest_errors = function()
		reset()
		local path, err = ReplayLibrary.resolve("latest")
		assert_true(path == nil, "empty library should not resolve latest")
		assert_true(err ~= nil, "expected an error for empty library")
	end,

	test_format_list_marks_newest = function()
		reset()
		Replay.write(TEST_DIR .. "/20200101_000001.lua",
			Replay.serialize(sample_data("old")))
		Replay.write(TEST_DIR .. "/20200102_000000.lua",
			Replay.serialize(sample_data("new")))
		local text = ReplayLibrary.formatList()
		assert_true(text:find("%* 20200102_000000") ~= nil,
			"newest entry should be marked: " .. text)
		assert_true(text:find("%[new%]") ~= nil, "level name should be listed")
	end,

	test_engine_buffers_launch_state_and_saves = function()
		reset()
		local H = require("tests.helpers.engine_helpers")
		local Peg = require("src.entities.peg")
		local Ball = require("src.entities.ball")
		local eng = H.new_engine()
		H.setup_engine(eng, { Peg.new(600, 200, "blue", 20) }, { red = 0, green = 0 }, 1)
		eng.last_shot_replay_path = TEST_DIR .. "/last_shot.lua"
		eng.active_balls = { Ball.new(100, 50) }
		eng:launchBalls()
		assert_true(eng.last_shot_replay_lua ~= nil,
			"launchBalls should buffer the serialized launch state")
		assert_true(ReplayLibrary.fileExists(TEST_DIR .. "/last_shot.lua"),
			"rolling last_shot capture should still be written")
		local path = eng:saveLastShotReplay("engine")
		assert_true(path ~= nil, "engine save should return a path")
		local data = Replay.load(path)
		assert_true(data ~= nil, "engine-saved replay should load")
		assert_eq(#data.balls, 1)
	end,
}
