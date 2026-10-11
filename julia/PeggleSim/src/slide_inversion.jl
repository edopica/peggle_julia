# ===========================================================================
# SlideInversion: valley (pendulum) detection and lowest-peg removal.
#
# Ports src/systems/slide_inversion.lua (dev tree, `detmath.sqrt` routing).
#
# A ball can settle into a concave valley formed by a zero-gap generated
# line and oscillate like a pendulum, scoring peg after peg on every pass.
# This processor detects the apex of each oscillation — the moment the ball
# stops rolling along the slide and goes back — and asks the Engine to remove
# the lowest already-hit peg(s) of that line.
#
# Detection (per launched ball, per slide line):
#   * The ball is "on a slide" while it keeps contacting a zero-gap line
#     (line.gap == 0) within slide_invert_contact_timeout. Contacting a
#     different line restarts the tracking.
#   * Each peg contact reports the surface normal (peg -> ball). The signed
#     tangential speed is tang = nx*vy - ny*vx; its sign flips at an apex.
#   * |tang| below slide_invert_tangent_epsilon is ignored, so the previous
#     direction is held across the apex.
#   * A genuine bounce (did_bounce) resyncs the direction instead of
#     triggering.
#
# Removal: on inversion select the already-hit pegs of the sliding line whose
# recorded impact_y is greatest (lowest on screen); ties within
# slide_invert_lowest_tie are all selected. Push `remove_slide_pegs` with
# their stable original index ids. Pegs removed by an earlier inversion are
# skipped. Scoring is untouched.
#
# Lua nil/false reads map to explicit `nothing`/`false` checks via
# `_si_truthy` (a missing key and a stored `false` are both "not set").
#
# Tracker schema (STATE.jl v1, no field changes):
#   line_hits[line_id] = Vector of Dict("peg_id","impact_y"), score order
#   hit_seen[peg_id]   = true
#   removed[peg_id]    = true
#   track[ball_id]     = Dict("line_id","no_contact_time","tangent_sign")
# ===========================================================================

# Lua truthiness for values read from the tracker maps (nil/false are falsy).
_si_truthy(v) = v !== nothing && v !== false

# `bid = ev.ball_id`; nil ball ids skip the event.
function _si_ball_id(ev::GameEvent)
    v = get(ev.fields, "ball_id", nothing)
    return v === nothing ? nothing : Int(v)
end

# Local speed_of(b): sqrt(vx*vx + vy*vy).
function _si_ball_speed(b::BallState)::Float64
    return DetMath.det_sqrt(b.vx * b.vx + b.vy * b.vy)
end

# Sign of the ball's velocity along the contact surface (the tangential
# component perpendicular to the contact normal). nothing when the ball is
# too slow for the sign to be trusted.
function _si_tangent_sign(nx::Float64, ny::Float64, b::BallState,
                          epsilon::Float64)
    speed = _si_ball_speed(b)
    if speed <= 0
        return nothing
    end
    tang = nx * b.vy - ny * b.vx
    if abs(tang) < epsilon
        return nothing
    end
    if tang > 0
        return 1
    end
    return -1
end

# Record first-hit impact positions for zero-gap lines. First-hit only, so
# one entry per peg; impact_y is the y of the ball at the scoring contact
# (Lua `ev.impact_y or 0`).
function _si_note_scores!(t::SlideInversionTrackers, journal::GameplayJournal)
    for ev in journal.derived
        if ev.type == "peg_scored"
            line = get(ev.fields, "line", nothing)
            line isa AbstractDict || continue
            get(line, "gap", nothing) == 0 || continue
            peg_id = Int(ev.fields["peg_id"])
            _si_truthy(get(t.hit_seen, peg_id, nothing)) && continue
            t.hit_seen[peg_id] = true
            line_id = String(line["id"])
            arr = get(t.line_hits, line_id, nothing)
            if arr === nothing
                arr = Any[]
                t.line_hits[line_id] = arr
            end
            iy = get(ev.fields, "impact_y", nothing)
            push!(arr, Dict{String,Any}(
                "peg_id" => peg_id,
                "impact_y" => (iy === nothing ? 0.0 : Float64(iy)),
            ))
        end
    end
    return nothing
end

