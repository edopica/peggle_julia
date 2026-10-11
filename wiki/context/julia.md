# Julia package: M2 state foundation and M3 shot engine

Durable technical notes for the Julia code in the port (M2 and M3). This page
covers the pinned package, the deterministic math backend, the exact LÖVE 11.5
RNG, the level/config/state types, the ready-to-aim initialization pipeline,
the checkpoint contract, per-worker ownership, and the provenance conventions
the parity manifests rely on. Section 10 covers the M3 full-physics shot
engine.

The Lua-side formats and the decision boundary are defined in
`wiki/context/interchange.md` and `wiki/context/reference.md`; the measured M2
results are in `results/m2-math-census.json`,
`results/m2-checkpoint-bench.json`, and `results/parity/local.json`. The M3
results are in `results/m3/` (see `wiki/benchmarks/m3-shot.md`).

## 1. Package and pinned environment

The package is `julia/PeggleSim/` (module `PeggleSim`, version `0.1.0`).
`Project.toml` and `Manifest.toml` are committed together and form the pinned
environment: `julia_version = "1.12.6"`, `manifest_format = "2.0"`.

| Dependency | Role |
| --- | --- |
| `JSON` 0.21.4 | `JSON.parsefile` for artifacts and fixtures |
| `Base64` (stdlib) | `rng.state_b64` encoding |
| `Libdl` (stdlib) | dynamic loading of the `core_math` native component |
| `Printf` (stdlib) | `%.17g` canonical float formatting |
| `SHA` (stdlib) | artifact/checkpoint hashing |
| `Test` (extras) | test target only |

No other runtime dependency may be added without revisiting this pin.

```bash
julia --project=julia/PeggleSim -e 'using Pkg; Pkg.instantiate()'
julia --project=julia/PeggleSim -e 'using Pkg; Pkg.test()'   # 4722 pass, 0 fail
```

Source files are included in this fixed order by `src/PeggleSim.jl`:

| File | Contents |
| --- | --- |
| `src/detmath.jl` | `DetMath`: deterministic math backends |
| `src/rng.jl` | `LoveRandom`: exact LÖVE 11.5 generator |
| `src/canonical.jl` | canonical JSON encoder and hashing |
| `src/jsonio.jl` | typed accessors, `CANONICAL_TYPE_ORDER` |
| `src/config.jl` | `SimConfig` from `interchange/config.v1.json` |
| `src/level.jl` | `LevelDefinition`/`Peg` from level artifacts |
| `src/colorstate.jl` | `ColorState`, `PegColors` port |
| `src/state.jl` | bucket/ball/tracker/match/engine/sim state |
| `src/scratch.jl` | `Scratch`, `WorkerState`, `test_advance!` |
| `src/checkpoint.jl` | `Checkpoint` capture/encode/decode/restore |
| `src/parity.jl` | cross-machine manifest and configuration list |

The M3 block (`src/events.jl` through `src/engine.jl`, 12 files) is included
after `checkpoint.jl` and before `parity.jl`. Its file map is in §10.

## 2. DetMath: deterministic math backends

`DetMath` routes every authoritative call site through one of three explicit
backends. The backend is chosen once, at module initialization, from the
environment variable `PEGGLE_MATH_BACKEND`. It is read in `__init__`, never at
precompile time, so one precompiled image serves every backend:

- `system_libm` (default on Linux): `ccall` into `libm.so.6`, the same C
  library LuaJIT uses, so results are bit-identical on the reference platform;
- `core_math` (experimental; adoption undecided): the pinned shared native
  component under `native/artifacts/<platform>/` (platform filename:
  `libpeggle_math.so`, `peggle_math.dll`, or `libpeggle_math.dylib`), ABI 1,
  loaded with `Libdl.dlopen` and called through `dlsym`'d function pointers.
  The path can be overridden with `PEGGLE_MATH_LIB`. A missing library, a
  missing symbol, or a wrong ABI is a hard startup error with no fallback;
- `julia_base` (default elsewhere): Julia runtime `Base` math (`Base.sin`,
  ...). This is not a claim about a pinned implementation: the identity
  reports `Base.Math.libm` as the library name and makes no version claim.
  `openlibm` is accepted as a backward-compatible alias and is always reported
  as `julia_base`.

Unknown `PEGGLE_MATH_BACKEND` values throw at load. The `core_math` platform
tags are `linux-x86_64`, `darwin-aarch64`, and `windows-x86_64` (from
`Sys.islinux`/`Sys.isapple`/`Sys.iswindows` and `Sys.ARCH`); the repository
root is derived from the package location.

