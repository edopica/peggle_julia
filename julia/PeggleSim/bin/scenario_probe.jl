#!/usr/bin/env julia
# M4 scenario probe: port fixtures/scenarios.lua to the Julia physics/engine
# seam and compare every expected scenario record under fixtures/expected/.
#
# The 11 scenario fixtures deliberately drive the low-level seam (circle graze
# band, rotated rectangle corner, annular surfaces/cap, reducer tie-break,
# depenetration, equal-mass ball-ball impulse) which natural aim-grid shots
# cannot target precisely.  Each port here reproduces the Lua scenario body
# literally:
#
#   * the physics-only scenarios call PeggleSim.physics_update! directly with
#     a Config copy whose gravity is zero (the Lua probes mutate Config.gravity
#     and the harness restores it);
#   * probe_near_tie_equal_toi reproduces tests/helpers/engine_helpers.lua
#     (`new_engine`/`setup_engine`/`run_shot`): an EngineState with the two
#     inline pegs, no purple promotion, a manually launched ball, and the
#     helper's empty callback table (so all balls depleted starts the
#     end-of-turn clearing cascade, exactly like the Lua helper);
#   * the Lua harness snapshots/restores Config and LevelManager.virtual_*
#     around every scenario.  This driver never mutates shared state: each
#     scenario gets its own Config copy and its own engine/journal.
#
# Expected records are the manifest.  Every expected `result` and `completion`
# field is compared exactly (numbers with ==, no tolerance; nested event
# arrays included).  -0 vs 0 and Int vs Float representations are treated as
# equal numeric JSON values but recorded as representation notes.  Provenance
# is checked first: source.config_sha256 must equal the loaded config's
# source_sha256 identity.
#
# A scenario that cannot be ported faithfully is reported as "not_ported" with
# an explicit reason; it is never silently skipped.  The driver exits 0 only
# when every ported scenario matches (mismatches and ported errors fail).
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/scenario_probe.jl \
#       [--expected-dir DIR] [--config PATH] [--out PATH]
#
# Exit status: 0 iff every ported scenario match; 1 on a parity failure or a
# ported-scenario error; 2 on a malformed corpus / provenance mismatch.

using PeggleSim

const REPO_ROOT = dirname(dirname(dirname(@__DIR__)))
const DEFAULT_SCENARIO_IDS = (
    "probe_graze_gap_0_25",
    "probe_graze_gap_0_50",
    "probe_graze_gap_0_75",
    "probe_rectangle_corner_rotated",
    "probe_annular_outer_surface",
    "probe_annular_inner_surface",
    "probe_annular_cap_crossing",
    "probe_near_tie_equal_toi",
    "probe_depenetration_inner_wall",
    "probe_depenetration_band_exit",
    "probe_ball_ball_impulse",
)

# The scenario runner captures LevelManager.virtual_width/height after the
# preceding shot fixtures.  The catalog's last shot before the scenarios is
# squiggly_annular_drop on squiggly_circle, whose artifact is 1200x1900 (also
# the Config default), so the scenarios see 1200x1900.  Only
# probe_near_tie_equal_toi depends on the height (fall-out threshold and
# bucket); the physics-only probes use the same width for wall checks.
const VIRTUAL_WIDTH = 1200.0
const VIRTUAL_HEIGHT = 1900.0
const GRAZE_PEG_RADIUS = 10.0

# ---------------------------------------------------------------------------
# CLI / paths
# ---------------------------------------------------------------------------

function _usage()
    println("usage: scenario_probe.jl [--expected-dir DIR] [--config PATH] [--out PATH]")
end

function _parse_args(argv)
    opts = Dict{String,String}()
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg == "--help" || arg == "-h"
            _usage()
            exit(0)
        elseif arg in ("--expected-dir", "--config", "--out")
            i += 1
            i <= length(argv) || error("missing value for $(arg)")
            opts[arg] = argv[i]
        else
            error("unknown argument: $(arg)")
        end
        i += 1
    end
    return opts
end

function _ensure_parent(path::AbstractString)
    dir = dirname(abspath(path))
    isempty(dir) || mkpath(dir)
    return nothing
end

function _display_path(path::AbstractString)
    absolute = normpath(abspath(path))
    prefix = REPO_ROOT * "/"
    return startswith(absolute, prefix) ? absolute[length(prefix) + 1:end] : absolute
end

# ---------------------------------------------------------------------------
# Config copy with named overrides (SimConfig is immutable; never mutate the
# shared loaded config).
# ---------------------------------------------------------------------------

function _config_with(base::PeggleSim.SimConfig; overrides...)
    fields = fieldnames(PeggleSim.SimConfig)
    vals = Any[getfield(base, f) for f in fields]
    for (key, value) in pairs(overrides)
        i = findfirst(==(key), fields)
        i === nothing && error("unknown SimConfig field $(key)")
        vals[i] = value
    end
    return PeggleSim.SimConfig(vals...)
