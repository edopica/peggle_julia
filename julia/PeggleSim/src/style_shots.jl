# ===========================================================================
# StyleShots: deterministic style-shot recognition from gameplay events.
#
# Ports src/systems/style_shots.lua (dev tree, `detmath.sqrt` routing). The
# processor consumes the step's completed event stream (raw then derived)
# from the GameplayJournal and pushes `award_style_points` commands for
# qualifying style shots.
#
# Recognized styles:
#   long_shot          — a segment between two consecutive chain-eligible
#                        scoring peg impacts (same ball) whose impact-position
#                        distance is >= long_shot_distance.
#   super_long_shot   — same, but >= super_long_shot_distance. Super does not
#                        also award Long.
#   double_long_shot   — the second consecutive *qualifying* segment in a row.
#   lucky_bounce       — a bucket bounce followed (later in the shot) by a
#                        bucket catch for the same ball.
#   off_the_wall       — a side-wall contact followed by a non-blue peg
#                        score for the same ball.
#   slide              — slide_min_pegs consecutive scoring contacts on
#                        adjacent zero-gap line pegs of ONE line (closed lines
#                        wrap) with no bounce inside the run; awarded once per
#                        ball and line per shot.
#
# Chain rules (per ball, across the whole shot):
#   * Only valid impacts ("sweep" or "graze") on peg contacts participate.
#   * A valid contact that scores a NON-blue peg for the first time is
#     "chain-eligible". A qualifying distance awards Long/Super and advances
#     the consecutive-qualifying streak; a short distance resets the streak.
#   * A valid contact with a blue peg, or with an already-hit peg (no
#     peg_scored this contact), BREAKS the chain.
#   * Graze / overlap / depenetration contacts neither complete nor break.
#   * Off the Wall: a side-wall hit is consumed when a peg is subsequently
#     scored — non-blue awards it, blue or already-hit fails it.
#
# Lua nil/false reads map to explicit `nothing`/`false` checks. `_style_truthy`
# mirrors Lua truthiness for the tracker maps: a missing key and a stored
# `false` are both "not set".
#
# Tracker maps (STATE.jl schema v1, no field changes); the M2 schema types
# slide_runs / slide_awarded as Dict{String,Any}, so the Lua
# `slide_runs[ball_id][line_id]` nesting keys the outer map by the ball id's
# string form. Line ids are artifact strings (LineMetadata.id::String).
#   last_impact[ball_id]             = Dict("x","y","seq")
#   awarded[ball_id]                 = Dict("long","super","double_long_shot",
#                                           "lucky","off_wall")
#   slide_runs[string(ball_id)]      = Dict(line_id => Dict("len","last",
#                                                           "dir","seqs"))
#   slide_awarded[string(ball_id)]   = Dict(line_id => true)
#
# The `virtual_width` argument is part of the frozen interface and mirrors the
# Engine passing LevelManager.virtual_width; the dev-tree Lua reads it into
# `vw` but the current recognizer never uses it (off-the-wall has no distance
# gate). It is kept for signature compatibility.
# ===========================================================================

# Lua truthiness for values read from the tracker maps (nil/false are falsy).
_style_truthy(v) = v !== nothing && v !== false

# `bid = ev.ball_id`; nil ball ids skip every branch (each Lua branch also
# checks `bid ~= nil`).
function _style_ball_id(ev::GameEvent)
    v = get(ev.fields, "ball_id", nothing)
    return v === nothing ? nothing : Int(v)
end

# Lua `ev.did_bounce` read as truthiness.
_style_did_bounce(ev::GameEvent) = _style_truthy(get(ev.fields, "did_bounce", nothing))

# Local dist(x1, y1, x2, y2): dx = x1 - x2; dy = y1 - y2; sqrt(dx*dx + dy*dy).
function _style_dist(x1, y1, x2, y2)::Float64
    dx = Float64(x1) - Float64(x2)
    dy = Float64(y1) - Float64(y2)
    return DetMath.det_sqrt(dx * dx + dy * dy)
end

# ensure_award_tab: returns the ball's award table, creating it if absent.
function _style_ensure_award_tab!(t::StyleShotTrackers, ball_id::Int)
    tab = get(t.awarded, ball_id, nothing)
    if tab === nothing
        tab = Dict{String,Any}()
        t.awarded[ball_id] = tab
    end
    return tab
end

# A ball's slide runs are stored under string(ball_id) (see file header).
# clear_ball_slide sets slide_runs[bid] = nil; the per-(ball, line) award
# markers in slide_awarded survive.
function _style_clear_ball_slide!(t::StyleShotTrackers, ball_id::Int)
    delete!(t.slide_runs, string(ball_id))
    return nothing
