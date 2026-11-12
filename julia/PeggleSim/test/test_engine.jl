# Focused tests for src/engine.jl (workstream F), porting
# ../peggle_evolved/src/engine/core.lua (dev tree @ da75225).
#
# Every scene uses the real mustache artifact + dev config through the M2
# checkpoint contract (`build_checkpoint` -> `shot_engine`), so the assertions
# pin the full engine pipeline: launch staging, physics integration, scoring,
# green power spawns, the clearing cascade, and multi-worker determinism.

using Test
using PeggleSim

const ENGINE_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const ENGINE_MUSTACHE_DIR = joinpath(ENGINE_REPO_ROOT, "fixtures", "mustache")
const ENGINE_MUSTACHE_LEVEL =
    joinpath(ENGINE_MUSTACHE_DIR, "artifact", "mustache.v1.json")
const ENGINE_MUSTACHE_CONFIG =
    joinpath(ENGINE_MUSTACHE_DIR, "config.dev.v1.json")

const ENGINE_CENTER_AIM = 900
const ENGINE_LEFT_AIM = 0
const ENGINE_CENTER_STEPS = 922
const ENGINE_CENTER_CLEARING_STEPS = 975
const ENGINE_LEFT_STEPS = 1507

function _engine_level()
    return PeggleSim.load_level(ENGINE_MUSTACHE_LEVEL)
end

function _engine_config()
    return PeggleSim.load_config(ENGINE_MUSTACHE_CONFIG)
end

function _engine_checkpoint(level, config)
    provenance = (
        reference_revision = "da752257f613abbd209f1aa1acdd37a5f9be05f5",
        reference_tree = "61278edc5467bf8399c24f4af0fcf36d75cac6a2",
        config_sha256 = config.source_sha256,
        level_sha256 = PeggleSim.level_sha256(ENGINE_MUSTACHE_LEVEL),
    )
    return PeggleSim.build_checkpoint(
        level, config; balls = 1, mode = :solo, provenance = provenance)
end

function _engine_new(; clearing::Bool = false)
    level = _engine_level()
    config = _engine_config()
    ckpt = _engine_checkpoint(level, config)
    return PeggleSim.shot_engine(
        ckpt; config = config,
        callbacks = PeggleSim.harness_callbacks(; clearing = clearing),
        level = level)
end

function _engine_run(aim_index::Int; clearing::Bool = false)
    eng = _engine_new(; clearing = clearing)
    PeggleSim.launch!(eng, aim_index)
    PeggleSim.run_shot!(eng)
    return eng
end

