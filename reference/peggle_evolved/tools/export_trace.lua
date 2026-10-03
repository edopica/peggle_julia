math.atan2 = math.atan2 or math.atan
local script_dir = debug.getinfo(1, "S").source:match("@(.*)/.*$") or "."
if script_dir:sub(-5) == "tools" then
	package.path = package.path .. ";" .. script_dir .. "/../?.lua"
end

local Config = require("src.config")
local Physics = require("src.systems.physics")
local Circuits = require("src.systems.circuits")
local LevelManager = require("src.systems.level_manager")
local MotionSchema = require("src.systems.motion_schema")
local Validator = require("src.systems.level_validator")
local Ball = require("src.entities.ball")
local Bucket = require("src.entities.bucket")
local Peg = require("src.entities.peg")
local JSON = require("tools.json")

-- Headless love stub so shared gameplay modules (LevelManager.load ->
-- Screen.resize, physics contact code) can run under plain luajit.
local function ensure_love_stub()
	if not _G.love then
		_G.love = {
			graphics = {
				getDimensions = function() return 1920, 1080 end,
			},
		}
	end
end

local function run_simulation(level_data, angle, suffix)
    local balls = {}
    local circle_pegs = {}
    local rect_pegs = {}
    local annular_pegs = {}
    local extra_circles = {}
    local all_pegs = {}

    -- Mirror Engine:setupLevel (src/engine/core.lua:310-322): raw pegs that
    -- lack radius/base_x are rebuilt through Peg.new so every peg matches the
    -- entity shape the engine simulates.
    local raw_pegs = level_data.pegs or {}
    for _, p in ipairs(raw_pegs) do
        if p.radius and p.base_x then
            table.insert(all_pegs, p)
        else
            local new_p = Peg.new(p.x, p.y, p.type, p.radius)
            for k, v in pairs(p) do
                new_p[k] = v
            end
            table.insert(all_pegs, new_p)
        end
    end

    local level_circuits = level_data.level_circuits or {}

    -- Load-time schema gate (Engine:setupLevel order: validate, then
    -- Circuits.initialize): invalid motion data fails here with the canonical
    -- "Motion schema error: ..." message instead of mid-simulation.
    MotionSchema.validate(all_pegs, level_circuits)

    -- Discard pegs whose base position intersects a wall boundary, exactly as
    -- gameplay does before circuit initialization. Closed path circuits keep
    -- their intentionally off-screen hidden-return bases.
    all_pegs = Validator.validate_pegs(all_pegs, level_circuits)

    Circuits.initialize(all_pegs, level_circuits)
    Validator.check_initialized_positions(all_pegs, level_circuits)

    local next_id = 1
    for _, p in ipairs(all_pegs) do
        p.id = next_id
        p.original_index = next_id
        if not p.base_x then p.base_x = p.x end
        if not p.base_y then p.base_y = p.y end
        if not p.shape or p.shape == "circle" then
            table.insert(circle_pegs, p)
        elseif p.shape == "rectangle" then
            table.insert(rect_pegs, p)
        elseif p.shape == "annular" then
            table.insert(annular_pegs, p)
        end
        next_id = next_id + 1
    end

    -- Per-level virtual dimensions (resolved into LevelManager by the level
    -- load, falling back to Config defaults) are the source of truth for
    -- spawn, bucket geometry and the walls/fell-out thresholds below.
    local vw = LevelManager.virtual_width
    local vh = LevelManager.virtual_height

    local bucket = Bucket.new()

    -- Same launch math as Engine:launchBalls (src/engine/core.lua:1507-1509):
    -- angle is the game's current_aim_angle (world frame, math.pi/2 = straight
    -- down), snapped exactly as gameplay snaps it.
    local effective_angle = Physics.getSnappedAimAngle(angle)
    local ball = Ball.new(vw / 2, 0.0)
    ball.vx = math.cos(effective_angle) * Config.launch_speed
    ball.vy = math.sin(effective_angle) * Config.launch_speed
    ball.launched = true
    table.insert(balls, ball)

    local events = {}
    local trace = {}
    local steps = 0
    local max_steps = 60 * 20

    -- Physics no longer mutates peg.hit without an event sink; provide one
    -- that marks pegs hit on ball_contacted_peg (preserves this tool's behavior).
    local sink = {}
    function sink:emit_raw(event_type, fields)
        if event_type == "ball_contacted_peg" and fields.peg_id ~= nil then
            local peg = all_pegs[fields.peg_id]
            if peg then
                peg.hit = true
            end
        end
    end

    while steps < max_steps do
        steps = steps + 1

        local hits_before = {}
        for _, p in ipairs(all_pegs) do if p.hit then hits_before[p.id] = true end end

        Circuits.update(all_pegs, level_circuits, Config.fixed_dt)

        local prev_vx = ball.vx
        local prev_vy = ball.vy

        Physics.update(balls, circle_pegs, rect_pegs, annular_pegs, Config.fixed_dt, extra_circles, sink)
        Bucket.update(bucket, Config.fixed_dt)
        
        if prev_vx < 0 and ball.vx > 0 and ball.x <= ball.radius + 1.0 then
            table.insert(events, {step = steps, type = "wall", side = "left"})
        elseif prev_vx > 0 and ball.vx < 0 and ball.x >= vw - ball.radius - 1.0 then
            table.insert(events, {step = steps, type = "wall", side = "right"})
        end
        if prev_vy < 0 and ball.vy > 0 and ball.y <= ball.radius + 1.0 then
            table.insert(events, {step = steps, type = "wall", side = "top"})
        end

        for _, p in ipairs(all_pegs) do
            if p.hit and not hits_before[p.id] then
                table.insert(events, {step = steps, type = "hit", peg_id = p.id, peg_type = p.type})
            end
        end

        local res = Bucket.resolve(bucket, ball)
        if res == "caught" then
            table.insert(events, {step = steps, type = "caught"})
            break
        end

        -- Same fall-out gate as the engine (src/engine/core.lua:1151):
        -- level bottom plus Config.fall_out_margin, radius-adjusted.
        if ball.y - ball.radius > vh + Config.fall_out_margin then
            table.insert(events, {step = steps, type = "fell_out"})
            break
        end

        table.insert(trace, {step = steps, x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy, bx = bucket.x})
    end

    local e_filename = "lua_events" .. suffix .. ".json"
    local t_filename = "lua_trace" .. suffix .. ".json"
    local out_events = io.open(e_filename, "w")
    out_events:write(JSON.stringify(events))
    out_events:close()

    local out_trace = io.open(t_filename, "w")
    out_trace:write(JSON.stringify(trace))
    out_trace:close()

    print("Exported " .. e_filename .. " and " .. t_filename .. " (Steps: " .. steps .. ")")
end

local function main()
    ensure_love_stub()

    local level_path = arg[1] or "src/levels/level1.lua"
    
    local sweep = false
    local angle_str = arg[2]
    
    if arg[2] == "--sweep" then
        sweep = true
    end

    local angles = {}
    if sweep then
        -- Sweep the launch arc in the game's angle convention (0 = horizontal
        -- right, math.pi/2 = straight down), symmetric around straight down:
        -- ten angles spanning math.pi/2 - 0.45 .. math.pi/2 + 0.45, all inside
        -- getSnappedAimAngle's clamp arc [0, math.pi].
        local center = math.pi / 2
        for i = 1, 10 do
            table.insert(angles, {a = center + (i - 1) * 0.1 - 0.45, s = "_sweep_" .. i})
        end
    else
        table.insert(angles, {a = tonumber(angle_str) or 0.0, s = ""})
    end

    for _, a_info in ipairs(angles) do
        local level_data
        local module_name = level_path:match("^src/levels/([%w_]+)%.lua$")
        if module_name then
            -- Same load the game performs (Engine:setupLevel ->
            -- LevelManager.load): clears the module cache, resolves the
            -- level's per-level virtual dimensions into LevelManager
            -- (falling back to Config defaults), and returns fresh data.
            level_data = LevelManager.load(module_name)
        else
            level_data = loadfile(level_path)()
            LevelManager.virtual_width = level_data.virtual_width or Config.virtual_width
            LevelManager.virtual_height = level_data.virtual_height or Config.virtual_height
        end
        run_simulation(level_data, a_info.a, a_info.s)
    end

    local cfg = {
         fixed_dt = Config.fixed_dt,
         gravity = Config.gravity,
         restitution = Config.restitution,
         wall_damping = Config.wall_damping,
         graze_tolerance = Config.graze_tolerance,
         ball_radius = Config.ball_radius,
         toi_epsilon = Config.toi_epsilon or 1e-9,
         safe_t_margin = Config.safe_t_margin or 0.001,
         overlap_push_margin = Config.overlap_push_margin or 0.1,
         annular_cap_epsilon = Config.annular_cap_epsilon or 0.01,
         launch_speed = Config.launch_speed,
         virtual_width = LevelManager.virtual_width,
         virtual_height = LevelManager.virtual_height
    }

    local out_cfg = io.open("lua_config.json", "w")
    out_cfg:write(JSON.stringify(cfg))
    out_cfg:close()
    print("Exported lua_config.json")
end

main()
