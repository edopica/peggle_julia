# Shot-time engine pipeline: port of ../peggle_evolved/src/engine/core.lua
# (dev tree @ da752257). Only the authoritative fixed-step pipeline is ported;
# the following Engine responsibilities are intentionally excluded:
#
#   * presentation/replay: Replay.serialize/write, TraceExporter (legacy),
#     ContactEvents, ImpactDebug, Perf, rendering, mouse/keyboard input;
#   * circuit motion: static levels only (empty circuit collections);
#   * shot-timeline retention and onStepFinalized/onHUDRefresh callbacks.
#
# `ShotEngine` wraps the M2 `SimState` and owns the shot-time runtime state:
# journals, per-shape peg lists, aim angle, shot lifecycle flags, buffered
# derived events, staged power spawns, and the optional canonical trace
# writer. The pipeline order follows core.lua Engine:stepSimulation and every
# code path reaches Engine:finalizeStep.

# Maximum normalized time-of-impact spread for two line contacts to count as
# one simultaneous shared-boundary crossing (core.lua line 40). Contacts in
# the same CCD iteration at different TOIs are sequential crossings.
const SEAM_TOI_EPSILON = 0.05

# Sentinels matching Lua's end-of-shot bookkeeping.
const SHOT_END_HANDLED = "__handled"

struct ShotCallbacks
    on_all_balls_depleted::Union{Nothing,Function}  # eng -> Bool skip_clearing
    on_bucket_catch::Union{Nothing,Function}        # eng -> Nothing
    on_style_shot::Union{Nothing,Function}          # eng, info -> Nothing
    on_turn_end::Union{Nothing,Function}            # eng -> Nothing
end

function ShotCallbacks(;
    on_all_balls_depleted = nothing,
    on_bucket_catch = nothing,
    on_style_shot = nothing,
    on_turn_end = nothing,
)::ShotCallbacks
    return ShotCallbacks(
        on_all_balls_depleted, on_bucket_catch, on_style_shot, on_turn_end)
end

mutable struct ShotEngine
    sim::SimState
    config::SimConfig
    virtual_width::Float64
    virtual_height::Float64
    journal::GameplayJournal
    commands::GameplayCommands
    circle_pegs::Vector{Peg}
    rect_pegs::Vector{Peg}
    annular_pegs::Vector{Peg}
    callbacks::ShotCallbacks
    current_aim_angle::Float64
    # shot runtime (not checkpointed)
    shot_initial_step::Int
    shot_final_step::Int
    shot_end_reason::Union{Nothing,String}
    last_removal_reason::Union{Nothing,String}
    shot_end_pending::Bool
    scored_this_step::Bool
    midturn_clear_started::Bool
    buffered_peg_scored::Vector{Dict{String,Any}}
    pending_spawn_specs::Vector{PowerSpawnSpec}
    skip_clearing::Bool
    shot_done::Bool
    trace::Union{Nothing,GameplayTraceWriter}
    accumulator::Float64
    steps_run::Int
    turn_peg_refs::Vector{Peg}
    initial_balls::Int
    style_counts::Dict{String,Int}
end

# ---------------------------------------------------------------------------
# Aim helpers
# ---------------------------------------------------------------------------

# Physics.getSnappedAimAngle port (snapped_aim_angle facade).
function snapped_aim_angle(angle::Float64, c::SimConfig)::Float64
    return get_snapped_aim_angle(angle, c)
end

# Harness grid formula: AIM_MIN + (index / AIM_STEPS) * AIM_SPAN.
function angle_for_index(index::Int, c::SimConfig)::Float64
    aim_mid = pi / 2
    aim_limit = c.aim_angle_limit
    aim_min = aim_mid - aim_limit
    aim_span = 2 * aim_limit
    return aim_min + (index / c.aim_discretization_steps) * aim_span
end

# Lua Peg.value.
function peg_value(p::Peg, c::SimConfig)::Float64
    return c.peg_types[p.peg_type].value
end

# ---------------------------------------------------------------------------
# Construction / reset
# ---------------------------------------------------------------------------

function _split_peg_lists!(eng::ShotEngine)::Nothing
    empty!(eng.circle_pegs)
    empty!(eng.rect_pegs)
    empty!(eng.annular_pegs)
    for p in eng.sim.engine.pegs
        if p.shape isa CircleShape
            push!(eng.circle_pegs, p)
        elseif p.shape isa RectangleShape
            push!(eng.rect_pegs, p)
        else
            push!(eng.annular_pegs, p)
        end
    end
    return nothing
end

