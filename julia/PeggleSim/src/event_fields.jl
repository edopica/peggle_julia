# Concrete, allocation-free gameplay-event payload.
#
# The journal is authoritative and is read by the peg reducer, StyleShots,
# SlideInversion, BallState, and the trace exporter. An earlier design stored
# the payload as `Union{Dict{String,Any},ContactPayload}`; because that union
# has a non-isbits member, Julia boxed every ContactPayload on entry
# (288 B/event) and boxed scalar `get` results at each consumer. This struct
# is a concrete superset: all fields are stored unboxed (Nothing means the
# key is absent), so emitting into a warmed journal and reading fields are
# allocation-free.
#
# The key set and value types mirror the Lua payloads exactly. Line metadata
# is flattened into `line_meta_*` fields (a nested ContactLine is
# materialized only at the trace boundary) so no non-isbits object has to be
# boxed on the hot path. `source_sequences`/`peg_ids` reference
# producer-owned vectors that are never mutated after emission.
Base.@kwdef struct EventFields <: AbstractDict{String,Any}
    # Contact / physics facts.
    ball_id::Union{Nothing,Int} = nothing
    peg_id::Union{Nothing,Int} = nothing
    peg_type::Union{Nothing,String} = nothing
    peg_shape::Union{Nothing,String} = nothing
    line_meta_id::Union{Nothing,String} = nothing
    line_meta_index::Union{Nothing,Int} = nothing
    line_meta_count::Union{Nothing,Int} = nothing
    line_meta_closed::Union{Nothing,Bool} = nothing
    line_meta_gap::Union{Nothing,Float64} = nothing
    contact_kind::Union{Nothing,String} = nothing
    did_bounce::Union{Nothing,Bool} = nothing
    impact_x::Union{Nothing,Float64} = nothing
    impact_y::Union{Nothing,Float64} = nothing
    frame_t::Union{Nothing,Float64} = nothing
    toi::Union{Nothing,Float64} = nothing
    iteration::Union{Nothing,Int} = nothing
    normal_x::Union{Nothing,Float64} = nothing
    normal_y::Union{Nothing,Float64} = nothing
    incoming_vx::Union{Nothing,Float64} = nothing
    incoming_vy::Union{Nothing,Float64} = nothing
    outgoing_vx::Union{Nothing,Float64} = nothing
    outgoing_vy::Union{Nothing,Float64} = nothing
    other_ball_id::Union{Nothing,Int} = nothing
    other_outgoing_vx::Union{Nothing,Float64} = nothing
    other_outgoing_vy::Union{Nothing,Float64} = nothing
    peg_x::Union{Nothing,Float64} = nothing
    peg_y::Union{Nothing,Float64} = nothing
    peg_angle::Union{Nothing,Float64} = nothing
    peg_theta::Union{Nothing,Float64} = nothing
    wall::Union{Nothing,String} = nothing

    # Scoring / derived facts.
    source_sequence::Union{Nothing,Int} = nothing
    hit_order::Union{Nothing,Int} = nothing
    multiplier_at_hit::Union{Nothing,Int} = nothing
    peg_value::Union{Nothing,Float64} = nothing

    # Style / commands / bucket / lifecycle facts.
    style::Union{Nothing,String} = nothing
    points::Union{Nothing,Float64} = nothing
    distance::Union{Nothing,Float64} = nothing
    line_id::Union{Nothing,String} = nothing
    reason::Union{Nothing,String} = nothing
    completion_reason::Union{Nothing,String} = nothing
    source::Union{Nothing,String} = nothing
    value::Union{Nothing,Float64} = nothing
    bucket_x::Union{Nothing,Float64} = nothing
    x::Union{Nothing,Float64} = nothing
    y::Union{Nothing,Float64} = nothing
    vx::Union{Nothing,Float64} = nothing
    vy::Union{Nothing,Float64} = nothing
    elapsed::Union{Nothing,Float64} = nothing
    initial_step::Union{Nothing,Int} = nothing
    final_step::Union{Nothing,Int} = nothing
    shot_id::Union{Nothing,Int} = nothing
    peg_score::Union{Nothing,Float64} = nothing
    bonus_score::Union{Nothing,Float64} = nothing
    style_score::Union{Nothing,Float64} = nothing
    total_score::Union{Nothing,Float64} = nothing
    source_sequences::Union{Nothing,AbstractVector} = nothing
    peg_ids::Union{Nothing,AbstractVector} = nothing

    # Cold-path overflow for payload keys outside the fixed schema (the public
    # `emit_raw!`/`stage!` API accepts an arbitrary dictionary). Always
    # `nothing` for the hot emitters, so it costs nothing in the step path.
    extra::Union{Nothing,Dict{String,Any}} = nothing
end

# Schema field count excludes the `extra` overflow slot.
const _EVENT_SCHEMA_FIELDS = fieldcount(EventFields) - 1
const _EVENT_FIELD_NAMES = map(String, fieldnames(EventFields)[1:_EVENT_SCHEMA_FIELDS])
const _EVENT_FIELD_NAME_SET = Set(_EVENT_FIELD_NAMES)

