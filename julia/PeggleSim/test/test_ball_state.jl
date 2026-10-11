# Focused tests for src/ball_state.jl (workstream E), porting the dev-tree
# unit tests ../peggle_evolved/tests/test_ball_state.lua to the real
# GameplayJournal / GameplayCommands API. A real SimConfig is loaded from the
# mustache dev fixture.

using Test
using PeggleSim

const BS_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const BS_CONFIG_PATH =
    joinpath(BS_REPO_ROOT, "fixtures", "mustache", "config.dev.v1.json")

function _bs_trackers()
    t = PeggleSim.BallStateTrackers()
    PeggleSim.reset_shot!(t)
    return t
end

function _bs_ball(id::Int; vx = 0.0, vy = 0.0, launched = true)
    b = PeggleSim.BallState(id, 100.0, 100.0, 6.0)
    b.vx = vx
    b.vy = vy
    b.launched = launched
    return b
end

# One complete fixed step over a fresh journal/commands pair.
function _bs_step!(t, balls, dt, c; scored = false, style_award = false)
    j = PeggleSim.GameplayJournal()
    cmds = PeggleSim.GameplayCommands()
    PeggleSim.begin_step!(j, 1, 1)
    PeggleSim.begin_step!(cmds, 1, 1)
    if scored
        PeggleSim.emit_raw!(j, "ball_contacted_peg",
            Dict{String,Any}("ball_id" => 1, "peg_id" => 1))
    end
    PeggleSim.seal_raw!(j)
    if scored
        PeggleSim.emit_derived!(j, "peg_scored",
            Dict{String,Any}("peg_id" => 1, "ball_id" => 1))
    end
    if style_award
        PeggleSim.emit_derived!(j, "style_awarded",
            Dict{String,Any}("style" => "long_shot", "points" => 1000))
    end
    PeggleSim.ball_state_process!(t, j, cmds, balls, dt, c)
    PeggleSim.finish_step!(j)
    return j, cmds
end

_bs_derived_types(j) = [ev.type for ev in j.derived]
_bs_command_reasons(cmds) = Any[cmd["reason"] for cmd in cmds.commands]
_bs_has_derived(j, event_type) = event_type in _bs_derived_types(j)

