# Shared CORE-MATH backend: implementation plan before M3

Date: 2026-10-09

Status: planned. No CORE-MATH revision or build has acceptance yet.

## 1. Objective

Both engines will use one pinned CORE-MATH source revision for authoritative transcendental functions.
Platform-specific binaries will expose the same C interface.
The initial experiment will measure correctness, reproducibility, gameplay changes, and performance.

This work closes the math and cross-machine gaps from M2 before M3 starts.
M3 is the minimal shot evaluator milestone in the governing implementation plan.

The current Julia package implements initialization and checkpoints, but no shot evaluator.
Full Lua-versus-Julia shot comparisons therefore belong to M3.
The immediate comparison covers math, RNG-dependent initialization, geometry, and checkpoints.
Lua trace comparisons will measure changes from the existing Lua backend.

## 2. Required reading and existing evidence

Read these files before implementation:

- `wiki/quickstart.md`
- `../peggle_evolved/AGENTS.md` and `../peggle_evolved/wiki/quickstart.md`
- `../peggle_evolved/temp/julia_port/implementation-plan.md`, sections 4 and 5
- `wiki/context/julia.md`
- `wiki/context/fixtures.md`
- `wiki/decisions/0001-math-backend.md`
- `wiki/audits/m2-math-census.md`
- `wiki/audits/m2-rng-geometry.md`
- `temp/shared_math_library_report.md`

Current implementation entry points:

| Path | Purpose |
| --- | --- |
| `julia/PeggleSim/src/detmath.jl` | Julia math interface |
| `julia/PeggleSim/src/parity.jl` | Parity manifest |
| `julia/PeggleSim/bin/parity_emit.jl` | Manifest command |
| `scripts/compare_parity.sh` | Manifest comparison |
| `tools/` | Lua exporters and census producers |
| `harness/main.lua` | Lua fixture capture and candidate sweeps |
| `fixtures/` | Frozen reference observations |
| `reference/PIN.md` | Frozen Lua source identity |

The local review passed 3,692 Julia assertions and 25 gameplay fixture comparisons.
It also reproduced nine checkpoints, RNG fixtures, and 15,794 math cases.
That evidence covers one host with system libm.
It does not establish cross-machine determinism.

## 3. Scope and repository rules

1. Inspect the working trees in both repositories.
2. Record the existing changes before implementation.
3. Preserve unrelated work.
4. Keep `reference/peggle_evolved/` read-only throughout the experiment.
5. Keep the existing fixtures and baseline outputs unchanged during the experiment.
6. Write experimental outputs under `tmp/core-math/` in this repository.
7. Implement permanent Lua integration in `../peggle_evolved/`.
8. Keep the system-libm backend available for historical comparisons.
9. Do not change physics rules, collision tolerances, RNG mapping, or candidate ordering.
10. Do not commit or advance the reference pin without the required user instruction.

No custom transcendental algorithms belong in this work.
Thin wrappers, build adaptations, and explicit special-value handling are within scope.

## 4. Work package A: inventory and contract

### Procedure

1. Inventory authoritative math calls in both projects.
2. Include level construction, color initialization, launch calculations, physics, bucket motion, and RNG helpers.
3. Include circuit and path initialization, even though M3 supports static levels.
4. Identify cached Lua aliases such as `local sin = math.sin`.
5. Identify powers that bypass the math interface through `^` or compiler transformations.
6. Identify authoritative math inside LÖVE native functions.
7. Separate rendering-only calls from authoritative calls.
8. Record each authoritative call site and its replacement.
9. Define the initial OS and CPU matrix before build work.
10. Record each environment as required, experimental, or unsupported.

The proposed shipping matrix includes Linux x86-64, Windows x86-64, and macOS ARM64.
Additional architectures require separate evidence.
The initial acceptance matrix must include two physical hosts and two operating systems.
An unavailable required environment remains an open acceptance item.

### Numeric contract

