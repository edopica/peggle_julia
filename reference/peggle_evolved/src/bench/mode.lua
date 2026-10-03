local Config = require("src.config")
local Ball = require("src.entities.ball")
local Screen = require("src.systems.screen")
local LevelManager = require("src.systems.level_manager")
local Perf = require("src.systems.perf")
local Replay = require("src.systems.replay")
local TraceExporter = require("src.systems.trace_exporter")
local GameplayTraceExporter = require("src.systems.gameplay_trace_exporter")
local Engine = require("src.engine.core")

-- ===========================================================================
-- Module-local state (initialized by setup())
-- ===========================================================================
local is_bench, no_jit, num_balls, bench_level, replay_file, trace_file
local gameplay_trace_file, retain_shot_timeline, headless, time_scale
local current_level_name
local totalScore = 0
local cachedScoreText = ""
local show_debug_overlay = false
local is_profiling = false
local profile_file = nil
local profile_module = nil
local engine = nil

-- ===========================================================================
-- Internal helpers
-- ===========================================================================
local function reloadConfig()
	package.loaded["src.config"] = nil
	local newConfig = require("src.config")
	for k, v in pairs(newConfig) do
		Config[k] = v
	end
	local window_flags = { resizable = true, fullscreen = Config.fullscreen, fullscreentype = "desktop" }
	if is_bench then window_flags.vsync = 0 end
	local mode_w, mode_h = Config.window_width, Config.window_height
	if Config.fullscreen then
		local display = love.window.getDisplayCount() > 0 and 1 or nil
		local dw, dh = love.window.getDesktopDimensions(display)
		mode_w, mode_h = dw, dh
	end
	love.window.setMode(mode_w, mode_h, window_flags)
	Screen.resize(mode_w, mode_h)
end

local function profile_cb(th, samples, vmst)
	if profile_file and profile_module then
		local dump = profile_module.dumpstack(th, "pf", 1)
		profile_file:write(dump .. "\n")
	end
end

local function resetBenchTurn()
	if is_bench then
		local active_balls = {}
		for i = 1, num_balls do
			local x = (i / (num_balls + 1)) * LevelManager.virtual_width
			local b = Ball.new(x, 50)
			b.launched = true
			b.vx = 0
			b.vy = 0
			table.insert(active_balls, b)
		end
		engine:resetTurn(active_balls)
		-- Bench mode bypasses Engine:launchBall, so set up shot state and
		-- stage ball_launched events manually for complete traces.
		engine.shot_id = engine.shot_id + 1
		engine.shot_initial_step = engine.sim_step_id + 1
		engine.shot_end_reason = nil
		engine.last_removal_reason = nil
		if engine.retain_shot_timeline then
			engine.current_shot_timeline = {}
		end
		for _, b in ipairs(engine.active_balls) do
			engine.events:stage("ball_launched", {
				ball_id = b.id, x = b.x, y = b.y, vx = b.vx, vy = b.vy,
			})
		end
	else
		engine:resetTurn()
	end
end

-- Set up a level for a one-shot CLI run (replay or bench). LevelManager
-- raises a clear "level not available" error for deleted/missing levels;
-- report it on stdout and exit nonzero instead of surfacing the interactive
-- error screen, which would hang unattended replay/bench runs.
local function setupLevelOrExit(level_name)
	local ok, err = pcall(engine.setupLevel, engine, level_name)
	if not ok then
		print(err)
		love.event.quit(1)
	end
	return ok
end

-- ===========================================================================
-- LÖVE callback functions
-- ===========================================================================
local function bench_load()
	love.window.setTitle("Peggle Evolved - MVP")
	if is_bench then love.window.setVSync(0); print("Vsync disabled for benchmarking") end
	reloadConfig()

	engine = Engine.new({
		onHUDRefresh = function(eng)
			cachedScoreText = "Score: " .. (totalScore + eng:getTurnScore()) .. " (x" .. eng.currentMultiplier .. ")"
		end,
		onLaunch = function(eng)
			return true
		end,
		onBucketCatch = function(eng, ball)
			eng.bonusScore = eng.bonusScore + Config.bucket_bonus
		end,
		onFeverCatch = function(eng, ball, value)
			-- Fever points are awarded internally by core; we let the ball drop.
		end,
		onTurnEnd = function(eng)
			totalScore = totalScore + eng:getTurnScore()
			-- Close the gameplay trace exporter after the final step record
			-- (containing shot_completed) has been exported at phase 23.
			-- onTurnEnd fires at phase 25, after the step record is written.
			if (GameplayTraceExporter.file or gameplay_trace_file) and eng.trace_exporter then
				GameplayTraceExporter.close()
				eng.trace_exporter = nil
			end
			if replay_file then
				-- One-shot replay: the captured shot is complete, terminate
				-- instead of starting a fresh interactive turn.
				if TraceExporter.file then TraceExporter.close() end
				love.event.quit()
				return
			end
			if eng.isFever and not is_bench then
				engine:setupLevel(current_level_name)
			end
			resetBenchTurn()
		end,
		onAllBallsDepleted = function(eng)
			if TraceExporter.file then
				TraceExporter.close()
				love.event.quit()
				return true
			end
			if is_bench then
				Perf.saveAndExit(current_level_name, num_balls)
				return true
			end
			return false
		end
	})

	if replay_file then
		local replay_data = Replay.load(replay_file)
		if replay_data then
			current_level_name = replay_data.level_name
			if not setupLevelOrExit(current_level_name) then return end
			engine.retain_shot_timeline = retain_shot_timeline
			-- Applies captured peg/bucket/ball state and establishes a valid
			-- nonzero shot_id for the in-progress replay shot (see §3.2).
			engine:applyReplayState(replay_data)
			if trace_file then TraceExporter.init(trace_file) end
			if gameplay_trace_file then
				GameplayTraceExporter.init(gameplay_trace_file)
				engine.trace_exporter = GameplayTraceExporter
			end
			engine.headless = headless
			if #(replay_data.balls or {}) == 0 then
				-- The captured shot was already over: nothing to simulate.
				print("Replay contains no live balls; the captured shot was already complete.")
				if TraceExporter.file then TraceExporter.close() end
				if GameplayTraceExporter.file then GameplayTraceExporter.close() end
				love.event.quit()
			end
		end
	else
		if not setupLevelOrExit(current_level_name) then return end
		resetBenchTurn()
		if trace_file then TraceExporter.init(trace_file) end
		if gameplay_trace_file then
			GameplayTraceExporter.init(gameplay_trace_file)
			engine.trace_exporter = GameplayTraceExporter
		end
		engine.retain_shot_timeline = retain_shot_timeline
		engine.headless = headless
	end
