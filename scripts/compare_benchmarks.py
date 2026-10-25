#!/usr/bin/env python3
"""Compare two benchmark runs for compatibility, scaling, throughput, and parity.

Usage:
  python3 scripts/compare_benchmarks.py <run1_dir_or_id> <run2_dir_or_id> [--benchmarks-dir results/benchmarks]
"""

from __future__ import annotations

import argparse
from pathlib import Path
import statistics
import sys
from typing import Any, Dict, List, Tuple

from benchmark_schema import load_manifest, read_csv_rows


def resolve_run_dir(arg: str, benchmarks_dir: Path) -> Path:
    p = Path(arg)
    if p.exists() and p.is_dir():
        return p.resolve()
    candidate = benchmarks_dir / "runs" / arg
    if candidate.exists() and candidate.is_dir():
        return candidate.resolve()
    raise FileNotFoundError(f"Could not resolve benchmark run directory from '{arg}'")


def get_medians_by_worker(rows: List[Dict[str, str]]) -> Dict[int, Dict[str, float]]:
    groups: Dict[int, List[Dict[str, str]]] = {}
    for r in rows:
        w = int(r["workers"])
        groups.setdefault(w, []).append(r)

    results: Dict[int, Dict[str, float]] = {}
    w1_wall = None
    if 1 in groups:
        w1_wall = statistics.median(float(r["wall_seconds"]) for r in groups[1])

    for w in sorted(groups.keys()):
        w_rows = groups[w]
        wall = statistics.median(float(r["wall_seconds"]) for r in w_rows)
        cands_sec = statistics.median(float(r["candidates_per_second"]) for r in w_rows)
        matches_hr = statistics.median(float(r["completed_matches_per_hour"]) for r in w_rows)
        mean_dec = statistics.median(float(r["decision_mean_seconds"]) for r in w_rows)
        p50_dec = statistics.median(float(r["decision_p50_seconds"]) for r in w_rows)
        p95_dec = statistics.median(float(r["decision_p95_seconds"]) for r in w_rows)

        # RSS
        rss_list = [
            float(r["process_rss_bytes"])
            for r in w_rows
            if r.get("process_rss_bytes") and r["process_rss_bytes"] != ""
        ]
        peak_list = [
            float(r["process_peak_rss_bytes"])
            for r in w_rows
            if r.get("process_peak_rss_bytes") and r["process_peak_rss_bytes"] != ""
        ]

        rss_med = statistics.median(rss_list) / (1024 * 1024) if rss_list else 0.0
        peak_med = statistics.median(peak_list) / (1024 * 1024) if peak_list else 0.0

        base = w1_wall if w1_wall is not None else wall
        speedup = base / wall if wall > 0 else 1.0
        efficiency = (speedup / w) * 100.0

        results[w] = {
            "wall_seconds": wall,
            "candidates_per_second": cands_sec,
            "completed_matches_per_hour": matches_hr,
            "decision_mean_seconds": mean_dec,
            "decision_p50_seconds": p50_dec,
            "decision_p95_seconds": p95_dec,
            "speedup": speedup,
            "efficiency": efficiency,
            "rss_mib": rss_med,
            "peak_rss_mib": peak_med,
        }
    return results


