# Benchmark Run: `20261025T093415Z_omarchy_v_beb3`

- **Benchmark**: `ribbon_1v1_campaign`
- **Workload**: `ribbon_1v1_small_verification`
- **Status**: `completed`
- **Timestamp (UTC)**: `2026-10-25T09:34:15Z`
- **Host**: `omarchy` (`AMD Ryzen 5 4600H with Radeon Graphics`, 6 physical cores / 12 threads)
- **Runtime**: Julia `1.12.6` with `4` threads
- **Git revision**: `5de45c742ace599e2024d0751c851d189b9ddfe9` (dirty: `True`)
- **Harness fingerprint**: `e9bbc75d73a801e7408118e3c9e19ba35179b3e4459d224ee02c662f47bbfac0`
- **Canonical gameplay hash**: `9eb49cf1041370a850d9572430405840eab482019331d62d6ba78653aad76519`

## Worker Scaling

Summary metrics (medians across 3 repetitions):

| Workers | Campaign wall (s) | Completed matches/hour | Candidates/second | Speedup | Efficiency |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 40.138 | 358.8 | 1,525.6 | 1.00× | 50.0% |
| 4 | 23.628 | 609.5 | 2,591.6 | 1.00× | 25.0% |

### Wall Time by Repeat

| Workers | Repeat 1 (s) | Repeat 2 (s) | Repeat 3 (s) |
| ---: | ---: | ---: | ---: |
| 2 | 40.138 | - | - |
| 4 | 23.628 | - | - |

### Decision Latencies

| Workers | Mean decision (s) | p50 decision (s) | p95 decision (s) | Verification/output (s) |
| ---: | ---: | ---: | ---: | ---: |
| 2 | 2.221 | 0.995 | 7.781 | 0.6900 |
| 4 | 2.364 | 1.087 | 7.791 | 0.1647 |

### Phase Durations

Values are summed worker wall durations across all matches:

| Workers | Simulation (s) | Candidate reset (s) | Selection (ms) | Actual shot (ms) | Checkpoint (ms) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 72.924 | 0.768 | 1285.747 | 438.134 | 89.771 |
| 4 | 79.485 | 0.792 | 4.500 | 82.394 | 6.768 |

Process RSS after output ranges from **605.3 to 631.4 MiB**.
Cumulative process peak RSS is **639.1 MiB**.

## Match Results

Seeded matches (4 matches per campaign, 2 trials, all completed):

| Match | Player 1 score | Player 2 score | Winner | Turns | Termination |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 128,460 | 146,250 | 2 | 7 | all_red_cleared |
| 2 | 248,840 | 149,963 | 1 | 10 | all_red_cleared |
| 3 | 140,770 | 325,590 | 2 | 8 | all_red_cleared |
| 4 | 233,364 | 117,240 | 1 | 9 | all_red_cleared |

## Workload Configuration

- Mode: `1v1`
- Matches: `4`
- Base seed: `20261024`
- Candidates per turn: `1801`
- Level: `fixtures/ribbon_waves/artifact/ribbon_waves.v1.json` (`073b426e66c948895a73a5a45b96b4a5538332c8db2d5b1318f245f8ffe6f86e`)
- Config: `campaigns/ribbon/config.v1.json` (`9de96e70851daa3d596c9cd3e28a1ad67705ec70e4afda5090e6868a2cad385c`)


## Artifacts

- Canonical gameplay history: [`results/benchmarks/histories/9eb49cf1041370a850d9572430405840eab482019331d62d6ba78653aad76519.json`](../../results/benchmarks/histories/9eb49cf1041370a850d9572430405840eab482019331d62d6ba78653aad76519.json)
- Full archive bundle: [`results/benchmarks/artifacts/20261025T093415Z_omarchy_v_beb3.tar.gz`](../../results/benchmarks/artifacts/20261025T093415Z_omarchy_v_beb3.tar.gz)
