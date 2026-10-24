# MVP solo campaigns. The shot engine owns physics; this layer ports the solo
# callbacks/end-turn/resetTurn rules from the frozen src/states/game.lua.
Base.@kwdef struct CampaignOptions
    games::Int = 3
    base_seed::Int = 20261024
    sector_size::Int = 100
    epsilon::Int = 1
    max_steps::Int = 3600
    max_turns::Int = 100
    workers::Int = 3
end

function validate_campaign(o::CampaignOptions)
    for name in (:games, :sector_size, :max_steps, :max_turns, :workers)
        getfield(o, name) > 0 || throw(ArgumentError("$name must be positive"))
    end
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

function solo_callbacks()
    return ShotCallbacks(
        on_bucket_catch = eng -> begin
            p = eng.sim.match.players[1]
            p.balls += 1
            p.bucket_hits += 1
            nothing
        end,
        on_style_shot = (eng, info) -> begin
            style = String(info["style"])
            eng.style_counts[style] = get(eng.style_counts, style, 0) + 1
            nothing
        end)
end

# Called once, only after a completed actual shot; no reset on truncated shots.
function finish_solo_turn!(eng::ShotEngine)
    eng.shot_done || throw(ArgumentError("cannot finish an incomplete shot"))
    m = eng.sim.match
    p = m.players[1]
    p.score += get_turn_score(eng)
    if !any(peg -> peg.peg_type === :red && !peg.hit, eng.sim.engine.pegs)
        m.game_over = true
        m.winner = 1
        return "all_red_cleared"
    elseif p.balls <= 0
        m.game_over = true
        m.winner = 1
        return "balls_exhausted"
    end
    return "continue"
end

function prepare_solo_turn!(eng::ShotEngine, provenance)
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

# Separate, deterministically derived bot seeds fit exactly in LoveRandom's
# Float64 constructor. Gameplay RNG starts from the same level seed in all games.
bot_seed(base::Int, game::Int) = Int(wang_hash64(UInt64(base) ⊻
    (UInt64(game) * UInt64(0x9e3779b97f4a7c15))) & UInt64(0x001fffffffffffff))

function evaluate_candidates!(eng::ShotEngine, ckpt::Checkpoint,
                              scores::Vector{Float64}, max_steps::Int)
    reset_ns = UInt64(0)
    simulation_ns = UInt64(0)
    incomplete = Int[]
    for i in 0:(length(scores)-1)
        t = time_ns()
        reset_shot_engine!(eng, ckpt)
        reset_ns += time_ns() - t
        t = time_ns()
        launch!(eng, i)
        run_shot!(eng; max_steps)
        scores[i+1] = get_turn_score(eng)
        simulation_ns += time_ns() - t
        eng.shot_done || push!(incomplete, i)
    end
    return (; reset_ns, simulation_ns, incomplete)
end

function run_solo_game(initial::Checkpoint, level::LevelDefinition, config::SimConfig,
                       o::CampaignOptions, game::Int)
    setup_start = time_ns()
    seed = bot_seed(o.base_seed, game)
    rng = LoveRandom(seed)
    live = shot_engine(initial; config, level, callbacks = solo_callbacks())
    candidate = shot_engine(initial; config, level, callbacks = solo_callbacks())
    scores = zeros(config.aim_discretization_steps + 1)
    prov = campaign_provenance(level)
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
        evaluated = evaluate_candidates!(candidate, ckpt, scores, o.max_steps)
        candidates += length(scores)
        phases["candidate_reset"] += evaluated.reset_ns / 1e9
        phases["simulation"] += evaluated.simulation_ns / 1e9
        if !isempty(evaluated.incomplete)
            push!(decisions, Dict("turn" => turn, "incomplete_candidates" => evaluated.incomplete))
            reason = "candidate_step_limit"
            push!(latencies, (time_ns() - start) / 1e9)
            break
        end
        t = time_ns()
        decision = select_sector_shot(scores, o.sector_size, rng)
        index = decision["intended_index"]::Int
        offset = execution_offset!(rng, index, o.epsilon, config.aim_discretization_steps)
        decision["offset"] = offset
        decision["executed_index"] = index + offset
        decision["turn"] = turn
        phases["selection"] += (time_ns() - t) / 1e9
        t = time_ns()
        # Live is still the original decision state: evaluations touched only candidate.
        next_ball_id_before = live.sim.engine.next_ball_id
        live.sim.match.players[1].balls -= 1
        launch!(live, index + offset)
        run_shot!(live; max_steps = o.max_steps)
        turns += 1
        summary = shot_summary(live)
        decision["shot"] = Dict(string(k) => v for (k, v) in pairs(summary))
        # The single-shot summary assumes IDs start at one; campaigns retain IDs.
        decision["shot"]["spawned"] = live.sim.engine.next_ball_id - next_ball_id_before
        decision["style_counts"] = copy(live.style_counts)
        reason = live.shot_done ? finish_solo_turn!(live) : "actual_step_limit"
        decision["remaining_balls"] = live.sim.match.players[1].balls
        decision["remaining_pegs"] = length(live.sim.engine.pegs)
        decision["remaining_red_pegs"] = count(p -> p.peg_type === :red && !p.hit, live.sim.engine.pegs)
        decision["gameplay_rng_state"] = get_state(live.sim.rng)
        decision["bot_rng_state"] = get_state(rng)
        push!(decisions, decision)
        phases["actual_shot"] += (time_ns() - t) / 1e9
        if reason == "continue" && turn < o.max_turns
            t = time_ns()
            ckpt = prepare_solo_turn!(live, prov)
            phases["checkpoint"] += (time_ns() - t) / 1e9
        end
        push!(latencies, (time_ns() - start) / 1e9)
        reason == "continue" || break
        reason = "turn_limit"
    end
    result = Dict("game" => game, "base_seed" => o.base_seed, "bot_seed" => seed,
        "gameplay_seed" => initial.rng.seed, "initial_gameplay_rng_state" => initial.rng.state_b64,
        "final_gameplay_rng_state" => get_state(live.sim.rng), "final_bot_rng_state" => get_state(rng),
        "decisions" => decisions, "final_score" => live.sim.match.players[1].score,
        "turns" => turns, "completed" => live.sim.match.game_over,
        "termination_reason" => reason, "remaining_balls" => live.sim.match.players[1].balls,
        "remaining_pegs" => length(live.sim.engine.pegs))
    return (; result, timings = (; phases, setup_seconds, decision_seconds = latencies, candidates))
end

function run_campaign(level::LevelDefinition, config::SimConfig, o::CampaignOptions;
                      parallel::Bool = true)
    validate_campaign(o)
    workers = min(o.workers, o.games)
    parallel && Threads.nthreads() < workers && throw(ArgumentError("start Julia with at least $workers threads"))
    for i in 0:config.aim_discretization_steps
        angle = angle_for_index(i, config)
        snapped_aim_angle(angle, config) == angle || error("aim grid identity failed at $i")
    end
    initial = build_checkpoint(level, config; provenance = campaign_provenance(level))
    results = Vector{Any}(undef, o.games)
    if parallel
        @sync for worker in 1:workers
            Threads.@spawn for game in worker:workers:o.games
                results[game] = run_solo_game(initial, level, config, o, game)
            end
        end
    else
        for game in 1:o.games
            results[game] = run_solo_game(initial, level, config, o, game)
        end
    end
    return (; games = [r.result for r in results], timings = [r.timings for r in results])
end