function _fresh_shot_engine(sim::SimState, config::SimConfig, vw::Float64,
                            vh::Float64,
                            callbacks::ShotCallbacks)::ShotEngine
    eng = ShotEngine(
        sim, config, vw, vh,
        GameplayJournal(), GameplayCommands(),
        Peg[], Peg[], Peg[],
        callbacks,
        pi / 2,
        0, 0, nothing, nothing, false, false, false,
        Dict{String,Any}[], PowerSpawnSpec[],
        false, false, nothing,
        0.0, 0,
        Peg[], length(sim.engine.balls), Dict{String,Int}(),
    )
    _split_peg_lists!(eng)
    return eng
end

# Build a shot engine from a ready-to-aim checkpoint. The level's virtual
# width/height default to the config values but are passed explicitly by the
# driver (level artifacts may override: mustache is 880x550 while the config
# carries 1200x1900). A `level` keyword overrides both.
function shot_engine(ckpt::Checkpoint;
                     config::SimConfig,
                     callbacks::ShotCallbacks = ShotCallbacks(),
                     virtual_width::Float64 = config.virtual_width,
                     virtual_height::Float64 = config.virtual_height,
                     level::Union{Nothing,LevelDefinition} = nothing)::ShotEngine
    vw = level === nothing ? virtual_width : level.virtual_width
    vh = level === nothing ? virtual_height : level.virtual_height
    return _fresh_shot_engine(sim_from_checkpoint(ckpt), config, vw, vh, callbacks)
end

# Restore an engine in place from a checkpoint (same identity namespace
# semantics as Engine:applyReplayState/resetTurn: the checkpoint's
# next_ball_id/used_ball_ids are authoritative).
function reset_shot_engine!(eng::ShotEngine, ckpt::Checkpoint)::ShotEngine
    restore!(eng.sim, ckpt)
    _split_peg_lists!(eng)
    reset!(eng.journal)
    reset!(eng.commands)
    eng.accumulator = 0.0
    eng.steps_run = 0
    eng.shot_initial_step = 0
    eng.shot_final_step = 0
    eng.shot_end_reason = nothing
    eng.last_removal_reason = nothing
    eng.shot_end_pending = false
    eng.scored_this_step = false
    eng.midturn_clear_started = false
    eng.skip_clearing = false
    eng.shot_done = false
    eng.current_aim_angle = pi / 2
    eng.initial_balls = length(eng.sim.engine.balls)
    empty!(eng.buffered_peg_scored)
    empty!(eng.pending_spawn_specs)
    empty!(eng.turn_peg_refs)
    for id in eng.sim.engine.turn_pegs_hit
        peg = get(eng.sim.engine.peg_by_id, id, nothing)
        peg === nothing || push!(eng.turn_peg_refs, peg)
    end
    empty!(eng.style_counts)
    return eng
end

# ---------------------------------------------------------------------------
# Stable ball identities (Engine:registerBall / Engine:unregisterBall)
# ---------------------------------------------------------------------------

# BallState has no nil id; 0 is the sentinel for "allocate the next id".
function register_ball!(e::EngineState, b::BallState)::BallState
    id = b.id
    auto = id == 0

    if auto
        candidate = e.next_ball_id
        while candidate in e.used_ball_ids
            candidate += 1
        end
        id = candidate
    end

    existing_id = get(e.live_id_by_ball, b, 0)
    if existing_id != 0
        existing_id == id && return b
        error("register_ball!: ball id changed from $(existing_id) to $(id) while registered")
    end

    id in e.used_ball_ids && error(
        "register_ball!: ball id $(id) already consumed and cannot be reused")
    haskey(e.live_ball_ids, id) && error(
        "register_ball!: duplicate live ball id $(id)")

    if auto
        b.id = id
    end
    push!(e.used_ball_ids, id)
    e.live_ball_ids[id] = b
    e.live_id_by_ball[b] = id
    if id >= e.next_ball_id
        e.next_ball_id = id + 1
    end
    return b
end

function unregister_ball!(e::EngineState,
                          b::Union{Nothing,BallState})::Nothing
    b === nothing && return nothing
    id = get(e.live_id_by_ball, b, 0)
    id == 0 && return nothing
    b.id == id || error(
        "unregister_ball!: ball id changed from $(id) to $(b.id) while registered")
    get(e.live_ball_ids, id, nothing) === b || error(
        "unregister_ball!: live mapping inconsistent for id $(id)")
    delete!(e.live_ball_ids, id)
    delete!(e.live_id_by_ball, b)
    return nothing
end

# ---------------------------------------------------------------------------
# Authoritative peg-hit reduction (post-physics)
# ---------------------------------------------------------------------------

const SCORING_CONTACT_KINDS = ("sweep", "graze", "overlap", "depenetrate")

