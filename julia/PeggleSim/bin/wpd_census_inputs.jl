#!/usr/bin/env julia
# WP-D1: build the math comparison input corpus and the independent oracle.
#
# Usage:
#   julia --project=julia/PeggleSim julia/PeggleSim/bin/wpd_census_inputs.jl \
#       [--fixture fixtures/math_census/math_census.v1.json] \
#       [--out tmp/core-math/wpd-inputs.json]
#
# For every function in {sin cos tan asin acos atan exp log sqrt atan2 pow mod}
# the corpus contains, in this order:
#   1. every historical census input (fixtures/math_census/math_census.v1.json)
#      plus its one-ULP and two-ULP neighbours (component-wise for binary);
#   2. the numeric-contract section 12 boundary values (signed zero, subnormal
#      and normal edges, infinities, NaNs, pi-family boundaries, huge
#      arguments, domain edges, thresholds, squares, pow/atan2/mod grids);
#   3. `hard_to_round_per_function` oracle-derived cases chosen from a
#      deterministic grid (boundaries and recorded values above, 4096 logspace
#      points, 4096 splitmix64-derived bit patterns) as the inputs whose exact
#      value is closest to a binary64 rounding midpoint. Distance is measured
#      at 256 bits, RoundNearest, relative to the local ULP.
#
# Cases are deduplicated by bit pattern and keep their first insertion order.
# Every value is a lowercase "0x%016x" bit-hex string.
#
# Oracle rules (`wpd-plan.md` section 1.1):
#   * IEEE special cases first (numeric-contract sections 6/7/9, C pow
#     semantics, IEEE atan2 semantics).
#   * Otherwise interval evaluation: with BigFloat at each precision
#     p in {256, 512, 1024, 2048, 4096}, compute the function under RoundDown
#     and RoundUp; convert both to Float64 with RoundNearest; when the two
#     results are the same value the oracle is decided (exact zero is
#     normalized to +0 because all mathematical zeros here round ties-to-even
#     to +0). NaN under both directions means the mathematical result is NaN;
#     the recorded decision bits are the quiet +NaN pattern 0x7ff8..., and the
#     comparator treats oracle NaNs by class/sign. Still undecided at 4096
#     records the 1-based case index in `oracle_undecided` (must be empty).
#   * `mod` evaluates the contract expression `a - floor(a/b)*b`: the binary64
#     division and multiplication are single correctly rounded operations, so
#     the interval is taken over the exact final subtraction (which is exact
#     at high precision because both operands are binary64).
#   * `special` entries carry explicit contract bits; the generator checks that
#     they agree with the general oracle and exits nonzero otherwise.
#
# The process prints per-function case and undecided counts and exits nonzero
# when any case stays undecided or a special expectation is inconsistent.

using PeggleSim
using Printf
import JSON

const DEFAULT_FIXTURE = "fixtures/math_census/math_census.v1.json"
const DEFAULT_OUT = "tmp/core-math/wpd-inputs.json"

const PRECISION_START = 256
const PRECISION_MAX = 4096
const PRECISIONS = (256, 512, 1024, 2048, 4096)
const HARD_TO_ROUND_PER_FUNCTION = 128
const GRID_POINTS = 4096

const UNARY_FUNCTIONS = ["sin", "cos", "tan", "asin", "acos", "atan",
                         "exp", "log", "sqrt"]
const BINARY_FUNCTIONS = ["atan2", "pow", "mod"]
const ALL_FUNCTIONS = vcat(UNARY_FUNCTIONS, BINARY_FUNCTIONS)

# ===========================================================================
# Bit patterns and constants
# ===========================================================================

bits64(x::Float64)::UInt64 = reinterpret(UInt64, x)
f64(u::UInt64)::Float64 = reinterpret(Float64, u)
bithex(u::UInt64)::String = @sprintf("0x%016x", u)

const QNAN = 0x7ff8000000000000
const NEG_QNAN = 0xfff8000000000000
const POS_ZERO = 0x0000000000000000
const NEG_ZERO = 0x8000000000000000
const ONE = bits64(1.0)
const NEG_ONE = bits64(-1.0)
const TWO = bits64(2.0)
const NEG_TWO = bits64(-2.0)
const THREE = bits64(3.0)
const NEG_THREE = bits64(-3.0)
const FOUR = bits64(4.0)
const NEG_FOUR = bits64(-4.0)
const HALF = bits64(0.5)
const NEG_HALF = bits64(-0.5)
const THREE_HALF = bits64(3.5)
const NEG_THREE_HALF = bits64(-3.5)
const POS_INF = bits64(Inf)
const NEG_INF = bits64(-Inf)
const MIN_SUBNORMAL = 0x0000000000000001
const LARGEST_SUBNORMAL = 0x000fffffffffffff
const SMALLEST_NORMAL = 0x0010000000000000

const BIGPI = setprecision(BigFloat, 4096) do
    BigFloat(pi)
end
const BIGE = setprecision(BigFloat, 4096) do
    exp(BigFloat(1))
end

rnd64(x::BigFloat)::Float64 = Float64(x, RoundNearest)

const PI_F = rnd64(BIGPI)
const NEG_PI_F = rnd64(-BIGPI)
const PI_OVER_2_F = rnd64(BIGPI / 2)
const NEG_PI_OVER_2_F = rnd64(-BIGPI / 2)
const PI_OVER_4_F = rnd64(BIGPI / 4)
const NEG_PI_OVER_4_F = rnd64(-BIGPI / 4)
const THREE_PI_OVER_4_F = rnd64(3 * BIGPI / 4)
const NEG_THREE_PI_OVER_4_F = rnd64(-3 * BIGPI / 4)
const EULER_F = rnd64(BIGE)

