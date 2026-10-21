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

# Journal payloads are the concrete EventFields superset. Commands keep their
# own Dict payloads; they are not part of the steady-state stepping gate.
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
_owned_payload(fields::EventFields) = fields
_owned_payload(fields::ContactPayload) = fields

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
function emit_raw!(j::GameplayJournal, event_type::AbstractString, fields = nothing)
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
function emit_derived!(j::GameplayJournal, event_type::AbstractString, fields = nothing)
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

mutable struct GameplayCommands
    step_id::Int
    shot_id::Int
    sequence::Int
    commands::Vector{Dict{String,Any}}
    applied::Vector{Dict{String,Any}}
end

function GameplayCommands()
    c = GameplayCommands(
        0, 0, 0, Dict{String,Any}[], Dict{String,Any}[])
    return reset!(c)
end

# GameplayCommands:reset (gameplay_commands.lua lines 44-50).
function reset!(c::GameplayCommands)
    c.step_id = 0
    c.shot_id = 0
    c.sequence = 0
    empty!(c.commands)
    empty!(c.applied)
    return c
end

# GameplayCommands:begin_step (lines 52-58).
function begin_step!(c::GameplayCommands, step_id::Int, shot_id::Int)
    c.step_id = step_id
    c.shot_id = shot_id
    c.sequence = 0
    empty!(c.commands)
    empty!(c.applied)
    return c
end

# GameplayCommands:push (lines 60-80). The payload is deep-copied at push
# time, so caller-owned arrays (e.g. source_sequences) are never retained.
function push_command!(c::GameplayCommands, command_type::AbstractString, fields = nothing)
    # Command payloads stay plain detached dictionaries: they are exported to
    # Lua and are not part of the steady-state stepping gate.
    owned = fields === nothing ? EventFields() : _copy_payload(fields)
    c.sequence += 1
    cmd = Dict{String,Any}(
        "step" => c.step_id,
        "shot_id" => c.shot_id,
        "sequence" => c.sequence,
        "type" => String(command_type),
    )
    for (k, v) in owned
        cmd[k] = v
    end
    push!(c.commands, cmd)
    return c
end

# GameplayCommands:record_applied (lines 97-101): stores an independent copy
# plus a stable scalar status ("applied" | "ignored_duplicate").
function record_applied!(c::GameplayCommands, cmd::AbstractDict,
                         status::AbstractString = "applied")
    rec = _copy_payload(cmd)
    rec["status"] = String(status)
    push!(c.applied, rec)
    return c
end

# GameplayCommands:snapshot (lines 87-91): requested commands this step.
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
    return c
end
