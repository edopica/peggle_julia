# Port of src/entities/bucket.lua (dev tree @ da752257, detmath routing).
#
# The Lua entity reads `LevelManager.virtual_width` (the level's resolved
# virtual width, which the level artifact may override: mustache is 880x550
# while Config carries 1200x1900). The frozen M3 interface maps that read to
# `c.virtual_width`; the four-argument overload takes the level width
# explicitly so the engine can pass `ShotEngine.virtual_width` and stay
# bit-exact with the Lua reference on levels that override the default.
# `Bucket.update` never touches `prev_x` (Engine:savePreviousState does), so
# neither method does either.

# Half the total span of the bucket (hole plus both edges), from its center.
function bucket_half_span(bucket::BucketState)::Float64
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
# mapping is :caught | :bounced | :none. The catch check runs first, so a ball
# inside the hole span is never resolved against the walls.
function bucket_resolve!(bucket::BucketState, ball::BallState,
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
