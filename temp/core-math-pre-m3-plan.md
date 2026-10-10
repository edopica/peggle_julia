# Shared CORE-MATH backend: implementation plan before M3

Created: 2026-10-09. Updated: 2026-10-10.

Status: experimental integration implemented on Linux x86-64. Local math, state, and full trace comparisons pass.
All findings from the implementation review are closed.
The cross-machine matrix, target-OS runtime qualification of the cross-built Windows/macOS artifacts, the adoption decision, and reference migration remain open.
M3 has not started. Strict M2 portability acceptance remains open.

### Current progress

| Work package | Current status | Remaining work |
| --- | --- | --- |
| A — inventory and contract | Recorded for the current authoritative paths | Extend the audit for new authoritative paths |
| B — native component | Source pinned, ABI 1 and Linux artifact checked; Windows/macOS cross-built artifacts and packaging rules exist | Target-OS runtime qualification |
| C — engine integration | Lua FFI and Julia `ccall` integration implemented | Qualification on the remaining platforms |
| D — math and state | Local comparisons pass, parity repairs reviewed; experimental CORE-MATH-era parity inputs and `make wpd-parity` exist | Cross-machine evidence with experimental CORE-MATH inputs |
| E — traces and portability | Full `make wpd-trace` rerun completed (6 full-state + 19 result-only, 637 candidates) | Required host/OS matrix |
| F — performance and adoption | Local measurements recorded | Adoption ADR, reference migration, and final regression checks |

CORE-MATH remains opt-in through `PEGGLE_MATH_BACKEND=core_math`.
The historical Linux backend remains `system_libm`.
The frozen reference and historical fixtures retain their existing role until adoption.
The review did not create a commit.

### Next execution steps

1. Resolve the pre-existing development-tree `src/config.lua` difference without overwriting unrelated work. Done: runtime config overlay; the dev-tree edit is preserved.
2. Run `make wpd-trace` with the repaired comparison tools. Done.
3. Record full-state results for all six trace-enabled fixtures and result comparisons for the other 19 fixtures. Done.
4. Implement the remaining required native builds and packaging rules. Partly done: cross-built artifacts and packaging rules exist; target-OS runtime qualification is open.
5. Prepare experimental CORE-MATH-era inputs for parity manifests without replacing historical fixtures. Done.
6. Collect exact comparisons on at least two physical hosts and two operating systems. A cross-machine qualification kit is prepared (runbook `wiki/context/cross-platform-qualification.md`, tracked experimental census, Linux baseline manifest, per-OS instructions); evidence collection is pending the macOS/Windows trip.
7. Complete the adoption decision after the correctness and performance evidence is sufficient.
8. After adoption approval, complete the reference migration and final regression checks.
9. Start M3 only after the gate in section 11 closes.

Backend adoption does not depend on the M3 shot evaluator.
Only full Lua-versus-Julia shot comparisons depend on that evaluator.
Any earlier acceptance note that makes adoption depend on M3 has an incorrect circular dependency.

## 1. Objective

Both experimental backends use one pinned CORE-MATH source revision for authoritative transcendental functions.
The Linux binary exposes the shared C interface.
The experiment has local correctness, reproducibility, event/result, and performance evidence.

This work closes the math and cross-machine gaps from M2 before M3 starts.
M3 is the minimal shot evaluator milestone in the governing implementation plan.

The current Julia package implements initialization and checkpoints, but no shot evaluator.
Full Lua-versus-Julia shot comparisons therefore belong to M3.
The immediate comparison covers math, RNG-dependent initialization, geometry, and checkpoints.
Lua trace comparisons measure changes from the existing Lua backend.

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
| `../peggle_evolved/src/detmath.lua` | Lua math interface |
| `native/core-math/PIN.md` | CORE-MATH source pin |
| `native/build.sh`, `scripts/verify_core_math.sh` | Native build and artifact checks |
| `julia/PeggleSim/src/parity.jl` | Parity manifest |
| `julia/PeggleSim/bin/parity_emit.jl` | Manifest command |
| `scripts/compare_parity.sh` | Manifest comparison |
| `tools/compare_traces.py`, `tools/compare_candidates.py` | Experimental trace and candidate comparisons |
| `tools/` | Lua exporters and census producers |
| `harness/main.lua` | Lua fixture capture and candidate sweeps |
| `fixtures/` | Frozen reference observations |
| `reference/PIN.md` | Frozen Lua source identity |

### Current evidence

| Check | Latest recorded result |
| --- | --- |
| Frozen reference | 133 files match |
| Native component | Source pin, checksum, ABI, symbol audit, and smoke check pass |
| Julia suite | 3,848 assertions pass |
| Repository checks | `make check` passes all seven steps |
| Trace comparator | 35 comparison cases and four ULP assertions pass |
| Parity comparator | 12 contract cases pass |
| Shared math | 113,735 cases and 57 specials, zero Lua/Julia or enforced oracle mismatches |
| State comparisons | Eight levels, RNG/color cases, and nine canonical checkpoints pass locally |
| Earlier Lua captures | 25 fixture results and 637 candidates per backend agree on observed events/results |
| Snapshot capture check | Two frozen-reference captures match. A changed ball position fails comparison |

