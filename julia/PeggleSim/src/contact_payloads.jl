# Internal, read-only string-keyed views. All reachable values are immutable;
# no live Peg/BallState or producer-owned containers may be stored here.
# `nothing` means an absent key, matching Lua's nil-assignment semantics.
abstract type ImmutableContactFields <: AbstractDict{String,Any} end

struct ContactLine <: ImmutableContactFields
    id::String
    index::Int
    count::Int
    closed::Bool
    gap::Float64
end
ContactLine(line::LineMetadata) =
    ContactLine(line.id, line.index, line.count, line.closed, line.gap)

Base.@kwdef struct ContactPayload <: ImmutableContactFields
    ball_id::Int
    contact_kind::String
    did_bounce::Bool
    impact_x::Float64
    impact_y::Float64
    frame_t::Float64
    toi::Float64
    iteration::Int
    normal_x::Float64
    normal_y::Float64
    incoming_vx::Float64
    incoming_vy::Float64
    outgoing_vx::Float64
    outgoing_vy::Float64
    other_ball_id::Union{Nothing,Int} = nothing
    other_outgoing_vx::Union{Nothing,Float64} = nothing
    other_outgoing_vy::Union{Nothing,Float64} = nothing
    peg_id::Union{Nothing,Int} = nothing
    peg_type::Union{Nothing,String} = nothing
    peg_shape::Union{Nothing,String} = nothing
    line::Union{Nothing,ContactLine} = nothing
    peg_x::Union{Nothing,Float64} = nothing
    peg_y::Union{Nothing,Float64} = nothing
    peg_angle::Union{Nothing,Float64} = nothing
    peg_theta::Union{Nothing,Float64} = nothing
    wall::Union{Nothing,String} = nothing
end

# Literal field access keeps string-keyed consumers compatible without building
# a dictionary (or interning caller-supplied keys). Generate these small methods
# once, rather than allocating key strings for each lookup/iteration.
for T in (ContactLine, ContactPayload)
    names = fieldnames(T)
    keynames = map(String, names)
    @eval _contact_keys(::Type{$T}) = $keynames
    branches = [:(key == $(String(name)) && return getfield(fields, $(QuoteNode(name))))
                for name in names]
    @eval @inline function _contact_value(fields::$T, key::AbstractString)
        $(branches...)
        return nothing
    end
end

@inline function Base.get(fields::ImmutableContactFields, key::AbstractString, default)
    value = _contact_value(fields, key)
    return value === nothing ? default : value
end
@inline Base.haskey(fields::ImmutableContactFields, key::AbstractString) =
    _contact_value(fields, key) !== nothing
function Base.getindex(fields::ImmutableContactFields, key::AbstractString)
    value = _contact_value(fields, key)
    value === nothing && throw(KeyError(key))
    return value
end

function Base.iterate(fields::ImmutableContactFields, i::Int = 1)
    names = _contact_keys(typeof(fields))
    while i <= length(names)
        value = getfield(fields, i)
        key = names[i]
        i += 1
        value === nothing || return (Pair{String,Any}(key, value), i)
    end
    return nothing
end
Base.length(fields::ImmutableContactFields) =
    count(i -> getfield(fields, i) !== nothing, 1:fieldcount(typeof(fields)))
