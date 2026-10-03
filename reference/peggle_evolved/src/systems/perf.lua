local Perf = {
    is_enabled = false,
    update_start_time = 0,
    draw_start_time = 0,
    
    -- metrics
    total_update_time = 0,
    total_draw_time = 0,
    total_dt = 0,
    frames = 0,
    
    peg_checks = 0,
    collisions = 0,
    active_balls = 0,
    
    timer = 0,

    -- global metrics
    global_update_time = 0,
    global_draw_time = 0,
    global_frames = 0,
    global_time = 0,
    global_peg_checks = 0,
    global_collisions = 0
}

function Perf.enabled()
    return Perf.is_enabled
end

function Perf.init(enabled)
    Perf.is_enabled = enabled
    if not enabled then return end
    
    print("--- BENCHMARK MODE ENABLED ---")
    local has_jit, jit = pcall(require, "jit")
    if has_jit and jit then
        print("LuaJIT: true | version=" .. tostring(jit.version) .. " | arch=" .. tostring(jit.arch) .. " | status=" .. tostring(jit.status()))
    else
        print("LuaJIT: false")
    end
end

function Perf.beginUpdate()
    if not Perf.is_enabled then return end
    Perf.update_start_time = love.timer.getTime()
end

function Perf.endUpdate()
    if not Perf.is_enabled then return end
    local now = love.timer.getTime()
    local dt = now - Perf.update_start_time
    Perf.total_update_time = Perf.total_update_time + dt
    Perf.global_update_time = Perf.global_update_time + dt
end

function Perf.beginDraw()
    if not Perf.is_enabled then return end
    Perf.draw_start_time = love.timer.getTime()
end

function Perf.endDraw()
    if not Perf.is_enabled then return end
    local now = love.timer.getTime()
    local dt = now - Perf.draw_start_time
    Perf.total_draw_time = Perf.total_draw_time + dt
    Perf.global_draw_time = Perf.global_draw_time + dt
end

function Perf.incPegChecks(n)
    if not Perf.is_enabled then return end
    local count = n or 1
    Perf.peg_checks = Perf.peg_checks + count
    Perf.global_peg_checks = Perf.global_peg_checks + count
end

function Perf.incCollisions(n)
    if not Perf.is_enabled then return end
    local count = n or 1
    Perf.collisions = Perf.collisions + count
    Perf.global_collisions = Perf.global_collisions + count
end

function Perf.setActiveBalls(n)
    if not Perf.is_enabled then return end
    Perf.active_balls = n
end

function Perf.report(dt)
    if not Perf.is_enabled then return end
    
    Perf.total_dt = Perf.total_dt + dt
    Perf.frames = Perf.frames + 1
    Perf.timer = Perf.timer + dt
    
    Perf.global_time = Perf.global_time + dt
    Perf.global_frames = Perf.global_frames + 1
    
    if Perf.timer >= 1.0 then
        local avg_dt = (Perf.total_dt / Perf.frames) * 1000
        local avg_update = (Perf.total_update_time / Perf.frames) * 1000
        local avg_draw = (Perf.total_draw_time / Perf.frames) * 1000
        local fps = love.timer.getFPS()
        
        local has_jit, jit = pcall(require, "jit")
        local jit_status = false
        if has_jit and jit then
            jit_status = jit.status()
        end
        
        print(string.format("BENCH | fps=%d | avg_dt=%.3fms | update=%.3fms | draw=%.3fms | peg_checks=%d | collisions=%d | active_balls=%d | jit=%s",
            fps, avg_dt, avg_update, avg_draw, Perf.peg_checks, Perf.collisions, Perf.active_balls, tostring(jit_status)))
            
        Perf.total_update_time = 0
        Perf.total_draw_time = 0
        Perf.total_dt = 0
        Perf.frames = 0
        Perf.peg_checks = 0
        Perf.collisions = 0
        Perf.timer = Perf.timer - 1.0
    end
end

function Perf.saveAndExit(level_name, num_balls)
    if not Perf.is_enabled then return end
    
    local has_jit, jit = pcall(require, "jit")
    local jit_status = false
    if has_jit and jit then
        jit_status = jit.status()
    end
    
    local avg_fps = Perf.global_frames / Perf.global_time
    local avg_update = (Perf.global_update_time / Perf.global_frames) * 1000
    local avg_draw = (Perf.global_draw_time / Perf.global_frames) * 1000
    
    local file = io.open("benchmark_results.csv", "a")
    if file then
        local f = io.open("benchmark_results.csv", "r")
        local needs_header = true
        if f then
            local content = f:read(1)
            f:close()
            if content then needs_header = false end
        end
        if needs_header then
            file:write("level,balls,jit,total_time,frames,avg_fps,avg_update_ms,avg_draw_ms,peg_checks,collisions\n")
        end
        
        file:write(string.format("%s,%d,%s,%.3f,%d,%.2f,%.3f,%.3f,%d,%d\n",
            level_name, num_balls, tostring(jit_status), Perf.global_time, Perf.global_frames, 
            avg_fps, avg_update, avg_draw, Perf.global_peg_checks, Perf.global_collisions))
        file:close()
        print("Benchmark saved to benchmark_results.csv")
    else
        print("Error: Could not open benchmark_results.csv for writing.")
    end
    love.event.quit()
end

return Perf
