# Per-step append-only deterministic gameplay event journal and ordered
# command buffer.
#
# Ports:
#   * src/systems/gameplay_events.lua   -> GameplayJournal
#   * src/systems/gameplay_commands.lua -> GameplayCommands
#   * src/systems/exportable.lua        -> payload deep copy (scalar/array/
#     object subset only; no validation layer, per the M3 brief)
#
# One journal instance is owned by each shot Engine. It is the authoritative
# record of "what happened during this fixed step, and in what order".
#
# Phases:
#   raw     -- objective facts produced during physics/bucket/fall-out. Raw
#              events preserve their original production order and may not be
#              appended after seal_raw!.
#   derived -- facts derived from raw events by explicit Engine processors
#              (peg_scored, style awards, ball state, shot completion).
#
# Envelope (added automatically): schema_version=1, step, shot_id, sequence
# (per-step, from 1, shared by both phases), phase, type.
#
# Payload ownership: payloads are deep-copied on entry into the journal, so a
# producer mutating its dict after emit/stage cannot change stored events
# (gameplay_events.lua lines 19-24, exportable.lua copy_value). Payloads only
# contain strings, finite numbers, booleans, and recursive Dicts/Vectors.
# Physics contacts use immutable typed payloads and can be retained directly;
# snapshot/export boundaries still return detached recursive dictionaries.
# Unlike the Lua version no rejection layer exists in M3 -- unsupported values
# are stored by reference.
#
# Events generated outside an open fixed step (e.g. launch input) are staged
# and deterministically flushed at the beginning of the next fixed step as raw
# events, with that step's shot_id (gameplay_events.lua lines 76-102).

const GAMEPLAY_EVENT_SCHEMA_VERSION = 1

include("contact_payloads.jl")
include("event_fields.jl")

# Journal payloads are the concrete EventFields superset. Command payloads use
# the concrete GameplayCommand record defined below.
const EventPayload = EventFields

struct GameEvent
    type::String
    phase::Symbol                      # :raw | :derived
    step::Int
    shot_id::Int
    sequence::Int
    fields::EventPayload
end

# Envelope keys + payload, JSON-ready. The payload is copied so callers can
# never reach back into journal-owned storage (snapshot() boundary in Lua).
# As in Lua, payload keys are merged after the envelope, so a payload key that
# collides with an envelope key wins.
function event_dict(ev::GameEvent)::Dict{String,Any}
    d = Dict{String,Any}(
        "schema_version" => GAMEPLAY_EVENT_SCHEMA_VERSION,
        "step" => ev.step,
        "shot_id" => ev.shot_id,
        "sequence" => ev.sequence,
        "phase" => String(ev.phase),
        "type" => ev.type,
    )
    for (k, v) in ev.fields
        d[k] = _copy_payload(v)
    end
    return d
end

# Deep copy of the exportable scalar/array/object subset. Scalars (numbers,
# strings, booleans, nothing) pass through; Dicts and Vectors are copied
# recursively so no producer-held container is ever retained by the journal.
function _copy_payload(v)
    if v isa AbstractDict
        out = Dict{String,Any}()
        for (k, x) in v
            out[string(k)] = _copy_payload(x)
        end
        return out
    elseif v isa AbstractVector || v isa Tuple
        return Any[_copy_payload(x) for x in v]
    elseif v isa NamedTuple
        out = Dict{String,Any}()
        for (k, x) in pairs(v)
            out[string(k)] = _copy_payload(x)
        end
        return out
    else
        return v
    end
end

# fields === nothing produces an empty payload, exactly like a Lua event with
# no payload table (the serialized form has no extra keys either way).
_owned_payload(::Nothing) = EventFields()
_owned_payload(fields::AbstractDict) = EventFields(fields)
_owned_payload(fields::NamedTuple) = EventFields(_copy_payload(fields))
# Safe to retain: EventFields is immutable; its line view is immutable and
# its vector fields reference producer-owned vectors that are not mutated
# after emission. Export still goes through _copy_payload, which materializes
# detached dictionaries.
@inline _owned_payload(fields::EventFields) = fields
@inline _owned_payload(fields::ContactPayload) = fields

