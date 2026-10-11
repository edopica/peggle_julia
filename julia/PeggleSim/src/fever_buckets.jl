# Port of src/entities/fever_buckets.lua (dev tree @ da752257).
#
# The constructor state (five value segments, six radius-40 dividers) lives in
# state.jl as FeverBucketsState. This file ports the shot-time behavior:
# activate raises the bank off-screen, update animates it up at
# Config.fever_bucket_raise_speed with the dividers following `top`, and
# resolve returns the segment value under the ball (or the 10000 fallback
# inside the divider gaps). The ultra-fever value override lives in
# core.lua's step (Engine) and is not this module's concern.
#
# Lua `FeverBuckets.resolve` returns nil for "no interaction"; the frozen
# Julia interface maps that to (result = :none, value = 0.0).

# FeverBuckets.activate: top jumps below the screen, then animates upward.
# This is the same state transition as state.jl's activate_fever_buckets!
# (used by update_multiplier! when the multiplier reaches 100).
function fever_activate!(f::FeverBucketsState)::Nothing
    activate_fever_buckets!(f)
    return nothing
end

# FeverBuckets.update: no-op unless animating; clamp at target_top and stop.
function fever_update!(f::FeverBucketsState, dt::Float64,
                       c::SimConfig)::Nothing
    if !f.animating
        return nothing
    end

    f.top = f.top - c.fever_bucket_raise_speed * dt

    for d in f.dividers
        d.y = f.top
    end

    if f.top <= f.target_top
        f.top = f.target_top
        f.animating = false
        for d in f.dividers
            d.y = f.top
        end
    end
    return nothing
end

# FeverBuckets.resolve: a downward-moving ball below the bank line scores the
# segment containing its x (in bucket order); the divider gaps and the outer
# margins fall back to 10000.
function fever_resolve!(f::FeverBucketsState,
                        ball::BallState)::NamedTuple
    if ball.y > f.top && ball.vy > 0
        for b in f.buckets
            if ball.x >= b.x && ball.x <= b.x + b.width
                return (result = :caught, value = b.value)
            end
        end
        return (result = :caught, value = 10000.0)
    end
    return (result = :none, value = 0.0)
end
