# ===========================================================================
# ImpactGeometry: pure geometry helpers shared by the collision
# instrumentation (ImpactDebug) and the render-only contact presenter
# (ContactEvents). No state, no mutation.
#
# Ports ../peggle_evolved/src/systems/impact_geometry.lua at da75225. The Lua
# file leaves its transcendentals on `math.*` (it is presentation-only apart
# from `peg_transform_at_toi`, which physics calls when emitting peg contact
# events); this port routes every one through DetMath per the M3 porting
# rules. The only signature deviation is `wall_separation`, which takes the
# virtual width explicitly because Julia has no `LevelManager` global.
# ===========================================================================

# Squared distance from (px, py) to the segment (ax, ay)-(bx, by).
function dist_seg_sq(px::Float64, py::Float64, ax::Float64, ay::Float64,
                     bx::Float64, by::Float64)::Float64
    abx, aby = bx - ax, by - ay
    t = 0.0
    denom = abx * abx + aby * aby
    if denom > 0
        t = ((px - ax) * abx + (py - ay) * aby) / denom
        if t < 0
            t = 0.0
        elseif t > 1
            t = 1.0
        end
    end
    cx, cy = ax + abx * t, ay + aby * t
    dx, dy = px - cx, py - cy
    return dx * dx + dy * dy
end

# Peg transform at the moment of impact. The physics engine stores the peg's
# END-of-step transform plus its per-step velocity; broadPhasePass derives the
# iteration-window-start transform as (x - vx * window). The transform at TOI
# is therefore end - v * window * (1 - toi).
#
# Frozen M3 signature. The fourth value is the annular `theta_start` at the
# TOI; it is `nothing` for circle and rectangle pegs (the Lua function returns
# the tuple with `nil` there).
function peg_transform_at_toi(peg::Peg, window::Float64, toi::Float64
                             )::Tuple{Float64,Float64,Float64,Union{Nothing,Float64}}
    vx, vy, va = peg.vx, peg.vy, peg.va
    back = window * (1 - toi)
    px = peg.x - vx * back
    py = peg.y - vy * back
    angle = peg.angle - va * back
    shape = peg.shape
    theta = shape isa AnnularShape ? (shape.theta_start - va * back) : nothing
    return (px, py, angle, theta)
end

# Signed surface separation between the ball (center icx/icy, radius r) and a
# peg at the given transform. Positive = gap, negative = penetration.
function surface_separation(peg::Peg, px::Float64, py::Float64, angle::Float64,
                            theta_start::Union{Nothing,Float64}, icx::Float64,
                            icy::Float64, r::Float64)::Float64
    shape = peg.shape
    dx, dy = icx - px, icy - py
    if shape isa CircleShape
        return DetMath.det_sqrt(dx * dx + dy * dy) - r - shape.radius
    elseif shape isa RectangleShape
        ca, sa = DetMath.det_cos(angle), DetMath.det_sin(angle)
        lx = dx * ca + dy * sa
        ly = -dx * sa + dy * ca
        hw = shape.width / 2
        hh = shape.height / 2
        qx = abs(lx) - hw
        qy = abs(ly) - hh
        ox = max(qx, 0.0)
        oy = max(qy, 0.0)
        sd = DetMath.det_sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0.0)
        return sd - r
    elseif shape isa AnnularShape
        d = DetMath.det_sqrt(dx * dx + dy * dy)
        ts = theta_start === nothing ? shape.theta_start : theta_start
        te = shape.theta_end_abs - (shape.theta_start - ts) # shift span by same delta
        ang = DetMath.det_atan2(dy, dx)
        norm = DetMath.lua_mod(ang - ts, pi * 2)
        in_arc = norm <= (te - ts + 0.001) || norm >= (pi * 2 - 0.001)
        if in_arc
            if d > shape.r_out
                return d - shape.r_out - r
            elseif d < shape.r_in
                return shape.r_in - d - r
            else
                return -min(shape.r_out - d, d - shape.r_in) - r
            end
        end
        # Outside the angular span: nearest solid points lie on the cap segments.
        cs, ss = DetMath.det_cos(ts), DetMath.det_sin(ts)
        ce, se = DetMath.det_cos(te), DetMath.det_sin(te)
        d1 = dist_seg_sq(icx, icy, px + shape.r_in * cs, py + shape.r_in * ss,
                         px + shape.r_out * cs, py + shape.r_out * ss)
        d2 = dist_seg_sq(icx, icy, px + shape.r_in * ce, py + shape.r_in * se,
                         px + shape.r_out * ce, py + shape.r_out * se)
        return DetMath.det_sqrt(min(d1, d2)) - r
    end
    return 0.0
end

# `virtual_width` replaces the Lua `LevelManager.virtual_width` global.
function wall_separation(hit_nx::Float64, hit_ny::Float64, icx::Float64,
                         icy::Float64, r::Float64, virtual_width::Float64)::Float64
    if hit_nx > 0
        return icx - r # left wall
    elseif hit_nx < 0
        return virtual_width - icx - r # right wall
    else
        return icy - r # ceiling
    end
end
