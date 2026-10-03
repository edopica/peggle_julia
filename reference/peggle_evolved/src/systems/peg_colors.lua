--- peg_colors.lua — Deterministic peg type assignment & purple-peg queue.
--
-- This system handles two responsibilities:
--   1. Assigning peg types (blue, red, green, purple) from a shuffled pool
--      so that the exact number of each type matches the level config.
--   2. Managing a "purple queue" that rotates one or more active purple pegs
--      on a turn-by-turn basis, controlled by Config.purple_pegs_per_turn.
--
-- Determinism guarantee: all randomness flows through a single
-- love.math.newRandomGenerator seeded once at initialisation.
-- No math.random, no os.time, no pairs() on ordered data.

local Config = require("src.config")
local PegColors = {}

---------------------------------------------------------------------------
-- Internal state (reset on each call to PegColors.init)
---------------------------------------------------------------------------
local rng              -- love RandomGenerator instance
local all_pegs         -- reference to the live pegs array from main
local purple_queue     -- array of peg references (blue pegs, in shuffle order)
local active_purples   -- array of pegs currently promoted to purple

---------------------------------------------------------------------------
-- Fisher-Yates (Knuth) in-place shuffle — uses our seeded RNG only.
-- Iterates from the end to guarantee uniform distribution.
---------------------------------------------------------------------------
local function fisher_yates(arr)
    for i = #arr, 2, -1 do
        local j = rng:random(1, i)
        arr[i], arr[j] = arr[j], arr[i]
    end
end