const PI_BITS = bits64(PI_F)
const NEG_PI_BITS = bits64(NEG_PI_F)
const PI_OVER_2_BITS = bits64(PI_OVER_2_F)
const NEG_PI_OVER_2_BITS = bits64(NEG_PI_OVER_2_F)
const PI_OVER_4_BITS = bits64(PI_OVER_4_F)
const NEG_PI_OVER_4_BITS = bits64(NEG_PI_OVER_4_F)
const THREE_PI_OVER_4_BITS = bits64(THREE_PI_OVER_4_F)
const NEG_THREE_PI_OVER_4_BITS = bits64(NEG_THREE_PI_OVER_4_F)

# ===========================================================================
# BigFloat evaluation helpers (exact inputs, catch domain errors as NaN)
# ===========================================================================

function apply_unary_big(name::Symbol, x::BigFloat)::BigFloat
    name === :sin && return sin(x)
    name === :cos && return cos(x)
    name === :tan && return tan(x)
    name === :asin && return asin(x)
    name === :acos && return acos(x)
    name === :atan && return atan(x)
    name === :exp && return exp(x)
    name === :log && return log(x)
    name === :sqrt && return sqrt(x)
    error("unknown unary function $(name)")
end

function apply_binary_big(name::Symbol, a::BigFloat, b::BigFloat)::BigFloat
    name === :atan2 && return atan(a, b)
    name === :pow && return a^b
    error("unknown binary function $(name)")
end

function safe_apply(::Type{BigFloat}, f::Function)::BigFloat
    try
        return f()
    catch err
        err isa DomainError || rethrow()
        return BigFloat(NaN)
    end
end

# The interval decision: directed bounds `lo <= true <= hi`; convert both to
# Float64 with RoundNearest and require the same result. Matching bit patterns
# decide directly, which preserves the sign of results that underflow to a
# signed zero. When the bits differ but the values compare equal the only
# possible pair is (-0, +0): the bounds straddle an exact zero, and
# round-to-nearest maps an exact mathematical zero to +0 (contract-pinned
# signed zeros are handled as explicit special cases before the interval).
function decide_interval(lo::BigFloat, hi::BigFloat)::Tuple{UInt64,Bool}
    if isnan(lo) || isnan(hi)
        return (QNAN, true)
    end
    lf = Float64(lo, RoundNearest)
    hf = Float64(hi, RoundNearest)
    if bits64(lf) == bits64(hf)
        return (bits64(lf), true)
    end
    if lf == hf
        return (POS_ZERO, true)
    end
    return (POS_ZERO, false)
end

function interval_unary(name::Symbol, x::Float64)::Tuple{UInt64,Bool}
    bx = BigFloat(x)
    for p in PRECISIONS
        lo, hi = setprecision(BigFloat, p) do
            l = safe_apply(BigFloat, () -> setrounding(BigFloat, RoundDown) do
                apply_unary_big(name, bx)
            end)
            h = safe_apply(BigFloat, () -> setrounding(BigFloat, RoundUp) do
                apply_unary_big(name, bx)
            end)
            (l, h)
        end
        u, ok = decide_interval(lo, hi)
        ok && return (u, true)
    end
    return (POS_ZERO, false)
end

function interval_binary(name::Symbol, a::Float64, b::Float64)::Tuple{UInt64,Bool}
    ba = BigFloat(a)
    bb = BigFloat(b)
    for p in PRECISIONS
        lo, hi = setprecision(BigFloat, p) do
            l = safe_apply(BigFloat, () -> setrounding(BigFloat, RoundDown) do
                apply_binary_big(name, ba, bb)
            end)
            h = safe_apply(BigFloat, () -> setrounding(BigFloat, RoundUp) do
                apply_binary_big(name, ba, bb)
            end)
            (l, h)
        end
        u, ok = decide_interval(lo, hi)
        ok && return (u, true)
    end
    return (POS_ZERO, false)
end

# `mod` models the contract expression: q = floor(a/b) with a binary64
# division, t = q*b with a binary64 multiplication, then the exact final
# subtraction interval. Both a and t are binary64, so the difference is exact
# at 4096 bits and the interval always decides there.
function interval_mod(a::Float64, b::Float64)::Tuple{UInt64,Bool}
    q = floor(a / b)
    t = q * b
    ba = BigFloat(a)
    bt = BigFloat(t)
    for p in PRECISIONS
        lo, hi = setprecision(BigFloat, p) do
            l = setrounding(BigFloat, RoundDown) do
                ba - bt
            end
            h = setrounding(BigFloat, RoundUp) do
                ba - bt
            end
            (l, h)
        end
        u, ok = decide_interval(lo, hi)
        ok && return (u, true)
    end
    return (POS_ZERO, false)
end

# ===========================================================================
# Oracle special cases (numeric-contract sections 6/7/9; C pow; IEEE atan2)
# ===========================================================================

function odd_integer(b::Float64)::Bool
    isinteger(b) || return false
    abs(b) < 9.007199254740992e15 || return false
    return isodd(Int64(b))
end

