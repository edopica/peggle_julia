# ===========================================================================
# Physics: the whole `Physics.update` port (swept CCD, all peg shapes,
# ball-ball, graze, depenetration).
#
# Authoritative source: ../peggle_evolved/src/systems/physics.lua at da75225
# (the dev tree). The vendored pinned file reference/peggle_evolved/... is
# semantically identical modulo the `physics_ctx` refactor and the DetMath
# routing, both of which are ported here.
#
# Porting rules applied:
#   * every transcendental goes through DetMath (det_sin, det_cos, det_atan2,
#     det_sqrt, lua_mod); LuaJIT `x ^ 2` -> `x * x`, `x ^ 0.5` -> det_sqrt.
#   * expression order and grouping are preserved verbatim.
#   * the Lua file-level `physics_ctx` and `grazed_pool`/`grazed_n` become a
#     engine-owned `PhysicsContext` so parallel workers share no state.
#   * presentation-only systems (ImpactDebug, ContactEvents, Perf, and
#     `ball.draw_path`) are not ported; the event sink is the gameplay
#     journal (`emit_raw!`).
# ===========================================================================

# PRIORITY table (physics.lua lines 10-17).
const PRIORITY = (
    wall = 1,
    circle_peg = 2,
    ball = 2,
    rect_peg = 3,
    annular_peg = 4,
    extra_circle = 5,
)

# ---------------------------------------------------------------------------
# Shape access
# ---------------------------------------------------------------------------

@inline peg_shape_name(::CircleShape)::String = "circle"
@inline peg_shape_name(::RectangleShape)::String = "rectangle"
@inline peg_shape_name(::AnnularShape)::String = "annular"

# Lua reads a peg's shape-specific fields off the flat table; the Julia Peg
# keeps them on the shape object. `peg.shape or "circle"` is a nil check that
# cannot fire for the typed union (all pegs carry a shape), so `peg_shape_name`
# handles the mapping directly.
@inline circle_shape(peg::Peg)::CircleShape = peg.shape
@inline rect_shape(peg::Peg)::RectangleShape = peg.shape
@inline annular_shape(peg::Peg)::AnnularShape = peg.shape

# `circ.radius`: circle pegs keep it on CircleShape, fever dividers directly.
@inline circ_radius(circ::Peg)::Float64 = circle_shape(circ).radius
@inline circ_radius(circ::FeverDivider)::Float64 = circ.radius

# ---------------------------------------------------------------------------
# Event payload helpers (physics.lua lines 19-90)
# ---------------------------------------------------------------------------

# Copy the authoring line metadata of a peg onto an event payload (plain
# scalars only; the metadata contract is enumerable by design). Returns
# `nothing` when the peg has no line, mirroring Lua `contact_line` returning
# nil; the caller must then omit the `line` key (Lua assigns nil, which drops
# the key from the payload table).
function contact_line(peg::Peg)
    line = peg.line
    line === nothing && return nothing
    return ContactLine(line)
end

# Line metadata projections. These avoid constructing a `ContactLine` (a
# non-isbits object) merely to copy it into an EventFields union slot; each
# returns a scalar or an existing string reference.
@inline _line_id(::Nothing) = nothing
@inline _line_id(l::LineMetadata) = l.id
@inline _line_index(::Nothing) = nothing
@inline _line_index(l::LineMetadata) = l.index
@inline _line_count(::Nothing) = nothing
@inline _line_count(l::LineMetadata) = l.count
@inline _line_closed(::Nothing) = nothing
@inline _line_closed(l::LineMetadata) = l.closed
@inline _line_gap(::Nothing) = nothing
@inline _line_gap(l::LineMetadata) = l.gap

# Objective collision fact carried to `emit_contact!`. The Lua record is a
# plain table with these fields; `other_ball` is nil for non-ball contacts and
# `other_vout_x`/`other_vout_y` are nil only for the end-of-step ball
# depenetration record (where Lua nil-assignment drops the payload keys).
struct ContactRecord
    isx::Float64
    isy::Float64
    move_x::Float64
    move_y::Float64
    window::Float64
    total_dt::Float64
    toi::Float64
    iter::Int
    nx::Float64
    ny::Float64
    vin_x::Float64
    vin_y::Float64
    vout_x::Float64
    vout_y::Float64
    other_ball::Union{Nothing,BallState}
    other_vout_x::Union{Nothing,Float64}
    other_vout_y::Union{Nothing,Float64}
end

# Build and emit a raw contact event to the gameplay journal. Physics is
# purely observational here: it reports objective collision facts and never
# mutates peg.hit or any authoritative gameplay state. The journal records the
# event for later authoritative reduction.
#
# Lua's `if not event_sink then return end` guard is unnecessary: the frozen
# M3 signature always supplies the journal.
function emit_contact!(journal::GameplayJournal, event_type::AbstractString,
                       ball::BallState, rec::ContactRecord, did_bounce::Bool,
                       peg::Union{Nothing,Peg,FeverDivider},
                       contact_kind::AbstractString)::Nothing
    ix = rec.isx + rec.move_x * rec.toi
    iy = rec.isy + rec.move_y * rec.toi
    frame_t = ((rec.total_dt - rec.window) + rec.toi * rec.window) / rec.total_dt
    px = py = pa = ptheta = nothing
    peg_id = nothing
    peg_type = nothing
    peg_shape = nothing
    local_wall = nothing
    pline = nothing
    if peg isa Peg
        px, py, pa, ptheta = peg_transform_at_toi(peg, rec.window, rec.toi)
        peg_id = peg.id
        peg_type = peg_type_name(peg.peg_type)
        peg_shape = peg_shape_name(peg.shape)
        pline = peg.line
    elseif peg isa FeverDivider
        # Lua's emit_contact receives the divider table through its `if peg`
        # branch: `peg.shape or "circle"` -> "circle", the transform is the raw
        # static x/y with angle 0, and there is no id/type/line to emit.
        px, py, pa = peg.x, peg.y, 0.0
        peg_shape = "circle"
    elseif event_type == "ball_contact_wall"
        # Derive wall identity deterministically from the contact normal.
        # left wall  -> normal (+1, 0)
        # right wall -> normal (-1, 0)
        # ceiling    -> normal (0, +1)
        local_wall = rec.nx > 0 ? "left" : (rec.nx < 0 ? "right" : "top")
    end
    fields = EventFields(
        ball_id = ball.id, contact_kind = String(contact_kind),
        did_bounce = did_bounce, impact_x = ix, impact_y = iy,
        frame_t = frame_t, toi = rec.toi, iteration = rec.iter,
        normal_x = rec.nx, normal_y = rec.ny,
        incoming_vx = rec.vin_x, incoming_vy = rec.vin_y,
        outgoing_vx = rec.vout_x, outgoing_vy = rec.vout_y,
        other_ball_id = rec.other_ball === nothing ? nothing : rec.other_ball.id,
        other_outgoing_vx = rec.other_ball === nothing ? nothing : rec.other_vout_x,
        other_outgoing_vy = rec.other_ball === nothing ? nothing : rec.other_vout_y,
        peg_id = peg_id,
        peg_type = peg_type,
        peg_shape = peg_shape,
        line_meta_id = _line_id(pline), line_meta_index = _line_index(pline),
        line_meta_count = _line_count(pline), line_meta_closed = _line_closed(pline),
        line_meta_gap = _line_gap(pline),
        peg_x = px, peg_y = py, peg_angle = pa, peg_theta = ptheta,
        wall = local_wall,
    )
    emit_raw!(journal, event_type, fields)
    return nothing
end

# ---------------------------------------------------------------------------
# Reusable physics state (physics.lua lines 92-115)
# ---------------------------------------------------------------------------

# One persistent-slot graze entry; `t` is the iteration-window toi.
struct GrazedPeg
    peg::Peg
    t::Float64
end

# Per-frame ball bookkeeping for ball-ball collision reconstruction.
mutable struct BallFrameState
    done::Bool
    vend_x::Float64
    vend_y::Float64
end

# Immutable, worker-local invariants for one CCD movement window. Keep the
# reference subtraction even for zero velocity: signed zeros are observable.
struct StaticCollisionQuery
    rel_move_x::Float64
    rel_move_y::Float64
    rel_move_len::Float64
end

# The Lua file-level `physics_ctx` plus engine-local frame and graze pools.
mutable struct PhysicsContext
    balls::Vector{BallState}
    ball_frame::Dict{BallState,BallFrameState}
    journal::GameplayJournal
    config::SimConfig
    virtual_width::Float64
    ball::Union{Nothing,BallState}
    total_dt::Float64
    move_x::Float64
    move_y::Float64
    time_remaining::Float64
    min_t::Float64
    hit_nx::Float64
    hit_ny::Float64
    hit_type::Union{Nothing,String}
    # Lua's hit_peg holds the divider table for extra-circle contacts too:
    # `is_extra and nil or circ` evaluates to `circ` in Lua (the and/or idiom
    # cannot yield nil). See check_circles.
    hit_peg::Union{Nothing,Peg,FeverDivider}
    hit_other_ball::Union{Nothing,BallState}
    hit_priority::Union{Nothing,Int}
    hit_peg_index::Union{Nothing,Int}
    hit_overlap::Float64
    grazed::Vector{GrazedPeg}
    frame_pool::Vector{BallFrameState}
    static_query::StaticCollisionQuery