# Engine:contactCanScore predicate: a raw ball_contacted_peg event may score
# iff its contact kind is scoring-eligible, the peg exists, and it is a
# first hit.
function _contact_can_score(ev::GameEvent, peg::Union{Nothing,Peg})::Bool
    ev.type == "ball_contacted_peg" || return false
    kind = get(ev.fields, "contact_kind", nothing)
    (kind isa AbstractString && kind in SCORING_CONTACT_KINDS) || return false
    peg === nothing && return false
    peg.hit && return false
    return true
end

function _event_toi(ev::GameEvent)::Float64
    toi = get(ev.fields, "toi", nothing)
    return toi === nothing ? 0.0 : Float64(toi)
end

function _peg_line_dict(line::LineMetadata)::Dict{String,Any}
    return Dict{String,Any}(
        "id" => line.id,
        "index" => line.index,
        "count" => line.count,
        "closed" => line.closed,
        "gap" => line.gap,
    )
end

# Engine:scorePeg - first-hit scoring plus the buffered peg_scored event.
function score_peg!(eng::ShotEngine, peg::Peg, ev::GameEvent)::Nothing
    e = eng.sim.engine
    peg.hit = true
    e.hit_counter += 1
    peg.hit_order = e.hit_counter

    if peg.peg_type === :red
        e.red_pegs_hit_amount += 1
        update_multiplier!(e)
    end

    peg.multiplier_at_hit = e.current_multiplier
    push!(e.turn_pegs_hit, peg.id)
    push!(eng.turn_peg_refs, peg)
    eng.scored_this_step = true

    ps = Dict{String,Any}(
        "source_sequence" => ev.sequence,
        "ball_id" => ev.fields["ball_id"],
        "peg_id" => peg.id,
        "peg_type" => String(peg.peg_type),
        "peg_shape" => peg_shape_name(peg.shape),
        "contact_kind" => ev.fields["contact_kind"],
        "did_bounce" => ev.fields["did_bounce"],
        "iteration" => ev.fields["iteration"],
        "impact_x" => ev.fields["impact_x"],
        "impact_y" => ev.fields["impact_y"],
        "hit_order" => peg.hit_order,
        "multiplier_at_hit" => peg.multiplier_at_hit,
        "peg_value" => peg_value(peg, eng.config),
    )
    if peg.line !== nothing
        ps["line"] = _peg_line_dict(peg.line)
    end
    push!(eng.buffered_peg_scored, ps)

    if peg.peg_type === :green
        append!(eng.pending_spawn_specs, powers_activate(peg, eng.config))
    elseif peg.peg_type === :purple
        on_purple_peg_hit!(eng.sim.colors, peg)
    end
    return nothing
end

# Engine:reducePegContacts - ordered raw peg-contact reduction with the
# zero-gap line-seam collapse (SEAM_TOI_EPSILON).
function reduce_peg_contacts!(eng::ShotEngine)::Nothing
    e = eng.sim.engine
    empty!(eng.buffered_peg_scored)
    empty!(eng.pending_spawn_specs)

    # Phase 1: collect all eligible raw contacts in raw order.
    candidates = Tuple{GameEvent,Peg}[]
    for ev in eng.journal.raw
        if ev.type == "ball_contacted_peg"
            peg = get(e.peg_by_id, Int(ev.fields["peg_id"]), nothing)
            if _contact_can_score(ev, peg)
                push!(candidates, (ev, peg))
            end
        end
    end

    # Phase 2: group simultaneous (ball, line, iteration) zero-gap line
    # contacts, deduplicated per peg keeping the earliest TOI.
    groups = Dict{String,Vector{Tuple{GameEvent,Peg}}}()
    group_keys = String[]
    for (ev, peg) in candidates
        line = peg.line
        line === nothing && continue
        iteration = get(ev.fields, "iteration", nothing)
        iteration === nothing && continue
        line.gap == 0 || continue
        key = string(ev.fields["ball_id"], "|", line.id, "|",
                     string(Int(iteration)))
        group = get!(groups, key) do
            push!(group_keys, key)
            Tuple{GameEvent,Peg}[]
        end
        existing = findfirst(entry -> entry[2] === peg, group)
        if existing === nothing
            push!(group, (ev, peg))
        elseif _event_toi(ev) < _event_toi(group[existing][1])
            group[existing] = (ev, peg)
        end
    end

    # Collapse a contiguous adjacent-index run whose TOI spread is within the
    # seam epsilon to its lowest line index.
    suppressed = Dict{String,IdDict{Peg,Bool}}()
    for key in group_keys
        group = groups[key]
        n = length(group)
        n >= 2 || continue
        sort!(group; by = entry -> entry[2].line.index, alg = MergeSort)
        toi_min = _event_toi(group[1][1])
        toi_max = toi_min
        for entry in group
            toi = _event_toi(entry[1])
            toi < toi_min && (toi_min = toi)
            toi > toi_max && (toi_max = toi)
        end
        first_line = group[1][2].line
        links = 0
        for i in 2:n
            if group[i][2].line.index == group[i - 1][2].line.index + 1
                links += 1
            end
        end
        if first_line.closed && first_line.count >= 3 &&
           group[1][2].line.index == 1 &&
           group[n][2].line.index == first_line.count
            links += 1
        end
        if links == n - 1 && (toi_max - toi_min) <= SEAM_TOI_EPSILON
            drop = get!(suppressed, key) do
                IdDict{Peg,Bool}()
            end
            for i in 2:n
                drop[group[i][2]] = true
            end
        end
    end

    # Phase 3: score each peg at most once, using its first candidate in raw
    # order that is not suppressed.
    scored = IdDict{Peg,Bool}()
    for (ev, peg) in candidates
        haskey(scored, peg) && continue
        blocked = false
        line = peg.line
        if line !== nothing
            iteration = get(ev.fields, "iteration", nothing)
            if iteration !== nothing
                key = string(ev.fields["ball_id"], "|", line.id, "|",
                             string(Int(iteration)))
                drop = get(suppressed, key, nothing)
                blocked = drop !== nothing && get(drop, peg, false)
            end
        end
        if !blocked
            score_peg!(eng, peg, ev)
            scored[peg] = true
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Clearing cascade
# ---------------------------------------------------------------------------