function oracle_unary(name::Symbol, x::Float64)::Tuple{UInt64,Bool}
    xb = bits64(x)
    isnan(x) && return (QNAN, true)
    if name === :sin || name === :cos || name === :tan
        name === :sin && iszero(x) && return (xb, true)
        name === :tan && iszero(x) && return (xb, true)
        name === :cos && iszero(x) && return (ONE, true)
        isinf(x) && return (QNAN, true)
    elseif name === :asin
        iszero(x) && return (xb, true)
        abs(x) > 1.0 && return (QNAN, true)
    elseif name === :acos
        abs(x) > 1.0 && return (QNAN, true)
    elseif name === :atan
        iszero(x) && return (xb, true)
    elseif name === :exp
        x == Inf && return (POS_INF, true)
        x == -Inf && return (POS_ZERO, true)
        iszero(x) && return (ONE, true)
    elseif name === :log
        iszero(x) && return (NEG_INF, true)
        x < 0.0 && return (QNAN, true)
        x == Inf && return (POS_INF, true)
        x == 1.0 && return (POS_ZERO, true)
    elseif name === :sqrt
        iszero(x) && return (xb, true)
        x < 0.0 && return (QNAN, true)
        x == Inf && return (POS_INF, true)
    end
    return interval_unary(name, x)
end

function oracle_pow(a::Float64, b::Float64)::Tuple{UInt64,Bool}
    if b == 0.0
        return (ONE, true)               # pow(x, +/-0) = 1 including x = NaN
    end
    if a == 1.0
        return (ONE, true)               # pow(1, y) = 1 including y = NaN
    end
    if isnan(a) || isnan(b)
        return (QNAN, true)
    end
    if isinf(b)
        ab = abs(a)
        if ab == 1.0
            return (ONE, true)           # pow(-1, +/-Inf) = 1
        end
        return ((ab > 1.0) == (b > 0)) ? (POS_INF, true) : (POS_ZERO, true)
    end
    if isinf(a)
        if a > 0
            return b > 0 ? (POS_INF, true) : (POS_ZERO, true)
        end
        odd = odd_integer(b)
        if b > 0
            return odd ? (NEG_INF, true) : (POS_INF, true)
        else
            return odd ? (NEG_ZERO, true) : (POS_ZERO, true)
        end
    end
    if a == 0.0
        neg = signbit(a)
        if b > 0
            return (neg && odd_integer(b)) ? (NEG_ZERO, true) : (POS_ZERO, true)
        else
            return (neg && odd_integer(b)) ? (NEG_INF, true) : (POS_INF, true)
        end
    end
    if a < 0.0 && !isinteger(b)
        return (QNAN, true)              # negative base, fractional exponent
    end
    return interval_binary(:pow, a, b)
end

function oracle_atan2(y::Float64, x::Float64)::Tuple{UInt64,Bool}
    (isnan(y) || isnan(x)) && return (QNAN, true)
    if iszero(x)
        if iszero(y)
            if signbit(x)
                return signbit(y) ? (NEG_PI_BITS, true) : (PI_BITS, true)
            else
                return signbit(y) ? (NEG_ZERO, true) : (POS_ZERO, true)
            end
        end
        return signbit(y) ? (NEG_PI_OVER_2_BITS, true) : (PI_OVER_2_BITS, true)
    end
    if iszero(y)
        if signbit(x)
            return signbit(y) ? (NEG_PI_BITS, true) : (PI_BITS, true)
        else
            return signbit(y) ? (NEG_ZERO, true) : (POS_ZERO, true)
        end
    end
    if isinf(y) && isinf(x)
        if x > 0
            return signbit(y) ? (NEG_PI_OVER_4_BITS, true) : (PI_OVER_4_BITS, true)
        else
            return signbit(y) ? (NEG_THREE_PI_OVER_4_BITS, true) : (THREE_PI_OVER_4_BITS, true)
        end
    end
    if isinf(y)
        return signbit(y) ? (NEG_PI_OVER_2_BITS, true) : (PI_OVER_2_BITS, true)
    end
    if isinf(x)
        if x > 0
            return signbit(y) ? (NEG_ZERO, true) : (POS_ZERO, true)
        else
            return signbit(y) ? (NEG_PI_BITS, true) : (PI_BITS, true)
        end
    end
    return interval_binary(:atan2, y, x)
end

function oracle_mod(a::Float64, b::Float64)::Tuple{UInt64,Bool}
    (isnan(a) || isnan(b)) && return (QNAN, true)
    b == 0.0 && return (NEG_QNAN, true)
    isinf(b) && return (NEG_QNAN, true)
    isinf(a) && return (NEG_QNAN, true)
    iszero(a) && return (POS_ZERO, true)
    return interval_mod(a, b)
end

function oracle_binary(name::Symbol, a::Float64, b::Float64)::Tuple{UInt64,Bool}
    name === :pow && return oracle_pow(a, b)
    name === :atan2 && return oracle_atan2(a, b)
    name === :mod && return oracle_mod(a, b)
    error("unknown binary function $(name)")
end

# ===========================================================================
# Hard-to-round measurement
# ===========================================================================

# Relative distance of the exact BigFloat value to the nearest binary64
# rounding midpoint. 0 means an exact tie; values near 0 are the hard cases.
# Non-finite / NaN results and results outside the binary64 range return Inf.
function midpoint_distance_rel(y::BigFloat)::BigFloat
    isnan(y) && return BigFloat(Inf)
    lo = Float64(y, RoundDown)
    hi = Float64(y, RoundUp)
    if lo != hi
        (isfinite(lo) && isfinite(hi)) || return BigFloat(Inf)
        gap = BigFloat(hi) - BigFloat(lo)
        mid = (BigFloat(lo) + BigFloat(hi)) / 2
        return abs(y - mid) / gap
    end
    isfinite(lo) || return BigFloat(Inf)
    u = BigFloat(eps(lo))
    a = (BigFloat(prevfloat(lo)) + BigFloat(lo)) / 2
    b = (BigFloat(lo) + BigFloat(nextfloat(lo))) / 2
    return min(abs(y - a), abs(y - b)) / u