# Lowest already-hit, not-yet-removed pegs of a line, in deterministic score
# order. Empty when the line has no eligible hit pegs. Ties within `tie`
# (Config.slide_invert_lowest_tie) are all selected.
function _si_lowest_hit_pegs(t::SlideInversionTrackers, line_id::AbstractString,
                             tie::Float64)::Vector{Int}
    arr = get(t.line_hits, line_id, nothing)
    arr === nothing && return Int[]
    max_y = nothing
    for rec in arr
        if !_si_truthy(get(t.removed, rec["peg_id"], nothing))
            y = rec["impact_y"]
            if max_y === nothing || y > max_y
                max_y = y
            end
        end
    end
    max_y === nothing && return Int[]
    out = Int[]
    for rec in arr
        if !_si_truthy(get(t.removed, rec["peg_id"], nothing)) &&
           rec["impact_y"] >= max_y - tie
            push!(out, rec["peg_id"])
        end
    end
    return out
end

# Run the inversion check for one completed fixed step. Only launched balls
# are considered.
function slide_inversion_process!(
    t::SlideInversionTrackers,
    journal::GameplayJournal,
    commands::GameplayCommands,
    balls::Vector{BallState},
    dt::Float64,
    c::SimConfig,
)::Nothing
    timeout = c.slide_invert_contact_timeout
    epsilon = c.slide_invert_tangent_epsilon
    tie = Float64(c.slide_invert_lowest_tie)

    _si_note_scores!(t, journal)

    # This step's zero-gap contact line + surface normal and any genuine
    # bounce, per ball.
    contact_line = Dict{Int,String}()
    contact_normal = Dict{Int,NTuple{2,Float64}}()
    bounced = Dict{Int,Bool}()
    for ev in journal.raw
        bid = _si_ball_id(ev)
        bid === nothing && continue
        if ev.type == "ball_contacted_peg"
            line = get(ev.fields, "line", nothing)
            if line isa AbstractDict && get(line, "gap", nothing) == 0
                contact_line[bid] = String(line["id"])
                nx = get(ev.fields, "normal_x", nothing)
                ny = get(ev.fields, "normal_y", nothing)
                contact_normal[bid] = (
                    nx === nothing ? 0.0 : Float64(nx),
                    ny === nothing ? 0.0 : Float64(ny),
                )
            end
        end
        if _si_truthy(get(ev.fields, "did_bounce", nothing))
            bounced[bid] = true
        end
    end

    for b in balls
        b.launched || continue
        bid = b.id
        line_id = get(contact_line, bid, nothing)
        track = get(t.track, bid, nothing)

        if line_id !== nothing
            if track !== nothing && track["line_id"] != line_id
                # A different line ends the previous slide.
                track = nothing
                delete!(t.track, bid)
            end
            if track === nothing
                track = Dict{String,Any}(
                    "line_id" => line_id,
                    "no_contact_time" => 0.0,
                    "tangent_sign" => nothing,
                )
                t.track[bid] = track
            end
            track["no_contact_time"] = 0.0
        elseif track !== nothing
            track["no_contact_time"] =
                Float64(track["no_contact_time"]) + dt
            if track["no_contact_time"] > timeout
                track = nothing
                delete!(t.track, bid)
            end
        end

        if track !== nothing
            normal = get(contact_normal, bid, nothing)
            sign = normal === nothing ? nothing :
                _si_tangent_sign(normal[1], normal[2], b, epsilon)
            if _si_truthy(get(bounced, bid, nothing))
                # A real bounce is not a pendulum inversion: resync the
                # direction to the post-bounce motion.
                track["tangent_sign"] = sign
            elseif sign !== nothing
                prev_sign = track["tangent_sign"]
                if _si_truthy(prev_sign) && sign != prev_sign
                    # The ball stopped rolling and went back: drop the lowest
                    # already-hit peg(s) of the line to open the valley.
                    peg_ids = _si_lowest_hit_pegs(t, track["line_id"], tie)
                    if !isempty(peg_ids)
                        for pid in peg_ids
                            t.removed[pid] = true
                        end
                        push_command!(commands, "remove_slide_pegs", Dict{String,Any}(
                            "ball_id" => bid,
                            "line_id" => track["line_id"],
                            "reason" => "slide_direction_inversion",
                            "peg_ids" => peg_ids,
                        ))
                    end
                end
                track["tangent_sign"] = sign
            end
        end
    end
    return nothing
end

# Notify that a ball was removed.
function slide_inversion_on_ball_removed!(t::SlideInversionTrackers,
                                          ball_id::Int)::Nothing
    delete!(t.track, ball_id)
    return nothing
end