def compare_runs(dir1: Path, dir2: Path) -> None:
    m1 = load_manifest(dir1 / "manifest.json")
    m2 = load_manifest(dir2 / "manifest.json")

    t1_rows = read_csv_rows(dir1 / "trials.csv")
    t2_rows = read_csv_rows(dir2 / "trials.csv")

    stats1 = get_medians_by_worker(t1_rows)
    stats2 = get_medians_by_worker(t2_rows)

    print("================================================================================")
    print("BENCHMARK COMPARISON REPORT")
    print("================================================================================")
    print(f"Run 1 (Baseline):   {m1.get('run_id')} ({dir1.name})")
    print(f"Run 2 (Candidate):  {m2.get('run_id')} ({dir2.name})")
    print("--------------------------------------------------------------------------------")

    # 1. Compatibility & Provenance Check
    print("1. Compatibility & Intentional Differences:")
    compat_checks = [
        ("Workload ID", m1.get("workload_id"), m2.get("workload_id"), True),
        ("Protocol Version", m1.get("protocol_version"), m2.get("protocol_version"), True),
        ("Schema Version", m1.get("schema_version"), m2.get("schema_version"), True),
        ("Benchmark", m1.get("benchmark"), m2.get("benchmark"), True),
    ]

    all_compat = True
    for label, v1, v2, strict in compat_checks:
        match = (v1 == v2)
        tag = "[OK]" if match else ("[ERROR]" if strict else "[DIFF]")
        if strict and not match:
            all_compat = False
        print(f"  {tag} {label:18}: Run 1 = '{v1}' | Run 2 = '{v2}'")

    h1 = m1.get("host", {})
    h2 = m2.get("host", {})
    s1 = m1.get("source", {})
    s2 = m2.get("source", {})
    r1 = m1.get("runtime", {})
    r2 = m2.get("runtime", {})

    print("\n  Intentional / Environmental Differences:")
    print(f"    Host ID:         {h1.get('host_id')} vs {h2.get('host_id')}")
    print(f"    CPU Model:       {h1.get('cpu_model')} vs {h2.get('cpu_model')}")
    print(f"    Cores / SMT:     {h1.get('physical_cores')}c/{h1.get('cpu_threads')}t vs {h2.get('physical_cores')}c/{h2.get('cpu_threads')}t")
    print(f"    Git Revision:    {s1.get('git_revision', '')[:10]} (dirty={s1.get('git_dirty')}) vs {s2.get('git_revision', '')[:10]} (dirty={s2.get('git_dirty')})")
    print(f"    Harness Fingerprint: {s1.get('harness_fingerprint', '')[:16]}... vs {s2.get('harness_fingerprint', '')[:16]}...")
    print(f"    Julia Version:   {r1.get('julia_version')} ({r1.get('julia_threads')} threads) vs {r2.get('julia_version')} ({r2.get('julia_threads')} threads)")

    # 2. Gameplay Parity
    art1 = m1.get("artifacts", {}).get("canonical_gameplay_history", {})
    art2 = m2.get("artifacts", {}).get("canonical_gameplay_history", {})
    sha1 = art1.get("sha256", "unknown")
    sha2 = art2.get("sha256", "unknown")

    print("\n--------------------------------------------------------------------------------")
    print("2. Gameplay Parity:")
    print(f"  Run 1 Gameplay SHA-256: {sha1}")
    print(f"  Run 2 Gameplay SHA-256: {sha2}")
    if sha1 == sha2:
        print("  Status: [PARITY VERIFIED] Byte-for-byte identical canonical gameplay history.")
    else:
        print("  Status: [MISMATCH] Canonical gameplay histories differ! Physics or logic changed.")

    # 3. Scaling & Wall Time Table
    common_workers = sorted(set(stats1.keys()) & set(stats2.keys()))
    print("\n--------------------------------------------------------------------------------")
    print("3. Worker Scaling & Wall Times (medians):")
    print(
        f"{'Workers':>7} | {'Run 1 Wall (s)':>14} | {'Run 2 Wall (s)':>14} | {'Delta (%)':>10} | {'Run 1 Spd':>9} | {'Run 2 Spd':>9} | {'Run 1 Eff':>9} | {'Run 2 Eff':>9}"
    )
    print("-" * 96)
    for w in common_workers:
        st1 = stats1[w]
        st2 = stats2[w]
        wall1 = st1["wall_seconds"]
        wall2 = st2["wall_seconds"]
        delta_pct = ((wall2 - wall1) / wall1) * 100.0 if wall1 > 0 else 0.0
        delta_str = f"{delta_pct:+.1f}%"
        print(
            f"{w:>7} | {wall1:>14.3f} | {wall2:>14.3f} | {delta_str:>10} | {st1['speedup']:>8.2f}× | {st2['speedup']:>8.2f}× | {st1['efficiency']:>8.1f}% | {st2['efficiency']:>8.1f}%"
        )

    # 4. Throughput & Decision Latencies Table
    print("\n--------------------------------------------------------------------------------")
    print("4. Throughput & Decision Latencies (medians):")
    print(
        f"{'Workers':>7} | {'Run 1 Cands/s':>13} | {'Run 2 Cands/s':>13} | {'Ratio':>7} | {'Run 1 p50 (s)':>13} | {'Run 2 p50 (s)':>13} | {'Run 1 p95 (s)':>13} | {'Run 2 p95 (s)':>13}"
    )
    print("-" * 96)
    for w in common_workers:
        st1 = stats1[w]
        st2 = stats2[w]
        c1 = st1["candidates_per_second"]
        c2 = st2["candidates_per_second"]
        ratio = (c2 / c1) if c1 > 0 else 1.0
        print(
            f"{w:>7} | {c1:>13,.1f} | {c2:>13,.1f} | {ratio:>6.2f}× | {st1['decision_p50_seconds']:>13.3f} | {st2['decision_p50_seconds']:>13.3f} | {st1['decision_p95_seconds']:>13.3f} | {st2['decision_p95_seconds']:>13.3f}"
        )

    # 5. Memory RSS Table
    print("\n--------------------------------------------------------------------------------")
    print("5. Process Memory (medians across repeats):")
    print(
        f"{'Workers':>7} | {'Run 1 RSS (MiB)':>15} | {'Run 2 RSS (MiB)':>15} | {'Run 1 Peak (MiB)':>16} | {'Run 2 Peak (MiB)':>16}"
    )
    print("-" * 80)
    for w in common_workers:
        st1 = stats1[w]
        st2 = stats2[w]
        print(
            f"{w:>7} | {st1['rss_mib']:>15.1f} | {st2['rss_mib']:>15.1f} | {st1['peak_rss_mib']:>16.1f} | {st2['peak_rss_mib']:>16.1f}"
        )
    print("================================================================================")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run1", help="Path or Run ID for baseline run")
    parser.add_argument("run2", help="Path or Run ID for candidate run")
    parser.add_argument(
        "--benchmarks-dir",
        type=Path,
        default=Path("results/benchmarks"),
        help="Path to benchmarks base directory",
    )
    args = parser.parse_args()

    benchmarks_dir = args.benchmarks_dir.resolve()
    try:
        dir1 = resolve_run_dir(args.run1, benchmarks_dir)
        dir2 = resolve_run_dir(args.run2, benchmarks_dir)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    compare_runs(dir1, dir2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
