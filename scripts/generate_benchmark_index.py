#!/usr/bin/env python3
"""Generate benchmark index.csv and update README.md in run directories.

Scans results/benchmarks/runs/*/manifest.json and generates
results/benchmarks/index.csv. Also regenerates README.md in each run directory
from its trials.csv and matches.csv.

Usage:
  python3 scripts/generate_benchmark_index.py [--runs-dir results/benchmarks/runs] [--out results/benchmarks/index.csv]
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Any, Dict, List

from benchmark_schema import (
    INDEX_CSV_COLUMNS,
    generate_run_readme,
    load_manifest,
    read_csv_rows,
    write_csv_rows,
)


def generate_index(
    runs_dir: Path, out_path: Path, root_dir: Path, update_readme: bool = True
) -> List[Dict[str, Any]]:
    if not runs_dir.exists():
        print(f"Runs directory does not exist: {runs_dir}")
        return []

    manifest_files = sorted(runs_dir.glob("*/manifest.json"))
    index_rows: List[Dict[str, Any]] = []

    for manifest_path in manifest_files:
        run_dir = manifest_path.parent
        try:
            m = load_manifest(manifest_path)
        except Exception as e:
            print(f"Warning: could not read {manifest_path}: {e}", file=sys.stderr)
            continue

        run_id = m.get("run_id", run_dir.name)
        benchmark = m.get("benchmark", "")
        timestamp = m.get("timestamp_utc", "")
        host = m.get("host", {})
        host_id = host.get("host_id", "")
        source = m.get("source", {})
        git_rev = source.get("git_revision", "")
        workload_id = m.get("workload_id", "")
        protocol_v = m.get("protocol_version", "")
        schema_v = m.get("schema_version", "")
        status = m.get("status", "")
        rel_manifest = str(manifest_path.resolve().relative_to(root_dir.resolve()))

        index_rows.append(
            {
                "run_id": run_id,
                "benchmark": benchmark,
                "timestamp_utc": timestamp,
                "host_id": host_id,
                "git_revision": git_rev,
                "workload_id": workload_id,
                "protocol_version": protocol_v,
                "schema_version": schema_v,
                "status": status,
                "manifest_path": rel_manifest,
            }
        )

        if update_readme:
            trials_path = run_dir / "trials.csv"
            matches_path = run_dir / "matches.csv"
            trials_rows = read_csv_rows(trials_path) if trials_path.exists() else []
            matches_rows = read_csv_rows(matches_path) if matches_path.exists() else []
            readme_text = generate_run_readme(m, trials_rows, matches_rows)
            readme_path = run_dir / "README.md"
            readme_path.write_text(readme_text, encoding="utf-8")

    # Sort index by timestamp_utc ascending, then run_id
    index_rows.sort(key=lambda r: (r["timestamp_utc"], r["run_id"]))

    write_csv_rows(out_path, INDEX_CSV_COLUMNS, index_rows)
    return index_rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runs-dir",
        type=Path,
        default=Path("results/benchmarks/runs"),
        help="Path to runs directory",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("results/benchmarks/index.csv"),
        help="Path to output index.csv",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("."),
        help="Root repository directory",
    )
    parser.add_argument(
        "--no-readme",
        action="store_true",
        help="Do not update run README.md files",
    )
    args = parser.parse_args()

    root_dir = args.root.resolve()
    runs_dir = (root_dir / args.runs_dir).resolve() if not args.runs_dir.is_absolute() else args.runs_dir
    out_path = (root_dir / args.out).resolve() if not args.out.is_absolute() else args.out

    rows = generate_index(runs_dir, out_path, root_dir, update_readme=not args.no_readme)
    print(f"Indexed {len(rows)} benchmark run(s) -> {out_path}")
    for r in rows:
        print(f"  - {r['run_id']} [{r['workload_id']}] {r['host_id']} ({r['status']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