end

function rounded_value_unary(name::Symbol, x::Float64)::BigFloat
    (isnan(x) || isinf(x)) && return BigFloat(NaN)
    setprecision(BigFloat, 256) do
        bx = BigFloat(x)
        try
            apply_unary_big(name, bx)
        catch err
            err isa DomainError ? BigFloat(NaN) : rethrow()
        end
    end
end

function rounded_value_binary(name::Symbol, a::Float64, b::Float64)::BigFloat
    if name === :mod
        (isnan(a) || isnan(b) || isinf(a) || isinf(b) || b == 0.0) &&
            return BigFloat(NaN)
        q = floor(a / b)
        t = q * b
        return setprecision(BigFloat, 256) do
            BigFloat(a) - BigFloat(t)
        end
    end
    (isnan(a) || isnan(b)) && return BigFloat(NaN)
    setprecision(BigFloat, 256) do
        ba = BigFloat(a)
        bb = BigFloat(b)
        try
            apply_binary_big(name, ba, bb)
        catch err
            err isa DomainError ? BigFloat(NaN) : rethrow()
        end
    end
end

# ===========================================================================
# Deterministic grids
# ===========================================================================

function build_grid_u64()::Vector{UInt64}
    out = UInt64[]
    n = GRID_POINTS
    for i in 1:n
        t = -308.0 + 616.0 * (i - 1) / (n - 1)
        x = 10.0^t
        push!(out, bits64(x))
        push!(out, bits64(-x))
    end
    state = UInt64(0x243f6a8885a308d3)
    for _ in 1:n
        state += 0x9e3779b97f4a7c15
        z = state
        z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
        z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
        z = z ⊻ (z >> 31)
        push!(out, z)
    end
    return out
end

# ===========================================================================
# Boundary values (numeric-contract section 12)
# ===========================================================================

function push_neighbors!(v::Vector{Float64}, x::Float64)
    push!(v, prevfloat(x), x, nextfloat(x))
    return v
end

function generic_boundaries()::Vector{Float64}
    v = Float64[]
    for u in (POS_ZERO, NEG_ZERO, MIN_SUBNORMAL, 0x8000000000000001,
              LARGEST_SUBNORMAL, 0x800fffffffffffff,
              SMALLEST_NORMAL, 0x8010000000000000,
              ONE, NEG_ONE, POS_INF, NEG_INF, QNAN, NEG_QNAN)
        push!(v, f64(u))
    end
    return v
end

function unary_boundary_values(name::String)::Vector{Float64}
    v = generic_boundaries()
    if name in ("sin", "cos", "tan")
        for k in (-8, -4, -2, -1, 1, 2, 4, 8)
            push_neighbors!(v, rnd64(BIGPI * k / 4))
        end
        for k in (3, 1024, 1048576)
            push_neighbors!(v, rnd64(2 * BIGPI * k))
        end
    end
    if name in ("sin", "cos", "tan", "atan")
        push_neighbors!(v, PI_OVER_2_F)
        push_neighbors!(v, NEG_PI_OVER_2_F)
    end
    if name in ("asin", "acos")
        for u in (bits64(-1.0), bits64(nextfloat(-1.0)), bits64(prevfloat(-1.0)),
                  bits64(1.0), bits64(nextfloat(1.0)), bits64(prevfloat(1.0)),
                  HALF, NEG_HALF)
            push_neighbors!(v, f64(u))
        end
    end
    if name == "exp"
        for x in (709.78, -745.13, 709.782712893383973, -745.133219101941108,
                  709.0, 710.0, -745.0, -746.0)
            push_neighbors!(v, x)
        end
    end
    if name == "log"
        push_neighbors!(v, 1.0)
        push_neighbors!(v, EULER_F)
        for x in (0.5, 2.0, 10.0, 2.2250738585072014e-308, 1.0e-300)
            push_neighbors!(v, x)
        end
    end
    if name == "sqrt"
        for n in 1:256
            push_neighbors!(v, Float64(n) * Float64(n))
        end
        for k in (-537, -500, -300, -100, -50, 0, 50, 100, 300, 500, 511)
            push_neighbors!(v, ldexp(1.0, 2k))
        end
        for x in (0.25, 0.5, 2.0, PI_F, 1.0e300)
            push_neighbors!(v, x)
        end
    end
    for x in (2.0^53, 1.0e15, 1.0e100, 1.0e300)
        push!(v, x, -x)
    end
    return v
end

function pow_boundary_pairs()::Vector{Tuple{Float64,Float64}}
    grid_vals = Float64[0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 0.5, -0.5,
                        Inf, -Inf, f64(QNAN), f64(MIN_SUBNORMAL), 1.0e300]
    p = Tuple{Float64,Float64}[]
    for a in grid_vals, b in grid_vals
        push!(p, (a, b))
    end
    for a in (-2.0, -3.0, -0.5, -1.5),
        b in (-4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0,
              0.5, 1.5, -0.5, -1.5, 2.5)
        push!(p, (a, b))
    end
    for a in (2.0, 0.5, 1.0e300, f64(MIN_SUBNORMAL), f64(LARGEST_SUBNORMAL)),
        b in (1.0e300, -1.0e300, 1024.0, -1024.0, 1075.0, -1075.0)
        push!(p, (a, b))
    end
    return p
end

