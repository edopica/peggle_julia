# M0 reference definition

This document freezes the reference revision, configuration, candidate action
space, and decision boundary used by every M0 measurement and by later
milestones.

## 1. Reference revision

| Field | Value |
| --- | --- |
| Repository | `git@github.com:edopica/peggle_evolved.git` |
| Revision | `d17f6e7089b6e761f4367fc6a6dcd5b4da0309b9` (`d17f6e7`) |
| Tree hash | `3dc7ddfe19916e149d2531b20c73463c28a202c8` |
| Config hash (`src/config.lua`) | `455757c900c604563865b5195eda2f31cfeba3d8666b6d782390e38c47e91d4d` |
| Vendored tree | `reference/peggle_evolved/` |
| Manifest | `reference/files.sha256` (133 files) |

The revision is the committed `HEAD` at M0 start. Uncommitted working-tree
edits to `src/systems/path.lua` and `src/systems/physics.lua` are excluded
because a reference must be reconstructible from a commit. If those edits are
committed, the pin must be advanced and every fixture and baseline re-captured.

`scripts/verify_reference.sh` checks the vendored tree against the manifest.

## 2. Authoritative constants

From `src/config.lua` at the pinned revision:

| Constant | Value | Role |
| --- | --- | --- |
| `fixed_dt` | `1/60` s | Simulation timestep. All candidates advance in fixed steps. |
| `gravity` | `1000` px/s² | Ball acceleration. |
| `launch_speed` | `800` px/s | Launch speed; direction is the snapped aim angle. |
| `ball_radius` | `6` px | Launched ball radius. |
| `restitution` | `0.8` | Peg bounce factor. |
| `wall_damping` | `0.8` | Wall bounce factor. |
| `graze_tolerance` | `0.5` px | Visual-overlap scoring band. |
| `toi_epsilon` | `1e-9` s | Collision tie-break window (unchanged in M0). |
| `safe_t_margin` | `0.001` s | Time pulled back from impact. |
| `overlap_push_margin` | `0.1` px | Depenetration margin. |
| `ball_ball_collisions` | `true` | Launched balls collide as equal-mass circles. |
| `aim_angle_limit` | `math.rad(90)` = π/2 | Half-arc of the aim range. |
| `aim_discretization_steps` | `1800` | Aim grid intervals (see §3). |
| `purple_pegs_per_turn` | `1` | Blue-to-purple promotion count per turn. |
| `bucket_bonus` | `10000` | Solo/baseline bucket catch points. |
| `ball_still_speed` | `18` px/s | Stall threshold. |
| `clear_still_time` | `0.6` s | Still time before clearing. |
| `clear_no_score_time` | `10.5` s | No-score time before clearing. |
| `starting_balls` | `10` | Balls per player (match layer; M5). |

The full config is vendored. Any change to these constants advances the
reference revision.

## 3. Candidate grid

The aim grid is derived from the game's own snapping function,
`Physics.getSnappedAimAngle` (`reference/peggle_evolved/src/systems/physics.lua`,
pinned revision), not from a separate floating-point loop.

```text
mid       = pi / 2
limit     = Config.aim_angle_limit
min_angle = mid - limit
span      = 2 * limit
steps     = Config.aim_discretization_steps          -- 1800
angle(i)  = min_angle + (i / steps) * span           -- i in 0..1800
```

With the pinned config the arc is `[0, pi]`, and there are **1801 legal aim
indices** (0 through 1800 inclusive). The harness verifies before every sweep
that `getSnappedAimAngle(angle(i)) == angle(i)` for all 1801 indices and
aborts if any mismatch exists.

Index 0 aims along `+x` (right), index 900 straight down, and index 1800
along `-x` (left). The game's per-key aim stepping also produces exactly these
indices because it snaps before adding `(2*limit)/steps`.

The style-shot brute-forcer (`tools/test_style_shot.lua`) uses a separate
0.1-degree loop with snapping disabled. It is **not** the definition of the
bot action space and is not used for M0 measurements.

## 4. Decision boundary: ready-to-aim, zero delay

The decision checkpoint for M0 is the state immediately after
`Engine:resetTurn` completes and before any call to `Engine:update`:

- level pegs built, boundary-filtered, transformed, and ordered;
- peg types assigned by the seeded `PegColors.init` and the first purple
  promotion applied by `PegColors.assign_next_purple_peg`;
- one (or N) unlaunched ball(s) placed at `(virtual_width/2, 50)` (single-ball)
  or evenly spread on y = 50 (multiball synthetic workload);
- bucket constructed at its initial phase;
- `shot_id`/step counters, event journal, command buffer, style/ball-state/
  slide-inversion trackers reset;
- ball identity namespace starting fresh per candidate because each candidate
  is evaluated on a fresh `Engine` instance.

The bot action is applied immediately: set `current_aim_angle` to the grid
angle and call `launchBalls()` with no intervening `update`. The launch delay
is zero fixed steps. The action schema already reserves an integer launch
delay so the later timing phase needs no format change.

For static levels `level_circuits` is empty, so no circuit state advances.
Moving-level checkpoints enter the workload in the motion phase (M8).

## 5. Action and result schemas

The M1 versioned forms of these schemas are defined in
`wiki/context/interchange.md` and `schemas/action.v1.schema.json`,
`schemas/shot-result.v1.schema.json`.

`ShotAction` (M0 form):

```text
aim_index : integer  0..1800
delay     : integer  fixed steps to wait before launch (always 0 in M0)
```

`ShotResult` features captured per candidate (raw JSONL keys in parentheses):

- `steps` — fixed steps simulated until all balls were removed or the step cap;
- `completed` — true when the shot ended before the cap;
- `reason` — `fell_out`, `bucket_caught`, `all_balls_removed`, or `step_limit`;
- `score`, `peg_score`, `bonus`, `style_points` — score components;
- `style_total`, `styles` — awarded style shots and their counts;
- `pegs_hit`, `reds_hit`, `multiplier`, `is_fever` — board state at shot end;
- `balls` — number of simultaneously launched balls;
- `mem_kb` — Lua heap after the candidate.

Phase timings in microseconds: `t_init`, `t_reset`, `t_sim`, `t_extract`, and
the output write (`t_output`, recorded in the sweep loop).

## 6. Observation modes in the harness

The harness runs the **summary** observation mode: it keeps the authoritative
engine state and score components, and does not retain step records or write
trace files per candidate. `engine.retain_shot_timeline` stays `false` and no
trace exporter is installed, so the candidate cost excludes diagnostic trace
output. Diagnostic modes are exercised by the reference's existing exporters
and enter the comparison protocol in M3/M4.

## 7. Known deviations and open items

- The reference `toi_epsilon` remains `1e-9`; the proposed `1e-6` tolerance is
  a separate physics decision and is not applied.
- Collision ties keep the current candidate-index scan order.
- The first purple promotion happens inside `resetTurn`; RNG state at the
  checkpoint therefore depends on the seeded level initialization. The M2
  checkpoint must capture the RNG state explicitly; M0 rebuilds it by
  re-running `setupLevel` per candidate.
- `resetTurn` in M0 is not yet a full checkpoint restore. M0 measures its
  current cost; M2 replaces it with an explicit capture/reset contract that
  also restores RNG, purple queues, circuit phases, and bucket phase.
