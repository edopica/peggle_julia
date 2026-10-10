# Julia simulation platform: implementation plan

Status: Revised after two planning discussions. Open recommendations remain provisional.
Date: 2026-10-03

## 1. Goal and first useful deliverable

The platform generates levels, runs bot games, and measures level behavior.
The target workload is bot-versus-bot 1v1 matches.
Solo play is an acceptable intermediate milestone for the shared simulator.
Its main workload evaluates every candidate shot from the same decision state.
The primary performance metric is the elapsed time for that complete evaluation.

The first useful deliverable accepts a level and a decision state.
It evaluates the legal aim grid, returns shot features, and exports selected shots for inspection.
Full games, procedural generation, and statistical analysis build on this deliverable.

The proposed implementation starts with portable CPU code.
Independent shots provide parallel work without changes to arithmetic inside each shot.

### Agreed product requirements

- The intended selection process starts with several thousand generated levels.
- Simulation and analysis produce approximately 50 candidates for human review.
- The user selects approximately 10 final levels.
- The initial implementation does not need to generate the complete level collection.
- Hardware selection and campaign duration remain flexible. Campaigns can run for days.
- Fast simulation remains a primary goal, without a fixed wall-clock deadline at this stage.
- The same engine version and identical inputs must produce bit-identical authoritative results across machines.
- Lua and Julia must produce identical or almost always identical gameplay event sequences.
- Cross-engine bit parity is desirable within a proportionate engineering effort.
- Initial simulation campaigns use static levels.
- Bots will eventually choose launch timing. Timing search requires a separate analysis phase.

The determinism requirement applies to Peggle Evolved and the Julia simulator separately.
Exact numeric agreement between the two implementations is an optional improvement.

The proposed initial meaning of a static level is fixed peg geometry with normal bucket behavior.
The initial bot evaluates angles with zero additional waiting at the ready-to-aim boundary.
Simulation time continues through shots and clearing. Bot computation consumes no simulated time.
The normal bucket remains a timing-dependent mechanic even on a level with fixed pegs.
This initial action policy is reproducible, but it does not cover every eventual timing choice.

## 2. Findings that affect the plan

The three source documents establish the goals and describe earlier parity work:

- `goal.md`
- `julia-port-strategy.md`
- `shared_math_library_report.md`

The repository architecture supports a separate simulation core, but several details need attention:

| Finding | Consequence |
| --- | --- |
| The engine has 26 phases plus phase 18b. | Preserve authoritative phase order and event order. |
| Match rules also live in `src/states/game.lua`. | Include a match layer for inventories, penalties, turn changes, and game completion. |
| Trace snapshots omit some continuation state. | Define a separate checkpoint contract for candidate evaluation. |
| Path circuits exist in `circuit_primitives.lua`. | Include runtime path sampling in the later moving-level phase and numeric audit. |
| `toi_epsilon` currently equals `1e-9`. | Treat the proposed `1e-6` tolerance as a separate physics decision. |
| Collision ties currently use candidate indices. | Preserve current scan order and tie behavior in the reference port. |
| The physics source already has hoisted collision helpers. | Reassess the earlier P1/P2 recommendations against the selected baseline. |
| The configured aim grid has 1800 intervals. | Derive legal actions from the actual snapping function, including endpoints. |

The current snapping formula can produce indices from 0 through 1800, inclusive.
The existing style-shot tool uses a separate floating-point angle loop and disables snapping.
Its loop is not the definition of the bot action space.

The current level dumper provides useful data conversion, but it is not a complete interchange contract.
It omits compiled path caches and converts legacy circuit functions to an unknown kind.
The new interchange must reject unsupported circuits explicitly.

Some wiki descriptions differ from current match code.
For example, 1v1 uses a shared bucket counter and discards the current turn score on a no-red turn.
Reference behavior must come from the selected source revision and fixtures.

## 3. Proposed architecture

```text
Level generator / Lua level exporter
                  |
                  v
            LevelDefinition
                  |
                  v
          Simulation + MatchState
                  |
          decision checkpoint
                  |
                  v
       Candidate evaluator <---- Bot configuration
                  |
          ShotResult array
                  |
                  v
         Bot selects an action
                  |
          advance live match
                  |
                  v
        GameResult + action log
                  |
          analysis / preview
```

