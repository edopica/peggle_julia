#!/usr/bin/env julia
# Emit the M2 math census result summary (WP-E).
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/math_census.jl \
#       --fixture fixtures/math_census/math_census.v1.json \
#       --out results/m2-math-census.json
#
# Reads the fixture captured by tools/capture_math_census.lua, recomputes every
# case with DetMath (system libm on Linux) and, as a diagnostic, with the Julia
# Base (openlibm) functions. The output is canonical JSON: per-function case
# counts, system-libm mismatches (must be 0), openlibm divergence counts, and
# SHA-256 digests of the fixture and of its expected section. The process exits
# nonzero when any system-libm mismatch is found.

using PeggleSim
using PeggleSim.DetMath
import JSON

const DEFAULT_FIXTURE = "fixtures/math_census/math_census.v1.json"
const DEFAULT_OUT = "results/m2-math-census.json"

const UNARY_SPECS = [
    (name = "sin", det = det_sin, openlibm = Base.sin),
    (name = "cos", det = det_cos, openlibm = Base.cos),
    (name = "atan", det = det_atan, openlibm = Base.atan),
    (name = "asin", det = det_asin, openlibm = Base.asin),
    (name = "exp", det = det_exp, openlibm = Base.exp),
    (name = "log", det = det_log, openlibm = Base.log),
    (name = "sqrt", det = det_sqrt, openlibm = Base.sqrt),
]

const BINARY_SPECS = [
    (name = "atan2", a = "atan2_y", b = "atan2_x",
        det = (y, x) -> det_atan2(y, x),
        openlibm = (y, x) -> Base.atan(y, x)),
    (name = "pow", a = "pow_a", b = "pow_b",
        det = (a, b) -> det_pow(a, b),
        openlibm = (a, b) -> Base.:^(a, b)),
    (name = "mod", a = "mod_a", b = "mod_b",
        det = (a, b) -> lua_mod(a, b),
        openlibm = (a, b) -> a - floor(a / b) * b),
]

function parse_args(argv)
    opts = Dict{String,String}(
        "fixture" => DEFAULT_FIXTURE, "out" => DEFAULT_OUT)
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--fixture" || a == "--out"
            i += 1
            i <= length(argv) || error("missing value for $(a)")
            opts[a[3:end]] = argv[i]
        elseif a == "--help" || a == "-h"
            println("usage: math_census.jl [--fixture PATH] [--out PATH]")
            exit(0)
        else
            error("unknown argument: $(a)")
        end
        i += 1
    end
    return opts
end

# openlibm throws DomainError where the system libm returns a NaN bit pattern
# (e.g. asin outside [-1, 1]); treat that as a divergence (diagnostic only).
function base_bits(f, args...)
    try
        return float_bits_hex(f(args...))
    catch err
        err isa DomainError || rethrow()
        return nothing
    end
end

function check_unary(xs, want, detfn, basefn)
    mismatches = 0
    divergences = 0
    for i in eachindex(xs)
        x = Float64(xs[i])
        expected = String(want[i])
        float_bits_hex(detfn(x)) != expected && (mismatches += 1)
        base_bits(basefn, x) != expected && (divergences += 1)
    end
    return length(xs), mismatches, divergences
end

function check_binary(as, bs, want, detfn, basefn)
    mismatches = 0
    divergences = 0
    for i in eachindex(as)
        a = Float64(as[i])
        b = Float64(bs[i])
        expected = String(want[i])
        float_bits_hex(detfn(a, b)) != expected && (mismatches += 1)
        base_bits(basefn, a, b) != expected && (divergences += 1)
    end
    return length(as), mismatches, divergences
end

math_backend_object() = PeggleSim.DetMath.math_backend_identity_dict()

function main(argv)
    opts = parse_args(argv)
    fixture_path = opts["fixture"]
    out_path = opts["out"]

    isfile(fixture_path) ||
        error("math census fixture not found: $(fixture_path); " *
              "run scripts/capture_math_census.sh first")

    # inttype=Float64 keeps the sign of bare `-0` from the canonical text.
    fixture = JSON.parsefile(fixture_path; inttype = Float64)
    @assert fixture["format"] == "peggle.math_census"
    inputs = fixture["inputs"]
    expected = fixture["expected"]
    counts = fixture["counts"]

    system_mismatches = 0
    system_checked = 0
    openlibm = Dict{String,Any}()
    openlibm_total = 0
    openlibm_checked = 0

    for spec in UNARY_SPECS
        checked, mismatches, divergences = check_unary(
            inputs[spec.name], expected[spec.name], spec.det, spec.openlibm)
        system_mismatches += mismatches
        system_checked += checked
        openlibm[spec.name] = divergences
        openlibm_total += divergences
        openlibm_checked += checked
    end
    for spec in BINARY_SPECS
        checked, mismatches, divergences = check_binary(
            inputs[spec.a], inputs[spec.b], expected[spec.name],
            spec.det, spec.openlibm)
        system_mismatches += mismatches
        system_checked += checked
        openlibm[spec.name] = divergences
        openlibm_total += divergences
        openlibm_checked += checked
    end

    summary = Dict{String,Any}(
        "format" => "peggle.math_census_results",
        "schema_version" => 1,
        "source" => fixture["source"],
        "fixture" => fixture_path,
        "fixture_sha256" => sha256_hex(read(fixture_path)),
        "expected_sha256" => sha256_hex(expected),
        "counts" => Dict(k => Int(v) for (k, v) in counts),
        "total_cases" => system_checked,
        "math_backend" => math_backend_object(),
        "system_libm" => Dict{String,Any}(
            "checked" => system_checked,
            "mismatches" => system_mismatches,
        ),
        "openlibm" => Dict{String,Any}(
            "checked" => openlibm_checked,
            "mismatches" => openlibm_total,
            "by_function" => openlibm,
        ),
    )

    dir = dirname(out_path)
    isempty(dir) || mkpath(dir)
    open(out_path, "w") do io
        write(io, canonical_json(summary))
        write(io, "\n")
    end

    println("math census summary: ", out_path)
    println("  fixture_sha256=", summary["fixture_sha256"])
    println("  total_cases=", system_checked,
            " system_libm_mismatches=", system_mismatches,
            " openlibm_mismatches=", openlibm_total)
    if system_mismatches != 0
        println("  ERROR: system libm mismatches must be 0")
        exit(1)
    end
    return nothing
end

main(ARGS)
