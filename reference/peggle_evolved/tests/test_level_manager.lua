-- LevelManager tests: level availability is enforced at load. Replays (and
-- --bench --level) referencing a level that no longer exists must fail with
-- a clear "level not available" error naming the level, never with Lua's
-- raw "module not found" require message.
local LevelManager = require("src.systems.level_manager")
local H = require("tests.helpers.engine_helpers")

-- The six grid/test levels removed by the motion refactor (ADR-0007) plus
-- a name that never existed. Replays referencing these cannot load: legacy
-- replay compatibility is scoped to retained levels only.
local REMOVED_LEVELS = {
	"benchmark_100", "benchmark_200", "benchmark_300",
	"benchmark_500", "benchmark_1000", "test_rotation",
	"no_such_level",
}

local function assert_clean_missing_level_error(name, msg)
	assert_true(msg:find("LevelManager.load:") ~= nil, name .. ": " .. msg)
	assert_true(msg:find(name, 1, true) ~= nil,
		name .. ": error names the level -> " .. msg)
	assert_true(msg:find("does not exist") ~= nil,
		name .. ": error says the level is unavailable -> " .. msg)
	assert_true(msg:find("not available") ~= nil,
		name .. ": error says not available -> " .. msg)
	-- Not the raw require message (which lists search paths and
	-- never names the level as a level).
	assert_true(msg:find("package.preload") == nil,
		name .. ": no raw require module-not-found message -> " .. msg)
end

return {
	test_existing_level_still_loads = function()
		local level_data = LevelManager.load("level1")
		assert_true(type(level_data) == "table", "level1 loads")
		assert_true(type(level_data.pegs) == "table", "level1 has pegs")
	end,

	test_removed_levels_fail_with_clean_error = function()
		for _, name in ipairs(REMOVED_LEVELS) do
			local ok, err = pcall(LevelManager.load, name)
			assert_false(ok, name .. " must not load")
			assert_clean_missing_level_error(name, tostring(err))
		end
	end,

	test_setup_level_propagates_clean_error = function()
		-- Engine:setupLevel is the replay choke point (bench_load replays
		-- the capture's level_name through it); the clean LevelManager
		-- error must propagate unchanged.
		local eng = H.new_engine()
		local ok, err = pcall(eng.setupLevel, eng, "benchmark_100")
		assert_false(ok, "setupLevel of a removed level fails")
		assert_clean_missing_level_error("benchmark_100", tostring(err))
	end,
}