function start_clearing!(eng::ShotEngine, is_end_of_turn::Bool)::Nothing
    e = eng.sim.engine
    lit = Peg[p for p in e.pegs if p.hit]
    sort!(lit; by = p -> p.hit_order)
    e.clear_queue = lit
    e.clear_timer = 0.0
    e.clearing_is_end_of_turn = is_end_of_turn
    return nothing
end

function _remove_identity!(list::Vector{Peg}, peg::Peg)::Nothing
    for i in eachindex(list)
        if list[i] === peg
            deleteat!(list, i)
            break
        end
    end
    return nothing
end

# Engine:removePeg - drop the peg from every board collection. The score
# (turn_pegs_hit) is intentionally untouched.
function remove_peg!(eng::ShotEngine, peg::Peg)::Nothing
    e = eng.sim.engine
    _remove_identity!(e.pegs, peg)
    on_peg_removed!(eng.sim.colors, peg)
    delete!(e.peg_by_id, peg.id)
    if peg.shape isa CircleShape
        _remove_identity!(eng.circle_pegs, peg)
    elseif peg.shape isa RectangleShape
        _remove_identity!(eng.rect_pegs, peg)
    else
        _remove_identity!(eng.annular_pegs, peg)
    end
    return nothing
end

function update_clearing!(eng::ShotEngine, dt::Float64)::Nothing
    e = eng.sim.engine
    queue = e.clear_queue
    queue === nothing && return nothing
    interval = eng.config.peg_vanish_interval
    e.clear_timer += dt
    while !isempty(queue) && e.clear_timer >= interval
        e.clear_timer -= interval
        peg = popfirst!(queue)
        remove_peg!(eng, peg)
    end

    if isempty(queue)
        e.clear_queue = nothing
        if e.clearing_is_end_of_turn
            # Defer onTurnEnd to the finalize phase so shot_completed lands
            # first.
            eng.shot_end_pending = true
        else
            ball_state_reset_timers!(eng.sim.trackers.ball_state)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Gameplay command application
# ---------------------------------------------------------------------------

# Lua `{k = v}` drops nil-valued keys; build the same shape for events whose
# payload fields come from optional command keys.
function _present_payload(entries::Pair...)::Dict{String,Any}
    d = Dict{String,Any}()
    for (key, value) in entries
        value === nothing || (d[key] = value)
    end
    return d
end