end

function PhysicsContext(balls::Vector{BallState}, config::SimConfig,
                        virtual_width::Float64, journal::GameplayJournal)::PhysicsContext
    return PhysicsContext(
        balls, Dict{BallState,BallFrameState}(), journal, config, virtual_width,
        nothing, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
        nothing, nothing, nothing, nothing, nothing, 0.0, GrazedPeg[], BallFrameState[],
        StaticCollisionQuery(0.0, 0.0, 0.0))
end

# Release borrowed entity references without discarding reusable capacity.
function reset_physics_context!(ctx::PhysicsContext, balls::Vector{BallState},
                                config::SimConfig, virtual_width::Float64,
                                journal::GameplayJournal)::Nothing
    ctx.balls = balls
    ctx.config = config
    ctx.virtual_width = virtual_width
    ctx.journal = journal
    empty!(ctx.ball_frame)
    empty!(ctx.grazed)
    ctx.ball = nothing
    ctx.total_dt = ctx.move_x = ctx.move_y = ctx.time_remaining = 0.0
    ctx.static_query = StaticCollisionQuery(0.0, 0.0, 0.0)
    ctx.min_t = 1.0
    ctx.hit_nx = ctx.hit_ny = ctx.hit_overlap = 0.0
    ctx.hit_type = nothing
    ctx.hit_peg = nothing
    ctx.hit_other_ball = nothing
    ctx.hit_priority = nothing
    ctx.hit_peg_index = nothing
    return nothing
end

# Persistent graze buffer (physics.lua lines 92-108). The Lua pool is indexed
# by `grazed_n` and reset before each sweep window; the vector `empty!` reset
# preserves the "entries from a previous window are never read" contract.
function grazed_add!(ctx::PhysicsContext, peg::Peg, t::Float64)::Nothing
    push!(ctx.grazed, GrazedPeg(peg, t))
    return nothing
end

# physics.lua lines 117-144.
function register_hit!(ctx::PhysicsContext, t::Float64, nx::Float64, ny::Float64,
                       htype::String, peg::Union{Nothing,Peg,FeverDivider},
                       priority::Int, peg_index::Union{Nothing,Int},
                       overlap::Float64,
                       other_ball::Union{Nothing,BallState} = nothing)::Bool
    if t < ctx.min_t - ctx.config.toi_epsilon
        ctx.min_t = t
        ctx.hit_nx, ctx.hit_ny = nx, ny
        ctx.hit_type = htype
        ctx.hit_peg = peg
        ctx.hit_other_ball = other_ball
        ctx.hit_priority = priority
        ctx.hit_peg_index = peg_index
        ctx.hit_overlap = overlap
        return true
    elseif abs(t - ctx.min_t) <= ctx.config.toi_epsilon
        hit_priority = ctx.hit_priority
        hit_peg_index = ctx.hit_peg_index
        if hit_priority === nothing || priority < hit_priority ||
           (priority == hit_priority &&
            (peg_index === nothing ? 0 : peg_index) <
            (hit_peg_index === nothing ? 0 : hit_peg_index))
            ctx.min_t = t
            ctx.hit_nx, ctx.hit_ny = nx, ny
            ctx.hit_type = htype
            ctx.hit_peg = peg
            ctx.hit_other_ball = other_ball
            ctx.hit_priority = priority
            ctx.hit_peg_index = peg_index
            ctx.hit_overlap = overlap
            return true
        end
    end
    return false
end

# ---------------------------------------------------------------------------
# Annular sweep slice helpers (physics.lua lines 146-261)
# ---------------------------------------------------------------------------

function annular_is_inside_arc(cx_rel::Float64, cy_rel::Float64, t_start::Float64,
                               t_end::Float64)::Bool
    hit_angle = DetMath.det_atan2(cy_rel, cx_rel)
    normalized = DetMath.lua_mod(hit_angle - t_start, pi * 2)
    # Small epsilon to account for floating point errors at boundaries
    return normalized <= (t_end - t_start + 0.001) ||
           normalized >= (pi * 2 - 0.001)
end

function annular_check_cap(ctx::PhysicsContext, peg::Peg, ball::BallState,
                           peg_index::Int, t_offset::Float64, t_scale::Float64,
                           px::Float64, py::Float64, bx::Float64, by::Float64,
                           dx::Float64, dy::Float64, slice_move_x::Float64,
                           slice_move_y::Float64, normal_x::Float64,
                           normal_y::Float64, angle::Float64)::Nothing
    shape = annular_shape(peg)
    denom = slice_move_x * normal_x + slice_move_y * normal_y
    if denom < -0.0001
        cap_px = px + shape.r_in * DetMath.det_cos(angle)
        cap_py = py + shape.r_in * DetMath.det_sin(angle)
        d0 = (bx - cap_px) * normal_x + (by - cap_py) * normal_y
        t = (ball.radius - d0) / denom
        hit_physically = false

        if t >= -0.001 && t <= 1.0
            t_hit = max(0.0, t)
            cx_rel = dx + slice_move_x * t_hit
            cy_rel = dy + slice_move_y * t_hit
            px_rel = cx_rel - normal_x * ball.radius
            py_rel = cy_rel - normal_y * ball.radius

            cap_dir_x = DetMath.det_cos(angle)
            cap_dir_y = DetMath.det_sin(angle)
            dot = px_rel * cap_dir_x + py_rel * cap_dir_y

            dist2 = px_rel * px_rel + py_rel * py_rel
            if dot >= 0 &&
               dist2 >= (shape.r_in * shape.r_in - ctx.config.annular_cap_epsilon) &&
               dist2 <= (shape.r_out * shape.r_out + ctx.config.annular_cap_epsilon)
                register_hit!(ctx, t_offset + t_hit * t_scale, normal_x, normal_y,
                              "peg", peg, PRIORITY.annular_peg, peg_index, 0.0)
                hit_physically = true
            end
        end

        if !hit_physically
            p = ctx.config.graze_tolerance
            t_graze = (ball.radius + p - d0) / denom
            if t_graze >= -0.001 && t_graze <= 1.0
                t_hit = max(0.0, t_graze)
                cx_rel = dx + slice_move_x * t_hit
                cy_rel = dy + slice_move_y * t_hit
                px_rel = cx_rel - normal_x * (ball.radius + p)
                py_rel = cy_rel - normal_y * (ball.radius + p)

                cap_dir_x = DetMath.det_cos(angle)
                cap_dir_y = DetMath.det_sin(angle)
                dot = px_rel * cap_dir_x + py_rel * cap_dir_y

                dist2 = px_rel * px_rel + py_rel * py_rel
                if dot >= 0 &&
                   dist2 >= (shape.r_in * shape.r_in - ctx.config.annular_cap_epsilon) &&
                   dist2 <= (shape.r_out * shape.r_out + ctx.config.annular_cap_epsilon)
                    # Lua guards with `peg.hit ~= nil`, always true for a real
                    # peg (Peg.new sets hit=false); the guard only excludes
                    # FeverDividers, which never reach this function.
                    grazed_add!(ctx, peg, t_offset + t_graze * t_scale)
                end
            end
        end
    end
    return nothing
end

function annular_check_corner(ctx::PhysicsContext, peg::Peg, ball::BallState,
                              peg_index::Int, t_offset::Float64, t_scale::Float64,
                              px::Float64, py::Float64, bx::Float64, by::Float64,
                              dx::Float64, dy::Float64, slice_move_x::Float64,
                              slice_move_y::Float64, a::Float64, corner_r::Float64,
                              corner_theta::Float64)::Nothing
    iter_corner_x = px + corner_r * DetMath.det_cos(corner_theta)
    iter_corner_y = py + corner_r * DetMath.det_sin(corner_theta)

    cdx = bx - iter_corner_x
    cdy = by - iter_corner_y
    cb = 2 * (cdx * slice_move_x + cdy * slice_move_y)
    cc = (cdx * cdx + cdy * cdy) - (ball.radius * ball.radius)

    if a > 0.0001
        disc = cb * cb - 4 * a * cc

        p = ctx.config.graze_tolerance
        allowed_disc = -(p * 2 * ball.radius + p * p) * 4 * a

        if disc >= allowed_disc
            root = DetMath.det_sqrt(max(0.0, disc))
            t1 = (-cb - root) / (2 * a)
            if t1 >= -0.001 && t1 <= 1.0
                if disc < 0
                    # `peg.hit ~= nil` is always true for real pegs.
                    grazed_add!(ctx, peg, t_offset + t1 * t_scale)
                else
                    cx_rel = cdx + slice_move_x * t1
                    cy_rel = cdy + slice_move_y * t1
                    dist = DetMath.det_sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
                    if dist == 0
                        dist = 0.01
                    end

                    t1 = max(0.0, t1)
                    n_x, n_y = 0.0, -1.0
                    if dist > 1e-8
                        n_x = cx_rel / dist
                        n_y = cy_rel / dist
                    end
                    register_hit!(ctx, t_offset + t1 * t_scale, n_x, n_y, "peg", peg,
                                  PRIORITY.annular_peg, peg_index, 0.0)
                end
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Broad phase and circle sweep (physics.lua lines 263-361)
# ---------------------------------------------------------------------------

