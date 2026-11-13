# Port of src/entities/bucket.lua (dev tree @ da752257, detmath routing), plus
# the 10ee3a0 ramp bucket (RULES_RAMP_BUCKET; see the second half of this file
# and wiki/context/bucket-ramps.md). The model is fixed per BucketState by
# `bucket.ramps`, which the constructor takes from `SimConfig.rules`.
#
# The Lua entity reads `LevelManager.virtual_width` (the level's resolved
# virtual width, which the level artifact may override: mustache is 880x550
# while Config carries 1200x1900). The frozen M3 interface maps that read to
# `c.virtual_width`; the four-argument overload takes the level width
# explicitly so the engine can pass `ShotEngine.virtual_width` and stay
# bit-exact with the Lua reference on levels that override the default.
# `Bucket.update` never touches `prev_x` (Engine:savePreviousState does), so
# neither method does either.

# Half the total span of the bucket, from its center.
#   classic: hole plus both edges.
#   ramps:   Bucket.half_span = hole/2 + rim + ramp foot.
function bucket_half_span(bucket::BucketState)::Float64
    if bucket.ramps
        return bucket.hole / 2 + bucket.rim_width + bucket.ramp_width
    end
    return bucket.hole / 2 + bucket.edge
end

function bucket_update!(bucket::BucketState, dt::Float64, c::SimConfig)::Nothing
    return bucket_update!(bucket, dt, c, c.virtual_width)
end

# Bucket.update: a sinusoid with amplitude = center - halfSpan, driven by
# omega = sqrt(max_accel / amplitude), max_accel = multiplier * width. The
# phase wraps with Lua's floored modulo to bound precision loss.
function bucket_update!(bucket::BucketState, dt::Float64, c::SimConfig,
                        virtual_width::Float64)::Nothing
    w = virtual_width
    half = bucket_half_span(bucket)
    center = w / 2
    amplitude = center - half

    max_accel = c.bucket_accel_multiplier * w

    omega = DetMath.det_sqrt(max_accel / amplitude)

    bucket.phase = bucket.phase + omega * dt
    bucket.phase = DetMath.lua_mod(bucket.phase, pi * 2)

    bucket.x = center - amplitude * DetMath.det_cos(bucket.phase)
    return nothing
end

# collideRect (local in bucket.lua): resolve a circle (the ball) against an
# axis-aligned rectangle, reflecting off the actual surface normal with
# restitution. Mutates the ball; returns true on contact. Lua's
# `math.min/max` argument order is preserved literally.
function bucket_collide_rect!(ball::BallState, rx::Float64, ry::Float64,
                              rw::Float64, rh::Float64,
                              c::SimConfig)::Bool
    r = ball.radius

    cx = max(rx, min(ball.x, rx + rw))
    cy = max(ry, min(ball.y, ry + rh))
    dx = ball.x - cx
    dy = ball.y - cy
    d2 = dx * dx + dy * dy

    if d2 >= r * r
        return false
    end

    nx = 0.0
    ny = 0.0
    if d2 > 1e-8
        # Outside the rect: normal points from the closest surface point.
        dist = DetMath.det_sqrt(d2)
        nx = dx / dist
        ny = dy / dist
        ball.x = cx + nx * r
        ball.y = cy + ny * r
    else
        # Center inside the rect: eject along the shallowest axis.
        toLeft = ball.x - rx
        toRight = (rx + rw) - ball.x
        toTop = ball.y - ry
        toBottom = (ry + rh) - ball.y
        m = min(toLeft, toRight, toTop, toBottom)
        if m == toLeft
            nx = -1.0
            ny = 0.0
            ball.x = rx - r
        elseif m == toRight
            nx = 1.0
            ny = 0.0
            ball.x = rx + rw + r
        elseif m == toTop
            nx = 0.0
            ny = -1.0
            ball.y = ry - r
        else
            nx = 0.0
            ny = 1.0
            ball.y = ry + rh + r
        end
    end

    # Reflect velocity along the normal only when moving into the surface.
    dot = ball.vx * nx + ball.vy * ny
    if dot < 0
        e = 1 + c.restitution
        ball.vx = ball.vx - e * dot * nx
        ball.vy = ball.vy - e * dot * ny
    end
    return true