The latest review reran both comparator suites and the trace script syntax check.
The broader suite counts come from the recorded implementation checks.
Earlier gameplay captures omit snapshots and establish event/result agreement only.
The full development-tree trace comparison has not rerun after the snapshot and coverage repairs.
All current execution evidence covers one Linux host, not the required cross-machine matrix.

Evidence records:

- `tmp/core-math/wpc-acceptance.md`: inventory, build, and integration evidence.
- `tmp/core-math/wpd-acceptance.md`: math, state, and parity evidence.
- `tmp/core-math/wpef-acceptance.md`: trace/performance evidence and later corrections.
- `tmp/core-math/comparison-tooling-repairs.md`: review repairs and focused reproductions.

These records are local scratch files under `tmp/`.
Their later corrections supersede earlier status statements.

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

Status: inventory, environment matrix, and numeric contract recorded for current authoritative paths.
The records are `tmp/core-math/authoritative-inventory.md`, `environment-matrix.md`, and `numeric-contract.md`.
LÖVE `randomNormal` remains outside the shared backend, with no current authoritative M2 caller.
Any future authoritative use requires integration and checkpoint cache coverage first.

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

Status: implemented and checked on Linux x86-64. Required Windows/macOS builds remain open.

- CORE-MATH revision: `040ee482a8caefe2afe71a3a59d43923d2f0c7e6`.
- Interface: ABI 1, eleven math functions, and two identity/version functions.
- Artifact: `native/artifacts/linux-x86_64/libpeggle_math.so`.
- Recorded artifact SHA-256: `d012f42e0185fbf7d15b892a687b5a07e93668cb5b66ba9021dcbf9d006d0494`.
- Repeated Linux builds produced identical bytes in the recorded checks.
- `sqrt` uses hardware IEEE-754 square root, including the hidden shim for internal calls.
- Required internal FMA uses the documented libm `fma` dependency.

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

Exported symbols use the `peggle_math_` prefix.
Required transcendental functions are `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log`, and `pow`.
The inventory can add functions to this list.

CORE-MATH is a collection of routines, not an assumed complete replacement for every C math function.
Binary64 `sqrt` has an explicit hardware implementation and local correctness evidence.
Lua modulo retains the specified floored-modulo expression and operation order.
Rounding helpers need explicit behavior for negative values and ties.

### Acceptance

- Every required environment builds the same versioned interface from the pinned source.
- Both projects report matching source and ABI identities.
- Binary hashes identify platform artifacts but need not match across platforms.
- No authoritative transcendental call silently uses the host library.
- Artifact packaging supports execution without a compiler on the player machine.

## 6. Work package C: integrate Lua and Julia

Status: implemented in both development projects and checked locally.
Lua uses FFI. Julia selects its backend in `__init__` and calls resolved C symbols.
Backend identity and explicit startup errors are implemented.
`PEGGLE_MATH_LIB` selects an explicit artifact path.
Cross-platform packaging and execution evidence remain open.

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

Status: local math/state comparisons pass. The parity-tool review findings are closed.
The independent MPFR oracle uses directed bounds with increasing precision.
CORE-MATH matches the enforced oracle cases. Historical system libm has 126 non-NaN deviations.
Oracle NaN comparisons use class only. The engine-to-engine math comparison uses exact bits.

Experimental state comparisons preserve the historical fixtures.
The current parity emitter still reads historical census expectations, which CORE-MATH does not fully match.
Cross-machine CORE-MATH qualification needs separate experimental inputs before adoption, followed by migrated fixtures after adoption.

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
6. Include configuration and input-artifact hashes in the comparison prerequisites.
7. Reject incompatible manifest identities before authoritative comparisons.
8. Reject failed census or reset status, including identical failures in both manifests.
9. Report the first difference with expected and actual values.
10. Retain enough state to locate differences within hashed records.

Implemented native prerequisites are platform-independent: backend, source revision/tag, ABI, numeric contract version, and component source hash.
The native binary checksum belongs in environment provenance, not shared prerequisites.
Manifest construction checks that checksum against the recorded platform artifact.
The comparator rejects missing or unsupported manifest structure before comparison.
Malformed schema input returns exit 5. Failed recorded checks cannot pass through equality.

### Acceptance

- Lua and Julia return identical bits for every shared math case.
- Correctness comparisons pass under the specified rounding contract.
- Computed RNG and initialization state agree across the required matrix.
- Reset restores the original state without cross-worker aliases.
- No historical mismatch disappears through replacement of the historical expectations.

## 8. Work package E: Lua traces and cross-machine evidence

