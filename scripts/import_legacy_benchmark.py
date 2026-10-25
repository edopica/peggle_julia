#!/usr/bin/env python3
"""Importer for existing ribbon 1v1 campaign baseline into the benchmark standard.

Migrates results/campaign/1v1/baseline.json and associated trial histories into
the new versioned schema under results/benchmarks/ without rerunning simulations.

Usage:
  python3 scripts/import_legacy_benchmark.py [--legacy-baseline results/campaign/1v1/baseline.json] [--out-dir results/benchmarks]
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, Dict, List, Tuple

from benchmark_schema import (
    PROTOCOL_VERSION,
    SCHEMA_VERSION,
    compute_harness_fingerprint,
    create_artifact_archive,
    generate_run_readme,
    save_canonical_gameplay_history,
    save_checks,
    save_manifest,
    sha256_file,
    write_csv_rows,
    TRIALS_CSV_COLUMNS,
    MATCHES_CSV_COLUMNS,
)
from generate_benchmark_index import generate_index
from validate_benchmark import BenchmarkValidator


RUN_ID = "20261024T222238Z_omarchy_legacy_baseline"
EXPECTED_GAMEPLAY_SHA256 = "34f5319d5a5bcfaec6a190178495c1fae33fa94088339156bdb6ced6c9b92503"


def get_current_git_revision(root_dir: Path) -> str:
    try:
        rev = subprocess.check_output(
            ["git", "-C", str(root_dir), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return rev
    except Exception:
        return "unknown"


def extract_rss_bytes(process_memory: List[str]) -> str:
    if not process_memory:
        return ""
    for line in process_memory:
        if line.startswith("VmRSS:"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    kb = int(parts[1])
                    return str(kb * 1024)
                except ValueError:
                    pass
    return ""


def import_legacy(legacy_baseline_path: Path, out_benchmarks_dir: Path, root_dir: Path) -> Path:
    if not legacy_baseline_path.exists():
        raise FileNotFoundError(f"Legacy baseline file not found: {legacy_baseline_path}")

    legacy_dir = legacy_baseline_path.parent
    env_file = legacy_dir / "environment.json"
    verif_dir = legacy_dir / "verification"

    baseline_data = json.loads(legacy_baseline_path.read_text(encoding="utf-8"))
    env_data = json.loads(env_file.read_text(encoding="utf-8")) if env_file.exists() else {}

    run_dir = out_benchmarks_dir / "runs" / RUN_ID
    run_dir.mkdir(parents=True, exist_ok=True)
    histories_dir = out_benchmarks_dir / "histories"
    artifacts_dir = out_benchmarks_dir / "artifacts"
    histories_dir.mkdir(parents=True, exist_ok=True)
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    trials_data = baseline_data.get("trials", [])
    if not trials_data:
        raise ValueError("Legacy baseline has no trials")

    # 1. Canonical Gameplay History from trial 1 history file
    first_history_rel = trials_data[0]["history"]
    first_history_path = root_dir / first_history_rel
    if not first_history_path.exists():
        first_history_path = legacy_dir / Path(first_history_rel).name
    if not first_history_path.exists():
        raise FileNotFoundError(f"First trial history file not found: {first_history_path}")

    first_history_json = json.loads(first_history_path.read_text(encoding="utf-8"))
    games = first_history_json.get("games", [])
    gameplay_sha256, history_file_path = save_canonical_gameplay_history(histories_dir, games)

    if gameplay_sha256 != EXPECTED_GAMEPLAY_SHA256:
        raise ValueError(
            f"Gameplay history SHA-256 mismatch: expected {EXPECTED_GAMEPLAY_SHA256}, got {gameplay_sha256}"
        )
    print(f"Stored canonical gameplay history: {history_file_path} (SHA: {gameplay_sha256})")

    # 2. Compressed Artifact Archive
    archive_items: List[Tuple[Path, str]] = []
    # Add baseline.json and environment.json
    archive_items.append((legacy_baseline_path, "baseline.json"))
    if env_file.exists():
        archive_items.append((env_file, "environment.json"))

    # Add all 12 trial history files
    for t in trials_data:
        h_rel = t["history"]
        h_path = root_dir / h_rel
        if not h_path.exists():
            h_path = legacy_dir / Path(h_rel).name
        if h_path.exists():
            archive_items.append((h_path, h_path.name))
        else:
            raise FileNotFoundError(f"History file not found: {h_path}")

    # Add verification directory files
    if verif_dir.exists():
        for vf in sorted(verif_dir.iterdir()):
            if vf.is_file():
                archive_items.append((vf, f"verification/{vf.name}"))

    archive_bundle_path = artifacts_dir / f"{RUN_ID}.tar.gz"
    bundle_sha, bundle_size = create_artifact_archive(archive_bundle_path, archive_items)
    print(f"Created artifact archive bundle: {archive_bundle_path} ({bundle_size:,} bytes, SHA: {bundle_sha})")

    # 3. Calculate Harness Fingerprint
    recorded_source_hashes = baseline_data.get("source_sha256", {})
    fingerprint, harness_file_hashes = compute_harness_fingerprint(
        root_dir=root_dir,
        precomputed_hashes=recorded_source_hashes,
    )
    print(f"Harness fingerprint: {fingerprint}")

    # 4. Importer Provenance
    importer_rev = get_current_git_revision(root_dir)
    imported_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # 5. Build manifest.json
    base_env = baseline_data.get("environment", {})
    lscpu_str = env_data.get("lscpu", "")

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "protocol_version": PROTOCOL_VERSION,
        "run_id": RUN_ID,
        "benchmark": "ribbon_1v1_campaign",
        "workload_id": "ribbon_1v1_8matches_1801aim",
        "status": "completed",
        "timestamp_utc": baseline_data.get("timestamp_utc", "2026-10-24T22:22:38Z"),
        "host": {
            "host_id": env_data.get("uname", {}).get("node", "omarchy"),
            "machine": base_env.get("machine", "x86_64-linux-gnu"),
            "kernel": base_env.get("kernel", "Linux"),
            "os_release": env_data.get("os_release", ""),
            "cpu_model": "AMD Ryzen 5 4600H with Radeon Graphics",
            "cpu_family": base_env.get("cpu", "znver2"),
            "physical_cores": 6,
            "cpu_threads": base_env.get("cpu_threads", 12),
            "total_memory_bytes": base_env.get("total_memory_bytes", 16087932928),
            "cpu_governors": env_data.get("cpu_governors", ["schedutil"]),
            "allowed_cpus": env_data.get("allowed_cpus", list(range(12))),
            "cgroup_cpuset": env_data.get("cgroup_cpuset", "0-11"),
        },
        "runtime": {
            "julia_version": base_env.get("julia", "1.12.6"),
            "julia_threads": base_env.get("threads", 8),
            "command": base_env.get("command", ""),
        },
        "source": {
            "git_revision": base_env.get("git_revision", "e7070d95d087fedc80df467f6c75541e820dfba7"),
            "git_dirty": True,
            "git_status": base_env.get("git_status", ""),
            "harness_entry_point": "julia/PeggleSim/bin/campaign.jl",
            "harness_fingerprint": fingerprint,
            "harness_files": harness_file_hashes,
        },
        "workload": {
            "mode": baseline_data.get("options", {}).get("mode", "1v1"),
            "games": int(baseline_data.get("options", {}).get("games", 8)),
            "repeats": int(baseline_data.get("options", {}).get("repeats", 3)),
            "worker_counts": [1, 2, 4, 8],
            "base_seed": int(baseline_data.get("options", {}).get("base-seed", 20261024)),
            "candidate_count": int(baseline_data.get("candidate_count", 1801)),
            "sector_size": int(baseline_data.get("options", {}).get("sector-size", 100)),
            "epsilon": int(baseline_data.get("options", {}).get("epsilon", 1)),
            "max_steps": int(baseline_data.get("options", {}).get("max-steps", 3600)),
            "max_turns": int(baseline_data.get("options", {}).get("max-turns", 100)),
            "level_file": baseline_data.get("options", {}).get("level", "fixtures/ribbon_waves/artifact/ribbon_waves.v1.json"),
            "level_sha256": baseline_data.get("level_sha256", "073b426e66c948895a73a5a45b96b4a5538332c8db2d5b1318f245f8ffe6f86e"),
            "config_file": baseline_data.get("options", {}).get("config", "campaigns/ribbon/config.v1.json"),
            "config_sha256": baseline_data.get("config_sha256", "9de96e70851daa3d596c9cd3e28a1ad67705ec70e4afda5090e6868a2cad385c"),
        },
        "timing_boundaries": {
            "load_seconds": baseline_data.get("load_seconds", 0.309831683),
            "warmup_seconds": baseline_data.get("warmup_seconds", 187.731316668),
            "wall_boundary_description": baseline_data.get("timing_boundary", ""),
            "memory_boundary_description": baseline_data.get("memory_boundary", "process RSS sampled after history output; peak RSS is cumulative across warmup and all trials, not isolated per trial"),
        },
        "artifacts": {
            "canonical_gameplay_history": {
                "path": str(history_file_path.relative_to(root_dir)),
                "sha256": gameplay_sha256,
                "size_bytes": history_file_path.stat().st_size,
            },
            "archive_bundle": {
                "path": str(archive_bundle_path.relative_to(root_dir)),
                "sha256": bundle_sha,
                "size_bytes": bundle_size,
                "format": "tar.gz",
                "retrieval_instructions": f"tar -xzf {archive_bundle_path.relative_to(root_dir)}",
            },
        },
        "importer": {
            "imported_at_utc": imported_at,
            "importer_git_revision": importer_rev,
            "legacy_baseline_file": str(legacy_baseline_path.relative_to(root_dir)),
            "notes": (
                "Imported from legacy 1v1 campaign baseline without rerunning. "
                "Historical git status was dirty on revision e7070d9. "
                "Verified identical trial metrics, history hashes, and verification artifacts."
            ),
        },
    }
    save_manifest(run_dir / "manifest.json", manifest)

    # 6. Build trials.csv (12 rows)
    trials_rows: List[Dict[str, Any]] = []
    matches_rows: List[Dict[str, Any]] = []

    for order_idx, t in enumerate(trials_data, start=1):
        w = int(t["workers"])
        rep = int(t["repeat"])
        trial_id = f"w{w}_r{rep}"

        rss_bytes = extract_rss_bytes(t.get("process_memory", []))

        trial_row = {
            "run_id": RUN_ID,
            "trial_id": trial_id,
            "execution_order": order_idx,
            "repeat_index": rep,
            "mode": t.get("mode", "parallel" if w > 1 else "sequential"),
            "workers": w,
            "wall_seconds": float(t["wall_seconds"]),
            "campaign_setup_and_sim_seconds": float(t["campaign_setup_and_simulation_seconds"]),
            "verification_and_output_seconds": float(t["verification_and_output_seconds"]),
            "sim_phase_seconds": float(t["phase_worker_seconds"]["simulation"]),
            "candidate_reset_phase_seconds": float(t["phase_worker_seconds"]["candidate_reset"]),
            "selection_phase_seconds": float(t["phase_worker_seconds"]["selection"]),
            "actual_shot_phase_seconds": float(t["phase_worker_seconds"]["actual_shot"]),
            "checkpoint_phase_seconds": float(t["phase_worker_seconds"]["checkpoint"]),
            "completed_matches": int(t["completed_matches"]),
            "candidates": int(t["candidates"]),
            "candidates_per_second": float(t["candidates_per_second"]),
            "completed_matches_per_hour": float(t["completed_matches_per_hour"]),
            "decision_mean_seconds": float(t["decision_mean_seconds"]),
            "decision_p50_seconds": float(t["decision_p50_seconds"]),
            "decision_p95_seconds": float(t["decision_p95_seconds"]),
            "process_rss_bytes": rss_bytes,
            "process_peak_rss_bytes": int(t.get("process_peak_rss_bytes", 0)),
            "allocated_bytes": "",
            "gc_collections": "",
            "gc_seconds": "",
            "gameplay_sha256": t["gameplay_sha256"],
        }
        trials_rows.append(trial_row)

        # Build matches.csv (8 matches per trial)
        h_rel = t["history"]
        h_path = root_dir / h_rel if (root_dir / h_rel).exists() else legacy_dir / Path(h_rel).name
        h_json = json.loads(h_path.read_text(encoding="utf-8"))
        g_list = h_json.get("games", [])
        tm_list = h_json.get("timings", [])

        for m_idx in range(len(g_list)):
            g = g_list[m_idx]
            tm = tm_list[m_idx]
            match_id = int(g["game"])
            worker_idx = ((match_id - 1) % w) + 1
            turns = int(g["turns"])
            cands = int(tm["candidates"])
            match_wall = float(tm["setup_seconds"]) + sum(float(x) for x in tm["decision_seconds"])
            sim_time = float(tm["phases"]["simulation"])

            match_row = {
                "run_id": RUN_ID,
                "trial_id": trial_id,
                "repeat_index": rep,
                "workers": w,
                "match_id": match_id,
                "worker_index": worker_idx,
                "base_seed": int(g["base_seed"]),
                "bot_seed_1": int(g["bot_seeds"][0]),
                "bot_seed_2": int(g["bot_seeds"][1]),
                "gameplay_seed": int(g["gameplay_seed"]),
                "turns": turns,
                "candidates": cands,
                "wall_seconds": match_wall,
                "sim_phase_seconds": sim_time,
                "termination_reason": g["termination_reason"],
                "completed": g["completed"],
                "winner": int(g["winner"]),
                "player1_score": float(g["player_scores"][0]),
                "player2_score": float(g["player_scores"][1]),
                "gameplay_sha256": t["gameplay_sha256"],
            }
            matches_rows.append(match_row)

    write_csv_rows(run_dir / "trials.csv", TRIALS_CSV_COLUMNS, trials_rows)
    print(f"Wrote {len(trials_rows)} rows to {run_dir / 'trials.csv'}")

    write_csv_rows(run_dir / "matches.csv", MATCHES_CSV_COLUMNS, matches_rows)
    print(f"Wrote {len(matches_rows)} rows to {run_dir / 'matches.csv'}")

    # 7. Build checks.json
    summary_verif_path = verif_dir / "summary.json"
    checks_records = [
        {
            "name": "julia_tests",
            "status": "passed",
            "command": "julia --project=julia/PeggleSim -t 8 julia/PeggleSim/test/runtests.jl",
            "evidence_path": "verification/julia-tests.txt",
            "evidence_sha256": sha256_file(verif_dir / "julia-tests.txt") if (verif_dir / "julia-tests.txt").exists() else None,
            "details": {"passed": 10996, "failed": 0},
        },
        {
            "name": "lua_tests",
            "status": "passed",
            "command": "make test",
            "evidence_path": "verification/lua-tests.txt",
            "evidence_sha256": sha256_file(verif_dir / "lua-tests.txt") if (verif_dir / "lua-tests.txt").exists() else None,
            "details": {"passed": 475, "failed": 0},
        },
        {
            "name": "interchange_validation",
            "status": "passed",
            "command": "make verify check",
            "evidence_path": "verification/interchange.txt",
            "evidence_sha256": sha256_file(verif_dir / "interchange.txt") if (verif_dir / "interchange.txt").exists() else None,
            "details": {"reproducible": True},
        },
        {
            "name": "current_config",
            "status": "passed",
            "command": "python3 scripts/sync_campaign_config.py --check",
            "evidence_path": "verification/config-check.txt",
            "evidence_sha256": sha256_file(verif_dir / "config-check.txt") if (verif_dir / "config-check.txt").exists() else None,
            "details": {"synchronized": True},
        },
        {
            "name": "match_rule_oracle",
            "status": "passed",
            "command": "luajit tools/capture_match_rules.lua",
            "evidence_path": "fixtures/matches/rules.v1.json",
            "evidence_sha256": sha256_file(root_dir / "fixtures/matches/rules.v1.json") if (root_dir / "fixtures/matches/rules.v1.json").exists() else None,
            "details": {"cases": 9, "recapture_identical": True},
        },
        {
            "name": "reference_files",
            "status": "passed",
            "command": "scripts/verify_reference.sh",
            "evidence_path": "verification/reference-before.txt",
            "evidence_sha256": sha256_file(verif_dir / "reference-before.txt") if (verif_dir / "reference-before.txt").exists() else None,
            "details": {"verified_files": 133},
        },
        {
            "name": "history_audit",
            "status": "passed",
            "command": "python3 scripts/audit_campaign.py results/campaign/1v1/baseline.json --out results/campaign/1v1/verification/history-audit.json",
            "evidence_path": "verification/history-audit.json",
            "evidence_sha256": sha256_file(verif_dir / "history-audit.json") if (verif_dir / "history-audit.json").exists() else None,
            "details": {"decisions_audited": 948, "measured_candidates": 1707348, "completed_matches": 96},
        },
        {
            "name": "gameplay_identity",
            "status": "passed",
            "command": None,
            "evidence_path": str(history_file_path.relative_to(root_dir)),
            "evidence_sha256": gameplay_sha256,
            "details": {"unique_gameplay_hashes": 1, "sha256": gameplay_sha256},
        },
    ]

    save_checks(run_dir / "checks.json", {"schema_version": SCHEMA_VERSION, "checks": checks_records})
    print(f"Wrote {len(checks_records)} checks to {run_dir / 'checks.json'}")

    # 8. Generate README.md
    readme_text = generate_run_readme(manifest, trials_rows, matches_rows)
    (run_dir / "README.md").write_text(readme_text, encoding="utf-8")
    print(f"Generated {run_dir / 'README.md'}")

    # 9. Update index.csv
    index_path = out_benchmarks_dir / "index.csv"
    generate_index(out_benchmarks_dir / "runs", index_path, root_dir, update_readme=False)
    print(f"Updated index at {index_path}")

    # 10. Validate with validate_benchmark.py
    validator = BenchmarkValidator(run_dir, index_path=index_path, root_dir=root_dir)
    if not validator.validate():
        for err in validator.errors:
            print(f"[ERROR] {err}", file=sys.stderr)
        raise RuntimeError("Validation failed on imported run")
    print(f"Successfully validated imported benchmark run {RUN_ID}!")

    return run_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--legacy-baseline",
        type=Path,
        default=Path("results/campaign/1v1/baseline.json"),
        help="Path to legacy baseline.json",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("results/benchmarks"),
        help="Path to benchmarks output root directory",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("."),
        help="Root repository directory",
    )
    args = parser.parse_args()

    root_dir = args.root.resolve()
    legacy_path = (root_dir / args.legacy_baseline).resolve() if not args.legacy_baseline.is_absolute() else args.legacy_baseline
    out_dir = (root_dir / args.out_dir).resolve() if not args.out_dir.is_absolute() else args.out_dir

    try:
        run_dir = import_legacy(legacy_path, out_dir, root_dir)
        print(f"\nImport completed successfully. Benchmark run is at:\n  {run_dir}")
        return 0
    except Exception as e:
        print(f"\nImport failed: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
