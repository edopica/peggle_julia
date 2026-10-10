using Test
using Printf
using PeggleSim
using PeggleSim.DetMath
import JSON

# Cross-language math census (WP-E).
#
# fixtures/math_census/math_census.v1.json is captured from plain LuaJIT
# (system libm) by tools/capture_math_census.lua. Every expected value is the
# "0x%016x" IEEE-754 bit pattern of the LuaJIT result, so the strict contract
# is exact string equality between `float_bits_hex(det_f(input))` and the
# captured string, never a tolerance.
#
# The DetMath backend is authoritative. In addition, every case is recomputed
# with the Julia Base (openlibm) function purely as a diagnostic: the
# divergence counts are printed for the audit report and never fail the test.

const CENSUS_FIXTURE = normpath(joinpath(
    @__DIR__, "..", "..", "..", "fixtures", "math_census", "math_census.v1.json"))

const CENSUS_UNARY = [
    (name = "sin", det = det_sin, openlibm = Base.sin),
    (name = "cos", det = det_cos, openlibm = Base.cos),
    (name = "atan", det = det_atan, openlibm = Base.atan),
    (name = "asin", det = det_asin, openlibm = Base.asin),
    (name = "exp", det = det_exp, openlibm = Base.exp),
    (name = "log", det = det_log, openlibm = Base.log),
    (name = "sqrt", det = det_sqrt, openlibm = Base.sqrt),
]

