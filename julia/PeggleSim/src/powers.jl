# Port of src/systems/powers.lua (dev tree @ da752257).
#
# Powers.activate is called by the Engine during the authoritative peg-hit
# reduction phase for a green peg. It returns ball spawn specs; the Engine
# creates, registers (stable ids), and stages the spawned balls so they begin
# physics on the following fixed step.
#
# The Lua source is pure arithmetic on peg.x/peg.y: it consumes no RNG (no
# `love.math.random` call site exists) and no Config value, so no LoveRandom
# object is involved. The frozen M3 signature carries `c::SimConfig` for
# uniformity; it is intentionally unused.

struct PowerSpawnSpec
    x::Float64
    y::Float64
    vx::Float64
    vy::Float64
end

# Two balls spawn 10 px above the green peg: leftward and rightward at 150
# px/s, both rising at 200 px/s. Literal order and values mirror the Lua table.
function powers_activate(peg::Peg, c::SimConfig)::Vector{PowerSpawnSpec}
    return PowerSpawnSpec[
        PowerSpawnSpec(peg.x, peg.y - 10.0, 150.0, -200.0),
        PowerSpawnSpec(peg.x, peg.y - 10.0, -150.0, -200.0),
    ]
end