end

# ---------------------------------------------------------------------------
# Entity constructors mirroring src/entities/peg.lua and ball.lua.
# ---------------------------------------------------------------------------

function _ball(id::Int, x::Float64, y::Float64, radius::Float64 = 6.0;
               vx::Float64 = 0.0, vy::Float64 = 0.0,
               launched::Bool = true)
    b = PeggleSim.BallState(id, x, y, radius)
    b.vx = vx
    b.vy = vy
    b.launched = launched
    return b
end

function _circle_peg(id::Int, x::Float64, y::Float64, radius::Float64;
                     peg_type::Symbol = :blue)
    return PeggleSim.Peg(id, x, y, x, y, PeggleSim.CircleShape(radius),
                         peg_type, false, 0, 0, nothing)
end

function _rect_peg(id::Int, x::Float64, y::Float64, width::Float64,
                   height::Float64, angle::Float64;
                   peg_type::Symbol = :blue)
    return PeggleSim.Peg(id, x, y, x, y,
                         PeggleSim.RectangleShape(width, height, angle),
                         peg_type, false, 0, 0, nothing)
end

# Peg.new_annular's annular_segments(r_out, span): full = max(16, floor(r_out*0.4)),
# partial sectors scale down to the same chord resolution, clamped to [4, full].
function _annular_segments(r_out::Float64, span::Float64)::Int
    full = max(16, Int(floor(r_out * 0.4)))
    scaled = Int(ceil(abs(span) / (pi * 2) * full))
    return clamp(scaled, 4, full)
end

function _annular_peg(id::Int, x::Float64, y::Float64, r_in::Float64,
                      r_out::Float64, theta_start::Float64,
                      theta_end::Float64; peg_type::Symbol = :blue)
    theta_end_abs = theta_end
    while theta_end_abs <= theta_start
        theta_end_abs += pi * 2
    end
    segments = _annular_segments(r_out, theta_end_abs - theta_start)
    return PeggleSim.Peg(
        id, x, y, x, y,
        PeggleSim.AnnularShape(r_in, r_out, theta_start, theta_end_abs, segments),
        peg_type, false, 0, 0, nothing)
end

# ---------------------------------------------------------------------------
# Raw journal -> the scenario contact_sink shape.
#
# fixtures/scenarios.lua's sink records only these keys (Lua nil fields drop
# out), in this order.  We build the same object so expected/actual event
# arrays compare field-for-field; envelope extras (frame_t, iteration,
# peg_type, line, peg transform) are deliberately not part of the observation.
# ---------------------------------------------------------------------------

const SINK_EVENT_KEYS = (
    "type", "ball_id", "peg_id", "peg_shape", "contact_kind", "did_bounce",
    "toi", "impact_x", "impact_y", "normal_x", "normal_y", "incoming_vx",
    "incoming_vy", "outgoing_vx", "outgoing_vy",
)

function _sink_events(j::PeggleSim.GameplayJournal)
    out = Any[]
    for ev in j.raw
        d = Dict{String,Any}()
        d["type"] = ev.type
        for key in SINK_EVENT_KEYS
            key == "type" && continue
            value = get(ev.fields, key, nothing)
            value === nothing || (d[key] = value)
        end
        push!(out, d)
    end
    return out
end

function _contact_kinds(j::PeggleSim.GameplayJournal)
    return String[String(ev.fields["contact_kind"]) for ev in j.raw]
end

function _final_state(b::PeggleSim.BallState)
    return Dict{String,Any}("x" => b.x, "y" => b.y, "vx" => b.vx, "vy" => b.vy)
end

# One open journal for a whole scenario, exactly like the Lua sink's list.
function _run_physics_scenario(
    balls::Vector{PeggleSim.BallState},
    circle_pegs::Vector{PeggleSim.Peg},
    rect_pegs::Vector{PeggleSim.Peg},
    annular_pegs::Vector{PeggleSim.Peg},
    c::PeggleSim.SimConfig,
    max_steps::Int,
    stop::Function,
)
    j = PeggleSim.GameplayJournal()
    PeggleSim.begin_step!(j, 1, 1)
    steps = 0
    for i in 1:max_steps
        PeggleSim.physics_update!(
            balls, circle_pegs, rect_pegs, annular_pegs, c.fixed_dt,
            nothing, c, VIRTUAL_WIDTH, j)
        steps = i
        stop(balls, j) && break
    end
    return steps, j
end

# ---------------------------------------------------------------------------
# Scenario ports.  Each returns (outcome_named_tuple) with `steps` and
# `result`, mirroring the Lua scenario return value.
# ---------------------------------------------------------------------------

