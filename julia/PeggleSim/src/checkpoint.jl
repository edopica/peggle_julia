# Decision checkpoint v1 (schemas/checkpoint.v1.schema.json).
#
# `Checkpoint` mirrors the schema exactly with immutable record structs; the
# only mutable objects it owns are the plain Vectors and tracker Dicts. Both
# `capture_checkpoint` and `restore!` copy, so a checkpoint never aliases live
# simulation arrays (and vice versa).
#
# `rng.state_b64` is the base64 of the ASCII `love.math.RandomGenerator
# :getState()` string, exactly as the reference harness serialized it.
# `purple_queue.queue` is the remaining queue (blue un-hit ids) and
# `.active` the currently promoted ids.

struct CheckpointProvenance
    reference_revision::String
    reference_tree::String
    config_sha256::String
    level_sha256::String
end

struct CheckpointPeg
    id::Int
    peg_type::Symbol
    hit::Bool
    x::Float64
    y::Float64
    base_x::Float64
    base_y::Float64
    shape::Union{CircleShape,RectangleShape,AnnularShape}
    line::Union{Nothing,LineMetadata}
    hit_order::Int
    multiplier_at_hit::Int
end

struct CheckpointBall
    id::Int
    x::Float64
    y::Float64
    prev_x::Float64
    prev_y::Float64
    vx::Float64
    vy::Float64
    radius::Float64
    launched::Bool
end

struct CheckpointBucket
    x::Float64
    prev_x::Float64
    top::Float64
    hole::Float64
    edge::Float64
    height::Float64
    phase::Float64
end

struct CheckpointFeverBucket
    x::Float64
    width::Float64
    value::Float64
end

struct CheckpointFeverDivider
    x::Float64
    y::Float64
    radius::Float64
    is_divider::Bool
end

struct CheckpointFeverBuckets
    top::Float64
    target_top::Float64
    height::Float64
    animating::Bool
    buckets::Vector{CheckpointFeverBucket}
    dividers::Vector{CheckpointFeverDivider}
end

struct CheckpointClearing
    active::Bool
    is_end_of_turn::Bool
    timer::Float64
end

struct CheckpointEngine
    step_id::Int
    shot_id::Int
    level_name::String
    is_fever::Bool
    current_multiplier::Int
    hit_counter::Int
    total_red_pegs::Int
    red_pegs_hit_amount::Int
    bonus_score::Float64
    style_score::Float64
    pegs::Vector{CheckpointPeg}
    balls::Vector{CheckpointBall}
    bucket::CheckpointBucket
    next_ball_id::Int
    used_ball_ids::Vector{Int}
    turn_pegs_hit::Vector{Int}
    clearing::CheckpointClearing
    fever_buckets::CheckpointFeverBuckets
end

struct CheckpointRng
    generator::String
    seed::Int
    state_b64::String
end

struct CheckpointPurpleQueue
    queue::Vector{Int}
    active::Vector{Int}
end

struct CheckpointMatch
    mode::Symbol
    players::Vector{MatchPlayer}
    current_player_index::Int
    shared_bucket_hits::Int
    game_over::Bool
    winner::Union{Nothing,Int}
end

struct Checkpoint
    format::String
    schema_version::Int
    boundary::String
    provenance::CheckpointProvenance
    engine::CheckpointEngine
    rng::CheckpointRng
    purple_queue::CheckpointPurpleQueue
    trackers::Trackers
    match::CheckpointMatch
end

# ---------------------------------------------------------------------------
# Provenance normalization
# ---------------------------------------------------------------------------

function _provenance(p)::CheckpointProvenance
    p isa CheckpointProvenance && return p
    if p isa NamedTuple
        return CheckpointProvenance(
            String(p.reference_revision), String(p.reference_tree),
            String(p.config_sha256), String(p.level_sha256))
    elseif p isa AbstractDict
        return CheckpointProvenance(
            as_string(p["reference_revision"], "provenance.reference_revision"),
            as_string(p["reference_tree"], "provenance.reference_tree"),
            as_string(p["config_sha256"], "provenance.config_sha256"),
            as_string(p["level_sha256"], "provenance.level_sha256"))
    else
        throw(ArgumentError(
            "provenance must be a CheckpointProvenance, NamedTuple, or Dict, got $(typeof(p))"))
    end
end

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

_checkpoint_peg(p::Peg) = CheckpointPeg(
    p.id, p.peg_type, p.hit, p.x, p.y, p.base_x, p.base_y,
    p.shape, p.line, p.hit_order, p.multiplier_at_hit)

_checkpoint_ball(b::BallState) = CheckpointBall(
    b.id, b.x, b.y, b.prev_x, b.prev_y, b.vx, b.vy, b.radius, b.launched)

_checkpoint_bucket(b::BucketState) = CheckpointBucket(
    b.x, b.prev_x, b.top, b.hole, b.edge, b.height, b.phase)

_checkpoint_fever(f::FeverBucketsState) = CheckpointFeverBuckets(
    f.top, f.target_top, f.height, f.animating,
    [CheckpointFeverBucket(b.x, b.width, b.value) for b in f.buckets],
    [CheckpointFeverDivider(d.x, d.y, d.radius, d.is_divider) for d in f.dividers],
)

