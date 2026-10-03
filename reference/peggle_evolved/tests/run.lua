-- Plain-Lua test runner for Phase 1 gameplay systems.
-- Loads the love stub, then runs every tests/test_*.lua file. Each test file
-- returns a table of named test functions; failures are collected and reported.
--
-- Usage:
--   luajit tests/run.lua
--   lua tests/run.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*)/.*$") or "."
	package.path = package.path .. ";" .. script_dir .. "/../?.lua"
	package.path = package.path .. ";" .. script_dir .. "/?.lua"

-- Load the love stub before any module requires love.
require("tests.love_stub")

local function list_tests()
	local files = {}
	-- Use a directory listing via popen (lfs may not be installed).
	local p = io.popen('ls "' .. script_dir .. '"')
	if p then
		for line in p:lines() do
			if line:match("^test_.*%.lua$") then
				table.insert(files, line)
			end
		end
		p:close()
	end
	table.sort(files)
	return files
end

local passed, failed = 0, 0
local failures = {}

local function assert_eq(a, b, msg)
	if a ~= b then
		error(string.format("assert_eq failed: %s\n  expected: %s\n  got:      %s",
			msg or "", tostring(b), tostring(a)), 2)
	end
end

local function assert_true(v, msg)
	if not v then
		error("assert_true failed: " .. (msg or "value was not true"), 2)
	end
end

local function assert_false(v, msg)
	if v then
		error("assert_false failed: " .. (msg or "value was not false"), 2)
	end
end

_G.assert_eq = assert_eq
_G.assert_true = assert_true
_G.assert_false = assert_false

local function run_file(name)
	local path = script_dir .. "/" .. name
	local chunk, err = loadfile(path)
	if not chunk then
		print("  [LOAD ERROR] " .. name .. ": " .. tostring(err))
		failed = failed + 1
		return
	end
	local ok, tests = pcall(chunk)
	if not ok then
		print("  [EXEC ERROR] " .. name .. ": " .. tostring(tests))
		failed = failed + 1
		return
	end
	-- Ensure deterministic ordering of test names.
	local names = {}
	for k in pairs(tests) do if type(k) == "string" then table.insert(names, k) end end
	table.sort(names)
	for _, tname in ipairs(names) do
		local tfn = tests[tname]
		if type(tfn) == "function" then
			local fok, ferr = pcall(tfn)
			if fok then
				passed = passed + 1
			else
				failed = failed + 1
				table.insert(failures, name .. "::" .. tname .. ": " .. tostring(ferr))
				print("  [FAIL] " .. tname .. ": " .. tostring(ferr))
			end
		end
	end
end

local files = list_tests()
print(string.format("Running %d test file(s)...", #files))
for _, f in ipairs(files) do
	print("== " .. f .. " ==")
	run_file(f)
end

print(string.format("\nResults: %d passed, %d failed", passed, failed))
if #failures > 0 then
	print("\nFailures:")
	for _, fmsg in ipairs(failures) do
		print("  - " .. fmsg)
	end
	os.exit(1)
end