- Authoritative values use IEEE-754 binary64.
- The rounding mode is round-to-nearest, ties-to-even.
- Subnormal values remain enabled.
- Simulation expressions preserve their explicit operation order.
- Simulation code excludes fast-math and accidental FMA contraction.
- CORE-MATH routines retain intentional internal FMA operations required by their algorithms.
- Signed zero behavior has explicit cases.
- NaN and infinity behavior has an explicit policy.
- Invalid authoritative state produces an explicit error before canonical serialization.
- Hardware dispatch cannot change returned bits within the supported matrix.

### Acceptance

- The call-site inventory covers every authoritative phase and initialization path.
- The environment matrix has explicit boundaries.
- The numeric contract specifies ordinary inputs and boundary inputs.

## 5. Work package B: source pin, build, and C interface

### Procedure

1. Select a full CORE-MATH commit hash after inspection of its documentation and required routines.
2. Pin all required source files, headers, licenses, and source hashes.
3. Select one canonical location for the source pin and wrapper implementation.
4. Make both projects consume the same versioned native component.
5. Prevent independent edits to duplicate wrapper implementations.
6. Provide a reproducible build command for each required environment.
7. Record the compiler, target, build flags, source hashes, and artifact SHA-256.
8. Follow the requirements of each selected CORE-MATH routine.
9. Inspect dependencies on system math symbols and compiler runtime functions.
10. Prevent accidental calls to host transcendental implementations.
11. Export versioned C symbols with explicit binary64 arguments and return values.
12. Provide a backend identity function through the C interface.
13. Make missing artifacts or incompatible ABI versions produce an explicit startup error.

Proposed symbols use the `peggle_math_` prefix.
Required transcendental functions are `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log`, and `pow`.
The inventory can add functions to this list.

CORE-MATH is a collection of routines, not an assumed complete replacement for every C math function.
Binary64 `sqrt` needs an explicit implementation choice and correctness evidence.
Lua modulo retains the specified floored-modulo expression and operation order.
Rounding helpers need explicit behavior for negative values and ties.

### Acceptance

- Every required environment builds the same versioned interface from the pinned source.
- Both projects report matching source and ABI identities.
- Binary hashes identify platform artifacts but need not match across platforms.
- No authoritative transcendental call silently uses the host library.
- Artifact packaging supports execution without a compiler on the player machine.

## 6. Work package C: integrate Lua and Julia

### Lua procedure

1. Add an authoritative math module in the development Lua project.
2. Load the native component through LuaJIT FFI.
3. Initialize the backend before authoritative modules cache function references.
4. Replace authoritative call sites with explicit calls to the new module.
5. Preserve rendering-only math where it does not affect authoritative state.
6. Add an explicit backend selector for experiment commands.
7. Report the selected backend in fixture and trace metadata.
8. Add packaging rules for the required native artifacts.

Harness-only monkeypatches do not establish final integration.
Existing LÖVE RNG integer behavior must remain unchanged.
If authoritative RNG helpers call native transcendentals, route those helpers through the shared contract.
If such helpers participate in checkpoint continuation, preserve the normal-deviate cache.

### Julia procedure

1. Replace the platform-only backend choice in `src/detmath.jl` with an explicit backend selection mechanism.
2. Call the shared C symbols directly through `ccall`.
3. Keep backend selection fixed throughout each run.
4. Make backend selection reliable across Julia precompilation.
5. Preserve a separate system-libm mode for historical fixture comparisons.
6. Remove the claim that Julia `Base` calls identify a pinned Openlibm implementation.
7. Record the native component identity in parity and benchmark outputs.

### Acceptance

- Both processes report the intended backend before authoritative initialization.
- Missing native components cannot trigger fallback behavior.
- A source audit accounts for remaining direct math calls.
- The historical backend still reproduces the historical fixtures.

## 7. Work package D: math and state comparisons

### Procedure