function apply_commands!(eng::ShotEngine)::Nothing
    e = eng.sim.engine
    for cmd in eng.commands.commands
        status = "applied"
        ctype = cmd["type"]

        if ctype == "award_style_points"
            points = get(cmd, "points", nothing)
            e.style_score = e.style_score +
                (points === nothing ? 0.0 : Float64(points))
            emit_derived!(eng.journal, "style_awarded", _present_payload(
                "ball_id" => get(cmd, "ball_id", nothing),
                "style" => get(cmd, "style", nothing),
                "points" => points,
                "distance" => get(cmd, "distance", nothing),
                "peg_id" => get(cmd, "peg_id", nothing),
                "line_id" => get(cmd, "line_id", nothing),
                "source_sequences" => get(cmd, "source_sequences", nothing),
            ))
            cb = eng.callbacks.on_style_shot
            if cb !== nothing
                seqs = get(cmd, "source_sequences", nothing)
                info = _present_payload(
                    "ball_id" => get(cmd, "ball_id", nothing),
                    "style" => get(cmd, "style", nothing),
                    "points" => points,
                    "distance" => get(cmd, "distance", nothing),
                    "peg_id" => get(cmd, "peg_id", nothing),
                    "line_id" => get(cmd, "line_id", nothing),
                    "source_sequences" => seqs === nothing ? nothing : copy(seqs),
                )
                cb(eng, info)
            end
        elseif ctype == "start_midturn_clearing"
            # Idempotent: clearing initializes at most once per step.
            if e.clear_queue === nothing && !eng.midturn_clear_started
                eng.midturn_clear_started = true
                has_hit_pegs = any(p -> p.hit, e.pegs)
                if has_hit_pegs
                    start_clearing!(eng, false)
                else
                    ball_state_reset_timers!(eng.sim.trackers.ball_state)
                end
            else
                status = "ignored_duplicate"
            end
        elseif ctype == "remove_slide_pegs"
            removed = 0
            peg_ids = get(cmd, "peg_ids", nothing)
            for peg_id in (peg_ids === nothing ? Int[] : peg_ids)
                peg = get(e.peg_by_id, Int(peg_id), nothing)
                if peg !== nothing
                    remove_peg!(eng, peg)
                    removed += 1
                    emit_derived!(eng.journal, "slide_peg_removed",
                                  _present_payload(
                        "ball_id" => get(cmd, "ball_id", nothing),
                        "line_id" => get(cmd, "line_id", nothing),
                        "peg_id" => Int(peg_id),
                        "reason" => get(cmd, "reason", nothing),
                    ))
                end
            end
            removed == 0 && (status = "ignored_duplicate")
        end

        record_applied!(eng.commands, cmd, status)
    end
    eng.midturn_clear_started = false
    return nothing
end

# ---------------------------------------------------------------------------
# Scoring and shot lifecycle
# ---------------------------------------------------------------------------

# Engine:getTurnScore - weightedSum * count + bonus + style.
function get_turn_score(eng::ShotEngine)::Float64
    e = eng.sim.engine
    weighted_sum = 0.0
    count = 0
    for peg in eng.turn_peg_refs
        weighted_sum = weighted_sum +
            peg_value(peg, eng.config) * Float64(peg.multiplier_at_hit)
        count += 1
    end
    return weighted_sum * count + e.bonus_score + e.style_score
end

# Engine:getTurnPegScore - weightedSum * count only.
function get_turn_peg_score(eng::ShotEngine)::Float64
    weighted_sum = 0.0
    count = 0
    for peg in eng.turn_peg_refs
        weighted_sum = weighted_sum +
            peg_value(peg, eng.config) * Float64(peg.multiplier_at_hit)
        count += 1
    end
    return weighted_sum * count
end

# Engine:emitShotCompleted - ran after applyCommands so the totals include
# this step's style awards.
function emit_shot_completed!(eng::ShotEngine)::Nothing
    e = eng.sim.engine
    peg_score = get_turn_peg_score(eng)
    bonus_score = e.bonus_score
    style_score = e.style_score
    total_score = peg_score + bonus_score + style_score

    reason = eng.shot_end_reason
    if reason === nothing || reason == SHOT_END_HANDLED
        reason = eng.last_removal_reason === nothing ?
            "all_balls_removed" : eng.last_removal_reason
        eng.shot_end_reason = reason
    end

    emit_derived!(eng.journal, "shot_completed", Dict{String,Any}(
        "completion_reason" => reason,
        "initial_step" => eng.shot_initial_step,
        "final_step" => e.step_id,
        "shot_id" => e.shot_id,
        "peg_score" => peg_score,
        "bonus_score" => bonus_score,
        "style_score" => style_score,
        "total_score" => total_score,
    ))
    return nothing
end

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

function launch!(eng::ShotEngine, aim_index::Int)::Nothing
    eng.current_aim_angle = angle_for_index(aim_index, eng.config)
    _launch_balls!(eng)
    return nothing
end

