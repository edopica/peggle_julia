#!/usr/bin/env julia
# WP-D1: compare one backend's Lua results against the Julia engine and the
# independent oracle.
#
# Usage:
#   PEGGLE_MATH_BACKEND=core_math julia --project=julia/PeggleSim \
#     julia/PeggleSim/bin/wpd_compare.jl \
#     --inputs tmp/core-math/wpd-inputs.json \
#     --lua tmp/core-math/wpd-lua-core_math.json \
#     --out tmp/core-math/wpd-compare-core_math.json \
#     --expect-backend core_math
#
# Checks, for every function section and every special entry:
#   1. engine: the Julia backend's bits equal the Lua result string exactly
#      (including NaN payload and sign);
#   2. oracle: non-NaN oracle bits must match exactly; a NaN oracle is checked
#      by class and sign, with sign and payload differences counted
#      informationally (CORE-MATH and glibc do not promise identical NaN
#      payloads or signs for domain errors);
#   3. special: both engines must produce the contract's explicit expected bits
#      exactly.
#
# The correctness oracle is enforced for `core_math`: CORE-MATH is the
# correctly rounded component and any deviation fails the run. `system_libm`
# is the historical control and is known not to be correctly rounded; its
# deviations from the oracle are recorded (`oracle.mismatches`,
# `oracle.enforced = false`) but do not fail the comparator. All other checks
# fail for every backend.
#
# Output is canonical JSON with the comparison summary; see the plan section
# 1.3. The process exits nonzero on any engine mismatch, oracle mismatch for
# core_math, undecided index, or special mismatch. `mod` is evaluated with
# PeggleSim.DetMath.lua_mod (the same IEEE expression as Lua `%`).

using PeggleSim
using PeggleSim.DetMath
import JSON

const UNARY_FNS = Dict{String,Function}(
    "sin" => det_sin,
    "cos" => det_cos,
    "tan" => det_tan,
    "asin" => det_asin,
    "acos" => det_acos,
    "atan" => det_atan,
    "exp" => det_exp,
    "log" => det_log,
    "sqrt" => det_sqrt,
)

const BINARY_FNS = Dict{String,Function}(
    "atan2" => (a, b) -> det_atan2(a, b),
    "pow" => (a, b) -> det_pow(a, b),
    "mod" => (a, b) -> lua_mod(a, b),
)

parse_bithex(s::AbstractString)::UInt64 = parse(UInt64, s[3:end], base = 16)

canonical_backend(name::AbstractString)::String =
    name == "openlibm" ? "julia_base" : String(name)

function parse_args(argv)
    opts = Dict{String,String}()
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a in ("--inputs", "--lua", "--out", "--expect-backend")
            i += 1
            i <= length(argv) || error("missing value for $(a)")
            opts[a[3:end]] = argv[i]
        elseif a == "--help" || a == "-h"
            println("usage: wpd_compare.jl --inputs PATH --lua PATH --out PATH " *
                    "--expect-backend NAME")
            exit(0)
        else
            error("unknown argument: $(a)")
        end
        i += 1
    end
    for key in ("inputs", "lua", "out", "expect-backend")
        haskey(opts, key) || error("missing required argument --$(key)")
    end
    return opts
end

function mismatch_object(fn::String, index::Int, a::String, b, expected::String,
                         got::String)
    return Dict{String,Any}(
        "function" => fn,
        "index" => index,
        "a" => a,
        "b" => b,
        "expected" => expected,
        "got" => got,
    )
end

