# Level artifact parsing (interchange/levels/<name>.v1.json, peggle.level v1).
#
# The artifact is the authoritative static board: peg order, contiguous ids,
# effective type counts, line metadata, and the reference provenance. Motion
# is rejected: v1 supports static levels only, so a level with a non-static
# `motion` or with any circuit collection is a hard load error.

abstract type AbstractPegShape end

struct CircleShape <: AbstractPegShape
    radius::Float64
end

struct RectangleShape <: AbstractPegShape
    width::Float64
    height::Float64
    angle::Float64
end

struct AnnularShape <: AbstractPegShape
    r_in::Float64
    r_out::Float64
    theta_start::Float64
    theta_end_abs::Float64
    segments::Int
end

# Line metadata copied verbatim from the artifact. `id` is a level-authored
# string identifier (the level schema requires a string and the captured
# checkpoints serialize those strings verbatim), so the brief's `id::Int`
# sketch is superseded by the artifact contract.
struct LineMetadata
    id::String
    index::Int
    count::Int
    closed::Bool
    gap::Float64
end

mutable struct Peg
    id::Int
    x::Float64
    y::Float64
    base_x::Float64
    base_y::Float64
    shape::Union{CircleShape,RectangleShape,AnnularShape}
    peg_type::Symbol
    hit::Bool
    hit_order::Int
    multiplier_at_hit::Int
    line::Union{Nothing,LineMetadata}
end

struct LevelDefinition
    name::String
    virtual_width::Float64
    virtual_height::Float64
    level_seed::Int
    type_counts::NamedTuple{(:blue, :green, :purple, :red),NTuple{4,Int}}
    default_peg_type::Symbol
    pegs::Vector{Peg}
    provenance::NamedTuple
    level_sha256::String
end

const LEVEL_TOP_LEVEL_KEYS = (
    "format", "schema_version", "name", "motion", "virtual_width",
    "virtual_height", "level_seed", "type_counts", "default_peg_type",
    "pegs", "provenance",
)

const LEVEL_CIRCUIT_KEYS = ("circuits", "level_circuits", "motion_circuits")

const VALID_PEG_TYPES = (:blue, :green, :purple, :red)

function _parse_peg_type(x, what::AbstractString)::Symbol
    t = Symbol(as_string(x, what))
    t in VALID_PEG_TYPES || throw(ArgumentError("$(what): unknown peg type '$(t)'"))
    return t
end

function _parse_line(x, what::AbstractString)::LineMetadata
    d = as_object(x, what)
    return LineMetadata(
        as_string(d["id"], "$(what).id"),
        as_int(d["index"], "$(what).index"),
        as_int(d["count"], "$(what).count"),
        as_bool(d["closed"], "$(what).closed"),
        as_f64(d["gap"], "$(what).gap"),
    )
end

function _parse_peg(x, index::Int)::Peg
    d = as_object(x, "pegs[$(index)]")
    id = as_int(d["id"], "pegs[$(index)].id")
    id == index || throw(ArgumentError(
        "level: peg ids must be contiguous in level order: pegs[$(index)].id == $(id)"))
    xpos = as_f64(d["x"], "pegs[$(index)].x")
    ypos = as_f64(d["y"], "pegs[$(index)].y")
    shape_name = as_string(d["shape"], "pegs[$(index)].shape")
    shape = if shape_name == "circle"
        CircleShape(as_f64(d["radius"], "pegs[$(index)].radius"))
    elseif shape_name == "rectangle"
        RectangleShape(
            as_f64(d["width"], "pegs[$(index)].width"),
            as_f64(d["height"], "pegs[$(index)].height"),
            as_f64(d["angle"], "pegs[$(index)].angle"),
        )
    elseif shape_name == "annular"
        AnnularShape(
            as_f64(d["r_in"], "pegs[$(index)].r_in"),
            as_f64(d["r_out"], "pegs[$(index)].r_out"),
            as_f64(d["theta_start"], "pegs[$(index)].theta_start"),
            as_f64(d["theta_end_abs"], "pegs[$(index)].theta_end_abs"),
            as_int(d["segments"], "pegs[$(index)].segments"),
        )
    else
        throw(ArgumentError("level: unknown peg shape '$(shape_name)' at pegs[$(index)]"))
    end
    line = haskey(d, "line") ? _parse_line(d["line"], "pegs[$(index)].line") : nothing
    return Peg(
        id, xpos, ypos, xpos, ypos, shape,
        _parse_peg_type(d["type"], "pegs[$(index)].type"),
        false, 0, 0, line,
    )
end

function _parse_type_counts(x)::NamedTuple{(:blue, :green, :purple, :red),NTuple{4,Int}}
    d = as_object(x, "type_counts")
    for key in ("blue", "green", "purple", "red")
        haskey(d, key) || throw(ArgumentError("level: type_counts is missing '$(key)'"))
    end
    return (
        blue = as_int(d["blue"], "type_counts.blue"),
        green = as_int(d["green"], "type_counts.green"),
        purple = as_int(d["purple"], "type_counts.purple"),
        red = as_int(d["red"], "type_counts.red"),
    )
end

function _parse_provenance(x)
    d = as_object(x, "provenance")
    return (
        reference_revision = as_string(d["reference_revision"], "provenance.reference_revision"),
        reference_tree = as_string(d["reference_tree"], "provenance.reference_tree"),
        config_sha256 = as_string(d["config_sha256"], "provenance.config_sha256"),
        level_source = as_string(d["level_source"], "provenance.level_source"),
    )
end

function level_sha256(path::AbstractString)::String
    return sha256_hex(read(path))
end

function load_level(path::AbstractString)::LevelDefinition
    bytes = read(path)
    doc = as_object(load_json(path), "level document")
    for key in keys(doc)
        key in LEVEL_TOP_LEVEL_KEYS ||
            throw(ArgumentError("level: unknown top-level key '$(key)'"))
    end
    for key in LEVEL_CIRCUIT_KEYS
        haskey(doc, key) && throw(ArgumentError(
            "level: circuits are not supported by the v1 static subset ('$(key)' present)"))
    end
    as_string(doc["format"], "format") == "peggle.level" ||
        throw(ArgumentError("level: format must be peggle.level"))
    as_int(doc["schema_version"], "schema_version") == 1 ||
        throw(ArgumentError("level: unsupported schema_version"))

    motion = as_string(doc["motion"], "motion")
    motion == "static" || throw(ArgumentError(
        "level: motion must be \"static\" for the v1 static subset, got \"$(motion)\""))

    pegs = Peg[]
    raw_pegs = as_array(doc["pegs"], "pegs")
    for (i, raw) in enumerate(raw_pegs)
        push!(pegs, _parse_peg(raw, i))
    end
    isempty(pegs) && throw(ArgumentError("level: pegs must not be empty"))

    return LevelDefinition(
        as_string(doc["name"], "name"),
        as_f64(doc["virtual_width"], "virtual_width"),
        as_f64(doc["virtual_height"], "virtual_height"),
        as_int(doc["level_seed"], "level_seed"),
        _parse_type_counts(doc["type_counts"]),
        _parse_peg_type(doc["default_peg_type"], "default_peg_type"),
        pegs,
        _parse_provenance(doc["provenance"]),
        sha256_hex(bytes),
    )
end