function _graze_probe(base::PeggleSim.SimConfig, gap::Float64)
    c = _config_with(base; gravity = 0.0)
    peg = _circle_peg(1, 600.0, 300.0, GRAZE_PEG_RADIUS)
    ball = _ball(1, 600.0 - (GRAZE_PEG_RADIUS + c.ball_radius + gap), 150.0;
                 vy = 400.0)
    steps, j = _run_physics_scenario(
        [ball], [peg], PeggleSim.Peg[], PeggleSim.Peg[], c, 120,
        (balls, _j) -> balls[1].y > 500.0)
    result = Dict{String,Any}(
        "gap" => gap,
        "event_count" => length(j.raw),
        "contact_kinds" => _contact_kinds(j),
        "final" => _final_state(ball),
    )
    return (steps = steps, result = result)
end

function _rectangle_corner_probe(base::PeggleSim.SimConfig, angle::Float64)
    c = _config_with(base; gravity = 0.0)
    rect = _rect_peg(1, 600.0, 300.0, 40.0, 20.0, angle)
    half_w, half_h = 20.0, 10.0
    delta = 3.0
    # Contact lands at t = 0.9997 of the second frame; the residual window is
    # below the physics loop's threshold (see fixtures/scenarios.lua).
    start_offset = 31.8455
    corner_local = (-half_w, half_h)
    start_local = (-half_w - delta, half_h + start_offset)

    cos_a = PeggleSim.DetMath.det_cos(angle)
    sin_a = PeggleSim.DetMath.det_sin(angle)
    corner_x = 600.0 + cos_a * corner_local[1] - sin_a * corner_local[2]
    corner_y = 300.0 + sin_a * corner_local[1] + cos_a * corner_local[2]
    start_x = 600.0 + cos_a * start_local[1] - sin_a * start_local[2]
    start_y = 300.0 + sin_a * start_local[1] + cos_a * start_local[2]

    speed = 800.0
    vx = speed * sin_a
    vy = -speed * cos_a
    ball = _ball(1, start_x, start_y; vx = vx, vy = vy)
    steps, j = _run_physics_scenario(
        [ball], PeggleSim.Peg[], [rect], PeggleSim.Peg[], c, 90,
        (balls, journal) -> !isempty(journal.raw) || balls[1].y > 460.0)
    result = Dict{String,Any}(
        "angle" => angle,
        "corner_local" => Dict{String,Any}("x" => corner_local[1], "y" => corner_local[2]),
        "corner" => Dict{String,Any}("x" => corner_x, "y" => corner_y),
        "delta" => delta,
        "start_offset" => start_offset,
        "start" => Dict{String,Any}("x" => start_x, "y" => start_y),
        "velocity" => Dict{String,Any}("vx" => vx, "vy" => vy),
        "event_count" => length(j.raw),
        "contact_kinds" => _contact_kinds(j),
        "events" => _sink_events(j),
        "final" => _final_state(ball),
    )
    return (steps = steps, result = result)
end

function _annular_sector()
    return _annular_peg(1, 600.0, 300.0, 40.0, 50.0, -0.5, 0.5)
end

function _annular_outer_probe(base::PeggleSim.SimConfig)
    c = _config_with(base; gravity = 0.0)
    peg = _annular_sector()
    ball = _ball(1, 600.0 + 50.0 + c.ball_radius + 1.0, 300.0; vx = -200.0)
    steps, j = _run_physics_scenario(
        [ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg], c, 90,
        (balls, _j) -> balls[1].x < 590.0)
    result = Dict{String,Any}(
        "surface" => "outer",
        "event_count" => length(j.raw),
        "contact_kinds" => _contact_kinds(j),
        "events" => _sink_events(j),
        "final" => _final_state(ball),
    )
    return (steps = steps, result = result)
end

function _annular_inner_probe(base::PeggleSim.SimConfig)
    c = _config_with(base; gravity = 0.0)
    peg = _annular_sector()
    ball = _ball(1, 600.0 + 40.0 - c.ball_radius - 1.0, 300.0; vx = 200.0)
    steps, j = _run_physics_scenario(
        [ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg], c, 90,
        (balls, _j) -> balls[1].x > 610.0)
    result = Dict{String,Any}(
        "surface" => "inner",
        "event_count" => length(j.raw),
        "contact_kinds" => _contact_kinds(j),
        "events" => _sink_events(j),
        "final" => _final_state(ball),
    )
    return (steps = steps, result = result)
end