Interface (all `Float64` in/out): `det_sin`, `det_cos`, `det_atan`,
`det_atan2(y, x)`, `det_asin`, `det_acos`, `det_tan`, `det_exp`, `det_log`,
`det_pow(a, b)`, `det_sqrt`, plus `lua_mod(a, b) = a - floor(a/b)*b` (Lua's
floored modulo; C `fmod` and Julia `rem` truncate and must not be used).

`math_backend_identity()` returns `(backend, library, platform, abi_version,
artifact_sha256, core_math_revision, core_math_tag, glibc, julia)`;
inapplicable fields are `nothing`. `math_backend_identity_dict()` is the
JSON-ready view used by the parity `environment` section, the checkpoint
benchmark, and the census summary.

Rules for the authoritative path: no `@fastmath`, no `@simd`, no `@turbo`, no
`muladd`, no `fma`. `test/test_detmath.jl` scans the sources for all five.
The backend policy and its measured divergence rates are recorded in
`wiki/decisions/0001-math-backend.md` (amended for WP-C); the census is
audited in `wiki/audits/m2-math-census.md`.

## 3. RNG: exact LÖVE 11.5 port

`src/rng.jl` ports `love.math.RandomGenerator` from LÖVE 11.5:

- `wang_hash64(key)` is the Thomas Wang 64-bit hash, byte-for-byte the C++
  implementation;
- `LoveRandom(seed)`: `s = trunc(UInt64, seed_double)`, then
  `do s = wang_hash64(s) while s == 0; state = s`, `last_randomnormal = Inf`;
- `rand_u64!`: xorshift64* with shifts 12/25/27 and multiplier
  `0x2545F4914F6CDD1D`;
- `random01`: `reinterpret(Float64, 0x3FF0000000000000 | (rand_u64!() >> 12)) - 1.0`;
- integer mapping: `random(r, max) = Int(floor(random01(r) * max)) + 1`;
  `random(r, lo, hi) = Int(floor(random01(r) * (hi - lo + 1))) + lo`;
- `get_state`/`set_state!`: `"0x"` + 16 lowercase hex digits; `set_state!`
  resets `last_randomnormal`;
- `random_normal(r, stddev)`: LÖVE Box-Muller with the `Inf` cache sentinel,
  consuming two `random01` draws; `sqrt`/`log`/`sin`/`cos` go through
  `DetMath`;
- `snapshot`/`restore!` copy seed, state, and cache for worker-local use.

Ground truth from LÖVE 11.5 is pinned in `fixtures/rng/rng_sequences.v1.json`
(10 seeds, integer/`random01`/state/set-state cases; seed 345 draws
4,7,2,9,1,2,5,10 and state `0x7837ac8e69b05bb3`) and in
`fixtures/rng/peg_colors.v1.json`. Coverage is audited in
`wiki/audits/m2-rng-geometry.md`.

## 4. Level and config types

`load_config(path)` parses `interchange/config.v1.json` into the immutable
`SimConfig` struct: every value key is an explicit typed field with the same
name (`c.fixed_dt`, `c.gravity`, `c.purple_pegs_per_turn`, ...), nested
`peg_types`/colors become typed structs and tuples, and the loader rejects
unknown or missing keys (`CONFIG_VALUE_KEYS`) because that means the pinned
reference changed.

`load_level(path)` parses `interchange/levels/<name>.v1.json` into
`LevelDefinition`:

- `name`, `virtual_width`, `virtual_height`, `level_seed`,
  `type_counts::NamedTuple{(:blue,:green,:purple,:red)}`,
  `default_peg_type`, `provenance`, `level_sha256`;
- `pegs::Vector{Peg}` in engine order; `Peg` carries `id`, live and `base_`
  positions, a `CircleShape`/`RectangleShape`/`AnnularShape`, mutable
  `peg_type`, `hit`/`hit_order`/`multiplier_at_hit`, and optional
  `LineMetadata` (`id` is the authored string);
- peg ids must be contiguous and equal to their 1-based index;
- `motion != "static"` and any circuit key are hard errors (v1 static subset).

`src/jsonio.jl` provides strict `as_f64`/`as_int`/`as_bool`/`as_string`/
`as_array`/`as_object` accessors and the frozen type order
`(blue, green, purple, red)`. `test/test_level.jl` checks bit-exact float
round-tripping from `%.17g` text, matching the canonical encoder.

## 5. Ready-to-aim initialization pipeline

`build_sim_state(level, config; balls = 1, mode = :solo)` builds the
checkpoint boundary state, equivalent to `Engine:setupLevel` + `resetTurn`:

