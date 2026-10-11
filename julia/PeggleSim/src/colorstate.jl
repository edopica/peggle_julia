# Deterministic peg colour assignment and the purple-promotion queue.
#
# Exact port of reference/peggle_evolved/src/systems/peg_colors.lua:
#   * the pool is built in the fixed order blue, green, purple, red;
#   * the pool is shuffled with LÖVE Fisher-Yates `for i = n:-1:2` using
#     `rng:random(1, i)`;
#   * types are assigned to pegs in engine order;
#   * the queue is built from blue pegs in engine order and shuffled the same
#     way, using the same generator;
#   * `assign_next_purple_pegs!` reverts active purples to blue, then drains
#     hit queue heads, rebuilds the queue from surviving blue pegs when it
#     empties (engine order, same Fisher-Yates), and stops when no blue pegs
#     remain.
#
# The Lua module keeps the generator in a module-local. The port stores the
# same generator on the color state so the three-argument
# `assign_next_purple_pegs!(pegs, cs, per_turn)` signature can rebuild the
# queue with exactly the reference draws. `queue` and `active` hold peg ids.

mutable struct ColorState
    queue::Vector{Int}
    active::Vector{Int}
    rng::Union{Nothing,LoveRandom}
end

ColorState(queue::Vector{Int}, active::Vector{Int}) = ColorState(queue, active, nothing)

function _fisher_yates!(rng::LoveRandom, items::Vector{T}) where {T}
    for i in length(items):-1:2
        j = random(rng, 1, i)
        items[i], items[j] = items[j], items[i]
    end
    return items
end

_type_count(type_counts, name::Symbol) = if type_counts isa NamedTuple
    hasproperty(type_counts, name) ? getfield(type_counts, name) : 0
else
    get(type_counts, name, get(type_counts, String(name), 0))
end

function init_colors!(
    pegs::Vector{Peg},
    type_counts,
    seed::Integer,
    rng::LoveRandom,
)::ColorState
    pool = Symbol[]
    for type_name in CANONICAL_TYPE_ORDER
        count = _type_count(type_counts, type_name)
        count >= 0 || throw(ArgumentError(
            "peg_colors: negative count for '$(type_name)': $(count)"))
        for _ in 1:count
            push!(pool, type_name)
        end
    end
    length(pool) == length(pegs) || throw(DimensionMismatch(string(
        "peg_colors: pool size (", length(pool), ") does not match peg count (",
        length(pegs), ")")))

    _fisher_yates!(rng, pool)
    for (i, peg) in enumerate(pegs)
        peg.peg_type = pool[i]
    end

    queue = Int[]
    for peg in pegs
        peg.peg_type === :blue && push!(queue, peg.id)
    end
    _fisher_yates!(rng, queue)

    return ColorState(queue, Int[], rng)
end

function assign_next_purple_pegs!(pegs::Vector{Peg}, cs::ColorState, per_turn::Int)
    by_id = Dict(p.id => p for p in pegs)

    # Revert every active purple peg back to blue.
    for id in cs.active
        peg = get(by_id, id, nothing)
        if peg !== nothing && peg.peg_type === :purple
            peg.peg_type = :blue
        end
    end
    empty!(cs.active)

    promoted = 0
    while promoted < per_turn
        # Drain dead (already-hit) candidates from the front.
        while !isempty(cs.queue) && by_id[cs.queue[1]].hit
            popfirst!(cs.queue)
        end

        if isempty(cs.queue)
            rng = cs.rng
            rng === nothing && throw(ArgumentError(
                "assign_next_purple_pegs!: queue rebuild requires ColorState.rng"))
            for peg in pegs
                if peg.peg_type === :blue && !peg.hit
                    push!(cs.queue, peg.id)
                end
            end
            _fisher_yates!(rng, cs.queue)
            isempty(cs.queue) && break # no blue pegs left on the board at all
        end

        candidate = popfirst!(cs.queue)
        by_id[candidate].peg_type = :purple
        push!(cs.active, candidate)
        promoted += 1
    end
    return cs
end

function purple_queue_snapshot(cs::ColorState)::NamedTuple
    return (queue = copy(cs.queue), active = copy(cs.active))
end

# PegColors.on_purple_peg_hit (peg_colors.lua lines 189-196): the hit purple
# peg leaves the active list. No immediate re-promotion and no queue removal
# (the peg was consumed from the queue at promotion time).
function on_purple_peg_hit!(cs::ColorState, peg::Peg)
    i = findfirst(==(peg.id), cs.active)
    i === nothing || deleteat!(cs.active, i)
    return cs
end

# PegColors.on_peg_removed (lines 208-224): purge a removed peg from the
# active list and from anywhere in the queue so it can never be promoted.
function on_peg_removed!(cs::ColorState, peg::Peg)
    i = findfirst(==(peg.id), cs.active)
    i === nothing || deleteat!(cs.active, i)
    for j in length(cs.queue):-1:1
        if cs.queue[j] == peg.id
            deleteat!(cs.queue, j)
            break # each peg appears at most once
        end
    end
    return cs
end
