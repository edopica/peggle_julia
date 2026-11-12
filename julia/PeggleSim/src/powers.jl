# Port of src/systems/powers.lua (dev tree @ da752257; 10ee3a0 one-ball
# multiball under RULES_RAMP_BUCKET).
#
# Powers.activate is called by the Engine during the authoritative peg-hit
# reduction phase for a green peg. It returns ball spawn specs; the Engine
# creates, registers (stable ids), and stages the spawned balls so they begin
# physics on the following fixed step.
#
# The Lua source is pure arithmetic on peg.x/peg.y: it consumes no RNG (no
# `love.math.random` call site exists) and no Config value, so no LoveRandom
# object is involved. `c.rules` selects the spawn list (the only Config read):
#
#   RULES_CLASSIC      two balls (the pinned behavior);
#   RULES_RAMP_BUCKET  exactly ONE ball, the first spec of the classic list
#                      (10ee3a0 "fix multiball").

struct PowerSpawnSpec
    x::Float64
    y::Float64
    vx::Float64
    vy::Float64
end

# Spawn specs 10 px above the green peg, rising at 200 px/s: rightward at 150
# px/s, then (classic only) leftward. Literal order and values mirror the Lua
# table. Appends to `dest` (the engine's reused pending-spawn vector), so the
# per-hit path allocates nothing once the vector has grown.
function powers_activate!(dest::Vector{PowerSpawnSpec}, peg::Peg,
                          c::SimConfig)::Vector{PowerSpawnSpec}
    push!(dest, PowerSpawnSpec(peg.x, peg.y - 10.0, 150.0, -200.0))
    if c.rules === RULES_CLASSIC
        push!(dest, PowerSpawnSpec(peg.x, peg.y - 10.0, -150.0, -200.0))
    end
    return dest
end

# Powers.activate: a fresh spec list (API/tests; the engine uses the in-place
# form above).
function powers_activate(peg::Peg, c::SimConfig)::Vector{PowerSpawnSpec}
    return powers_activate!(PowerSpawnSpec[], peg, c)
end
