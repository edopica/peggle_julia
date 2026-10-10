# Exact port of LÖVE 11.5 love.math.RandomGenerator.
#
# Reference: src/modules/math/RandomGenerator.{h,cpp} and
# src/modules/math/wrap_RandomGenerator.cpp at tag 11.5.
#
# The generator is a 64-bit xorshift* (Marsaglia, xorshift.di.unimi.it) with
# a Thomas Wang 64-bit hash of the seed. `random01` maps the top 52 bits of a
# draw onto [0,1) with exact power-of-two scaling. Integer sampling uses the
# LÖVE Lua wrapper mapping.

const LOVE_DEFAULT_SEED = UInt64(0x0139408DCBBF7A44) # low 0xCBBF7A44, high 0x0139408D

const RNG_XORSHIFT_MULTIPLIER = UInt64(0x2545F4914F6CDD1D)
const RNG_MANTISSA_BASE = UInt64(0x3FF0000000000000)

mutable struct LoveRandom
    seed::UInt64
    state::UInt64
    last_randomnormal::Float64
end

# Thomas Wang's 64-bit integer hash, byte-for-byte the C++ implementation.
function wang_hash64(key::UInt64)::UInt64
    key = (~key) + (key << 21)
    key = key ⊻ (key >> 24)
    key = (key + (key << 3)) + (key << 8)
    key = key ⊻ (key >> 14)
    key = (key + (key << 2)) + (key << 4)
    key = key ⊻ (key >> 28)
    key = key + (key << 31)
    return key
end

function LoveRandom(seed::Real)
    seedf = Float64(seed)
    isfinite(seedf) || throw(ArgumentError("invalid random seed: $(seed)"))
    original = trunc(UInt64, seedf)
    hashed = original
    while true
        hashed = wang_hash64(hashed)
        hashed != 0 && break
    end
    return LoveRandom(original, hashed, Inf)
end

# LÖVE accepts a seed as two 32-bit halves (low, high).
function LoveRandom(low::UInt32, high::UInt32)
    return LoveRandom((UInt64(high) << 32) | UInt64(low))
end

function rand_u64!(r::LoveRandom)::UInt64
    r.state ⊻= r.state >> 12
    r.state ⊻= r.state << 25
    r.state ⊻= r.state >> 27
    return r.state * RNG_XORSHIFT_MULTIPLIER
end

function random01(r::LoveRandom)::Float64
    bits = RNG_MANTISSA_BASE | (rand_u64!(r) >> 12)
    return reinterpret(Float64, bits) - 1.0
end

random(r::LoveRandom)::Float64 = random01(r)

function random(r::LoveRandom, max::Int)::Int
    return Int(floor(random01(r) * max)) + 1
end

function random(r::LoveRandom, lo::Int, hi::Int)::Int
    return Int(floor(random01(r) * (hi - lo + 1))) + lo
end

function get_state(r::LoveRandom)::String
    return "0x" * string(r.state, base = 16, pad = 16)
end

function set_state!(r::LoveRandom, s::AbstractString)
    text = String(s)
    (startswith(text, "0x") || startswith(text, "0X")) ||
        throw(ArgumentError("invalid random state: $(text)"))
    digits = text[3:end]
    if isempty(digits) || length(digits) > 16 ||
       !all(c -> c in "0123456789abcdefABCDEF", digits)
        throw(ArgumentError("invalid random state: $(text)"))
    end
    r.state = parse(UInt64, digits, base = 16)
    r.last_randomnormal = Inf
    return r
end

function get_seed(r::LoveRandom)::Tuple{UInt32,UInt32}
    return (UInt32(r.seed & 0xFFFFFFFF), UInt32(r.seed >> 32))
end

# Box-Muller with LÖVE's cached-value sentinel. The two uniforms come from
# random01; the cached value is `r*cos(phi)` scaled by the caller's stddev on
# the next call. Transcendental functions go through DetMath so the sequence
# matches the C library the reference used.
function random_normal(r::LoveRandom, stddev::Float64 = 1.0)::Float64
    if r.last_randomnormal != Inf
        cached = r.last_randomnormal
        r.last_randomnormal = Inf
        return cached * stddev
    end
    rad = DetMath.det_sqrt(-2.0 * DetMath.det_log(1.0 - random01(r)))
    phi = (2.0 * Float64(pi)) * (1.0 - random01(r))
    r.last_randomnormal = rad * DetMath.det_cos(phi)
    return rad * DetMath.det_sin(phi) * stddev
end

function snapshot(r::LoveRandom)::LoveRandom
    return LoveRandom(r.seed, r.state, r.last_randomnormal)
end

function restore!(r::LoveRandom, snap::LoveRandom)
    r.seed = snap.seed
    r.state = snap.state
    r.last_randomnormal = snap.last_randomnormal
    return r
end
