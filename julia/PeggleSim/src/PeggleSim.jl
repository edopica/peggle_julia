module PeggleSim

using Base64
using JSON
using Printf
using SHA

include("detmath.jl")
include("rng.jl")
include("canonical.jl")
include("jsonio.jl")
include("config.jl")
include("level.jl")
include("colorstate.jl")
include("state.jl")
include("scratch.jl")
include("checkpoint.jl")

# M3 shot-time systems. Order matters (engine.jl consumes all).
include("events.jl")
include("impact_geometry.jl")
include("physics.jl")
include("bucket.jl")
include("fever_buckets.jl")
include("powers.jl")
include("style_shots.jl")
include("ball_state.jl")
include("slide_inversion.jl")
include("snapshot.jl")
include("trace.jl")
include("engine.jl")

include("parity.jl")

export DetMath
export LoveRandom, wang_hash64, rand_u64!, random01, random, get_state,
       set_state!, get_seed, random_normal, snapshot, restore!
export canonical_json, sha256_hex, float_bits_hex, CanonicalArray, CanonicalObject
export load_json, as_f64, as_int, as_bool, as_string, as_array, as_object,
       canonical_type_order

end