@inline _line_complete(fields::EventFields) =
    fields.line_meta_id !== nothing && fields.line_meta_index !== nothing &&
    fields.line_meta_count !== nothing && fields.line_meta_closed !== nothing &&
    fields.line_meta_gap !== nothing

@inline function _event_value(fields::EventFields, key::AbstractString)
    if key == "line"
        _line_complete(fields) || return nothing
        return ContactLine(fields.line_meta_id, fields.line_meta_index::Int,
                           fields.line_meta_count::Int,
                           fields.line_meta_closed::Bool,
                           fields.line_meta_gap::Float64)
    end
    @inbounds for i in 1:_EVENT_SCHEMA_FIELDS
        if key == _EVENT_FIELD_NAMES[i]
            return getfield(fields, i)
        end
    end
    extra = fields.extra
    extra === nothing && return nothing
    return get(extra, key, nothing)
end

# Cold path: build a payload from an arbitrary dictionary. Known schema keys
# populate their typed slot (the "line" object flattens into line_meta_*),
# unknown keys land in `extra`, and vectors are copied so the journal never
# retains a producer-owned container.
function EventFields(d::AbstractDict)::EventFields
    raw_line = get(d, "line", nothing)
    # Only a complete line object flattens into line_meta_*; a partial one is
    # kept verbatim in `extra` so the exported payload matches the input.
    line = raw_line isa AbstractDict && haskey(raw_line, "id") &&
           haskey(raw_line, "index") && haskey(raw_line, "count") &&
           haskey(raw_line, "closed") && haskey(raw_line, "gap") ? raw_line : nothing
    vals = ntuple(_EVENT_SCHEMA_FIELDS) do i
        name = _EVENT_FIELD_NAMES[i]
        if startswith(name, "line_meta_")
            line === nothing && return nothing
            return get(line, name[11:end], nothing)
        end
        v = get(d, name, nothing)
        return v isa AbstractVector ? copy(v) : v
    end
    extra = nothing
    for (k, v) in d
        ks = String(k)
        ((ks == "line" && line !== nothing) || ks in _EVENT_FIELD_NAME_SET) && continue
        extra === nothing && (extra = Dict{String,Any}())
        extra[ks] = _copy_payload(v)
    end
    return EventFields(vals..., extra)
end

Base.convert(::Type{EventFields}, d::AbstractDict) = EventFields(d)

@inline function Base.get(fields::EventFields, key::AbstractString, default)
    value = _event_value(fields, key)
    return value === nothing ? default : value
end
@inline Base.haskey(fields::EventFields, key::AbstractString) =
    _event_value(fields, key) !== nothing
function Base.getindex(fields::EventFields, key::AbstractString)
    value = _event_value(fields, key)
    value === nothing && throw(KeyError(key))
    return value
end

# Iteration exposes the Lua-shaped key set: the flattened line_meta_* fields
# collapse into one nested "line" object, absent keys are skipped, and cold
# overflow keys follow the schema fields.
function Base.iterate(fields::EventFields)
    return _iterate_schema(fields, 1)
end
Base.iterate(fields::EventFields, state::Int) = _iterate_schema(fields, state)
function Base.iterate(fields::EventFields,
                      state::Tuple{Dict{String,Any},Any})
    next = iterate(state[1], state[2])
    next === nothing && return nothing
    pair, index = next
    return (pair, (state[1], index))
end

function _iterate_schema(fields::EventFields, i::Int)
    n = _EVENT_SCHEMA_FIELDS
    while i <= n
        key = _EVENT_FIELD_NAMES[i]
        value = getfield(fields, i)
        i += 1
        startswith(key, "line_meta_") && continue
        value === nothing || return (Pair{String,Any}(key, value), i)
    end
    if i == n + 1
        i = n + 2
        if _line_complete(fields)
            line = ContactLine(fields.line_meta_id, fields.line_meta_index::Int,
                               fields.line_meta_count::Int,
                               fields.line_meta_closed::Bool,
                               fields.line_meta_gap::Float64)
            return (Pair{String,Any}("line", line), i)
        end
    end
    extra = fields.extra
    (extra === nothing || isempty(extra)) && return nothing
    next = iterate(extra)
    next === nothing && return nothing
    pair, index = next
    return (pair, (extra, index))
end

function Base.length(fields::EventFields)
    n = 0
    @inbounds for i in 1:_EVENT_SCHEMA_FIELDS
        startswith(_EVENT_FIELD_NAMES[i], "line_meta_") && continue
        getfield(fields, i) === nothing || (n += 1)
    end
    fields.line_meta_id === nothing || (n += 1)
    fields.extra === nothing || (n += length(fields.extra))
    return n
end
Base.keys(fields::EventFields) =
    [k for (k, _) in fields]