# ---------------------------------------------------------------------------
# GameplayJournal
# ---------------------------------------------------------------------------

mutable struct GameplayJournal
    step_id::Int
    shot_id::Int
    sequence::Int
    raw_sealed::Bool
    open::Bool
    raw::Vector{GameEvent}
    derived::Vector{GameEvent}
    staged::Vector{Tuple{String,EventPayload}}
end

function GameplayJournal()
    j = GameplayJournal(
        0, 0, 0, false, false,
        GameEvent[], GameEvent[],
        Tuple{String,EventPayload}[])
    return reset!(j)
end

# GameplayEvents:reset (gameplay_events.lua lines 65-74).
function reset!(j::GameplayJournal)
    j.step_id = 0
    j.shot_id = 0
    j.sequence = 0
    j.raw_sealed = false
    j.open = false
    empty!(j.raw)
    empty!(j.derived)
    empty!(j.staged)
    return j
end

# GameplayEvents:stage (lines 80-86). The payload is copied NOW: later
# mutation of the caller's dict cannot affect the staged event. The frozen
# API accepts any dict literal (the copy normalizes the key type). Immutable
# contact payloads are retained directly, as with immediate emission.
function stage!(j::GameplayJournal, event_type::AbstractString, fields = nothing)
    owned = fields === nothing ? EventFields() : _owned_payload(fields)
    push!(j.staged, (String(event_type), owned))
    return j
end

# GameplayEvents:begin_step (lines 89-102). Flushes staged events as raw
# events (in staging order) with this step's shot_id.
function begin_step!(j::GameplayJournal, step_id::Int, shot_id::Int)
    j.step_id = step_id
    j.shot_id = shot_id
    j.sequence = 0
    j.raw_sealed = false
    empty!(j.raw)
    empty!(j.derived)
    j.open = true

    for (event_type, fields) in j.staged
        emit_raw!(j, event_type, fields)
    end
    empty!(j.staged)
    return j
end

# GameplayEvents:emit_raw (lines 106-133). The payload is copied FIRST so a
# rejected payload (not applicable in M3) would leave the journal untouched.
@inline function emit_raw!(j::GameplayJournal, event_type::AbstractString, fields = nothing)
    j.open || throw(ArgumentError(
        "GameplayEvents: emit_raw('$(event_type)') outside an open step"))
    j.raw_sealed && throw(ArgumentError(
        "GameplayEvents: emit_raw('$(event_type)') after seal_raw"))
    owned = _owned_payload(fields)
    j.sequence += 1
    push!(j.raw, GameEvent(
        String(event_type), :raw, j.step_id, j.shot_id, j.sequence, owned))
    return j
end

# GameplayEvents:seal_raw (lines 136-141).
function seal_raw!(j::GameplayJournal)
    j.open || throw(ArgumentError("GameplayEvents: seal_raw outside an open step"))
    j.raw_sealed = true
    return j
end

# GameplayEvents:emit_derived (lines 145-172). Only valid after seal_raw!.
@inline function emit_derived!(j::GameplayJournal, event_type::AbstractString, fields = nothing)
    j.open || throw(ArgumentError(
        "GameplayEvents: emit_derived('$(event_type)') outside an open step"))
    j.raw_sealed || throw(ArgumentError(
        "GameplayEvents: emit_derived('$(event_type)') before seal_raw"))
    owned = _owned_payload(fields)
    j.sequence += 1
    push!(j.derived, GameEvent(
        String(event_type), :derived, j.step_id, j.shot_id, j.sequence, owned))
    return j
end

# GameplayEvents:finish_step (lines 220-222). The step is complete even if
# empty; subsequent raw/derived emissions require a new begin_step!.
function finish_step!(j::GameplayJournal)
    j.open = false
    return j