@testset "ball state" begin
    c = PeggleSim.load_config(BS_CONFIG_PATH)
    dt = c.fixed_dt
    idle_steps = ceil(Int, c.clear_still_time / dt) + 1

    @testset "active -> slow -> idle" begin
        t = _bs_trackers()
        j, _ = _bs_step!(t, [_bs_ball(1; vx = 100.0, vy = 100.0)], dt, c)
        @test !PeggleSim._bs_truthy(get(t.idle, 1, nothing))
        @test !_bs_has_derived(j, "ball_became_idle")

        # A ball below still speed must persist for clear_still_time.
        idle_events = 0
        for _ in 1:idle_steps
            j, _ = _bs_step!(t, [_bs_ball(1; vx = 1.0, vy = 1.0)], dt, c)
            idle_events += count(==("ball_became_idle"), _bs_derived_types(j))
        end
        @test t.idle[1] === true
        @test t.idle_timer[1] >= c.clear_still_time
        @test idle_events == 1
    end

    @testset "wake hysteresis" begin
        t = _bs_trackers()
        for _ in 1:idle_steps
            _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
        end
        @test t.idle[1] === true

        wake = c.ball_still_speed * c.ball_wake_speed_multiplier
        # Inside the band [still, wake): stays idle, no reactivation.
        band = (c.ball_still_speed + wake) / 2.0
        j, _ = _bs_step!(t, [_bs_ball(1; vx = band, vy = 0.0)], dt, c)
        @test t.idle[1] === true
        @test !_bs_has_derived(j, "ball_reactivated")

        # At/above the wake speed: reactivates exactly once.
        j, _ = _bs_step!(t, [_bs_ball(1; vx = wake, vy = 0.0)], dt, c)
        @test t.idle[1] === false
        @test t.idle_timer[1] == 0.0
        @test t.reacted[1] === true
        @test _bs_has_derived(j, "ball_reactivated")

        j, _ = _bs_step!(t, [_bs_ball(1; vx = wake * 2.0, vy = 0.0)], dt, c)
        @test !_bs_has_derived(j, "ball_reactivated")
    end

    @testset "reactivation fires once per idle episode" begin
        t = _bs_trackers()
        for _ in 1:idle_steps
            _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
        end
        j, _ = _bs_step!(t, [_bs_ball(1; vx = 200.0, vy = 0.0)], dt, c)
        @test _bs_has_derived(j, "ball_reactivated")

        # Re-enter idle: ball_became_idle must fire again and reactivated
        # must be allowed again.
        local saw_idle = false
        for _ in 1:idle_steps
            local j2
            j2, _ = _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
            saw_idle = saw_idle || _bs_has_derived(j2, "ball_became_idle")
        end
        @test saw_idle
        j, _ = _bs_step!(t, [_bs_ball(1; vx = 200.0, vy = 0.0)], dt, c)
        @test _bs_has_derived(j, "ball_reactivated")
    end

    @testset "ball_became_idle fires once per entry" begin
        t = _bs_trackers()
        n = 0
        for _ in 1:idle_steps
            j, _ = _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
            n += count(==("ball_became_idle"), _bs_derived_types(j))
        end
        @test n == 1
        for _ in 1:3
            j, _ = _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
            n += count(==("ball_became_idle"), _bs_derived_types(j))
        end
        @test n == 1
    end

    @testset "all balls idle latch and clearing command" begin
        t = _bs_trackers()
        all_idle_steps = 0
        push_steps = 0
        local command
        for _ in 1:(idle_steps + 5)
            j, cmds = _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
            if _bs_has_derived(j, "all_balls_became_idle")
                all_idle_steps += 1
            end
            if !isempty(cmds.commands)
                push_steps += 1
                command = cmds.commands[1]
            end
        end
        @test all_idle_steps == 1
        @test push_steps == 1
        @test t.all_idle_latch === true
        @test command["type"] == "start_midturn_clearing"
        @test command["reason"] == "all_balls_became_idle"

        # A moving ball clears the latch; a later all-idle episode re-fires.
        j, cmds = _bs_step!(t, [_bs_ball(1; vx = 200.0, vy = 0.0)], dt, c)
        @test t.all_idle_latch === false
        @test !_bs_has_derived(j, "all_balls_became_idle")
        @test isempty(cmds.commands)

        local refired = false
        for _ in 1:(idle_steps + 2)
            local j2, cmds2
            j2, cmds2 = _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
            if _bs_has_derived(j2, "all_balls_became_idle")
                refired = true
                @test length(cmds2.commands) == 1
                @test cmds2.commands[1]["reason"] == "all_balls_became_idle"
            end
        end
        @test refired
    end

    @testset "moving ball prevents all-idle" begin
        t = _bs_trackers()
        j, cmds = _bs_step!(t,
            [_bs_ball(1; vx = 0.0, vy = 0.0), _bs_ball(2; vx = 200.0, vy = 0.0)],
            dt, c)
        @test !_bs_has_derived(j, "all_balls_became_idle")
        @test isempty(cmds.commands)
    end

    @testset "no-score timer" begin
        # Scoring resets it every step.
        t = _bs_trackers()
        for _ in 1:100
            _bs_step!(t, [_bs_ball(1; vx = 50.0, vy = 50.0)], dt, c; scored = true)
        end
        @test t.no_score_timer == 0.0
        @test t.no_score_timeout_fired === false

        # Style awards do not reset it.
        t = _bs_trackers()
        j, cmds = _bs_step!(t, [_bs_ball(1; vx = 50.0, vy = 50.0)], dt, c;
                            style_award = true)
        @test !_bs_has_derived(j, "no_score_timeout_reached")
        @test t.no_score_timer == dt
        @test isempty(cmds.commands)

        # It accumulates exactly by dt without scoring.
        for _ in 1:9
            _bs_step!(t, [_bs_ball(1; vx = 50.0, vy = 50.0)], dt, c)
        end
        @test isapprox(t.no_score_timer, 10.0 * dt; atol = 1e-12)
    end

    @testset "no-score timeout fires once" begin
        t = _bs_trackers()
        timeouts = 0
        local timeout_event
        total = 0.0
        for _ in 1:2000
            j, cmds = _bs_step!(t, [_bs_ball(1; vx = 50.0, vy = 50.0)], dt, c)
            for ev in j.derived
                if ev.type == "no_score_timeout_reached"
                    timeouts += 1
                    timeout_event = ev
                end
            end
            for cmd in cmds.commands
                @test cmd["reason"] == "no_score_timeout_reached"
            end
            total += dt
            total > c.clear_no_score_time * 2 && break
        end
        @test timeouts == 1
        @test t.no_score_timeout_fired === true
        # The event carries the timer value at the moment it fired; the timer
        # itself keeps accumulating afterwards (Lua semantics).
        @test timeout_event.fields["elapsed"] >= c.clear_no_score_time
        @test isapprox(Float64(timeout_event.fields["elapsed"]),
                       c.clear_no_score_time; atol = 1e-9)
        @test Float64(timeout_event.fields["elapsed"]) <= t.no_score_timer
    end

    @testset "reset_timers and ball removal/spawn" begin
        t = _bs_trackers()
        for _ in 1:idle_steps
            _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
        end
        @test t.all_idle_latch === true
        @test t.idle[1] === true

        PeggleSim.ball_state_reset_timers!(t)
        @test isempty(t.idle) && isempty(t.idle_timer) && isempty(t.reacted)
        @test t.all_idle_latch === false
        @test t.no_score_timer == 0.0
        @test t.no_score_timeout_fired === false

        # After reset a fresh episode pushes once more.
        pushes = 0
        for _ in 1:(idle_steps + 2)
            _, cmds = _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
            pushes += length(cmds.commands)
        end
        @test pushes == 1

        # on_ball_removed deletes the per-ball state.
        t = _bs_trackers()
        for _ in 1:idle_steps
            _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
        end
        @test haskey(t.idle, 1)
        PeggleSim.ball_state_on_ball_removed!(t, 1)
        @test !haskey(t.idle, 1)
        @test !haskey(t.idle_timer, 1)
        @test !haskey(t.reacted, 1)

        # on_ball_spawned clears the latch.
        t = _bs_trackers()
        for _ in 1:idle_steps
            _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0)], dt, c)
        end
        @test t.all_idle_latch === true
        PeggleSim.ball_state_on_ball_spawned!(t)
        @test t.all_idle_latch === false
    end

    @testset "unlaunched balls are ignored" begin
        t = _bs_trackers()
        j, cmds = _bs_step!(t, [_bs_ball(1; vx = 0.0, vy = 0.0, launched = false)],
                            dt, c)
        @test isempty(t.idle)
        @test !_bs_has_derived(j, "all_balls_became_idle")
        @test !_bs_has_derived(j, "ball_became_idle")
        @test isempty(cmds.commands)
    end

    @testset "removed idle ball stops counting toward all-idle" begin
        t = _bs_trackers()
        # One idle and one moving; removing the idle one leaves a moving ball,
        # so no all-idle episode can fire.
        _bs_step!(t,
            [_bs_ball(1; vx = 0.0, vy = 0.0), _bs_ball(2; vx = 100.0, vy = 100.0)],
            dt, c)
        PeggleSim.ball_state_on_ball_removed!(t, 1)
        j, cmds = _bs_step!(t, [_bs_ball(2; vx = 100.0, vy = 100.0)], dt, c)
        @test !_bs_has_derived(j, "all_balls_became_idle")
        @test isempty(cmds.commands)
    end

    @testset "external movement is judged by velocity" begin
        t = _bs_trackers()
        b = _bs_ball(1; vx = 30.0, vy = 0.0)
        b.x = 200.0
        _bs_step!(t, [b], dt, c)
        @test !PeggleSim._bs_truthy(get(t.idle, 1, nothing))
    end
end
