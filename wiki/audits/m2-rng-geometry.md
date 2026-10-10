# M2 audit: RNG parity, initialized geometry, reset determinism

Status: complete (2026-10-04). Machines: reference host only (see §5).

- RNG fixtures: `fixtures/rng/rng_sequences.v1.json`,
  `fixtures/rng/peg_colors.v1.json`
- Checkpoint fixtures: `fixtures/checkpoints/*.v1.json` (9 records)
- Classifier: `results/parity/local.json`
- Benchmark: `results/m2-checkpoint-bench.json`
- Commands: `make capture-m2-check`, `make julia-test`, `make julia-parity`

## 1. RNG fixture coverage

`fixtures/rng/rng_sequences.v1.json` pins the generator itself over 10 seeds:
`0, 1, 42, 123, 345, 20260918, 3735928559, 4294967295, 4294967296,
9007199254740991`. Each seed runs six operation groups in order
(`random(1,100)` ×8, `random(1,10)` ×8, `random(1,1)` ×4,
`random(2,1000000)` ×8, `random(1,1801)` ×8, `random01` ×8) and records
integer results, `random01` results as `0x%016x` float bits, the state after
the draws, and the next four `random01` bits. Three `set_state` cases pin
state restore followed by draws, and two seed anchors pin the M2 ground truth:
seed 345 draws `4,7,2,9,1,2,5,10` with state `0x7837ac8e69b05bb3`, and seed 0
`random(1,100)` returns 22 with state `0x5e15348974525b7a`.

`fixtures/rng/peg_colors.v1.json` covers color assignment per static level:

| Level | Seed | blue/green/purple/red | Initial queue | Rounds | Queue rebuilds |
| --- | ---: | --- | ---: | ---: | ---: |
| `circle_level` | 123 | 13/2/0/10 | 13 | 4 | 1 |
| `double_long_shot` | 345 | 0/0/0/12 | 0 | 1 | 0 |
| `long_shot` | 345 | 0/1/0/1 | 0 | 1 | 0 |
| `lucky_bounce` | 345 | 5/0/0/10 | 5 | 4 | 1 |
| `off_the_wall` | 345 | 4/2/0/10 | 4 | 4 | 1 |
| `slide` | 1 | 73/0/0/0 | 73 | 4 | 1 |
| `squiggly_circle` | 20260918 | 180/2/0/10 | 180 | 4 | 1 |
| `super_long_shot` | 345 | 0/1/0/1 | 0 | 1 | 0 |

Each record stores the full `peg_types` array in level order, the queue and
active sets after initialization and after the first promotion, and the RNG
state at both points. The scripted rounds mark pegs hit, call
`assign_next_purple_pegs`, and record `queue_before`/`active_before`,
`rebuilt`, `queue`/`active`, and before/after RNG state. Every blue-pegged
level rebuilds its queue at least once (round 4 drains the pre-built queue and
re-shuffles the survivors); the three no-blue levels exercise the
"no promotion possible" path. The fixture's RNG draws are produced by the
real reference generator, so any mapping or seeding error surfaces as a
mismatch at the first affected draw.

## 2. Initialized geometry and checkpoint byte parity

For each of the 9 configurations Julia runs `build_checkpoint(level, config)`
— artifact pegs → `init_colors!` → bucket/fever/ball state → `resetTurn`
equivalent with the first purple promotion — canonicalizes it, and compares
the bytes with the captured record. All 9 are byte-identical, including
`rng.state_b64`, the purple queue/active, bucket and fever bucket phase,
trackers, match state, and permanent ball-id allocation
(`fixtures/checkpoints/slide.multiball3.v1.json` covers 3 balls).

Checkpoint geometry hashes (canonical `checkpoint_sha256`, from
`results/parity/local.json`):

| Configuration | Level | Balls | Pegs | SHA-256 |
| --- | --- | ---: | ---: | --- |
| `circle_level` | `circle_level` | 1 | 25 | `5ee270042c373571fc9a158ee350dc62dd0aca5d6150d1dcd6bd503c4417ef89` |
| `double_long_shot` | `double_long_shot` | 1 | 12 | `289e0452a77e33f6e7a162850b5a70ae38d68bd578b7694603259875d8ec4a94` |
| `long_shot` | `long_shot` | 1 | 2 | `6208132e25fe657c8d6e5c3d1ba8fe6e6314a558ef654181e6a4e211e2a48883` |
| `lucky_bounce` | `lucky_bounce` | 1 | 15 | `97d8ff920c79993161338da791e40a1825a0ac5b4492672b6e28fac6271f71be` |
| `off_the_wall` | `off_the_wall` | 1 | 16 | `6692142def7d3b0f9f630781666d3d06b90c4d69b921649ba381ab28bc025dc4` |
| `slide` | `slide` | 1 | 73 | `6f987cf8a52e44b3934e3a80b803cb301ed1d1303f09c1260c324b6da977e008` |
| `slide.multiball3` | `slide` | 3 | 73 | `9899723e6841ae6c5a798b7721934ea165f019976703bd7ae88c81608fa8d6a0` |
| `squiggly_circle` | `squiggly_circle` | 1 | 192 | `7ff26f8b6188bb02de133dead051efa8816b8ab729a4b20d909c57dc03eeaf7a` |
| `super_long_shot` | `super_long_shot` | 1 | 2 | `a2d8079bc5eb1b43a9310108594a9453ee739646f8e8e2b31492ac324c529e7f` |

RNG fixture hashes pinned by the manifest:
`rng_sequences_sha256 f105d119...bec02`,
`peg_colors_sha256 456552bc...02032`.

## 3. Reset determinism and aliasing

The parity manifest runs, per configuration, `capture -> test_advance!
(steps = 7, rng_draws = 5, purple_promotions = 1) -> reset_worker! ->
capture` twice and records both hashes. All 9 pairs are equal
(`reset_deterministic = true`). The unit suite repeats this over multiple
cycles and checks that the mutated checkpoint hash differs from the original
before restore (`test/test_checkpoint.jl`).

Aliasing evidence (`test/test_checkpoint.jl` §"restore and capture do not
alias"): after restoring, mutating peg type/position, ball position,
`used_ball_ids`, `turn_pegs_hit`, the purple queue/active, and tracker maps
leaves the checkpoint hash unchanged; symmetrically, mutating a captured
checkpoint's arrays, queue, and trackers leaves the originating simulation
recapture hash unchanged. `reset_worker!` copies every checkpoint-owned
array, so no worker references mutable state owned by another worker or by
the checkpoint.

## 4. Checkpoint memory and reset cost

`results/m2-checkpoint-bench.json` records per configuration: checkpoint
bytes (`Base.summarysize` of the `Checkpoint`), scratch bytes, worker bytes,
and reset p50. Dominant sizes: `squiggly_circle` checkpoint 41,024 B with
192 pegs; `slide` 17,017 B and `slide.multiball3` 17,177 B with 73 pegs;
`circle_level` 6,213 B. Scratch is a constant 132,384 B per worker and worker
totals range 136,457–184,303 B. Reset p50 stays 5.7–13.9 µs across all
configurations; details and the M0 comparison are in
`wiki/benchmarks/m2-checkpoint.md`.

## 5. Cross-machine status

As in the math census audit, no second physical host was reachable
(`deathstar` DNS failed). The geometry/reset evidence above comes from one
host plus two independently generated local parity manifests (the unit suite
builds and compares them) and the `scripts/compare_parity.sh` tooling. The
manifest's `authoritative` section contains no host data, so a future second
host can be compared with `make julia-parity` + `compare_parity.sh` without
re-capturing anything; that run is still outstanding.
