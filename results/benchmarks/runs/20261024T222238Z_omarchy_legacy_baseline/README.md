# Benchmark Run: `20261024T222238Z_omarchy_legacy_baseline`

- **Benchmark**: `ribbon_1v1_campaign`
- **Workload**: `ribbon_1v1_8matches_1801aim`
- **Status**: `completed`
- **Timestamp (UTC)**: `2026-10-24T22:22:38Z`
- **Host**: `omarchy` (`AMD Ryzen 5 4600H with Radeon Graphics`, 6 physical cores / 12 threads)
- **Runtime**: Julia `1.12.6` with `8` threads
- **Git revision**: `e7070d95d087fedc80df467f6c75541e820dfba7` (dirty: `True`)
- **Harness fingerprint**: `0df86ae8d21b2a071d844c3d233dd9584e40fc0d95bd90df5c4bf361fc4ab16e`
- **Canonical gameplay hash**: `34f5319d5a5bcfaec6a190178495c1fae33fa94088339156bdb6ced6c9b92503`

## Worker Scaling

Summary metrics (medians across 3 repetitions):

| Workers | Campaign wall (s) | Completed matches/hour | Candidates/second | Speedup | Efficiency |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 148.948 | 193.4 | 955.2 | 1.00× | 100.0% |
| 2 | 76.578 | 376.1 | 1,858.0 | 1.95× | 97.3% |
| 4 | 46.329 | 621.6 | 3,071.1 | 3.22× | 80.4% |
| 8 | 39.234 | 734.1 | 3,626.4 | 3.80× | 47.5% |

### Wall Time by Repeat

| Workers | Repeat 1 (s) | Repeat 2 (s) | Repeat 3 (s) |
| ---: | ---: | ---: | ---: |
| 1 | 148.443 | 149.374 | 148.948 |
| 2 | 76.578 | 77.783 | 75.941 |
| 4 | 47.217 | 46.053 | 46.329 |
| 8 | 39.234 | 39.642 | 38.828 |

### Decision Latencies

| Workers | Mean decision (s) | p50 decision (s) | p95 decision (s) | Verification/output (s) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.885 | 0.983 | 6.727 | 0.0194 |
| 2 | 1.935 | 1.024 | 7.043 | 0.0190 |
| 4 | 2.128 | 1.044 | 7.668 | 0.0479 |
| 8 | 2.831 | 1.216 | 11.087 | 0.0485 |

### Phase Durations

Values are summed worker wall durations across all matches:

| Workers | Simulation (s) | Candidate reset (s) | Selection (ms) | Actual shot (ms) | Checkpoint (ms) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 146.734 | 1.674 | 8.027 | 152.138 | 7.882 |
| 2 | 150.688 | 1.660 | 7.867 | 157.293 | 8.085 |
| 4 | 165.696 | 1.838 | 9.314 | 173.121 | 7.479 |
| 8 | 220.876 | 2.119 | 8.345 | 209.641 | 7.955 |

Process RSS after output ranges from **566.8 to 599.5 MiB**.
Cumulative process peak RSS is **634.4 MiB**.

## Match Results

Seeded matches (8 matches per campaign, 12 trials, all completed):

| Match | Player 1 score | Player 2 score | Winner | Turns | Termination |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 128,460 | 146,250 | 2 | 7 | all_red_cleared |
| 2 | 248,840 | 149,963 | 1 | 10 | all_red_cleared |
| 3 | 140,770 | 325,590 | 2 | 8 | all_red_cleared |
| 4 | 233,364 | 117,240 | 1 | 9 | all_red_cleared |
| 5 | 210,860 | 308,470 | 2 | 6 | all_red_cleared |
| 6 | 839,728 | 71,650 | 1 | 11 | all_red_cleared |
| 7 | 31,533 | 7,608 | 1 | 20 | balls_exhausted |
| 8 | 104,580 | 289,420 | 2 | 8 | all_red_cleared |

## Workload Configuration

- Mode: `1v1`
- Matches: `8`
- Base seed: `20261024`
- Candidates per turn: `1801`
- Level: `fixtures/ribbon_waves/artifact/ribbon_waves.v1.json` (`073b426e66c948895a73a5a45b96b4a5538332c8db2d5b1318f245f8ffe6f86e`)
- Config: `campaigns/ribbon/config.v1.json` (`9de96e70851daa3d596c9cd3e28a1ad67705ec70e4afda5090e6868a2cad385c`)

## Importer Provenance

- **Imported at**: `2026-10-25T09:17:39Z`
- **Importer Git revision**: `5de45c742ace599e2024d0751c851d189b9ddfe9`
- **Legacy source file**: `results/campaign/1v1/baseline.json`
- **Notes**: Imported from legacy 1v1 campaign baseline without rerunning. Historical git status was dirty on revision e7070d9. Verified identical trial metrics, history hashes, and verification artifacts.

## Artifacts

- Canonical gameplay history: [`results/benchmarks/histories/34f5319d5a5bcfaec6a190178495c1fae33fa94088339156bdb6ced6c9b92503.json`](../../results/benchmarks/histories/34f5319d5a5bcfaec6a190178495c1fae33fa94088339156bdb6ced6c9b92503.json)
- Full archive bundle: [`results/benchmarks/artifacts/20261024T222238Z_omarchy_legacy_baseline.tar.gz`](../../results/benchmarks/artifacts/20261024T222238Z_omarchy_legacy_baseline.tar.gz)