# Rebuilt after every change to the ball movement or remaining time. The +0
# velocity path also applies to fever dividers; moving and -0 velocities keep
# the original per-object expression below.
@inline function prepare_static_query!(ctx::PhysicsContext)::Nothing
    rel_move_x = ctx.move_x - 0.0 * ctx.time_remaining
    rel_move_y = ctx.move_y - 0.0 * ctx.time_remaining
    rel_move_len = DetMath.det_sqrt(rel_move_x * rel_move_x + rel_move_y * rel_move_y)
    ctx.static_query = StaticCollisionQuery(rel_move_x, rel_move_y, rel_move_len)
    return nothing
end

# Shared broad-phase tail: derives the iteration-window-start transforms and
# rejects when the moving-circle reach cannot touch the ball.
function broad_phase_common(ctx::PhysicsContext, px::Float64, py::Float64,
                            peg_vx::Float64, peg_vy::Float64, br::Float64)
    ball = ctx.ball::BallState
    move_x = ctx.move_x
    move_y = ctx.move_y
    time_remaining = ctx.time_remaining

    peg_iter_x = px - peg_vx * time_remaining
    peg_iter_y = py - peg_vy * time_remaining

    if isequal(peg_vx, 0.0) && isequal(peg_vy, 0.0)
        query = ctx.static_query
        rel_move_x = query.rel_move_x
        rel_move_y = query.rel_move_y
        rel_move_len = query.rel_move_len
    else
        rel_move_x = move_x - peg_vx * time_remaining
        rel_move_y = move_y - peg_vy * time_remaining
        rel_move_len = DetMath.det_sqrt(rel_move_x * rel_move_x + rel_move_y * rel_move_y)
    end

    dx = ball.x - peg_iter_x
    dy = ball.y - peg_iter_y

    reach = ball.radius + br + rel_move_len

    if dx * dx + dy * dy > reach * reach
        return nothing
    end
    return (dx = dx, dy = dy, rel_move_x = rel_move_x, rel_move_y = rel_move_y,
            peg_iter_x = peg_iter_x, peg_iter_y = peg_iter_y)
end

# Constructor-prepared geometry survives reset through the immutable shape.
# Retain lazy fallback for callers that explicitly invalidate the peg cache.
@inline function prepared_bounding_radius(peg::Peg)::Float64
    br = peg.bounding_radius
    if br === nothing
        br = peg_bounding_radius(peg.shape)
        peg.bounding_radius = br
    end
    return br
end

function broad_phase_pass(ctx::PhysicsContext, peg::Peg)
    return broad_phase_common(ctx, peg.x, peg.y, peg.vx, peg.vy,
                              prepared_bounding_radius(peg))
end

# Fever-divider extras: no `shape` so Lua treats it as a circle with the raw
# radius; the divider struct has no bounding_radius cache, so the radius is
# used directly. Lua `peg.vx or 0` -> the divider has no velocity fields.
function broad_phase_pass(ctx::PhysicsContext, div::FeverDivider)
    return broad_phase_common(ctx, div.x, div.y, 0.0, 0.0, div.radius)
end

@inline function broad_phase_pass(ctx::PhysicsContext, geometry::CompactPegGeometry)
    return broad_phase_common(ctx, geometry.x, geometry.y, geometry.vx,
                              geometry.vy, geometry.bounding_radius)
end

# Refresh once per frame, rather than per CCD window. This also keeps direct
# callers' changes to transforms, velocities and shape/radius caches visible.
function refresh_geometry!(records::Vector{CompactPegGeometry{S}}, pegs::Vector{Peg}) where {S}
    resize!(records, length(pegs))
    for i in eachindex(pegs)
        p = pegs[i]
        records[i] = CompactPegGeometry(p.x, p.y, p.vx, p.vy,
                                       prepared_bounding_radius(p), p.shape::S)
    end
    return nothing
end

@inline scan_geometry(pegs, ::Nothing, i) = pegs[i]
@inline scan_geometry(pegs, geometry::Vector, i) = geometry[i]

# 2. Check Pegs and Extra Circles (Swept Circle-Circle)
#
# Lua passes `is_extra and nil or circ` as the hit peg. That and/or idiom
# yields `circ` even when is_extra is true, so extra-circle (fever divider)
# contacts carry the divider into emit_contact: shape defaults to "circle",
# the transform is static, and there is no id/type/line. The port must use the
# value Lua actually passes, not the apparent intent of the expression.
function check_circles(ctx::PhysicsContext,
                       circles::Union{Nothing,Vector{Peg},Vector{FeverDivider}},
                       is_extra::Bool, geometry = nothing)::Nothing
    ball = ctx.ball::BallState
    if circles === nothing
        return
    end
    for i in eachindex(circles)
        bp = broad_phase_pass(ctx, scan_geometry(circles, geometry, i))
        if bp !== nothing
            circ = circles[i]
            dx = bp.dx
            dy = bp.dy
            rel_move_x = bp.rel_move_x
            rel_move_y = bp.rel_move_y
            a = rel_move_x * rel_move_x + rel_move_y * rel_move_y
            b = 2 * (dx * rel_move_x + dy * rel_move_y)
            radius_sum = ball.radius + circ_radius(circ)
            cc = (dx * dx + dy * dy) - (radius_sum * radius_sum)

            if cc < 0
                # Already intersecting (Discrete pop-out to prevent getting stuck)
                dist = DetMath.det_sqrt(dx * dx + dy * dy)
                if dist == 0
                    dist = 0.01
                end
                register_hit!(ctx, 0.0, dx / dist, dy / dist,
                              is_extra ? "extra" : "peg",
                              circ,
                              is_extra ? PRIORITY.extra_circle : PRIORITY.circle_peg,
                              i, radius_sum - dist)
            elseif a > 0.0001
                # Calculate Time of Impact (TOI) using quadratic formula
                disc = b * b - 4 * a * cc

                # Allow a tiny miss distance to count as a hit (for grazes where
                # pixels visually touch)
                p = ctx.config.graze_tolerance
                allowed_disc = -(p * 2 * radius_sum + p * p) * 4 * a

                if disc >= allowed_disc
                    root = DetMath.det_sqrt(max(0.0, disc))
                    t1 = (-b - root) / (2 * a)

                    if t1 >= -0.001 && t1 <= 1.0
                        cx_rel = dx + rel_move_x * t1
                        cy_rel = dy + rel_move_y * t1
                        dist = DetMath.det_sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
                        if dist == 0
                            dist = 0.01
                        end

                        if disc < 0
                            # This collision was only detected because
                            # graze_tolerance expanded the discriminant window.
                            # Light up the peg but do NOT deflect. Lua also
                            # checks `circ.hit ~= nil` (always true for a peg)
                            # and excludes extras, which have no hit field.
                            if !is_extra
                                grazed_add!(ctx, circ, t1)
                            end
                        else
                            t1 = max(0.0, t1)
                            register_hit!(ctx, t1, cx_rel / dist, cy_rel / dist,
                                          is_extra ? "extra" : "peg",
                                          circ,
                                          is_extra ? PRIORITY.extra_circle : PRIORITY.circle_peg,
                                          i, 0.0)
                        end
                    end
                end
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Rotating pegs: rectangle and annular sweep slices (physics.lua lines 363-618)
# ---------------------------------------------------------------------------

# Rotating pegs (rectangles and annulars): the renderer interpolates the peg
# angle across the frame, but a swept check can only freeze the angle at one
# instant. To keep the swept geometry within a pixel of the drawn geometry,
# the frame window is split into time slices such that the surface arc
# travelled per slice (|va| * slice_time * bounding_radius) stays below
# Config.rotation_sweep_arc_px. Each slice runs the frozen-angle sweep and
# reports times in the iteration-wide [0, 1] window. Deterministic: the slice
# count derives only from peg velocities and config constants.
function rotation_slices(ctx::PhysicsContext, peg::Peg, peg_va::Float64)::Int
    time_remaining = ctx.time_remaining
    if peg_va == 0
        return 1
    end
    arc = abs(peg_va) * time_remaining * peg.bounding_radius::Float64
    slices_f = ceil(arc / ctx.config.rotation_sweep_arc_px)
    max_slices = ctx.config.rotation_sweep_max_slices
    if slices_f > max_slices
        return max_slices
    elseif slices_f < 1
        return 1
    end
    return Int(slices_f)
end