1. copy artifact pegs in order (`base_x/base_y` = artifact position);
2. `rng = LoveRandom(level.level_seed)`;
3. `init_colors!(pegs, level.type_counts, level_seed, rng)`: build the pool in
   `(blue, green, purple, red)` order, LÖVE Fisher-Yates with
   `random(1, i)` for `i = n:-1:2`, assign to pegs in engine order, then build
   and shuffle the blue-id queue with the same generator;
4. construct `BucketState` (centered, `phase = pi/2`) and `FeverBucketsState`
   (five `vw/5` segments, radius-40 dividers);
5. place balls: one ball at `(virtual_width/2, 50)`; for `n > 1` balls
   `x_i = (i / (n + 1)) * virtual_width`, `y = 50`, ids `1..n`;
6. initialize scoring (`total_red_pegs = type_counts.red`, `current_multiplier`
   via `update_multiplier!`, `next_ball_id = n+1`, `used_ball_ids = 1..n`);
7. reset trackers and construct the solo `MatchState`;
8. `assign_next_purple_pegs!(pegs, colors, purple_pegs_per_turn)`: revert
   active purples to blue, drain hit queue heads, rebuild the queue from
   surviving blue pegs with the same Fisher-Yates when it empties (the
   empty-queue rebuild path), and promote until the per-turn count is met or
   no blue pegs remain.

The first promotion happens inside this pipeline, so the checkpoint RNG state
already includes those draws. No motion and no shot-time systems are modeled
at this boundary.

## 6. Checkpoint contract

`Checkpoint` mirrors `schemas/checkpoint.v1.schema.json` exactly and is
lossless at `boundary = "ready_to_aim"`:

- `capture_checkpoint(sim; provenance)` copies every authoritative field
  (engine scoring, pegs with hit data, balls, bucket/fever, clearing,
  ball-id allocation, RNG `state_b64`, purple queue/active, all tracker maps,
  match) and never aliases live arrays;
- `checkpoint_to_dict`/`checkpoint_from_dict` are the JSON codec;
  `checkpoint_canonical`/`checkpoint_sha256` define the byte-level identity;
- `restore!(sim, ckpt)` and `sim_from_checkpoint(ckpt)` rebuild state by
  element-wise copy; restore resets `clear_queue = nothing` and rejects
  `clearing.active == true`;
- `build_checkpoint(level, config; balls, mode, provenance)` is
  build + capture in one call;
- `first_difference(a, b; path)` reports the first differing JSON path for
  diagnostics.

Guarantees verified by the test suite and the parity manifest: the canonical
bytes of a Julia-built checkpoint equal the captured Lua fixture bytes for all
9 configurations; `capture -> test_advance! -> reset -> capture` is
byte-identical and repeatable; mutating a restored simulation does not change
the checkpoint and vice versa (aliasing tests); the captured RNG
`state_b64` decodes to the ASCII `getState()` string.

## 7. WorkerState and Scratch ownership

`WorkerState` owns one simulation, one `Scratch`, and the zero-allocation
event/command journals. `Scratch` preallocates reusable `peg_ids`, `ball_ids`,
`queue`, `active`, `floats`, and `ints` buffers.

`make_worker(ckpt, scratch_caps)` builds a fresh simulation from the
checkpoint and then calls `reset_worker!`. `reset_worker!(w, ckpt)` restores
the simulation, refills the scratch buffers from the restored state, and
empties the journals. Checkpoint-owned arrays and worker-owned storage are
never shared: each reset copies, so a worker cannot mutate another worker's
state or the checkpoint itself.

`test_advance!(w; steps, rng_draws, purple_promotions)` is the deterministic
M2 stand-in for a simulation step: it mutates counters, scoring arrays, one
peg and one ball, consumes RNG draws, and performs promotions. It exists so
the reset contract is exercised before the M3 shot evaluator.

## 8. Commands and outputs

```bash
make julia-test          # Pkg.test() in the pinned environment
make julia-parity        # recompute results/parity/local.json and verify
make julia-bench         # write results/m2-checkpoint-bench.json
make capture-m2          # capture RNG + peg-color + checkpoint fixtures (LÖVE)
make capture-m2-check    # re-capture and require byte equality
make math-census         # capture the math census fixture (luajit)
make math-census-check   # re-capture and compare
make wpd-math            # WP-D: CORE-MATH vs system libm vs MPFR oracle
make wpd-state           # WP-D: Lua core_math capture + Julia state comparison
make wpd-parity          # WP-D: experimental CORE-MATH-era parity manifest + comparison
make wpd-trace           # WP-E: gameplay traces/candidates (single host)
make wpd-perf            # WP-F: math/checkpoint/sweep performance comparison
make m3-trace            # M3: Julia snapshot traces for the base mustache fixtures
make m3-mustache         # M3: 5-fixture Lua-vs-Julia trace control comparison
make m3-sweep            # M3: stride-200 serial/parallel identity sweep
make m3-bench            # M3: Lua-vs-Julia mustache benchmark + full-grid agreement
```

