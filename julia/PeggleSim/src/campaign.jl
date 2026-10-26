# Solo and 1v1 campaigns. Physics stays in ShotEngine; match rules follow
# src/states/game.lua. The default workload is shared-board 1v1.
Base.@kwdef struct CampaignOptions
    mode::Symbol = Symbol("1v1")
    games::Int = 8
    base_seed::Int = 20261024
    sector_size::Int = 100
    epsilon::Int = 1
    max_steps::Int = 3600
    max_turns::Int = 100
    workers::Int = 8
end

function validate_campaign(o::CampaignOptions)
    for name in (:games, :sector_size, :max_steps, :max_turns, :workers)
        getfield(o, name) > 0 || throw(ArgumentError("$name must be positive"))
    end
    o.mode in (:solo, Symbol("1v1")) || throw(ArgumentError("mode must be solo or 1v1"))
    o.epsilon >= 0 || throw(ArgumentError("epsilon must be nonnegative"))
    o.base_seed >= 0 || throw(ArgumentError("base_seed must be nonnegative"))
    return o
end

function aim_sectors(last_index::Int, size::Int)
    last_index >= 0 && size > 0 || throw(ArgumentError("invalid sector bounds"))
    return [i:min(i + size - 1, last_index) for i in 0:size:last_index]
end

# Rejection sampling gives unbiased discrete draws and uses only the bot stream.
function bot_uniform!(rng::LoveRandom, lo::Int, hi::Int)
    lo <= hi || throw(ArgumentError("empty sampling interval"))
    n = UInt64(hi - lo + 1)
    threshold = (-n) % n
    while true
        x = rand_u64!(rng)
        x >= threshold && return lo + Int(x % n)
    end
end

function execution_offset!(rng::LoveRandom, index::Int, epsilon::Int, last::Int)
    epsilon >= 0 && 0 <= index <= last || throw(ArgumentError("invalid noise bounds"))
    return bot_uniform!(rng, -min(epsilon, index), min(epsilon, last - index))
end

function select_sector_shot(scores::Vector{Float64}, size::Int, rng::LoveRandom)
    all(isfinite, scores) || throw(ArgumentError("scores must be finite"))
    sectors = aim_sectors(length(scores) - 1, size)
    winners = [begin
        best = maximum(@view scores[(first(s)+1):(last(s)+1)])
        indices = [i for i in s if scores[i+1] == best]
        Dict("sector" => j, "first" => first(s), "last" => last(s),
             "score" => best, "indices" => indices)
    end for (j, s) in enumerate(sectors)]
    sorted = sort([w["score"]::Float64 for w in winners])
    n = length(sorted)
    median = isodd(n) ? sorted[(n+1)÷2] : (sorted[n÷2] + sorted[n÷2+1]) / 2
    eligible = [j for j in eachindex(winners) if winners[j]["score"] >= median]
    sector = eligible[bot_uniform!(rng, 1, length(eligible))]
    ties = winners[sector]["indices"]::Vector{Int}
    index = ties[bot_uniform!(rng, 1, length(ties))]
    return Dict{String,Any}("sectors" => winners, "median" => median,
        "eligible_sectors" => eligible, "selected_sector" => sector,
        "intended_index" => index)
end

campaign_provenance(level) = (
    reference_revision = level.provenance.reference_revision,
    reference_tree = level.provenance.reference_tree,
    config_sha256 = level.provenance.config_sha256,
    level_sha256 = level.level_sha256)

function match_callbacks()
    return ShotCallbacks(
        on_bucket_catch = eng -> begin
            m = eng.sim.match
            if m.mode === :solo
                m.players[1].balls += 1
            else
                m.shared_bucket_hits += 1
                eng.sim.engine.bonus_score += m.shared_bucket_hits * eng.config.bucket_incremental_base
            end
            nothing
        end,
        on_style_shot = (eng, info) -> begin
            style = String(info["style"])
            eng.style_counts[style] = get(eng.style_counts, style, 0) + 1
            nothing
        end)
end

# Compatibility entry points for the optional solo workflow.
solo_callbacks() = match_callbacks()

function determine_match_winner!(m::MatchState)
    m.winner = m.mode === :solo ? 1 :
        m.players[1].score > m.players[2].score ? 1 :
        m.players[2].score > m.players[1].score ? 2 : 0
    return m.winner
end