function _annular_cap_probe(base::PeggleSim.SimConfig)
    c = _config_with(base; gravity = 0.0)
    peg = _annular_sector()
    cap_angle = -0.5
    radius = 45.0
    angular_offset = 0.2
    theta = cap_angle - angular_offset
    start_x = 600.0 + radius * PeggleSim.DetMath.det_cos(theta)
    start_y = 300.0 + radius * PeggleSim.DetMath.det_sin(theta)
    normal = (
        x = PeggleSim.DetMath.det_sin(cap_angle),
        y = -PeggleSim.DetMath.det_cos(cap_angle),
    )
    speed = 250.0
    vx = -normal.x * speed
    vy = -normal.y * speed
    ball = _ball(1, start_x, start_y; vx = vx, vy = vy)
    steps, j = _run_physics_scenario(
        [ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg], c, 90,
        (balls, _j) -> balls[1].x < 560.0 || balls[1].y < 200.0)

    isempty(j.raw) && error("annular cap probe captured no contact event")
    first = _sink_events(j)[1]
    qx = first["impact_x"] - first["normal_x"] * c.ball_radius
    qy = first["impact_y"] - first["normal_y"] * c.ball_radius
    cap_dx, cap_dy = qx - 600.0, qy - 300.0
    cap_radius = PeggleSim.DetMath.det_sqrt(cap_dx * cap_dx + cap_dy * cap_dy)

    result = Dict{String,Any}(
        "surface" => "cap",
        "cap_angle" => cap_angle,
        "angular_offset" => angular_offset,
        "start" => Dict{String,Any}("x" => start_x, "y" => start_y),
        "velocity" => Dict{String,Any}("vx" => vx, "vy" => vy),
        "cap_normal" => Dict{String,Any}("x" => normal.x, "y" => normal.y),
        "cap_radius" => cap_radius,
        "event_count" => length(j.raw),
        "contact_kinds" => _contact_kinds(j),
        "events" => _sink_events(j),
        "final" => _final_state(ball),
    )
    return (steps = steps, result = result)
end

# Engine-level near-tie probe: H.new_engine + H.setup_engine + H.run_shot.
# The Lua helper installs inline pegs (original_index 1, 2), leaves both blue
# (setup_engine does not call assign_next_purple_pegs), and launches one ball
# at (600, 150) with vy = 400 under the default gravity (1000).
function _near_tie_probe(base::PeggleSim.SimConfig)
    pegs = PeggleSim.Peg[
        _circle_peg(1, 585.0, 300.0, 10.0),
        _circle_peg(2, 615.0, 300.0, 10.0),
    ]
    for (i, peg) in enumerate(pegs)
        peg.id == i || error("near-tie peg id mismatch")
    end

    rng = PeggleSim.LoveRandom(1)
    type_counts = (blue = 2, green = 0, purple = 0, red = 0)
    colors = PeggleSim.init_colors!(pegs, type_counts, 1, rng)
    peg_by_id = Dict(peg.id => peg for peg in pegs)

    engine = PeggleSim.EngineState(
        0, 0, "",
        pegs, peg_by_id,
        PeggleSim.BallState[], Dict{Int,PeggleSim.BallState}(),
        IdDict{PeggleSim.BallState,Int}(),
        PeggleSim.BucketState(VIRTUAL_WIDTH, VIRTUAL_HEIGHT, base),
        PeggleSim.FeverBucketsState(base, VIRTUAL_WIDTH, VIRTUAL_HEIGHT),
        nothing, false, 0.0, 0.0, 0.0,
        0, 0, 1, false, 0, Int[], 1, Int[])
    PeggleSim.update_multiplier!(engine)

    sim = PeggleSim.SimState(
        engine, rng, colors, PeggleSim.Trackers(),
        PeggleSim.MatchState(:solo; starting_balls = base.starting_balls))
    eng = PeggleSim._fresh_shot_engine(
        sim, base, VIRTUAL_WIDTH, VIRTUAL_HEIGHT, PeggleSim.ShotCallbacks())

    ball = PeggleSim.BallState(0, 600.0, 150.0, base.ball_radius)
    ball.launched = true
    ball.vx = 0.0
    ball.vy = 400.0
    PeggleSim.register_ball!(engine, ball)
    engine.balls = [ball]
    eng.initial_balls = 1
    engine.shot_id += 1
    eng.shot_initial_step = engine.step_id + 1
    PeggleSim.reset_shot!(sim.trackers)
    PeggleSim.stage!(eng.journal, "ball_launched", Dict{String,Any}(
        "ball_id" => ball.id,
        "x" => ball.x,
        "y" => ball.y,
        "vx" => ball.vx,
        "vy" => ball.vy,
    ))

    start_step = engine.step_id
    steps = 0
    for _ in 1:600
        eng.shot_done && break
        engine.step_id += 1
        PeggleSim.save_previous_state(eng)
        PeggleSim.step_simulation!(eng, base.fixed_dt)
        steps = engine.step_id - start_step
        eng.shot_end_reason == "__handled" && break
    end

    result = Dict{String,Any}(
        "scored_order" => copy(engine.turn_pegs_hit),
        "pegs_hit" => length(engine.turn_pegs_hit),
        "score" => PeggleSim.get_turn_score(eng),
    )
    return (steps = steps, result = result)
end

