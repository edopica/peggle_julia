#!/usr/bin/env julia
# Paired, interleaved layout/reset experiment. Run from the compact checkout.
# Usage: julia --project=julia/PeggleSim -t 8,0 --gcthreads=1 \
#   scripts/bench_prepared_checkpoint.jl BASELINE_ROOT PREPARED_ROOT OUT [WORKERS] [REPEATS]
# PREPARED_ROOT is the same candidate source with the candidate loop's reset
# call changed to reset_shot_engine!(eng, prepared; compact=false).
# Three isolated modules let warmed variants alternate in one process. This
# measures elapsed time, allocated bytes and GC; shared-process RSS cannot
# establish per-variant memory footprints. No profiling in timed regions.
using JSON
using SHA
using Statistics

function load_variant(root, name)
    function rename_module(ex)
        if ex isa Expr && ex.head === :module
            ex.args[2] = name
        end
        return ex
    end
    Base.include(rename_module, Main, joinpath(root, "julia/PeggleSim/src/PeggleSim.jl"))
    return Base.invokelatest(getfield, Main, name)
end

function trial(M, level, config, options, expected, path)
    start = time_ns()
    run = M.run_campaign(level, config, options; parallel=options.workers > 1)
    simulation_end = time_ns()
    identical = expected === nothing || run.games == expected
    open(path, "w") do io
        JSON.print(io, run, 2)
        println(io)
    end
    identical || error("gameplay mismatch: $path")
    return (; run, wall_seconds=(time_ns()-start)/1e9,
        simulation_seconds=(simulation_end-start)/1e9)
end

function reset_probe(M, level, config, prepared)
    ckpt = M.build_checkpoint(level, config; provenance=M.campaign_provenance(level))
    eng = M.shot_engine(ckpt; config, level)
    t = time_ns()
    snapshot = prepared ? M.prepare_checkpoint(ckpt) : ckpt
    preparation_seconds = (time_ns()-t)/1e9
    reset() = prepared ? M.reset_shot_engine!(eng, snapshot;
        compact= nameof(M) === :CompactSim, static_geometry=true) : M.reset_shot_engine!(eng, snapshot)
    for _ in 1:10
        reset()
    end
    bytes, times = Int[], Float64[]
    for _ in 1:5
        GC.gc()
        timed = @timed for _ in 1:1801
            reset()
        end
        push!(bytes, timed.bytes)
        push!(times, timed.time)
    end
    # Warm stepping and then account only update!, excluding reset and launch.
    steps_bytes = Int[]
    for _ in 1:4
        reset()
        M.launch!(eng, 900)
        b = @allocated M.run_shot!(eng; max_steps=3600)
        push!(steps_bytes, b)
    end
    return (; preparation_seconds, resets_per_sample=1801,
        reset_allocated_bytes=bytes, reset_seconds=times,
        stepping_allocated_bytes=steps_bytes[2:end],
        snapshot_bytes=Base.summarysize(snapshot), worker_bytes=Base.summarysize(eng))
end

function main()
    3 <= length(ARGS) <= 5 || error("BASELINE_ROOT PREPARED_ROOT OUT [WORKERS] [REPEATS]")
    baseline, prepared, out = abspath.(ARGS[1:3])
    compact = dirname(@__DIR__)
    workers = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 8
    repeats = length(ARGS) >= 5 ? parse(Int, ARGS[5]) : 3
    1 <= workers <= Threads.nthreads(:default) || error("insufficient threads")
    repeats >= 3 || error("at least three repetitions required")
    ispath(out) && error("output already exists: $out")
    mkpath(out)
    roots = (baseline, prepared, compact)
    names = (:BaselineSim, :PreparedSim, :CompactSim)
    variants = [load_variant(root, name) for (root,name) in zip(roots,names)]
    # The modules have just been defined; enter their methods in the new world.
    Base.invokelatest(measure, variants, roots, out, workers, repeats)
end

