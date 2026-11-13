# Focused tests for src/snapshot.jl (workstream F), the schema v2 port of
# ../peggle_evolved/src/systems/simulation_snapshot.lua.
#
# The key-set assertions pin the Lua nil -> absent-key mapping (circle and
# annular pegs have no base_angle/angle; hit_order/multiplier_at_hit appear
# only after a hit; scored_fever only when true; fever omits target_top and
# the divider is_divider flag). Scenes use the real b2 level (circles,
# annular and rectangle pegs) and g1 (ribbons) under the 10ee3a0 rules
# (RULES_RAMP_BUCKET); the per-step snapshots of these boards were checked
# byte-identical against Lua 10ee3a0 (wiki/context/bucket-ramps.md).

using Test
using PeggleSim

const SNAP_RL = PeggleSim.RealLevels

function _snap_engine(name::AbstractString)
    level = PeggleSim.load_level(SNAP_RL.artifact_path(name))
    config = PeggleSim.load_config(SNAP_RL.fixture_config_path(name))
    ckpt = PeggleSim.build_checkpoint(
        level, config; balls = 1, mode = :solo,
        provenance = PeggleSim.campaign_provenance(level))
    eng = PeggleSim.shot_engine(
        ckpt; config = config, callbacks = PeggleSim.harness_callbacks(),
        level = level)
    return eng, level, config
end

@testset "snapshot" begin
    @testset "one-step capture shape (schema v2)" begin
        eng, level, config = _snap_engine("b2")
        PeggleSim.launch!(eng, 900)
        PeggleSim.update!(eng, config.fixed_dt)

        snap = PeggleSim.snapshot_capture(eng)
        @test snap["schema_version"] == 2
        @test snap["step_id"] == 1
        @test snap["shot_id"] == 1
        @test snap["level_name"] == "b2"
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
        # Launch speed 400 at the center aim, gravity 700, one 1/60 s step.
        @test ball["prev_y"] == 50.0
        @test ball["vy"] == 400.0 + config.gravity * config.fixed_dt
        @test ball["y"] == 56.66

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

        rect = first(p for p in pegs if p["shape"] == "rectangle")
        @test haskey(rect, "base_angle") && haskey(rect, "angle")
        @test Set(keys(rect["line"])) ==
              Set(["id", "index", "count", "closed", "gap"])

        annular = first(p for p in pegs if p["shape"] == "annular")
        @test haskey(annular, "r_in") && haskey(annular, "r_out")
        @test haskey(annular, "theta_start") && haskey(annular, "theta_end_abs")
        @test !haskey(annular, "segments")
        @test !haskey(annular, "base_angle")
        @test !haskey(annular, "angle")

        # 10ee3a0 ramp bucket keys; the classic `edge` key is absent.
        @test Set(keys(snap["bucket"])) == Set([
            "x", "prev_x", "top", "hole", "rim_width", "rim_height",
            "ramp_width", "ramp_height", "height", "floor", "phase",
        ])
        @test !haskey(snap, "catch_hold_until_step")

        fever = snap["fever_buckets"]
        @test !haskey(fever, "target_top")
        @test length(fever["buckets"]) == 5
        @test length(fever["dividers"]) == 6
        @test all(!haskey(b, "is_divider") for b in fever["buckets"])
        @test all(!haskey(d, "is_divider") for d in fever["dividers"])
        @test fever["top"] == level.virtual_height
    end

    @testset "hit pegs and scored_fever keys" begin
        eng, _, _ = _snap_engine("b2")
        PeggleSim.launch!(eng, 0)

        # Step until the first hit (b2 aim 0: step 24), while the hit peg is
        # still on the board.
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

    @testset "ribbon pegs carry their pieces" begin
        eng, _, _ = _snap_engine("g1")
        snap = PeggleSim.snapshot_capture(eng)
        ribbon = first(p for p in snap["pegs"] if p["shape"] == "ribbon")
        @test haskey(ribbon, "base_angle") && haskey(ribbon, "angle")
        @test haskey(ribbon, "path_start") && haskey(ribbon, "path_end")
        @test !haskey(ribbon, "radius")
        @test !isempty(ribbon["parts"])
        @test all(Set(keys(part)) == Set(["x", "y", "r_in", "r_out", "theta_start",
                                          "theta_end_abs", "path_direction"])
                  for part in ribbon["parts"])
    end
end
