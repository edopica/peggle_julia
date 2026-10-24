#!/usr/bin/env julia
using PeggleSim
using JSON
using SHA

const ROOT = normpath(joinpath(@__DIR__, "../../.."))
function main(args)
    defaults = Dict("level" => "fixtures/ribbon_waves/artifact/ribbon_waves.v1.json",
        "config" => "fixtures/ribbon_waves/config.dev.v1.json", "games" => "3",
        "base-seed" => "20261024", "sector-size" => "100", "epsilon" => "1",
        "max-steps" => "3600", "max-turns" => "100", "workers" => "3",
        "repeats" => "3", "out" => "results/campaign/baseline.json")
    if "--help" in args
        println("julia --project=julia/PeggleSim -t 3 julia/PeggleSim/bin/campaign.jl [--NAME VALUE]")
        println("Warms full sequential/concurrent campaigns and output, then measures repeated campaigns; verifies identical histories.")
        for k in sort(collect(keys(defaults)))
            println("  --$k (default: $(defaults[k]))")
        end
        return
    end
    iseven(length(args)) || error("options require values; see --help")
    for i in 1:2:length(args)
        startswith(args[i], "--") || error("invalid option $(args[i])")
        key = args[i][3:end]
        haskey(defaults, key) || error("unknown option $(args[i])")
        defaults[key] = args[i+1]
    end
    num(k) = parse(Int, defaults[k])
    o = PeggleSim.CampaignOptions(games = num("games"), base_seed = num("base-seed"),
        sector_size = num("sector-size"), epsilon = num("epsilon"), max_steps = num("max-steps"),
        max_turns = num("max-turns"), workers = num("workers"))
    PeggleSim.validate_campaign(o)
    num("repeats") > 0 || error("repeats must be positive")
    Threads.nthreads() >= min(o.workers, o.games) || error("insufficient Julia threads")
    out = abspath(defaults["out"])
    mkpath(dirname(out))
    t = time_ns()
    levelpath = abspath(defaults["level"])
    configpath = abspath(defaults["config"])
    level = PeggleSim.load_level(levelpath)
    level.name == "ribbon_waves" || error("MVP campaign supports only ribbon_waves")
    config = PeggleSim.load_config(configpath)
    load_seconds = (time_ns() - t) / 1e9
    println("Warmup: full sequential campaign (excluded from measurements)")
    flush(stdout)
    t = time_ns()
    warmup = PeggleSim.run_campaign(level, config, o; parallel = false)
    println("Warmup: full concurrent campaign (excluded from measurements)")
    flush(stdout)
    parallel_warmup = PeggleSim.run_campaign(level, config, o; parallel = true)
    parallel_warmup.games == warmup.games || error("warmup gameplay/history mismatch")
    # Exercise the exact IOStream/pretty-print path used by measured output.
    mktemp() do path, io
        JSON.print(io, warmup, 2)
        println(io)
    end
    bytes2hex(sha256(PeggleSim.canonical_json(warmup.games)))
    warmup_seconds = (time_ns() - t) / 1e9
    trials = Any[]
    expected = warmup.games
    for repeat in 1:num("repeats")
        # Alternate order to reduce systematic thermal/order bias.
        for parallel in (isodd(repeat) ? (false, true) : (true, false))
            GC.gc()
            t = time_ns()
            run = PeggleSim.run_campaign(level, config, o; parallel)
            simulation_end = time_ns()
            run.games == expected || error("gameplay/history mismatch: repeat $repeat parallel=$parallel")
            mode = parallel ? "parallel" : "sequential"
            historypath = joinpath(dirname(out), "$(splitext(basename(out))[1])-$mode-$repeat.json")
            open(historypath, "w") do io
                JSON.print(io, run, 2)
                println(io)
            end
            finish = time_ns()
            seconds = (finish - t) / 1e9
            candidates = sum(r.candidates for r in run.timings)
            latency = sort(vcat([r.decision_seconds for r in run.timings]...))
            phases = Dict(k => sum(r.phases[k] for r in run.timings) for k in keys(run.timings[1].phases))
            completed = count(g -> g["completed"], run.games)
            rss = isfile("/proc/self/status") ? filter(l -> startswith(l, "VmRSS:") || startswith(l, "VmHWM:"), readlines("/proc/self/status")) : String[]
            trial = Dict("repeat" => repeat, "mode" => mode, "wall_seconds" => seconds,
                "campaign_setup_and_simulation_seconds" => (simulation_end - t) / 1e9,
                "verification_and_output_seconds" => (finish - simulation_end) / 1e9,
                "completed_games" => completed, "completed_games_per_hour" => completed * 3600 / seconds,
                "candidates" => candidates, "candidates_per_second" => candidates / seconds,
                "decision_mean_seconds" => sum(latency) / length(latency),
                "decision_p50_seconds" => latency[cld(length(latency),2)],
                "decision_p95_seconds" => latency[ceil(Int, 0.95 * length(latency))],
                "phase_worker_seconds" => phases, "process_memory" => rss,
                "process_peak_rss_bytes" => Sys.maxrss(), "history" => relpath(historypath, ROOT),
                "gameplay_sha256" => bytes2hex(sha256(PeggleSim.canonical_json(run.games))))
            push!(trials, trial)
            println("$mode repeat=$repeat wall=$(round(seconds;digits=3))s completed=$completed candidates=$candidates")
            flush(stdout)
        end
    end
    report = Dict("options" => defaults, "level_sha256" => bytes2hex(sha256(read(levelpath))),
        "config_sha256" => bytes2hex(sha256(read(configpath))),
        "candidate_count" => config.aim_discretization_steps + 1,
        "source_sha256" => Dict(relpath(p, ROOT) => bytes2hex(sha256(read(p))) for p in
            [@__FILE__, joinpath(ROOT, "julia/PeggleSim/src/campaign.jl"),
             joinpath(ROOT, "julia/PeggleSim/Manifest.toml")]),
        "timing_boundary" => "wall includes checkpoint/grid validation, worker and engine setup, all decisions, history identity verification and history JSON output/close; excludes process startup, one-time artifact load, GC before trial, warmup, final aggregate report write; load_seconds reported separately",
        "memory_boundary" => "process RSS sampled after history output; peak RSS is cumulative across warmup and all trials, not isolated per trial",
        "timestamp_utc" => strip(read(`date -u +%Y-%m-%dT%H:%M:%SZ`, String)),
        "load_seconds" => load_seconds, "warmup_seconds" => warmup_seconds,
        "identity_verified" => true, "trials" => trials,
        "environment" => Dict("julia" => string(VERSION), "threads" => Threads.nthreads(),
            "cpu" => Sys.CPU_NAME, "cpu_threads" => Sys.CPU_THREADS, "kernel" => string(Sys.KERNEL),
            "machine" => Sys.MACHINE, "total_memory_bytes" => Sys.total_memory(),
            "git_revision" => strip(read(`git -C $ROOT rev-parse HEAD`, String)),
            "git_status" => read(`git -C $ROOT status --short`, String),
            "cpu_info" => isfile("/proc/cpuinfo") ? first(filter(l -> startswith(l,"model name"), readlines("/proc/cpuinfo"))) : "unavailable",
            "command" => "julia --project=julia/PeggleSim -t $(Threads.nthreads()) julia/PeggleSim/bin/campaign.jl " * join(args," ")))
    open(out, "w") do io
        JSON.print(io, report, 2)
        println(io)
    end
    println("Saved $out")
end
main(ARGS)