function atan2_boundary_pairs()::Vector{Tuple{Float64,Float64}}
    p = Tuple{Float64,Float64}[]
    zeros = (0.0, -0.0)
    for y in zeros, x in zeros
        push!(p, (y, x))
    end
    for s in (1.0, -1.0)
        for x in (0.0, -0.0, 1.0, -1.0, Inf, -Inf)
            push!(p, (s, x))
        end
        push!(p, (0.0, s), (-0.0, s), (s, s), (s, -s))
    end
    for m in (1.0, -1.0, 0.5, -0.5,
              f64(MIN_SUBNORMAL), -f64(MIN_SUBNORMAL),
              f64(LARGEST_SUBNORMAL), -f64(LARGEST_SUBNORMAL),
              f64(SMALLEST_NORMAL), -f64(SMALLEST_NORMAL),
              1.0e-300, -1.0e-300, 1.0e300, -1.0e300,
              floatmax(Float64), -floatmax(Float64))
        push!(p, (m, m), (m, -m), (m, 1.0), (1.0, m))
    end
    tiny = (f64(MIN_SUBNORMAL), -f64(MIN_SUBNORMAL), 1.0e-300, -1.0e-300)
    huge = (1.0e300, -1.0e300)
    for y in tiny
        for x in huge
            push!(p, (y, x), (x, y))
        end
        push!(p, (y, 1.0), (y, -1.0))
    end
    for y in huge
        push!(p, (y, f64(MIN_SUBNORMAL)), (y, -f64(MIN_SUBNORMAL)))
        push!(p, (y, f64(LARGEST_SUBNORMAL)), (y, -f64(LARGEST_SUBNORMAL)))
        push!(p, (y, 1.0), (y, -1.0))
    end
    for s in (1.0, -1.0, Inf, -Inf)
        push!(p, (s, Inf), (s, -Inf), (Inf, s), (-Inf, s))
    end
    push!(p, (f64(QNAN), 1.0), (1.0, f64(QNAN)), (f64(QNAN), f64(QNAN)),
          (f64(QNAN), 0.0), (0.0, f64(QNAN)), (Inf, f64(QNAN)),
          (f64(NEG_QNAN), 1.0), (1.0, f64(NEG_QNAN)))
    return p
end

function mod_boundary_pairs()::Vector{Tuple{Float64,Float64}}
    p = Tuple{Float64,Float64}[]
    # numeric-contract section 9 table
    for (a, b) in ((0.0, -0.0), (-0.0, 2.0), (0.0, -2.0), (-0.0, -2.0),
                   (1.0, 0.0), (1.0, -0.0), (1.0, Inf), (1.0, -Inf),
                   (-1.0, Inf), (-1.0, -Inf), (-1.0, 2.0), (1.0, -2.0),
                   (3.5, -2.0), (-3.5, 2.0))
        push!(p, (a, b))
    end
    for a in (0.0, -0.0, 1.0, -1.0, 5.5, -5.5, 7.0, -7.0)
        for b in (5.0, -5.0, 1.5, -1.5)
            push!(p, (a, b))
        end
    end
    # exact-quotient pairs and their neighbours
    for b in (1.0, -1.0, 2.0, -2.0, 0.5, -0.5, 3.0, -3.0, PI_F, -PI_F,
              f64(MIN_SUBNORMAL), 1.0e-300, 1.0e300)
        for k in -3:3
            a = k * b
            for aa in (prevfloat(a), a, nextfloat(a))
                push!(p, (aa, b))
            end
        end
    end
    # zero / tiny / huge operands
    extremes = (f64(MIN_SUBNORMAL), -f64(MIN_SUBNORMAL),
                f64(LARGEST_SUBNORMAL), -f64(LARGEST_SUBNORMAL),
                1.0e-300, -1.0e-300, 1.0e300, -1.0e300)
    for a in extremes
        for b in (1.0, -1.0, 3.0, -3.0, f64(MIN_SUBNORMAL),
                  1.0e-300, 1.0e300, PI_F)
            push!(p, (a, b))
        end
    end
    for b in extremes
        for a in (0.0, -0.0, 1.0, -1.0, PI_F, -PI_F)
            push!(p, (a, b))
        end
    end
    return p
end

binary_boundary_pairs(name::String) =
    name == "pow" ? pow_boundary_pairs() :
    name == "atan2" ? atan2_boundary_pairs() : mod_boundary_pairs()

# ===========================================================================
# Case construction
# ===========================================================================

function historical_unary(fixture, name::String)::Vector{Float64}
    haskey(fixture["inputs"], name) || return Float64[]
    return Float64.(fixture["inputs"][name])
end

# tan and acos were missing from the M2 census. Reuse the recorded corpus of
# the function with the same domain so the WP-D coverage matches the other
# functions: tan over all reals (the atan corpus), acos over [-1, 1] (the
# asin corpus).
function wpd_historical_unary(fixture, name::String)::Vector{Float64}
    if name == "tan"
        return historical_unary(fixture, "atan")
    elseif name == "acos"
        return historical_unary(fixture, "asin")
    end
    return historical_unary(fixture, name)
end

function historical_binary_pairs(fixture, name::String)::Vector{Tuple{Float64,Float64}}
    if name == "atan2"
        as, bs = fixture["inputs"]["atan2_y"], fixture["inputs"]["atan2_x"]
    elseif name == "pow"
        as, bs = fixture["inputs"]["pow_a"], fixture["inputs"]["pow_b"]
    else
        as, bs = fixture["inputs"]["mod_a"], fixture["inputs"]["mod_b"]
    end
    length(as) == length(bs) || error("historical $(name) arrays are not parallel")
    return [(Float64(as[i]), Float64(bs[i])) for i in eachindex(as)]
