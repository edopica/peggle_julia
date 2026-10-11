# Live simulation state for the M2 ready-to-aim boundary.
#
# Ports the constructor state of the reference entities/systems:
#   * BucketState          <- src/entities/bucket.lua Bucket.new
#   * FeverBucketsState    <- src/entities/fever_buckets.lua FeverBuckets.new
#   * BallState            <- src/entities/ball.lua Ball.new
#   * Trackers             <- StyleShots/BallState/SlideInversion reset_shot
#   * MatchState           <- solo match bookkeeping used by the harness
#   * EngineState/SimState <- the ready-to-aim slices of Engine:setupLevel and
#                             Engine:resetTurn (core.lua)
#
# Only the ready-to-aim state is modeled in M2; shot-time systems arrive
# with their milestones. Trackers keep the full schema v1 field set so the
# checkpoint is lossless.

mutable struct BucketState
    x::Float64
    prev_x::Float64
    top::Float64
    hole::Float64
    edge::Float64
    height::Float64
    phase::Float64
end

# Bucket.new: centered, opening at vh - margin - height, phase pi/2.
function BucketState(vw::Float64, vh::Float64, c::SimConfig)::BucketState
    return BucketState(
        vw / 2,                     # x
        vw / 2,                     # prev_x
        vh - c.bucket_margin - c.bucket_height, # top
        c.bucket_hole,
        c.bucket_edge,
        c.bucket_height,
        pi / 2,                     # starts at center, moving right
    )
end

mutable struct FeverBucketSpec
    x::Float64
    width::Float64
    value::Float64
end

mutable struct FeverDivider
    x::Float64
    y::Float64
    radius::Float64
    is_divider::Bool
end

mutable struct FeverBucketsState
    top::Float64
    target_top::Float64
    height::Float64
    animating::Bool
    buckets::Vector{FeverBucketSpec}
    dividers::Vector{FeverDivider}
end

# FeverBuckets.new: five segments of vw/5 separated by radius-40 dividers.
function FeverBucketsState(c::SimConfig, vw::Float64, vh::Float64)::FeverBucketsState
    separator_radius = 40.0
    segment = vw / 5
    dividers = FeverDivider[
        FeverDivider(i * segment, vh, separator_radius, true) for i in 0:5
    ]
    values = (10000.0, 50000.0, 100000.0, 50000.0, 10000.0)
    buckets = FeverBucketSpec[
        FeverBucketSpec((i - 1) * segment + separator_radius,
                        segment - 2 * separator_radius,
                        values[i]) for i in 1:5
    ]
    return FeverBucketsState(vh, vh, 40.0, false, buckets, dividers)
end

# FeverBuckets.activate (core.lua updateMultiplier -> isFever transition).
function activate_fever_buckets!(f::FeverBucketsState)
    f.top = f.target_top + f.height + 50.0
    f.animating = true
    for d in f.dividers
        d.y = f.top
    end
    return f
end

mutable struct BallState
    id::Int
    x::Float64
    y::Float64
    prev_x::Float64
    prev_y::Float64
    vx::Float64
    vy::Float64
    radius::Float64
    launched::Bool
    scored_fever::Bool
end

# Ball.new: zero velocity, unlaunched, previous position at the spawn point.
# `scored_fever` is set by the fever scoring path, never at construction.
function BallState(id::Int, x::Float64, y::Float64, radius::Float64)::BallState
    return BallState(id, x, y, x, y, 0.0, 0.0, radius, false, false)
end

mutable struct StyleShotTrackers
    last_impact::Dict{Int,Any}
    qualifying_streak::Dict{Int,Any}
    last_qualifying_seq::Dict{Int,Any}
    bucket_bounced::Dict{Int,Any}
    bounced_after_bucket::Dict{Int,Any}
    side_wall_hit::Dict{Int,Any}
    hit_any_peg::Dict{Int,Any}
    awarded::Dict{Int,Any}
    slide_runs::Dict{String,Any}
    slide_awarded::Dict{String,Any}
