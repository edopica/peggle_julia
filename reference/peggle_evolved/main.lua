-- ===========================================================================
-- CLI arg parsing
-- ===========================================================================
local is_bench = false
local no_jit = false
local num_balls = 1
local bench_level = nil
local replay_file = nil
local list_replays = false
local trace_file = nil
local gameplay_trace_file = nil
local retain_shot_timeline = false
local headless = false
local impact_debug = false
local impact_debug_file = nil
local present_debug = false
local present_debug_file = nil
local contact_present = nil
local time_scale = nil

local test_style_shot = false
local target_style = nil

local CliOptions = require("src.cli_options")

if arg then
	for i, a in ipairs(arg) do
		if a == "--test-style-shot" then
			test_style_shot = true
		elseif a == "--target-style" then
			target_style = arg[i + 1]
		elseif a == "--bench" or a == "--profile" then
			is_bench = true
		elseif a == "--nojit" then
			no_jit = true
		elseif a == "--balls" then
			num_balls = tonumber(arg[i + 1]) or 1
		elseif a == "--level" then
			bench_level = arg[i + 1]
		elseif a == "--replay" then
			replay_file = arg[i + 1]
		elseif a == "--list-replays" then
			list_replays = true
		elseif a == "--export-traces" then
			trace_file = arg[i + 1]
		elseif a == "--export-gameplay-traces" then
			gameplay_trace_file = arg[i + 1]
		elseif a == "--retain-shot-timeline" then
			retain_shot_timeline = true
		elseif a == "--headless" then
			headless = true
		elseif a == "--impact-debug" then
			impact_debug = true
			local next_arg = arg[i + 1]
			if next_arg and next_arg:sub(1, 2) ~= "--" then
				impact_debug_file = next_arg
			end
		elseif a == "--present-debug" then
			present_debug = true
			local next_arg = arg[i + 1]
			if next_arg and next_arg:sub(1, 2) ~= "--" then
				present_debug_file = next_arg
			end
		elseif a == "--contact-present" then
			contact_present = arg[i + 1]
		elseif a == "--time-scale" then
			time_scale = tonumber(arg[i + 1])
		end
	end
end

-- Publish session-wide CLI options for the game state machine.
CliOptions.gameplay_trace_file = gameplay_trace_file
CliOptions.retain_shot_timeline = retain_shot_timeline
CliOptions.headless = headless

-- --list-replays: print the saved-replay library and exit without running.
if list_replays then
	local ReplayLibrary = require("src.systems.replay_library")
	print(ReplayLibrary.formatList())
	love.load = function() love.event.quit() end
	return
end

-- Resolve --replay selectors ("latest", a saved name, or an explicit path)
-- against the replay library before entering bench/replay mode.
if replay_file then
	local ReplayLibrary = require("src.systems.replay_library")
	local resolved, rerr = ReplayLibrary.resolve(replay_file)
	if not resolved then
		print("Error: " .. tostring(rerr))
		print(ReplayLibrary.formatList())
		love.load = function() love.event.quit(1) end
		return
	end
	replay_file = resolved
end

if impact_debug then
	require("src.systems.impact_debug").init(impact_debug_file or "temp/impact_log.jsonl")
end

if present_debug then
	require("src.systems.contact_events").init_log(present_debug_file or "temp/present_log.jsonl")
end

if contact_present then
	require("src.systems.contact_events").presentation_enabled = (contact_present ~= "off")
end

-- Headless mode: disable the render-only contact presenter so the
-- authoritative simulation runs identically with or without rendering.
if headless then
	require("src.systems.contact_events").presentation_enabled = false
end

if test_style_shot then
	local TestStyleShot = require("tools.test_style_shot")
	local callbacks = TestStyleShot.setup({ level = bench_level, target_style = target_style })
	love.load = callbacks.load
	love.update = callbacks.update
	love.draw = callbacks.draw
	love.mousepressed = callbacks.mousepressed
	love.mousemoved = callbacks.mousemoved
	love.wheelmoved = callbacks.wheelmoved
	love.keypressed = callbacks.keypressed
	love.resize = callbacks.resize
	return
end

-- ===========================================================================
-- Bench / replay mode — delegate to bench.mode
-- ===========================================================================
if is_bench or replay_file then
	local BenchMode = require("src.bench.mode")
	local callbacks = BenchMode.setup({
		is_bench = is_bench,
		no_jit = no_jit,
		num_balls = num_balls,
		bench_level = bench_level,
		replay_file = replay_file,
		trace_file = trace_file,
		gameplay_trace_file = gameplay_trace_file,
		retain_shot_timeline = retain_shot_timeline,
		headless = headless,
		time_scale = time_scale,
	})
	love.load = callbacks.load
	love.update = callbacks.update
	love.draw = callbacks.draw
	love.mousepressed = callbacks.mousepressed
	love.mousemoved = callbacks.mousemoved
	love.wheelmoved = callbacks.wheelmoved
	love.keypressed = callbacks.keypressed
	love.resize = callbacks.resize
	return
end

-- ===========================================================================
-- Normal gameplay — delegate to state machine
-- ===========================================================================
local States = require("src.states")
local Config = require("src.config")
local Screen = require("src.systems.screen")

-- Load state modules (self-register into States table)
require("src.states.menu")
require("src.states.level_select")
require("src.states.game")

function love.load()
	love.window.setTitle("Peggle Evolved")

	local window_flags = { resizable = true, fullscreen = Config.fullscreen, fullscreentype = "desktop" }
	local mode_w, mode_h = Config.window_width, Config.window_height
	if Config.fullscreen then
		local display = love.window.getDisplayCount() > 0 and 1 or nil
		local dw, dh = love.window.getDesktopDimensions(display)
		mode_w, mode_h = dw, dh
	end
	love.window.setMode(mode_w, mode_h, window_flags)
	Screen.resize(mode_w, mode_h)

	States.switch("menu")
end

function love.update(dt)
	if States.current and States.current.update then
		States.current:update(dt)
	end
end

function love.draw()
	if States.current and States.current.draw then
		States.current:draw()
	end
end

function love.mousepressed(x, y, button, istouch, presses)
	if States.current and States.current.mousepressed then
		States.current:mousepressed(x, y, button)
	end
end

function love.mousemoved(x, y, dx, dy, istouch)
	if States.current and States.current.mousemoved then
		States.current:mousemoved(x, y, dx, dy)
	end
end

function love.wheelmoved(x, y)
	if States.current and States.current.wheelmoved then
		States.current:wheelmoved(x, y)
	end
end

function love.keypressed(key)
	if States.current and States.current.keypressed then
		States.current:keypressed(key)
	end
end

function love.textinput(text)
	if States.current and States.current.textinput then
		States.current:textinput(text)
	end
end

function love.resize(w, h)
	Screen.resize(w, h)
end
