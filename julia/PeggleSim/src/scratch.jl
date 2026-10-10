# Per-worker scratch buffers and the M2 stand-in simulation step.
#
# `Scratch` owns reusable buffers so hot loops never allocate during a sweep;
# `WorkerState` owns one simulation plus its scratch and the zero-alloc
# gameplay event/command journals. `reset_worker!` restores the simulation
# from a checkpoint and refills the scratch buffers without aliasing any
# checkpoint-owned array.
#
# `test_advance!` is a deterministic M2 stand-in for a simulation advance:
# it mutates the step/shot counters, scoring arrays, one peg and one ball,
# consumes RNG draws, and performs purple promotions. It exists so the reset
# contract (capture -> mutate -> restore -> identical hash) is exercised
# before the real shot evaluator arrives in M3.

const SCRATCH_DEFAULTS = (
    peg_ids = 4096,
    ball_ids = 64,
    queue = 4096,
    active = 64,
    floats = 4096,
    ints = 4096,
)

_sized_vector(::Type{T}, capacity::Integer) where {T} =
    sizehint!(T[], max(0, Int(capacity)))

mutable struct Scratch
    "Peg ids reused by traversal kernels."
    peg_ids::Vector{Int}
    "Ball ids of the current shot."
    ball_ids::Vector{Int}
    "Working copy of the purple queue."
    queue::Vector{Int}
    "Working copy of the active purples."
    active::Vector{Int}
    "Generic float scratch."
    floats::Vector{Float64}
    "Generic integer scratch."
    ints::Vector{Int}
end

function Scratch(caps = SCRATCH_DEFAULTS)
    if caps isa Integer
        n = Int(caps)
        caps = (peg_ids = n, ball_ids = n, queue = n, active = n,
                floats = n, ints = n)
    end
    return Scratch(
        _sized_vector(Int, caps.peg_ids),
        _sized_vector(Int, caps.ball_ids),
        _sized_vector(Int, caps.queue),
        _sized_vector(Int, caps.active),
        _sized_vector(Float64, caps.floats),
        _sized_vector(Int, caps.ints),
    )
end

scratch_bytes(s::Scratch)::Int = Base.summarysize(s)

mutable struct WorkerState
    sim::SimState
    scratch::Scratch
    events::Vector{Any}
    commands::Vector{Any}
end

# `ckpt` is a Checkpoint (checkpoint.jl is included after this file; the
# annotation is deliberately left off so the include order stays as frozen).
function make_worker(ckpt, scratch_caps = SCRATCH_DEFAULTS)
    sim = sim_from_checkpoint(ckpt)
    worker = WorkerState(sim, Scratch(scratch_caps), Any[], Any[])
    return reset_worker!(worker, ckpt)
end

# Restore the worker simulation and refill scratch from the restored state.
# The checkpoint's arrays are copied element-wise; the worker never aliases
# checkpoint-owned storage.
function reset_worker!(w::WorkerState, ckpt)
    restore!(w.sim, ckpt)
    _refill_scratch!(w)
    empty!(w.events)
    empty!(w.commands)
    return w
end

function _refill_scratch!(w::WorkerState)
    s = w.scratch
    empty!(s.peg_ids)
    for p in w.sim.engine.pegs
        push!(s.peg_ids, p.id)
    end
    empty!(s.ball_ids)
    for b in w.sim.engine.balls
        push!(s.ball_ids, b.id)
    end
    empty!(s.queue)
    append!(s.queue, w.sim.colors.queue)
    empty!(s.active)
    append!(s.active, w.sim.colors.active)
    empty!(s.floats)
    empty!(s.ints)
    return s
end

function test_advance!(
    w::WorkerState;
    steps::Int,
    rng_draws::Int,
    purple_promotions::Int,
)
    e = w.sim.engine
    if steps > 0
        e.step_id += steps
        e.shot_id += 1
        e.hit_counter += steps
        e.bonus_score += Float64(steps)
        e.style_score += 2.0 * Float64(steps)
        if !isempty(e.pegs)
            peg = e.pegs[1]
            peg.hit = true
            peg.hit_order = e.hit_counter
            peg.multiplier_at_hit = e.current_multiplier
            push!(e.turn_pegs_hit, peg.id)
        end
        if !isempty(e.balls)
            ball = e.balls[1]
            ball.x += Float64(steps)
            ball.prev_x = ball.x
            ball.vx += 1.0
            ball.launched = true
        end
        push!(w.events, (kind = :step, step_id = e.step_id, shot_id = e.shot_id))
        push!(w.commands, (kind = :advance, steps = steps))
        push!(w.scratch.floats, Float64(steps))
    end
    for _ in 1:rng_draws
        random01(w.sim.rng)
    end
    if purple_promotions > 0
        assign_next_purple_pegs!(e.pegs, w.sim.colors, purple_promotions)
    end
    return w
end
