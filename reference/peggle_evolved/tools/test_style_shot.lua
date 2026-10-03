local Engine = require("src.engine.core")
local Config = require("src.config")
local Screen = require("src.systems.screen")
local Perf = require("src.systems.perf")

local TestStyleShot = {}

function TestStyleShot.setup(opts)
    local level_name = opts.level or "long_shot"
    local target_style = opts.target_style or "long_shot"

    -- We need to ensure we have a valid window for drawing.
    local function reloadConfig()
        package.loaded["src.config"] = nil
        local newConfig = require("src.config")
        for k, v in pairs(newConfig) do
            Config[k] = v
        end
        Config.aim_discretization_steps = nil
        local window_flags = { resizable = true, fullscreen = Config.fullscreen, fullscreentype = "desktop" }
        local mode_w, mode_h = Config.window_width, Config.window_height
        if Config.fullscreen then
            local display = love.window.getDisplayCount() > 0 and 1 or nil
            local dw, dh = love.window.getDesktopDimensions(display)
            mode_w, mode_h = dw, dh
        end
        love.window.setMode(mode_w, mode_h, window_flags)
        Screen.resize(mode_w, mode_h)
    end

    local mid = math.pi / 2
    local min_angle = mid - Config.aim_angle_limit
    local max_angle = mid + Config.aim_angle_limit

    local state = "searching" -- "searching", "replaying"

    local level_data_cache = nil
    local original_load = require("src.systems.level_manager").load
    require("src.systems.level_manager").load = function(name)
        if state == "searching" then
            if not level_data_cache then
                level_data_cache = original_load(name)
            end
            -- Return a deep copy so Engine can mutate it (like circuit assignment)
            local function deep_copy(obj)
                if type(obj) ~= "table" then return obj end
                local res = {}
                for k, v in pairs(obj) do res[k] = deep_copy(v) end
                return setmetatable(res, getmetatable(obj))
            end
            return deep_copy(level_data_cache)
        end
        return original_load(name)
    end

    local current_angle = min_angle
    local search_step = math.rad(0.1)
    local angles_per_frame = 200

    local found_shots = {}
    local current_shot_idx = 1
    local visual_engine = nil
    local style_popups = {}

    local function setup_visual_engine(angle)
        style_popups = {}
        visual_engine = Engine.new({
            onStyleShot = function(eng, info)
                local ball = eng.balls and eng.balls[info.ball_id]
                local x = ball and ball.x or Config.virtual_width / 2
                local y = ball and ball.y or Config.virtual_height / 3

                local config = {
                    long_shot = { text = "LONG SHOT!", color = {1, 1, 0}, scale = 1.2, duration = 2.0 },
                    super_long_shot = { text = "SUPER LONG SHOT!", color = {1, 0.5, 0}, scale = 1.6, duration = 2.5 },
                    double_long_shot = { text = "DOUBLE LONG SHOT!", color = {0.8, 0.2, 1}, scale = 1.6, duration = 3.0 },
                    lucky_bounce = { text = "LUCKY BOUNCE!", color = {0, 1, 0}, scale = 1.3, duration = 2.0 },
                    off_the_wall = { text = "OFF THE WALL!", color = {0, 1, 1}, scale = 1.3, duration = 2.0 },
                    slide = { text = "SLIDE!", color = {0.6, 1, 1}, scale = 1.4, duration = 2.2 }
                }

                local preset = config[info.style]
                if preset then
                    table.insert(style_popups, {
                        text = preset.text,
                        points = info.points,
                        x = x,
                        y = y,
                        color = preset.color,
                        scale = preset.scale,
                        duration = preset.duration,
                        time = 0
                    })
                end
                print("Visual engine style shot: " .. info.style)
            end
        })
        visual_engine.headless = false
        visual_engine:setupLevel(level_name)
        visual_engine:resetTurn()
        visual_engine.current_aim_angle = angle
        visual_engine:launchBalls()
    end

    local function test_angle(angle)
        local engine = Engine.new({
            onStyleShot = function(eng, info)
                if info.style == target_style or (target_style == "long_shot" and info.style == "super_long_shot") then
                    eng.found_style_shot = info.style
                end
            end,
            onTurnEnd = function(eng)
            end,
            onAllBallsDepleted = function(eng)
            end
        })
        engine.headless = true
        engine:setupLevel(level_name)
        engine:resetTurn()
        engine.current_aim_angle = angle
        engine:launchBalls()

        local max_steps = 3600
        local steps = 0
        while #engine.active_balls > 0 and steps < max_steps do
            engine:update(1/60)
            steps = steps + 1
        end

        if engine.found_style_shot then
            return true, engine.found_style_shot
        end
        return false
    end

    local callbacks = {}

    function callbacks.load()
        love.window.setTitle("Peggle Evolved - Test Style Shot")
        reloadConfig()
    end

    function callbacks.update(dt)
        if state == "searching" then
            for i = 1, angles_per_frame do
                if current_angle > max_angle then
                    if #found_shots > 0 then
                        state = "replaying"
                        current_shot_idx = 1
                        setup_visual_engine(found_shots[current_shot_idx].angle)
                    else
                        print("Finished sweeping without finding anything.")
                        love.event.quit()
                    end
                    break
                end

                local success, style = test_angle(current_angle)
                if success then
                    table.insert(found_shots, { angle = current_angle, style = style })
                end
                current_angle = current_angle + search_step
            end
        elseif state == "replaying" then
            if visual_engine then
                visual_engine:update(dt)
            end
            for i = #style_popups, 1, -1 do
                local p = style_popups[i]
                p.time = p.time + dt
                p.y = p.y - (40 * dt)
                if p.time >= p.duration then
                    table.remove(style_popups, i)
                end
            end
        end
    end

    function callbacks.draw()
        love.graphics.clear(0, 0, 0, 1)
        Screen.apply()

        if state == "replaying" and visual_engine then
            visual_engine:draw()
            
            local font = love.graphics.getFont()
            for _, p in ipairs(style_popups) do
                local alpha = 1.0
                if p.time > p.duration - 0.5 then
                    alpha = math.max(0, (p.duration - p.time) / 0.5)
                end
                
                local text_str = p.text .. "\n+" .. p.points
                local ptext = love.graphics.newText(font, text_str)
                local px = p.x - (ptext:getWidth() * p.scale) / 2
                local py = p.y - (ptext:getHeight() * p.scale) / 2
                
                -- Shadow
                love.graphics.setColor(0, 0, 0, 0.5 * alpha)
                love.graphics.draw(ptext, px + 2, py + 2, 0, p.scale, p.scale)
                
                -- Main text
                love.graphics.setColor(p.color[1], p.color[2], p.color[3], alpha)
                love.graphics.draw(ptext, px, py, 0, p.scale, p.scale)
            end
        end

        -- Draw HUD on top
        love.graphics.setColor(1, 1, 1, 1)
        local padding = 10
        if state == "searching" then
            local pct = (current_angle - min_angle) / (max_angle - min_angle) * 100
            love.graphics.print(string.format("Searching... %.2f%% (Angle: %.4f)", pct, current_angle), padding, padding)
            love.graphics.print(string.format("Found %d shots so far...", #found_shots), padding, padding + 20)
        elseif state == "replaying" then
            local shot = found_shots[current_shot_idx]
            love.graphics.print(string.format("Replaying shot %d of %d (Angle: %.4f, %s)", current_shot_idx, #found_shots, shot.angle, shot.style), padding, padding)
            love.graphics.print("Press 'r' to replay, 'n' for next, 'b' for previous, 'q' to quit", padding, padding + 20)
        end
        Screen.clear()
    end

    function callbacks.mousepressed(x, y, button)
        if state == "replaying" and visual_engine then
            visual_engine:mousepressed(x, y, button)
        end
    end

    function callbacks.mousemoved(x, y, dx, dy)
        if state == "replaying" and visual_engine then
            visual_engine:mousemoved(x, y, dx, dy)
        end
    end

    function callbacks.wheelmoved(x, y)
        if state == "replaying" and visual_engine then
            visual_engine:wheelmoved(x, y)
        end
    end

    function callbacks.keypressed(key)
        if key == "q" or key == "escape" then
            love.event.quit()
        end

        if state == "replaying" then
            if key == "r" then
                setup_visual_engine(found_shots[current_shot_idx].angle)
            elseif key == "n" then
                current_shot_idx = current_shot_idx + 1
                if current_shot_idx > #found_shots then current_shot_idx = 1 end
                setup_visual_engine(found_shots[current_shot_idx].angle)
            elseif key == "b" then
                current_shot_idx = current_shot_idx - 1
                if current_shot_idx < 1 then current_shot_idx = #found_shots end
                setup_visual_engine(found_shots[current_shot_idx].angle)
            else
                if visual_engine then
                    visual_engine:keypressed(key)
                end
            end
        end
    end

    function callbacks.resize(w, h)
        Screen.resize(w, h)
    end

    return callbacks
end

return TestStyleShot