function check_corner(ctx::PhysicsContext, peg::Peg, peg_index::Int,
                      cos_a::Float64, sin_a::Float64, t_offset::Float64,
                      t_scale::Float64, r::Float64, p::Float64,
                      local_ball_x::Float64, local_ball_y::Float64,
                      local_move_x::Float64, local_move_y::Float64,
                      corner_x::Float64, corner_y::Float64)::Nothing
    cdx = local_ball_x - corner_x
    cdy = local_ball_y - corner_y
    a = local_move_x * local_move_x + local_move_y * local_move_y
    b = 2 * (cdx * local_move_x + cdy * local_move_y)
    cc = (cdx * cdx + cdy * cdy) - (r * r)

    if a > 0.0001
        disc = b * b - 4 * a * cc

        allowed_disc = -(p * 2 * r + p * p) * 4 * a

        if disc >= allowed_disc
            root = DetMath.det_sqrt(max(0.0, disc))
            t1 = (-b - root) / (2 * a)
            if t1 >= -0.001 && t1 <= 1.0
                if disc < 0
                    # `peg.hit ~= nil` is always true for real pegs.
                    grazed_add!(ctx, peg, t_offset + t1 * t_scale)
                else
                    cx_pos = local_ball_x + local_move_x * t1
                    cy_pos = local_ball_y + local_move_y * t1
                    dist = DetMath.det_sqrt((cx_pos - corner_x) * (cx_pos - corner_x) +
                                            (cy_pos - corner_y) * (cy_pos - corner_y))
                    if dist == 0
                        dist = 0.01
                    end

                    t1 = max(0.0, t1)
                    local_nx = 0.0
                    local_ny = -1.0
                    if dist > 1e-8
                        local_nx = (cx_pos - corner_x) / dist
                        local_ny = (cy_pos - corner_y) / dist
                    end
                    register_hit!(ctx, t_offset + t1 * t_scale,
                                  local_nx * cos_a - local_ny * sin_a,
                                  local_nx * sin_a + local_ny * cos_a,
                                  "peg", peg, PRIORITY.rect_peg, peg_index, 0.0)
                end
            end
        end
    end
    return nothing
end

function sweep_slice(ctx::PhysicsContext, peg::Peg, peg_index::Int, slices::Int,
                     angle_iter::Float64, peg_vx::Float64, peg_vy::Float64,
                     peg_va::Float64, peg_iter_x::Float64, peg_iter_y::Float64,
                     rel_move_x::Float64, rel_move_y::Float64, rx::Float64,
                     ry::Float64, rw::Float64, rh::Float64, r::Float64,
                     p::Float64, s::Int)::Bool
    ball = ctx.ball::BallState
    move_x = ctx.move_x
    move_y = ctx.move_y
    time_remaining = ctx.time_remaining
    t_offset = s / slices
    if t_offset > ctx.min_t + ctx.config.toi_epsilon
        return false
    end
    t_scale = 1 / slices

    # Positions at slice start (rotation frozen for the slice duration)
    bx = ball.x + move_x * t_offset
    by = ball.y + move_y * t_offset
    px = peg_iter_x + peg_vx * time_remaining * t_offset
    py = peg_iter_y + peg_vy * time_remaining * t_offset
    dx = bx - px
    dy = by - py
    slice_move_x = rel_move_x * t_scale
    slice_move_y = rel_move_y * t_scale

    angle = angle_iter + peg_va * time_remaining * t_offset
    cos_a = DetMath.det_cos(angle)
    sin_a = DetMath.det_sin(angle)

    # Transform ball's position relative to peg center into local space
    local_ball_x = dx * cos_a + dy * sin_a
    local_ball_y = -dx * sin_a + dy * cos_a

    # Transform relative movement vector into local space
    local_move_x = slice_move_x * cos_a + slice_move_y * sin_a
    local_move_y = -slice_move_x * sin_a + slice_move_y * cos_a

    # 1. Check if already overlapping (discrete check)
    cx = max(rx, min(local_ball_x, rx + rw))
    cy = max(ry, min(local_ball_y, ry + rh))
    l_dx = local_ball_x - cx
    l_dy = local_ball_y - cy
    d2 = l_dx * l_dx + l_dy * l_dy

    if d2 < r * r
        local_nx = 0.0
        local_ny = 0.0
        overlap = 0.0
        if d2 > 1e-8
            dist = DetMath.det_sqrt(d2)
            local_nx = l_dx / dist
            local_ny = l_dy / dist
            overlap = r - dist
        else
            # Ball center inside rectangle, eject along shallowest axis
            toLeft = local_ball_x - rx
            toRight = (rx + rw) - local_ball_x
            toTop = local_ball_y - ry
            toBottom = (ry + rh) - local_ball_y
            m = min(toLeft, toRight, toTop, toBottom)
            if m == toLeft
                local_nx, local_ny = -1.0, 0.0
                overlap = r - toLeft
            elseif m == toRight
                local_nx, local_ny = 1.0, 0.0
                overlap = r - toRight
            elseif m == toTop
                local_nx, local_ny = 0.0, -1.0
                overlap = r - toTop
            else
                local_nx, local_ny = 0.0, 1.0
                overlap = r - toBottom
            end
        end
        # Rotate normal back to world space
        wrld_nx = local_nx * cos_a - local_ny * sin_a
        wrld_ny = local_nx * sin_a + local_ny * cos_a
        register_hit!(ctx, t_offset, wrld_nx, wrld_ny, "peg", peg,
                      PRIORITY.rect_peg, peg_index, overlap)
    else
        if d2 < (r + p) * (r + p)
            # `peg.hit ~= nil` is always true for real pegs.
            grazed_add!(ctx, peg, t_offset)
        end

        # 2. Swept check: check the 4 sides of the expanded box in local space
        # Left segment: x = rx - r, y in [ry, ry + rh]
        if local_move_x > 0
            hit_physically = false
            t = (rx - r - local_ball_x) / local_move_x
            if t >= 0 && t <= 1.0
                iy = local_ball_y + local_move_y * t
                if iy >= ry && iy <= ry + rh
                    local_nx, local_ny = -1.0, 0.0
                    register_hit!(ctx, t_offset + t * t_scale,
                                  local_nx * cos_a - local_ny * sin_a,
                                  local_nx * sin_a + local_ny * cos_a,
                                  "peg", peg, PRIORITY.rect_peg, peg_index, 0.0)
                    hit_physically = true
                end
            end
            if !hit_physically
                t_graze = (rx - r - p - local_ball_x) / local_move_x
                if t_graze >= 0 && t_graze <= 1.0
                    iy_graze = local_ball_y + local_move_y * t_graze
                    if iy_graze >= ry && iy_graze <= ry + rh
                        # `peg.hit ~= nil` is always true for real pegs.
                        grazed_add!(ctx, peg, t_offset + t_graze * t_scale)
                    end
                end
            end
        end

        # Right segment: x = rx + rw + r, y in [ry, ry + rh]
        if local_move_x < 0
            hit_physically = false
            t = (rx + rw + r - local_ball_x) / local_move_x
            if t >= 0 && t <= 1.0
                iy = local_ball_y + local_move_y * t
                if iy >= ry && iy <= ry + rh
                    local_nx, local_ny = 1.0, 0.0
                    register_hit!(ctx, t_offset + t * t_scale,
                                  local_nx * cos_a - local_ny * sin_a,
                                  local_nx * sin_a + local_ny * cos_a,
                                  "peg", peg, PRIORITY.rect_peg, peg_index, 0.0)
                    hit_physically = true
                end
            end
            if !hit_physically
                t_graze = (rx + rw + r + p - local_ball_x) / local_move_x
                if t_graze >= 0 && t_graze <= 1.0
                    iy_graze = local_ball_y + local_move_y * t_graze
                    if iy_graze >= ry && iy_graze <= ry + rh
                        # `peg.hit ~= nil` is always true for real pegs.
                        grazed_add!(ctx, peg, t_offset + t_graze * t_scale)
                    end
                end
            end
        end

        # Top segment: y = ry - r, x in [rx, rx + rw]
        if local_move_y > 0
            hit_physically = false
            t = (ry - r - local_ball_y) / local_move_y
            if t >= 0 && t <= 1.0
                ix = local_ball_x + local_move_x * t
                if ix >= rx && ix <= rx + rw
                    local_nx, local_ny = 0.0, -1.0
                    register_hit!(ctx, t_offset + t * t_scale,
                                  local_nx * cos_a - local_ny * sin_a,
                                  local_nx * sin_a + local_ny * cos_a,
                                  "peg", peg, PRIORITY.rect_peg, peg_index, 0.0)
                    hit_physically = true
                end
            end
            if !hit_physically
                t_graze = (ry - r - p - local_ball_y) / local_move_y
                if t_graze >= 0 && t_graze <= 1.0
                    ix_graze = local_ball_x + local_move_x * t_graze
                    if ix_graze >= rx && ix_graze <= rx + rw
                        # `peg.hit ~= nil` is always true for real pegs.
                        grazed_add!(ctx, peg, t_offset + t_graze * t_scale)
                    end
                end
            end
        end

        # Bottom segment: y = ry + rh + r, x in [rx, rx + rw]
        if local_move_y < 0
            hit_physically = false
            t = (ry + rh + r - local_ball_y) / local_move_y
            if t >= 0 && t <= 1.0
                ix = local_ball_x + local_move_x * t
                if ix >= rx && ix <= rx + rw
                    local_nx, local_ny = 0.0, 1.0
                    register_hit!(ctx, t_offset + t * t_scale,
                                  local_nx * cos_a - local_ny * sin_a,
                                  local_nx * sin_a + local_ny * cos_a,
                                  "peg", peg, PRIORITY.rect_peg, peg_index, 0.0)
                    hit_physically = true
                end
            end
            if !hit_physically
                t_graze = (ry + rh + r + p - local_ball_y) / local_move_y
                if t_graze >= 0 && t_graze <= 1.0
                    ix_graze = local_ball_x + local_move_x * t_graze
                    if ix_graze >= rx && ix_graze <= rx + rw
                        # `peg.hit ~= nil` is always true for real pegs.
                        grazed_add!(ctx, peg, t_offset + t_graze * t_scale)
                    end
                end
            end
        end

        # Check the 4 corner circles of radius r in local space
        check_corner(ctx, peg, peg_index, cos_a, sin_a, t_offset, t_scale, r, p,
                     local_ball_x, local_ball_y, local_move_x, local_move_y, rx, ry)
        check_corner(ctx, peg, peg_index, cos_a, sin_a, t_offset, t_scale, r, p,
                     local_ball_x, local_ball_y, local_move_x, local_move_y, rx + rw, ry)
        check_corner(ctx, peg, peg_index, cos_a, sin_a, t_offset, t_scale, r, p,
                     local_ball_x, local_ball_y, local_move_x, local_move_y, rx, ry + rh)
        check_corner(ctx, peg, peg_index, cos_a, sin_a, t_offset, t_scale, r, p,
                     local_ball_x, local_ball_y, local_move_x, local_move_y,
                     rx + rw, ry + rh)
    end

    return true
