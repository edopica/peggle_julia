# Audit 001: Deterministic Peg Color Assignment & Rotation Queue

## 1. Overview
This audit verifies the peg color assignment subsystem implemented in `src/systems/peg_colors.lua`, covering initial pool shuffling, purple peg rotation queues, and deterministic seeding logic.

## 2. System Architecture

### A. Initial Pool Shuffling
1. Level configurations supply a `type_counts` table (e.g. 25 red pegs, 2 green pegs, remainder blue pegs).
2. The subsystem generates an array of type strings corresponding to total peg count.
3. Fisher-Yates shuffle is performed using a dedicated `love.math.newRandomGenerator(seed)` instance.
4. Colors are assigned sequentially to pegs based on index.

### B. Turn-by-Turn Purple Peg Queue
1. All pegs assigned `blue` during initial pool generation form the purple candidate queue.
2. The candidate list is shuffled deterministically at level start.
3. On `resetTurn()`, the active purple peg(s) cycle based on `Config.purple_pegs_per_turn`.
4. If a purple peg is hit and removed during a turn, it is dropped from future queue rotations.

## 3. Determinism Verification
- Replays with identical level seeds produce 100% identical peg color distributions.
- Queue progression is independent of framerate or rendering order.
