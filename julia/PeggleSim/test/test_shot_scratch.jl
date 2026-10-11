using Test
using PeggleSim

@testset "shot scratch ownership and reset" begin
    root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    fixture = joinpath(root, "fixtures", "mustache")
    level = PeggleSim.load_level(joinpath(fixture, "artifact", "mustache.v1.json"))
    config = PeggleSim.load_config(joinpath(fixture, "config.dev.v1.json"))
    provenance = (
        reference_revision = "da752257f613abbd209f1aa1acdd37a5f9be05f5",
        reference_tree = "61278edc5467bf8399c24f4af0fcf36d75cac6a2",
        config_sha256 = config.source_sha256,
        level_sha256 = level.level_sha256,
    )
    ckpt = PeggleSim.build_checkpoint(level, config; provenance)
    new_engine() = PeggleSim.shot_engine(ckpt; config, level,
                                         callbacks = PeggleSim.harness_callbacks())
    a, b = new_engine(), new_engine()
    sa, sb = a.scratch, b.scratch
    @test sa !== sb
    @test sa.physics !== sb.physics
    @test sa.physics.ball_frame !== sb.physics.ball_frame
    @test sa.physics.grazed !== sb.physics.grazed
    @test sa.physics.frame_pool !== sb.physics.frame_pool
    @test sa.contacts.groups !== sb.contacts.groups
    @test sa.contacts.group_pool !== sb.contacts.group_pool
    @test sa.scored_by_source !== sb.scored_by_source
    @test sa.slide.contact_line !== sb.slide.contact_line
    @test sa.remaining_balls !== a.sim.engine.balls
    @test sa.remaining_balls !== sb.remaining_balls

    # Interleave independent engines, then reset one while the other is live.
    PeggleSim.launch!(a, 0)
    PeggleSim.launch!(b, 900)
    for _ in 1:80
        PeggleSim.update!(a, config.fixed_dt)
        PeggleSim.update!(b, config.fixed_dt)
    end
    retained_snapshot = PeggleSim.snapshot_capture(b)
    retained_journal = PeggleSim.journal_snapshot(a.journal)
    retained_journal_copy = deepcopy(retained_journal)
    frames = copy(sa.physics.frame_pool)
    @test !isempty(frames)
    PeggleSim.reset_shot_engine!(a, ckpt)
    @test a.scratch === sa
    @test sa.physics.balls === a.sim.engine.balls
    @test isempty(sa.physics.ball_frame)
    @test isempty(sa.physics.grazed)
    @test sa.physics.ball === nothing
    @test sa.physics.hit_peg === nothing
    @test isempty(sa.contacts.candidates)
    @test isempty(sa.contacts.groups)
    @test all(isempty, sa.contacts.group_pool)
    @test all(isempty, sa.contacts.suppressed_pool)
    @test isempty(sa.contacts.scored)
    @test isempty(sa.scored_by_source)
    @test isempty(sa.slide.contact_line)
    @test isempty(sa.slide.contact_normal)
    @test isempty(sa.slide.bounced)
    @test isempty(sa.remaining_balls)
    @test PeggleSim.snapshot_capture(b) == retained_snapshot

    # Reused frame slots must be initialized for restored ball identities.
    PeggleSim.launch!(a, 900)
    PeggleSim.update!(a, config.fixed_dt)
    @test sa.physics.frame_pool[1] === frames[1]
    @test all(ball -> haskey(a.sim.engine.live_id_by_ball, ball),
              keys(sa.physics.ball_frame))
    PeggleSim.run_shot!(a)
    PeggleSim.run_shot!(b)
    @test PeggleSim.shot_summary(a) == PeggleSim.shot_summary(b)
    @test PeggleSim.snapshot_capture(a) == PeggleSim.snapshot_capture(b)
    @test retained_journal == retained_journal_copy

    @testset "reused physics matches fresh context across ball-set changes" begin
        balls = [PeggleSim.BallState(1, 300.0, 100.0, config.ball_radius),
                 PeggleSim.BallState(2, 330.0, 100.0, config.ball_radius)]
        for (i, ball) in enumerate(balls)
            ball.launched = true
            ball.vx = i == 1 ? 500.0 : -500.0
        end
        reference = deepcopy(balls)
        journal = PeggleSim.GameplayJournal()
        ref_journal = PeggleSim.GameplayJournal()
        ctx = PeggleSim.PhysicsContext(balls, config, level.virtual_width, journal)
        no_pegs = PeggleSim.Peg[]
        state(b) = (b.id, b.x, b.y, b.vx, b.vy, b.launched)
        for step in 1:8
            if step == 4
                # Shrink and replace an entity while reusing its numeric id.
                pop!(balls)
                pop!(reference)
                balls[1] = PeggleSim.BallState(1, 400.0, 120.0, config.ball_radius)
                reference[1] = deepcopy(balls[1])
            elseif step == 5
                balls[1].launched = reference[1].launched = true
            end
            PeggleSim.begin_step!(journal, step, 1)
            PeggleSim.begin_step!(ref_journal, step, 1)
            PeggleSim.physics_update!(balls, no_pegs, no_pegs, no_pegs,
                config.fixed_dt, nothing, config, level.virtual_width, journal, ctx)
            PeggleSim.physics_update!(reference, no_pegs, no_pegs, no_pegs,
                config.fixed_dt, nothing, config, level.virtual_width, ref_journal)
            @test state.(balls) == state.(reference)
            @test PeggleSim.journal_snapshot(journal) ==
                  PeggleSim.journal_snapshot(ref_journal)
            @test length(ctx.ball_frame) == count(b -> b.launched, balls)
            @test all(key -> any(b -> b === key, balls), keys(ctx.ball_frame))
        end
        @test length(ctx.frame_pool) == 2
    end

    @testset "seam pools recycle without stale suppression" begin
        PeggleSim.reset_shot_engine!(a, ckpt)
        pegs = a.sim.engine.pegs[1:3]
        for (i, peg) in enumerate(pegs)
            peg.peg_type = :blue
            peg.line = PeggleSim.LineMetadata("scratch|line", i, 3, false, 0.0)
        end
        function contacts!(order)
            PeggleSim.begin_step!(a.journal, 1, 1)
            for i in order
                peg = pegs[i]
                PeggleSim.emit_raw!(a.journal, "ball_contacted_peg", Dict{String,Any}(
                    "ball_id" => 1, "peg_id" => peg.id,
                    "contact_kind" => "sweep", "did_bounce" => false,
                    "iteration" => 1, "toi" => 0.5,
                    "impact_x" => peg.x, "impact_y" => peg.y,
                ))
            end
            PeggleSim.reduce_peg_contacts!(a)
        end
        contacts!((3, 2, 1))
        @test [p.hit for p in pegs] == [true, false, false]
        group = sa.contacts.group_pool[1]
        drop = sa.contacts.suppressed_pool[1]
        @test length(drop) == 2
        saved_score = only(a.buffered_peg_scored)
        saved_score_copy = deepcopy(saved_score)
        # The formerly suppressed peg can score on the next step, even though
        # the same group slot and (ball, line, iteration) key are reused.
        contacts!((2,))
        @test pegs[2].hit
        @test !pegs[3].hit
        @test sa.contacts.group_pool[1] === group
        @test sa.contacts.suppressed_pool[1] === drop
        @test isempty(drop)
        @test saved_score == saved_score_copy
        @test saved_score["peg_id"] == pegs[1].id
        contacts!(())
        @test isempty(sa.contacts.groups)
        @test isempty(group)
        @test isempty(a.buffered_peg_scored)
        @test saved_score == saved_score_copy
    end

    @testset "seam reduction boundaries and group-slot reuse" begin
        # Expectations follow pinned src/engine/core.lua:reducePegContacts:
        # earliest TOI defines group membership, but scoring uses raw order.
        eng = new_engine()
        pegs = eng.sim.engine.pegs[1:4]
        function line!(indices; id = "scratch|line", count = 4, closed = false)
            for (peg, index) in zip(pegs, indices)
                peg.peg_type = :blue
                peg.line = PeggleSim.LineMetadata(id, index, count, closed, 0.0)
            end
        end
        function reduce!(contacts)
            PeggleSim.begin_step!(eng.journal, 1, 1)
            for (i, toi) in contacts
                peg = pegs[i]
                PeggleSim.emit_raw!(eng.journal, "ball_contacted_peg", Dict{String,Any}(
                    "ball_id" => 1, "peg_id" => peg.id,
                    "contact_kind" => "sweep", "did_bounce" => false,
                    "iteration" => 1, "toi" => toi,
                    "impact_x" => peg.x, "impact_y" => peg.y,
                ))
            end
            PeggleSim.reduce_peg_contacts!(eng)
            return [p["peg_id"] for p in eng.buffered_peg_scored]
        end

        @testset "two groups exchange pooled slots" begin
            line!((1, 2, 1, 2))
            for (i, peg) in enumerate(pegs[3:4])
                peg.line = PeggleSim.LineMetadata("scratch|other", i, 2, false, 0.0)
            end
            @test reduce!(((2, 0.5), (1, 0.5), (4, 0.5), (3, 0.5))) ==
                  [pegs[1].id, pegs[3].id]
            scratch = eng.scratch.contacts
            key1, key2 = (1, "scratch|line", 1), (1, "scratch|other", 1)
            @test (scratch.groups[key1], scratch.groups[key2]) == (1, 2)
            groups = copy(scratch.group_pool)
            drops = copy(scratch.suppressed_pool)
            @test length.(drops) == [1, 1]
            # Both previously suppressed pegs remain eligible. Reverse first
            # appearance so each key now uses the other group's old slot.
            @test reduce!(((4, 0.5), (2, 0.5))) == [pegs[4].id, pegs[2].id]
            @test (scratch.groups[key1], scratch.groups[key2]) == (2, 1)
            @test all(i -> scratch.group_pool[i] === groups[i], 1:2)
            @test all(i -> scratch.suppressed_pool[i] === drops[i], 1:2)
            @test length.(groups) == [1, 1]
            @test all(isempty, drops)
        end

        @testset "duplicate TOIs and raw scoring order" begin
            for duplicate_tois in ((0.8, 0.2), (0.2, 0.8))
                PeggleSim.reset_shot_engine!(eng, ckpt)
                pegs = eng.sim.engine.pegs[1:4]
                line!((1, 2, 3, 4))
                @test reduce!(((1, duplicate_tois[1]), (2, 0.2),
                               (1, duplicate_tois[2]))) == [pegs[1].id]
                @test length(eng.scratch.contacts.group_pool[1]) == 2
                @test only(eng.buffered_peg_scored)["source_sequence"] ==
                      eng.journal.raw[1].sequence
            end
        end

        @testset "closed seam and inclusive TOI epsilon" begin
            # Start at zero to test the exact 0.05 boundary without subtraction
            # rounding. Indices 1 and 4 are adjacent only on a closed line.
            for (closed, toi, expected) in ((true, 0.05, [1]),
                                            (true, nextfloat(0.05), [2, 1]),
                                            (false, 0.05, [2, 1]))
                PeggleSim.reset_shot_engine!(eng, ckpt)
                pegs = eng.sim.engine.pegs[1:4]
                line!((1, 4, 2, 3); closed)
                @test reduce!(((2, toi), (1, 0.0))) == [pegs[i].id for i in expected]
            end
        end
    end
end