# Only completed actual shots are banked; candidates use get_turn_score and
# never apply match penalties. turn_peg_refs survives peg clearing/removal.
function finish_match_turn!(eng::ShotEngine)
    eng.shot_done || throw(ArgumentError("cannot finish an incomplete shot"))
    m = eng.sim.match
    player = m.current_player_index
    p = m.players[player]
    before = p.score
    shot_score = get_turn_score(eng)
    hit_red = any(peg -> peg.peg_type === :red, eng.turn_peg_refs)
    p.score += shot_score
    penalty = 0.0
    credited = shot_score
    if m.mode === Symbol("1v1") && !hit_red
        p.score -= shot_score
        penalty = floor(p.score * 0.25)
        p.score -= penalty
        credited = 0.0
    end
    reason = "continue"
    if !any(peg -> peg.peg_type === :red && !peg.hit, eng.sim.engine.pegs)
        reason = "all_red_cleared"
    elseif m.mode === :solo
        p.balls <= 0 && (reason = "balls_exhausted")
    else
        found = false
        for _ in 1:2
            m.current_player_index = 3 - m.current_player_index
            if m.players[m.current_player_index].balls > 0
                found = true
                break
            end
        end
        found || (reason = "balls_exhausted")
    end
    if reason != "continue"
        m.game_over = true
        determine_match_winner!(m)
    end
    return (; reason, player, hit_red, penalty, credited_score = credited,
        score_before = before, score_after = p.score, score_delta = p.score - before)
end

finish_solo_turn!(eng::ShotEngine) = finish_match_turn!(eng).reason

function prepare_match_turn!(eng::ShotEngine, provenance)
    e = eng.sim.engine
    isempty(e.balls) || throw(ArgumentError("previous balls still live"))
    ball = register_ball!(e, BallState(0, eng.virtual_width / 2, 50.0, eng.config.ball_radius))
    # register_ball! registers identity; the collection is owned by the caller.
    push!(e.balls, ball)
    e.clear_queue = nothing
    e.clear_timer = 0.0
    empty!(e.turn_pegs_hit)
    e.bonus_score = 0.0
    e.style_score = 0.0
    reset_shot!(eng.sim.trackers)
    assign_next_purple_pegs!(e.pegs, eng.sim.colors, eng.config.purple_pegs_per_turn)
    ckpt = capture_checkpoint(eng.sim; provenance)
    reset_shot_engine!(eng, ckpt)
    return ckpt
end

prepare_solo_turn!(eng::ShotEngine, provenance) = prepare_match_turn!(eng, provenance)

# Separate, deterministically derived bot seeds fit exactly in LoveRandom's
# Float64 constructor. Gameplay RNG starts from the same level seed in all games.
bot_seed(base::Int, game::Int) = Int(wang_hash64(UInt64(base) ⊻
    (UInt64(game) * UInt64(0x9e3779b97f4a7c15))) & UInt64(0x001fffffffffffff))

function evaluate_candidates!(eng::ShotEngine, ckpt::Checkpoint,
                              scores::Vector{Float64}, max_steps::Int,
                              ::Val{Instrument} = Val(true)) where {Instrument}
    reset_ns = UInt64(0)
    simulation_ns = UInt64(0)
    incomplete = Int[]
    for i in 0:(length(scores)-1)
        t = Instrument ? time_ns() : UInt64(0)
        reset_shot_engine!(eng, ckpt)
        Instrument && (reset_ns += time_ns() - t)
        t = Instrument ? time_ns() : UInt64(0)
        launch!(eng, i)
        run_shot!(eng; max_steps)
        scores[i+1] = get_turn_score(eng)
        Instrument && (simulation_ns += time_ns() - t)
        eng.shot_done || push!(incomplete, i)
    end
    return (; reset_ns, simulation_ns, incomplete)
end

