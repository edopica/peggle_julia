# Campaign diagnostics 20261025T121437Z_omarchy_e49038

Protocol: `campaign-diagnostics/1`. Gameplay SHA-256: `34f5319d5a5bcfaec6a190178495c1fae33fa94088339156bdb6ced6c9b92503`.

Every measured trial and warmup has identical gameplay; all matches complete.

Times are median [min, max] seconds. Each worker setting uses a fresh process with a fixed Julia/GC thread budget. Profilers are excluded from timing rows.

| Workers | Phases | N | End-to-end s | Setup/simulation s | Verification/output s | Allocated MiB | GC s | GC collections |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | True | 3 | 148.428 [147.980, 150.196] | 148.410 [147.962, 150.178] | 0.018 [0.018, 0.018] | 2017.384 [2017.351, 2017.493] | 0.232 [0.226, 0.236] | 127.000 [127.000, 129.000] |
| 1 | False | 3 | 149.514 [146.920, 149.873] | 149.492 [146.902, 149.853] | 0.020 [0.018, 0.022] | 2017.417 [2017.357, 2017.476] | 0.237 [0.234, 0.246] | 128.000 [127.000, 129.000] |
| 2 | True | 3 | 81.170 [80.458, 81.783] | 81.152 [80.440, 81.765] | 0.018 [0.018, 0.018] | 2017.465 [2017.399, 2017.498] | 0.229 [0.225, 0.241] | 124.000 [123.000, 128.000] |
| 2 | False | 3 | 80.788 [80.663, 81.471] | 80.769 [80.645, 81.453] | 0.019 [0.018, 0.019] | 2017.445 [2017.381, 2017.450] | 0.231 [0.224, 0.243] | 124.000 [123.000, 124.000] |
| 4 | True | 3 | 46.112 [45.694, 46.801] | 46.092 [45.675, 46.781] | 0.020 [0.019, 0.020] | 2017.433 [2017.385, 2017.516] | 0.251 [0.250, 0.260] | 116.000 [114.000, 116.000] |
| 4 | False | 3 | 45.648 [45.522, 46.835] | 45.629 [45.503, 46.817] | 0.019 [0.018, 0.019] | 2017.421 [2017.352, 2017.457] | 0.258 [0.253, 0.260] | 116.000 [115.000, 118.000] |
| 8 | True | 3 | 35.381 [35.275, 38.143] | 35.362 [35.257, 38.125] | 0.018 [0.018, 0.019] | 2017.443 [2017.410, 2017.459] | 0.411 [0.409, 0.415] | 105.000 [99.000, 107.000] |
| 8 | False | 3 | 34.422 [34.328, 37.737] | 34.404 [34.279, 37.688] | 0.049 [0.018, 0.049] | 2017.368 [2017.364, 2017.446] | 0.414 [0.410, 0.414] | 104.000 [101.000, 105.000] |

Workers 1: paired instrumentation overhead 0.216 [-1.026, 1.026]%; positive means timers enabled was slower. Three pairs describe variability; small differences do not establish a gain.


Workers 2: paired instrumentation overhead 0.473 [-1.244, 1.389]%; positive means timers enabled was slower. Three pairs describe variability; small differences do not establish a gain.


Workers 4: paired instrumentation overhead 1.294 [-2.435, 2.525]%; positive means timers enabled was slower. Three pairs describe variability; small differences do not establish a gain.


Workers 8: paired instrumentation overhead 2.478 [1.076, 3.068]%; positive means timers enabled was slower. Three pairs describe variability; small differences do not establish a gain.


GC fraction is available from each raw trial as gc_seconds / wall_seconds; GC time is process-wide elapsed collection time, not aggregate GC-thread CPU time.

Memory values below are MiB, with no forced GC between campaign completion and post-campaign RSS. Loaded/warmed values are snapshots, not live object sizes. Campaign peaks are external samples; lifetime peaks include loading, compilation and both warmups.

| Workers | Loaded RSS | Warmed RSS | Post-campaign RSS | Sampled campaign peak | Lifetime peak |
| --- | --- | --- | --- | --- | --- |
| 1 | 598.8 | 611.8 | 611.5 | 654.8 | 654.6 |
| 2 | 594.3 | 640.4 | 666.2 | 710.7 | 710.6 |
| 4 | 603.7 | 629.5 | 662.3 | 708.7 | 734.0 |
| 8 | 601.2 | 672.3 | 683.3 | 731.8 | 731.3 |

CPU profile repeat 1: 13813 primary-thread samples across the complete campaign and output.

| Exclusive stack category | Samples | Percent |
| --- | --- | --- |
| precise_collision_and_physics | 5982 | 43.31% |
| broad_phase | 2756 | 19.95% |
| scoring_and_events | 2586 | 18.72% |
| engine_updates | 2446 | 17.71% |
| gc | 23 | 0.17% |
| runtime_or_other | 19 | 0.14% |
| campaign_and_reset | 1 | 0.01% |

Allocation profile repeat 1: 132009 sampled events at rate 0.01. Largest sources by sampled bytes (not exact totals):

- `Peg at level.jl:41 [inlined]`: 16,475,200 sampled bytes
- `restore!(sim::PeggleSim.SimState, ckpt::PeggleSim.Checkpoint) at checkpoint.jl:872`: 2,911,228 sampled bytes
- `FeverDivider at state.jl:46 [inlined]`: 410,736 sampled bytes
- `restore!(sim::PeggleSim.SimState, ckpt::PeggleSim.Checkpoint) at checkpoint.jl:902`: 397,440 sampled bytes
- `FeverBucketSpec at state.jl:40 [inlined]`: 228,768 sampled bytes
- `BallState at state.jl:88 [inlined]`: 114,720 sampled bytes
- `runtime_or_other`: 103,493 sampled bytes
- `MatchState at state.jl:296 [inlined]`: 92,224 sampled bytes
- `_match_from_checkpoint at checkpoint.jl:776 [inlined]`: 91,136 sampled bytes
- `MatchPlayer at state.jl:290 [inlined]`: 88,896 sampled bytes

GC seconds and collection counts are process-wide deltas over setup/simulation plus verification/output, measured with Julia's `@timed`; explicit pre-trial GC is excluded. Allocation profiling is a separate campaign. Strict-zero shot probes do not imply a zero-allocation campaign.

CPU categories use the deepest recognized stack frame; inlined code and native GC constrain attribution. Precise collision/physics includes integration and resolution. Tree and portable stack counts retain the detail needed to refine attribution. Category percentages use the primary campaign thread, excluding parked worker threads; all-thread trees are retained. Samples are not CPU cycle counts.

Each setting warms both variants with the entire campaign. Enabled/disabled order alternates by repetition. Match scheduling is unchanged. Decision latency and match setup timers remain in both variants; the experiment removes candidate/phase timers only. RSS is sampled externally every 100 ms by default, and can miss brief peaks. Worker counts run sequentially in requested order; thermal, frequency, SMT and contention remain uncontrolled.

The original end-to-end boundary includes grid/checkpoint validation, engine setup, decisions, gameplay equality verification, JSON output and close. Hash computation, profile decoding and final summary writing remain outside it. Raw records separately retain process wall time, entry/load duration, artifact load, full warmup and measured compilation times; warmup includes compilation and is not pure startup cost. `@timed` totals include the small enclosing diagnostic wrapper. This protocol is separate from historical throughput protocol 1.0.0.

Raw histories, samples, logs, profiles and source snapshot are in the checksum-verified archive named in manifest.json. It is currently a local Git artifact; external durable archival remains unconfigured. No historical evidence was removed.