---------------------------------------------------------------------------
-- PegColors.init(pegs, type_counts, seed)
--
-- Assigns peg types deterministically and prepares the purple queue.
--
-- @param pegs        Array of peg tables (must already have x, y, radius).
--                    The table is iterated with ipairs so insertion order
--                    determines assignment order.
-- @param type_counts Table with keys "red", "green", "purple", "blue",
--                    each mapping to the desired count for that type.
--                    The sum of all counts MUST equal #pegs.
-- @param seed        Integer seed for the RNG.
---------------------------------------------------------------------------
function PegColors.init(pegs, type_counts, seed)
    -- 1. Seed our private RNG ------------------------------------------------
    rng = love.math.newRandomGenerator(seed)

    -- Keep a reference to the live pegs array so we can rebuild the purple
    -- queue later from whatever blue pegs still exist on the board.
    all_pegs = pegs

    -- 2. Build the colour pool ------------------------------------------------
    --    We iterate the type list in a fixed, alphabetical order so the pool
    --    construction itself is deterministic regardless of table hashing.
    local ordered_types = { "blue", "green", "purple", "red" }
    local pool = {}
    for _, type_name in ipairs(ordered_types) do
        local count = type_counts[type_name] or 0
        for _ = 1, count do
            pool[#pool + 1] = type_name
        end
    end

    assert(#pool == #pegs,
        string.format(
            "peg_colors: pool size (%d) does not match peg count (%d)",
            #pool, #pegs))

    -- 3. Shuffle the pool with Fisher-Yates -----------------------------------
    fisher_yates(pool)

    -- 4. Assign types to pegs in list order -----------------------------------
    for i, peg in ipairs(pegs) do
        peg.type = pool[i]
    end

    -- 5. Build the purple queue from all BLUE pegs ----------------------------
    --    Only blue pegs are eligible to be promoted to purple on future turns.
    purple_queue = {}
    for _, peg in ipairs(pegs) do
        if peg.type == "blue" then
            purple_queue[#purple_queue + 1] = peg
        end
    end

    fisher_yates(purple_queue)

    -- 6. No active purple pegs until the first call to assign_next_purple_pegs.
    active_purples = {}
end

---------------------------------------------------------------------------
-- rebuild_purple_queue()
--
-- Repopulates the queue from all pegs currently on the board that are
-- blue and un-hit.  Called automatically when the queue runs empty but
-- live blue pegs still exist.
--
-- Pegs that are currently active purple (already promoted this turn) have
-- type == "purple", so the type == "blue" check naturally excludes them.
---------------------------------------------------------------------------
local function rebuild_purple_queue()
    purple_queue = {}
    for _, peg in ipairs(all_pegs) do
        if peg.type == "blue" and not peg.hit then
            purple_queue[#purple_queue + 1] = peg
        end
    end
    fisher_yates(purple_queue)
end

---------------------------------------------------------------------------
-- PegColors.assign_next_purple_pegs()
--
-- Called at the start of every new turn / round.
--
-- • Reverts ALL currently active purple pegs back to blue.
-- • Promotes up to Config.purple_pegs_per_turn pegs from the queue.
-- • If the queue empties mid-promotion, rebuilds it from surviving blue
--   pegs and continues.  Stops only when no blue pegs remain at all.
---------------------------------------------------------------------------
function PegColors.assign_next_purple_pegs()
    -- Revert every active purple peg back to blue.
    for _, peg in ipairs(active_purples) do
        if peg.type == "purple" then
            peg.type = "blue"
        end
    end
    active_purples = {}

    local count = Config.purple_pegs_per_turn or 1
    local promoted = 0

    while promoted < count do
        -- Drain dead (already-hit) candidates from the front.
        while #purple_queue > 0 and purple_queue[1].hit do
            table.remove(purple_queue, 1)
        end

        -- If the queue is empty, try to refill from surviving blue pegs.
        if #purple_queue == 0 then
            rebuild_purple_queue()
            if #purple_queue == 0 then
                break -- no blue pegs left on the board at all
            end
        end

        local candidate = table.remove(purple_queue, 1)
        candidate.type = "purple"
        active_purples[#active_purples + 1] = candidate
        promoted = promoted + 1
    end
end

-- Backward-compatible alias for callers that used the singular name.
PegColors.assign_next_purple_peg = PegColors.assign_next_purple_pegs

---------------------------------------------------------------------------
-- PegColors.is_active_purple(peg)
--
-- Returns true if the given peg is one of the currently promoted purples.
---------------------------------------------------------------------------
function PegColors.is_active_purple(peg)
    for _, p in ipairs(active_purples) do
        if p == peg then
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- PegColors.on_purple_peg_hit(peg)
--
-- Called when the ball collides with one of the active purple pegs.
-- Removes the peg from the active list.  No immediate re-promotion:
-- new purple pegs are only assigned at the start of the next turn.
--
-- The peg has already been consumed from purple_queue at promotion
-- time, so no queue removal is needed here.
--
-- @param peg  The peg that was hit.  Must be in active_purples;
--             silently ignored otherwise.
---------------------------------------------------------------------------
function PegColors.on_purple_peg_hit(peg)
    for i, p in ipairs(active_purples) do
        if p == peg then
            table.remove(active_purples, i)
            return
        end
    end
end

---------------------------------------------------------------------------
-- PegColors.on_peg_removed(peg)
--
-- Called when a peg is removed from the board for any reason OTHER than a
-- direct hit (e.g., it fell into the bucket, or was swept by end-of-turn
-- clearing without being an active purple peg).
--
-- If the removed peg happens to be in the purple queue or the active list,
-- purge it so we never try to promote a ghost peg.
---------------------------------------------------------------------------
function PegColors.on_peg_removed(peg)
    -- Remove from active list if present.
    for i, p in ipairs(active_purples) do
        if p == peg then
            table.remove(active_purples, i)
            break
        end
    end

    -- Remove from anywhere in the queue.
    for i = #purple_queue, 1, -1 do
        if purple_queue[i] == peg then
            table.remove(purple_queue, i)
            break -- each peg appears at most once
        end
    end
end

---------------------------------------------------------------------------
-- Accessors (read-only)
---------------------------------------------------------------------------

--- Returns the array of pegs currently promoted to purple (may be empty).
function PegColors.get_active_purples()
    return active_purples
end

--- Returns the number of pegs still in the purple queue.
function PegColors.get_purple_queue_size()
    return #purple_queue
end

return PegColors
