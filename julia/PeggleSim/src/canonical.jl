# Canonical JSON encoder, byte-compatible with tools/canonical_json.lua.
#
# Rules (see the Lua tool for the authoritative description):
#   * object keys are emitted in ascending lexicographic byte order;
#   * arrays keep their order;
#   * integral doubles with |v| < 2^53 are emitted as decimal integers
#     without a fractional part; every other finite value uses %.17g;
#   * negative zero is preserved as -0;
#   * NaN and infinities are rejected;
#   * container kinds are explicit in Julia: a Vector is an array and a Dict
#     is an object, so empty ones are never ambiguous. CanonicalArray and
#     CanonicalObject exist to force a kind on a container whose Julia type
#     does not already express it (and to mirror the Lua marker API).
#   * no timestamps or host data ever appear in the output.

struct CanonicalArray
    items::Vector{Any}
end

CanonicalArray() = CanonicalArray(Any[])
CanonicalArray(items::AbstractVector) = CanonicalArray(Vector{Any}(items))

struct CanonicalObject
    items::Dict{String,Any}
end

CanonicalObject() = CanonicalObject(Dict{String,Any}())

function CanonicalObject(items::AbstractDict)
    d = Dict{String,Any}()
    for (k, v) in items
        d[_canonical_key(k)] = v
    end
    return CanonicalObject(d)
end

function _canonical_key(k)
    if k isa AbstractString
        return String(k)
    elseif k isa Symbol
        return String(k)
    else
        throw(ArgumentError("CanonicalJSON: object key is a $(typeof(k)); only string keys are supported"))
    end
end

const CANONICAL_MAX_SAFE_INTEGER = 9007199254740992.0

function canonical_json(value)::String
    io = IOBuffer()
    _encode_value!(io, value, "\$")
    return String(take!(io))
end

function _encode_value!(io::IO, v, path::AbstractString)
    if v === nothing || v === missing
        write(io, "null")
    elseif v isa Bool
        write(io, v ? "true" : "false")
    elseif v isa CanonicalArray
        _encode_array!(io, v.items, path)
    elseif v isa CanonicalObject
        _encode_object!(io, v.items, path)
    elseif v isa AbstractVector
        _encode_array!(io, v, path)
    elseif v isa AbstractDict
        _encode_object!(io, v, path)
    elseif v isa NamedTuple
        _encode_object!(io, v, path)
    elseif v isa Tuple
        _encode_array!(io, v, path)
    elseif v isa AbstractString
        _encode_string!(io, v)
    elseif v isa Integer
        _encode_number!(io, Float64(v), path)
    elseif v isa AbstractFloat
        _encode_number!(io, Float64(v), path)
    else
        throw(ArgumentError("CanonicalJSON: cannot encode value of type $(typeof(v)) at $(path)"))
    end
    return nothing
end

function _encode_array!(io::IO, items, path::AbstractString)
    write(io, UInt8('['))
    i = 0
    for v in items
        i += 1
        i > 1 && write(io, UInt8(','))
        _encode_value!(io, v, path * "[" * string(i) * "]")
    end
    write(io, UInt8(']'))
    return nothing
end

function _encode_object!(io::IO, d::NamedTuple, path::AbstractString)
    keys_sorted = sort!([String(k) for k in Base.keys(d)])
    write(io, UInt8('{'))
    for (i, k) in enumerate(keys_sorted)
        i > 1 && write(io, UInt8(','))
        _encode_string!(io, k)
        write(io, UInt8(':'))
        _encode_value!(io, getfield(d, Symbol(k)), path * "." * k)
    end
    write(io, UInt8('}'))
    return nothing
end

function _encode_object!(io::IO, d::AbstractDict, path::AbstractString)
    pairs_sorted = sort!(collect(d); by = kv -> _canonical_key(kv.first))
    write(io, UInt8('{'))
    for (i, kv) in enumerate(pairs_sorted)
        i > 1 && write(io, UInt8(','))
        key = _canonical_key(kv.first)
        _encode_string!(io, key)
        write(io, UInt8(':'))
        _encode_value!(io, kv.second, path * "." * key)
    end
    write(io, UInt8('}'))
    return nothing
end

function _encode_string!(io::IO, s::AbstractString)
    write(io, UInt8('"'))
    for b in codeunits(s)
        if b == UInt8('"')
            write(io, "\\\"")
        elseif b == UInt8('\\')
            write(io, "\\\\")
        elseif b == 0x08
            write(io, "\\b")
        elseif b == 0x0c
            write(io, "\\f")
        elseif b == 0x0a
            write(io, "\\n")
        elseif b == 0x0d
            write(io, "\\r")
        elseif b == 0x09
            write(io, "\\t")
        elseif b < 0x20
            write(io, @sprintf("\\u%04x", b))
        else
            write(io, b)
        end
    end
    write(io, UInt8('"'))
    return nothing
end

function _encode_number!(io::IO, x::Float64, path::AbstractString)
    if isnan(x)
        throw(ArgumentError("CanonicalJSON: cannot encode NaN at $(path)"))
    end
    if isinf(x)
        throw(ArgumentError("CanonicalJSON: cannot encode infinity at $(path)"))
    end
    if x == 0.0 && signbit(x)
        write(io, "-0")
        return nothing
    end
    if isinteger(x) && abs(x) < CANONICAL_MAX_SAFE_INTEGER
        write(io, string(Int64(x)))
        return nothing
    end
    write(io, @sprintf("%.17g", x))
    return nothing
end

# SHA-256 of raw bytes when given a string, of the canonical encoding
# otherwise. Kept here so artifacts and their hashes always agree.
sha256_hex(data::AbstractString)::String =
    bytes2hex(SHA.sha256(Vector{UInt8}(codeunits(data))))

sha256_hex(data::AbstractVector{UInt8})::String =
    bytes2hex(SHA.sha256(Vector{UInt8}(data)))

sha256_hex(x)::String = sha256_hex(canonical_json(x))

float_bits_hex(x::Float64)::String = @sprintf("0x%016x", reinterpret(UInt64, x))