function _depenetration_inner_wall_probe(base::PeggleSim.SimConfig)
    c = _config_with(base; gravity = 0.0)
    cx, cy = 600.0, 950.0
    r_in, r_out = 8724.9, 8744.9
    span = 0.0014
    peg = _annular_peg(1, cx, cy, r_in, r_out, -span / 2, span / 2)
    ball = _ball(1, cx + r_in - c.ball_radius + 0.03, cy)
    radial() = PeggleSim.DetMath.det_sqrt((ball.x - cx)^2 + (ball.y - cy)^2)
    before = radial()
    steps, j = _run_physics_scenario(
        [ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg], c, 1,
        (balls, _j) -> true)
    after = radial()
    result = Dict{String,Any}(
        "before" => before,
        "after" => after,
        "moved" => before - after,
        "inside_hole" => after <= r_in,
        "contact_kinds" => _contact_kinds(j),
        "final" => _final_state(ball),
    )
    return (steps = steps, result = result)
end

function _depenetration_band_exit_probe(base::PeggleSim.SimConfig)
    c = _config_with(base; gravity = 0.0)
    cx, cy = 600.0, 950.0
    r_in, r_out = 100.0, 120.0
    peg = _annular_peg(1, cx, cy, r_in, r_out, -0.05, 0.05)
    radial(b) = PeggleSim.DetMath.det_sqrt((b.x - cx)^2 + (b.y - cy)^2)

    inner_ball = _ball(1, cx + 105.0, cy)
    inner_steps, inner_j = _run_physics_scenario(
        [inner_ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg], c, 1,
        (balls, _j) -> true)
    outer_ball = _ball(2, cx + 115.0, cy)
    outer_steps, outer_j = _run_physics_scenario(
        [outer_ball], PeggleSim.Peg[], PeggleSim.Peg[], [peg], c, 1,
        (balls, _j) -> true)
    inner_steps == 1 || error("inner band-exit probe ran $(inner_steps) steps")
    outer_steps == 1 || error("outer band-exit probe ran $(outer_steps) steps")

    result = Dict{String,Any}(
        "inner_ball_radius" => radial(inner_ball),
        "inner_exits_inward" => radial(inner_ball) < r_in,
        "inner_contact_kinds" => _contact_kinds(inner_j),
        "outer_ball_radius" => radial(outer_ball),
        "outer_exits_outward" => radial(outer_ball) > r_out,
        "outer_contact_kinds" => _contact_kinds(outer_j),
    )
    return (steps = inner_steps, result = result)
end

function _ball_ball_impulse_probe(base::PeggleSim.SimConfig)
    c = _config_with(base; gravity = 0.0)
    a = _ball(1, 580.0, 300.0; vx = 200.0)
    b = _ball(2, 620.0, 300.0; vx = -200.0)
    steps, j = _run_physics_scenario(
        [a, b], PeggleSim.Peg[], PeggleSim.Peg[], PeggleSim.Peg[], c, 60,
        (balls, _j) -> balls[1].vx < 0.0 && balls[2].vx > 0.0)
    result = Dict{String,Any}(
        "event_count" => length(j.raw),
        "contact_kinds" => _contact_kinds(j),
        "a" => _final_state(a),
        "b" => _final_state(b),
    )
    return (steps = steps, result = result)
end

# ---------------------------------------------------------------------------
# Scenario registry
# ---------------------------------------------------------------------------

struct ScenarioPort
    id::String
    category::String
    mechanism::String
    driver::String
    run::Function
end

function _ports()
    return ScenarioPort[
        ScenarioPort("probe_graze_gap_0_25", "shape_boundary",
            "circle graze band at 0.25 px past tangent", "physics_update!",
            base -> _graze_probe(base, 0.25)),
        ScenarioPort("probe_graze_gap_0_50", "shape_boundary",
            "circle graze band exactly at graze_tolerance (0.5 px)", "physics_update!",
            base -> _graze_probe(base, 0.5)),
        ScenarioPort("probe_graze_gap_0_75", "shape_boundary",
            "circle graze band at 0.75 px past tangent (miss)", "physics_update!",
            base -> _graze_probe(base, 0.75)),
        ScenarioPort("probe_rectangle_corner_rotated", "shape_boundary",
            "swept rotated-rectangle corner at TOI 0.9997", "physics_update!",
            base -> _rectangle_corner_probe(base, 0.6)),
        ScenarioPort("probe_annular_outer_surface", "shape_boundary",
            "radial sweep against an annular outer surface", "physics_update!",
            base -> _annular_outer_probe(base)),
        ScenarioPort("probe_annular_inner_surface", "shape_boundary",
            "radial sweep against an annular inner surface", "physics_update!",
            base -> _annular_inner_probe(base)),
        ScenarioPort("probe_annular_cap_crossing", "shape_boundary",
            "perpendicular sweep across an annular start cap", "physics_update!",
            base -> _annular_cap_probe(base)),
        ScenarioPort("probe_near_tie_equal_toi", "near_tie",
            "reducer candidate-order tie-break at equal TOI", "shot_engine",
            base -> _near_tie_probe(base)),
        ScenarioPort("probe_depenetration_inner_wall", "overlap_correction",
            "inner-wall depenetration stays inside the hole", "physics_update!",
            base -> _depenetration_inner_wall_probe(base)),
        ScenarioPort("probe_depenetration_band_exit", "overlap_correction",
            "band depenetration exits through the nearer surface", "physics_update!",
            base -> _depenetration_band_exit_probe(base)),
        ScenarioPort("probe_ball_ball_impulse", "multiball",
            "equal-mass head-on ball-ball impulse", "physics_update!",
            base -> _ball_ball_impulse_probe(base)),
    ]