end

function StyleShotTrackers()
    return StyleShotTrackers(
        Dict{Int,Any}(), Dict{Int,Any}(), Dict{Int,Any}(), Dict{Int,Any}(),
        Dict{Int,Any}(), Dict{Int,Any}(), Dict{Int,Any}(), Dict{Int,Any}(),
        Dict{String,Any}(), Dict{String,Any}(),
    )
end

function reset_shot!(t::StyleShotTrackers)
    empty!(t.last_impact)
    empty!(t.qualifying_streak)
    empty!(t.last_qualifying_seq)
    empty!(t.bucket_bounced)
    empty!(t.bounced_after_bucket)
    empty!(t.side_wall_hit)
    empty!(t.hit_any_peg)
    empty!(t.awarded)
    empty!(t.slide_runs)
    empty!(t.slide_awarded)
    return t
end

mutable struct BallStateTrackers
    idle::Dict{Int,Any}
    idle_timer::Dict{Int,Any}
    reacted::Dict{Int,Any}
    all_idle_latch::Bool
    no_score_timer::Float64
    no_score_timeout_fired::Bool
end

function BallStateTrackers()
    return BallStateTrackers(
        Dict{Int,Any}(), Dict{Int,Any}(), Dict{Int,Any}(), false, 0.0, false)
end

function reset_shot!(t::BallStateTrackers)
    empty!(t.idle)
    empty!(t.idle_timer)
    empty!(t.reacted)
    t.all_idle_latch = false
    t.no_score_timer = 0.0
    t.no_score_timeout_fired = false
    return t
end

mutable struct SlideInversionTrackers
    line_hits::Dict{String,Any}
    hit_seen::Dict{Int,Any}
    removed::Dict{Int,Any}
    track::Dict{Int,Any}
end

function SlideInversionTrackers()
    return SlideInversionTrackers(
        Dict{String,Any}(), Dict{Int,Any}(), Dict{Int,Any}(), Dict{Int,Any}())
end

function reset_shot!(t::SlideInversionTrackers)
    empty!(t.line_hits)
    empty!(t.hit_seen)
    empty!(t.removed)
    empty!(t.track)
    return t
end

mutable struct Trackers
    style_shots::StyleShotTrackers
    ball_state::BallStateTrackers
    slide_inversion::SlideInversionTrackers
end

function Trackers()
    return Trackers(
        StyleShotTrackers(), BallStateTrackers(), SlideInversionTrackers())
end

function reset_shot!(t::Trackers)
    reset_shot!(t.style_shots)
    reset_shot!(t.ball_state)
    reset_shot!(t.slide_inversion)
    return t
end

mutable struct MatchPlayer
    score::Float64
    balls::Int
    bucket_hits::Int
end

mutable struct MatchState
    mode::Symbol
    players::Vector{MatchPlayer}
    current_player_index::Int
    shared_bucket_hits::Int
    game_over::Bool
    winner::Union{Nothing,Int}
end

function MatchState(mode::Symbol; starting_balls::Int)
    players = [MatchPlayer(0.0, starting_balls, 0), MatchPlayer(0.0, starting_balls, 0)]
    return MatchState(mode, players, 1, 0, false, nothing)
end

# Ready-to-aim slice of Engine.new / Engine:setupLevel / Engine:resetTurn.
mutable struct EngineState
    step_id::Int                    # Engine.sim_step_id
    shot_id::Int
    level_name::String
    pegs::Vector{Peg}
    peg_by_id::Dict{Int,Peg}
    balls::Vector{BallState}        # active_balls
    live_ball_ids::Dict{Int,BallState}
    live_id_by_ball::IdDict{BallState,Int}
    bucket::BucketState
    fever_buckets::FeverBucketsState
    clear_queue::Union{Nothing,Vector{Peg}}
    clearing_is_end_of_turn::Bool
    clear_timer::Float64
    bonus_score::Float64
    style_score::Float64
    total_red_pegs::Int
    red_pegs_hit_amount::Int
    current_multiplier::Int
    is_fever::Bool
    hit_counter::Int
    turn_pegs_hit::Vector{Int}
    next_ball_id::Int
    used_ball_ids::Vector{Int}