function run_bot_game(initial::Checkpoint, level::LevelDefinition, config::SimConfig,
                       o::CampaignOptions, game::Int,
                       instrumentation::Val{Instrument} = Val(true)) where {Instrument}
    setup_start = time_ns()
    seeds = o.mode === :solo ? [bot_seed(o.base_seed, game)] :
        [bot_seed(o.base_seed, 2 * (game - 1) + player) for player in 1:2]
    rngs = LoveRandom.(seeds)
    live = shot_engine(initial; config, level, callbacks = match_callbacks())
    candidate = shot_engine(initial; config, level, callbacks = match_callbacks())
    scores = zeros(config.aim_discretization_steps + 1)
    prov = initial.provenance
    ckpt = initial
    decisions = Any[]
    latencies = Float64[]
    phases = Dict(k => 0.0 for k in ("candidate_reset", "simulation", "selection", "actual_shot", "checkpoint"))
    candidates = 0
    reason = "turn_limit"
    turns = 0
    setup_seconds = (time_ns() - setup_start) / 1e9
    for turn in 1:o.max_turns
        start = time_ns()
        player = live.sim.match.current_player_index
        rng = rngs[player]
        evaluated = evaluate_candidates!(candidate, ckpt, scores, o.max_steps, instrumentation)
        candidates += length(scores)
        Instrument && (phases["candidate_reset"] += evaluated.reset_ns / 1e9)
        Instrument && (phases["simulation"] += evaluated.simulation_ns / 1e9)
        if !isempty(evaluated.incomplete)
            push!(decisions, Dict("turn" => turn, "player" => player, "incomplete_candidates" => evaluated.incomplete))
            reason = "candidate_step_limit"
            push!(latencies, (time_ns() - start) / 1e9)
            break
        end
        t = Instrument ? time_ns() : UInt64(0)
        decision = select_sector_shot(scores, o.sector_size, rng)
        index = decision["intended_index"]::Int
        offset = execution_offset!(rng, index, o.epsilon, config.aim_discretization_steps)
        decision["offset"] = offset
        decision["executed_index"] = index + offset
        decision["turn"] = turn
        decision["player"] = player
        Instrument && (phases["selection"] += (time_ns() - t) / 1e9)
        t = Instrument ? time_ns() : UInt64(0)
        # Live is still the original decision state: evaluations touched only candidate.
        next_ball_id_before = live.sim.engine.next_ball_id
        live.sim.match.players[player].balls -= 1
        launch!(live, index + offset)
        run_shot!(live; max_steps = o.max_steps)
        turns += 1
        summary = shot_summary(live)
        decision["shot"] = Dict(string(k) => v for (k, v) in pairs(summary))
        # The single-shot summary assumes IDs start at one; campaigns retain IDs.
        decision["shot"]["spawned"] = live.sim.engine.next_ball_id - next_ball_id_before
        decision["style_counts"] = copy(live.style_counts)
        reason = "actual_step_limit"
        if live.shot_done
            outcome = finish_match_turn!(live)
            reason = outcome.reason
            decision["settlement"] = Dict(string(k) => v for (k,v) in pairs(outcome))
        end
        decision["remaining_balls"] = live.sim.match.players[player].balls
        decision["player_scores"] = [p.score for p in live.sim.match.players]
        decision["player_balls"] = [p.balls for p in live.sim.match.players]
        decision["shared_bucket_hits"] = live.sim.match.shared_bucket_hits
        decision["next_player"] = live.sim.match.game_over ? nothing : live.sim.match.current_player_index
        decision["remaining_pegs"] = length(live.sim.engine.pegs)
        decision["remaining_red_pegs"] = count(p -> p.peg_type === :red && !p.hit, live.sim.engine.pegs)
        decision["gameplay_rng_state"] = get_state(live.sim.rng)
        decision["bot_rng_state"] = get_state(rng)
        push!(decisions, decision)
        Instrument && (phases["actual_shot"] += (time_ns() - t) / 1e9)
        if reason == "continue" && turn < o.max_turns
            t = Instrument ? time_ns() : UInt64(0)
            ckpt = prepare_match_turn!(live, prov)
            Instrument && (phases["checkpoint"] += (time_ns() - t) / 1e9)
        end
        push!(latencies, (time_ns() - start) / 1e9)
        reason == "continue" || break
        reason = "turn_limit"
    end
    result = Dict("game" => game, "mode" => String(o.mode), "base_seed" => o.base_seed,
        "bot_seeds" => seeds,
        "gameplay_seed" => initial.rng.seed, "initial_gameplay_rng_state" => initial.rng.state_b64,
        "final_gameplay_rng_state" => get_state(live.sim.rng), "final_bot_rng_states" => get_state.(rngs),
        "decisions" => decisions, "final_score" => o.mode === :solo ?
            live.sim.match.players[1].score : [p.score for p in live.sim.match.players],
        "player_scores" => [p.score for p in live.sim.match.players],
        "player_balls" => [p.balls for p in live.sim.match.players],
        "player_turns" => [count(d -> get(d,"player",0)==i && haskey(d,"shot"), decisions) for i in 1:2],
        "winner" => live.sim.match.winner, "shared_bucket_hits" => live.sim.match.shared_bucket_hits,
        "turns" => turns, "completed" => live.sim.match.game_over,
        "termination_reason" => reason, "remaining_balls" => live.sim.match.players[1].balls,
        "remaining_pegs" => length(live.sim.engine.pegs))
    return (; result, timings = (; phases = Instrument ? phases : nothing, setup_seconds, decision_seconds = latencies, candidates))
end

function run_campaign(level::LevelDefinition, config::SimConfig, o::CampaignOptions;
                      parallel::Bool = true, phase_instrumentation::Bool = true)
    validate_campaign(o)
    workers = min(o.workers, o.games)
    parallel && Threads.nthreads() < workers && throw(ArgumentError("start Julia with at least $workers threads"))
    for i in 0:config.aim_discretization_steps
        angle = angle_for_index(i, config)
        snapped_aim_angle(angle, config) == angle || error("aim grid identity failed at $i")
    end
    provenance = merge(campaign_provenance(level), (; config_sha256 = config.source_sha256))
    initial = build_checkpoint(level, config; mode = o.mode, provenance)
    results = Vector{Any}(undef, o.games)
    if parallel
        @sync for worker in 1:workers
            Threads.@spawn for game in worker:workers:o.games
                results[game] = run_bot_game(initial, level, config, o, game, Val(phase_instrumentation))
            end
        end
    else
        for game in 1:o.games
            results[game] = run_bot_game(initial, level, config, o, game, Val(phase_instrumentation))
        end
    end
    return (; games = [r.result for r in results], timings = [r.timings for r in results])
end