1. Run the existing census inputs through Lua CORE-MATH and Julia CORE-MATH.
2. Compare output bits directly between the two implementations.
3. Keep historical system-libm expectations as a separate comparison axis.
4. Add missing interface functions and boundary cases to the census.
5. Include signed zeros, subnormals, quadrant boundaries, and known hard-to-round inputs.
6. Include upstream cases applicable to the selected routines.
7. Use an independent high-precision oracle for correctness comparisons.
8. Use sufficient precision or interval bounds to establish each expected binary64 rounding result.
9. Run RNG sequence and purple-queue cases through both engines.
10. Regenerate experimental level artifacts through the Lua CORE-MATH initialization path.
11. Compare those artifacts with the historical geometry.
12. Build both engines' checkpoints from identical experimental artifacts and seeds.
13. Compare canonical checkpoints and authoritative float bits.

Imported Lua geometry alone does not establish parity for Julia geometry construction.
Only compare construction paths that both engines implement.
Report imported geometry and independently computed state separately.

### Parity manifest repairs

1. Hash computed RNG outputs and final generator states, not only fixture files.
2. Hash computed color assignments and purple-queue rebuild results.
3. Record state after deterministic mutation and before reset.
4. Require each restored hash to equal the original checkpoint hash.
5. Include the Julia source identity and native source identity.
6. Include artifact and configuration hashes in the comparison prerequisites.
7. Reject incompatible manifest identities before authoritative comparisons.
8. Reject failed census or reset status, including identical failures in both manifests.
9. Report the first difference with expected and actual values.
10. Retain enough state to locate differences within hashed records.

### Acceptance

- Lua and Julia return identical bits for every shared math case.
- Correctness comparisons pass under the specified rounding contract.
- Computed RNG and initialization state agree across the required matrix.
- Reset restores the original state without cross-worker aliases.
- No historical mismatch disappears through replacement of the historical expectations.

## 8. Work package E: Lua traces and cross-machine evidence

### Procedure

1. Run the frozen reference checks before the experiment.
2. Establish a system-libm control for the experimental Lua source.
3. Compare that control with the frozen reference fixtures.
4. Resolve unrelated source differences before attributing changes to CORE-MATH.
5. Capture the 25 gameplay fixtures with the experimental CORE-MATH backend.
6. Capture a fixed candidate sample from every applicable baseline workload.
7. Compare ordered event types, entity IDs, commands, scores, and completion reasons.
8. Report differences in step placement separately.
9. Compare continuous payloads by exact bits and ULP distance.
10. Record the first divergent step and surrounding state for each affected shot.
11. Classify each semantic mismatch before acceptance.
12. Repeat the same CORE-MATH captures across the required environment matrix.
13. Compare authoritative state throughout each run, not only final scores.
14. Run the Julia foundation suite on each required environment.
15. Run the frozen reference checks after the experiment.

Existing gameplay traces omit snapshots.
Experimental diagnostics therefore need authoritative state samples or per-step hashes with first-difference recapture support.
Host metadata and performance timing do not belong in authoritative comparisons.

Lua CORE-MATH versus historical Lua measures a backend migration.
It does not measure Lua-versus-Julia shot parity.
Cross-machine CORE-MATH comparisons require exact agreement without numeric tolerances.

### Acceptance

- The system-libm control reproduces the relevant historical behavior.
- Every historical gameplay difference has a recorded classification.
- CORE-MATH runs agree exactly across the required matrix.
- Two runs on one host do not substitute for two physical hosts.
- An unavailable host does not count as a successful comparison.

## 9. Work package F: performance and adoption decision

### Procedure

1. Measure math calls on recorded workload inputs after warmup.
2. Measure wrapper overhead through LuaJIT FFI and Julia `ccall`.
3. Measure Lua candidate sweeps under both backends on the same host.
4. Keep candidate inputs, completion rules, observation mode, and source behavior equivalent.
5. Include initialization, simulation, extraction, and output costs separately.
6. Record cold startup separately from warm throughput.
7. Report median and tail timing, allocations, memory, and repeated-run variation.
8. Measure Julia checkpoint and reset costs with the new backend.
9. Report performance regressions without changing correctness requirements.

