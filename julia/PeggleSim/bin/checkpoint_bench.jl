#!/usr/bin/env julia
# Checkpoint memory and reset benchmark on the real levels.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/checkpoint_bench.jl \
#       [--level NAME|all|PATH] [--out results/checkpoint-bench.json]
#       [--iterations 200] [--warmups 20]
#
# For every configuration (each real level with one ball, plus m1 with three
# balls, under the campaign config) the script times one setupLevel-equivalent
# build, then measures `capture_checkpoint` and `reset_worker!` over the
# requested iterations after warmups. It records per-iteration nanoseconds,
# `@allocated` per call and memory sizes. Output is canonical JSON with a
# date-free, host-free method block.
#
# The M2 version of this benchmark measured the pinned interchange levels and
# mapped them to the M0 Lua baseline workloads; that record is
# results/m2-checkpoint-bench.json (historical, not rewritten here). There is
# no M0 baseline for the real levels, so the `baseline` block always reports
# `present = false`.

using PeggleSim
import JSON

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const DEFAULT_OUT = joinpath(REPO_ROOT, "results", "checkpoint-bench.json")
const DEFAULT_ITERATIONS = 200
const DEFAULT_WARMUPS = 20

function parse_args(argv)
    opts = Dict{String,String}()
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--out", "--iterations", "--warmups", "--level")
            i += 1
            i <= length(argv) || error("missing value for $(arg)")
            opts[arg[3:end]] = argv[i]
        elseif arg == "--help" || arg == "-h"
            println("usage: checkpoint_bench.jl [--level NAME|all|PATH] [--out PATH] " *
                    "[--iterations N] [--warmups N]")
            println("  real levels: ", join(PeggleSim.RealLevels.NAMES, ", "),
                    " (default: all)")
            exit(0)
        else
            error("unknown argument: $(arg)")
        end
        i += 1
    end
    return opts
end

# (label, level name, level path, balls) rows for a --level value. `all` adds
# the three-ball m1 row, which exercises multi-ball checkpoints.
function _configurations(spec::AbstractString)
    rows = [(label, label, path, 1) for (label, path) in PeggleSim.RealLevels.resolve(spec)]
    if spec == "all"
        push!(rows, ("m1.multiball3", "m1", PeggleSim.RealLevels.artifact_path("m1"), 3))
    end
    return rows
end

function _percentile_us(ns::Vector{Int}, q::Float64)::Float64
    n = length(ns)
    n > 0 || return 0.0
    sorted = sort(ns)
    index = clamp(ceil(Int, q * n), 1, n)
    return sorted[index] / 1000.0
end

function _median(values::Vector{Float64})::Float64
    isempty(values) && return 0.0
    sorted = sort(values)
    return sorted[cld(length(sorted), 2)]
end

function _benchmark_configuration(cfg, level, config, provenance, iterations, warmups)
    # Untimed warmup: compile the build/capture/reset paths.
    warm_sim = PeggleSim.build_sim_state(level, config; balls = cfg.balls, mode = :solo)
    warm_ckpt = PeggleSim.capture_checkpoint(warm_sim; provenance = provenance)
    warm_worker = PeggleSim.make_worker(warm_ckpt)
    PeggleSim.test_advance!(warm_worker; steps = 3, rng_draws = 2, purple_promotions = 1)
    PeggleSim.reset_worker!(warm_worker, warm_ckpt)

    # One timed setupLevel-equivalent build.
    GC.gc()
    start = time_ns()
    sim = PeggleSim.build_sim_state(level, config; balls = cfg.balls, mode = :solo)
    build_ns = Int(time_ns() - start)
    ckpt = PeggleSim.capture_checkpoint(sim; provenance = provenance)
    worker = PeggleSim.make_worker(ckpt)

    capture_ns = Vector{Int}(undef, iterations)
    for _ in 1:warmups
        PeggleSim.capture_checkpoint(sim; provenance = provenance)
    end
    for i in 1:iterations
        start = time_ns()
        PeggleSim.capture_checkpoint(sim; provenance = provenance)
        capture_ns[i] = Int(time_ns() - start)
    end
    capture_alloc = Base.@allocated PeggleSim.capture_checkpoint(sim; provenance = provenance)

    reset_ns = Vector{Int}(undef, iterations)
    for _ in 1:warmups
        PeggleSim.reset_worker!(worker, ckpt)
    end
    for i in 1:iterations
        start = time_ns()
        PeggleSim.reset_worker!(worker, ckpt)
        reset_ns[i] = Int(time_ns() - start)
    end
    reset_alloc = Base.@allocated PeggleSim.reset_worker!(worker, ckpt)

    reset_p50 = _percentile_us(reset_ns, 0.50)
    build_us = build_ns / 1000.0
    return Dict{String,Any}(
        "configuration" => cfg.label,
        "level" => cfg.level,
        "balls" => cfg.balls,
        "pegs" => length(sim.engine.pegs),
        "build_us" => build_us,
        "capture" => Dict{String,Any}(
            "p50_us" => _percentile_us(capture_ns, 0.50),
            "p90_us" => _percentile_us(capture_ns, 0.90),
            "max_us" => _percentile_us(capture_ns, 1.00),
            "allocated_bytes" => capture_alloc,
            "nanoseconds" => capture_ns,
        ),
        "reset" => Dict{String,Any}(
            "p50_us" => reset_p50,
            "p90_us" => _percentile_us(reset_ns, 0.90),
            "max_us" => _percentile_us(reset_ns, 1.00),
            "allocated_bytes" => reset_alloc,
            "nanoseconds" => reset_ns,
        ),
        "memory" => Dict{String,Any}(
            "checkpoint_bytes" => Base.summarysize(ckpt),
            "scratch_bytes" => PeggleSim.scratch_bytes(worker.scratch),
            "worker_bytes" => Base.summarysize(worker),
        ),
        "reset_over_build" => build_us > 0.0 ? reset_p50 / build_us : 0.0,
    )