_checkpoint_engine(e::EngineState) = CheckpointEngine(
    e.step_id, e.shot_id, e.level_name, e.is_fever, e.current_multiplier,
    e.hit_counter, e.total_red_pegs, e.red_pegs_hit_amount,
    e.bonus_score, e.style_score,
    CheckpointPeg[_checkpoint_peg(p) for p in e.pegs],
    CheckpointBall[_checkpoint_ball(b) for b in e.balls],
    _checkpoint_bucket(e.bucket),
    e.next_ball_id,
    copy(e.used_ball_ids),
    copy(e.turn_pegs_hit),
    CheckpointClearing(e.clear_queue !== nothing, e.clearing_is_end_of_turn,
                       e.clear_timer),
    _checkpoint_fever(e.fever_buckets),
)

_checkpoint_match(m::MatchState) = CheckpointMatch(
    m.mode,
    [MatchPlayer(p.score, p.balls, p.bucket_hits) for p in m.players],
    m.current_player_index, m.shared_bucket_hits, m.game_over, m.winner,
)

function capture_checkpoint(sim::SimState; provenance)::Checkpoint
    prov = _provenance(provenance)
    engine = _checkpoint_engine(sim.engine)
    rng = CheckpointRng(
        "love.math.newRandomGenerator",
        Int(sim.rng.seed),
        Base64.base64encode(get_state(sim.rng)),
    )
    purple_queue = CheckpointPurpleQueue(copy(sim.colors.queue), copy(sim.colors.active))
    trackers = deepcopy(sim.trackers)
    match = _checkpoint_match(sim.match)
    return Checkpoint(
        "peggle.checkpoint", 1, "ready_to_aim",
        prov, engine, rng, purple_queue, trackers, match,
    )
end

# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

function _shape_name(shape::AbstractPegShape)::String
    shape isa CircleShape && return "circle"
    shape isa RectangleShape && return "rectangle"
    shape isa AnnularShape && return "annular"
    throw(ArgumentError("unknown peg shape type: $(typeof(shape))"))
end

function _line_to_dict(l::LineMetadata)::Dict{String,Any}
    return Dict{String,Any}(
        "id" => l.id,
        "index" => l.index,
        "count" => l.count,
        "closed" => l.closed,
        "gap" => l.gap,
    )
end

function _peg_to_dict(p::CheckpointPeg)::Dict{String,Any}
    d = Dict{String,Any}(
        "id" => p.id,
        "type" => String(p.peg_type),
        "hit" => p.hit,
        "x" => p.x,
        "y" => p.y,
        "base_x" => p.base_x,
        "base_y" => p.base_y,
        "shape" => _shape_name(p.shape),
    )
    if p.shape isa CircleShape
        d["radius"] = p.shape.radius
    elseif p.shape isa RectangleShape
        d["width"] = p.shape.width
        d["height"] = p.shape.height
        d["angle"] = p.shape.angle
    elseif p.shape isa AnnularShape
        d["r_in"] = p.shape.r_in
        d["r_out"] = p.shape.r_out
        d["theta_start"] = p.shape.theta_start
        d["theta_end_abs"] = p.shape.theta_end_abs
        d["segments"] = p.shape.segments
    end
    p.line !== nothing && (d["line"] = _line_to_dict(p.line))
    if p.hit
        d["hit_order"] = p.hit_order
        d["multiplier_at_hit"] = p.multiplier_at_hit
    end
    return d
end

function _ball_to_dict(b::CheckpointBall)::Dict{String,Any}
    return Dict{String,Any}(
        "id" => b.id, "x" => b.x, "y" => b.y,
        "prev_x" => b.prev_x, "prev_y" => b.prev_y,
        "vx" => b.vx, "vy" => b.vy,
        "radius" => b.radius, "launched" => b.launched,
    )
end

function _bucket_to_dict(b::CheckpointBucket)::Dict{String,Any}
    return Dict{String,Any}(
        "x" => b.x, "prev_x" => b.prev_x, "top" => b.top,
        "hole" => b.hole, "edge" => b.edge, "height" => b.height,
        "phase" => b.phase,
    )
end

function _fever_to_dict(f::CheckpointFeverBuckets)::Dict{String,Any}
    return Dict{String,Any}(
        "top" => f.top,
        "target_top" => f.target_top,
        "height" => f.height,
        "animating" => f.animating,
        "buckets" => Any[
            Dict{String,Any}("x" => b.x, "width" => b.width, "value" => b.value)
            for b in f.buckets
        ],
        "dividers" => Any[
            Dict{String,Any}("x" => d.x, "y" => d.y, "radius" => d.radius,
                             "is_divider" => d.is_divider)
            for d in f.dividers
        ],
    )
end