No Julia shot-speedup claim belongs in this experiment.
Julia has no shot evaluator until M3.
There is no agreed fixed performance threshold for adopting CORE-MATH.
The adoption report must explain the measured cost and its effect on the intended workload.

### Adoption procedure

1. Write an ADR that supersedes the authoritative system-libm decision.
2. Record the selected revision, ABI, matrix, numeric contract, and remaining limitations.
3. Record the adoption decision after correctness and performance evidence is complete.
4. After adoption approval, advance the Lua reference through the existing pin procedure.
5. Preserve the previous reference and evidence through versioned repository history.
6. Regenerate interchange artifacts, previews, fixtures, and baselines under the new reference.
7. Update provenance, manifests, and backend identities together.
8. Run the complete reference, interchange, Julia, and parity checks.
9. Update permanent documentation and the M2 status.

If acceptance fails, retain the experimental evidence and keep M2 open.
Do not silently weaken the environment matrix or determinism contract.

## 10. Deliverables and command interface

Required deliverables:

- One pinned native component with reproducible build instructions and licenses.
- Lua and Julia integrations with explicit backend identity.
- A complete authoritative call-site inventory.
- A numeric contract and supported environment matrix.
- Independent math correctness evidence.
- Repaired parity manifests and comparison tooling.
- Classified Lua trace differences and cross-machine state comparisons.
- Equivalent-workload performance results.
- An adoption ADR and updated milestone documentation.

Proposed new commands must provide these operations:

| Operation | Required behavior |
| --- | --- |
| Build native component | Consume the source pin and emit an identified platform artifact |
| Run math comparison | Compare Lua, Julia, historical outputs, and independent expected results |
| Capture experimental fixtures | Write a separate backend-specific corpus |
| Compare traces | Report semantic, step-placement, and numeric differences separately |
| Emit parity evidence | Recompute authoritative values and record environment identity |
| Compare environments | Enforce prerequisite identity and exact authoritative agreement |
| Run performance comparison | Use equivalent workloads and retain raw measurements |

Exact command names belong in the implementation documentation after the commands exist.

Existing regression commands remain useful:

```bash
make verify
make check-all
make capture-m2-check
make math-census-check
make julia-test
make self-check
```

Historical commands must select the historical backend until the reference migration completes.
Experimental commands must not overwrite historical outputs.

## 11. Gate before M3

M3 starts only after these conditions hold:

- [ ] Both engines consume the same pinned CORE-MATH component.
- [ ] The authoritative call-site inventory is complete.
- [ ] Required build artifacts and packaging rules exist.
- [ ] Shared math cases have exact Lua-versus-Julia agreement.
- [ ] Independent correctness cases pass.
- [ ] RNG, geometry, checkpoint, and reset evidence satisfies the M2 contract.
- [ ] Required physical hosts and operating systems have exact authoritative agreement.
- [ ] Lua trace changes have classifications and first-divergence evidence.
- [ ] Performance results cover equivalent workloads.
- [ ] The adoption decision and reference migration are complete.
- [ ] Permanent documentation records the supported contract accurately.
- [ ] The adopted source, pin, fixtures, and build instructions form a reproducible repository state.

M3 then adds circle-shot physics, serial sweeps, and worker-owned parallel sweeps.
Its first comparison must use the adopted Lua backend and equivalent supported gameplay.
Its acceptance still requires exact serial/parallel agreement across the supported matrix.

## 12. Upstream references

- CORE-MATH mission, routine list, and implementation limitations: https://core-math.gitlabpages.inria.fr/
- CORE-MATH source: https://gitlab.inria.fr/core-math/core-math/
- CORE-MATH FAQ: https://core-math.gitlabpages.inria.fr/faq.html

The implementation must inspect the selected revision rather than assume that current website claims apply to every revision.
