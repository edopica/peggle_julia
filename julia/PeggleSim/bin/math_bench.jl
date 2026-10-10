#!/usr/bin/env julia
# WP-F on-host math microbenchmark (Julia side).
#
# Mirrors tools/math_bench.lua: the same splitmix64 input generator (and the
# same inputs_checksum), the same warmup/batch schedule, and per-function
# per-call nanoseconds (median/p90/p99), raw batch times, a bit-exact output
# checksum, and Base.@allocated bytes for one call. Both engines measure
# their own dispatch (`PeggleSim.DetMath` here), so only within-engine
# system_libm/core_math ratios are meaningful; Lua-vs-Julia absolute costs
# are separate measurements.
#
# Usage:
#   PEGGLE_MATH_BACKEND=core_math PEGGLE_MATH_LIB=/path/libpeggle_math.so \
#     julia --project=julia/PeggleSim julia/PeggleSim/bin/math_bench.jl \
#       --out tmp/core-math/perf/math-bench-julia-core_math.json

using PeggleSim
using PeggleSim.DetMath
using Printf

const N_INPUTS = 4096
const WARMUP_CALLS = 4096
const CALLS_PER_BATCH = 8192
const BATCH_COUNT = 21

const SINK = Ref(0.0)

mutable struct SplitMix64
    state::UInt64
end

function next_u64!(rng::SplitMix64)::UInt64
    rng.state += 0x9E3779B97F4A7C15
    z = rng.state
    z ⊻= z >> 30
    z *= 0xBF58476D1CE4E5B9
    z ⊻= z >> 27
    z *= 0x94D049BB133111EB
    return z ⊻ (z >> 31)
end

next_unit(rng::SplitMix64)::Float64 = Float64(next_u64!(rng) >> 11) * 0x1.0p-53

function parse_args(argv)
    opts = Dict{String,String}()
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--out"
            i += 1
            i <= length(argv) || error("missing value for $(a)")
            opts["out"] = argv[i]
        elseif a == "--help" || a == "-h"
            println("usage: math_bench.jl --out PATH")
            exit(0)
        else
            error("unknown argument: $(a)")
        end
        i += 1
    end
    return opts
end

function percentile(sorted::Vector{Float64}, q::Float64)::Float64
    n = length(sorted)
    n > 0 || return 0.0
    idx = clamp(ceil(Int, q * n), 1, n)
    return sorted[idx]
end

function build_inputs()
    rng = SplitMix64(0x9E3779B97F4A7C15)
    inputs = Vector{Float64}(undef, N_INPUTS)
    for i in 1:N_INPUTS
        e = Int(floor(next_unit(rng) * 25.0)) - 12
        s = next_unit(rng)
        inputs[i] = (2.0 * s - 1.0) * ldexp(1.0, e)
    end
    inputs[1] = 0.0
    inputs[2] = -0.0
    inputs[3] = 0.5
    inputs[4] = -0.5
    inputs[5] = 1.0
    inputs[6] = -1.0
    inputs[7] = 3.141592653589793
    inputs[8] = -3.141592653589793
    inputs[9] = 1.0e9
    inputs[10] = -1.0e9
    inputs[11] = 1.0e-9
    inputs[12] = -1.0e-9

    unit_in = Vector{Float64}(undef, N_INPUTS)
    exp_in = Vector{Float64}(undef, N_INPUTS)
    log_in = Vector{Float64}(undef, N_INPUTS)
    pow_b = Vector{Float64}(undef, N_INPUTS)
    for i in 1:N_INPUTS
        unit_in[i] = 2.0 * next_unit(rng) - 1.0
    end
    for i in 1:N_INPUTS
        exp_in[i] = 40.0 * next_unit(rng) - 20.0
    end
    for i in 1:N_INPUTS
        e = Int(floor(next_unit(rng) * 19.0)) - 9
        log_in[i] = ldexp(1.0, e) * (1.0 + next_unit(rng))
    end
    for i in 1:N_INPUTS
        pow_b[i] = 6.0 * next_unit(rng) - 3.0
    end

    sqrt_in = Vector{Float64}(undef, N_INPUTS)
    atan2_x = Vector{Float64}(undef, N_INPUTS)
    mod_b = Vector{Float64}(undef, N_INPUTS)
    for i in 1:N_INPUTS
        sqrt_in[i] = abs(inputs[i])
        atan2_x[i] = inputs[(i * 7 + 3) % N_INPUTS + 1]
        b = inputs[(i * 13 + 5) % N_INPUTS + 1]
        if b == 0.0 || b != b
            b = 1.5
        end
        mod_b[i] = b
    end

    acc = zero(UInt64)
    for x in inputs
        acc ⊻= reinterpret(UInt64, x)
    end
    for x in unit_in
        acc ⊻= reinterpret(UInt64, x)
    end
    for x in exp_in
        acc ⊻= reinterpret(UInt64, x)
    end
    for x in log_in
        acc ⊻= reinterpret(UInt64, x)
    end
    for x in pow_b
        acc ⊻= reinterpret(UInt64, x)
    end
    checksum = string(acc, base = 16, pad = 16)
    return (inputs = inputs, unit_in = unit_in, exp_in = exp_in,
            log_in = log_in, pow_b = pow_b, sqrt_in = sqrt_in,
            atan2_x = atan2_x, mod_b = mod_b,
            inputs_checksum = "0x" * checksum)
end

