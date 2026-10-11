# Focused tests for src/snapshot.jl (workstream F), the schema v2 port of
# ../peggle_evolved/src/systems/simulation_snapshot.lua.
#
# The key-set assertions pin the Lua nil -> absent-key mapping (circle and
# annular pegs have no base_angle/angle; hit_order/multiplier_at_hit appear
# only after a hit; scored_fever only when true; fever omits target_top and
# the divider is_divider flag).

using Test
using PeggleSim

const SNAP_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const SNAP_MUSTACHE_DIR = joinpath(SNAP_REPO_ROOT, "fixtures", "mustache")
const SNAP_MUSTACHE_LEVEL =
    joinpath(SNAP_MUSTACHE_DIR, "artifact", "mustache.v1.json")
const SNAP_MUSTACHE_CONFIG =
    joinpath(SNAP_MUSTACHE_DIR, "config.dev.v1.json")

function _snap_level()
    return PeggleSim.load_level(SNAP_MUSTACHE_LEVEL)
end

function _snap_config()
    return PeggleSim.load_config(SNAP_MUSTACHE_CONFIG)
end

@testset "snapshot" begin
    @testset "one-step capture shape (schema v2)" begin
        level = _snap_level()
        config = _snap_config()
        provenance = (
            reference_revision = "da752257f613abbd209f1aa1acdd37a5f9be05f5",
            reference_tree = "61278edc5467bf8399c24f4af0fcf36d75cac6a2",
            config_sha256 = config.source_sha256,
            level_sha256 = PeggleSim.level_sha256(SNAP_MUSTACHE_LEVEL),
        )
        ckpt = PeggleSim.build_checkpoint(
            level, config; balls = 1, mode = :solo, provenance = provenance)
        eng = PeggleSim.shot_engine(
            ckpt; config = config, callbacks = PeggleSim.harness_callbacks(),
            level = level)
        PeggleSim.launch!(eng, 900)
        PeggleSim.update!(eng, config.fixed_dt)

        snap = PeggleSim.snapshot_capture(eng)
        @test snap["schema_version"] == 2
        @test snap["step_id"] == 1
        @test snap["shot_id"] == 1
        @test snap["level_name"] == "mustache"
        @test snap["turn_peg_count"] == 0
        @test snap["turn_pegs_hit"] == Int[]
        @test snap["clearing_active"] === false
        @test snap["bucket"]["phase"] != 0.0

        balls = snap["balls"]
        @test length(balls) == 1
        ball = balls[1]
        @test Set(keys(ball)) == Set([
            "id", "x", "y", "prev_x", "prev_y", "vx", "vy", "radius",
            "launched",
        ])
        @test ball["id"] == 1
        @test ball["launched"] === true
        @test ball["y"] == 63.32
        @test ball["prev_y"] == 50.0

        pegs = snap["pegs"]
        @test length(pegs) == length(level.pegs)
        circle = first(p for p in pegs if p["shape"] == "circle")
        @test haskey(circle, "radius")
        @test !haskey(circle, "base_angle")
        @test !haskey(circle, "angle")
        @test !haskey(circle, "hit_order")
        @test !haskey(circle, "multiplier_at_hit")
        @test !haskey(circle, "circuit_id")
        @test !haskey(circle, "motion")
        @test circle["hit"] === false
        @test Set(keys(circle["line"])) ==
              Set(["id", "index", "count", "closed", "gap"])

        annular = first(p for p in pegs if p["shape"] == "annular")
        @test haskey(annular, "r_in") && haskey(annular, "r_out")
        @test haskey(annular, "theta_start") && haskey(annular, "theta_end_abs")
        @test !haskey(annular, "segments")
        @test !haskey(annular, "base_angle")
        @test !haskey(annular, "angle")

        @test Set(keys(snap["bucket"])) == Set([
            "x", "prev_x", "top", "hole", "edge", "height", "phase",
        ])

        fever = snap["fever_buckets"]
        @test !haskey(fever, "target_top")
        @test length(fever["buckets"]) == 5
        @test length(fever["dividers"]) == 6
        @test all(!haskey(b, "is_divider") for b in fever["buckets"])
        @test all(!haskey(d, "is_divider") for d in fever["dividers"])
        @test fever["top"] == 550.0
    end

    @testset "hit pegs and scored_fever keys" begin
        level = _snap_level()
        config = _snap_config()
        provenance = (
            reference_revision = "da752257f613abbd209f1aa1acdd37a5f9be05f5",
            reference_tree = "61278edc5467bf8399c24f4af0fcf36d75cac6a2",
            config_sha256 = config.source_sha256,
            level_sha256 = PeggleSim.level_sha256(SNAP_MUSTACHE_LEVEL),
        )
        ckpt = PeggleSim.build_checkpoint(
            level, config; balls = 1, mode = :solo, provenance = provenance)
        eng = PeggleSim.shot_engine(
            ckpt; config = config, callbacks = PeggleSim.harness_callbacks(),
            level = level)
        PeggleSim.launch!(eng, 0)

        # Step until the first hit (left-wall fixture: step 26), while the hit
        # peg is still on the board.
        while eng.sim.engine.hit_counter == 0 && eng.steps_run < 100
            PeggleSim.update!(eng, eng.config.fixed_dt)
        end
        @test eng.sim.engine.hit_counter == 1
        snap = PeggleSim.snapshot_capture(eng)
        hit = first(p for p in snap["pegs"] if p["hit"])
        @test haskey(hit, "hit_order")
        @test haskey(hit, "multiplier_at_hit")
        @test hit["multiplier_at_hit"] == 1
        @test length(snap["turn_pegs_hit"]) == 1
        @test snap["turn_peg_count"] == 1
        @test all(!haskey(p, "hit_order") for p in snap["pegs"] if !p["hit"])

        # A ball that scored in fever carries scored_fever.
        eng.sim.engine.balls[1].scored_fever = true
        snap2 = PeggleSim.snapshot_capture(eng)
        @test snap2["balls"][1]["scored_fever"] === true
    end
end