Status: earlier local event/result comparisons pass. The revised full trace rerun is blocked.
The development-tree `src/config.lua` has a pre-existing difference from the frozen configuration.
The script refuses this mismatch rather than overwrite it or attribute its effects to CORE-MATH.
The earlier capture used the pinned configuration temporarily and then restored the pre-existing edit.

All trace-tool review findings, including the full-state guard mismatch, are closed.
This closes the code review, not the execution or portability acceptance requirements.

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

Historical gameplay traces omit snapshots.
Fresh experimental captures use `--fixtures-snapshots` for the six trace-enabled fixtures.
The remaining 19 fixtures retain result-only comparisons.
The comparator retains both full step records for inspection of the first state difference.

Current comparison requirements:

- Full scope requires snapshot objects at every recorded step and identical step-ID sets.
- Partial coverage and header/snapshot disagreement fail the control and strict-reference checks.
- The volatility allowlist is empty. Fever-bucket animation state and divider positions are authoritative.
- Bare JSON `-0` retains its sign in numeric comparisons.
- ULP ordering is monotonic. Adjacent signed zeros have distance one by convention.
- The control guard derives expected trace IDs from historical expected records and cross-checks the historical trace files.
- Every expected trace must have full scope and at least one compared snapshot step.
- A missing trace cannot reduce the expected count. Unexpected traces also fail the guard.

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

Status: local performance measurements recorded. Adoption remains undecided.
The recorded Lua sweeps measured 49.9 candidates/s with system libm and 39.6 candidates/s with CORE-MATH.
Candidate outcomes agreed across 1,911 candidates per backend.
Repeated-run variation was 24–36%, so the approximately 21% slowdown is directional evidence, not a precise estimate.
Julia math calls allocated zero bytes. Checkpoint/reset allocations remained unchanged in the recorded comparison.
See `tmp/core-math/perf-summary.json` and `tmp/core-math/perf-report.md` for the measurement scope.

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

Implemented command interface:

| Command | Purpose / current limitation |
| --- | --- |
| `make core-math-build` | Build the pinned native component (Linux x86-64 only) |
| `make core-math-verify` | Check source pin, artifact checksum, ABI, symbols, and smoke cases |
| `make wpd-math` | Compare Lua, Julia, historical outputs, and MPFR expectations |
| `make wpd-state` | Capture experimental Lua state and compare Julia state |
| `make wpd-trace` | Compare fixtures, snapshot traces, and candidate samples (blocked by configuration mismatch) |
| `make julia-parity` | Emit a manifest (historical census expectations still require the historical backend) |
| `scripts/compare_parity.sh A.json B.json` | Compare compatible manifests and require successful recorded checks |
| `make wpd-perf` | Measure math, checkpoint/reset, and equivalent candidate workloads |
| `scripts/test_compare_traces.sh` | Run trace comparison contract cases |
| `scripts/test_compare_parity.sh` | Run parity comparison contract cases |

The Lua project uses `make math-native` to copy and check the shared native artifact.

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

- [x] Both experimental engines consume the same pinned CORE-MATH component on Linux x86-64.
- [x] The inventory covers current authoritative paths, with latent RNG helpers explicitly identified.
- [ ] Required build artifacts and packaging rules exist. Artifacts and packaging rules exist (cross-built); Windows/macOS runtime qualification open.
- [x] Shared math cases have exact Lua-versus-Julia agreement on the local host.
- [x] Independent correctness cases pass locally.
- [x] Local RNG, imported geometry, checkpoint, and reset comparisons pass.
- [x] All raised comparison-tool review findings are closed. Focused contract suites pass.
- [ ] RNG, geometry, checkpoint, and reset evidence satisfies the M2 contract.
- [ ] Required physical hosts and operating systems have exact authoritative agreement.
- [x] The repaired `make wpd-trace` completes with six full-state trace comparisons and 19 result-only comparisons.
- [x] Updated Lua trace changes have classifications and first-divergence evidence where differences exist (zero differences; no first divergence exists).
- [x] Local performance results cover equivalent workloads and record measurement variation.
- [ ] The adoption decision and reference migration are complete.
- [ ] Permanent documentation records the supported contract accurately.
- [ ] The adopted source, pin, fixtures, and build instructions form a reproducible repository state.

Checked local items do not imply acceptance on another host or operating system.
The unchecked target-OS qualification, matrix, adoption, and migration items keep the pre-M3 gate open.

M3 then adds circle-shot physics, serial sweeps, and worker-owned parallel sweeps.
Its first comparison must use the adopted Lua backend and equivalent supported gameplay.
Its acceptance still requires exact serial/parallel agreement across the supported matrix.

## 12. Upstream references

- CORE-MATH mission, routine list, and implementation limitations: https://core-math.gitlabpages.inria.fr/
- CORE-MATH source: https://gitlab.inria.fr/core-math/core-math/
- CORE-MATH FAQ: https://core-math.gitlabpages.inria.fr/faq.html

The implementation must inspect the selected revision rather than assume that current website claims apply to every revision.