end

mutable struct SimState
    engine::EngineState
    rng::LoveRandom
    colors::ColorState
    trackers::Trackers
    match::MatchState
end

# core.lua:306-320 thresholds; entering fever raises the bucket bank.
function update_multiplier!(e::EngineState)
    was_fever = e.is_fever
    if e.total_red_pegs == 0
        e.current_multiplier = 1
    else
        percentage = e.red_pegs_hit_amount / e.total_red_pegs
        if percentage >= 1.0
            e.current_multiplier = 100
        elseif percentage >= 0.88
            e.current_multiplier = 10
        elseif percentage >= 0.75
            e.current_multiplier = 5
        elseif percentage >= 0.60
            e.current_multiplier = 3
        elseif percentage >= 0.40
            e.current_multiplier = 2
        else
            e.current_multiplier = 1
        end
    end
    e.is_fever = e.current_multiplier == 100
    if e.is_fever && !was_fever
        activate_fever_buckets!(e.fever_buckets)
    end
    return e
end

# Harness initial-ball placement (INTERFACES.md decision 8).
function _initial_ball_x(index::Int, balls::Int, vw::Float64)::Float64
    return balls == 1 ? vw / 2 : (index / (balls + 1)) * vw
end

# Build the ready-to-aim state: artifact pegs -> PegColors.init -> bucket /
# fever / scoring / trackers -> resetTurn ball allocation and first
# purple promotion. Equivalent to setupLevel + resetTurn with harness balls.
function build_sim_state(
    level::LevelDefinition,
    c::SimConfig;
    balls::Int = 1,
    mode::Symbol = :solo,
)::SimState
    balls >= 1 || throw(ArgumentError("balls must be >= 1, got $(balls)"))

    pegs = Peg[
        Peg(p.id, p.x, p.y, p.x, p.y, p.shape, p.peg_type, false, 0, 0, p.line)
        for p in level.pegs
    ]
    peg_by_id = Dict(p.id => p for p in pegs)

    rng = LoveRandom(level.level_seed)
    colors = init_colors!(pegs, level.type_counts, level.level_seed, rng)

    bucket = BucketState(level.virtual_width, level.virtual_height, c)
    fever = FeverBucketsState(c, level.virtual_width, level.virtual_height)

    initial_balls = BallState[
        BallState(i, _initial_ball_x(i, balls, level.virtual_width), 50.0, c.ball_radius)
        for i in 1:balls
    ]
    live_ball_ids = Dict(id => b for (id, b) in zip(1:balls, initial_balls))
    live_id_by_ball = IdDict(b => id for (id, b) in zip(1:balls, initial_balls))

    engine = EngineState(
        0,                          # step_id
        0,                          # shot_id
        level.name,
        pegs,
        peg_by_id,
        initial_balls,
        live_ball_ids,
        live_id_by_ball,
        bucket,
        fever,
        nothing,                    # clear_queue
        false,                      # clearing_is_end_of_turn
        0.0,                        # clear_timer
        0.0,                        # bonus_score
        0.0,                        # style_score
        level.type_counts.red,      # total_red_pegs
        0,                          # red_pegs_hit_amount
        1,                          # current_multiplier
        false,                      # is_fever
        0,                          # hit_counter
        Int[],                      # turn_pegs_hit
        balls + 1,                  # next_ball_id
        collect(1:balls),           # used_ball_ids
    )
    update_multiplier!(engine)

    trackers = Trackers()
    match = MatchState(mode; starting_balls = c.starting_balls)

    assign_next_purple_pegs!(pegs, colors, c.purple_pegs_per_turn)

    return SimState(engine, rng, colors, trackers, match)
end