end

# ---------------------------------------------------------------------------
# Exact comparison (no tolerance).  Dict keys are visited sorted; arrays in
# index order.  Numeric equality uses ==; representation-only differences
# (-0 vs 0, Int vs Float) are recorded as notes, not failures.
# ---------------------------------------------------------------------------

mutable struct ComparisonState
    differences::Dict{String,Any}
    notes::Dict{String,Any}
    count::Int
end

ComparisonState() = ComparisonState(Dict{String,Any}(), Dict{String,Any}(), 0)

_is_number(x) = x isa Real && !(x isa Bool)

function _note_representation!(st::ComparisonState, path::String, expected, actual)
    if _is_number(expected) && _is_number(actual)
        same = isequal(expected, actual)
        typeof_same = typeof(expected) === typeof(actual)
        if !same || !typeof_same
            note = Dict{String,Any}(
                "expected_type" => string(typeof(expected)),
                "actual_type" => string(typeof(actual)),
            )
            if !same
                note["negative_zero"] = true
            end
            st.notes[path] = note
        end
    end
    return nothing
end

function _record_difference!(st::ComparisonState, path::String, expected, actual;
                             actual_missing::Bool = false)
    st.count += 1
    d = Dict{String,Any}("expected" => expected, "actual" => actual)
    actual_missing && (d["actual_missing"] = true)
    st.differences[path] = d
    return nothing
end

function _compare_values!(st::ComparisonState, path::String, expected, actual)
    if expected isa AbstractDict && actual isa AbstractDict
        exp_keys = sort!(String[String(k) for k in keys(expected)])
        act_keys = sort!(String[String(k) for k in keys(actual)])
        for key in exp_keys
            child = isempty(path) ? key : path * "." * key
            if !haskey(actual, key)
                _record_difference!(st, child, expected[key], nothing;
                                    actual_missing = true)
            else
                _compare_values!(st, child, expected[key], actual[key])
            end
        end
        for key in act_keys
            key in exp_keys && continue
            child = isempty(path) ? key : path * "." * key
            _record_difference!(st, child, nothing, actual[key])
        end
        return nothing
    elseif expected isa AbstractVector && actual isa AbstractVector
        if length(expected) != length(actual)
            _record_difference!(st, path * ".length", length(expected),
                                length(actual))
        end
        for i in 1:min(length(expected), length(actual))
            _compare_values!(st, path * "[$(i)]", expected[i], actual[i])
        end
        return nothing
    elseif expected isa Bool || actual isa Bool
        st.count += 1
        if !(expected isa Bool && actual isa Bool && expected == actual)
            st.differences[path] = Dict{String,Any}(
                "expected" => expected, "actual" => actual)
        end
        return nothing
    elseif _is_number(expected) && _is_number(actual)
        st.count += 1
        if expected != actual
            st.differences[path] = Dict{String,Any}(
                "expected" => expected, "actual" => actual)
        else
            _note_representation!(st, path, expected, actual)
        end
        return nothing
    else
        st.count += 1
        if !isequal(expected, actual)
            st.differences[path] = Dict{String,Any}(
                "expected" => expected, "actual" => actual)
        end
        return nothing
    end
end

# Count leaf fields in the expected observation (diagnostic; the comparison
# itself also counts every visited value).
function _leaf_count(value)
    if value isa AbstractDict
        return sum(_leaf_count(v) for v in values(value); init = 0)
    elseif value isa AbstractVector
        return sum(_leaf_count(v) for v in value; init = 0)
    else
        return 1
    end
end

# ---------------------------------------------------------------------------
# Expected-record loading and report
# ---------------------------------------------------------------------------

function _load_scenario_records(dir::AbstractString)
    records = Dict{String,Any}()
    for name in readdir(dir)
        endswith(name, ".json") || continue
        path = joinpath(dir, name)
        doc = as_object(load_json(path), "fixture record")
        get(doc, "kind", nothing) == "scenario" || continue
        id = as_string(doc["id"], "id")
        records[id] = doc
    end
    return records
end

function _check_provenance(id::AbstractString, doc, config::PeggleSim.SimConfig)
    source = as_object(doc["source"], "source")
    expected_sha = as_string(source["config_sha256"], "source.config_sha256")
    actual_sha = PeggleSim.config_source_sha256(config)
    expected_sha == actual_sha || error(
        "scenario $(id): source.config_sha256=$(expected_sha) does not match " *
        "loaded config source_sha256=$(actual_sha)")
    return Dict{String,Any}(
        "expected_config_sha256" => expected_sha,
        "actual_config_sha256" => actual_sha,
        "match" => true,
    )