end

# GameplayEvents:snapshot (lines 200-217). Detached deep copy of the completed
# step (raw + derived): mutating the result affects neither the journal nor
# previously retained snapshots.
function journal_snapshot(j::GameplayJournal)::NamedTuple
    return (
        schema_version = GAMEPLAY_EVENT_SCHEMA_VERSION,
        step = j.step_id,
        shot_id = j.shot_id,
        event_count = length(j.raw) + length(j.derived),
        raw = Dict{String,Any}[event_dict(ev) for ev in j.raw],
        derived = Dict{String,Any}[event_dict(ev) for ev in j.derived],
    )
end

# ---------------------------------------------------------------------------
# GameplayCommands
# ---------------------------------------------------------------------------

# Concrete command record: the envelope plus one typed slot per payload key the
# engine emits. Like EventFields this is an immutable, read-only AbstractDict
# view: iteration reproduces the detached Lua-shaped payload (absent keys are
# skipped), but no `Dict{String,Any}` is materialized on the step path.
#
# Ownership. A command is exported to Lua, so it must not alias caller-owned
# arrays. `push_command!` still detaches dictionary input (it copies the values
# into the typed slots / `extra`), and the engine's own emitters hand it
# scratch vectors from the per-buffer reuse pools that are never mutated after
# the push. The detached `Dict{String,Any}` payload is now materialized only at
# the export boundary (`command_snapshot`, `applied_snapshot`, the trace step
# record), where ownership changes hands exactly as before.
struct GameplayCommand <: AbstractDict{String,Any}
    type::String
    step::Int
    shot_id::Int
    sequence::Int
    ball_id::Union{Nothing,Int}
    style::Union{Nothing,String}
    points::Union{Nothing,Float64}
    distance::Union{Nothing,Float64}
    peg_id::Union{Nothing,Int}
    line_id::Union{Nothing,String}
    reason::Union{Nothing,String}
    source_sequences::Union{Nothing,Vector{Int}}
    peg_ids::Union{Nothing,Vector{Int}}
    status::Union{Nothing,String}
    extra::Union{Nothing,Dict{String,Any}}
end

# Key order of the exported Lua-shaped object: envelope first (as the frozen
# dict literal built it), then the payload slots, then `status` (applied
# records only), then cold-path overflow keys.
const _COMMAND_KEYS = (
    "step", "shot_id", "sequence", "type",
    "ball_id", "style", "points", "distance", "peg_id", "line_id", "reason",
    "source_sequences", "peg_ids", "status",
)
const _COMMAND_KEY_COUNT = length(_COMMAND_KEYS)

@inline function _command_slot_value(cmd::GameplayCommand, i::Int)
    i == 1 && return cmd.step
    i == 2 && return cmd.shot_id
    i == 3 && return cmd.sequence
    i == 4 && return cmd.type
    i == 5 && return cmd.ball_id
    i == 6 && return cmd.style
    i == 7 && return cmd.points
    i == 8 && return cmd.distance
    i == 9 && return cmd.peg_id
    i == 10 && return cmd.line_id
    i == 11 && return cmd.reason
    i == 12 && return cmd.source_sequences
    i == 13 && return cmd.peg_ids
    return cmd.status
end

@inline function _command_slot_index(key::AbstractString)::Int
    key == "step" && return 1
    key == "shot_id" && return 2
    key == "sequence" && return 3
    key == "type" && return 4
    key == "ball_id" && return 5
    key == "style" && return 6
    key == "points" && return 7
    key == "distance" && return 8
    key == "peg_id" && return 9
    key == "line_id" && return 10
    key == "reason" && return 11
    key == "source_sequences" && return 12
    key == "peg_ids" && return 13
    key == "status" && return 14
    return 0
end

@inline function _command_value(cmd::GameplayCommand, key::AbstractString)
    i = _command_slot_index(key)
    i != 0 && return _command_slot_value(cmd, i)
    extra = cmd.extra
    extra === nothing && return nothing
    return get(extra, key, nothing)