end

local function bench_update(dt)
	-- --time-scale N: slow (or accelerate) simulation time while rendering at
	-- the normal rate (presentation-sampling diagnostics).
	if time_scale then
		dt = dt * time_scale
	end
	engine:update(dt)
	Perf.report(dt)
end

local function bench_draw()
	Perf.beginDraw()
	love.graphics.clear(0, 0, 0, 1)
	Screen.apply()

	if not headless then
		engine:draw()
	end

	love.graphics.setColor(1, 1, 1, 0.7)
	love.graphics.print("Click/Enter: Launch | Arrows/Wheel: Aim | 'R': Reload", 10, 10)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.print(cachedScoreText, 10, 30)
	Screen.clear()

	if show_debug_overlay then
		love.graphics.setColor(0, 0, 0, 0.7)
		love.graphics.rectangle("fill", 10, 50, 250, is_profiling and 90 or 70)
		love.graphics.setColor(0, 1, 0, 1)
		local fps = love.timer.getFPS(); local mem = collectgarbage("count")
		local ms = love.timer.getAverageDelta() * 1000
		love.graphics.print("FPS: " .. fps, 20, 60)
		love.graphics.print(string.format("Mem: %.2f KB", mem), 20, 80)
		love.graphics.print(string.format("Avg Frame: %.2f ms", ms), 20, 100)
		if is_profiling then love.graphics.setColor(1, 0, 0, 1); love.graphics.print("PROFILING (jit.profile) ACTIVE", 20, 120) end
	end
	Perf.endDraw()
end

local function bench_mousepressed(x, y, button)
	engine:mousepressed(x, y, button)
end

local function bench_mousemoved(x, y, dx, dy)
	engine:mousemoved(x, y, dx, dy)
end

local function bench_wheelmoved(x, y)
	engine:wheelmoved(x, y)
end

local function bench_keypressed(key)
	engine:keypressed(key)

	if key == "r" then
		engine:setupLevel(current_level_name); resetBenchTurn()
	elseif key == "f5" then love.event.quit("restart")
	elseif key == "f3" then show_debug_overlay = not show_debug_overlay
	elseif key == "f4" then
		if profile_module then
			is_profiling = not is_profiling
			if is_profiling then
				profile_file = io.open("profile_dump.txt", "w")
				profile_module.start("li1", profile_cb)
			else
				profile_module.stop()
				if profile_file then profile_file:close(); profile_file = nil end
			end
		end
	elseif key == "f6" then current_level_name = "benchmark_lasagna"; engine:setupLevel(current_level_name); resetBenchTurn()
	end
end

local function bench_resize(w, h)
	Screen.resize(w, h)
end

-- ===========================================================================
-- Public API
-- ===========================================================================
local BenchMode = {}

function BenchMode.setup(opts)
	is_bench = opts.is_bench
	no_jit = opts.no_jit
	num_balls = opts.num_balls
	bench_level = opts.bench_level
	replay_file = opts.replay_file
	trace_file = opts.trace_file
	gameplay_trace_file = opts.gameplay_trace_file
	retain_shot_timeline = opts.retain_shot_timeline
	headless = opts.headless
	time_scale = opts.time_scale
	current_level_name = bench_level or "level1"

	if is_bench then
		Perf.init(true)
		if no_jit then
			local has_jit, jit = pcall(require, "jit")
			if has_jit and jit then
				jit.off()
				jit.flush()
				print("LuaJIT disabled via --nojit: status=" .. tostring(jit.status()))
			end
		end
	end

	pcall(function() profile_module = require("jit.profile") end)

	return {
		load = bench_load,
		update = bench_update,
		draw = bench_draw,
		mousepressed = bench_mousepressed,
		mousemoved = bench_mousemoved,
		wheelmoved = bench_wheelmoved,
		keypressed = bench_keypressed,
		resize = bench_resize,
	}
end

return BenchMode
