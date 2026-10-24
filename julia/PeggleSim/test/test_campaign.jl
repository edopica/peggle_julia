using Test
using PeggleSim

@testset "campaign sectors and selection" begin
    sectors = PeggleSim.aim_sectors(1800, 100)
    @test length(sectors) == 19
    @test sectors[end] == 1800:1800
    @test vcat(collect.(sectors)...) == collect(0:1800)
    @test PeggleSim.aim_sectors(9, 5) == [0:4, 5:9]
    @test_throws ArgumentError PeggleSim.aim_sectors(1800, 0)
    select = PeggleSim.select_sector_shot
    scores = Float64[1, 3, 3, 3, 2, 2, 3]
    a = LoveRandom(71)
    b = LoveRandom(71)
    chosen = Set{Int}()
    sectors_chosen = Set{Int}()
    for _ in 1:1000
        x = select(scores, 2, a)
        @test x == select(scores, 2, b)
        @test x["median"] == 3.0
        @test x["eligible_sectors"] == [1, 2, 4]
        push!(chosen, x["intended_index"])
        push!(sectors_chosen, x["selected_sector"])
    end
    @test chosen == Set([1, 2, 3, 6])
    @test sectors_chosen == Set([1, 2, 4])
    @test select(Float64[1, 1, 4, 4], 2, a)["median"] == 2.5
    @test select(zeros(1801), 100, a)["eligible_sectors"] == collect(1:19)
    @test PeggleSim.bot_seed(42,1) != PeggleSim.bot_seed(42,2)
    @test_throws ArgumentError PeggleSim.validate_campaign(PeggleSim.CampaignOptions(epsilon=-1))
end

@testset "campaign bounded discrete execution noise" begin
    rng = LoveRandom(19)
    for (index, epsilon, expected) in [(0, 1, 0:1), (1800, 1, -1:0),
                                      (900, 2, -2:2), (42, 0, 0:0), (0, 9999, 0:1800)]
        draws = [PeggleSim.execution_offset!(rng, index, epsilon, 1800) for _ in 1:20000]
        @test all(in(expected), draws)
        if length(expected) < 10
            @test Set(draws) == Set(expected)
            counts = [count(==(x), draws) for x in expected]
            @test maximum(counts) - minimum(counts) < 700
        end
    end
    @test_throws ArgumentError PeggleSim.execution_offset!(rng, 0, -1, 1800)
end

@testset "solo lifecycle, isolation, and scheduling" begin
    root = normpath(joinpath(@__DIR__, "../../.."))
    level = PeggleSim.load_level(joinpath(root, "fixtures/ribbon_waves/artifact/ribbon_waves.v1.json"))
    config = PeggleSim.load_config(joinpath(root, "fixtures/ribbon_waves/config.dev.v1.json"))
    prov = PeggleSim.campaign_provenance(level)
    initial = PeggleSim.build_checkpoint(level, config; provenance=prov)
    live = PeggleSim.shot_engine(initial; config, level, callbacks=PeggleSim.solo_callbacks())
    candidate = PeggleSim.shot_engine(initial; config, level, callbacks=PeggleSim.solo_callbacks())
    before = PeggleSim.checkpoint_to_dict(PeggleSim.capture_checkpoint(live.sim; provenance=prov))
    scores = zeros(1801)
    evaluation = PeggleSim.evaluate_candidates!(candidate, initial, scores, 1)
    @test !isempty(evaluation.incomplete)
    @test before == PeggleSim.checkpoint_to_dict(initial)
    @test before == PeggleSim.checkpoint_to_dict(PeggleSim.capture_checkpoint(live.sim; provenance=prov))
    # Real complete shots on ribbon; deplete balls through the actual lifecycle.
    p = live.sim.match.players[1]
    p.balls = 2
    ids = Int[]
    saw_removal = false
    for turn in 1:20
        push!(ids, only(live.sim.engine.balls).id)
        p.balls -= 1
        PeggleSim.launch!(live, 900)
        PeggleSim.run_shot!(live; max_steps=10000)
        @test live.shot_done
        shot_score = PeggleSim.get_turn_score(live)
        old_score = p.score
        reason = PeggleSim.finish_solo_turn!(live)
        @test p.score == old_score + shot_score
        @test all(peg -> !peg.hit, live.sim.engine.pegs)
        saw_removal |= length(live.sim.engine.pegs) < length(initial.engine.pegs)
        reason == "continue" || break
        phase = live.sim.engine.bucket.phase
        reds = live.sim.engine.red_pegs_hit_amount
        old_score = p.score
        ckpt = PeggleSim.prepare_solo_turn!(live, prov)
        p = live.sim.match.players[1] # restore may replace match players
        @test p.score == old_score
        @test live.sim.engine.bucket.phase == phase
        @test live.sim.engine.red_pegs_hit_amount == reds
        @test PeggleSim.get_turn_score(live) == 0
        @test length(live.sim.colors.active) <= config.purple_pegs_per_turn
        @test only(ckpt.engine.balls).launched == false
    end
    @test live.sim.match.game_over
    @test saw_removal
    @test issorted(ids) && length(unique(ids)) == length(ids)
    # Bucket return has no score bonus in solo.
    balls_before = p.balls
    bonus_before = live.sim.engine.bonus_score
    live.callbacks.on_bucket_catch(live)
    @test p.balls == balls_before + 1
    @test live.sim.engine.bonus_score == bonus_before
    # All-red completion has priority, even with balls remaining.
    redfree = PeggleSim.shot_engine(initial; config, level, callbacks=PeggleSim.solo_callbacks())
    filter!(p -> p.peg_type !== :red, redfree.sim.engine.pegs)
    redfree.shot_done = true
    @test PeggleSim.finish_solo_turn!(redfree) == "all_red_cleared"
    @test redfree.sim.match.game_over
    # Full legal grid, intentionally short cap: limits never count as completion.
    o = PeggleSim.CampaignOptions(max_steps=1, max_turns=2, workers=min(3,Threads.nthreads()))
    serial = PeggleSim.run_campaign(level, config, o; parallel=false)
    parallel = PeggleSim.run_campaign(level, config, o; parallel=true)
    @test serial.games == parallel.games
    @test all(g -> !g["completed"] && g["turns"] == 0 && g["termination_reason"] == "candidate_step_limit", serial.games)
    # Exercise actual selections and noisy executions, rather than only capped sweeps.
    actual = PeggleSim.CampaignOptions(max_turns=1, workers=min(3,Threads.nthreads()))
    serial_actual = PeggleSim.run_campaign(level, config, actual; parallel=false)
    parallel_actual = PeggleSim.run_campaign(level, config, actual; parallel=true)
    @test serial_actual.games == parallel_actual.games
    @test all(g -> g["turns"] == 1 && !isempty(g["decisions"][1]["sectors"]), serial_actual.games)
    @test all(g -> !g["completed"] && g["termination_reason"] == "turn_limit", serial_actual.games)
    @test_throws ArgumentError PeggleSim.finish_solo_turn!(candidate)
end
