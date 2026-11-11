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
    bounding_radius::Float64
    function RectangleShape(width::Float64, height::Float64, angle::Float64)
        # Shape geometry survives checkpoint reset; preserve the original
        # broad-phase expression and deterministic math backend.
        radius = DetMath.det_sqrt(width * width + height * height) / 2
        return new(width, height, angle, radius)
    end
end

RectangleShape(width::Real, height::Real, angle::Real) =
    RectangleShape(Float64(width), Float64(height), Float64(angle))

struct AnnularShape <: AbstractPegShape
    r_in::Float64
    r_out::Float64
    theta_start::Float64
    theta_end_abs::Float64
    segments::Int
end

# One annular collision piece of a ribbon (dev-tree src/entities/ribbon.lua).
# `x`/`y` is the piece's arc center as authored by Lines.generate; it is never
# re-derived from the owner transform (Lua only does that in set_transform,
# which static levels never reach outside replay restore). `local_x/local_y`
# are Lua's `ribbon_local_x/y = part.x - owner.x`. Only the first piece's
# entry cap and the last piece's exit cap collide.
struct RibbonPart
    x::Float64
    y::Float64
    local_x::Float64
    local_y::Float64
    shape::AnnularShape
    path_direction::Int
    no_cap_start::Bool
    no_cap_end::Bool
end

# A ribbon is ONE gameplay peg (scoring, colors, line metadata, removal) whose
# collision geometry is the ordered chain of `parts`. Physics expands it into
# annular pieces each step (`ribbon_collision_pieces!`); hits, grazes and
# depenetration contacts are attributed to the owner.
struct RibbonShape <: AbstractPegShape
    parts::Vector{RibbonPart}
    path_start::Float64
    path_end::Float64
    bounding_radius::Float64
end

# Ribbon.new: bound the complete analytic sector of every piece, including
# unsampled axis extrema, around the owner transform (ox, oy).
function _ribbon_bounding_radius(parts::Vector{RibbonPart}, ox::Float64, oy::Float64)::Float64
    bound = 0.0
    angles = Float64[]
    for part in parts
        sh = part.shape
        empty!(angles)
        push!(angles, sh.theta_start, sh.theta_end_abs)
        for k in 0:3
            theta = k * pi / 2
            if DetMath.lua_mod(theta - sh.theta_start, 2 * pi) <= sh.theta_end_abs - sh.theta_start
                push!(angles, theta)
            end
        end
        for theta in angles, radius in (sh.r_in, sh.r_out)
            dx = part.x + radius * DetMath.det_cos(theta) - ox
            dy = part.y + radius * DetMath.det_sin(theta) - oy
            bound = max(bound, DetMath.det_sqrt(dx * dx + dy * dy))
        end
    end
    return bound
end

# Build the ribbon shape around an owner transform. `pieces` holds
# (x, y, AnnularShape, path_direction) in chain order.
function RibbonShape(pieces::AbstractVector, path_start::Float64, path_end::Float64,
                     ox::Float64, oy::Float64)
    n = length(pieces)
    n > 0 || throw(ArgumentError("ribbon: expected collision pieces"))
    parts = RibbonPart[]
    for (i, (x, y, shape, dir)) in enumerate(pieces)
        (dir == 1 || dir == -1) ||
            throw(ArgumentError("ribbon: missing traversal direction"))
        (shape.r_in > 0 && shape.r_out > shape.r_in) ||
            throw(ArgumentError("ribbon: invalid collision piece"))
        no_cap_start = (dir == 1 && i > 1) || (dir == -1 && i < n)
        no_cap_end = (dir == 1 && i < n) || (dir == -1 && i > 1)
        push!(parts, RibbonPart(x, y, x - ox, y - oy, shape, dir,
                                no_cap_start, no_cap_end))
    end
    return RibbonShape(parts, path_start, path_end,
                       _ribbon_bounding_radius(parts, ox, oy))
end

@inline peg_bounding_radius(shape::CircleShape) = shape.radius
@inline peg_bounding_radius(shape::RectangleShape) = shape.bounding_radius
@inline peg_bounding_radius(shape::AnnularShape) = shape.r_out
@inline peg_bounding_radius(shape::RibbonShape) = shape.bounding_radius

