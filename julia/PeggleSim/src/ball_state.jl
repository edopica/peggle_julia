# ===========================================================================
# BallState: per-ball lifecycle, idle, and no-score detection.
#
# Ports src/systems/ball_state.lua (dev tree, `detmath.sqrt` routing). Owns
# the gameplay idle / stall / no-score timers and emits derived events plus
# `start_midturn_clearing` commands.
#
# Responsibilities:
#   * Per-ball idle tracking: a launched ball whose speed stays below
#     ball_still_speed for clear_still_time becomes idle (`ball_became_idle`
#     derived event on each transition into idle).
#   * Wake hysteresis: an IDLE ball reactivates only when its speed reaches
#     ball_still_speed * ball_wake_speed_multiplier. In the hysteresis band an
#     idle ball stays idle. `ball_reactivated` fires exactly once per
#     idle-to-moving transition.
#   * `all_balls_became_idle` derived event when every launched ball is idle
#     (latched); one `start_midturn_clearing` command per all-idle episode.
#   * No-score timer: reset to 0 on every `peg_scored` derived event. When it
#     reaches clear_no_score_time, emit `no_score_timeout_reached` once per
#     interval and push `start_midturn_clearing`.
#   * Style points do NOT reset the no-score timer.
#
# Lua nil/false reads map to explicit `nothing`/`false` checks via
# `_bs_truthy` (a missing key and a stored `false` are both "not set").
# ===========================================================================

# Lua truthiness for values read from the tracker maps (nil/false are falsy).
_bs_truthy(v) = v !== nothing && v !== false

# Local ball_speed(b): sqrt(vx*vx + vy*vy).
function _bs_ball_speed(b::BallState)::Float64
    return DetMath.det_sqrt(b.vx * b.vx + b.vy * b.vy)
end

# Process one completed fixed step. The journal must be sealed (raw phase
# complete) and already hold the step's peg_scored derived events. Only
# launched balls are considered.
function ball_state_process!(
    t::BallStateTrackers,
    journal::GameplayJournal,
    commands::GameplayCommands,
    balls::Vector{BallState},
    dt::Float64,
    c::SimConfig,
)::Nothing
    still_speed = c.ball_still_speed
    clear_still = c.clear_still_time
    clear_no_score = c.clear_no_score_time

    # Wake hysteresis: an idle ball must exceed still_speed * multiplier to
    # reactivate (configurable; not hard-coded).
    wake_mult = c.ball_wake_speed_multiplier
    wake_speed = still_speed * wake_mult

    # Did any peg score this step? (resets no-score timer)
    scored_this_step = false
    for ev in journal.derived
        if ev.type == "peg_scored"
            scored_this_step = true
            break
        end
    end

    if scored_this_step
        t.no_score_timer = 0.0
        t.no_score_timeout_fired = false
    else
        t.no_score_timer = t.no_score_timer + dt
    end

    # Per-ball idle tracking with wake hysteresis.
    all_idle = true
    has_launched = false
    for b in balls
        b.launched || continue
        has_launched = true
        bid = b.id
        speed = _bs_ball_speed(b)
        if _bs_truthy(get(t.idle, bid, nothing))
            # Idle: reactivate only above the wake threshold (hysteresis).
            if speed >= wake_speed
                t.idle[bid] = false
                t.idle_timer[bid] = 0.0
                all_idle = false
                if !_bs_truthy(get(t.reacted, bid, nothing))
                    t.reacted[bid] = true
                    emit_derived!(journal, "ball_reactivated",
                                  Dict{String,Any}("ball_id" => bid))
                end
            end
            # In the hysteresis band the ball stays idle (no timer change).
        else
            if speed >= still_speed
                # Active: any sustained slow-down restarts from zero.
                t.idle_timer[bid] = 0.0
                all_idle = false
            else
                timer = get(t.idle_timer, bid, nothing)
                timer_new = (timer === nothing ? 0.0 : Float64(timer)) + dt
                t.idle_timer[bid] = timer_new
                if timer_new >= clear_still
                    t.idle[bid] = true
                    # A new idle->moving transition may reactivate again later.
                    t.reacted[bid] = false
                    emit_derived!(journal, "ball_became_idle",
                                  Dict{String,Any}("ball_id" => bid))
                else
                    # Slow but not yet idle: prevents all-idle.
                    all_idle = false
                end
            end
        end
    end

    # All-idle latch: emit the event and push the clearing command exactly
    # once per all-idle episode (not every step).
    if has_launched && all_idle
        if !t.all_idle_latch
            t.all_idle_latch = true
            emit_derived!(journal, "all_balls_became_idle", nothing)
            push_command!(commands, "start_midturn_clearing",
                          Dict{String,Any}("reason" => "all_balls_became_idle"))
        end
    else
        # A non-idle ball (or no launched balls) resets the episode latch.
        t.all_idle_latch = false
    end

    # No-score timeout: emit once per interval, push midturn clearing.
    if t.no_score_timer >= clear_no_score && !t.no_score_timeout_fired
        t.no_score_timeout_fired = true
        emit_derived!(journal, "no_score_timeout_reached",
                      Dict{String,Any}("elapsed" => t.no_score_timer))
        push_command!(commands, "start_midturn_clearing",
                      Dict{String,Any}("reason" => "no_score_timeout_reached"))
    end
    return nothing
end

# Reset the idle/no-score timers (called after a mid-turn clear completes so
# the ball can play on, or when a stall condition fires with no hit pegs).
function ball_state_reset_timers!(t::BallStateTrackers)::Nothing
    empty!(t.idle)
    empty!(t.idle_timer)
    empty!(t.reacted)
    t.all_idle_latch = false
    t.no_score_timer = 0.0
    t.no_score_timeout_fired = false
    return nothing
end

# Notify that a new ball was spawned (resets all-idle latch).
function ball_state_on_ball_spawned!(t::BallStateTrackers)::Nothing
    t.all_idle_latch = false
    return nothing
end

# Notify that a ball was removed.
function ball_state_on_ball_removed!(t::BallStateTrackers, ball_id::Int)::Nothing
    delete!(t.idle, ball_id)
    delete!(t.idle_timer, ball_id)
    delete!(t.reacted, ball_id)
    return nothing
end
