# Small typed accessors over JSON.parsefile results.
#
# JSON.jl parses objects as Dict{String,Any} and arrays as Vector{Any};
# integral literals become Int64 and everything else Float64. These helpers
# keep the consuming code explicit about the expected type and fail loudly
# on a mismatch instead of silently converting.

function load_json(path::AbstractString)
    return JSON.parsefile(path)
end

function as_f64(x, what::AbstractString = "value")::Float64
    if !(x isa Real) || x isa Bool
        throw(ArgumentError("$(what) must be a number, got $(typeof(x))"))
    end
    return Float64(x)
end

function as_int(x, what::AbstractString = "value")::Int
    if x isa Integer && !(x isa Bool)
        return Int(x)
    elseif x isa AbstractFloat && isfinite(x) && isinteger(x)
        return Int(x)
    else
        throw(ArgumentError("$(what) must be an integer, got $(repr(x))"))
    end
end

function as_bool(x, what::AbstractString = "value")::Bool
    x isa Bool || throw(ArgumentError("$(what) must be a boolean, got $(repr(x))"))
    return x
end

function as_string(x, what::AbstractString = "value")::String
    x isa AbstractString || throw(ArgumentError("$(what) must be a string, got $(repr(x))"))
    return String(x)
end

function as_array(x, what::AbstractString = "value")
    x isa AbstractVector || throw(ArgumentError("$(what) must be an array, got $(typeof(x))"))
    return x
end

function as_object(x, what::AbstractString = "value")
    x isa AbstractDict || throw(ArgumentError("$(what) must be an object, got $(typeof(x))"))
    return x
end

# Frozen order used whenever peg types are serialized or iterated:
# (blue, green, purple, red).
const CANONICAL_TYPE_ORDER = (:blue, :green, :purple, :red)

canonical_type_order() = CANONICAL_TYPE_ORDER

function canonical_type_order(t::Symbol)::Int
    i = findfirst(==(t), CANONICAL_TYPE_ORDER)
    i === nothing && throw(ArgumentError("unknown peg type: $(t)"))
    return i
end

canonical_type_order(types) = sort!(collect(types); by = canonical_type_order)