end

function build_unary_cases(name::String, historical::Vector{Float64})
    seen = Set{UInt64}()
    out = UInt64[]
    function pushval(x::Float64)
        u = bits64(x)
        if !(u in seen)
            push!(seen, u)
            push!(out, u)
        end
    end
    for x in historical
        pushval(x)
        for d in 1:2
            lo = x
            hi = x
            for _ in 1:d
                lo = prevfloat(lo)
                hi = nextfloat(hi)
            end
            pushval(lo)
            pushval(hi)
        end
    end
    for x in unary_boundary_values(name)
        pushval(x)
    end
    return out, seen
end

function build_binary_cases(name::String, historical::Vector{Tuple{Float64,Float64}})
    seen = Set{Tuple{UInt64,UInt64}}()
    out = Tuple{UInt64,UInt64}[]
    function pushpair(a::Float64, b::Float64)
        u = (bits64(a), bits64(b))
        if !(u in seen)
            push!(seen, u)
            push!(out, u)
        end
    end
    for (a, b) in historical
        pushpair(a, b)
        adeltas = (-2, -1, 1, 2)
        bdeltas = (-2, -1, 1, 2)
        for da in adeltas
            aa = a
            for _ in 1:abs(da)
                aa = da < 0 ? prevfloat(aa) : nextfloat(aa)
            end
            pushpair(aa, b)
        end
        for db in bdeltas
            bb = b
            for _ in 1:abs(db)
                bb = db < 0 ? prevfloat(bb) : nextfloat(bb)
            end
            pushpair(a, bb)
        end
    end
    for (a, b) in binary_boundary_pairs(name)
        pushpair(a, b)
    end
    return out, seen
end

function add_hard_to_round_unary!(out::Vector{UInt64}, seen::Set{UInt64},
                                  name::String, grid::Vector{UInt64})
    scored = Tuple{BigFloat,UInt64}[]
    for u in out
        d = midpoint_distance_rel(rounded_value_unary(Symbol(name), f64(u)))
        isinf(d) || push!(scored, (d, u))
    end
    for u in grid
        d = midpoint_distance_rel(rounded_value_unary(Symbol(name), f64(u)))
        isinf(d) || push!(scored, (d, u))
    end
    sort!(scored, by = t -> (t[1], t[2]))
    n = min(HARD_TO_ROUND_PER_FUNCTION, length(scored))
    for i in 1:n
        u = scored[i][2]
        if !(u in seen)
            push!(seen, u)
            push!(out, u)
        end
    end
    return out
end

function add_hard_to_round_binary!(out::Vector{Tuple{UInt64,UInt64}},
                                   seen::Set{Tuple{UInt64,UInt64}},
                                   name::String, grid::Vector{UInt64})
    scored = Tuple{BigFloat,UInt64,UInt64}[]
    for (ua, ub) in out
        d = midpoint_distance_rel(
            rounded_value_binary(Symbol(name), f64(ua), f64(ub)))
        isinf(d) || push!(scored, (d, ua, ub))
    end
    pool = UInt64[]
    poolseen = Set{UInt64}()
    for (ua, ub) in out
        for u in (ua, ub)
            if !(u in poolseen)
                push!(poolseen, u)
                push!(pool, u)
            end
        end
    end
    for u in grid
        if !(u in poolseen)
            push!(poolseen, u)
            push!(pool, u)
        end
    end
    n = length(pool)
    if n > 0
        for i in 1:n
            for j in (mod1(i + 1, n), mod1(i + 7, n), mod1(n + 1 - i, n))
                ua, ub = pool[i], pool[j]
                d = midpoint_distance_rel(
                    rounded_value_binary(Symbol(name), f64(ua), f64(ub)))
                isinf(d) || push!(scored, (d, ua, ub))
            end
        end
    end
    sort!(scored, by = t -> (t[1], t[2], t[3]))
    kept = min(HARD_TO_ROUND_PER_FUNCTION, length(scored))
    for i in 1:kept
        ua, ub = scored[i][2], scored[i][3]
        if !((ua, ub) in seen)
            push!(seen, (ua, ub))
            push!(out, (ua, ub))
        end
    end
    return out
end

# ===========================================================================
# Special entries (numeric-contract sections 6 and 9 plus contract section 7
# exact infinity results)
# ===========================================================================

struct SpecialEntry
    name::String
    fn::String
    a::UInt64
    b::Union{UInt64,Nothing}
    expected::UInt64
    source::String
end