Every command selects its backend with `PEGGLE_MATH_BACKEND` (`system_libm`,
`core_math`, or `julia_base`; `openlibm` is an alias) and, for `core_math`,
`PEGGLE_MATH_LIB` overrides the artifact path.

The WP-D commands write experimental evidence under `tmp/core-math/`:
`scripts/core_math_compare.sh` builds a 113,735-case corpus with an
independent MPFR interval oracle and compares Lua and Julia under both
backends; `scripts/capture_wpd_state.sh` + `scripts/compare_wpd_state.sh`
exercise RNG, peg colors, level geometry, and ready-to-aim checkpoints
through both engines. Acceptance records:
`tmp/core-math/wpd-acceptance.md` (math/state), `tmp/core-math/wpef-acceptance.md`
(traces/performance).

`src/parity.jl` also exposes the manifest API used by `bin/parity_emit.jl`:
`parity_manifest`, `parity_authoritative`, `parity_configurations`,
`parity_provenance`, `write_parity`, `first_parity_difference`.
`bin/checkpoint_bench.jl` writes the checkpoint/reset benchmark and records
the backend identity; `bin/math_census.jl` writes the math census result
summary.

## 9. Provenance and hash conventions

- Every fixture and checkpoint records `reference_revision`,
  `reference_tree`, `config_sha256`, and (for levels) `level_sha256`;
  the Julia side rebuilds provenance from `reference/PIN.md`, the config
  artifact, and the level artifact bytes, never from the fixture it checks.
- Canonical JSON (`src/canonical.jl`) matches `tools/canonical_json.lua`
  byte-for-byte: sorted keys, explicit empty containers, `%.17g` doubles,
  integral decimals below 2^53, `-0` preserved, NaN/Inf rejected, no
  timestamps or host data.
- `results/parity/local.json` splits `identity`, `authoritative`, and
  `environment`. Only `authoritative` is compared across machines;
  `environment` carries the non-authoritative host/backend identity (CPU,
  kernel, library, and for `core_math` the platform and loaded artifact
  SHA-256). For `core_math` the loaded artifact is validated against
  `native/artifacts/<platform>/<artifact>.sha256`, where `<artifact>` is the
  platform-specific filename (`libpeggle_math.so`, `peggle_math.dll`, or
  `libpeggle_math.dylib`), before the manifest is emitted (a missing or
  mismatched checksum is an error), and
  `environment.math_backend` records `expected_artifact_sha256` and
  `artifact_validated`.
- The manifest is schema 2. `identity` additionally pins the Julia package
  source hash and a platform-independent `prerequisites` map: config
  artifact, census and RNG fixtures, level manifest, package version, and the
  native math backend identity. The backend prerequisite is `backend` always,
  plus for `core_math` the pinned `core_math_revision`, `core_math_tag` (when
  present), `abi_version`, `numeric_contract_version` (1), and
  `component_source_sha256` over `native/peggle_math.c`/`.h`/`.map`,
  `native/sqrt_shim.c`, and `native/core-math/files.sha256`; per-platform
  artifact bytes never enter the prerequisite. `compare_parity.sh` rejects
  invalid or unsupported manifests (exit 5), incompatible prerequisites
  (exit 3), and failed status flags (exit 4) before comparing.
- The authoritative section pins: math-census verification, computed RNG
  draws and final generator states plus their SHA-256, computed peg colors
  and every purple-queue rebuild round plus their SHA-256, level artifact
  SHA-256, checkpoint geometry SHA-256, and per-configuration reset records
  (`checkpoint_sha256`, `mutated_sha256`, two `restored_sha256`, and
  `restored_matches_original`, which must be true).

## 10. M3: full-physics shot engine

M3 extends the package from the checkpoint boundary to complete shots. The
new sources sit in the M3 include block of `src/PeggleSim.jl` (§1). Circuits
and path motion stay out of scope (static levels only). The package version
stays `0.1.0`, and the checkpoint serialization is unchanged.