### Core data boundaries

- `LevelDefinition`: geometry, stable peg identifiers, line metadata, circuit definitions, dimensions, and color-generation inputs.
- `SimConfig`: all authoritative constants and numeric policy, with a reproducible content hash.
- `DecisionCheckpoint`: complete state immediately before candidate evaluation.
- `ShotAction`: an integer aim index and an integer launch delay in fixed steps.
- `ShotResult`: score components, red hits, catches, style counts, duration, completion status, and selected trajectory features.
- `MatchState`: players, inventories, current player, bucket counter, match status, and simulation state.
- `RunManifest`: source revision, schema versions, configuration hash, level hash, seeds, runtime versions, and math backend identity.

The first checkpoint boundary is a ready-to-aim turn boundary.
This boundary avoids an initial requirement for arbitrary mid-shot continuation.
The contract must still include RNG state, purple queues, circuit phases, bucket phase, identities, and all future-relevant match state.

### Simulation storage

Shared level data remains read-only during candidate evaluation.
Each worker owns its mutable simulation state, event buffers, command buffers, and scratch storage.
Each candidate starts from the same checkpoint through an explicit reset operation.
Speculative shots must not consume identities or random numbers in the live match.

Concrete Julia types and reusable storage are initial requirements.
AoS versus SoA remains a measured choice for each collection.
Per-shape storage must preserve the reference candidate order.
An immutable struct with array fields still requires an explicit ownership rule.

### Observation modes

The simulator has one authoritative behavior with three observation modes:

1. **Summary:** retain only shot features and final state information needed by the caller.
2. **Events:** also export selected events for analysis.
3. **Diagnostic:** export full step records and state samples for parity checks and playback.

Summary mode retains the internal events required by scoring and gameplay processors.
It avoids persistent trace copies and file output for every candidate.
All modes must produce the same authoritative result.

## 4. Numeric and behavioral contract

### Recommended baseline

The reference port uses `Float64`, fixed steps, explicit operation order, and the current Lua collision rules.
The authoritative path excludes fast-math transformations and fused replacements for unfused reference expressions.
Compatibility checks cover modulo, rounding, powers, signed zero, numeric serialization, and random-number mapping.

The math interface covers `sin`, `cos`, `atan`, `atan2`, and `asin` at minimum.
The initial implementation audit includes authoritative level initialization and static geometry construction.
The moving-level phase adds runtime geometry updates and path compilation or sampling.
Load-time calculations can affect authoritative geometry.

The existing math report contains measurements, not a proof for all inputs or all servers.
Its shared-openlibm proposal also requires explicit Julia calls for functions such as two-argument `atan`.
The report itself notes that Julia does not necessarily route that operation through the library's `atan2`.

### Required cross-machine determinism

Identical authoritative inputs must produce bit-identical results on every supported machine for a given engine version.
Inputs include level data, configuration, seeds, initial state, and actions indexed by simulation step.
Bot decisions must also repeat independently of worker count and scheduling.
Wall-clock timing must not affect launch timing, random streams, or action selection.

The contract covers authoritative numeric state, events, commands, scores, and match outcomes.
Rendering, performance measurements, and environment metadata do not belong in authoritative comparison data.
Canonical state encoding must preserve float bits, stable field order, and stable entity order.

The recommended structure isolates a pinned math implementation behind a small interface.
A shared implementation for Lua and Julia minimizes differences between the two engines.
Openlibm is a candidate that requires assessment and cross-machine checks.
A library name or version alone does not establish bit identity.
Build flags, architecture-specific code, CPU dispatch, rounding mode, and subnormal handling also need an explicit contract.

The authoritative path requires explicit control of contraction and reassociation.
It must also preserve iteration order, constants, RNG behavior, and level initialization results.
CPU-specific acceleration cannot change these results.

A same-host system-libm backend remains useful for diagnosis of the current Lua reference.
It cannot serve as the production portability contract.
Cross-machine checks begin with the numeric foundation, before large simulation campaigns.
The supported OS and CPU architecture matrix requires definition during implementation.
Server model, core count, and rental decisions can remain open.