function special_entries()::Vector{SpecialEntry}
    s = SpecialEntry[]
    add(name, fn, a, b, expected) =
        push!(s, SpecialEntry(name, fn, a, b, expected, "numeric-contract"))
    add("sin_pos_zero", "sin", POS_ZERO, nothing, POS_ZERO)
    add("sin_neg_zero", "sin", NEG_ZERO, nothing, NEG_ZERO)
    add("tan_pos_zero", "tan", POS_ZERO, nothing, POS_ZERO)
    add("tan_neg_zero", "tan", NEG_ZERO, nothing, NEG_ZERO)
    add("asin_pos_zero", "asin", POS_ZERO, nothing, POS_ZERO)
    add("asin_neg_zero", "asin", NEG_ZERO, nothing, NEG_ZERO)
    add("atan_pos_zero", "atan", POS_ZERO, nothing, POS_ZERO)
    add("atan_neg_zero", "atan", NEG_ZERO, nothing, NEG_ZERO)
    add("cos_pos_zero", "cos", POS_ZERO, nothing, ONE)
    add("cos_neg_zero", "cos", NEG_ZERO, nothing, ONE)
    add("exp_pos_zero", "exp", POS_ZERO, nothing, ONE)
    add("exp_neg_zero", "exp", NEG_ZERO, nothing, ONE)
    add("log_one", "log", ONE, nothing, POS_ZERO)
    add("sqrt_pos_zero", "sqrt", POS_ZERO, nothing, POS_ZERO)
    add("sqrt_neg_zero", "sqrt", NEG_ZERO, nothing, NEG_ZERO)
    add("log_pos_zero", "log", POS_ZERO, nothing, NEG_INF)
    add("log_neg_zero", "log", NEG_ZERO, nothing, NEG_INF)
    add("exp_neg_inf", "exp", NEG_INF, nothing, POS_ZERO)
    add("exp_pos_inf", "exp", POS_INF, nothing, POS_INF)
    add("log_pos_inf", "log", POS_INF, nothing, POS_INF)
    add("sqrt_pos_inf", "sqrt", POS_INF, nothing, POS_INF)
    add("atan_pos_inf", "atan", POS_INF, nothing, PI_OVER_2_BITS)
    add("atan_neg_inf", "atan", NEG_INF, nothing, NEG_PI_OVER_2_BITS)
    add("pow_neg_zero_odd_pos", "pow", NEG_ZERO, THREE, NEG_ZERO)
    add("pow_neg_zero_odd_neg", "pow", NEG_ZERO, NEG_THREE, NEG_INF)
    add("pow_neg_zero_even_pos", "pow", NEG_ZERO, FOUR, POS_ZERO)
    add("pow_neg_zero_even_neg", "pow", NEG_ZERO, NEG_FOUR, POS_INF)
    add("pow_one_nan", "pow", ONE, QNAN, ONE)
    add("pow_nan_zero", "pow", QNAN, POS_ZERO, ONE)
    add("pow_neg_one_pos_inf", "pow", NEG_ONE, POS_INF, ONE)
    add("pow_neg_one_neg_inf", "pow", NEG_ONE, NEG_INF, ONE)
    add("atan2_pos_zero_pos_x", "atan2", POS_ZERO, TWO, POS_ZERO)
    add("atan2_neg_zero_pos_x", "atan2", NEG_ZERO, TWO, NEG_ZERO)
    add("atan2_pos_zero_neg_x", "atan2", POS_ZERO, NEG_TWO, PI_BITS)
    add("atan2_neg_zero_neg_x", "atan2", NEG_ZERO, NEG_TWO, NEG_PI_BITS)
    add("atan2_pos_y_pos_zero", "atan2", TWO, POS_ZERO, PI_OVER_2_BITS)
    add("atan2_neg_y_pos_zero", "atan2", NEG_TWO, POS_ZERO, NEG_PI_OVER_2_BITS)
    add("atan2_pos_y_neg_zero", "atan2", TWO, NEG_ZERO, PI_OVER_2_BITS)
    add("atan2_neg_y_neg_zero", "atan2", NEG_TWO, NEG_ZERO, NEG_PI_OVER_2_BITS)
    add("atan2_inf_inf", "atan2", POS_INF, POS_INF, PI_OVER_4_BITS)
    add("atan2_inf_neg_inf", "atan2", POS_INF, NEG_INF, THREE_PI_OVER_4_BITS)
    add("atan2_neg_inf_inf", "atan2", NEG_INF, POS_INF, NEG_PI_OVER_4_BITS)
    add("atan2_neg_inf_neg_inf", "atan2", NEG_INF, NEG_INF, NEG_THREE_PI_OVER_4_BITS)
    add("mod_pos_zero_neg_zero", "mod", POS_ZERO, NEG_ZERO, NEG_QNAN)
    add("mod_neg_zero_two", "mod", NEG_ZERO, TWO, POS_ZERO)
    add("mod_pos_zero_neg_two", "mod", POS_ZERO, NEG_TWO, POS_ZERO)
    add("mod_neg_zero_neg_two", "mod", NEG_ZERO, NEG_TWO, POS_ZERO)
    add("mod_one_pos_zero", "mod", ONE, POS_ZERO, NEG_QNAN)
    add("mod_one_neg_zero", "mod", ONE, NEG_ZERO, NEG_QNAN)
    add("mod_pos_one_pos_inf", "mod", ONE, POS_INF, NEG_QNAN)
    add("mod_pos_one_neg_inf", "mod", ONE, NEG_INF, NEG_QNAN)
    add("mod_neg_one_pos_inf", "mod", NEG_ONE, POS_INF, NEG_QNAN)
    add("mod_neg_one_neg_inf", "mod", NEG_ONE, NEG_INF, NEG_QNAN)
    add("mod_neg_one_two", "mod", NEG_ONE, TWO, ONE)
    add("mod_one_neg_two", "mod", ONE, NEG_TWO, NEG_ONE)
    add("mod_three_half_neg_two", "mod", THREE_HALF, NEG_TWO, NEG_HALF)
    add("mod_neg_three_half_two", "mod", NEG_THREE_HALF, TWO, HALF)
    return s
end

function special_is_consistent(e::SpecialEntry)::Bool
    bits, _ = e.b === nothing ?
        oracle_unary(Symbol(e.fn), f64(e.a)) :
        oracle_binary(Symbol(e.fn), f64(e.a), f64(e.b))
    expected = f64(e.expected)
    if isnan(expected)
        return isnan(f64(bits))
    end
    return bits == e.expected
end