end

# Swept Circle-OBB (Oriented Bounding Box / Angled Rectangle) collision
# detection and resolution.
function check_rectangles(ctx::PhysicsContext,
                          rects::Union{Nothing,Vector{Peg}}, geometry = nothing)::Nothing
    ball = ctx.ball::BallState
    time_remaining = ctx.time_remaining
    if rects === nothing
        return
    end
    for i in eachindex(rects)
        bp = broad_phase_pass(ctx, scan_geometry(rects, geometry, i))
        if bp !== nothing
            peg = rects[i]
            rel_move_x = bp.rel_move_x
            rel_move_y = bp.rel_move_y
            peg_iter_x = bp.peg_iter_x
            peg_iter_y = bp.peg_iter_y
            peg_vx = peg.vx
            peg_vy = peg.vy
            peg_va = peg.va

            slices = rotation_slices(ctx, peg, peg_va)
            angle_iter = peg.angle - peg_va * time_remaining

            # In local space, the peg is an AABB centered at (0, 0)
            shape = geometry === nothing ? rect_shape(peg) : geometry[i].shape
            # Lua `peg.half_w and -peg.half_w or -peg.width / 2`: the level
            # model never authors half_w, so the width/2 path always applies.
            rx = -shape.width / 2
            ry = -shape.height / 2
            rw = shape.width
            rh = shape.height
            r = ball.radius
            p = ctx.config.graze_tolerance

            for s in 0:(slices - 1)
                if !sweep_slice(ctx, peg, i, slices, angle_iter, peg_vx, peg_vy,
                                peg_va, peg_iter_x, peg_iter_y, rel_move_x,
                                rel_move_y, rx, ry, rw, rh, r, p, s)
                    break
                end
            end
        end
    end
    return nothing
end

function check_annulars(ctx::PhysicsContext,
                        pegs_list::Union{Nothing,Vector{Peg}}, geometry = nothing)::Nothing
    ball = ctx.ball::BallState
    move_x = ctx.move_x
    move_y = ctx.move_y
    time_remaining = ctx.time_remaining
    if pegs_list === nothing
        return
    end
    for i in eachindex(pegs_list)
        bp = broad_phase_pass(ctx, scan_geometry(pegs_list, geometry, i))
        if bp !== nothing
            peg = pegs_list[i]
            rel_move_x = bp.rel_move_x
            rel_move_y = bp.rel_move_y
            peg_iter_x = bp.peg_iter_x
            peg_iter_y = bp.peg_iter_y
            peg_vx = peg.vx
            peg_vy = peg.vy
            peg_va = peg.va
            shape = geometry === nothing ? annular_shape(peg) : geometry[i].shape

            slices = rotation_slices(ctx, peg, peg_va)
            t_start_iter = shape.theta_start - peg_va * time_remaining
            t_end_iter = shape.theta_end_abs - peg_va * time_remaining

            for s in 0:(slices - 1)
                t_offset = s / slices
                if t_offset > ctx.min_t + ctx.config.toi_epsilon
                    break
                end
                t_scale = 1 / slices

                # Positions and arc angles at slice start (rotation frozen for the slice)
                bx = ball.x + move_x * t_offset
                by = ball.y + move_y * t_offset
                px = peg_iter_x + peg_vx * time_remaining * t_offset
                py = peg_iter_y + peg_vy * time_remaining * t_offset
                dx = bx - px
                dy = by - py
                slice_move_x = rel_move_x * t_scale
                slice_move_y = rel_move_y * t_scale

                da_slice = peg_va * time_remaining * t_offset
                t_start = t_start_iter + da_slice
                t_end = t_end_iter + da_slice

                a = slice_move_x * slice_move_x + slice_move_y * slice_move_y
                b = 2 * (dx * slice_move_x + dy * slice_move_y)

                # Discrete overlap check for moving annulars. The catch zone spans
                # both sides of the wall, so classify the ball center and resolve
                # through the surface it is actually overlapping: only the outer
                # side may use the outward normal/outer penetration.
                dist_center = DetMath.det_sqrt(dx * dx + dy * dy)
                if dist_center < ball.radius + shape.r_out &&
                   annular_is_inside_arc(dx, dy, t_start, t_end)
                    if dist_center == 0
                        dist_center = 0.01
                    end
                    inner_diff = shape.r_in - ball.radius
                    if dist_center < shape.r_in
                        # Center in the hole: push back inward once the ball's
                        # surface has crossed the inner wall. A ball with full
                        # clearance sits deeper and is untouched.
                        inner_clear = dist_center - inner_diff
                        if inner_diff > 0 && inner_clear > 0
                            register_hit!(ctx, t_offset, -dx / dist_center,
                                          -dy / dist_center, "peg", peg,
                                          PRIORITY.annular_peg, i, inner_clear)
                        end
                    else
                        # Center in the solid band or outside it: exit through
                        # the nearer surface (the hole only counts when the ball
                        # fits through it).
                        outer_clear = (ball.radius + shape.r_out) - dist_center
                        inner_clear = inner_diff > 0 ? (dist_center - inner_diff) : nothing
                        if inner_clear !== nothing && inner_clear < outer_clear
                            register_hit!(ctx, t_offset, -dx / dist_center,
                                          -dy / dist_center, "peg", peg,
                                          PRIORITY.annular_peg, i, inner_clear)
                        elseif outer_clear > 0
                            register_hit!(ctx, t_offset, dx / dist_center,
                                          dy / dist_center, "peg", peg,
                                          PRIORITY.annular_peg, i, outer_clear)
                        end
                    end
                end

                # 1. Outer Arc
                radius_sum = ball.radius + shape.r_out
                cc = (dx * dx + dy * dy) - (radius_sum * radius_sum)
                if a > 0.0001
                    disc = b * b - 4 * a * cc

                    p = ctx.config.graze_tolerance
                    allowed_disc = -(p * 2 * radius_sum + p * p) * 4 * a

                    if disc >= allowed_disc
                        root = DetMath.det_sqrt(max(0.0, disc))
                        t1 = (-b - root) / (2 * a)
                        if t1 >= -0.001 && t1 <= 1.0
                            cx_rel = dx + slice_move_x * t1
                            cy_rel = dy + slice_move_y * t1
                            if annular_is_inside_arc(cx_rel, cy_rel, t_start, t_end)
                                if disc < 0
                                    # `peg.hit ~= nil` is always true for real pegs.
                                    grazed_add!(ctx, peg, t_offset + t1 * t_scale)
                                else
                                    dist = DetMath.det_sqrt(cx_rel * cx_rel +
                                                            cy_rel * cy_rel)
                                    if dist == 0
                                        dist = 0.01
                                    end

                                    t1 = max(0.0, t1)
                                    register_hit!(ctx, t_offset + t1 * t_scale,
                                                  cx_rel / dist, cy_rel / dist,
                                                  "peg", peg, PRIORITY.annular_peg,
                                                  i, 0.0)
                                end
                            end
                        end
                    end
                end

                # 2. Inner Arc
                if shape.r_in > 0
                    radius_diff = shape.r_in - ball.radius
                    if radius_diff > 0
                        cc = (dx * dx + dy * dy) - (radius_diff * radius_diff)
                        if a > 0.0001
                            disc = b * b - 4 * a * cc
                            if disc >= 0
                                root = DetMath.det_sqrt(disc)
                                # Correct root for hitting inner boundary from the inside
                                t1 = (-b + root) / (2 * a)
                                if t1 >= -0.001 && t1 <= 1.0
                                    t1 = max(0.0, t1)
                                    cx_rel = dx + slice_move_x * t1
                                    cy_rel = dy + slice_move_y * t1
                                    if annular_is_inside_arc(cx_rel, cy_rel, t_start, t_end)
                                        dist = DetMath.det_sqrt(cx_rel * cx_rel +
                                                                cy_rel * cy_rel)
                                        # Normal points INWARD
                                        register_hit!(ctx, t_offset + t1 * t_scale,
                                                      -cx_rel / dist, -cy_rel / dist,
                                                      "peg", peg, PRIORITY.annular_peg,
                                                      i, 0.0)
                                    end
                                end
                            end
                        end
                    end
                end

                # 3. Caps (normals derived from the slice-start arc angles)
                cos_ts = DetMath.det_cos(t_start)
                sin_ts = DetMath.det_sin(t_start)
                cos_te = DetMath.det_cos(t_end)
                sin_te = DetMath.det_sin(t_end)

                annular_check_cap(ctx, peg, ball, i, t_offset, t_scale, px, py, bx,
                                  by, dx, dy, slice_move_x, slice_move_y, sin_ts,
                                  -cos_ts, t_start)
                annular_check_cap(ctx, peg, ball, i, t_offset, t_scale, px, py, bx,
                                  by, dx, dy, slice_move_x, slice_move_y, -sin_te,
                                  cos_te, t_end)

                # 4. Corners (recomputed at the slice-start transform)
                annular_check_corner(ctx, peg, ball, i, t_offset, t_scale, px, py,
                                     bx, by, dx, dy, slice_move_x, slice_move_y,
                                     a, shape.r_in, t_start)
                annular_check_corner(ctx, peg, ball, i, t_offset, t_scale, px, py,
                                     bx, by, dx, dy, slice_move_x, slice_move_y,
                                     a, shape.r_out, t_start)
                annular_check_corner(ctx, peg, ball, i, t_offset, t_scale, px, py,
                                     bx, by, dx, dy, slice_move_x, slice_move_y,
                                     a, shape.r_in, t_end)
                annular_check_corner(ctx, peg, ball, i, t_offset, t_scale, px, py,
                                     bx, by, dx, dy, slice_move_x, slice_move_y,
                                     a, shape.r_out, t_end)
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Ball-ball sweep (physics.lua lines 811-889)
# ---------------------------------------------------------------------------