# Engine:launchBalls (replay serialization/write skipped).
function _launch_balls!(eng::ShotEngine)::Nothing
    e = eng.sim.engine
    e.clear_queue === nothing || return nothing

    has_unlaunched = any(b -> !b.launched, e.balls)
    has_unlaunched || return nothing

    # New shot: shot_id identifies one launched shot including all balls
    # created as part of it.
    e.shot_id += 1
    eng.shot_initial_step = e.step_id + 1
    eng.shot_final_step = e.step_id
    eng.shot_end_reason = nothing
    eng.last_removal_reason = nothing
    reset_shot!(eng.sim.trackers)

    effective_angle = snapped_aim_angle(eng.current_aim_angle, eng.config)
    for b in e.balls
        if !b.launched
            b.launched = true
            b.vx = DetMath.det_cos(effective_angle) * eng.config.launch_speed
            b.vy = DetMath.det_sin(effective_angle) * eng.config.launch_speed
            stage!(eng.journal, "ball_launched", Dict{String,Any}(
                "ball_id" => b.id,
                "x" => b.x,
                "y" => b.y,
                "vx" => b.vx,
                "vy" => b.vy,
            ))
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Fixed-step pipeline
# ---------------------------------------------------------------------------

# Engine:savePreviousState - rendering interpolation state.
function save_previous_state(eng::ShotEngine)::Nothing
    e = eng.sim.engine
    for peg in e.pegs
        peg.prev_x = peg.x
        peg.prev_y = peg.y
        if peg.shape isa RectangleShape
            peg.prev_angle = peg.angle
        elseif peg.shape isa AnnularShape
            peg.prev_angle = peg.angle
        end
    end
    for b in e.balls
        b.prev_x = b.x
        b.prev_y = b.y
    end
    e.bucket.prev_x = e.bucket.x
    return nothing
end

# Engine:update - accumulator loop over fixed steps, then the fever-bucket
# animation update. Mouse/keyboard aim handling is presentation-only and not
# ported.
function update!(eng::ShotEngine, dt::Float64)::Nothing
    e = eng.sim.engine
    fixed_dt = eng.config.fixed_dt

    acc = eng.accumulator + dt
    while acc >= fixed_dt
        save_previous_state(eng)
        e.step_id += 1
        step_simulation!(eng, fixed_dt)
        acc -= fixed_dt
    end
    eng.accumulator = acc

    fever_update!(e.fever_buckets, dt, eng.config)
    eng.steps_run += 1
    return nothing
end

# Steps 1-5 of Engine:stepSimulation plus the finalize handoff.
function step_simulation!(eng::ShotEngine, dt::Float64)::Nothing
    e = eng.sim.engine
    eng.scored_this_step = false
    eng.shot_end_pending = false

    # (1) Begin gameplay event pipeline for this fixed step.
    begin_step!(eng.journal, e.step_id, e.shot_id)
    begin_step!(eng.commands, e.step_id, e.shot_id)

    # (2) Register any active balls lacking stable ids.
    for b in e.balls
        register_ball!(e, b)
    end

    # (3) time_step is dt headless (the right-mouse circuit speedup needs
    # input state); ultra-fever overrides every fever bucket value.
    if e.is_fever
        is_ultra = true
        for peg in e.pegs
            if !peg.hit
                is_ultra = false
                break
            end
        end
        if is_ultra
            for spec in e.fever_buckets.buckets
                spec.value = 100000.0
            end
        end
    end

    # (4) Bucket motion unless fever.
    if !e.is_fever
        bucket_update!(e.bucket, dt, eng.config, eng.virtual_width)
    end

    # (5) Clearing early path.
    if e.clear_queue !== nothing
        update_clearing!(eng, dt)
        finalize_step!(eng, dt)
        return nothing
    end

    _step_body!(eng, dt)
    finalize_step!(eng, dt)
    return nothing
end