function _engine_to_dict(e::CheckpointEngine)::Dict{String,Any}
    return Dict{String,Any}(
        "step_id" => e.step_id,
        "shot_id" => e.shot_id,
        "level_name" => e.level_name,
        "is_fever" => e.is_fever,
        "current_multiplier" => e.current_multiplier,
        "hit_counter" => e.hit_counter,
        "total_red_pegs" => e.total_red_pegs,
        "red_pegs_hit_amount" => e.red_pegs_hit_amount,
        "bonus_score" => e.bonus_score,
        "style_score" => e.style_score,
        "pegs" => Any[_peg_to_dict(p) for p in e.pegs],
        "balls" => Any[_ball_to_dict(b) for b in e.balls],
        "bucket" => _bucket_to_dict(e.bucket),
        "next_ball_id" => e.next_ball_id,
        "used_ball_ids" => copy(e.used_ball_ids),
        "turn_pegs_hit" => copy(e.turn_pegs_hit),
        "clearing" => Dict{String,Any}(
            "active" => e.clearing.active,
            "is_end_of_turn" => e.clearing.is_end_of_turn,
            "timer" => e.clearing.timer,
        ),
        "fever_buckets" => _fever_to_dict(e.fever_buckets),
    )
end

# Tracker maps serialize as JSON objects with string keys (the reference
# harness `wrap` behavior for the empty ready-to-aim maps; all maps are empty
# at this boundary).
function _tracker_value_to_json(v)
    if v isa AbstractDict
        return Dict{String,Any}(string(k) => _tracker_value_to_json(x) for (k, x) in v)
    elseif v isa NamedTuple
        return Dict{String,Any}(string(k) => _tracker_value_to_json(x)
                                for (k, x) in pairs(v))
    elseif v isa AbstractVector || v isa Tuple
        return Any[_tracker_value_to_json(x) for x in v]
    else
        return v
    end
end

_tracker_map_to_dict(m::AbstractDict) =
    Dict{String,Any}(string(k) => _tracker_value_to_json(v) for (k, v) in m)

# Typed tracker payloads: only reachable from a mid-shot checkpoint, which the
# engine never takes; they define the shape rather than dropping fields.
_tracker_value_to_json(v::StyleLastImpact) =
    Dict{String,Any}("x" => v.x, "y" => v.y, "seq" => v.seq)

_tracker_value_to_json(v::StyleSlideRun) = Dict{String,Any}(
    "len" => v.len, "last" => v.last, "dir" => v.dir, "seqs" => v.seqs)

_tracker_value_to_json(v::SlideTrack) = Dict{String,Any}(
    "line_id" => v.line_id, "no_contact_time" => v.no_contact_time,
    "tangent_sign" => v.tangent_sign)

_tracker_value_to_json(v::SlideHitRecord) =
    Dict{String,Any}("peg_id" => v.peg_id, "impact_y" => v.impact_y)

function _trackers_to_dict(t::Trackers)::Dict{String,Any}
    ss = t.style_shots
    bs = t.ball_state
    si = t.slide_inversion
    return Dict{String,Any}(
        "style_shots" => Dict{String,Any}(
            "last_impact" => _tracker_map_to_dict(ss.last_impact),
            "qualifying_streak" => _tracker_map_to_dict(ss.qualifying_streak),
            "last_qualifying_seq" => _tracker_map_to_dict(ss.last_qualifying_seq),
            "bucket_bounced" => _tracker_map_to_dict(ss.bucket_bounced),
            "bounced_after_bucket" => _tracker_map_to_dict(ss.bounced_after_bucket),
            "side_wall_hit" => _tracker_map_to_dict(ss.side_wall_hit),
            "hit_any_peg" => _tracker_map_to_dict(ss.hit_any_peg),
            "awarded" => _tracker_map_to_dict(ss.awarded),
            "slide_runs" => _tracker_map_to_dict(ss.slide_runs),
            "slide_awarded" => _tracker_map_to_dict(ss.slide_awarded),
        ),
        "ball_state" => Dict{String,Any}(
            "idle" => _tracker_map_to_dict(bs.idle),
            "idle_timer" => _tracker_map_to_dict(bs.idle_timer),
            "reacted" => _tracker_map_to_dict(bs.reacted),
            "all_idle_latch" => bs.all_idle_latch,
            "no_score_timer" => bs.no_score_timer,
            "no_score_timeout_fired" => bs.no_score_timeout_fired,
        ),
        "slide_inversion" => Dict{String,Any}(
            "line_hits" => _tracker_map_to_dict(si.line_hits),
            "hit_seen" => _tracker_map_to_dict(si.hit_seen),
            "removed" => _tracker_map_to_dict(si.removed),
            "track" => _tracker_map_to_dict(si.track),
        ),
    )
end

function _match_to_dict(m::CheckpointMatch)::Dict{String,Any}
    d = Dict{String,Any}(
        "mode" => String(m.mode),
        "players" => Any[
            Dict{String,Any}("score" => p.score, "balls" => p.balls,
                             "bucket_hits" => p.bucket_hits)
            for p in m.players
        ],
        "current_player_index" => m.current_player_index,
        "shared_bucket_hits" => m.shared_bucket_hits,
        "game_over" => m.game_over,
    )
    m.winner !== nothing && (d["winner"] = m.winner)
    return d
end