function main(argv)
    opts = parse_args(argv)
    inputs_path = opts["inputs"]
    lua_path = opts["lua"]
    out_path = opts["out"]
    expect_backend = canonical_backend(opts["expect-backend"])

    actual_backend = String(MATH_BACKEND[])
    actual_backend == expect_backend || error(
        "DetMath backend is $(actual_backend) but --expect-backend " *
        "$(opts["expect-backend"]) was requested (canonical " *
        "$(expect_backend)); set PEGGLE_MATH_BACKEND before Julia starts")
    oracle_enforced = actual_backend == "core_math"

    input_bytes = read(inputs_path)
    input_sha = sha256_hex(input_bytes)
    inputs = JSON.parsefile(inputs_path)
    inputs["format"] == "peggle.wpd_math_inputs" ||
        error("unexpected inputs format: $(inputs["format"])")

    lua = JSON.parsefile(lua_path)
    lua["format"] == "peggle.wpd_math_results" ||
        error("unexpected Lua results format: $(lua["format"])")
    String(lua["backend"]) == actual_backend || error(
        "Lua results were produced with backend $(lua["backend"]) but the " *
        "Julia backend is $(actual_backend)")
    String(lua["inputs_sha256"]) == input_sha || error(
        "inputs_sha256 mismatch: Lua $(lua["inputs_sha256"]) vs file " *
        "$(input_sha); regenerate the Lua results")

    engine_checked = 0
    engine_mismatches = 0
    oracle_checked = 0
    oracle_mismatches = 0
    nan_sign_mismatches = 0
    nan_payload_differences = 0
    undecided_count = 0
    first_engine = nothing
    first_oracle = nothing
    by_function = Dict{String,Any}()

    function_names = sort!(collect(keys(inputs["cases"])))
    for fn in function_names
        section = inputs["cases"][fn]
        arity = Int(section["arity"])
        as = section["a"]
        bs = get(section, "b", nothing)
        lua_results = lua["results"][fn]
        oracle_bits = inputs["oracle"][fn]
        undecided_idx = get(inputs["oracle_undecided"], fn, Any[])
        length(lua_results) == length(as) ||
            error("Lua result count mismatch for $(fn): " *
                  "$(length(lua_results)) vs $(length(as))")
        length(oracle_bits) == length(as) ||
            error("oracle count mismatch for $(fn)")
        fn_engine_mismatches = 0
        fn_oracle_mismatches = 0
        fn_undecided = length(undecided_idx)
        undecided_count += fn_undecided
        for i in eachindex(as)
            a = parse_bithex(as[i])
            got = if arity == 2
                b = parse_bithex(bs[i])
                BINARY_FNS[fn](reinterpret(Float64, a), reinterpret(Float64, b))
            else
                UNARY_FNS[fn](reinterpret(Float64, a))
            end
            got_hex = float_bits_hex(got)
            lua_hex = String(lua_results[i])
            engine_checked += 1
            if got_hex != lua_hex
                engine_mismatches += 1
                fn_engine_mismatches += 1
                if first_engine === nothing
                    first_engine = mismatch_object(fn, i, String(as[i]),
                        bs === nothing ? nothing : String(bs[i]),
                        lua_hex, got_hex)
                end
            end
            oracle = parse_bithex(oracle_bits[i])
            oracle_checked += 1
            oracle_float = reinterpret(Float64, oracle)
            if isnan(oracle_float)
                if !isnan(got)
                    oracle_mismatches += 1
                    fn_oracle_mismatches += 1
                    if first_oracle === nothing
                        first_oracle = mismatch_object(fn, i, String(as[i]),
                            bs === nothing ? nothing : String(bs[i]),
                            String(oracle_bits[i]), got_hex)
                    end
                else
                    signbit(oracle_float) == signbit(got) ||
                        (nan_sign_mismatches += 1)
                    (oracle & 0x000fffffffffffff) ==
                        (reinterpret(UInt64, got) & 0x000fffffffffffff) ||
                        (nan_payload_differences += 1)
                end
            elseif reinterpret(UInt64, got) != oracle
                oracle_mismatches += 1
                fn_oracle_mismatches += 1
                if first_oracle === nothing
                    first_oracle = mismatch_object(fn, i, String(as[i]),
                        bs === nothing ? nothing : String(bs[i]),
                        String(oracle_bits[i]), got_hex)
                end
            end
        end
        by_function[fn] = Dict{String,Any}(
            "cases" => length(as),
            "engine_mismatches" => fn_engine_mismatches,
            "oracle_mismatches" => fn_oracle_mismatches,
            "undecided" => fn_undecided,
        )
    end

    special_checked = 0
    special_mismatches = 0
    first_special = nothing
    specials = inputs["special"]
    lua_special = lua["special_results"]
    length(lua_special) == length(specials) ||
        error("special_results count mismatch")
    for (i, sp) in enumerate(specials)
        fn = String(sp["fn"])
        a = parse_bithex(sp["a"])
        b = sp["b"] === nothing ? nothing : parse_bithex(sp["b"])
        got = if b === nothing
            UNARY_FNS[fn](reinterpret(Float64, a))
        else
            BINARY_FNS[fn](reinterpret(Float64, a), reinterpret(Float64, b))
        end
        got_hex = float_bits_hex(got)
        expected = String(sp["expected"])
        lua_hex = String(lua_special[i]["result"])
        String(lua_special[i]["name"]) == String(sp["name"]) ||
            error("special_results order mismatch at $(i): " *
                  "$(lua_special[i]["name"]) vs $(sp["name"])")
        special_checked += 1
        if got_hex != expected || lua_hex != expected
            special_mismatches += 1
            if first_special === nothing
                first_special = mismatch_object(fn, i, String(sp["a"]),
                    sp["b"] === nothing ? nothing : String(sp["b"]),
                    expected, got_hex)
                first_special["name"] = String(sp["name"])
            end
        end
    end

    summary = Dict{String,Any}(
        "format" => "peggle.wpd_math_comparison",
        "schema_version" => 1,
        "backend" => actual_backend,
        "input_sha256" => input_sha,
        "lua_sha256" => sha256_hex(read(lua_path)),
        "counts" => Dict{String,Any}(
            "cases" => engine_checked,
            "specials" => special_checked,
            "by_function" => Dict{String,Any}(
                fn => by_function[fn]["cases"] for fn in function_names),
        ),
        "engine" => Dict{String,Any}(
            "checked" => engine_checked,
            "mismatches" => engine_mismatches,
            "first_mismatch" => first_engine,
        ),
        "oracle" => Dict{String,Any}(
            "checked" => oracle_checked,
            "mismatches" => oracle_mismatches,
            "enforced" => oracle_enforced,
            "note" => oracle_enforced ?
                "core_math must be correctly rounded; mismatches fail the run" :
                "system_libm is the historical control; oracle deviations are recorded, not failures",
            "undecided" => undecided_count,
            "nan_sign_mismatches" => nan_sign_mismatches,
            "nan_payload_differences" => nan_payload_differences,
        ),
        "special" => Dict{String,Any}(
            "checked" => special_checked,
            "mismatches" => special_mismatches,
            "first_mismatch" => first_special,
        ),
        "by_function" => by_function,
    )

    dir = dirname(out_path)
    isempty(dir) || mkpath(dir)
    open(out_path, "w") do io
        write(io, canonical_json(summary))
        write(io, "\n")
    end

    println("wpd_compare: backend=", actual_backend,
            " cases=", engine_checked,
            " specials=", special_checked,
            " engine_mismatches=", engine_mismatches,
            " oracle_mismatches=", oracle_mismatches,
            " oracle_enforced=", oracle_enforced,
            " special_mismatches=", special_mismatches,
            " undecided=", undecided_count,
            " nan_sign_mismatches=", nan_sign_mismatches,
            " nan_payload_differences=", nan_payload_differences)
    if first_engine !== nothing
        println("  first engine mismatch: ", first_engine)
    end
    if first_oracle !== nothing
        println("  first oracle mismatch: ", first_oracle)
    end
    if first_special !== nothing
        println("  first special mismatch: ", first_special)
    end

    failures = engine_mismatches + special_mismatches + undecided_count +
               (oracle_enforced ? oracle_mismatches : 0)
    if failures != 0
        println("  ERROR: comparison failed")
        exit(1)
    end
    if !oracle_enforced && oracle_mismatches != 0
        println("  note: recorded ", oracle_mismatches,
                " historical-backend deviations from the correctly rounded oracle")
    end
    return nothing
end

main(ARGS)
