# Port of ../peggle_evolved/src/systems/simulation_snapshot.lua (schema v2).
#
# Deterministic in-memory authoritative state capture. No live entity
# references are retained: balls/pegs/bucket are copied by value (scalars
# only). Order is stable: balls in active_balls order, pegs in original_index
# order. Creation does not mutate simulation state.
#
# Null mapping (Lua stores nil fields as absent keys):
#   * circle and annular pegs have no base_angle/angle in the reference,
#     so the keys are omitted; rectangles carry both.
#   * hit_order/multiplier_at_hit are omitted until the first hit.
#   * circuit_id/circuit_t/circuit_state/circuit_timer/motion are omitted for
#     static pegs (no motion record).
#   * ball scored_fever is omitted while false.
#   * copy_fever omits target_top and the divider is_divider flag.
#   * line metadata is omitted when the peg has no line.

const SNAPSHOT_SCHEMA_VERSION = 2

function _snapshot_line(l::LineMetadata)::Dict{String,Any}
    return Dict{String,Any}(
        "id" => l.id,
        "index" => l.index,
        "count" => l.count,
        "closed" => l.closed,
        "gap" => l.gap,
    )
end

function _snapshot_peg(p::Peg)::Dict{String,Any}
    d = Dict{String,Any}(
        "original_index" => p.id,
        "type" => String(p.peg_type),
        "shape" => peg_shape_name(p.shape),
        "hit" => p.hit,
        "x" => p.x,
        "y" => p.y,
        "base_x" => p.base_x,
        "base_y" => p.base_y,
        "vx" => p.vx,
        "vy" => p.vy,
        "va" => p.va,
    )
    p.line === nothing || (d["line"] = _snapshot_line(p.line))
    # Lua hit_order/multiplier_at_hit are nil until the first hit; zero is the
    # Julia sentinel for "never hit".
    p.hit_order == 0 || (d["hit_order"] = p.hit_order)
    p.multiplier_at_hit == 0 || (d["multiplier_at_hit"] = p.multiplier_at_hit)
    if p.shape isa RectangleShape
        d["base_angle"] = p.base_angle
        d["angle"] = p.angle
        d["width"] = p.shape.width
        d["height"] = p.shape.height
    elseif p.shape isa AnnularShape
        # The snapshot writer records the authored sector, not the runtime
        # vertex count (Lua copy_peg has no segments field).
        d["r_in"] = p.shape.r_in
        d["r_out"] = p.shape.r_out
        d["theta_start"] = p.shape.theta_start
        d["theta_end_abs"] = p.shape.theta_end_abs
    else
        d["radius"] = p.shape.radius
    end
    return d
end

function _snapshot_ball(b::BallState)::Dict{String,Any}
    d = Dict{String,Any}(
        "id" => b.id,
        "x" => b.x,
        "y" => b.y,
        "prev_x" => b.prev_x,
        "prev_y" => b.prev_y,
        "vx" => b.vx,
        "vy" => b.vy,
        "radius" => b.radius,
        "launched" => b.launched,
    )
    b.scored_fever && (d["scored_fever"] = true)
    return d
end

function _snapshot_bucket(b::BucketState)::Dict{String,Any}
    return Dict{String,Any}(
        "x" => b.x,
        "prev_x" => b.prev_x,
        "top" => b.top,
        "hole" => b.hole,
        "edge" => b.edge,
        "height" => b.height,
        "phase" => b.phase,
    )
end

function _snapshot_fever(f::FeverBucketsState)::Dict{String,Any}
    buckets = Any[
        Dict{String,Any}("x" => slot.x, "width" => slot.width,
                         "value" => slot.value)
        for slot in f.buckets
    ]
    dividers = Any[
        Dict{String,Any}("x" => d.x, "y" => d.y, "radius" => d.radius)
        for d in f.dividers
    ]
    return Dict{String,Any}(
        "top" => f.top,
        "height" => f.height,
        "animating" => f.animating,
        "buckets" => buckets,
        "dividers" => dividers,
    )
end

# Capture the full authoritative snapshot of a shot engine. Mirrors
# SimulationSnapshot.capture(engine) field-for-field. The ShotEngine type is
# defined after this file in the fixed include order, so the argument is
# duck-typed; it must expose `sim.engine` (the frozen interface).
function snapshot_capture(engine)::Dict{String,Any}
    e = engine.sim.engine

    balls = Any[_snapshot_ball(b) for b in e.balls]
    pegs = Any[_snapshot_peg(p) for p in e.pegs]

    return Dict{String,Any}(
        "schema_version" => SNAPSHOT_SCHEMA_VERSION,
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
        "turn_peg_count" => length(e.turn_pegs_hit),
        "clearing_active" => e.clear_queue !== nothing,
        "clearing_is_end_of_turn" => e.clearing_is_end_of_turn,
        "clear_timer" => e.clear_timer,
        "balls" => balls,
        "pegs" => pegs,
        "bucket" => _snapshot_bucket(e.bucket),
        "fever_buckets" => _snapshot_fever(e.fever_buckets),
        "turn_pegs_hit" => copy(e.turn_pegs_hit),
    )
end