end

function _expected_completion(doc)
    completion = as_object(doc["completion"], "completion")
    return Dict{String,Any}(
        "rule" => as_string(completion["rule"], "completion.rule"),
        "completed" => as_bool(completion["completed"], "completion.completed"),
        "reason" => as_string(completion["reason"], "completion.reason"),
        "steps" => as_int(completion["steps"], "completion.steps"),
        "max_steps" => as_int(completion["max_steps"], "completion.max_steps"),
    )
end

function _actual_completion(outcome)
    return Dict{String,Any}(
        "rule" => "scenario",
        "completed" => get(outcome, :completed, true),
        "reason" => get(outcome, :reason, "probe_complete"),
        "steps" => outcome.steps,
        "max_steps" => get(outcome, :max_steps, outcome.steps),
    )
end

function _scenario_report(port, doc, config)
    id = port.id
    category = as_string(doc["category"], "category")
    expected_result = as_object(doc["result"], "result")
    expected_completion = _expected_completion(doc)
    provenance = _check_provenance(id, doc, config)

    report = Dict{String,Any}(
        "id" => id,
        "category" => category,
        "mechanism" => port.mechanism,
        "driver" => port.driver,
        "status" => "not_ported",
        "provenance" => provenance,
        "expected" => expected_result,
        "actual" => nothing,
        "completion" => Dict{String,Any}(
            "expected" => expected_completion,
            "actual" => nothing,
        ),
        "fields_compared" => 0,
        "result_fields_compared" => 0,
        "completion_fields_compared" => 0,
        "first_difference" => nothing,
        "differences" => Dict{String,Any}(),
        "representation_notes" => Dict{String,Any}(),
    )

    local outcome
    try
        outcome = port.run(config)
    catch err
        report["status"] = "mismatch"
        report["error"] = sprint(showerror, err)
        return report
    end

    actual_result = outcome.result
    actual_completion = _actual_completion(outcome)
    result_state = ComparisonState()
    completion_state = ComparisonState()
    _compare_values!(result_state, "result", expected_result, actual_result)
    _compare_values!(completion_state, "completion", expected_completion,
                     actual_completion)

    differences = merge(Dict{String,Any}(), completion_state.differences,
                        result_state.differences)
    notes = merge(Dict{String,Any}(), completion_state.notes, result_state.notes)
    first_difference = nothing
    if !isempty(differences)
        # Prefer a completion difference only if it sorts before every result
        # difference under the same path ordering; otherwise report the first
        # result difference.  A stable path sort is easier to read.
        for key in sort!(collect(keys(differences)))
            d = differences[key]
            fd = Dict{String,Any}("field" => key, "expected" => d["expected"],
                                  "actual" => d["actual"])
            get(d, "actual_missing", false) && (fd["actual_missing"] = true)
            first_difference = fd
            break
        end
    end

    report["actual"] = actual_result
    report["completion"]["actual"] = actual_completion
    report["fields_compared"] = result_state.count + completion_state.count
    report["result_fields_compared"] = result_state.count
    report["completion_fields_compared"] = completion_state.count
    report["expected_result_leaf_fields"] = _leaf_count(expected_result)
    report["first_difference"] = first_difference
    report["differences"] = differences
    report["representation_notes"] = notes
    report["status"] = isempty(differences) ? "match" : "mismatch"
    return report
end

function _not_ported_report(id, doc, config, reason)
    category = as_string(doc["category"], "category")
    provenance = _check_provenance(id, doc, config)
    return Dict{String,Any}(
        "id" => id,
        "category" => category,
        "mechanism" => reason,
        "driver" => nothing,
        "status" => "not_ported",
        "provenance" => provenance,
        "expected" => as_object(doc["result"], "result"),
        "actual" => nothing,
        "completion" => Dict{String,Any}(
            "expected" => _expected_completion(doc),
            "actual" => nothing,
        ),
        "fields_compared" => 0,
        "result_fields_compared" => 0,
        "completion_fields_compared" => 0,
        "first_difference" => nothing,
        "differences" => Dict{String,Any}(),
        "representation_notes" => Dict{String,Any}(),
        "gap" => Dict{String,Any}(
            "mechanism" => reason,
            "why" => "no faithful Julia port is registered for this scenario",
            "recommendation" => "port in a follow-up session",
        ),
    )
end