end

# run_tab: returns (creating if needed) the run for one (ball, line):
# { len, last, dir, seqs }.
function _style_run_tab!(t::StyleShotTrackers, ball_id::Int, line_id::AbstractString)
    key = string(ball_id)
    by_line = get(t.slide_runs, key, nothing)
    if by_line === nothing
        by_line = Dict{String,Any}()
        t.slide_runs[key] = by_line
    end
    run = get(by_line, String(line_id), nothing)
    if run === nothing
        run = Dict{String,Any}(
            "len" => 0, "last" => nothing, "dir" => 0, "seqs" => Any[])
        by_line[String(line_id)] = run
    end
    return run
end

# Extend or seed the slide run for one scored contact on a zero-gap line
# (StyleShots:note_slide_score). Called only for scoring contacts.
function _style_note_slide_score!(
    t::StyleShotTrackers,
    ev::GameEvent,
    scored::GameEvent,
    commands::GameplayCommands,
    min::Int,
    points::Float64,
)
    bid = Int(ev.fields["ball_id"])
    line = ev.fields["line"]::AbstractDict
    line_id = String(line["id"])
    scored_line = scored.fields["line"]::AbstractDict
    index = Int(scored_line["index"])
    run = _style_run_tab!(t, bid, line_id)

    if _style_did_bounce(ev)
        # A landing bounce may start a slide: any existing run was already
        # cleared by the bounce handling in process_step; seed length one.
        run["len"] = 1
        run["last"] = index
        run["dir"] = 0
        run["seqs"] = Any[ev.sequence]
        return nothing
    end

    if run["len"] == 0
        run["len"] = 1
        run["last"] = index
        run["dir"] = 0
        run["seqs"] = Any[ev.sequence]
        return nothing
    end

    # Extend: adjacent in the run's direction. Closed lines wrap.
    delta = index - (run["last"]::Int)
    if abs(delta) != 1
        closed = _style_truthy(get(line, "closed", nothing))
        count = Int(line["count"])
        if closed && delta == 1 - count
            delta = 1
        elseif closed && delta == count - 1
            delta = -1
        end
    end
    # A qualifying zero-gap contact that cannot extend the current run
    # invalidates it and seeds a fresh length-one run at this index. This
    # covers both a non-adjacent delta and a direction mismatch.
    run_dir = run["dir"]::Int
    if (delta != 1 && delta != -1) || (run_dir != 0 && run_dir != delta)
        run["len"] = 1
        run["last"] = index
        run["dir"] = 0
        run["seqs"] = Any[ev.sequence]
        return nothing
    end
    if run_dir == 0
        run["dir"] = delta
    end

    run["len"] = (run["len"]::Int) + 1
    run["last"] = index
    seqs = run["seqs"]::Vector{Any}
    if length(seqs) < min
        push!(seqs, ev.sequence)
    end

    if run["len"] == min
        key = string(bid)
        awarded = get(t.slide_awarded, key, nothing)
        if awarded !== nothing && _style_truthy(get(awarded, line_id, nothing))
            return nothing
        end
        if awarded === nothing
            awarded = Dict{String,Any}()
            t.slide_awarded[key] = awarded
        end
        awarded[line_id] = true
        push_command!(commands, "award_style_points", Dict{String,Any}(
            "ball_id" => bid,
            "style" => "slide",
            "points" => points,
            "line_id" => line_id,
            "source_sequences" => run["seqs"],
        ))
    end
    return nothing
end