function checkpoint_to_dict(ckpt::Checkpoint)::Dict{String,Any}
    return Dict{String,Any}(
        "format" => ckpt.format,
        "schema_version" => ckpt.schema_version,
        "boundary" => ckpt.boundary,
        "provenance" => Dict{String,Any}(
            "reference_revision" => ckpt.provenance.reference_revision,
            "reference_tree" => ckpt.provenance.reference_tree,
            "config_sha256" => ckpt.provenance.config_sha256,
            "level_sha256" => ckpt.provenance.level_sha256,
        ),
        "engine" => _engine_to_dict(ckpt.engine),
        "rng" => Dict{String,Any}(
            "generator" => ckpt.rng.generator,
            "seed" => ckpt.rng.seed,
            "state_b64" => ckpt.rng.state_b64,
        ),
        "purple_queue" => Dict{String,Any}(
            "queue" => copy(ckpt.purple_queue.queue),
            "active" => copy(ckpt.purple_queue.active),
        ),
        "trackers" => _trackers_to_dict(ckpt.trackers),
        "match" => _match_to_dict(ckpt.match),
    )
end

canonical_json(ckpt::Checkpoint)::String = canonical_json(checkpoint_to_dict(ckpt))

checkpoint_canonical(ckpt::Checkpoint)::String = canonical_json(ckpt)

checkpoint_sha256(ckpt::Checkpoint)::String = sha256_hex(checkpoint_canonical(ckpt))

# ---------------------------------------------------------------------------
# Decoding (checkpoint_to_dict / JSON.parsefile output -> Checkpoint)
# ---------------------------------------------------------------------------

function _parse_line_dict(d::AbstractDict)::LineMetadata
    return LineMetadata(
        as_string(d["id"], "line.id"),
        as_int(d["index"], "line.index"),
        as_int(d["count"], "line.count"),
        as_bool(d["closed"], "line.closed"),
        as_f64(d["gap"], "line.gap"),
    )
end

function _parse_checkpoint_peg(d::AbstractDict)::CheckpointPeg
    shape_name = as_string(d["shape"], "peg.shape")
    shape = if shape_name == "circle"
        CircleShape(as_f64(d["radius"], "peg.radius"))
    elseif shape_name == "rectangle"
        RectangleShape(
            as_f64(d["width"], "peg.width"),
            as_f64(d["height"], "peg.height"),
            as_f64(d["angle"], "peg.angle"),
        )
    elseif shape_name == "annular"
        AnnularShape(
            as_f64(d["r_in"], "peg.r_in"),
            as_f64(d["r_out"], "peg.r_out"),
            as_f64(d["theta_start"], "peg.theta_start"),
            as_f64(d["theta_end_abs"], "peg.theta_end_abs"),
            as_int(d["segments"], "peg.segments"),
        )
    else
        throw(ArgumentError("checkpoint: unknown peg shape '$(shape_name)'"))
    end
    line = haskey(d, "line") ? _parse_line_dict(as_object(d["line"], "peg.line")) : nothing
    return CheckpointPeg(
        as_int(d["id"], "peg.id"),
        Symbol(as_string(d["type"], "peg.type")),
        as_bool(d["hit"], "peg.hit"),
        as_f64(d["x"], "peg.x"),
        as_f64(d["y"], "peg.y"),
        as_f64(d["base_x"], "peg.base_x"),
        as_f64(d["base_y"], "peg.base_y"),
        shape,
        line,
        haskey(d, "hit_order") ? as_int(d["hit_order"], "peg.hit_order") : 0,
        haskey(d, "multiplier_at_hit") ? as_int(d["multiplier_at_hit"], "peg.multiplier_at_hit") : 0,
    )
end

function _parse_checkpoint_ball(d::AbstractDict)::CheckpointBall
    return CheckpointBall(
        as_int(d["id"], "ball.id"),
        as_f64(d["x"], "ball.x"),
        as_f64(d["y"], "ball.y"),
        as_f64(d["prev_x"], "ball.prev_x"),
        as_f64(d["prev_y"], "ball.prev_y"),
        as_f64(d["vx"], "ball.vx"),
        as_f64(d["vy"], "ball.vy"),
        as_f64(d["radius"], "ball.radius"),
        as_bool(d["launched"], "ball.launched"),
    )
end

function _parse_bucket(d::AbstractDict)::CheckpointBucket
    return CheckpointBucket(
        as_f64(d["x"], "bucket.x"),
        as_f64(d["prev_x"], "bucket.prev_x"),
        as_f64(d["top"], "bucket.top"),
        as_f64(d["hole"], "bucket.hole"),
        as_f64(d["edge"], "bucket.edge"),
        as_f64(d["height"], "bucket.height"),
        as_f64(d["phase"], "bucket.phase"),
    )
end