end

# Bucket.resolve. Lua returns "caught" | "bounced" | nil; the frozen Julia
# mapping is :caught | :bounced | :none.
function bucket_resolve!(bucket::BucketState, ball::BallState,
                         c::SimConfig)::Symbol
    bucket.ramps && return ramp_bucket_resolve!(bucket, ball, c)
    return classic_bucket_resolve!(bucket, ball, c)
end

# Classic (pinned) Bucket.resolve. The catch check runs first, so a ball
# inside the hole span is never resolved against the walls.
function classic_bucket_resolve!(bucket::BucketState, ball::BallState,
                                 c::SimConfig)::Symbol
    holeHalf = bucket.hole / 2

    if ball.vy > 0 &&
       ball.y + ball.radius >= bucket.top &&
       ball.y - ball.radius <= bucket.top + bucket.height &&
       abs(ball.x - bucket.x) <= holeHalf
        return :caught
    end

    # Solid parts: the two side walls and the base.
    edge = bucket.edge
    height = bucket.height
    top = bucket.top
    leftX = bucket.x - holeHalf - edge
    rightX = bucket.x + holeHalf

    hit = false
    if bucket_collide_rect!(ball, leftX, top, edge, height, c)
        hit = true
    end
    if bucket_collide_rect!(ball, rightX, top, edge, height, c)
        hit = true
    end
    if bucket_collide_rect!(ball, leftX, top + height,
                            bucket.hole + edge * 2, edge, c)
        hit = true
    end

    return hit ? :bounced : :none
end

# ===========================================================================
# 10ee3a0 ramp bucket (peggle_evolved src/entities/bucket.lua @ 10ee3a0)
# ===========================================================================
#
# Convex pieces in bucket-local coordinates (x from the center, y down from
# the rim top). Per side (left; right is mirrored): a flat top rim
# [hole/2, hole/2 + rim_w] x [0, rim_h], a ramp triangle from the rim's
# top-outer corner down to the level's lower border, and an inner block under
# the rim; a floor rectangle joins the sides under the opening. Order is
# fixed (bodies, floor, rims) because it is the iteration and tie-break order.
#
# Every arithmetic expression below keeps the Lua operand order; sqrt goes
# through DetMath like the Lua `detmath.sqrt`.

# make_piece: drop duplicate consecutive vertices (and a closing duplicate),
# reject fewer than 3 vertices or |area2| < 1e-9, then build edges with
# outward normals (away from the vertex centroid). `pts` is a flat
# (x1, y1, ...) tuple. Returns `nothing` for a degenerate piece.
function _bucket_make_piece(kind::UInt8,
                            pts::NTuple{N,Float64})::Union{Nothing,BucketPiece} where {N}
    verts = ntuple(_ -> 0.0, Val(8))
    k = 0
    for i in 1:2:N
        x = pts[i]
        y = pts[i + 1]
        if k == 0 || verts[k - 1] != x || verts[k] != y
            k + 2 <= 8 || throw(ArgumentError("bucket piece has more than 4 vertices"))
            verts = Base.setindex(verts, x, k + 1)
            verts = Base.setindex(verts, y, k + 2)
            k += 2
        end
    end
    if k >= 4 && verts[1] == verts[k - 1] && verts[2] == verts[k]
        verts = Base.setindex(verts, 0.0, k)
        verts = Base.setindex(verts, 0.0, k - 1)
        k -= 2
    end
    n = k ÷ 2
    n < 3 && return nothing
    nf = Float64(n)               # Lua `#verts / 2` is a float division

    area2 = 0.0
    cx = 0.0
    cy = 0.0
    for i in 1:n
        j = i % n + 1
        ax = verts[2 * i - 1]
        ay = verts[2 * i]
        bx = verts[2 * j - 1]
        by = verts[2 * j]
        area2 = area2 + ax * by - bx * ay
        cx = cx + ax
        cy = cy + ay
    end
    abs(area2) < 1e-9 && return nothing
    cx = cx / nf
    cy = cy / nf

    edges = ntuple(_ -> BUCKET_EDGE_ZERO, Val(4))
    m = 0
    for i in 1:n
        j = i % n + 1
        ax = verts[2 * i - 1]
        ay = verts[2 * i]
        dx = verts[2 * j - 1] - ax
        dy = verts[2 * j] - ay
        len = DetMath.det_sqrt(dx * dx + dy * dy)
        if len > 0
            ux = dx / len
            uy = dy / len
            nx = uy
            ny = -ux
            # Outward normal: away from the (interior) vertex centroid.
            if (ax - cx) * nx + (ay - cy) * ny < 0
                nx = -nx
                ny = -ny
            end
            m += 1
            edges = Base.setindex(edges, BucketEdge(ax, ay, ux, uy, nx, ny, len), m)
        end
    end
    return BucketPiece(kind, n, verts, m, edges)