end

@inline function Base.get(cmd::GameplayCommand, key::AbstractString, default)
    value = _command_value(cmd, key)
    return value === nothing ? default : value
end
@inline Base.haskey(cmd::GameplayCommand, key::AbstractString) =
    _command_value(cmd, key) !== nothing
function Base.getindex(cmd::GameplayCommand, key::AbstractString)
    value = _command_value(cmd, key)
    value === nothing && throw(KeyError(key))
    return value
end

function Base.iterate(cmd::GameplayCommand)
    return _iterate_command(cmd, 1)
end
Base.iterate(cmd::GameplayCommand, state::Int) = _iterate_command(cmd, state)
function Base.iterate(cmd::GameplayCommand,
                      state::Tuple{Dict{String,Any},Any})
    next = iterate(state[1], state[2])
    next === nothing && return nothing
    pair, index = next
    return (pair, (state[1], index))
end

function _iterate_command(cmd::GameplayCommand, i::Int)
    while i <= _COMMAND_KEY_COUNT
        value = _command_slot_value(cmd, i)
        key = _COMMAND_KEYS[i]
        i += 1
        value === nothing || return (Pair{String,Any}(key, value), i)
    end
    extra = cmd.extra
    (extra === nothing || isempty(extra)) && return nothing
    next = iterate(extra)
    next === nothing && return nothing
    pair, index = next
    return (pair, (extra, index))
end

function Base.length(cmd::GameplayCommand)
    n = 0
    @inbounds for i in 1:_COMMAND_KEY_COUNT
        _command_slot_value(cmd, i) === nothing || (n += 1)
    end
    cmd.extra === nothing || (n += length(cmd.extra))
    return n
end
Base.keys(cmd::GameplayCommand) = [k for (k, _) in cmd]

# Detached record from the public dictionary API. Known keys fill their typed
# slot (with the slot's value type); anything else, including a value of the
# wrong shape for a known key, is deep-copied into `extra` so the exported
# object is byte-for-byte what a plain copy would have produced.
function _command_from_dict(type::AbstractString, step::Int, shot_id::Int,
                            sequence::Int, fields, status::Union{Nothing,String})
    ball_id = nothing
    style = nothing
    points = nothing
    distance = nothing
    peg_id = nothing
    line_id = nothing
    reason = nothing
    seqs = nothing
    pegs = nothing
    extra = nothing
    if fields !== nothing
        for (k, v) in fields
            ks = String(k)
            if ks == "ball_id" && v isa Integer && !(v isa Bool)
                ball_id = Int(v)
            elseif ks == "style" && v isa AbstractString
                style = String(v)
            elseif ks == "points" && v isa Real && !(v isa Bool)
                points = Float64(v)
            elseif ks == "distance" && v isa Real && !(v isa Bool)
                distance = Float64(v)
            elseif ks == "peg_id" && v isa Integer && !(v isa Bool)
                peg_id = Int(v)
            elseif ks == "line_id" && v isa AbstractString
                line_id = String(v)
            elseif ks == "reason" && v isa AbstractString
                reason = String(v)
            elseif ks == "source_sequences" && _is_int_vector(v)
                seqs = Int[Int(x) for x in v]
            elseif ks == "peg_ids" && _is_int_vector(v)
                pegs = Int[Int(x) for x in v]
            else
                extra === nothing && (extra = Dict{String,Any}())
                extra[ks] = _copy_payload(v)
            end
        end
    end
    return GameplayCommand(String(type), step, shot_id, sequence,
                           ball_id, style, points, distance, peg_id, line_id,
                           reason, seqs, pegs, status, extra)
end

function _is_int_vector(v)::Bool
    (v isa AbstractVector) || return false
    for x in v
        (x isa Integer && !(x isa Bool)) || return false
    end
    return true
end

