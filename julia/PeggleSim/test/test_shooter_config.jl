using Test, JSON, PeggleSim

@testset "shooter placement and extended aim" begin
    config = PeggleSim.load_config(PeggleSim.RealLevels.config_path())
    level = PeggleSim.load_level(PeggleSim.RealLevels.artifact_path("b1"))
    @test config.aim_extra_angle ≈ deg2rad(45)
    checkpoint = PeggleSim.build_checkpoint(level, config; provenance=PeggleSim.campaign_provenance(level))
    @test only(checkpoint.engine.balls).y == 50.0
    lo = PeggleSim.angle_for_index(0, config)
    hi = PeggleSim.angle_for_index(config.aim_discretization_steps, config)
    @test lo < 0
    @test hi > pi
    for i in 0:config.aim_discretization_steps
        a = PeggleSim.angle_for_index(i, config)
        @test PeggleSim.snapped_aim_angle(a, config) == a
    end
    eng = PeggleSim.shot_engine(checkpoint; config, level)
    PeggleSim.launch!(eng, 0)
    @test only(eng.sim.engine.balls).vy < 0
    for _ in 1:90
        PeggleSim.step_simulation!(eng, config.fixed_dt)
        @test only(eng.sim.engine.balls).y >= config.ball_radius
    end
    empty!(eng.sim.engine.balls)
    next_turn = PeggleSim.prepare_match_turn!(eng, checkpoint.provenance)
    @test only(next_turn.engine.balls).y == 50.0
    legacy = PeggleSim.load_config(PeggleSim.RealLevels.fixture_config_path("b1"))
    @test legacy.aim_extra_angle == 0.0
    mktempdir() do dir
        doc = JSON.parsefile(PeggleSim.RealLevels.config_path())
        for (key, value) in (("aim_extra_angle", -0.1), ("aim_extra_angle", pi))
            bad = deepcopy(doc)
            bad["values"][key] = value
            path = joinpath(dir, "invalid.json")
            open(io -> JSON.print(io, bad), path, "w")
            @test_throws ArgumentError PeggleSim.load_config(path)
        end
    end
end