const CENSUS_BINARY = [
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

# openlibm throws DomainError where the system libm returns a NaN bit pattern
# (e.g. asin outside [-1, 1], pow of a negative base with a fractional
# exponent). Either way it is a divergence; this helper is diagnostic only.
function _census_openlibm_bits(f, args...)
    try
        return float_bits_hex(f(args...))
    catch err
        err isa DomainError || rethrow()
        return nothing
    end
end

# Check every unary case; returns (checked, mismatches, openlibm_divergences,
# first_mismatch). `got != want` is exact string inequality, checked for every
# input; the first mismatch is reported for diagnosis.
function _census_check_unary(xs, want, detfn, basefn)
    mismatches = 0
    divergences = 0
    first_mismatch = nothing
    for i in eachindex(xs)
        x = Float64(xs[i])
        expected = String(want[i])
        got = float_bits_hex(detfn(x))
        if got != expected
            mismatches += 1
            if first_mismatch === nothing
                first_mismatch = (index = i, input = x, expected = expected, got = got)
            end
        end
        if basefn !== nothing && _census_openlibm_bits(basefn, x) != expected
            divergences += 1
        end
    end
    return length(xs), mismatches, divergences, first_mismatch
end

function _census_check_binary(as, bs, want, detfn, basefn)
    mismatches = 0
    divergences = 0
    first_mismatch = nothing
    for i in eachindex(as)
        a = Float64(as[i])
        b = Float64(bs[i])
        expected = String(want[i])
        got = float_bits_hex(detfn(a, b))
        if got != expected
            mismatches += 1
            if first_mismatch === nothing
                first_mismatch = (index = i, a = a, b = b, expected = expected, got = got)
            end
        end
        if basefn !== nothing && _census_openlibm_bits(basefn, a, b) != expected
            divergences += 1
        end
    end
    return length(as), mismatches, divergences, first_mismatch
end

function _report_mismatch(label, first_mismatch)
    first_mismatch === nothing && return
    println("  first $(label) mismatch: ", first_mismatch)
end

@testset "Math census" begin
    if !isfile(CENSUS_FIXTURE)
        println("test_census: SKIP: fixture absent at $(CENSUS_FIXTURE); " *
                "run scripts/capture_math_census.sh first")
        @test_skip true
    else
        # JSON.jl parses bare `-0` as Int64(0); inttype=Float64 keeps the sign
        # so the parsed inputs are bit-identical to what LuaJIT encoded.
        fixture = JSON.parsefile(CENSUS_FIXTURE; inttype = Float64)
        inputs = fixture["inputs"]
        expected = fixture["expected"]
        counts = fixture["counts"]

        @test fixture["format"] == "peggle.math_census"
        @test Int(fixture["schema_version"]) == 1
        source = fixture["source"]
        @test source["reference_revision"] isa String
        @test source["reference_tree"] isa String
        @test occursin(r"^[0-9a-f]{64}$", source["config_sha256"])
        @test occursin(r"^[0-9a-f]{64}$", source["fixtures_sha256"])

        expected_keys = Set(vcat(
            [spec.name for spec in CENSUS_UNARY],
            [spec.name for spec in CENSUS_BINARY]))
        @test Set(keys(expected)) == expected_keys
        @test Set(keys(counts)) == expected_keys

        println("math census: ", CENSUS_FIXTURE)
        println("  fixture_sha256=", sha256_hex(read(CENSUS_FIXTURE)))

        system_mismatches = 0
        openlibm_divergences = Dict{String,Int}()
        total_cases = 0

        for spec in CENSUS_UNARY
            xs = inputs[spec.name]
            want = expected[spec.name]
            checked, mismatches, divergences, first_mismatch =
                _census_check_unary(xs, want, spec.det, spec.openlibm)
            _report_mismatch(spec.name, first_mismatch)
            @test checked == length(want)
            @test checked == Int(counts[spec.name])
            @test mismatches == 0
            system_mismatches += mismatches
            openlibm_divergences[spec.name] = divergences
            total_cases += checked
        end

        for spec in CENSUS_BINARY
            as = inputs[spec.a]
            bs = inputs[spec.b]
            want = expected[spec.name]
            checked, mismatches, divergences, first_mismatch =
                _census_check_binary(as, bs, want, spec.det, spec.openlibm)
            _report_mismatch(spec.name, first_mismatch)
            @test length(as) == length(bs)
            @test checked == length(want)
            @test checked == Int(counts[spec.name])
            @test mismatches == 0
            system_mismatches += mismatches
            openlibm_divergences[spec.name] = divergences
            total_cases += checked
        end

        @test system_mismatches == 0
        @test total_cases == sum(Int, values(counts))
        println("  total cases: ", total_cases)
        println("  system libm mismatches: ", system_mismatches)
        println("  openlibm divergences (diagnostic only):")
        for name in sort(collect(keys(openlibm_divergences)))
            @printf("    %-6s %6d / %6d\n", name,
                openlibm_divergences[name], Int(counts[name]))
        end

        @testset "inputs round-trip through canonical text" begin
            bad = 0
            checked = 0
            first_bad = nothing
            for name in sort(collect(keys(inputs)))
                for x in inputs[name]
                    xf = Float64(x)
                    back = JSON.parse(canonical_json(xf); inttype = Float64)
                    checked += 1
                    if !(back isa Float64) ||
                       reinterpret(UInt64, back) != reinterpret(UInt64, xf)
                        bad += 1
                        first_bad === nothing && (first_bad = (name, canonical_json(xf)))
                    end
                end
            end
            first_bad === nothing || println("  first round-trip failure: ", first_bad)
            @test checked > 0
            @test bad == 0
        end

        @testset "-0 survives parsing and is exercised" begin
            has_neg_zero = false
            for name in keys(inputs)
                for x in inputs[name]
                    if x == 0.0 && signbit(x)
                        has_neg_zero = true
                    end
                end
            end
            @test has_neg_zero
            @test float_bits_hex(Float64(inputs["sin"][2])) ==
                  "0x8000000000000000"
        end

        @testset "lua_mod sign and zero behavior" begin
            # Lua `%` is a - floor(a/b)*b; captured from LuaJIT 2.1.
            @test lua_mod(-7.0, 3.0) == 2.0
            @test lua_mod(7.0, 3.0) == 1.0
            @test lua_mod(-7.0, -3.0) == -1.0
            @test lua_mod(7.0, -3.0) == -2.0
            @test lua_mod(5.5, 2.0) == 1.5
            @test lua_mod(-5.5, 2.0) == 0.5
            @test lua_mod(5.5, -2.0) == -0.5
            @test lua_mod(-5.5, -2.0) == -1.5
            # A zero Lua-modulo result is always +0, never -0.
            for (a, b) in ((0.0, 5.0), (-0.0, 5.0), (0.0, -5.0), (-0.0, -5.0),
                           (-6.0, 3.0), (6.0, -3.0), (1e-300, 1e-300),
                           (-1e300, 3.0), (1e300, 3.0))
                got = lua_mod(a, b)
                @test got == 0.0
                @test !signbit(got)
            end
            @test isnan(lua_mod(3.0, 0.0))
            @test isnan(lua_mod(-3.0, 0.0))
            @test isnan(lua_mod(0.0, 0.0))
        end
    end
end