@testset "engine" begin
    @testset "launch stages ball_launched and the shot reaches fell_out" begin
        eng = _engine_new()

        # launch! mirrors Engine:launchBalls: velocities are set immediately
        # and the raw event is staged for the next fixed step.
        PeggleSim.launch!(eng, ENGINE_CENTER_AIM)
        @test length(eng.journal.staged) == 1
        event_type, fields = eng.journal.staged[1]
        @test event_type == "ball_launched"
        @test fields["ball_id"] == 1
        @test fields["x"] == 440.0
        @test fields["y"] == 50.0
        # Center aim snaps to pi/2: vx = cos(pi/2) * 800, vy = 800.
        @test PeggleSim.float_bits_hex(fields["vx"]) ==
              PeggleSim.float_bits_hex(4.8985871965894129e-14)
        @test PeggleSim.float_bits_hex(fields["vy"]) ==
              PeggleSim.float_bits_hex(800.0)
        @test eng.sim.engine.shot_id == 1
        @test eng.shot_initial_step == 1

        # The first fixed step flushes the staged event as raw sequence 1.
        PeggleSim.update!(eng, eng.config.fixed_dt)
        @test length(eng.journal.raw) >= 1
        @test eng.journal.raw[1].type == "ball_launched"
        @test eng.journal.raw[1].sequence == 1
        @test eng.journal.raw[1].step == 1

        PeggleSim.run_shot!(eng)
        summary = PeggleSim.shot_summary(eng)
        @test summary.completed
        @test summary.reason == "fell_out"
        @test summary.steps == ENGINE_CENTER_STEPS
        @test summary.score == 9000.0
        @test summary.peg_score == 4000.0
        @test summary.bonus == 0.0
        @test summary.style_points == 5000.0
        @test summary.styles == "slide:1"
        @test summary.pegs_hit == 16
        @test summary.reds_hit == 1
        @test summary.multiplier == 1
        @test !summary.is_fever
        @test summary.balls == 1
        @test summary.spawned == 0
        @test isempty(eng.sim.engine.balls)
        @test eng.last_removal_reason == "fell_out"
    end

    @testset "green power spawns two balls" begin
        eng = _engine_run(ENGINE_LEFT_AIM)
        summary = PeggleSim.shot_summary(eng)
        @test summary.completed
        @test summary.reason == "fell_out"
        @test summary.steps == ENGINE_LEFT_STEPS
        @test summary.pegs_hit == 30
        @test summary.reds_hit == 4
        @test summary.score == 39500.0
        @test summary.peg_score == 34500.0
        @test summary.spawned == 2
        # The green peg staged two spawn specs; ids 2 and 3 were consumed.
        @test eng.sim.engine.next_ball_id == 4
        @test sort(eng.sim.engine.used_ball_ids) == [1, 2, 3]
    end

    @testset "end-of-turn clearing cascade" begin
        eng = _engine_run(ENGINE_CENTER_AIM; clearing = true)
        summary = PeggleSim.shot_summary(eng)
        @test summary.completed
        @test summary.reason == "fell_out"
        @test eng.sim.engine.clear_queue === nothing
        # The cascade runs after the bench completion point.
        @test summary.steps == ENGINE_CENTER_CLEARING_STEPS
        # Every hit peg was swept off the board; un-hit pegs remain.
        @test all(!p.hit for p in eng.sim.engine.pegs)
        @test !isempty(eng.sim.engine.pegs)
        @test length(eng.sim.engine.pegs) ==
              length(_engine_level().pegs) - summary.pegs_hit
    end

    @testset "default callbacks: the engine owns shot completion" begin
        # Regression: shot completion must not depend on on_turn_end being
        # installed. With the default ShotCallbacks the shot still runs the
        # end-of-turn clearing cascade and then stops, emitting exactly one
        # shot_completed event. Before the fix the engine re-entered the
        # clearing cascade on an empty board and kept emitting
        # shot_completed until max_steps.
        level = _engine_level()
        config = _engine_config()
        ckpt = _engine_checkpoint(level, config)
        eng = PeggleSim.shot_engine(ckpt; config = config, level = level)
        PeggleSim.launch!(eng, ENGINE_CENTER_AIM)
        PeggleSim.run_shot!(eng)

        summary = PeggleSim.shot_summary(eng)
        @test summary.completed
        @test eng.shot_done
        @test summary.reason == "fell_out"
        @test summary.steps == ENGINE_CENTER_CLEARING_STEPS
        @test eng.sim.engine.clear_queue === nothing
        shot_completed =
            [ev for ev in eng.journal.derived if ev.type == "shot_completed"]
        @test length(shot_completed) == 1
    end

    @testset "parallel workers from one checkpoint are identical" begin
        level = _engine_level()
        config = _engine_config()
        ckpt = _engine_checkpoint(level, config)

        function run_worker()
            eng = PeggleSim.shot_engine(
                ckpt; config = config,
                callbacks = PeggleSim.harness_callbacks(), level = level)
            PeggleSim.launch!(eng, ENGINE_CENTER_AIM)
            PeggleSim.run_shot!(eng)
            return PeggleSim.shot_summary(eng)
        end

        task_a = Threads.@spawn run_worker()
        task_b = Threads.@spawn run_worker()
        summary_a = fetch(task_a)
        summary_b = fetch(task_b)
        @test summary_a == summary_b
        @test summary_a.steps == ENGINE_CENTER_STEPS
        @test summary_a.reason == "fell_out"
    end
end

# ---------------------------------------------------------------------------
# 10ee3a0 rules (RULES_RAMP_BUCKET): one-ball multiball and the bucket catch
# hold. Mirrors tests/test_engine_integration.lua @ 10ee3a0. The b2 imported
# level plus the synced campaign config (exported from 10ee3a0) are used; the
# full-shot step counts below were captured from the Lua dev tree at 10ee3a0
# with the harness (scripts/capture_imported_levels.sh flow into a scratch
# directory) and the Julia traces were byte-identical with snapshots.
# ---------------------------------------------------------------------------

const RAMP_ENGINE_CONFIG = joinpath(ENGINE_REPO_ROOT, "campaigns", "ribbon", "config.v1.json")
const RAMP_ENGINE_LEVEL = joinpath(ENGINE_REPO_ROOT, "fixtures", "imported_levels",
                                   "artifact", "b2.v1.json")

function _ramp_engine(; callbacks = PeggleSim.harness_callbacks(), trace_path = nothing)
    level = PeggleSim.load_level(RAMP_ENGINE_LEVEL)
    config = PeggleSim.load_config(RAMP_ENGINE_CONFIG)
    prov = (reference_revision = "10ee3a06eb6af3f79e502a2bd34d3e5697a6a2cc",
            reference_tree = "t", config_sha256 = config.source_sha256,
            level_sha256 = level.level_sha256)
    ckpt = PeggleSim.build_checkpoint(level, config; balls = 1, mode = :solo, provenance = prov)
    eng = PeggleSim.shot_engine(ckpt; config, callbacks, level)
    if trace_path !== nothing
        eng.trace = PeggleSim.trace_open(trace_path; include_snapshot = true)
    end
    return eng
end

function _trace_raw_counts(path)
    counts = Dict{String,Int}()
    for line in eachline(path)
        rec = PeggleSim.JSON.parse(line)
        get(rec, "kind", nothing) == "step" || continue
        for ev in rec["raw_events"]
            counts[ev["type"]] = get(counts, ev["type"], 0) + 1
        end
    end
    return counts
end