# One event of the step, processed against the tracker state. Mirrors the
# body of StyleShots:process_step's `for _, ev in ipairs(events:all())` loop.
function _style_process_event!(
    t::StyleShotTrackers,
    ev::GameEvent,
    scored_by_source::Dict{Int,GameEvent},
    commands::GameplayCommands,
    pt_lucky::Float64,
    pt_off_wall::Float64,
    pt_long::Float64,
    pt_super::Float64,
    pt_double::Float64,
    long_d::Float64,
    super_d::Float64,
    slide_min::Int,
    pt_slide::Float64,
)
    bid = _style_ball_id(ev)
    bid === nothing && return nothing

    if ev.type == "ball_contact_wall"
        if _style_truthy(get(t.bucket_bounced, bid, nothing))
            t.bounced_after_bucket[bid] = true
        end
        wall = get(ev.fields, "wall", nothing)
        if (wall == "left" || wall == "right") &&
           !_style_truthy(get(t.hit_any_peg, bid, nothing))
            t.side_wall_hit[bid] = ev.sequence
        end
        # Only a real bounce breaks the Long Shot chain / resets slides;
        # settling (non-bouncing) wall contacts are observational.
        if _style_did_bounce(ev)
            t.qualifying_streak[bid] = 0
            delete!(t.last_impact, bid)
            delete!(t.last_qualifying_seq, bid)
            _style_clear_ball_slide!(t, bid)
        end

    elseif ev.type == "bucket_bounced_ball"
        t.bucket_bounced[bid] = ev.sequence
        t.bounced_after_bucket[bid] = false
        # Bucket bounce breaks Long Shot chain.
        t.qualifying_streak[bid] = 0
        delete!(t.last_impact, bid)
        delete!(t.last_qualifying_seq, bid)
        # Bucket bounce resets slide runs.
        _style_clear_ball_slide!(t, bid)

    elseif ev.type == "ball_contact_fever_divider"
        # Only a real divider bounce resets slide runs.
        if _style_did_bounce(ev)
            _style_clear_ball_slide!(t, bid)
        end

    elseif ev.type == "ball_contact_ball"
        # A real ball-ball bounce is a trajectory discontinuity for both
        # balls: reset their slide runs. It does not break the Long Shot
        # chain.
        if _style_truthy(get(t.bucket_bounced, bid, nothing))
            t.bounced_after_bucket[bid] = true
        end
        other = get(ev.fields, "other_ball_id", nothing)
        other_bid = other === nothing ? nothing : Int(other)
        if other_bid !== nothing &&
           _style_truthy(get(t.bucket_bounced, other_bid, nothing))
            t.bounced_after_bucket[other_bid] = true
        end
        if _style_did_bounce(ev)
            _style_clear_ball_slide!(t, bid)
            if other_bid !== nothing
                _style_clear_ball_slide!(t, other_bid)
            end
        end

    elseif ev.type == "bucket_caught_ball"
        tab = _style_ensure_award_tab!(t, bid)
        if _style_truthy(get(t.bucket_bounced, bid, nothing)) &&
           _style_truthy(get(t.bounced_after_bucket, bid, nothing)) &&
           !_style_truthy(get(tab, "lucky", nothing))
            tab["lucky"] = true
            push_command!(commands, "award_style_points", Dict{String,Any}(
                "ball_id" => bid,
                "style" => "lucky_bounce",
                "points" => pt_lucky,
                "source_sequences" => Any[t.bucket_bounced[bid], ev.sequence],
            ))
        end

    elseif ev.type == "ball_contacted_peg"
        t.hit_any_peg[bid] = true
        if _style_truthy(get(t.bucket_bounced, bid, nothing))
            t.bounced_after_bucket[bid] = true
        end

        # Slide: zero-gap line contacts track per (ball, line). A bounced
        # contact clears the ball's runs; a scoring contact may seed a new
        # run (even from the bounce itself) or extend an adjacent
        # consistent-direction run.
        line = get(ev.fields, "line", nothing)
        if line isa AbstractDict && get(line, "gap", nothing) == 0
            scored = get(scored_by_source, ev.sequence, nothing)
            if _style_did_bounce(ev)
                _style_clear_ball_slide!(t, bid)
                if scored !== nothing && get(scored.fields, "line", nothing) isa AbstractDict
                    _style_note_slide_score!(t, ev, scored, commands, slide_min, pt_slide)
                end
            elseif scored !== nothing && get(scored.fields, "line", nothing) isa AbstractDict
                _style_note_slide_score!(t, ev, scored, commands, slide_min, pt_slide)
            end
        elseif _style_did_bounce(ev)
            # Bounce off a non-line peg ends any slide the ball had.
            _style_clear_ball_slide!(t, bid)
        end

        kind = get(ev.fields, "contact_kind", nothing)
        if kind == "sweep" || kind == "graze"
            scored = get(scored_by_source, ev.sequence, nothing)
            tab = _style_ensure_award_tab!(t, bid)
            ix = get(ev.fields, "impact_x", nothing)
            iy = get(ev.fields, "impact_y", nothing)

            if scored !== nothing && get(scored.fields, "peg_type", nothing) != "blue"
                # Chain-eligible scoring impact.
                # Off the Wall: non-blue peg scored after a side wall.
                wall_seq = get(t.side_wall_hit, bid, nothing)
                if _style_truthy(wall_seq) && !_style_truthy(get(tab, "off_wall", nothing))
                    tab["off_wall"] = true
                    push_command!(commands, "award_style_points", Dict{String,Any}(
                        "ball_id" => bid,
                        "style" => "off_the_wall",
                        "points" => pt_off_wall,
                        "peg_id" => scored.fields["peg_id"],
                        "source_sequences" => Any[wall_seq, ev.sequence],
                    ))
                    delete!(t.side_wall_hit, bid)   # consumed (awarded)
                end

                last = get(t.last_impact, bid, nothing)
                if last !== nothing
                    d = _style_dist(last["x"], last["y"], ix, iy)
                    segment_qualified = false
                    if d >= super_d
                        if !_style_truthy(get(tab, "super", nothing))
                            tab["super"] = true
                            push_command!(commands, "award_style_points", Dict{String,Any}(
                                "ball_id" => bid,
                                "style" => "super_long_shot",
                                "points" => pt_super,
                                "distance" => d,
                                "source_sequences" => Any[last["seq"], ev.sequence],
                            ))
                        end
                        segment_qualified = true
                    elseif d >= long_d
                        if !_style_truthy(get(tab, "long", nothing))
                            tab["long"] = true
                            push_command!(commands, "award_style_points", Dict{String,Any}(
                                "ball_id" => bid,
                                "style" => "long_shot",
                                "points" => pt_long,
                                "distance" => d,
                                "source_sequences" => Any[last["seq"], ev.sequence],
                            ))
                        end
                        segment_qualified = true
                    end

                    if segment_qualified
                        # Double: second consecutive qualifying segment. The
                        # sources are the contacts completing segment 1 and 2.
                        prev_qual_seq = get(t.last_qualifying_seq, bid, nothing)
                        streak = get(t.qualifying_streak, bid, nothing)
                        streak_new = (streak === nothing ? 0 : Int(streak)) + 1
                        t.qualifying_streak[bid] = streak_new
                        if streak_new >= 2 && !_style_truthy(get(tab, "double_long_shot", nothing))
                            tab["double_long_shot"] = true
                            push_command!(commands, "award_style_points", Dict{String,Any}(
                                "ball_id" => bid,
                                "style" => "double_long_shot",
                                "points" => pt_double,
                                "source_sequences" => Any[prev_qual_seq, ev.sequence],
                            ))
                        end
                        t.last_qualifying_seq[bid] = ev.sequence
                    else
                        # Short distance: streak broken (but the current special
                        # peg still becomes the base of the next segment below).
                        t.qualifying_streak[bid] = 0
                        delete!(t.last_qualifying_seq, bid)
                    end
                end
                # First chain impact sets the base; no streak increment yet.
                t.last_impact[bid] = Dict{String,Any}("x" => ix, "y" => iy, "seq" => ev.sequence)
            else
                # Breaks the chain: a blue peg (scored but blue) or an
                # already-hit peg (no peg_scored for this contact).
                t.qualifying_streak[bid] = 0
                delete!(t.last_impact, bid)
                delete!(t.last_qualifying_seq, bid)
                # Off the Wall: blue/already-hit consumes and fails the attempt.
                if _style_truthy(get(t.side_wall_hit, bid, nothing))
                    delete!(t.side_wall_hit, bid)
                end
            end
        end
    end
    return nothing