function _parse_fever(d::AbstractDict)::CheckpointFeverBuckets
    return CheckpointFeverBuckets(
        as_f64(d["top"], "fever_buckets.top"),
        as_f64(d["target_top"], "fever_buckets.target_top"),
        as_f64(d["height"], "fever_buckets.height"),
        as_bool(d["animating"], "fever_buckets.animating"),
        CheckpointFeverBucket[
            CheckpointFeverBucket(as_f64(b["x"], "fever.x"),
                                  as_f64(b["width"], "fever.width"),
                                  as_f64(b["value"], "fever.value"))
            for b in as_array(d["buckets"], "fever_buckets.buckets")
        ],
        CheckpointFeverDivider[
            CheckpointFeverDivider(as_f64(x["x"], "divider.x"),
                                   as_f64(x["y"], "divider.y"),
                                   as_f64(x["radius"], "divider.radius"),
                                   as_bool(x["is_divider"], "divider.is_divider"))
            for x in as_array(d["dividers"], "fever_buckets.dividers")
        ],
    )
end

function _int_vector(x, what::AbstractString)::Vector{Int}
    return Int[as_int(v, what) for v in as_array(x, what)]
end

function _parse_checkpoint_engine(d::AbstractDict)::CheckpointEngine
    clearing = as_object(d["clearing"], "engine.clearing")
    return CheckpointEngine(
        as_int(d["step_id"], "engine.step_id"),
        as_int(d["shot_id"], "engine.shot_id"),
        as_string(d["level_name"], "engine.level_name"),
        as_bool(d["is_fever"], "engine.is_fever"),
        as_int(d["current_multiplier"], "engine.current_multiplier"),
        as_int(d["hit_counter"], "engine.hit_counter"),
        as_int(d["total_red_pegs"], "engine.total_red_pegs"),
        as_int(d["red_pegs_hit_amount"], "engine.red_pegs_hit_amount"),
        as_f64(d["bonus_score"], "engine.bonus_score"),
        as_f64(d["style_score"], "engine.style_score"),
        CheckpointPeg[
            _parse_checkpoint_peg(as_object(p, "engine.pegs[]"))
            for p in as_array(d["pegs"], "engine.pegs")
        ],
        CheckpointBall[
            _parse_checkpoint_ball(as_object(b, "engine.balls[]"))
            for b in as_array(d["balls"], "engine.balls")
        ],
        _parse_bucket(as_object(d["bucket"], "engine.bucket")),
        as_int(d["next_ball_id"], "engine.next_ball_id"),
        _int_vector(d["used_ball_ids"], "engine.used_ball_ids"),
        _int_vector(d["turn_pegs_hit"], "engine.turn_pegs_hit"),
        CheckpointClearing(
            as_bool(clearing["active"], "engine.clearing.active"),
            as_bool(clearing["is_end_of_turn"], "engine.clearing.is_end_of_turn"),
            as_f64(clearing["timer"], "engine.clearing.timer"),
        ),
        _parse_fever(as_object(d["fever_buckets"], "engine.fever_buckets")),
    )
end

function _tracker_value_from_json(v)
    if v isa AbstractDict
        return Dict{String,Any}(string(k) => _tracker_value_from_json(x) for (k, x) in v)
    elseif v isa AbstractVector
        return Any[_tracker_value_from_json(x) for x in v]
    else
        return v
    end
end

_parse_int_tracker_map(x) =
    Dict{Int,Any}(parse(Int, string(k)) => _tracker_value_from_json(v)
                  for (k, v) in as_object(x, "tracker map"))

_parse_int_tracker_map(::Type{V}, x) where {V} =
    Dict{Int,V}(parse(Int, string(k)) => V(_tracker_value_from_json(v))
                for (k, v) in as_object(x, "tracker map"))

# Typed tracker payloads. A checkpoint is only taken at the ready-to-aim
# boundary, where every tracker map is empty, so these constructors are
# defensive: they define what a mid-shot round trip would mean rather than
# letting serialization silently drop fields.
StyleLastImpact(d::AbstractDict) =
    StyleLastImpact(Float64(d["x"]), Float64(d["y"]), Int(d["seq"]))

StyleSlideRun(d::AbstractDict) = StyleSlideRun(
    Int(d["len"]),
    d["last"] === nothing ? nothing : Int(d["last"]),
    Int(d["dir"]),
    Int[Int(x) for x in d["seqs"]],
)

SlideTrack(d::AbstractDict) = SlideTrack(
    string(d["line_id"]),
    Float64(d["no_contact_time"]),
    d["tangent_sign"] === nothing ? nothing : Int(d["tangent_sign"]),
)

SlideHitRecord(d::AbstractDict) = SlideHitRecord(Int(d["peg_id"]), Float64(d["impact_y"]))

_parse_int_nested_map(::Type{V}, x) where {V} =
    Dict{Int,Dict{String,V}}(
        parse(Int, string(k)) => Dict{String,V}(
            string(k2) => V(_tracker_value_from_json(v2))
            for (k2, v2) in as_object(v, "nested tracker map"))
        for (k, v) in as_object(x, "tracker map"))

_parse_string_record_map(::Type{V}, x) where {V} =
    Dict{String,Vector{V}}(
        string(k) => V[V(_tracker_value_from_json(x2))
                       for x2 in as_array(v, "tracker record list")]
        for (k, v) in as_object(x, "tracker map"))

_parse_string_tracker_map(x) =
    Dict{String,Any}(string(k) => _tracker_value_from_json(v)
                     for (k, v) in as_object(x, "tracker map"))

