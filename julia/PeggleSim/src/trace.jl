# Port of ../peggle_evolved/src/systems/gameplay_trace_exporter.lua.
#
# Canonical versioned JSONL gameplay trace: one JSON object per fixed step.
# The encoder is deterministic: object keys are emitted in sorted order and
# numbers use the Lua encoder's rules (full precision %.17g, integral values
# with |v| < 1e15 as integer tokens including "-0", NaN/Inf -> null), so two
# runs under the same runtime/config/seed produce byte-identical traces.
#
# Header: {"include_snapshot":bool,"kind":"gameplay_trace","schema_version":1}
# plus a math_backend identity block only when the DetMath backend is not the
# default system_libm (so the historical byte stream is unchanged on Linux).

const TRACE_SCHEMA_VERSION = 1

mutable struct GameplayTraceWriter
    io::IOStream
    include_snapshot::Bool
    steps_written::Int
end

# Lua string escaping order (gameplay_trace_exporter.lua lines 46-48): the
# backslash pass runs first so the sequences introduced by the later passes
# are not re-escaped.
function _trace_escape_string(s::AbstractString)::String
    out = replace(s, "\\" => "\\\\")
    out = replace(out, "\"" => "\\\"")
    out = replace(out, "\n" => "\\n")
    out = replace(out, "\r" => "\\r")
    out = replace(out, "\t" => "\\t")
    out = replace(out, "\b" => "\\b")
    out = replace(out, "\f" => "\\f")
    return out
end

# Lua `tostring(math.floor(v))` for integral doubles: plain integer text,
# with -0.0 keeping its sign ("-0").
function _trace_integral_token(v::Float64)::String
    if v == 0.0
        return signbit(v) ? "-0" : "0"
    end
    return string(Int(v))
end

function _trace_encode_number(v::Real, io::IOBuffer)::Nothing
    if v isa Bool
        print(io, v ? "true" : "false")
        return nothing
    end
    if v isa Integer
        print(io, string(v))
        return nothing
    end
    f = Float64(v)
    if isnan(f) || f == Inf || f == -Inf
        print(io, "null")
    elseif f == floor(f) && abs(f) < 1e15
        print(io, _trace_integral_token(f))
    else
        print(io, Printf.@sprintf("%.17g", f))
    end
    return nothing
end

function _trace_encode_dict(d::AbstractDict, io::IOBuffer)::Nothing
    # An empty Lua table serializes as [] (no keys -> array branch). All
    # journal payload objects carry at least one key; mirroring the rule
    # keeps trace_json faithful for empty dicts too.
    if isempty(d)
        print(io, "[]")
        return nothing
    end
    sorted_keys = sort!([string(k) for k in keys(d)])
    print(io, "{")
    for (i, k) in enumerate(sorted_keys)
        i > 1 && print(io, ",")
        print(io, "\"", _trace_escape_string(k), "\":")
        _trace_encode(d[k], io)
    end
    print(io, "}")
    return nothing
end

function _trace_encode(v, io::IOBuffer)::Nothing
    if v === nothing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa Real
        _trace_encode_number(v, io)
    elseif v isa AbstractString
        print(io, "\"", _trace_escape_string(v), "\"")
    elseif v isa AbstractDict
        _trace_encode_dict(v, io)
    elseif v isa AbstractVector || v isa Tuple
        print(io, "[")
        for (i, x) in enumerate(v)
            i > 1 && print(io, ",")
            _trace_encode(x, io)
        end
        print(io, "]")
    else
        # functions/userdata/threads (and any unsupported type): null.
        print(io, "null")
    end
    return nothing
end

# Deterministic JSON encoding following the Lua encoder.
function trace_json(value)::String
    io = IOBuffer()
    _trace_encode(value, io)
    return String(take!(io))
end

# JSON-ready math backend identity block. Only emitted for non-default
# backends; the CompareTraces contract treats it as scope metadata.
function _trace_math_backend_block()::Dict{String,Any}
    id = DetMath.math_backend_identity()
    return Dict{String,Any}(
        "name" => String(id.backend),
        "library" => String(id.library),
    )
end

function trace_open(path::AbstractString; include_snapshot::Bool = true)::GameplayTraceWriter
    io = open(path, "w")
    writer = GameplayTraceWriter(io, include_snapshot, 0)
    header = Dict{String,Any}(
        "schema_version" => TRACE_SCHEMA_VERSION,
        "kind" => "gameplay_trace",
        "include_snapshot" => include_snapshot,
    )
    if DetMath.MATH_BACKEND[] !== :system_libm
        header["math_backend"] = _trace_math_backend_block()
    end
    println(io, trace_json(header))
    return writer
end

# Write one completed step record (already built with the optional snapshot).
function trace_write_step!(t::GameplayTraceWriter, step_record::Dict{String,Any})::Nothing
    println(t.io, trace_json(step_record))
    t.steps_written += 1
    return nothing
end

function trace_close!(t::GameplayTraceWriter)::Nothing
    close(t.io)
    return nothing
end