end

# Lua `mirror`: negate every x.
@inline _bucket_mirror(pts::NTuple{N,Float64}) where {N} =
    ntuple(i -> isodd(i) ? -pts[i] : pts[i], Val(N))

@inline function _bucket_add_piece!(pieces::Vector{BucketPiece}, kind::UInt8,
                                    pts::NTuple{N,Float64}) where {N}
    p = _bucket_make_piece(kind, pts)
    p === nothing || push!(pieces, p)
    return nothing
end

# Bucket.build_pieces, written into the bucket's preallocated piece vector
# (capacity 7 is reserved at construction, so a rebuild never allocates).
function bucket_build_pieces!(bucket::BucketState)::Vector{BucketPiece}
    pieces = bucket.pieces
    empty!(pieces)
    hh = bucket.hole / 2
    rim_w = bucket.rim_width
    rim_h = bucket.rim_height
    depth = bucket.height
    bottom = depth + bucket.floor   # local y of the level's lower border
    rim_h = min(rim_h, bottom)
    ramp_w = bucket.ramp_width
    bucket.collision_half_span = hh + rim_w + ramp_w

    xi = -hh                        # inner edge (opening side)
    xo = xi - rim_w                 # outer edge of the flat rim (= ramp top)
    xr = xo - ramp_w                # foot of the ramp, on the lower border

    left_rim = (xi, 0.0, xo, 0.0, xo, rim_h, xi, rim_h)
    left_ramp = (xo, 0.0, xr, bottom, xo, bottom)
    left_inner = (xi, rim_h, xo, rim_h, xo, bottom, xi, bottom)
    floor = (-hh, depth, hh, depth, hh, bottom, -hh, bottom)

    _bucket_add_piece!(pieces, BUCKET_PIECE_BODY, left_ramp)
    _bucket_add_piece!(pieces, BUCKET_PIECE_BODY, _bucket_mirror(left_ramp))
    _bucket_add_piece!(pieces, BUCKET_PIECE_BODY, left_inner)
    _bucket_add_piece!(pieces, BUCKET_PIECE_BODY, _bucket_mirror(left_inner))
    _bucket_add_piece!(pieces, BUCKET_PIECE_FLOOR, floor)
    _bucket_add_piece!(pieces, BUCKET_PIECE_RIM, left_rim)
    _bucket_add_piece!(pieces, BUCKET_PIECE_RIM, _bucket_mirror(left_rim))
    return pieces
end

