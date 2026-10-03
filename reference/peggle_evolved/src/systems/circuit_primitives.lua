local CircuitPrimitives = {}

CircuitPrimitives.primitives = {
    ellipse = function(t, p)
        return math.cos(t) * p.amp_x, math.sin(t) * p.amp_y, (p.rotate and t or 0)
    end,

    oscillate_x = function(t, p)
        local f = p.frequency or 1
        return math.sin(t * f) * p.amp, 0, 0
    end,

    oscillate_y = function(t, p)
        local f = p.frequency or 1
        return 0, math.sin(t * f) * p.amp, 0
    end,

    rotate = function(t, p)
        return 0, 0, t * (p.speed_angular or 1)
    end,

    cos_ellipse = function(t, p)
        -- cos-based ellipse (phase-shifted from ellipse)
        return math.cos(t) * p.amp_x, math.cos(t) * p.amp_y, (p.rotate and t or 0)
    end,

    line = function(t, p)
        local angle = p.angle or 0
        local d = math.sin(t) * p.amp
        return math.cos(angle) * d, math.sin(angle) * d, 0
    end,

    -- Absolute world-space position along a compiled, closed Path. `t` is a
    -- distance in pixels; it wraps into [0, path:length()) so negative and
    -- multi-loop phases address the same point. The returned translation is
    -- already in world space and must not receive a peg base offset.
    path = function(t, p)
        local length = p.path:length()
        local s = t % length
        if s < 0 then s = s + length end
        local x, y = p.path:at_distance(s)
        return x, y, 0
    end,
}

-- Single classification point for absolute primitives: their eval result is a
-- world-space position, not an offset added to the peg base.
function CircuitPrimitives.is_absolute(def)
    return def.kind == "path"
end

-- Evaluate a circuit definition at time t.
-- def must have: kind (string), speed (number), and any
-- primitive-specific parameters.
function CircuitPrimitives.eval(def, t)
    local fn = CircuitPrimitives.primitives[def.kind]
    if not fn then
        error("Unknown circuit primitive: " .. tostring(def.kind))
    end
    return fn(t, def)
end

return CircuitPrimitives