mutable struct GameplayCommands
    step_id::Int
    shot_id::Int
    sequence::Int
    commands::Vector{GameplayCommand}
    applied::Vector{GameplayCommand}
    # Reuse pools for the two small payload vectors. A warmed step takes an
    # existing vector back instead of allocating, and the vectors are reused
    # only after every consumer of the previous step's payloads has finished
    # (the buffers are rewound at begin_step!/reset!). Never mutated after a
    # push, so the journal and the applied record can share them.
    seq_pool::Vector{Vector{Int}}
    seq_pool_n::Int
    peg_pool::Vector{Vector{Int}}
    peg_pool_n::Int
end

function GameplayCommands()
    c = GameplayCommands(
        0, 0, 0, GameplayCommand[], GameplayCommand[],
        Vector{Int}[], 0, Vector{Int}[], 0)
    return reset!(c)
end

# GameplayCommands:reset (gameplay_commands.lua lines 44-50).
function reset!(c::GameplayCommands)
    c.step_id = 0
    c.shot_id = 0
    c.sequence = 0
    empty!(c.commands)
    empty!(c.applied)
    c.seq_pool_n = 0
    c.peg_pool_n = 0
    return c
end

# GameplayCommands:begin_step (lines 52-58).
function begin_step!(c::GameplayCommands, step_id::Int, shot_id::Int)
    c.step_id = step_id
    c.shot_id = shot_id
    c.sequence = 0
    empty!(c.commands)
    empty!(c.applied)
    c.seq_pool_n = 0
    c.peg_pool_n = 0
    return c
end

@inline function _next_command_sequence!(c::GameplayCommands)::Int
    c.sequence += 1
    return c.sequence
end

# Take a pooled two-element `source_sequences` vector.
function _command_seq_pair!(c::GameplayCommands, a::Int, b::Int)::Vector{Int}
    if c.seq_pool_n < length(c.seq_pool)
        c.seq_pool_n += 1
        v = c.seq_pool[c.seq_pool_n]
        if length(v) == 2
            v[1] = a
            v[2] = b
        else
            resize!(v, 2)
            v[1] = a
            v[2] = b
        end
        return v
    end
    v = Int[a, b]
    push!(c.seq_pool, v)
    c.seq_pool_n = length(c.seq_pool)
    return v
end

# Pooled copy of an arbitrary-length `source_sequences` vector.
function _command_seq_vector!(c::GameplayCommands, src::AbstractVector)::Vector{Int}
    if c.seq_pool_n < length(c.seq_pool)
        c.seq_pool_n += 1
        v = c.seq_pool[c.seq_pool_n]
        empty!(v)
        for x in src
            push!(v, Int(x))
        end
        return v
    end
    v = Int[Int(x) for x in src]
    push!(c.seq_pool, v)
    c.seq_pool_n = length(c.seq_pool)
    return v
end

# Take an empty pooled scratch vector for `peg_ids` (filled by the caller
# before it is pushed into a command).
function take_peg_ids!(c::GameplayCommands)::Vector{Int}
    if c.peg_pool_n < length(c.peg_pool)
        c.peg_pool_n += 1
        v = c.peg_pool[c.peg_pool_n]
        empty!(v)
        return v
    end
    v = Int[]
    push!(c.peg_pool, v)
    c.peg_pool_n = length(c.peg_pool)
    return v
end

# Engine emitters: typed, allocation-free once the pools are warm.
@inline function _push_style_award!(c::GameplayCommands, ball_id::Int,
                                    style::String, points::Float64,
                                    peg_id::Union{Nothing,Int},
                                    distance::Union{Nothing,Float64},
                                    line_id::Union{Nothing,String},
                                    seqs::Vector{Int})
    push!(c.commands, GameplayCommand(
        "award_style_points", c.step_id, c.shot_id,
        _next_command_sequence!(c), ball_id, style, points, distance, peg_id,
        line_id, nothing, seqs, nothing, nothing, nothing))
    return c
end

