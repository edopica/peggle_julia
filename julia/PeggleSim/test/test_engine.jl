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