# Swept circle-circle between launched balls. Other balls are
# modelled over the current iteration window from their effective
# frame-time state (pending = frame-start, done = frame-end).
# Collisions share the circle-peg priority; exact ties are broken
# by the peg/ball index (first registered wins when equal).
function check_balls(ctx::PhysicsContext)::Nothing
    balls = ctx.balls
    ball_frame = ctx.ball_frame
    ball = ctx.ball::BallState
    move_x = ctx.move_x
    move_y = ctx.move_y
    time_remaining = ctx.time_remaining
    if ctx.config.ball_ball_collisions == false
        return
    end
    for (i, other) in enumerate(balls)
        if other !== ball && other.launched
            bf = get(ball_frame, other, nothing)
            if bf !== nothing && bf.done
                # Lua `bf.vend_x or other.vx`: vend is always set when done.
                vx = bf.vend_x
                vy = bf.vend_y
                ox = other.x - vx * time_remaining
                oy = other.y - vy * time_remaining
                other_move_x = vx * time_remaining
                other_move_y = vy * time_remaining
            else
                ox = other.x
                oy = other.y
                other_move_x = other.vx * time_remaining
                other_move_y = other.vy * time_remaining
            end

            dx = ball.x - ox
            dy = ball.y - oy
            rel_move_x = move_x - other_move_x
            rel_move_y = move_y - other_move_y
            radius_sum = ball.radius + other.radius

            rel_move_len = DetMath.det_sqrt(rel_move_x * rel_move_x +
                                            rel_move_y * rel_move_y)
            reach = radius_sum + rel_move_len
            if dx * dx + dy * dy <= reach * reach
                a = rel_move_x * rel_move_x + rel_move_y * rel_move_y
                b = 2 * (dx * rel_move_x + dy * rel_move_y)
                cc = (dx * dx + dy * dy) - (radius_sum * radius_sum)

                if cc < 0
                    # Already intersecting: pop out along the
                    # center line, or along the relative motion
                    # when the centers coincide (multiball spawn).
                    dist = DetMath.det_sqrt(dx * dx + dy * dy)
                    if dist > 1e-8
                        nx, ny = dx / dist, dy / dist
                    elseif rel_move_len > 1e-8
                        nx, ny = rel_move_x / rel_move_len, rel_move_y / rel_move_len
                    else
                        nx, ny = 1.0, 0.0
                    end
                    register_hit!(ctx, 0.0, nx, ny, "ball", nothing, PRIORITY.ball,
                                  i, radius_sum - dist, other)
                elseif a > 0.0001
                    disc = b * b - 4 * a * cc
                    if disc >= 0
                        root = DetMath.det_sqrt(disc)
                        t1 = (-b - root) / (2 * a)
                        if t1 >= -0.001 && t1 <= 1.0
                            cx_rel = dx + rel_move_x * t1
                            cy_rel = dy + rel_move_y * t1
                            dist = DetMath.det_sqrt(cx_rel * cx_rel + cy_rel * cy_rel)
                            if dist == 0
                                dist = 0.01
                            end
                            t1 = max(0.0, t1)
                            register_hit!(ctx, t1, cx_rel / dist, cy_rel / dist,
                                          "ball", nothing, PRIORITY.ball, i, 0.0, other)
                        end
                    end
                end
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# End-of-frame de-penetration (physics.lua lines 891-1092)
# ---------------------------------------------------------------------------

# End-of-frame de-penetration: when iterations max out, the ball freezes
# mid-frame while pegs keep moving to their final transform, and rotating
# pegs leave up to one sweep slice of frozen-angle lag. Either way the frame
# can end with the ball visibly inside a peg; push it out along the contact
# normal (position only) so physics and rendering never show interpenetration.
function depenetrate(ctx::PhysicsContext, pegs_list::Union{Nothing,Vector{Peg}},
                     shape::String)::Nothing
    ball = ctx.ball::BallState
    total_dt = ctx.total_dt
    if pegs_list === nothing
        return
    end
    for peg in pegs_list
        dx = ball.x - peg.x
        dy = ball.y - peg.y
        br = prepared_bounding_radius(peg)
        reach = ball.radius + br
        if dx * dx + dy * dy <= reach * reach
            # Lua `local nx, ny, overlap` are nil until a surface resolves.
            nx = 0.0
            ny = 0.0
            overlap = 0.0
            has_hit = false
            if shape == "circle"
                radius_sum = ball.radius + circ_radius(peg)
                dist = DetMath.det_sqrt(dx * dx + dy * dy)
                if dist < radius_sum
                    if dist == 0
                        dist = 0.01
                    end
                    nx, ny = dx / dist, dy / dist
                    overlap = radius_sum - dist
                    has_hit = true
                end
            elseif shape == "rectangle"
                angle = peg.angle
                cos_a = DetMath.det_cos(angle)
                sin_a = DetMath.det_sin(angle)
                lx = dx * cos_a + dy * sin_a
                ly = -dx * sin_a + dy * cos_a
                # Lua `peg.half_w or peg.width / 2`; half_w is never authored.
                rshape = rect_shape(peg)
                hw = rshape.width / 2
                hh = rshape.height / 2
                cx = max(-hw, min(lx, hw))
                cy = max(-hh, min(ly, hh))
                l_dx = lx - cx
                l_dy = ly - cy
                d2 = l_dx * l_dx + l_dy * l_dy
                if d2 < ball.radius * ball.radius
                    local_nx = 0.0
                    local_ny = 0.0
                    if d2 > 1e-8
                        dist = DetMath.det_sqrt(d2)
                        local_nx = l_dx / dist
                        local_ny = l_dy / dist
                        overlap = ball.radius - dist
                    else
                        # Ball center inside rectangle, eject along shallowest axis
                        toLeft = lx + hw
                        toRight = hw - lx
                        toTop = ly + hh
                        toBottom = hh - ly
                        m = min(toLeft, toRight, toTop, toBottom)
                        if m == toLeft
                            local_nx, local_ny = -1.0, 0.0
                            overlap = ball.radius + toLeft
                        elseif m == toRight
                            local_nx, local_ny = 1.0, 0.0
                            overlap = ball.radius + toRight
                        elseif m == toTop
                            local_nx, local_ny = 0.0, -1.0
                            overlap = ball.radius + toTop
                        else
                            local_nx, local_ny = 0.0, 1.0
                            overlap = ball.radius + toBottom
                        end
                    end
                    nx = local_nx * cos_a - local_ny * sin_a
                    ny = local_nx * sin_a + local_ny * cos_a
                    has_hit = true
                end
            else # annular
                ashape = annular_shape(peg)
                dist = DetMath.det_sqrt(dx * dx + dy * dy)
                if dist == 0
                    dist = 0.01
                end
                hit_angle = DetMath.det_atan2(dy, dx)
                normalized = DetMath.lua_mod(hit_angle - ashape.theta_start, pi * 2)
                in_arc = normalized <= (ashape.theta_end_abs - ashape.theta_start + 0.001) ||
                         normalized >= (pi * 2 - 0.001)
                inner_diff = ashape.r_in - ball.radius
                if in_arc
                    if dist < ashape.r_in
                        # Inside the hole: the void is the hole, so only push
                        # back inward once the ball's surface has crossed the
                        # inner wall (dist > r_in - ball.radius). A ball with
                        # full clearance sits deeper than that and is untouched.
                        inner_clear = dist - inner_diff
                        if inner_diff > 0 && inner_clear > 0
                            nx, ny = -dx / dist, -dy / dist
                            overlap = inner_clear
                            has_hit = true
                        end
                    elseif dist < ball.radius + ashape.r_out
                        # Inside the solid band: exit through the nearer
                        # surface so the ball is never pushed across the wall.
                        outer_clear = (ball.radius + ashape.r_out) - dist
                        inner_clear = inner_diff > 0 ? (dist - inner_diff) : nothing
                        if inner_clear !== nothing && inner_clear < outer_clear
                            nx, ny = -dx / dist, -dy / dist
                            overlap = inner_clear
                        else
                            nx, ny = dx / dist, dy / dist
                            overlap = outer_clear
                        end
                        has_hit = true
                    end
                end
            end
            if has_hit
                depen_rec = ContactRecord(
                    ball.x, ball.y, 0.0, 0.0, 0.0, total_dt, 0.0, 0,
                    nx, ny, ball.vx, ball.vy, ball.vx, ball.vy,
                    nothing, nothing, nothing,
                )
                ball.x = ball.x + nx * (overlap + ctx.config.overlap_push_margin)
                ball.y = ball.y + ny * (overlap + ctx.config.overlap_push_margin)
                # Report objective depenetration contact; reducer decides scoring.
                emit_contact!(ctx.journal, "ball_contacted_peg", ball, depen_rec,
                              false, peg, "depenetrate")
            end
        end
    end
    return nothing