# piece_penetration: depth (> 0) and the outward push normal of a circle at
# (px, py) into a convex piece. Returns (hit, depth, nx, ny); hit = false is
# Lua's nil.
@inline function _bucket_piece_penetration(piece::BucketPiece, px::Float64,
                                           py::Float64, r::Float64)
    max_sd = -Inf
    mnx = 0.0
    mny = 0.0
    for k in 1:piece.nedges
        e = piece.edges[k]
        sd = (px - e.ax) * e.nx + (py - e.ay) * e.ny
        if sd > max_sd
            max_sd = sd
            mnx = e.nx
            mny = e.ny
        end
    end
    if max_sd <= 0
        # Center inside: leave through the nearest face.
        return (true, r - max_sd, mnx, mny)
    end
    best_d2 = Inf
    bdx = 0.0
    bdy = 0.0
    for k in 1:piece.nedges
        e = piece.edges[k]
        s = (px - e.ax) * e.ux + (py - e.ay) * e.uy
        if s < 0
            s = 0.0
        elseif s > e.len
            s = e.len
        end
        dx = px - (e.ax + e.ux * s)
        dy = py - (e.ay + e.uy * s)
        d2 = dx * dx + dy * dy
        if d2 < best_d2
            best_d2 = d2
            bdx = dx
            bdy = dy
        end
    end
    best_d2 >= r * r && return (false, 0.0, 0.0, 0.0)
    d = DetMath.det_sqrt(best_d2)
    return (true, r - d, bdx / d, bdy / d)
end

# sweep: earliest contact of a circle moving p0 -> p0 + m (t in [0, 1]) with
# any piece; assumes it starts separated. Returns (hit, t, nx, ny).
function _bucket_sweep(pieces::Vector{BucketPiece}, p0x::Float64, p0y::Float64,
                       mx::Float64, my::Float64, r::Float64)
    found = false
    best_t = 0.0
    bnx = 0.0
    bny = 0.0
    limit = 1.0
    A = mx * mx + my * my
    A <= 0 && return (false, 0.0, 0.0, 0.0)
    for piece in pieces
        # Faces: the edge line offset outward by r, within the edge's span.
        for k in 1:piece.nedges
            e = piece.edges[k]
            d0 = (p0x - e.ax) * e.nx + (p0y - e.ay) * e.ny - r
            dm = mx * e.nx + my * e.ny
            if d0 >= 0 && dm < 0
                t = d0 / -dm
                if t <= limit
                    cx = p0x + mx * t
                    cy = p0y + my * t
                    s = (cx - e.ax) * e.ux + (cy - e.ay) * e.uy
                    if s >= 0 && s <= e.len && (!found || t < best_t)
                        found = true
                        best_t = t
                        bnx = e.nx
                        bny = e.ny
                        limit = t
                    end
                end
            end
        end
        # Corners: circle of radius r around each vertex.
        verts = piece.verts
        for i in 1:2:(2 * piece.nverts)
            fx = p0x - verts[i]
            fy = p0y - verts[i + 1]
            C = fx * fx + fy * fy - r * r
            B = fx * mx + fy * my
            if C >= 0 && B < 0
                disc = B * B - A * C
                if disc >= 0
                    t = (-B - DetMath.det_sqrt(disc)) / A
                    if t >= 0 && t <= limit && (!found || t < best_t)
                        dx = fx + mx * t
                        dy = fy + my * t
                        d = DetMath.det_sqrt(dx * dx + dy * dy)
                        if d > 0
                            found = true
                            best_t = t
                            bnx = dx / d
                            bny = dy / d
                            limit = t
                        end
                    end
                end
            end
        end
    end
    return (found, best_t, bnx, bny)
end

# reflect: reflect the velocity along the contact normal (only if moving into
# the surface), with restitution.
@inline function _bucket_reflect!(ball::BallState, nx::Float64, ny::Float64,
                                  c::SimConfig)::Nothing
    dot = ball.vx * nx + ball.vy * ny
    if dot < 0
        e = 1 + c.restitution
        ball.vx = ball.vx - e * dot * nx
        ball.vy = ball.vy - e * dot * ny
    end
    return nothing