function _parse_trackers(d::AbstractDict)::Trackers
    ss = as_object(d["style_shots"], "trackers.style_shots")
    bs = as_object(d["ball_state"], "trackers.ball_state")
    si = as_object(d["slide_inversion"], "trackers.slide_inversion")
    style = StyleShotTrackers(
        _parse_int_tracker_map(StyleLastImpact, ss["last_impact"]),
        _parse_int_tracker_map(Int, ss["qualifying_streak"]),
        _parse_int_tracker_map(Int, ss["last_qualifying_seq"]),
        _parse_int_tracker_map(Int, ss["bucket_bounced"]),
        _parse_int_tracker_map(Bool, ss["bounced_after_bucket"]),
        _parse_int_tracker_map(Int, ss["side_wall_hit"]),
        _parse_int_tracker_map(Bool, ss["hit_any_peg"]),
        _parse_int_nested_map(Bool, ss["awarded"]),
        _parse_int_nested_map(StyleSlideRun, ss["slide_runs"]),
        _parse_int_nested_map(Bool, ss["slide_awarded"]),
        StyleSlideRun[], 0, Dict{String,Bool}[], 0,
    )
    ball = BallStateTrackers(
        _parse_int_tracker_map(Bool, bs["idle"]),
        _parse_int_tracker_map(Float64, bs["idle_timer"]),
        _parse_int_tracker_map(Bool, bs["reacted"]),
        as_bool(bs["all_idle_latch"], "ball_state.all_idle_latch"),
        as_f64(bs["no_score_timer"], "ball_state.no_score_timer"),
        as_bool(bs["no_score_timeout_fired"], "ball_state.no_score_timeout_fired"),
    )
    slide = SlideInversionTrackers(
        _parse_string_record_map(SlideHitRecord, si["line_hits"]),
        _parse_int_tracker_map(Bool, si["hit_seen"]),
        _parse_int_tracker_map(Bool, si["removed"]),
        _parse_int_tracker_map(SlideTrack, si["track"]),
        SlideTrack[], 0, Vector{SlideHitRecord}[], 0,
    )
    return Trackers(style, ball, slide)
end

function _parse_match(d::AbstractDict)::CheckpointMatch
    players = MatchPlayer[
        MatchPlayer(as_f64(p["score"], "match.player.score"),
                    as_int(p["balls"], "match.player.balls"),
                    as_int(p["bucket_hits"], "match.player.bucket_hits"))
        for p in as_array(d["players"], "match.players")
    ]
    winner = haskey(d, "winner") ? as_int(d["winner"], "match.winner") : nothing
    return CheckpointMatch(
        Symbol(as_string(d["mode"], "match.mode")),
        players,
        as_int(d["current_player_index"], "match.current_player_index"),
        as_int(d["shared_bucket_hits"], "match.shared_bucket_hits"),
        as_bool(d["game_over"], "match.game_over"),
        winner,
    )
end

function checkpoint_from_dict(d::AbstractDict)::Checkpoint
    prov = as_object(d["provenance"], "provenance")
    rng = as_object(d["rng"], "rng")
    pq = as_object(d["purple_queue"], "purple_queue")
    return Checkpoint(
        as_string(d["format"], "format"),
        as_int(d["schema_version"], "schema_version"),
        as_string(d["boundary"], "boundary"),
        CheckpointProvenance(
            as_string(prov["reference_revision"], "provenance.reference_revision"),
            as_string(prov["reference_tree"], "provenance.reference_tree"),
            as_string(prov["config_sha256"], "provenance.config_sha256"),
            as_string(prov["level_sha256"], "provenance.level_sha256"),
        ),
        _parse_checkpoint_engine(as_object(d["engine"], "engine")),
        CheckpointRng(
            as_string(rng["generator"], "rng.generator"),
            as_int(rng["seed"], "rng.seed"),
            as_string(rng["state_b64"], "rng.state_b64"),
        ),
        CheckpointPurpleQueue(
            _int_vector(pq["queue"], "purple_queue.queue"),
            _int_vector(pq["active"], "purple_queue.active"),
        ),
        _parse_trackers(as_object(d["trackers"], "trackers")),
        _parse_match(as_object(d["match"], "match")),
    )
end

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

_sim_ball(cb::CheckpointBall) = begin
    b = BallState(cb.id, cb.x, cb.y, cb.radius)
    b.prev_x = cb.prev_x
    b.prev_y = cb.prev_y
    b.vx = cb.vx
    b.vy = cb.vy
    b.launched = cb.launched
    b
end