end

# Run style-shot recognition for one completed fixed step.
#
#   journal     = GameplayJournal (raw sealed; derived holds peg_scored)
#   commands    = GameplayCommands (receives award_style_points)
#   virtual_width = frozen interface argument; unused by the dev-tree Lua
#                   recognizer (kept for signature compatibility).
function style_shots_process!(
    t::StyleShotTrackers,
    journal::GameplayJournal,
    commands::GameplayCommands,
    virtual_width::Float64,
    c::SimConfig,
    scored_by_source::Dict{Int,GameEvent} = Dict{Int,GameEvent}(),
)::Nothing
    long_d = c.long_shot_distance
    super_d = c.super_long_shot_distance
    pt_long = c.long_shot_points
    pt_super = c.super_long_shot_points
    pt_double = c.double_long_shot_points
    pt_lucky = c.lucky_bounce_points
    pt_off_wall = c.off_the_wall_points
    slide_min = c.slide_min_pegs
    pt_slide = c.slide_points

    # Index peg_scored derived events by their source raw sequence.
    empty!(scored_by_source)
    for ev in journal.derived
        if ev.type == "peg_scored"
            src = get(ev.fields, "source_sequence", nothing)
            src !== nothing && (scored_by_source[Int(src)] = ev)
        end
    end

    # Events:all() = raw first, then derived (borrowed journal order).
    for ev in journal.raw
        _style_process_event!(
            t, ev, scored_by_source, commands,
            pt_lucky, pt_off_wall, pt_long, pt_super, pt_double,
            long_d, super_d, slide_min, pt_slide)
    end
    for ev in journal.derived
        _style_process_event!(
            t, ev, scored_by_source, commands,
            pt_lucky, pt_off_wall, pt_long, pt_super, pt_double,
            long_d, super_d, slide_min, pt_slide)
    end
    return nothing
end