end

# Ball-ball de-penetration fallback: unlike pegs, other balls also
# move, so sequential resolution can leave a residual overlap. Push
# only the current ball (position only) to keep its own draw_path
# consistent; the other ball's sub-step integrates its own motion.
function depenetrate_balls(ctx::PhysicsContext)::Nothing
    balls = ctx.balls
    ball = ctx.ball::BallState
    total_dt = ctx.total_dt
    if ctx.config.ball_ball_collisions == false
        return
    end
    for other in balls
        if other !== ball && other.launched
            dx = ball.x - other.x
            dy = ball.y - other.y
            radius_sum = ball.radius + other.radius
            d2 = dx * dx + dy * dy
            if d2 < radius_sum * radius_sum
                dist = DetMath.det_sqrt(d2)
                if dist > 1e-8
                    nx, ny = dx / dist, dy / dist
                else
                    nx, ny = 1.0, 0.0
                end
                overlap = radius_sum - dist
                depen_rec = ContactRecord(
                    ball.x, ball.y, 0.0, 0.0, 0.0, total_dt, 0.0, 0,
                    nx, ny, ball.vx, ball.vy, ball.vx, ball.vy,
                    other, nothing, nothing,
                )
                ball.x = ball.x + nx * (overlap + ctx.config.overlap_push_margin)
                ball.y = ball.y + ny * (overlap + ctx.config.overlap_push_margin)
                emit_contact!(ctx.journal, "ball_contact_ball", ball, depen_rec,
                              false, nothing, "depenetrate")
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Physics.update (physics.lua lines 1094-1433)
# ---------------------------------------------------------------------------