function _engine_from_checkpoint(ckpt::Checkpoint)::EngineState
    ce = ckpt.engine
    pegs = Peg[
        Peg(p.id, p.x, p.y, p.base_x, p.base_y, p.shape, p.peg_type,
            p.hit, p.hit_order, p.multiplier_at_hit, p.line)
        for p in ce.pegs
    ]
    peg_by_id = Dict(p.id => p for p in pegs)
    balls = BallState[_sim_ball(b) for b in ce.balls]
    live_ball_ids = Dict(b.id => b for b in balls)
    live_id_by_ball = IdDict(b => b.id for b in balls)
    cf = ce.fever_buckets
    fever = FeverBucketsState(
        cf.top, cf.target_top, cf.height, cf.animating,
        FeverBucketSpec[FeverBucketSpec(b.x, b.width, b.value) for b in cf.buckets],
        FeverDivider[FeverDivider(d.x, d.y, d.radius, d.is_divider) for d in cf.dividers],
    )
    ce.clearing.active && throw(ArgumentError(
        "checkpoint: v1 ready_to_aim checkpoints must have clearing.active == false"))
    return EngineState(
        ce.step_id, ce.shot_id, ce.level_name, pegs, peg_by_id,
        balls, live_ball_ids, live_id_by_ball,
        BucketState(ce.bucket.x, ce.bucket.prev_x, ce.bucket.top, ce.bucket.hole,
                    ce.bucket.edge, ce.bucket.height, ce.bucket.phase),
        fever,
        nothing,                    # clear_queue
        ce.clearing.is_end_of_turn,
        ce.clearing.timer,
        ce.bonus_score, ce.style_score,
        ce.total_red_pegs, ce.red_pegs_hit_amount,
        ce.current_multiplier, ce.is_fever, ce.hit_counter,
        copy(ce.turn_pegs_hit), ce.next_ball_id, copy(ce.used_ball_ids),
    )
end

function _match_from_checkpoint(ckpt::Checkpoint)::MatchState
    cm = ckpt.match
    return MatchState(
        cm.mode,
        [MatchPlayer(p.score, p.balls, p.bucket_hits) for p in cm.players],
        cm.current_player_index, cm.shared_bucket_hits, cm.game_over, cm.winner,
    )
end

function _rng_from_checkpoint(ckpt::Checkpoint)::LoveRandom
    rng = LoveRandom(ckpt.rng.seed)
    set_state!(rng, String(Base64.base64decode(ckpt.rng.state_b64)))
    return rng
end

# Build a fresh SimState from a checkpoint (used by make_worker).
function sim_from_checkpoint(ckpt::Checkpoint)::SimState
    rng = _rng_from_checkpoint(ckpt)
    engine = _engine_from_checkpoint(ckpt)
    colors = ColorState(copy(ckpt.purple_queue.queue), copy(ckpt.purple_queue.active), rng)
    trackers = deepcopy(ckpt.trackers)
    match = _match_from_checkpoint(ckpt)
    return SimState(engine, rng, colors, trackers, match)
end


# Restore tracker state into the live containers instead of replacing them.
# The reuse pools and dict capacities inside StyleShotTrackers and
# SlideInversionTrackers are what keep the warmed step path allocation-free;
# `deepcopy` here would discard them (and re-grow them every shot).
function _restore_trackers!(dst::Trackers, src::Trackers)::Nothing
    ds = dst.style_shots
    ss = src.style_shots
    reset_shot!(ds)
    copy!(ds.last_impact, ss.last_impact)
    copy!(ds.qualifying_streak, ss.qualifying_streak)
    copy!(ds.last_qualifying_seq, ss.last_qualifying_seq)
    copy!(ds.bucket_bounced, ss.bucket_bounced)
    copy!(ds.bounced_after_bucket, ss.bounced_after_bucket)
    copy!(ds.side_wall_hit, ss.side_wall_hit)
    copy!(ds.hit_any_peg, ss.hit_any_peg)
    _copy_nested_trackers!(ds.awarded, ss.awarded)
    _copy_nested_trackers!(ds.slide_runs, ss.slide_runs)
    _copy_nested_trackers!(ds.slide_awarded, ss.slide_awarded)

    db = dst.ball_state
    sb = src.ball_state
    reset_shot!(db)
    copy!(db.idle, sb.idle)
    copy!(db.idle_timer, sb.idle_timer)
    copy!(db.reacted, sb.reacted)
    db.all_idle_latch = sb.all_idle_latch
    db.no_score_timer = sb.no_score_timer
    db.no_score_timeout_fired = sb.no_score_timeout_fired

    di = dst.slide_inversion
    si = src.slide_inversion
    reset_shot!(di)
    copy!(di.hit_seen, si.hit_seen)
    copy!(di.removed, si.removed)
    for (k, v) in si.line_hits
        dst_vec = get(di.line_hits, k, nothing)
        if dst_vec === nothing
            di.line_hits[k] = copy(v)
        else
            empty!(dst_vec)
            append!(dst_vec, v)
        end
    end
    for (k, v) in si.track
        tr = _si_track!(di, String(v.line_id), k)
        tr.no_contact_time = v.no_contact_time
        tr.tangent_sign = v.tangent_sign
    end
    return nothing
end

function _copy_nested_trackers!(dst::Dict{Int,Dict{String,V}}, src) where {V}
    for (k, inner) in src
        d = get(dst, k, nothing)
        if d === nothing
            d = Dict{String,V}()
            dst[k] = d
        else
            empty!(d)
        end
        for (k2, v2) in inner
            d[k2] = v2
        end
    end
    return nothing
end