@inline function push_style_award!(c::GameplayCommands, ball_id::Int,
                                   style::String, points::Float64,
                                   peg_id::Union{Nothing,Int},
                                   distance::Union{Nothing,Float64},
                                   seq_a::Int, seq_b::Int,
                                   line_id = nothing)
    return _push_style_award!(c, ball_id, style, points, peg_id, distance,
                              line_id, _command_seq_pair!(c, seq_a, seq_b))
end

# Variable-length `source_sequences` (the slide run is `slide_min` long).
@inline function push_style_award_seqs!(c::GameplayCommands, ball_id::Int,
                                        style::String, points::Float64,
                                        line_id::String, seqs::Vector{Int})
    return _push_style_award!(c, ball_id, style, points, nothing, nothing,
                              line_id, _command_seq_vector!(c, seqs))
end

@inline function push_start_midturn_clearing!(c::GameplayCommands,
                                              reason::String)
    push!(c.commands, GameplayCommand(
        "start_midturn_clearing", c.step_id, c.shot_id,
        _next_command_sequence!(c), nothing, nothing, nothing, nothing, nothing,
        nothing, reason, nothing, nothing, nothing, nothing))
    return c
end

@inline function push_remove_slide_pegs!(c::GameplayCommands, ball_id::Int,
                                         line_id::String, reason::String,
                                         peg_ids::Vector{Int})
    push!(c.commands, GameplayCommand(
        "remove_slide_pegs", c.step_id, c.shot_id,
        _next_command_sequence!(c), ball_id, nothing, nothing, nothing, nothing,
        line_id, reason, nothing, peg_ids, nothing, nothing))
    return c
end

# GameplayCommands:push (lines 60-80). The public dictionary form still
# detaches the caller's payload at push time; the engine emits typed records
# through the helpers above.
function push_command!(c::GameplayCommands, command_type::AbstractString,
                       fields = nothing)
    push!(c.commands, _command_from_dict(
        command_type, c.step_id, c.shot_id, _next_command_sequence!(c),
        fields, nothing))
    return c
end

# GameplayCommands:record_applied (lines 97-101): stores an independent copy
# plus a stable scalar status ("applied" | "ignored_duplicate").
@inline function record_applied!(c::GameplayCommands, cmd::GameplayCommand,
                                 status::AbstractString = "applied")
    push!(c.applied, GameplayCommand(
        cmd.type, cmd.step, cmd.shot_id, cmd.sequence,
        cmd.ball_id, cmd.style, cmd.points, cmd.distance, cmd.peg_id,
        cmd.line_id, cmd.reason, cmd.source_sequences, cmd.peg_ids,
        String(status), cmd.extra))
    return c
end

function record_applied!(c::GameplayCommands, cmd::AbstractDict,
                         status::AbstractString = "applied")
    push!(c.applied, _command_from_dict(
        get(cmd, "type", ""), Int(get(cmd, "step", c.step_id)),
        Int(get(cmd, "shot_id", c.shot_id)), Int(get(cmd, "sequence", 0)),
        cmd, String(status)))
    return c
end

# GameplayCommands:snapshot (lines 87-91): requested commands this step.
# Detached recursive dictionaries are materialized here, never on the step
# path: this is the ownership hand-off to Lua/tests/trace output.
function command_snapshot(c::GameplayCommands)::Vector{Dict{String,Any}}
    return Dict{String,Any}[_copy_payload(cmd) for cmd in c.commands]
end

# GameplayCommands:applied_snapshot (lines 104-108): the applied journal.
function applied_snapshot(c::GameplayCommands)::Vector{Dict{String,Any}}
    return Dict{String,Any}[_copy_payload(cmd) for cmd in c.applied]
end

# GameplayCommands:clear (lines 110-113); the Engine calls this after
# finish_step! (core.lua line 1529). Kept as a superset of the frozen API.
function clear!(c::GameplayCommands)
    empty!(c.commands)
    empty!(c.applied)
    c.seq_pool_n = 0
    c.peg_pool_n = 0
    return c
end