# event_sink: the gameplay journal. Physics only reports objective collision
# facts to it; it never mutates authoritative gameplay state (peg.hit,
# scoring, ...). Presentation-only recording (ImpactDebug, ContactEvents) and
# the ball.draw_path timeline are not ported.
function physics_update!(
    balls::Vector{BallState},
    circle_pegs::Vector{Peg},
    rect_pegs::Vector{Peg},
    annular_pegs::Vector{Peg},
    dt::Float64,
    extras::Union{Nothing,Vector{FeverDivider}},
    config::SimConfig,
    virtual_width::Float64,
    journal::GameplayJournal,
    ctx::PhysicsContext = PhysicsContext(balls, config, virtual_width, journal),
    geometry::Union{Nothing,PreparedGeometry} = nothing,
    static_geometry::Bool = false,
)::Nothing
    reset_physics_context!(ctx, balls, config, virtual_width, journal)
    if geometry !== nothing && !static_geometry
        refresh_geometry!(geometry.circles, circle_pegs)
        refresh_geometry!(geometry.rectangles, rect_pegs)
        refresh_geometry!(geometry.annulars, annular_pegs)
    end

    # Per-frame ball bookkeeping for ball-ball collision reconstruction. A
    # launched ball not yet processed this frame is treated as starting at its
    # stored position and moving with its current velocity over the window. A
    # ball already processed is treated like a peg: its stored position is the
    # frame-end and the window start is back-derived as position - vend *
    # window, where vend is the velocity it actually finished its sub-step
    # with (post-bounce), so the reconstructed segment stays consistent with
    # its real motion instead of phantoming its pre-bounce direction.
    ball_frame = ctx.ball_frame
    frame_count = 0
    for b in balls
        if b.launched
            frame_count += 1
            if frame_count > length(ctx.frame_pool)
                push!(ctx.frame_pool, BallFrameState(false, 0.0, 0.0))
            end
            frame = ctx.frame_pool[frame_count]
            frame.done = false
            frame.vend_x = frame.vend_y = 0.0
            ball_frame[b] = frame
        end
    end

    for ball in balls
        if !ball.launched
            continue
        end

        ctx.ball = ball

        bfs = ball_frame[ball]

        time_remaining = dt
        total_dt = dt
        ctx.total_dt = total_dt
        max_iterations = 5
        iterations = 0

        while time_remaining > 0.00001 && iterations < max_iterations
            iterations = iterations + 1

            # Instrumentation capture (read-only): iteration-window start state.
            iter_sx, iter_sy = ball.x, ball.y
            iter_time = time_remaining

            move_x = ball.vx * time_remaining
            move_y = ball.vy * time_remaining
            ctx.move_x = move_x
            ctx.move_y = move_y
            ctx.time_remaining = time_remaining

            prepare_static_query!(ctx)

            ctx.min_t = 1.0
            ctx.hit_nx, ctx.hit_ny = 0.0, 0.0
            ctx.hit_type = nothing
            ctx.hit_peg = nothing
            ctx.hit_other_ball = nothing
            ctx.hit_priority = nothing
            ctx.hit_peg_index = nothing
            ctx.hit_overlap = 0.0
            empty!(ctx.grazed)

            # 1. Check Walls (Swept)
            if move_x < 0
                t = (ball.radius - ball.x) / move_x
                if ball.x <= ball.radius
                    register_hit!(ctx, 0.0, 1.0, 0.0, "wall", nothing,
                                  PRIORITY.wall, nothing, ball.radius - ball.x)
                elseif t >= 0
                    register_hit!(ctx, t, 1.0, 0.0, "wall", nothing,
                                  PRIORITY.wall, nothing, 0.0)
                end
            elseif move_x > 0
                right_wall = ctx.virtual_width
                t = (right_wall - ball.radius - ball.x) / move_x
                if ball.x >= right_wall - ball.radius
                    register_hit!(ctx, 0.0, -1.0, 0.0, "wall", nothing,
                                  PRIORITY.wall, nothing,
                                  ball.x - (right_wall - ball.radius))
                elseif t >= 0
                    register_hit!(ctx, t, -1.0, 0.0, "wall", nothing,
                                  PRIORITY.wall, nothing, 0.0)
                end
            end

            # Only the ceiling bounces; the floor is open so the ball falls out
            # the bottom (and may be caught by the bucket).
            if move_y < 0
                t = (ball.radius - ball.y) / move_y
                if ball.y <= ball.radius
                    register_hit!(ctx, 0.0, 0.0, 1.0, "wall", nothing,
                                  PRIORITY.wall, nothing, ball.radius - ball.y)
                elseif t >= 0
                    register_hit!(ctx, t, 0.0, 1.0, "wall", nothing,
                                  PRIORITY.wall, nothing, 0.0)
                end
            end

            check_circles(ctx, circle_pegs, false, geometry === nothing ? nothing : geometry.circles)
            check_rectangles(ctx, rect_pegs, geometry === nothing ? nothing : geometry.rectangles)
            check_annulars(ctx, annular_pegs, geometry === nothing ? nothing : geometry.annulars)

            check_circles(ctx, extras, true)

            check_balls(ctx)

            min_t = ctx.min_t
            hit_nx, hit_ny = ctx.hit_nx, ctx.hit_ny
            hit_type = ctx.hit_type
            hit_peg = ctx.hit_peg
            hit_other_ball = ctx.hit_other_ball
            hit_overlap = ctx.hit_overlap

            for gi in 1:length(ctx.grazed)
                g = ctx.grazed[gi]
                if g.t <= min_t + ctx.config.toi_epsilon
                    # Graze: report an objective raw contact fact. Authoritative
                    # scoring (peg.hit) is decided later by the Engine reducer.
                    ix = iter_sx + move_x * g.t
                    iy = iter_sy + move_y * g.t
                    frame_t = ((total_dt - iter_time) + g.t * iter_time) / total_dt
                    fields = EventFields(
                        ball_id = ball.id, peg_id = g.peg.id,
                        peg_type = peg_type_name(g.peg.peg_type),
                        peg_shape = peg_shape_name(g.peg.shape),
                        contact_kind = "graze", did_bounce = false,
                        impact_x = ix, impact_y = iy, frame_t = frame_t,
                        toi = g.t, iteration = iterations,
                        normal_x = 0.0, normal_y = 0.0,
                        incoming_vx = ball.vx, incoming_vy = ball.vy,
                        outgoing_vx = ball.vx, outgoing_vy = ball.vy,
                        line_meta_id = _line_id(g.peg.line),
                        line_meta_index = _line_index(g.peg.line),
                        line_meta_count = _line_count(g.peg.line),
                        line_meta_closed = _line_closed(g.peg.line),
                        line_meta_gap = _line_gap(g.peg.line),
                    )
                    emit_raw!(journal, "ball_contacted_peg", fields)
                end
            end

            # Apply movement up to impact (use safe_t to avoid floating point
            # sticking to bounds)
            safe_t = max(0.0, min_t - ctx.config.safe_t_margin)

            if min_t > 0
                ball.x = ball.x + move_x * safe_t
                ball.y = ball.y + move_y * safe_t
            end

            # Apply gravity for the time spent before the collision.
            # Gravity is applied to the ball's velocity BEFORE collision
            # resolution. This is correct for swept CCD: gravity acts during
            # the time the ball traveled to the impact point
            # (time_remaining * min_t), so the velocity at impact reflects
            # accumulated gravitational acceleration.
            ball.vy = ball.vy + ctx.config.gravity * (time_remaining * min_t)

            if min_t < 1.0 && hit_type !== nothing
                # Instrumentation capture (read-only): impact velocity after
                # the pre-collision gravity segment, before the impulse.
                idb_vin_x, idb_vin_y = ball.vx, ball.vy

                pvx, pvy = 0.0, 0.0
                if hit_type == "ball" && hit_other_ball !== nothing
                    pvx = hit_other_ball.vx
                    pvy = hit_other_ball.vy
                elseif hit_peg isa Peg
                    # A FeverDivider has no velocity fields; Lua's `peg.vx or 0`
                    # contributes (0, 0), the same as when hit_peg was nothing.
                    pvx = hit_peg.vx
                    pvy = hit_peg.vy
                end

                rel_vx = ball.vx - pvx
                rel_vy = ball.vy - pvy

                # Collision occurred! Resolve velocity
                dot = rel_vx * hit_nx + rel_vy * hit_ny
                did_bounce = false
                other_vout_x = nothing
                other_vout_y = nothing

                if dot < 0
                    if hit_type == "wall"
                        bounce_factor = ctx.config.wall_damping
                    elseif hit_type == "ball"
                        bounce_factor = ctx.config.ball_ball_restitution
                    else
                        bounce_factor = ctx.config.restitution
                    end
                    # Settling threshold: a contact whose normal approach speed
                    # is below bounce_min_normal_speed is a resting/creeping
                    # contact, not a bounce. Use a reduced restitution so it
                    # loses most energy while still ejecting from
                    # wedges/corners, and report did_bounce=false so style-shot
                    # slide runs are not reset by micro-contacts.
                    if (-dot) < ctx.config.bounce_min_normal_speed
                        bounce_factor = min(bounce_factor,
                                            ctx.config.settle_restitution)
                    else
                        did_bounce = true
                    end
                    impulse_x = -(1 + bounce_factor) * dot * hit_nx
                    impulse_y = -(1 + bounce_factor) * dot * hit_ny

                    if hit_type == "ball" && hit_other_ball !== nothing
                        # Equal-mass impulse: the pair shares the normal impulse
                        # in opposite directions (momentum is conserved exactly).
                        ball.vx = ball.vx + impulse_x * 0.5
                        ball.vy = ball.vy + impulse_y * 0.5
                        hit_other_ball.vx = hit_other_ball.vx - impulse_x * 0.5
                        hit_other_ball.vy = hit_other_ball.vy - impulse_y * 0.5
                    else
                        ball.vx = ball.vx + impulse_x
                        ball.vy = ball.vy + impulse_y
                    end
                end
                if hit_type == "ball" && hit_other_ball !== nothing
                    other_vout_x = hit_other_ball.vx
                    other_vout_y = hit_other_ball.vy
                end

                # Push out slightly if overlapping
                if min_t == 0
                    ball.x = ball.x + hit_nx * (hit_overlap + ctx.config.overlap_push_margin)
                    ball.y = ball.y + hit_ny * (hit_overlap + ctx.config.overlap_push_margin)
                end

                collision_rec = ContactRecord(
                    iter_sx, iter_sy, move_x, move_y, iter_time, total_dt,
                    min_t, iterations, hit_nx, hit_ny,
                    idb_vin_x, idb_vin_y, ball.vx, ball.vy,
                    hit_other_ball, other_vout_x, other_vout_y,
                )

                # Emit the authoritative raw contact event. Physics reports the
                # fact; the Engine reducer later decides scoring / peg.hit.
                if hit_type == "wall"
                    ev_type = "ball_contact_wall"
                elseif hit_type == "extra"
                    ev_type = "ball_contact_fever_divider"
                elseif hit_type == "ball"
                    ev_type = "ball_contact_ball"
                else
                    ev_type = "ball_contacted_peg"
                end
                emit_contact!(journal, ev_type, ball, collision_rec, did_bounce,
                              hit_peg, min_t == 0 ? "overlap" : "sweep")
            end

            time_remaining = time_remaining * (1 - min_t)
        end

        # In case iterations max out but time remains, finish the frame the same
        # way the loop does: advance by the leftover time, then apply gravity.
        # Applying gravity without the matching displacement pumps kinetic
        # energy into a ball that is still resting on a surface (the arc bowl
        # was observed accelerating past 3500 px/s with no height to pay for
        # it). Advancing first keeps the work/energy balance consistent.
        if time_remaining > 0.00001 && iterations >= max_iterations
            ball.x = ball.x + ball.vx * time_remaining
            ball.y = ball.y + ball.vy * time_remaining
            ball.vy = ball.vy + ctx.config.gravity * time_remaining
        end

        depenetrate(ctx, circle_pegs, "circle")
        depenetrate(ctx, rect_pegs, "rectangle")
        depenetrate(ctx, annular_pegs, "annular")

        depenetrate_balls(ctx)

        bfs.vend_x = ball.vx
        bfs.vend_y = ball.vy
        bfs.done = true
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Launch helpers (physics.lua lines 1435-1503)
# ---------------------------------------------------------------------------

# Julia names for the Lua `Physics.getLaunchVelocity` / `getSnappedAimAngle`.
# The config argument replaces the Lua `Config` global; `get_snapped_aim_angle`
# deliberately does not claim the engine's frozen `snapped_aim_angle` name.
function get_launch_velocity(x0::Float64, y0::Float64, xt::Float64, yt::Float64,
                             v::Float64, config::SimConfig)::Tuple{Float64,Float64}
    g = config.gravity
    dx = xt - x0
    dy = yt - y0

    # Handle near-vertical shots or zero gravity to avoid division by zero
    if abs(dx) < 0.1 || abs(g) < 0.1
        dist = DetMath.det_sqrt(dx * dx + dy * dy)
        if dist == 0
            return (0.0, 0.0)
        end
        return ((dx / dist) * v, (dy / dist) * v)
    end

    x2 = dx * dx
    v2 = v * v
    v4 = v2 * v2

    # Ballistic discriminant: v^4 - g(g*x^2 + 2*y*v^2)
    # Note: dy is positive downwards in LÖVE, so we use -2*dy*v2 for standard
    # formula
    disc = v4 - g * (g * x2 - 2 * dy * v2)

    if disc < 0
        # Target out of range, fallback to direct aim
        dist = DetMath.det_sqrt(dx * dx + dy * dy)
        return ((dx / dist) * v, (dy / dist) * v)
    end

    root = DetMath.det_sqrt(disc)

    # Two solutions for tan(theta) = (-v^2 +- root) / (g * dx)
    t1 = (-v2 + root) / (g * dx)
    t2 = (-v2 - root) / (g * dx)

    # We want the solution that is "flatter" (closer to the direct angle)
    direct_tan = dy / dx
    u = abs(t1 - direct_tan) < abs(t2 - direct_tan) ? t1 : t2

    # Calculate vx, vy from tan(theta) = u and vx^2 + vy^2 = v^2
    vx = v / DetMath.det_sqrt(1 + u * u)
    if dx < 0
        vx = -vx
    end
    vy = u * vx

    return (vx, vy)
end

function get_snapped_aim_angle(angle::Float64, config::SimConfig)::Float64
    # Lua `if not steps then return angle end` catches only nil/false; the
    # typed config always carries an integer, so the guard is unreachable.
    steps = config.aim_discretization_steps

    limit = config.aim_angle_limit
    mid = pi / 2

    # Clamp the input angle just in case
    angle = max(mid - limit, min(mid + limit, angle))

    # Scale the angle into [0, 1] range relative to the aiming arc
    normalized = (angle - (mid - limit)) / (2 * limit)

    # Snap to the nearest step
    normalized = floor(normalized * steps + 0.5) / steps

    # Scale back to world radians
    return (mid - limit) + normalized * (2 * limit)
end