end

# separate: discrete push-out against the deepest overlapping piece, up to 4
# times. Returns true on contact.
function _bucket_separate!(pieces::Vector{BucketPiece}, bucket::BucketState,
                           ball::BallState, c::SimConfig)::Bool
    margin = c.overlap_push_margin
    hit = false
    for _ in 1:4
        px = ball.x - bucket.x
        py = ball.y - bucket.top
        best_depth = 0.0
        bnx = 0.0
        bny = 0.0
        for piece in pieces
            ok, depth, nx, ny = _bucket_piece_penetration(piece, px, py, ball.radius)
            if ok && depth > best_depth
                best_depth = depth
                bnx = nx
                bny = ny
            end
        end
        best_depth <= 0 && break
        hit = true
        ball.x = ball.x + bnx * (best_depth + margin)
        ball.y = ball.y + bny * (best_depth + margin)
        _bucket_reflect!(ball, bnx, bny, c)
    end
    return hit
end

function _bucket_overlaps_any(pieces::Vector{BucketPiece}, px::Float64,
                              py::Float64, r::Float64)::Bool
    for piece in pieces
        _bucket_piece_penetration(piece, px, py, r)[1] && return true
    end
    return false
end

# Bucket.in_catch_zone: center over the opening (between the rims' inner
# edges), within the catch depth. Bucket-local (px, py).
@inline function bucket_in_catch_zone(bucket::BucketState, px::Float64,
                                      py::Float64, r::Float64)::Bool
    return abs(px) <= bucket.hole / 2 &&
           py + r >= 0 &&
           py - r <= bucket.height
end

# 10ee3a0 Bucket.resolve: sweep the ball's step displacement (prev_* relative
# to bucket.prev_x -> current position relative to bucket.x) against the
# pieces; a contact with the center outside the opening bounces; otherwise a
# downward ball in the catch zone is caught; otherwise discrete push-out.
function ramp_bucket_resolve!(bucket::BucketState, ball::BallState,
                              c::SimConfig)::Symbol
    pieces = bucket.pieces
    r = ball.radius
    top = bucket.top
    hole_half = bucket.hole / 2

    bx1 = bucket.x
    bx0 = bucket.prev_x
    p1x = ball.x - bx1
    p1y = ball.y - top
    p0x = ball.prev_x - bx0
    p0y = ball.prev_y - top

    # Broad phase in the moving bucket's frame. Inflate by the radius plus
    # one pixel so only swept circles safely clear of every piece are skipped.
    slack = r + 1.0
    half_span = bucket.collision_half_span
    if max(p0y, p1y) < -slack ||
       min(p0x, p1x) > half_span + slack ||
       max(p0x, p1x) < -half_span - slack
        return :none
    end

    # Swept contact (only when the step started separated from the bucket).
    if !_bucket_overlaps_any(pieces, p0x, p0y, r)
        found, t, nx, ny = _bucket_sweep(pieces, p0x, p0y, p1x - p0x, p1y - p0y, r)
        if found
            cx = p0x + (p1x - p0x) * t
            cy = p0y + (p1y - p0y) * t
            # A contact with the center over the opening (clipping the rim's
            # inner corner on the way in) is a catch, not a bounce.
            if abs(cx) > hole_half
                margin = c.overlap_push_margin
                ball.x = bx1 + cx + nx * margin
                ball.y = top + cy + ny * margin
                _bucket_reflect!(ball, nx, ny, c)
                _bucket_separate!(pieces, bucket, ball, c)
                return :bounced
            end
        end
    end

    # Caught: the ball drops into the opening between the rims.
    if ball.vy > 0 && bucket_in_catch_zone(bucket, p1x, p1y, r)
        return :caught
    end

    # Resting / pushed contacts.
    _bucket_separate!(pieces, bucket, ball, c) && return :bounced
    return :none
end