function measure(variants, roots, out, workers, repeats)
    labels = ("baseline", "prepared", "compact")
    levelpath = "fixtures/ribbon_waves/artifact/ribbon_waves.v1.json"
    configpath = "campaigns/ribbon/config.v1.json"
    levels = [M.load_level(joinpath(root, levelpath)) for (M,root) in zip(variants,roots)]
    configs = [M.load_config(joinpath(root, configpath)) for (M,root) in zip(variants,roots)]
    options = [M.CampaignOptions(mode=Symbol("1v1"), games=10, workers=workers,
        base_seed=20261024) for M in variants]
    expected = nothing
    warmups, probes, rows = Any[], Any[], Any[]
    for i in 1:3
        println("warmup ", labels[i]); flush(stdout)
        timed = @timed trial(variants[i], levels[i], configs[i], options[i], expected,
                             joinpath(out, "warmup-$(labels[i]).json"))
        expected = timed.value.run.games
        push!(warmups, (; variant=labels[i], seconds=timed.time,
                         compile_seconds=timed.compile_time))
        push!(probes, reset_probe(variants[i], levels[i], configs[i], i > 1))
    end
    # Latin-square order: each variant occupies each order position once.
    for repeat in 1:repeats
        order = circshift([1,2,3], repeat-1)
        for (position,i) in enumerate(order)
            println("trial $repeat position $position ", labels[i]); flush(stdout)
            GC.gc()
            path = joinpath(out, "trial-$repeat-$(labels[i]).json")
            timed = @timed trial(variants[i], levels[i], configs[i], options[i], expected, path)
            value = timed.value
            completed = count(g -> g["completed"], value.run.games)
            candidates = sum(t.candidates for t in value.run.timings)
            completed == 10 || error("incomplete matches")
            candidates == 198110 || error("unexpected candidate count")
            canonical = variants[i].canonical_json(value.run.games)
            open(joinpath(out, "history-$repeat-$(labels[i]).json"), "w") do io
                write(io, canonical)
            end
            phases = Dict(k => sum(t.phases[k] for t in value.run.timings)
                for k in keys(first(value.run.timings).phases))
            row = (; variant=labels[i], repeat, position, workers,
                wall_seconds=value.wall_seconds, simulation_seconds=value.simulation_seconds,
                allocated_bytes=timed.bytes, gc_seconds=timed.gctime,
                compile_seconds=timed.compile_time, completed_matches=completed, candidates,
                gameplay_sha256=bytes2hex(sha256(canonical)), phases)
            push!(rows, row)
            println(JSON.json(row)); flush(stdout)
            open(joinpath(out, "trials.json"), "w") do io
                JSON.print(io, rows, 2); println(io)
            end
        end
    end
    @assert length(unique(r.gameplay_sha256 for r in rows)) == 1
    summary = Dict(label => (; median_seconds=median([r.wall_seconds for r in rows if r.variant==label]),
        min_seconds=minimum(r.wall_seconds for r in rows if r.variant==label),
        max_seconds=maximum(r.wall_seconds for r in rows if r.variant==label),
        median_allocated_bytes=median([r.allocated_bytes for r in rows if r.variant==label])) for label in labels)
    report = (; format="peggle.prepared_checkpoint_experiment.v1", julia_version=string(VERSION),
        host=gethostname(), cpu=Sys.CPU_NAME, threads=Threads.nthreads(:default),
        interactive_threads=Threads.nthreads(:interactive), workers, games=10, repeats,
        base_seed=20261024, warmup="one full ten-match campaign per variant",
        math_backend=variants[3].DetMath.math_backend_identity_dict(),
        workload_sha256=bytes2hex(sha256(read(levelpath))),
        config_sha256=bytes2hex(sha256(read(configpath))),
        method="Same-process isolated modules; GC outside each measurement; Latin-square order; phase clocks enabled; equality and JSON output included; hashing and reset probes excluded; allocation and GC from @timed; RSS not attributed",
        roots, warmups, reset_probes=Dict(zip(labels,probes)), trials=rows, summary)
    open(joinpath(out, "report.json"), "w") do io
        JSON.print(io, report, 2); println(io)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