function run_unary(fn, xs::Vector{Float64})
    n = length(xs)
    checksum = zero(UInt64)
    sink = 0.0
    for k in 0:(WARMUP_CALLS - 1)
        y = fn(xs[k % n + 1])
        checksum ⊻= reinterpret(UInt64, y)
        sink += y
    end
    batches = Vector{Int}(undef, BATCH_COUNT)
    for b in 1:BATCH_COUNT
        start = time_ns()
        local_sink = 0.0
        k = 0
        while k < CALLS_PER_BATCH
            local_sink += fn(xs[k % n + 1])
            k += 1
        end
        batches[b] = Int(time_ns() - start)
        sink += local_sink
    end
    allocated = Base.@allocated fn(xs[1])
    SINK[] += sink
    return (batches = batches, checksum = checksum, allocated = allocated)
end

function run_binary(fn, xs::Vector{Float64}, ys::Vector{Float64})
    n = length(xs)
    checksum = zero(UInt64)
    sink = 0.0
    for k in 0:(WARMUP_CALLS - 1)
        i = k % n + 1
        y = fn(xs[i], ys[i])
        checksum ⊻= reinterpret(UInt64, y)
        sink += y
    end
    batches = Vector{Int}(undef, BATCH_COUNT)
    for b in 1:BATCH_COUNT
        start = time_ns()
        local_sink = 0.0
        k = 0
        while k < CALLS_PER_BATCH
            i = k % n + 1
            local_sink += fn(xs[i], ys[i])
            k += 1
        end
        batches[b] = Int(time_ns() - start)
        sink += local_sink
    end
    allocated = Base.@allocated fn(xs[1], ys[1])
    SINK[] += sink
    return (batches = batches, checksum = checksum, allocated = allocated)
end

function function_record(result)
    percall = sort([Float64(b) / CALLS_PER_BATCH for b in result.batches])
    return Dict{String,Any}(
        "ns_per_call" => Dict{String,Any}(
            "median" => percentile(percall, 0.50),
            "p90" => percentile(percall, 0.90),
            "p99" => percentile(percall, 0.99),
        ),
        "batches" => result.batches,
        "checksum" => "0x" * string(result.checksum, base = 16, pad = 16),
        "calls" => BATCH_COUNT * CALLS_PER_BATCH,
        "allocated_bytes" => Int(result.allocated),
        "total_ns" => sum(result.batches),
        "total_seconds" => sum(result.batches) / 1e9,
    )
end

function main(argv)
    opts = parse_args(argv)
    out_path = get(opts, "out", nothing)
    out_path === nothing && error("math_bench: --out is required")

    env_backend = get(ENV, "PEGGLE_MATH_BACKEND", "")
    expected = isempty(env_backend) ?
               (Sys.islinux() ? "system_libm" : "julia_base") : env_backend
    actual = String(PeggleSim.DetMath.MATH_BACKEND[])
    actual == expected || error(
        "math_bench: DetMath backend $(actual) does not match " *
        "PEGGLE_MATH_BACKEND=$(expected)")

    data = build_inputs()
    specs = Any[
        ("sin", run_unary(det_sin, data.inputs)),
        ("cos", run_unary(det_cos, data.inputs)),
        ("tan", run_unary(det_tan, data.inputs)),
        ("asin", run_unary(det_asin, data.unit_in)),
        ("acos", run_unary(det_acos, data.unit_in)),
        ("atan", run_unary(det_atan, data.inputs)),
        ("atan2", run_binary(det_atan2, data.inputs, data.atan2_x)),
        ("exp", run_unary(det_exp, data.exp_in)),
        ("log", run_unary(det_log, data.log_in)),
        ("pow", run_binary(det_pow, data.inputs, data.pow_b)),
        ("sqrt", run_unary(det_sqrt, data.sqrt_in)),
        ("mod", run_binary(lua_mod, data.inputs, data.mod_b)),
    ]

    per_function = Dict{String,Any}()
    total_seconds = 0.0
    for (name, result) in specs
        record = function_record(result)
        per_function[name] = record
        total_seconds += record["total_seconds"]
        println(rpad(name, 6),
                " median=", lpad(string(round(record["ns_per_call"]["median"];
                                               digits = 3)), 10),
                " ns/call  allocated=", record["allocated_bytes"],
                " B  checksum=", record["checksum"])
    end

    document = Dict{String,Any}(
        "format" => "peggle.math_bench",
        "schema_version" => 1,
        "engine" => "julia",
        "backend" => String(PeggleSim.DetMath.MATH_BACKEND[]),
        "identity" => PeggleSim.DetMath.math_backend_identity_dict(),
        "input_count" => N_INPUTS,
        "inputs_checksum" => data.inputs_checksum,
        "warmup_calls" => WARMUP_CALLS,
        "calls_per_batch" => CALLS_PER_BATCH,
        "batch_count" => BATCH_COUNT,
        "measured_calls_per_function" => BATCH_COUNT * CALLS_PER_BATCH,
        "total_seconds" => total_seconds,
        "per_function" => per_function,
    )

    dir = dirname(out_path)
    isempty(dir) || mkpath(dir)
    open(out_path, "w") do io
        write(io, canonical_json(document))
        write(io, "\n")
    end
    println("math_bench: engine=julia backend=", document["backend"],
            " sink=", SINK[])
    println("math_bench: wrote ", out_path)
    return nothing
end

main(ARGS)