# Steps 6-15 of Engine:stepSimulation.
function _step_body!(eng::ShotEngine, dt::Float64)::Nothing
    e = eng.sim.engine

    # (6) Circuits update: static levels only (no circuits).

    # (7) Physics -> raw collision events (observational).
    extras = e.is_fever ? e.fever_buckets.dividers : nothing
    physics_update!(e.balls, eng.circle_pegs, eng.rect_pegs, eng.annular_pegs,
                    dt, extras, eng.config, eng.virtual_width, eng.journal)

    # (8) draw_path path_step stamping is presentation-only.

    # (9) If not all launched, no bucket resolution this step.
    all_launched = true
    for b in e.balls
        if !b.launched
            all_launched = false
            break
        end
    end
    all_launched || return nothing

    # (10) Reduce raw peg contacts (authoritative first-hit scoring).
    reduce_peg_contacts!(eng)

    # (11) Bucket / fever resolution + raw events + mode callbacks.
    remaining_balls = BallState[]
    for b in e.balls
        remove_ball = false
        caught = false

        if e.is_fever
            res = fever_resolve!(e.fever_buckets, b)
            if res.result === :caught && !b.scored_fever
                e.bonus_score = e.bonus_score + res.value
                b.scored_fever = true
                emit_raw!(eng.journal, "fever_bucket_caught_ball",
                          Dict{String,Any}(
                    "ball_id" => b.id,
                    "x" => b.x, "y" => b.y,
                    "incoming_vx" => b.vx, "incoming_vy" => b.vy,
                    "outgoing_vx" => b.vx, "outgoing_vy" => b.vy,
                    "value" => res.value,
                ))
            end
        else
            in_vx, in_vy = b.vx, b.vy
            result = bucket_resolve!(e.bucket, b, eng.config)
            out_vx, out_vy = b.vx, b.vy
            if result === :caught
                caught = true
                remove_ball = true
                emit_raw!(eng.journal, "bucket_caught_ball", Dict{String,Any}(
                    "ball_id" => b.id,
                    "x" => b.x, "y" => b.y,
                    "incoming_vx" => in_vx, "incoming_vy" => in_vy,
                    "outgoing_vx" => out_vx, "outgoing_vy" => out_vy,
                    "bucket_x" => e.bucket.x,
                ))
                cb = eng.callbacks.on_bucket_catch
                cb === nothing || cb(eng)
            elseif result === :bounced
                emit_raw!(eng.journal, "bucket_bounced_ball", Dict{String,Any}(
                    "ball_id" => b.id,
                    "x" => b.x, "y" => b.y,
                    "incoming_vx" => in_vx, "incoming_vy" => in_vy,
                    "outgoing_vx" => out_vx, "outgoing_vy" => out_vy,
                    "bucket_x" => e.bucket.x,
                ))
            end
        end

        # (12) Fall-out detection (a caught ball must not also fell out).
        if !caught &&
           b.y - b.radius > eng.virtual_height + eng.config.fall_out_margin
            remove_ball = true
            emit_raw!(eng.journal, "ball_fell_out", Dict{String,Any}(
                "ball_id" => b.id,
                "x" => b.x, "y" => b.y,
                "reason" => "open_floor",
            ))
        end

        if remove_ball
            # (13) Ball removal: track reason, notify trackers, free live id.
            eng.last_removal_reason = caught ? "bucket_caught" : "fell_out"
            ball_state_on_ball_removed!(eng.sim.trackers.ball_state, b.id)
            slide_inversion_on_ball_removed!(eng.sim.trackers.slide_inversion, b.id)
            unregister_ball!(e, b)
        else
            push!(remaining_balls, b)
        end
    end
    e.balls = remaining_balls

    # (14) Append power-spawned balls (created during reduction); they begin
    # physics on the following fixed step.
    if !isempty(eng.pending_spawn_specs)
        for spec in eng.pending_spawn_specs
            nb = BallState(0, spec.x, spec.y, eng.config.ball_radius)
            nb.launched = true
            nb.vx = spec.vx
            nb.vy = spec.vy
            register_ball!(e, nb)
            push!(e.balls, nb)
            ball_state_on_ball_spawned!(eng.sim.trackers.ball_state)
            emit_raw!(eng.journal, "ball_spawned", Dict{String,Any}(
                "ball_id" => nb.id,
                "source" => "green_power",
                "x" => nb.x, "y" => nb.y,
                "vx" => nb.vx, "vy" => nb.vy,
            ))
        end
        empty!(eng.pending_spawn_specs)
    end

    # (15) Shot-end detection.
    if isempty(e.balls)
        skip_clearing = false
        cb = eng.callbacks.on_all_balls_depleted
        if cb !== nothing
            r = cb(eng)
            skip_clearing = !(r === nothing || r === false)
        end
        if !skip_clearing
            start_clearing!(eng, true)
        else
            # Mode handled depletion itself; the shot ends now.
            eng.shot_end_reason = eng.last_removal_reason === nothing ?
                "all_balls_removed" : eng.last_removal_reason
            eng.shot_end_pending = true
        end
    end
    return nothing
end