The current Lua implementation requires its own determinism assessment.
The existing source review does not establish that it already satisfies the cross-machine requirement.
Any shared-math adoption that changes Lua results requires a versioned baseline and new fixtures.

### Parity checks

There are two separate comparison axes:

1. **One engine across machines:** exact authoritative float bits and discrete state. No tolerance or agreement percentage applies.
2. **Lua versus Julia:** identical or almost always identical gameplay event sequences. Numeric bit parity is desirable, but optional.

The cross-machine suite must compare state throughout a run, not only final scores.
It covers numeric kernels, RNG sequences, initialized geometry, shots, complete matches, and bot decisions.
Worker-count and scheduling variations must preserve the same results.
The comparison tool reports the first difference and the surrounding state.

Cross-engine comparisons distinguish event semantics from numeric diagnostic payloads.
Event semantics include ordered event types, entity identifiers, gameplay decisions, commands, score components, and completion reasons.
Continuous payloads, such as impact coordinates, can use explicit numeric tolerances.
The comparison reports differences in fixed-step placement separately. Any permitted timing tolerance requires an explicit rule.

The frozen Lua-versus-Julia regression corpus requires exact agreement on event semantics.
Larger campaigns measure event-sequence agreement across complete shots and matches.
They also record outcome differences and the first divergent event in each affected run.
Every semantic mismatch requires classification. An aggregate agreement rate cannot silently excuse an implementation error.

The earlier report's 99.99% figure is not an agreed acceptance threshold.
Initial measurements will inform a concrete cross-engine threshold and its sample definition.
That threshold cannot relax the strict cross-machine requirement for either engine.

### Scope of cross-engine parity work

The initial approach uses existing math libraries, a small compatibility interface, and measured comparisons.
Straightforward operation-order matching remains useful during the port.
Cross-engine bit parity is an optional result, not an additional release gate.
Custom transcendental implementations or major engine rewrites solely for cross-engine bit parity require a new scope decision.
Mandatory cross-machine reproducibility remains part of the implementation contract.

Changes to epsilon or tie rules require a separate reference revision and new fixtures.

## 5. Milestones and acceptance criteria

### M0 — Define the workload and select the reference

Tasks:

1. Select the reference source revision and configuration.
2. Define the static-level candidate grid and ready-to-aim decision boundary with zero additional launch delay.
3. Select representative levels, seeds, and bot decisions for repeatable benchmarks.
4. Inventory the existing corpus and reusable benchmark tools.
5. Measure current Lua throughput on representative decision states.
6. Record sweep time, same-core speedup, memory use, and scaling as continuing engineering metrics.

Acceptance:

- A reproducible baseline covers static circles, rectangles, annular pegs, dense layouts, and multiball workloads.
- Moving and path-driven workloads enter the baseline during the later motion phase.
- Timings separate initialization, checkpoint reset, simulation, feature extraction, and output.
- Warm throughput and cold startup time appear separately.
- The workload estimate includes all candidate shots at every turn, not only the selected shots.
- Hardware selection and a campaign deadline do not block implementation.

### M1 — Define interchange, fixtures, and level previews

Tasks:

1. Define versioned level, configuration, checkpoint, action-log, and result formats.
2. Extend the Lua exporter to capture the inputs required for reproducible simulation.
3. Preserve line metadata required by slide inversion.
4. Define the initial static-level subset and explicit rejection of unsupported motion.
5. Add round-trip checks for numeric values, order, dimensions, and identifiers.
6. Capture reference shots and targeted boundary cases.
7. Add an SVG preview for all static peg shapes.

Acceptance:

- A Lua level produces a data artifact and a preview without Julia simulation.
- Unsupported circuit functions produce a clear error.
- Fixtures include shape boundaries, near-ties, grazes, overlap correction, clearing, fever, powers, and style awards.
- Static lines and arcs preserve the metadata required by gameplay processors.
- Each fixture records its reference revision, configuration, seeds, and expected completion.

The strategy document mentions a 42-case matrix.
M1 must locate and assess that matrix before treating it as sufficient coverage.

### M2 — Establish the math and state foundations

Tasks:

1. Create a Julia package with a pinned dependency environment.
2. Implement concrete level, simulation, checkpoint, and scratch types.
3. Implement the pinned math backend and compatibility helpers.
4. Implement the exact reference RNG and integer sampling behavior.
5. Run a math census on recorded inputs and boundary cases.
6. Implement checkpoint capture and reset at the agreed decision boundary.
7. Add cross-machine comparisons for numeric kernels, RNG sequences, and initialized geometry.

Acceptance:

- RNG checks cover initial color assignment and later purple-queue rebuilds.
- Math results satisfy the strict cross-machine contract on the initial supported environment matrix.
- Reset restores all future-relevant state without references to mutable state in another worker.
- Repeated reset and simulation produce the same result.
- Checkpoint memory and reset cost appear in the benchmark report.

### M3 — Build a minimal shot evaluator and measure it early

Tasks:

1. Port a static-circle shot slice with walls, bucket behavior, and basic scoring.
2. Implement integer-indexed candidate enumeration.
3. Implement serial sweeps from a reusable checkpoint.
4. Add parallel sweeps with worker-owned state.
5. Return compact results in candidate order.
6. Compare the supported slice against equivalent Lua cases.

Acceptance:

- Every candidate uses the same initial state.
- Serial and parallel sweeps produce bit-identical authoritative results across the initial supported environment matrix.
- The benchmark includes reset, simulation, and result extraction.
- The report measures the slice's speedup, reset overhead, allocation behavior, and worker scaling against the Lua baseline.

This slice provides an early performance decision point.
Its results do not establish throughput for rotating annular pegs, path circuits, or complete gameplay.
Measured bottlenecks determine the next storage or algorithm change before expansion.

### M4 — Complete static-level shot behavior and the main performance gate

Port order:

1. Static peg geometry, derived collision data, and line metadata.
2. Rectangle and annular collision behavior and overlap correction.
3. Ball-ball collisions, green powers, and stable spawn order.
4. Bucket and fever resolution.
5. Peg reduction, multipliers, purple state, and clearing.
6. Style shots, ball-state timers, slide inversion, and shot completion.
7. Full phase orchestration and diagnostic trace export.

Each increment receives reference comparisons and throughput measurements.
The reference inventory must also cover authoritative behavior outside `stepSimulation`, including launch and update-loop lifecycle rules.
Completion means the agreed ready-for-next-turn boundary, including end-of-turn clearing.
A step limit produces an explicit incomplete result rather than an ordinary low score.

Acceptance:

- The frozen corpus passes the selected parity contract.
- Static-level support includes all current peg shapes and applicable gameplay mechanics.
- Motion-specific behavior enters the later moving-level phase.
- Summary and diagnostic modes produce identical outcomes.
- Representative full sweeps demonstrate measured throughput gains over equivalent Lua work.
- Cross-machine comparisons require bit-identical authoritative state throughout the supported fixture runs.
- Reports include median and tail latency, shots per second, allocations, peak memory, and scaling across worker counts.
- Warm fixed-capacity stepping targets zero heap allocation, with any capacity growth measured separately.

Profiling can justify shape-specific layouts, cached geometry, moving-peg lists, or broadphase acceleration.
Any candidate-filtering optimization must preserve collision coverage and reference tie behavior.

### M5 — Run complete bot games and inspect selected shots

Tasks:

1. Implement solo matches as the initial end-to-end check of the shared simulator.
2. Implement baseline bots with deterministic action selection.
3. Separate shot features from bot utility and skill configuration.
4. Assign stable seeds independently of worker scheduling.
5. Re-run the selected action on the live state.
6. Record match actions, turn results, final results, and representative diagnostics.
7. Add Lua import and replay support for selected generated levels and shots.
8. Implement the 1v1 rules through the match layer.
9. Add complete-match checkpoints and restartable campaign batches before long-duration runs.

Acceptance:

- A complete game repeats bit-identically under the same inputs across supported machines.
- Both solo and 1v1 match rules pass reference cases before level-selection campaigns begin.
- Initial matches use static levels and the zero-additional-delay action policy.
- 1v1 cases cover shared board state, shared bucket bonuses, penalties, player inventories, turn order, and match completion.
- Candidate evaluation cannot change the live match or its RNG state.
- Changing worker count does not change chosen actions or match outcomes.
- Lua playback accepts the generated level and preserved launch state.
- Playback comparisons identify differences between Julia results and Lua re-simulation.
- A stopped campaign resumes from completed work without duplicate results.

The shared shot simulator provides most of the implementation for both modes.
The 1v1 match layer still needs dedicated reference cases because its rules affect bot utility and level selection.

Lua re-simulation shows the Lua result from exported inputs.
Exact inspection of a divergent Julia trajectory requires a separate recorded-state playback adapter.
That adapter uses diagnostic samples instead of new physics calculations.

Bot skill remains a policy decision.
Possible controls include utility weights, decision noise, aim error, and limited candidate access.
The first baseline uses exhaustive one-ply evaluation and deterministic tie-breaking.

### M6 — Connect generation and analysis

Tasks:

1. Implement one seeded, parameterized static-level family.
2. Add geometric checks for bounds, overlaps, and required metadata.
3. Generate previews and export candidates through the shared level format.
4. Run complete 1v1 matches across seeds and bot pairings.
5. Store result tables in chunked columnar files with stable identifiers.
6. Produce score distributions, completion rates, style frequencies, and representative replays.
7. Add exploratory metrics for action diversity, near-optimal choices, and sensitivity to aim error.
8. Produce a shortlist with previews, metrics, and representative match replays.

Acceptance:

- One command can generate, simulate, summarize, preview, and export a level batch.
- Metrics identify their sample population, bot policy, seeds, and incomplete-run count.
- Entropy metrics define their outcomes, bins, and sampling distribution.
- Human review compares interesting metrics with actual play and replay evidence.

### Proposed selection process

The intended campaign reduces several thousand levels to approximately 50 candidates.
The user then selects approximately 10 levels through inspection and play.
The first implementation exercises this process on a small batch.

The proposed stages are:

1. Geometric checks and a small reproducible simulation sample for every level.
2. More matches for promising or uncertain levels across bot pairings and seeds.
3. A shortlist that preserves distinct play patterns as well as strong measured results.
4. Human review through previews, metrics, match replays, and playable level exports.

For 1v1, candidate metrics include score margins, first-player advantage, lead changes, style frequency, and skill separation.
Matched bot pairings and swapped player seats help distinguish level effects from bot strength.
Sampling budgets and shortlist criteria remain open until initial data is available.
Incomplete matches require explicit accounting in every selection stage.

Adaptive sampling uses fixed batches and stable result order.
Worker completion order and wall-clock deadlines must not change promotion decisions.
Stored campaign decisions make a resumed selection process reproducible.

Score variance or entropy alone does not define an enjoyable level.
The initial analysis preserves multiple metrics rather than collapsing them into one fitness score.

### M7 — Scale campaigns across servers

Tasks:

1. Define deterministic work identifiers from level, seed, bot, and repetition.
2. Partition campaigns into resumable file-based batches.
3. Extend local restartable batches with atomic result completion and retries across servers.
4. Record environment and numeric backend identity for each batch.
5. Run parity and performance checks on each supported server environment.
6. Merge results in stable order without duplicate completed jobs.

Acceptance:

- A stopped campaign resumes without loss or duplicate results.
- Scheduling and partition changes preserve results within the selected numeric contract.
- Memory and output volume remain bounded for the target campaign size.

Independent games or level batches are the proposed cross-server work unit.
Shot-level threads serve each local evaluation through a bounded shared execution budget.
The scheduler must avoid nested pools that oversubscribe CPU cores.

### M8 — Analyze launch timing and add moving-level support

This phase follows reliable static-level shot evaluation and match simulation.
It does not require completion of the full generation campaign or cross-server orchestration.

The analysis must define:

- The allowed waiting horizon and its gameplay meaning.
- The delay resolution in integer simulation steps.
- The bucket phase and circuit state that advance during waiting.
- Clearing and between-turn timing at the decision boundary.
- Whether any finite motion period permits safe reuse of equivalent states.
- The cost of exhaustive angle-delay evaluation versus deterministic staged search.
- Reuse of pre-launch checkpoints across angles at the same delay.
- How skill and aim error interact with timing choices.