function restore!(sim::SimState, ckpt::Checkpoint)
    ce = ckpt.engine

    # RNG first so the color state can share the restored generator.
    sim.rng.seed = UInt64(ckpt.rng.seed)
    set_state!(sim.rng, String(Base64.base64decode(ckpt.rng.state_b64)))

    e = sim.engine
    e.step_id = ce.step_id
    e.shot_id = ce.shot_id
    e.level_name = ce.level_name
    e.is_fever = ce.is_fever
    e.current_multiplier = ce.current_multiplier
    e.hit_counter = ce.hit_counter
    e.total_red_pegs = ce.total_red_pegs
    e.red_pegs_hit_amount = ce.red_pegs_hit_amount
    e.bonus_score = ce.bonus_score
    e.style_score = ce.style_score

    empty!(e.pegs)
    for p in ce.pegs
        push!(e.pegs, Peg(p.id, p.x, p.y, p.base_x, p.base_y, p.shape,
                          p.peg_type, p.hit, p.hit_order, p.multiplier_at_hit,
                          p.line))
    end
    empty!(e.peg_by_id)
    for p in e.pegs
        e.peg_by_id[p.id] = p
    end

    empty!(e.balls)
    for cb in ce.balls
        push!(e.balls, _sim_ball(cb))
    end
    empty!(e.live_ball_ids)
    empty!(e.live_id_by_ball)
    for b in e.balls
        e.live_ball_ids[b.id] = b
        e.live_id_by_ball[b] = b.id
    end

    b = ce.bucket
    e.bucket.x = b.x
    e.bucket.prev_x = b.prev_x
    e.bucket.top = b.top
    e.bucket.hole = b.hole
    e.bucket.edge = b.edge
    e.bucket.height = b.height
    e.bucket.phase = b.phase

    cf = ce.fever_buckets
    e.fever_buckets.top = cf.top
    e.fever_buckets.target_top = cf.target_top
    e.fever_buckets.height = cf.height
    e.fever_buckets.animating = cf.animating
    empty!(e.fever_buckets.buckets)
    for fb in cf.buckets
        push!(e.fever_buckets.buckets, FeverBucketSpec(fb.x, fb.width, fb.value))
    end
    empty!(e.fever_buckets.dividers)
    for fd in cf.dividers
        push!(e.fever_buckets.dividers, FeverDivider(fd.x, fd.y, fd.radius, fd.is_divider))
    end

    ce.clearing.active && throw(ArgumentError(
        "checkpoint: v1 ready_to_aim checkpoints must have clearing.active == false"))
    e.clear_queue = nothing
    e.clearing_is_end_of_turn = ce.clearing.is_end_of_turn
    e.clear_timer = ce.clearing.timer

    empty!(e.turn_pegs_hit)
    append!(e.turn_pegs_hit, ce.turn_pegs_hit)
    e.next_ball_id = ce.next_ball_id
    empty!(e.used_ball_ids)
    append!(e.used_ball_ids, ce.used_ball_ids)

    empty!(sim.colors.queue)
    append!(sim.colors.queue, ckpt.purple_queue.queue)
    empty!(sim.colors.active)
    append!(sim.colors.active, ckpt.purple_queue.active)
    sim.colors.rng = sim.rng

    _restore_trackers!(sim.trackers, ckpt.trackers)
    sim.match = _match_from_checkpoint(ckpt)

    return sim
end

# ---------------------------------------------------------------------------
# Convenience and comparison
# ---------------------------------------------------------------------------

function build_checkpoint(
    level::LevelDefinition,
    config::SimConfig;
    balls::Int = 1,
    mode::Symbol = :solo,
    provenance,
)::Checkpoint
    sim = build_sim_state(level, config; balls = balls, mode = mode)
    return capture_checkpoint(sim; provenance = provenance)
end

first_difference(a::Checkpoint, b::Checkpoint; path::AbstractString = "") =
    first_difference(checkpoint_to_dict(a), checkpoint_to_dict(b); path = path)

function first_difference(a, b; path::AbstractString = "")
    return _first_difference(a, b, String(path))
end

_first_difference_key(k) = k isa AbstractString ? String(k) : string(k)

function _first_difference(a, b, path::String)
    if a isa AbstractDict && b isa AbstractDict
        map_a = Dict{String,Any}(_first_difference_key(k) => v for (k, v) in a)
        map_b = Dict{String,Any}(_first_difference_key(k) => v for (k, v) in b)
        for key in sort!(collect(union(keys(map_a), keys(map_b))))
            child = isempty(path) ? key : path * "." * key
            if !haskey(map_a, key) || !haskey(map_b, key)
                return child
            end
            diff = _first_difference(map_a[key], map_b[key], child)
            diff === nothing || return diff
        end
        return nothing
    elseif (a isa AbstractVector || a isa Tuple) && (b isa AbstractVector || b isa Tuple)
        if length(a) != length(b)
            return isempty(path) ? "\$" : path * "[$(min(length(a), length(b)) + 1)]"
        end
        for i in eachindex(a)
            diff = _first_difference(a[i], b[i], path * "[" * string(i) * "]")
            diff === nothing || return diff
        end
        return nothing
    else
        return isequal(a, b) ? nothing : (isempty(path) ? "\$" : path)
    end
end
