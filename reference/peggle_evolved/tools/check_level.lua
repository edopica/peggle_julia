-- Set up package path so requires from src/ work from root
local script_dir = debug.getinfo(1, "S").source:match("@(.*)/.*$") or "."
if script_dir:sub(-5) == "tools" then
	package.path = package.path .. ";" .. script_dir .. "/../?.lua"
end

local LevelChecker = require("src.systems.level_checker")
local Config = require("src.config")

local function main()
	local level_path = arg[1]
	if not level_path then
		print("Usage: lua tools/check_level.lua <path/to/level.lua>")
		os.exit(1)
	end
	
	-- Load the level
	local level_data, err = loadfile(level_path)
	if not level_data then
		print("Error loading level: " .. tostring(err))
		os.exit(1)
	end
	level_data = level_data()
	
	-- Extract level name from path
	local level_name = level_data.name or level_path:match("([^/]+)%.lua$") or "unknown"
	
	-- Resolve dimensions
	local v_width = level_data.virtual_width or Config.virtual_width
	local v_height = level_data.virtual_height or Config.virtual_height
	
	local result = LevelChecker.check(level_data)
	
	local circles, rects, annulars = 0, 0, 0
	local all_pegs = {}
	for _, p in ipairs(level_data.pegs or {}) do table.insert(all_pegs, p) end
	
	for _, p in ipairs(all_pegs) do
		local shape = p.shape or "circle"
		if shape == "circle" then circles = circles + 1
		elseif shape == "rectangle" then rects = rects + 1
		elseif shape == "annular" then annulars = annulars + 1
		end
	end
	
	print(string.format("=== Level Compiler: %s ===", level_name))
	print(string.format("Virtual resolution: %d x %d", v_width, v_height))
	print(string.format("Total pegs: %d (%d circles, %d rectangles, %d annular)", result.total_pegs, circles, rects, annulars))
	print(string.format("Static pegs: %d, Circuit pegs: %d on %d circuits\n", result.static_pegs, result.circuit_pegs, result.num_circuits))
	
	print("--- Static Overlap Check ---")
	if #result.reports.static == 0 then
		print("  [OK] No static overlaps detected.")
	else
		for _, msg in ipairs(result.reports.static) do
			print(msg)
		end
	end
	print("")
	
	print("--- Dynamic Overlap Check ---")
	if result.num_circuits == 0 then
		print("  [OK] No circuits present.")
	else
		local has_issue = false
		for _, msg in ipairs(result.reports.dynamic) do
			print(msg)
			if msg:find("%[ERROR%]") or msg:find("%[WARN") then
				has_issue = true
			end
		end
		if not has_issue then
			print("  [OK] No dynamic overlaps detected.")
		end
	end
	print("")
	
	print("--- SUMMARY ---")
	print(string.format("  ERRORS:  %d", result.errors))
	print(string.format("  WARNINGS: %d", result.warnings))
	
	if result.errors > 0 then
		print("  RESULT:  FAIL")
		os.exit(1)
	else
		print("  RESULT:  PASS")
		os.exit(0)
	end
end

main()
