-- Shared Engine integration test helpers.
-- Builds a minimal Engine wired for headless deterministic simulation without
-- the LÖVE state machine. Levels are inline peg tables.
local Engine = require("src.engine.core")
local Ball = require("src.entities.ball")
local Peg = require("src.entities.peg")
local LevelManager = require("src.systems.level_manager")
local Config = require("src.config")

local H = {}

-- Install a tiny level directly into the engine (bypassing LevelManager.load,
-- which needs love.graphics). Sets up pegs, ids, peg map, colors.
function H.setup_engine(engine, pegs, type_counts, seed)
	engine.pegs = {}
	for i, p in ipairs(pegs) do
		p.original_index = i
		table.insert(engine.pegs, p)
	end
	engine.level_circuits = {}
	engine:rebuildPegLists()
	engine:rebuildPegIdMap()
	local tc = type_counts or { red = 0, green = 0 }
	tc.blue = #engine.pegs - ((tc.red or 0) + (tc.green or 0))
	engine.totalRedPegs = tc.red or 0
	local PegColors = require("src.systems.peg_colors")
	PegColors.init(engine.pegs, tc, seed or 1)
	engine.hitCounter = 0
	engine.bonusScore = 0
	engine.styleScore = 0
	engine.turnPegsHit = {}
	engine.bucket = require("src.entities.bucket").new()
	engine.feverBuckets = require("src.entities.fever_buckets").new()
	engine.redPegsHitAmount = 0
	engine.clearQueue = nil
	engine.active_balls = {}
	engine.shot_id = 0
	engine:updateMultiplier()
	engine.slideInversion:reset_shot()
	if engine.callbacks.onHUDRefresh then engine.callbacks.onHUDRefresh(engine) end
end

function H.new_engine(callbacks)
	return Engine.new(callbacks or {})
end

-- Launch a single ball with a given velocity and run until the shot ends or
-- max_steps is reached. Returns the engine (with completed events).
function H.run_shot(engine, x, y, vx, vy, max_steps)
	max_steps = max_steps or 60 * 30
	local b = Ball.new(x, y)
	b.launched = true
	b.vx = vx
	b.vy = vy
	engine:registerBall(b)
	engine.active_balls = { b }
	engine.shot_id = engine.shot_id + 1
	engine.shot_initial_step = engine.sim_step_id + 1
	engine.styleShots:reset_shot()
	engine.ballState:reset_shot()
	engine.slideInversion:reset_shot()
	if engine.retain_shot_timeline then
		engine.current_shot_timeline = {}
	end
	engine.events:stage("ball_launched", { ball_id = b.id, x = b.x, y = b.y, vx = b.vx, vy = b.vy })
	for _ = 1, max_steps do
		if engine.is_halted then break end
		engine.sim_step_id = engine.sim_step_id + 1
		engine:savePreviousState()
		engine:stepSimulation(Config.fixed_dt)
		-- Stop once the shot is fully done (clearQueue finished + turn ended).
		if engine.shot_end_reason == "__handled" then break end
	end
	return engine
end

-- Collect all events of a type across the whole shot from the trace exporter
-- (if used) or by recording per-step. This helper records per-step into a list.
function H.make_recorder(engine)
	local steps = {}
	engine.callbacks.onStepFinalized = function(eng, rec)
		table.insert(steps, rec)
	end
	return steps
end

-- Flatten a recorder's step records into ordered event lists.
function H.flatten_events(steps, type)
	local out = {}
	for _, rec in ipairs(steps) do
		for _, e in ipairs(rec.raw_events) do
			if type == nil or e.type == type then table.insert(out, e) end
		end
		for _, e in ipairs(rec.derived_events) do
			if type == nil or e.type == type then table.insert(out, e) end
		end
	end
	return out
end

return H