const PegShapeUnion = Union{CircleShape,RectangleShape,AnnularShape,RibbonShape}

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
    shape::PegShapeUnion
    peg_type::Symbol
    hit::Bool
    hit_order::Int
    multiplier_at_hit::Int
    line::Union{Nothing,LineMetadata}
    # Live shot-time fields (M3). Static levels keep vx=vy=va=0 and x/y/angle
    # equal to their previous values. `angle` for a rectangle starts at the
    # shape's authored angle; every other shape starts at 0. `bounding_radius`
    # is prepared from immutable shape geometry, including after reset.
    base_angle::Float64
    angle::Float64
    vx::Float64
    vy::Float64
    va::Float64
    prev_x::Float64
    prev_y::Float64
    prev_angle::Float64
    bounding_radius::Union{Nothing,Float64}
    # Ribbon collision pieces only (physics-owned, never in a gameplay list):
    # the gameplay owner hits are attributed to, the suppressed internal caps,
    # and the piece sector. `piece_shape` is stored inline: rewriting the
    # union-typed `shape` field every step would box the sector each time.
    # Ordinary pegs keep `nothing`/false/NO_PIECE_SHAPE.
    ribbon_owner::Union{Nothing,Peg}
    no_cap_start::Bool
    no_cap_end::Bool
    piece_shape::AnnularShape
end

const NO_PIECE_SHAPE = AnnularShape(0.0, 0.0, 0.0, 0.0, 0)

# The 11-field positional constructor stays valid for level parsing, state
# building, and checkpoint restore; the live fields get their static defaults.
function Peg(id::Int, x::Float64, y::Float64, base_x::Float64, base_y::Float64,
             shape::PegShapeUnion,
             peg_type::Symbol, hit::Bool, hit_order::Int, multiplier_at_hit::Int,
             line::Union{Nothing,LineMetadata})::Peg
    angle = shape isa RectangleShape ? shape.angle : 0.0
    return Peg(
        id, x, y, base_x, base_y, shape, peg_type, hit, hit_order,
        multiplier_at_hit, line,
        angle, angle,               # base_angle, angle
        0.0, 0.0, 0.0,              # vx, vy, va
        x, y, angle,                # prev_x, prev_y, prev_angle
        peg_bounding_radius(shape), # bounding_radius
        nothing, false, false,      # ribbon_owner, no_cap_start, no_cap_end
        NO_PIECE_SHAPE,             # piece_shape
    )
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

# Inline numerical records for the collision scans. Metadata and scoring
# remain on the worker's Peg objects; ordinal i still means list position i.
struct CompactPegGeometry{S<:AbstractPegShape}
    x::Float64
    y::Float64
    vx::Float64
    vy::Float64
    bounding_radius::Float64
    shape::S
end

CompactPegGeometry(p::Peg) = CompactPegGeometry(
    p.x, p.y, p.vx, p.vy,
    p.bounding_radius === nothing ? peg_bounding_radius(p.shape) : p.bounding_radius,
    p.shape)

struct PreparedGeometry
    circles::Vector{CompactPegGeometry{CircleShape}}
    rectangles::Vector{CompactPegGeometry{RectangleShape}}
    annulars::Vector{CompactPegGeometry{AnnularShape}}
end

PreparedGeometry() = PreparedGeometry(CompactPegGeometry{CircleShape}[],
    CompactPegGeometry{RectangleShape}[], CompactPegGeometry{AnnularShape}[])

const LEVEL_TOP_LEVEL_KEYS = (
    "format", "schema_version", "name", "motion", "virtual_width",
    "virtual_height", "level_seed", "type_counts", "default_peg_type",
    "pegs", "provenance",
)

const LEVEL_CIRCUIT_KEYS = ("circuits", "level_circuits", "motion_circuits")

const VALID_PEG_TYPES = (:blue, :green, :purple, :red)

# Interned peg-type strings. `String(::Symbol)` allocates on the contact hot
# path; these literals are the same values the journal always carried.
@inline function peg_type_name(t::Symbol)
    t === :blue && return "blue"
    t === :green && return "green"
    t === :purple && return "purple"
    t === :red && return "red"
    return String(t)
end

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

function _parse_ribbon(d::AbstractDict, what::AbstractString, ox::Float64,
                       oy::Float64)::RibbonShape
    raw_parts = as_array(d["parts"], "$(what).parts")
    pieces = Tuple{Float64,Float64,AnnularShape,Int}[]
    for (j, raw) in enumerate(raw_parts)
        q = as_object(raw, "$(what).parts[$(j)]")
        w = "$(what).parts[$(j)]"
        push!(pieces, (
            as_f64(q["x"], "$(w).x"), as_f64(q["y"], "$(w).y"),
            AnnularShape(
                as_f64(q["r_in"], "$(w).r_in"),
                as_f64(q["r_out"], "$(w).r_out"),
                as_f64(q["theta_start"], "$(w).theta_start"),
                as_f64(q["theta_end_abs"], "$(w).theta_end_abs"),
                as_int(q["segments"], "$(w).segments"),
            ),
            as_int(q["path_direction"], "$(w).path_direction"),
        ))
    end
    return RibbonShape(pieces, as_f64(d["path_start"], "$(what).path_start"),
                       as_f64(d["path_end"], "$(what).path_end"), ox, oy)
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
    elseif shape_name == "ribbon"
        _parse_ribbon(d, "pegs[$(index)]", xpos, ypos)
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