| File | Contents |
| --- | --- |
| `src/events.jl` | `GameplayJournal`/`GameplayCommands`: raw/derived event journal and command queue |
| `src/impact_geometry.jl` | rotating-peg transform at the time of impact |
| `src/physics.jl` | full `Physics.update` port: swept CCD, graze, overlap and depenetration, ball-ball, walls, fever dividers |
| `src/bucket.jl` | bucket motion and catch/bounce resolution |
| `src/fever_buckets.jl` | fever activation, divider motion, ball resolution |
| `src/powers.jl` | green power spawn specs |
| `src/style_shots.jl` | style-shot trackers and awards |
| `src/ball_state.jl` | ball-state timers (spawn and drain) |
| `src/slide_inversion.jl` | slide-inversion tracker |
| `src/snapshot.jl` | per-step simulation snapshot (schema v2) |
| `src/trace.jl` | canonical gameplay-trace JSONL writer |
| `src/engine.jl` | `ShotEngine` pipeline: launch, update, run, scoring, clearing, shot end |
| `bin/shot_bench.jl` | single-shot trace/expected-record driver and serial/parallel sweeps |

The entity and tracker systems read the step's raw/derived events from the
journal and push commands. They never mutate pegs, scores, or `SimState.engine`
directly.

### Engine pipeline

`ShotEngine` wraps the M2 `SimState` and owns the shot-time state (journal,
commands, per-shape peg lists, aim angle, lifecycle flags, trace writer).
`shot_engine(ckpt)` builds one from a ready-to-aim checkpoint, and
`reset_shot_engine!(eng, ckpt)` restores it per candidate. `launch!(eng,
aim_index)` snaps the index through `angle_for_index` and `snapped_aim_angle`
and fires every unlaunched ball. `update!(eng, dt)` accumulates time and runs
each fixed step: `save_previous_state`, one step-id increment, and
`step_simulation!`. It then updates the fever buckets. `run_shot!` loops
`update!` until `shot_done` or `max_steps` (default 3600). `shot_summary`
returns the harness feature set: `steps`, `completed`, `reason`, `score`,
`peg_score`, `bonus`, `style_points`, `style_total`, `styles`, `pegs_hit`,
`reds_hit`, `multiplier`, `is_fever`, `balls`, and `spawned`.

`step_simulation!` and `finalize_step!` follow the documented 26-phase order
of `../peggle_evolved/src/engine/core.lua`. The order includes phase 18b
(slide inversion), the seam-collapse reduction, the clearing cascade,
deterministic command application, and `shot_completed` emission.
Presentation-only systems (`ContactEvents`, `ImpactDebug`, `Perf`,
`ball.draw_path`) are not ported. `harness_callbacks(clearing = false)`
reproduces the bench harness: all balls depleted ends the shot, a bucket catch
adds the bonus, a style shot increments the counter, and turn end sets
`shot_done`.

### Snapshots and traces

`snapshot_capture(engine)` produces schema-v2 snapshot dicts, key-for-key the
Lua `src/systems/simulation_snapshot.lua` schema. `trace.jl` writes canonical
gameplay-trace JSONL: one header plus one record per fixed step, sorted keys,
`%.17g` numbers, and integral values as integer tokens. The header carries a
`math_backend` identity block only when the DetMath backend is not
`system_libm`, so default-backend trace bytes stay stable. See
`wiki/context/m3-mustache.md` for the trace corpus and the comparison
runbook.

### Tests and parity

`test/runtests.jl` includes every `test_*.jl` file. M3 adds
`test_events.jl`, `test_impact_geometry.jl`, `test_physics.jl`,
`test_bucket.jl`, `test_fever.jl`, `test_powers.jl`, `test_style_shots.jl`,
`test_ball_state.jl`, `test_slide_inversion.jl`, `test_engine.jl`,
`test_snapshot.jl`, and `test_trace.jl`. `Pkg.test()` reports 4,722 pass / 0
fail.

- 5 mustache trace fixtures: the Lua snapshot-enabled corpus and the Julia
  traces are byte-identical. The comparison covers the full per-step state
  with zero differences, and the expected records are identical
  (`results/m3/mustache-compare.json`).
- Full candidate grid: 1,801/1,801 indices agree across 16 shared fields, and
  `first_divergent_candidate` is `null`
  (`results/m3/sweeps-compare-full.json`).
- Julia serial and parallel sweeps are bit-identical at every thread count.
- `spawned` is Julia-only in the sweep rows. The Lua raw format omits it. The
  multiball fixture covers spawn behavior in the trace comparison.

The benchmark is in `wiki/benchmarks/m3-shot.md`. The fixture catalog, capture
script, and comparison runbook are in `wiki/context/m3-mustache.md`.