# ===========================================================================
# Argument parsing / main
# ===========================================================================

function parse_args(argv)
    opts = Dict{String,String}(
        "fixture" => DEFAULT_FIXTURE, "out" => DEFAULT_OUT)
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a in ("--fixture", "--out")
            i += 1
            i <= length(argv) || error("missing value for $(a)")
            opts[a[3:end]] = argv[i]
        elseif a == "--help" || a == "-h"
            println("usage: wpd_census_inputs.jl [--fixture PATH] [--out PATH]")
            exit(0)
        else
            error("unknown argument: $(a)")
        end
        i += 1
    end
    return opts
end

function main(argv)
    opts = parse_args(argv)
    fixture_path = opts["fixture"]
    out_path = opts["out"]

    isfile(fixture_path) ||
        error("historical census fixture not found: $(fixture_path); " *
              "run scripts/capture_math_census.sh first")
    fixture = JSON.parsefile(fixture_path; inttype = Float64)
    @assert fixture["format"] == "peggle.math_census"
    historical_sha = sha256_hex(read(fixture_path))

    grid = build_grid_u64()

    cases_a = Dict{String,Vector{UInt64}}()
    cases_b = Dict{String,Vector{UInt64}}()
    oracles = Dict{String,Vector{UInt64}}()
    undecided = Dict{String,Vector{Int}}()
    total_cases = 0
    total_undecided = 0

    println("wpd_census_inputs: fixture=", fixture_path)
    for fn in UNARY_FUNCTIONS
        out, seen = build_unary_cases(fn, wpd_historical_unary(fixture, fn))
        add_hard_to_round_unary!(out, seen, fn, grid)
        obs = UInt64[]
        und = Int[]
        for (i, u) in enumerate(out)
            r, ok = oracle_unary(Symbol(fn), f64(u))
            push!(obs, r)
            ok || push!(und, i)
        end
        cases_a[fn] = out
        oracles[fn] = obs
        undecided[fn] = und
        total_cases += length(out)
        total_undecided += length(und)
        println("  ", rpad(fn, 6), " cases=", length(out),
                " undecided=", length(und))
    end
    for fn in BINARY_FUNCTIONS
        out, seen = build_binary_cases(fn, historical_binary_pairs(fixture, fn))
        add_hard_to_round_binary!(out, seen, fn, grid)
        as = UInt64[]
        bs = UInt64[]
        obs = UInt64[]
        und = Int[]
        for (i, (ua, ub)) in enumerate(out)
            r, ok = oracle_binary(Symbol(fn), f64(ua), f64(ub))
            push!(as, ua)
            push!(bs, ub)
            push!(obs, r)
            ok || push!(und, i)
        end
        cases_a[fn] = as
        cases_b[fn] = bs
        oracles[fn] = obs
        undecided[fn] = und
        total_cases += length(out)
        total_undecided += length(und)
        println("  ", rpad(fn, 6), " cases=", length(out),
                " undecided=", length(und))
    end

    specials = special_entries()
    inconsistent = String[]
    for e in specials
        if !special_is_consistent(e)
            push!(inconsistent, e.name)
        end
    end
    if !isempty(inconsistent)
        println(stderr, "wpd_census_inputs: inconsistent special entries: ",
                join(inconsistent, ", "))
    end

    cases_obj = Dict{String,Any}()
    for fn in ALL_FUNCTIONS
        entry = Dict{String,Any}(
            "arity" => (fn in UNARY_FUNCTIONS) ? 1 : 2,
            "a" => [bithex(u) for u in cases_a[fn]],
        )
        if fn in BINARY_FUNCTIONS
            entry["b"] = [bithex(u) for u in cases_b[fn]]
        end
        cases_obj[fn] = entry
    end
    oracle_obj = Dict{String,Any}()
    undecided_obj = Dict{String,Any}()
    for fn in ALL_FUNCTIONS
        oracle_obj[fn] = [bithex(u) for u in oracles[fn]]
        undecided_obj[fn] = undecided[fn]
    end
    special_arr = Any[Dict{String,Any}(
        "name" => e.name,
        "fn" => e.fn,
        "a" => bithex(e.a),
        "b" => e.b === nothing ? nothing : bithex(e.b),
        "expected" => bithex(e.expected),
        "source" => e.source,
    ) for e in specials]

    document = Dict{String,Any}(
        "format" => "peggle.wpd_math_inputs",
        "schema_version" => 1,
        "source" => Dict{String,Any}(
            "generator" => "julia/PeggleSim/bin/wpd_census_inputs.jl",
            "julia" => string(VERSION),
            "precision_start" => PRECISION_START,
            "precision_max" => PRECISION_MAX,
            "hard_to_round_per_function" => HARD_TO_ROUND_PER_FUNCTION,
            "historical_census_fixture" => fixture_path,
            "historical_census_sha256" => historical_sha,
        ),
        "cases" => cases_obj,
        "oracle" => oracle_obj,
        "oracle_undecided" => undecided_obj,
        "special" => special_arr,
    )

    dir = dirname(out_path)
    isempty(dir) || mkpath(dir)
    open(out_path, "w") do io
        write(io, canonical_json(document))
        write(io, "\n")
    end

    println("wpd_census_inputs: out=", out_path,
            " total_cases=", total_cases,
            " total_undecided=", total_undecided,
            " specials=", length(specials),
            " inconsistent_specials=", length(inconsistent))
    if total_undecided != 0 || !isempty(inconsistent)
        println("  ERROR: undecided cases or inconsistent specials")
        exit(1)
    end
    return nothing
end

main(ARGS)
