local Config = require("src.config")
local Screen = require("src.systems.screen")

local LevelManager = {}

-- Resolved virtual dimensions (from level data or Config fallback)
LevelManager.virtual_width = Config.virtual_width
LevelManager.virtual_height = Config.virtual_height

-- Require a level module, raising a clear error when the level is not
-- available (deleted or never added) instead of Lua's raw "module not
-- found" message, which names search paths rather than the level. Load
-- errors inside an existing level file keep their own message.
local function require_level(name)
	package.loaded["src.levels." .. name] = nil
	local ok, level_data = pcall(require, "src.levels." .. name)
	if ok then
		return level_data
	end
	local err = tostring(level_data)
	if err:find("not found", 1, true) then
		error(string.format(
			"LevelManager.load: level %q is not available: src/levels/%s.lua does not exist (the level was removed or never added)",
			name, name), 2)
	end
	error(string.format("LevelManager.load: level %q failed to load: %s", name, err), 2)
end

--- Load (or reload) a level by name.
-- Clears the module cache, requires the level file, resolves per-level
-- virtual resolution (falling back to Config defaults), updates the
-- Screen transform, and returns the raw level data for main.lua.
--
-- @param name  string  Module-style level name (e.g. "level1")
-- @return table  The level data table (pegs, type_counts, etc.)
function LevelManager.load(name)
	-- 1. Require the level file (cache cleared inside; missing levels get a
	-- clear "not available" error naming the level).
	local level_data = require_level(name)

	-- 2. Resolve per-level virtual resolution, falling back to Config
	LevelManager.virtual_width  = level_data.virtual_width  or Config.virtual_width
	LevelManager.virtual_height = level_data.virtual_height or Config.virtual_height

	-- 3. Recalculate the letterbox transform for the new dimensions
	local w, h = love.graphics.getDimensions()
	Screen.resize(w, h)

	-- 4. Return level data for main.lua to continue setup
	return level_data
end

return LevelManager
