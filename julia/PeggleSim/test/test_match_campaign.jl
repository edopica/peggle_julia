using Test
using JSON
using SHA
using PeggleSim

@testset "current Lua campaign configuration and 1v1 rule oracle" begin
    root = normpath(joinpath(@__DIR__, "../../.."))
    config_path = joinpath(root, "campaigns/ribbon/config.v1.json")
    config = PeggleSim.load_config(config_path)
    @test config.source_sha256 == bytes2hex(sha256(read(joinpath(root,"campaigns/ribbon/config.source.lua"))))
    @test config.launch_speed == 600
    @test config.gravity == 700
    @test config.wall_damping == 1.0
    @test PeggleSim.CampaignOptions().mode == Symbol("1v1")
    @test_throws ArgumentError PeggleSim.validate_campaign(PeggleSim.CampaignOptions(mode=:other))
    level = PeggleSim.load_level(joinpath(root,"fixtures/ribbon_waves/artifact/ribbon_waves.v1.json"))
    prov = merge(PeggleSim.campaign_provenance(level), (; config_sha256=config.source_sha256))
    metadata = JSON.parsefile(joinpath(root,"campaigns/ribbon/provenance.json"))
    @test metadata["game_source_sha256"] == bytes2hex(sha256(read(joinpath(root,"campaigns/ribbon/game.source.lua"))))
    isolated = PeggleSim.build_checkpoint(level,config;mode=Symbol("1v1"),provenance=prov)
    live = PeggleSim.shot_engine(isolated;config,level,callbacks=PeggleSim.match_callbacks())
    candidate = PeggleSim.shot_engine(isolated;config,level,callbacks=PeggleSim.match_callbacks())
    before = PeggleSim.checkpoint_to_dict(isolated)
    candidate.callbacks.on_bucket_catch(candidate)
    candidate.callbacks.on_bucket_catch(candidate)
    @test candidate.sim.match.shared_bucket_hits == 2
    @test candidate.sim.engine.bonus_score == 7500
    @test PeggleSim.checkpoint_to_dict(PeggleSim.capture_checkpoint(live.sim;provenance=prov)) == before
    @test PeggleSim.checkpoint_to_dict(isolated) == before
    PeggleSim.reset_shot_engine!(candidate,isolated)
    @test candidate.sim.match.shared_bucket_hits == 0
    @test candidate.sim.engine.bonus_score == 0
    cases = JSON.parsefile(joinpath(root,"fixtures/matches/rules.v1.json"))["cases"]
    @test length(cases) == 9
    for row in cases
        c = row["input"]
        expected = row["expected"]
        mode = Symbol(get(c,"mode","1v1"))
        ckpt = PeggleSim.build_checkpoint(level,config;mode,provenance=prov)
        eng = PeggleSim.shot_engine(ckpt;config,level,callbacks=PeggleSim.match_callbacks())
        m = eng.sim.match
        m.current_player_index = c["player"]
        m.shared_bucket_hits = get(c,"shared",0)
        for i in 1:2
            m.players[i].score = c["scores"][i]
            m.players[i].balls = c["balls"][i]
        end
        # Supply a completed shot to the match layer; all physics is tested
        # separately by the existing ribbon trace corpus and integration below.
        eng.sim.engine.style_score = c["score"]
        if get(c,"red",false)
            red = deepcopy(first(eng.sim.engine.pegs))
            red.peg_type = :red
            red.hit = true
            push!(eng.turn_peg_refs,red)
        end
        if get(c,"clear",false)
            filter!(p -> p.peg_type !== :red,eng.sim.engine.pegs)
        end
        m.players[m.current_player_index].balls -= 1
        for _ in 1:get(c,"catches",0)
            eng.callbacks.on_bucket_catch(eng)
        end
        @test eng.sim.engine.bonus_score == expected["bonus"]
        @test PeggleSim.get_turn_score(eng) == expected["shot_score"]
        eng.shot_done = true
        result = PeggleSim.finish_match_turn!(eng)
        @test [p.score for p in m.players] == expected["scores"]
        @test [p.balls for p in m.players] == expected["balls"]
        @test m.current_player_index == expected["player"]
        @test m.shared_bucket_hits == expected["shared"]
        @test m.game_over == expected["completed"]
        @test m.winner == get(expected,"winner",nothing)
        @test (result.reason == "continue") == (expected["resets"] == 1)
        @test result.score_after - result.score_before == result.score_delta
    end
    # A real two-player match progressing over multiple complete ribbon shots.
    initial = PeggleSim.build_checkpoint(level,config;mode=Symbol("1v1"),provenance=prov)
    eng = PeggleSim.shot_engine(initial;config,level,callbacks=PeggleSim.match_callbacks())
    for p in eng.sim.match.players
        p.balls = 2
    end
    players = Int[]
    for turn in 1:4
        m = eng.sim.match
        push!(players,m.current_player_index)
        m.players[m.current_player_index].balls -= 1
        PeggleSim.launch!(eng,900)
        PeggleSim.run_shot!(eng;max_steps=10000)
        @test eng.shot_done
        outcome = PeggleSim.finish_match_turn!(eng)
        @test sum(p.balls for p in m.players) == 4-turn
        m.game_over && break
        before = PeggleSim.checkpoint_to_dict(PeggleSim.capture_checkpoint(eng.sim;provenance=prov))["match"]
        ckpt = PeggleSim.prepare_match_turn!(eng,prov)
        @test PeggleSim.checkpoint_to_dict(ckpt)["match"] == before
        @test PeggleSim.get_turn_score(eng) == 0.0
    end
    @test eng.sim.match.game_over
    @test players == [1,2,1,2]
    # Same two real decisions, including both players' bot streams, at every
    # available requested worker count. Tests also run on single-thread Julia.
    o = PeggleSim.CampaignOptions(games=2,workers=1,max_turns=2)
    baseline = PeggleSim.run_campaign(level,config,o;parallel=false)
    for workers in unique([1,min(2,Threads.nthreads())])
        other = PeggleSim.CampaignOptions(games=2,workers=workers,max_turns=2)
        run = PeggleSim.run_campaign(level,config,other;parallel=true)
        @test run.games == baseline.games
    end
    @test all(g -> [d["player"] for d in g["decisions"]] == [1,2],baseline.games)
    @test length(unique(vcat([g["bot_seeds"] for g in baseline.games]...))) == 4
    @test all(g -> !g["completed"] && g["termination_reason"]=="turn_limit", baseline.games)
end