end

function main(argv)
    opts = parse_args(argv)
    out_path = get(opts, "out", DEFAULT_OUT)
    iterations = parse(Int, get(opts, "iterations", string(DEFAULT_ITERATIONS)))
    warmups = parse(Int, get(opts, "warmups", string(DEFAULT_WARMUPS)))
    iterations >= 200 || error("iterations must be >= 200, got $(iterations)")
    warmups >= 20 || error("warmups must be >= 20, got $(warmups)")

    config = PeggleSim.load_config(PeggleSim.RealLevels.config_path())

    results = []
    for (label, name, level_path, balls) in _configurations(get(opts, "level", "all"))
        level = PeggleSim.load_level(level_path)
        provenance = (
            reference_revision = String(level.provenance.reference_revision),
            reference_tree = String(level.provenance.reference_tree),
            config_sha256 = config.source_sha256,
            level_sha256 = String(level.level_sha256),
        )
        cfg = (label = label, level = name, balls = balls)
        result = _benchmark_configuration(
            cfg, level, config, provenance, iterations, warmups)
        push!(results, result)
        println("benchmarked ", cfg.label,
                ": build=", round(result["build_us"]; digits = 2), " us",
                " capture_p50=", round(result["capture"]["p50_us"]; digits = 2), " us",
                " reset_p50=", round(result["reset"]["p50_us"]; digits = 2), " us",
                " checkpoint=", result["memory"]["checkpoint_bytes"], " bytes")
    end

    build_us = Float64[r["build_us"] for r in results]
    capture_p50 = Float64[r["capture"]["p50_us"] for r in results]
    reset_p50 = Float64[r["reset"]["p50_us"] for r in results]
    summary = Dict{String,Any}(
        "configurations" => length(results),
        "build_us_median" => _median(build_us),
        "capture_p50_us_median" => _median(capture_p50),
        "reset_p50_us_median" => _median(reset_p50),
        "reset_over_build" => _median(build_us) > 0.0 ?
                              _median(reset_p50) / _median(build_us) : 0.0,
    )

    bench = Dict{String,Any}(
        "format" => "peggle.checkpoint_bench",
        "schema_version" => 1,
        "math_backend" => PeggleSim.DetMath.math_backend_identity_dict(),
        "method" => Dict{String,Any}(
            "iterations" => iterations,
            "warmups" => warmups,
            "build_samples" => 1,
            "timer" => "time_ns",
            "build_operation" => "build_sim_state (Engine:setupLevel equivalent)",
            "capture_operation" => "capture_checkpoint(sim; provenance)",
            "reset_operation" => "reset_worker!(worker, checkpoint)",
            "allocation_operation" => "Base.@allocated, one call per configuration",
            "date_free" => true,
            "host_data" => false,
        ),
        "results" => results,
        "summary" => summary,
        "config" => PeggleSim.RealLevels.CONFIG,
        "config_sha256" => config.source_sha256,
        "rules" => string(config.rules),
        "baseline" => Dict{String,Any}(
            "source" => nothing,
            "present" => false,
            "mapped" => Dict{String,Any}(),
        ),
    )

    dir = dirname(out_path)
    isempty(dir) || mkpath(dir)
    open(out_path, "w") do io
        write(io, canonical_json(bench))
        write(io, "\n")
    end
    println("checkpoint bench: ", out_path)
    println("  build_us_median=", round(summary["build_us_median"]; digits = 2),
            " capture_p50_us_median=", round(summary["capture_p50_us_median"]; digits = 2),
            " reset_p50_us_median=", round(summary["reset_p50_us_median"]; digits = 3),
            " reset_over_build=", round(summary["reset_over_build"]; digits = 5))
    return nothing
end

main(ARGS)
