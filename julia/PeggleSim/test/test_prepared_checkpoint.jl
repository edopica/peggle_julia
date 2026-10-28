using Test
using PeggleSim

@testset "prepared decision checkpoint and compact scans" begin
    root = normpath(joinpath(@__DIR__, "../../.."))
    config = PeggleSim.load_config(joinpath(root, "interchange/config.v1.json"))

    @testset "restore ownership, removals, and complete RNG state" begin
        for file in sort(readdir(joinpath(root, "fixtures/checkpoints")))
            endswith(file, ".v1.json") || continue
            checkpoint = PeggleSim.checkpoint_from_dict(PeggleSim.load_json(
                joinpath(root, "fixtures/checkpoints", file)))
            prepared = PeggleSim.prepare_checkpoint(checkpoint)
            witness = canonical_json(checkpoint)
            eng = PeggleSim.shot_engine(checkpoint; config)
            other = PeggleSim.shot_engine(checkpoint; config)
            PeggleSim.reset_shot_engine!(eng, prepared)
            PeggleSim.reset_shot_engine!(other, prepared)
            pool = copy(eng.sim.engine.pegs)
            balls = copy(eng.sim.engine.balls)
            for _ in 1:3
                peg = first(eng.sim.engine.pegs)
                PeggleSim.remove_peg!(eng, peg)
                peg.x = -100.0
                peg.angle = 42.0
                peg.vx = -0.0
                peg.va = 19.0
                peg.hit = true
                empty!(eng.sim.engine.balls)
                random_normal(eng.sim.rng)
                push!(eng.sim.colors.active, -123)
                PeggleSim.reset_shot_engine!(eng, prepared)
                restored = PeggleSim.capture_checkpoint(eng.sim; provenance=checkpoint.provenance)
                @test canonical_json(restored) == witness
                @test all(a === b for (a,b) in zip(pool, eng.sim.engine.pegs))
                @test all(a === b for (a,b) in zip(balls, eng.sim.engine.balls))
                @test all(p -> p.va == 0.0 && isequal(p.vx, 0.0), eng.sim.engine.pegs)
                @test eng.sim.rng.last_randomnormal === Inf
                @test eng.sim.colors.rng === eng.sim.rng
                @test all(eng.sim.engine.peg_by_id[p.id] === p for p in pool)
                @test canonical_json(PeggleSim.capture_checkpoint(other.sim;
                    provenance=checkpoint.provenance)) == witness
                @test canonical_json(checkpoint) == witness
            end
            checkpoint.engine.pegs[1] = checkpoint.engine.pegs[end]
            @test canonical_json(prepared.checkpoint) == witness
            @test all(a !== b for (a,b) in zip(pool, other.sim.engine.pegs))
        end
    end

    @testset "full shot parity, events, spawn and clearing reuse" begin
        for (path, configpath, aims, balls) in (
                ("fixtures/mustache/artifact/mustache.v1.json",
                 "fixtures/mustache/config.dev.v1.json", (0, 570, 900), 1),
                ("interchange/levels/slide.v1.json", "interchange/config.v1.json", (570, 900), 3),
                ("interchange/levels/squiggly_circle.v1.json", "interchange/config.v1.json", (570, 900), 1),
                ("fixtures/ribbon_waves/artifact/ribbon_waves.v1.json",
                 "campaigns/ribbon/config.v1.json", (570, 900), 1))
            level = PeggleSim.load_level(joinpath(root, path))
            cfg = PeggleSim.load_config(joinpath(root, configpath))
            checkpoint = PeggleSim.build_checkpoint(level, cfg; balls,
                provenance=PeggleSim.campaign_provenance(level))
            prepared = PeggleSim.prepare_checkpoint(checkpoint)
            baseline = PeggleSim.shot_engine(checkpoint; config=cfg, level,
                callbacks=PeggleSim.harness_callbacks(clearing=true))
            candidate = PeggleSim.shot_engine(checkpoint; config=cfg, level,
                callbacks=PeggleSim.harness_callbacks(clearing=true))
            for (compact, static_geometry) in ((false, false), (true, false), (true, true)), aim in aims
                PeggleSim.reset_shot_engine!(baseline, checkpoint)
                PeggleSim.reset_shot_engine!(candidate, prepared; compact, static_geometry)
                PeggleSim.launch!(baseline, aim)
                PeggleSim.launch!(candidate, aim)
                for step in 1:4000
                    @test baseline.shot_done == candidate.shot_done
                    baseline.shot_done && break
                    PeggleSim.update!(baseline, cfg.fixed_dt)
                    PeggleSim.update!(candidate, cfg.fixed_dt)
                    # Observe the full ordered event streams, including graze.
                    for field in (:raw, :derived)
                        @test canonical_json(PeggleSim.event_dict.(getproperty(baseline.journal, field))) ==
                              canonical_json(PeggleSim.event_dict.(getproperty(candidate.journal, field)))
                    end
                end
                @test baseline.shot_done && candidate.shot_done
                @test PeggleSim.shot_summary(baseline) == PeggleSim.shot_summary(candidate)
                @test canonical_json(PeggleSim.capture_checkpoint(baseline.sim;
                    provenance=checkpoint.provenance)) == canonical_json(
                    PeggleSim.capture_checkpoint(candidate.sim; provenance=checkpoint.provenance))
            end
        end
    end

    @testset "inline layout and live geometry refresh" begin
        for S in (PeggleSim.CircleShape, PeggleSim.RectangleShape, PeggleSim.AnnularShape)
            @test isbitstype(PeggleSim.CompactPegGeometry{S})
        end
        peg = PeggleSim.Peg(1, 0.0, -0.0, 0.0, 0.0, PeggleSim.CircleShape(9.0),
                            :blue, false, 0, 0, nothing)
        records = [PeggleSim.CompactPegGeometry(peg)]
        ball = PeggleSim.BallState(1, 0.0, 0.0, 6.0)
        ctx = PeggleSim.PhysicsContext([ball], config, 1200.0, PeggleSim.GameplayJournal())
        ctx.ball = ball
        ctx.move_x, ctx.move_y, ctx.time_remaining = 3.0, -0.0, 1 / 60
        PeggleSim.prepare_static_query!(ctx)
        for x in (0.0, -0.0, 1000.0), vx in (0.0, -0.0, 32.0)
            peg.x = x
            peg.vx = vx
            peg.bounding_radius = nothing
            PeggleSim.refresh_geometry!(records, [peg])
            @test isequal(PeggleSim.broad_phase_pass(ctx, records[1]),
                          PeggleSim.broad_phase_pass(ctx, peg))
        end
    end
end
