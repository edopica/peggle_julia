#!/usr/bin/env julia
# Run from the repository root, on deathstar only. Extraction is outside measurement.
using PeggleSim

function evaluate!(eng, ckpt, aim)
    PeggleSim.reset_shot_engine!(eng, ckpt)
    PeggleSim.launch!(eng, aim)
    PeggleSim.run_shot!(eng; max_steps = 3600)
    return nothing
end

function check_result(eng, expected, aim)
    @assert eng.trace === nothing
    @assert PeggleSim.canonical_json(PeggleSim.shot_summary(eng)) == expected "Shot result changed for aim $aim"
    return nothing
end

function measure!(eng, ckpt, aim, samples, expected)
    bytes = zeros(Int, samples)
    elapsed = zeros(Int, samples)
    for i in 1:samples
        GC.gc()
        b0 = Base.gc_bytes()
        t0 = time_ns()
        evaluate!(eng, ckpt, aim)
        elapsed[i] = Int(time_ns() - t0)
        bytes[i] = Int(Base.gc_bytes() - b0)
        # Extraction and comparison occur after both counters stop.
        check_result(eng, expected, aim)
    end
    return bytes, elapsed
end

function stats(values)
    ordered = sort(values)
    return Dict("min" => first(ordered), "median" => ordered[cld(length(ordered), 2)],
                "max" => last(ordered), "mean" => sum(values) / length(values))
end

function main()
    strip(read(`hostname -s`, String)) == "deathstar" || error("Run this harness on deathstar")
    Threads.nthreads(:default) == 1 || error("Allocation accounting requires one thread")
    length(ARGS) in (2, 3) || error("usage: allocation_bench.jl OUT LABEL [BASELINE_JSON]")
    level_path = "fixtures/mustache/artifact/mustache.v1.json"
    config_path = "fixtures/mustache/config.dev.v1.json"
    level = PeggleSim.load_level(level_path)
    config = PeggleSim.load_config(config_path)
    ckpt = PeggleSim.build_checkpoint(level, config; balls = 1, mode = :solo,
        provenance = (reference_revision = level.provenance.reference_revision,
            reference_tree = level.provenance.reference_tree,
            config_sha256 = level.provenance.config_sha256, level_sha256 = level.level_sha256))
    eng = PeggleSim.shot_engine(ckpt; callbacks = PeggleSim.harness_callbacks(clearing = false),
        config = config, virtual_width = level.virtual_width, virtual_height = level.virtual_height)
    eng.trace = nothing
    aims = (900, 570)
    expected = Dict{Int,String}()
    for aim in aims
        for i in 1:5
            evaluate!(eng, ckpt, aim)
            if i == 1
                expected[aim] = PeggleSim.canonical_json(PeggleSim.shot_summary(eng))
            end
            check_result(eng, expected[aim], aim)
        end
    end
    measure!(eng, ckpt, 900, 1, expected[900]) # Compile the wrapper outside recorded samples.
    rows = Dict{String,Any}()
    for aim in aims
        bytes, ns = measure!(eng, ckpt, aim, 15, expected[aim])
        @assert eng.trace === nothing
        rows[string(aim)] = Dict("bytes" => stats(bytes), "nanoseconds" => stats(ns),
            "bytes_samples" => bytes, "nanoseconds_samples" => ns,
            "result_checks" => Dict("reference" => "first warmup result for this aim",
                "warmup_results_checked" => 5, "measured_results_checked" => 15,
                "wrapper_warmup_results_checked" => aim == 900 ? 1 : 0,
                "first_result_sha256" => PeggleSim.sha256_hex(expected[aim]),
                "all_identical" => true),
            "result" => PeggleSim.shot_summary(eng))
    end
    report = Dict{String,Any}(
        "format" => "peggle.allocation_bench.v2", "label" => ARGS[2],
        "julia_version" => string(VERSION), "cpu" => Sys.CPU_NAME,
        "kernel" => string(Sys.KERNEL), "workspace" => pwd(),
        "threads" => Threads.nthreads(:default), "interactive_threads" => Threads.nthreads(:interactive),
        "math_backend" => PeggleSim.DetMath.math_backend_identity_dict(),
        "level_sha256" => PeggleSim.sha256_hex(read(level_path)),
        "config_sha256" => PeggleSim.sha256_hex(read(config_path)),
        "harness_sha256" => PeggleSim.sha256_hex(read(@__FILE__)),
        "method" => "Base.gc_bytes and time_ns around reset+launch+run; no extraction; trace disabled; GC before each sample outside timed region",
        "result_validation" => "Every warmup, wrapper warmup, and measured result matches the first warmup result for its aim; canonical summary comparison outside measured region",
        "warmup_per_aim" => 5, "samples_per_aim" => 15,
        "balls" => 1, "clearing" => false, "max_steps" => 3600, "aims" => rows)
    if length(ARGS) == 3
        baseline = PeggleSim.load_json(ARGS[3])
        for field in ("format", "julia_version", "threads", "interactive_threads", "level_sha256", "config_sha256", "harness_sha256", "method", "result_validation")
            @assert baseline[field] == report[field] "Incompatible benchmark field: $field"
        end
        @assert PeggleSim.canonical_json(baseline["math_backend"]) == PeggleSim.canonical_json(report["math_backend"])
        comparison = Dict{String,Any}()
        for aim in string.(aims)
            old, new = baseline["aims"][aim], rows[aim]
            identical = PeggleSim.canonical_json(old["result"]) == PeggleSim.canonical_json(new["result"])
            @assert identical "Shot result changed for aim $aim"
            comparison[aim] = Dict("result_identical" => identical,
                "bytes_saved" => old["bytes"]["median"] - new["bytes"]["median"],
                "time_ratio" => new["nanoseconds"]["median"] / old["nanoseconds"]["median"])
        end
        report["comparison"] = comparison
    end
    mkpath(dirname(abspath(ARGS[1])))
    open(ARGS[1], "w") do io
        println(io, PeggleSim.canonical_json(report))
    end
    println(PeggleSim.canonical_json(report))
end

main()