# Engine:finalizeStep - every code path reaches here.
function finalize_step!(eng::ShotEngine, dt::Float64)::Nothing
    e = eng.sim.engine

    # (16) Seal raw events.
    seal_raw!(eng.journal)

    # (17) Append buffered peg_scored derived events in source order.
    if !isempty(eng.buffered_peg_scored)
        for ps in eng.buffered_peg_scored
            emit_derived!(eng.journal, "peg_scored", ps)
        end
        empty!(eng.buffered_peg_scored)
    end

    # (18) StyleShots -> award_style_points commands.
    style_shots_process!(eng.sim.trackers.style_shots, eng.journal, eng.commands,
                         eng.virtual_width, eng.config)

    # (18b) SlideInversion -> remove_slide_pegs; paused during clearing.
    if e.clear_queue === nothing
        slide_inversion_process!(eng.sim.trackers.slide_inversion, eng.journal,
                                 eng.commands, e.balls, dt, eng.config)
    end

    # (19) BallState -> derived events + start_midturn_clearing command;
    # paused while a clearing cascade is active.
    if e.clear_queue === nothing
        ball_state_process!(eng.sim.trackers.ball_state, eng.journal,
                            eng.commands, e.balls, dt, eng.config)
    end

    # (20) Apply gameplay commands in deterministic order.
    apply_commands!(eng)

    # (21) Shot-lifecycle derived events (after command application so the
    # totals include this step's style awards). The engine owns shot
    # completion: reaching this transition (all balls depleted with clearing
    # skipped, or the end-of-turn clearing cascade drained) ends the shot
    # regardless of whether a callback is installed. Phase (25) notifies
    # on_turn_end afterwards.
    if eng.shot_end_pending
        eng.shot_end_pending = false
        emit_shot_completed!(eng)
        eng.shot_done = true
    end

    # (22)+(23) Trace step record (no timeline retention).
    if eng.trace !== nothing
        snap = journal_snapshot(eng.journal)
        record = Dict{String,Any}(
            "schema_version" => TRACE_SCHEMA_VERSION,
            "kind" => "step",
            "step" => e.step_id,
            "shot_id" => e.shot_id,
            "raw_events" => snap.raw,
            "derived_events" => snap.derived,
            "requested_commands" => command_snapshot(eng.commands),
            "applied_commands" => applied_snapshot(eng.commands),
        )
        if eng.trace.include_snapshot
            record["snapshot"] = snapshot_capture(eng)
        end
        trace_write_step!(eng.trace, record)
    end
    eng.shot_final_step = e.step_id

    # (25) If the shot ended, fire onTurnEnd and mark the reason handled.
    if eng.shot_end_reason !== nothing && eng.shot_end_reason != SHOT_END_HANDLED
        eng.shot_end_reason = SHOT_END_HANDLED
        cb = eng.callbacks.on_turn_end
        cb === nothing || cb(eng)
    end

    # (26) Finish/clear per-step working buffers.
    finish_step!(eng.journal)
    clear!(eng.commands)
    return nothing
end

# ---------------------------------------------------------------------------
# Driving and summary
# ---------------------------------------------------------------------------

function run_shot!(eng::ShotEngine; max_steps::Int = 3600)::Nothing
    while !eng.shot_done && eng.steps_run < max_steps
        update!(eng, eng.config.fixed_dt)
    end
    return nothing
end

# Harness-equivalent callbacks. `clearing=false` reproduces the bench mode:
# all balls depleted ends the shot immediately (no end-of-turn cascade).
function harness_callbacks(; clearing::Bool = false)::ShotCallbacks
    return ShotCallbacks(
        eng -> !clearing,
        eng -> begin
            e = eng.sim.engine
            e.bonus_score = e.bonus_score + eng.config.bucket_bonus
            return nothing
        end,
        (eng, info) -> begin
            style = get(info, "style", nothing)
            if style !== nothing
                key = String(style)
                eng.style_counts[key] = get(eng.style_counts, key, 0) + 1
            end
            return nothing
        end,
        # Notification only: finalize_step! already owns the shot_done
        # transition before firing on_turn_end.
        eng -> nothing,
    )
end

# Harness feature set (same names as harness/main.lua run_candidate).
function shot_summary(eng::ShotEngine)::NamedTuple
    e = eng.sim.engine
    styles = sort!([string(name, ":", count)
                    for (name, count) in eng.style_counts])
    reason = eng.last_removal_reason
    if reason === nothing
        reason = eng.shot_done ? "all_balls_removed" : "step_limit"
    end
    style_total = 0
    for count in values(eng.style_counts)
        style_total += count
    end
    return (
        steps = eng.steps_run,
        completed = eng.shot_done,
        reason = reason,
        score = get_turn_score(eng),
        peg_score = get_turn_peg_score(eng),
        bonus = e.bonus_score,
        style_points = e.style_score,
        style_total = style_total,
        styles = join(styles, ","),
        pegs_hit = length(e.turn_pegs_hit),
        reds_hit = e.red_pegs_hit_amount,
        multiplier = e.current_multiplier,
        is_fever = e.is_fever,
        balls = eng.initial_balls,
        spawned = (e.next_ball_id - 1) - eng.initial_balls,
    )
end