function run_probe(opts)
    expected_dir = get(opts, "--expected-dir",
                       joinpath(REPO_ROOT, "fixtures", "expected"))
    config_path = get(opts, "--config",
                      joinpath(REPO_ROOT, "interchange", "config.v1.json"))
    out_path = get(opts, "--out",
                   joinpath(REPO_ROOT, "results", "m4", "scenario-parity.json"))

    config = PeggleSim.load_config(config_path)
    records = _load_scenario_records(expected_dir)
    isempty(records) && error("no scenario records found in $(expected_dir)")

    # Expected corpus must be exactly the pinned 11 scenario records; an
    # unexpected scenario is not silently skipped.
    expected_ids = sort!(collect(keys(records)))
    pinned_ids = sort!(collect(DEFAULT_SCENARIO_IDS))
    extras = setdiff(expected_ids, pinned_ids)
    isempty(extras) || error(
        "unexpected scenario record(s) in $(expected_dir): " * join(extras, ", "))

    # Validate every record (format, schema, scenario action, provenance)
    # before running any scenario, so a bad corpus never produces a partial
    # report that looks like a parity result.
    for id in expected_ids
        doc = records[id]
        as_string(doc["format"], "$(id).format") == "peggle.fixture" ||
            error("$(id): format must be peggle.fixture")
        as_int(doc["schema_version"], "$(id).schema_version") == 1 ||
            error("$(id): unsupported schema_version")
        action = as_object(doc["action"], "$(id).action")
        as_string(action["kind"], "$(id).action.kind") == "scenario" ||
            error("$(id): action.kind must be scenario")
        as_string(action["name"], "$(id).action.name") == id ||
            error("$(id): action.name does not match the record id")
        _check_provenance(id, doc, config)
    end

    ports = Dict(port.id => port for port in _ports())
    reports = Dict{String,Any}[]
    for id in DEFAULT_SCENARIO_IDS
        haskey(records, id) || error(
            "missing expected scenario record $(id) in $(expected_dir)")
        doc = records[id]
        if haskey(ports, id)
            push!(reports, _scenario_report(ports[id], doc, config))
        else
            push!(reports, _not_ported_report(id, doc, config,
                "no faithful Julia port registered"))
        end
    end

    matched = count(r -> r["status"] == "match", reports)
    failed = count(r -> r["status"] == "mismatch", reports)
    not_ported = count(r -> r["status"] == "not_ported", reports)
    ported = length(reports) - not_ported
    all_ported_match = failed == 0 && ported == matched

    report = Dict{String,Any}(
        "format" => "peggle.m4_scenario_parity",
        "schema_version" => 1,
        "math_backend" => string(PeggleSim.DetMath.MATH_BACKEND[]),
        "config" => _display_path(config_path),
        "config_sha256" => PeggleSim.config_source_sha256(config),
        "expected_dir" => _display_path(expected_dir),
        "comparison" => Dict{String,Any}(
            "numeric_equality" => "exact == (no tolerance)",
            "bool_equality" => "exact",
            "number_representation" => "-0/0 and Int/Float are equal JSON numbers; recorded as representation_notes",
            "fields" => "every field of the expected result and completion objects, including event arrays",
        ),
        "scenarios" => reports,
        "summary" => Dict{String,Any}(
            "scenarios_total" => length(reports),
            "ported" => ported,
            "matched" => matched,
            "failed" => failed,
            "not_ported" => not_ported,
            "all_ported_match" => all_ported_match,
            "fields_compared_total" => sum(r["fields_compared"] for r in reports;
                                           init = 0),
            "result_fields_compared_total" =>
                sum(r["result_fields_compared"] for r in reports; init = 0),
            "first_mismatch" =>
                findfirst(r -> r["first_difference"] !== nothing, reports),
        ),
    )

    _ensure_parent(out_path)
    open(out_path, "w") do io
        write(io, PeggleSim.canonical_json(report))
        write(io, "\n")
    end

    println("scenario_probe: ", matched, "/", ported, " ported scenarios match",
            not_ported > 0 ? "; $(not_ported) not ported" : "")
    for r in reports
        status = r["status"] == "match" ? "match" :
                 r["status"] == "mismatch" ? "MISMATCH" : "not_ported"
        println("scenario_probe: ", rpad(r["id"], 36), " ", status,
                r["first_difference"] === nothing ? "" :
                "  first=" * string(r["first_difference"]["field"]))
        if r["first_difference"] !== nothing
            fd = r["first_difference"]
            println(stderr, "scenario_probe: first difference in ", r["id"],
                    ": ", fd["field"], " expected=", repr(fd["expected"]),
                    " actual=", repr(fd["actual"]))
        end
        haskey(r, "error") && println(stderr,
            "scenario_probe: ported scenario error in ", r["id"], ": ", r["error"])
    end
    println("scenario_probe: report ", out_path)
    return all_ported_match
end

function main(argv)
    opts = try
        _parse_args(argv)
    catch err
        println(stderr, "scenario_probe: ", sprint(showerror, err))
        exit(2)
    end
    ok = try
        run_probe(opts)
    catch err
        println(stderr, "scenario_probe: corpus/provenance error: ",
                sprint(showerror, err))
        exit(2)
    end
    ok || exit(1)
    return nothing
end

main(ARGS)