Static pegs do not remove timing choices because the normal bucket moves.
Period reduction requires evidence. Multiple circuits do not necessarily share a useful common period.
Elapsed wall-clock time must never determine search coverage or action selection.

Implementation tasks after the analysis:

1. Add path definitions and derived-cache ownership to the supported interchange contract.
2. Port circuit motion, pause behavior, and runtime peg transforms.
3. Port rotation slices and moving-shape collision behavior.
4. Add moving-level fixtures and cross-machine checks.
5. Implement the agreed timing policy and angle-delay profiler.
6. Compare timed actions against Lua from identical decision states.

Acceptance:

- Timing policy, candidate coverage, and any approximation are explicit and versioned.
- Moving levels satisfy the same determinism and cross-engine event contracts as static levels.
- Timing search produces identical results across machines and worker schedules.
- Performance reports include waiting-state preparation and the complete angle-delay search.

## 6. Visualization recommendation

The recommended first preview is a standalone SVG generated from level data.
It works on servers and can appear in a browser or a contact sheet.
Additional snapshots can show selected circuit phases.

The recommended interactive viewer is the existing Lua game through a level and replay bridge.
This approach reuses the existing visual style and controls.
If interactive inspection becomes a frequent bottleneck, a Julia-native viewer remains an option.

## 7. Performance measurement policy

| Measure | Target |
| --- | --- |
| Candidate grid | Legal aim indices at zero additional delay initially. Timing search follows dedicated analysis. |
| Representative level complexity | Pending level selection |
| Typical and worst-case sweep time | Measure continuously. No fixed deadline yet. |
| Same-core speedup over current Lua | Measure on equivalent workloads and report bottlenecks. |
| Available worker count | Configurable. Hardware selection is deferred. |
| Maximum memory per worker | Pending checkpoint measurements |
| Campaign size | Several thousand levels, approximately 50 shortlisted, approximately 10 selected by the user |
| Campaign duration | Flexible, including multi-day runs |

Both Lua and Julia measurements require equivalent gameplay, observation mode, completion rules, and candidate inputs.
Parallel speedup must appear separately from the language-level improvement.
The comparison must not credit Julia for less gameplay or less diagnostic output.
Flexible runtime budgets do not reduce the priority of throughput and memory efficiency.
They remove the need for an arbitrary completion-time target before implementation.

## 8. Decisions for the next discussion

1. **Bot policy:** first utility features, strategy differences, and skill models for 1v1 evaluation.
2. **Visualization:** SVG previews plus Lua playback, or a Julia-native interactive viewer?
3. **First static generator:** parameterized lines and arcs, peg clusters, or another level family?
4. **Measured cross-engine acceptance:** event-sequence agreement threshold after the initial comparison results.

The agreed mode sequence permits solo first and requires 1v1 for the target campaign.
Static levels precede moving levels and the dedicated timing analysis.
The proposed initial action policy uses zero additional delay.
Provisional visualization defaults remain SVG previews and Lua playback.
The action schema includes launch delay from the start so later timing searches need no format change.
Hardware selection, a fixed campaign deadline, and final sampling budgets do not block M0.

## 9. Source map

| Concern | Existing source |
| --- | --- |
| Phase order and shot lifecycle | `src/engine/core.lua` |
| Aim grid and collision behavior | `src/systems/physics.lua`, `src/config.lua` |
| Match rules | `src/states/game.lua` |
| Circuit and path behavior | `src/systems/circuits.lua`, `src/systems/circuit_primitives.lua`, `src/systems/path.lua` |
| Color state | `src/systems/peg_colors.lua` |
| Trace snapshot scope | `src/systems/simulation_snapshot.lua` |
| Replay compatibility | `src/systems/replay.lua`, `src/systems/replay_library.lua` |
| Existing level exporter | `tools/dump_level.lua` |
| Existing shot search | `tools/test_style_shot.lua` |
| Architecture and mechanics | `wiki/architecture.md`, `wiki/gameplay-pipeline.md`, `wiki/game-mechanics.md` |

This draft comes from document and source review.
No new performance or parity measurements accompany it.