@testset "engine: 10ee3a0 rules" begin
    @testset "green peg hit spawns exactly one extra ball" begin
        path = joinpath(mktempdir(), "spawn.jsonl")
        eng = _ramp_engine(; trace_path = path)
        @test eng.config.rules === PeggleSim.RULES_RAMP_BUCKET
        PeggleSim.launch!(eng, 450)
        max_live = 0
        while !eng.shot_done && eng.steps_run < 3600
            PeggleSim.update!(eng, eng.config.fixed_dt)
            max_live = max(max_live, length(eng.sim.engine.balls))
        end
        PeggleSim.trace_close!(eng.trace)
        summary = PeggleSim.shot_summary(eng)
        # Lua 10ee3a0 harness capture (b2_right): 348 steps, fell_out, 15000.
        @test summary.steps == 348
        @test summary.reason == "fell_out"
        @test summary.score == 15000.0
        @test summary.spawned == 1
        @test max_live == 2
        @test _trace_raw_counts(path)["ball_spawned"] == 1
        green_scored = 0
        for line in eachline(path)
            rec = PeggleSim.JSON.parse(line)
            get(rec, "kind", nothing) == "step" || continue
            for ev in rec["derived_events"]
                ev["type"] == "peg_scored" && ev["peg_type"] == "green" && (green_scored += 1)
            end
        end
        @test green_scored == 1
    end

    @testset "caught ball falls out of view, then shot end is held" begin
        caught_step = Ref{Union{Nothing,Int}}(nothing)
        turn_end_step = Ref{Union{Nothing,Int}}(nothing)
        base = PeggleSim.harness_callbacks()
        callbacks = PeggleSim.ShotCallbacks(
            base.on_all_balls_depleted,
            eng -> (caught_step[] = eng.sim.engine.step_id; base.on_bucket_catch(eng)),
            base.on_style_shot,
            eng -> (turn_end_step[] === nothing && (turn_end_step[] = eng.sim.engine.step_id); nothing),
        )
        path = joinpath(mktempdir(), "hold.jsonl")
        eng = _ramp_engine(; callbacks, trace_path = path)
        e = eng.sim.engine
        PeggleSim.launch!(eng, 900)
        # Drop the ball straight into the bucket (Lua test: 40 px above the
        # rim top at vy = 400).
        b = e.balls[1]
        b.x = b.prev_x = e.bucket.x
        b.y = b.prev_y = e.bucket.top - 40
        b.vx = 0.0
        b.vy = 400.0
        removed_step = nothing
        live_after_catch = false
        hold_seen = nothing
        while !eng.shot_done && eng.steps_run < 600
            PeggleSim.update!(eng, eng.config.fixed_dt)
            if caught_step[] !== nothing && removed_step === nothing
                if length(e.balls) == 1 && e.step_id > caught_step[]
                    live_after_catch = true
                    @test e.balls[1].bucket_caught
                end
                if isempty(e.balls)
                    removed_step = e.step_id
                    hold_seen = eng.catch_hold_until_step
                end
            end
        end
        PeggleSim.trace_close!(eng.trace)
        @test caught_step[] !== nothing
        @test live_after_catch
        @test removed_step !== nothing
        @test b.y - b.radius > eng.virtual_height
        counts = _trace_raw_counts(path)
        @test get(counts, "ball_fell_out", 0) == 0
        @test counts["bucket_caught_ball"] == 1
        @test turn_end_step[] !== nothing
        hold_steps = Int(ceil(eng.config.bucket_catch_hold / eng.config.fixed_dt))
        @test hold_seen == removed_step + hold_steps
        @test turn_end_step[] - removed_step >= hold_steps
        @test turn_end_step[] == removed_step + hold_steps
        @test eng.last_removal_reason == "bucket_caught"
        @test eng.catch_hold_until_step === nothing
        @test e.bonus_score == eng.config.bucket_bonus
        # The snapshot carries the hold and the caught flag while they apply.
        holds = 0
        caught_flags = 0
        for line in eachline(path)
            rec = PeggleSim.JSON.parse(line)
            get(rec, "kind", nothing) == "step" || continue
            snap = rec["snapshot"]
            haskey(snap, "catch_hold_until_step") && (holds += 1)
            any(bb -> get(bb, "bucket_caught", false), snap["balls"]) && (caught_flags += 1)
            @test !haskey(snap["bucket"], "edge")
            @test haskey(snap["bucket"], "rim_width")
        end
        @test holds == hold_steps
        @test caught_flags == removed_step - caught_step[]
    end

    @testset "real catch: b2 straight drop" begin
        eng = _ramp_engine()
        PeggleSim.launch!(eng, 900)
        PeggleSim.run_shot!(eng)
        summary = PeggleSim.shot_summary(eng)
        # Lua 10ee3a0 harness capture (b2_center).
        @test summary.steps == 528
        @test summary.reason == "bucket_caught"
        @test summary.score == 15170.0
        # A reset clears the hold, as Engine:resetTurn does.
        eng.catch_hold_until_step = 7
        PeggleSim.reset_shot_engine!(eng, PeggleSim.capture_checkpoint(eng.sim;
            provenance = (reference_revision = "r", reference_tree = "t",
                          config_sha256 = "c", level_sha256 = "l")))
        @test eng.catch_hold_until_step === nothing
    end
end
