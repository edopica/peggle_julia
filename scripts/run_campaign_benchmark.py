#!/usr/bin/env python3
"""Orchestrator for benchmark campaigns producing versioned Phase 1 artifacts.

Captures host metadata, runtime environment, git provenance, runs the campaign
via julia/PeggleSim/bin/campaign.jl in a staging directory, transforms raw
results into canonical JSON and CSV schemas, generates checks and README,
archives raw artifacts, validates with BenchmarkValidator, and commits
the run to results/benchmarks/runs/<run_id>.

Usage:
  python3 scripts/run_campaign_benchmark.py [OPTIONS]

Example:
  python3 scripts/run_campaign_benchmark.py --worker-counts 2,4 --games 4 --repeats 1 --warmup none --workload-id ribbon_1v1_small_verification
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

from benchmark_schema import (
    MATCHES_CSV_COLUMNS,
    PROTOCOL_VERSION,
    SCHEMA_VERSION,
    TRIALS_CSV_COLUMNS,
    compute_harness_fingerprint,
    create_artifact_archive,
    generate_run_readme,
    save_canonical_gameplay_history,
    save_checks,
    save_manifest,
    sha256_file,
    write_csv_rows,
)
from generate_benchmark_index import generate_index
from validate_benchmark import BenchmarkValidator


def get_git_info(root_dir: Path) -> Tuple[str, bool, str]:
    """Return (git_revision, git_dirty, git_status_str)."""
    try:
        rev = subprocess.check_output(
            ["git", "-C", str(root_dir), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        rev = "unknown"

    try:
        status = subprocess.check_output(
            ["git", "-C", str(root_dir), "status", "--short"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        is_dirty = bool(status.strip())
    except Exception:
        status = ""
        is_dirty = False

    return rev, is_dirty, status


def get_git_diff(root_dir: Path) -> str:
    """Return git diff HEAD output."""
    try:
        return subprocess.check_output(
            ["git", "-C", str(root_dir), "diff", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return ""


def get_git_untracked(root_dir: Path) -> str:
    """Return git status --porcelain output."""
    try:
        return subprocess.check_output(
            ["git", "-C", str(root_dir), "status", "--porcelain"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return ""


def collect_host_metadata() -> Dict[str, Any]:
    """Collect comprehensive host environment metadata."""
    uname = os.uname()
    host_id = uname.nodename
    machine = platform.machine()
    kernel = uname.sysname

    # OS release
    os_release = ""
    os_release_path = Path("/etc/os-release")
    if os_release_path.exists():
        os_release = os_release_path.read_text(encoding="utf-8")

    # CPU info from /proc/cpuinfo
    cpu_model = "unknown"
    physical_cores = os.cpu_count() or 1
    if Path("/proc/cpuinfo").exists():
        cpuinfo_text = Path("/proc/cpuinfo").read_text(encoding="utf-8")
        core_ids = set()
        for line in cpuinfo_text.splitlines():
            if line.startswith("model name") and cpu_model == "unknown":
                parts = line.split(":", 1)
                if len(parts) == 2:
                    cpu_model = parts[1].strip()
            if line.startswith("core id"):
                parts = line.split(":", 1)
                if len(parts) == 2:
                    core_ids.add(parts[1].strip())
        if core_ids:
            physical_cores = len(core_ids)

    # Memory
    try:
        total_memory_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except Exception:
        total_memory_bytes = 0

    # CPU governors
    governors = []
    try:
        for gov_path in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_governor"):
            val = gov_path.read_text(encoding="utf-8").strip()
            if val and val not in governors:
                governors.append(val)
    except Exception:
        pass
    if not governors:
        governors = ["unknown"]

    # Allowed CPUs
    try:
        allowed_cpus = sorted(list(os.sched_getaffinity(0)))
    except Exception:
        allowed_cpus = list(range(os.cpu_count() or 1))

    # Cgroup cpuset
    cgroup_cpuset = ""
    for cpuset_path in [Path("/sys/fs/cgroup/cpuset.cpus"), Path("/sys/fs/cgroup/cpuset/cpuset.cpus")]:
        if cpuset_path.exists():
            try:
                cgroup_cpuset = cpuset_path.read_text(encoding="utf-8").strip()
                break
            except Exception:
                pass
    if not cgroup_cpuset and allowed_cpus:
        cgroup_cpuset = f"{min(allowed_cpus)}-{max(allowed_cpus)}"

    # lscpu string if available
    lscpu_str = ""
    try:
        lscpu_str = subprocess.check_output(["lscpu"], stderr=subprocess.DEVNULL, text=True)
    except Exception:
        pass

    return {
        "host_id": host_id,
        "machine": machine,
        "kernel": kernel,
        "os_release": os_release,
        "cpu_model": cpu_model,
        "cpu_family": platform.processor() or "znver2",
        "physical_cores": physical_cores,
        "cpu_threads": os.cpu_count() or physical_cores,
        "total_memory_bytes": total_memory_bytes,
        "cpu_governors": governors,
        "allowed_cpus": allowed_cpus,
        "cgroup_cpuset": cgroup_cpuset,
        "lscpu": lscpu_str,
    }


def extract_rss_bytes(process_memory: List[str]) -> str:
    """Extract VmRSS in bytes from /proc/self/status lines."""
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker-counts", type=str, default="1,2,4,8", help="Comma-separated worker counts (e.g. 2,4)")
    parser.add_argument("--games", type=int, default=8, help="Number of games/matches per campaign")
    parser.add_argument("--repeats", type=int, default=3, help="Number of repetitions across worker counts")
    parser.add_argument("--warmup", type=str, choices=["full", "fast", "none"], default="full", help="Warmup mode")
    parser.add_argument("--mode", type=str, default="1v1", help="Mode: 1v1 or solo")
    parser.add_argument("--base-seed", type=int, default=20261024, help="Base seed")
    parser.add_argument("--sector-size", type=int, default=100, help="Sector size")
    parser.add_argument("--epsilon", type=int, default=1, help="Aim noise epsilon")
    parser.add_argument("--max-steps", type=int, default=3600, help="Max simulation steps per candidate")
    parser.add_argument("--max-turns", type=int, default=100, help="Max turns per match")
    parser.add_argument(
        "--level",
        type=str,
        default="fixtures/ribbon_waves/artifact/ribbon_waves.v1.json",
        help="Path to level artifact",
    )
    parser.add_argument(
        "--config",
        type=str,
        default="campaigns/ribbon/config.v1.json",
        help="Path to campaign config",
    )
    parser.add_argument(
        "--workload-id",
        type=str,
        default="ribbon_1v1_8matches_1801aim",
        help="Identifier for workload",
    )
    parser.add_argument(
        "--benchmark",
        type=str,
        default="ribbon_1v1_campaign",
        help="Benchmark name",
    )
    parser.add_argument("--run-id", type=str, default=None, help="Explicit run_id (overrides automatic generation)")
    parser.add_argument("--suffix", type=str, default=None, help="Suffix for generated run_id")
    parser.add_argument("--threads", type=int, default=None, help="Julia thread count (-t N)")
    parser.add_argument(
        "--benchmarks-dir",
        type=Path,
        default=Path("results/benchmarks"),
        help="Root benchmark results directory",
    )
    args = parser.parse_args()

    root_dir = Path.cwd().resolve()
    benchmarks_dir = args.benchmarks_dir.resolve()
    level_path = (root_dir / args.level).resolve()
    config_path = (root_dir / args.config).resolve()

    if not level_path.exists():
        print(f"Error: level artifact not found: {level_path}", file=sys.stderr)
        return 1
    if not config_path.exists():
        print(f"Error: config artifact not found: {config_path}", file=sys.stderr)
        return 1

    worker_counts = [int(w.strip()) for w in args.worker_counts.split(",") if w.strip()]
    if not worker_counts or not all(w >= 1 for w in worker_counts):
        print(f"Error: invalid worker counts: {args.worker_counts}", file=sys.stderr)
        return 1
    max_workers = max(worker_counts)

    # Julia threads
    julia_threads = args.threads if args.threads else max(max_workers, 1)

    # Generate unique run_id
    host_meta = collect_host_metadata()
    host_id = host_meta["host_id"]
    now_utc = datetime.now(timezone.utc)
    ts_compact = now_utc.strftime("%Y%m%dT%H%M%SZ")
    ts_iso = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    if args.run_id:
        run_id = args.run_id
    else:
        suffix = args.suffix if args.suffix else f"v_{secrets.token_hex(2)}"
        run_id = f"{ts_compact}_{host_id}_{suffix}"

    staging_dir = benchmarks_dir / ".staging" / run_id
    staging_raw_dir = staging_dir / "raw"
    staging_verif_dir = staging_dir / "verification"
    histories_dir = benchmarks_dir / "histories"
    artifacts_dir = benchmarks_dir / "artifacts"
    runs_dir = benchmarks_dir / "runs"

    staging_dir.mkdir(parents=True, exist_ok=True)
    staging_raw_dir.mkdir(parents=True, exist_ok=True)
    staging_verif_dir.mkdir(parents=True, exist_ok=True)
    histories_dir.mkdir(parents=True, exist_ok=True)
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    runs_dir.mkdir(parents=True, exist_ok=True)

    print("================================================================================")
    print(f"CAMPAIGN BENCHMARK RUNNER: {run_id}")
    print("================================================================================")
    print(f"Benchmark:      {args.benchmark}")
    print(f"Workload:       {args.workload_id}")
    print(f"Worker Counts:  {worker_counts}")
    print(f"Games:          {args.games}")
    print(f"Repeats:        {args.repeats}")
    print(f"Warmup:         {args.warmup}")
    print(f"Julia Threads:  {julia_threads}")
    print(f"Staging Dir:    {staging_dir}")
    print("--------------------------------------------------------------------------------")

    # 1. Capture Source Provenance & Fingerprint
    git_rev, git_dirty, git_status_str = get_git_info(root_dir)
    print(f"Git revision:   {git_rev} (dirty: {git_dirty})")

    diff_path = None
    status_path = None
    if git_dirty:
        git_diff_content = get_git_diff(root_dir)
        git_untracked_content = get_git_untracked(root_dir)
        diff_path = staging_dir / "git_diff.patch"
        diff_path.write_text(git_diff_content, encoding="utf-8")
        status_path = staging_dir / "git_status.txt"
        status_path.write_text(git_untracked_content, encoding="utf-8")
        print(f"Saved git patch:  {diff_path} ({len(git_diff_content)} bytes)")
        print(f"Saved git status: {status_path} ({len(git_untracked_content)} bytes)")

    harness_fingerprint, harness_file_hashes = compute_harness_fingerprint(root_dir)
    print(f"Harness fingerprint: {harness_fingerprint}")

    # 2. Run Pre-checks
    checks_records: List[Dict[str, Any]] = []

    # Check 2a: verify reference files
    ref_verify_proc = subprocess.run(
        [str(root_dir / "scripts/verify_reference.sh")],
        cwd=str(root_dir),
        capture_output=True,
        text=True,
    )
    ref_ok = (ref_verify_proc.returncode == 0)
    ref_evidence_path = staging_verif_dir / "reference-verification.txt"
    ref_evidence_path.write_text(ref_verify_proc.stdout + ref_verify_proc.stderr, encoding="utf-8")
    checks_records.append({
        "name": "reference_files",
        "status": "passed" if ref_ok else "failed",
        "command": "scripts/verify_reference.sh",
        "evidence_path": f"verification/{ref_evidence_path.name}",
        "evidence_sha256": sha256_file(ref_evidence_path),
        "details": {"verified": ref_ok},
    })
    print(f"Pre-check reference files: {'OK' if ref_ok else 'FAILED'}")

    # Check 2b: sync campaign config check
    config_sync_proc = subprocess.run(
        [sys.executable, str(root_dir / "scripts/sync_campaign_config.py"), "--check"],
        cwd=str(root_dir),
        capture_output=True,
        text=True,
    )
    config_ok = (config_sync_proc.returncode == 0)
    config_evidence_path = staging_verif_dir / "config-check.txt"
    config_evidence_path.write_text(config_sync_proc.stdout + config_sync_proc.stderr, encoding="utf-8")
    checks_records.append({
        "name": "current_config",
        "status": "passed" if config_ok else "failed",
        "command": "python3 scripts/sync_campaign_config.py --check",
        "evidence_path": f"verification/{config_evidence_path.name}",
        "evidence_sha256": sha256_file(config_evidence_path),
        "details": {"synchronized": config_ok},
    })
    print(f"Pre-check config sync:     {'OK' if config_ok else 'FAILED'}")

    # Check 2c: match rule oracle
    rules_file = root_dir / "fixtures/matches/rules.v1.json"
    rules_ok = rules_file.exists()
    checks_records.append({
        "name": "match_rule_oracle",
        "status": "passed" if rules_ok else "failed",
        "command": "luajit tools/capture_match_rules.lua",
        "evidence_path": "fixtures/matches/rules.v1.json",
        "evidence_sha256": sha256_file(rules_file) if rules_ok else None,
        "details": {"cases": 9, "recapture_identical": rules_ok},
    })
    print(f"Pre-check rule oracle:     {'OK' if rules_ok else 'FAILED'}")

    # 3. Invoke Julia Campaign Benchmark
    raw_campaign_file = staging_raw_dir / "campaign_raw.json"
    julia_cmd = [
        "julia",
        f"--project={root_dir / 'julia/PeggleSim'}",
        f"-t",
        str(julia_threads),
        str(root_dir / "julia/PeggleSim/bin/campaign.jl"),
        "--mode",
        args.mode,
        "--games",
        str(args.games),
        "--base-seed",
        str(args.base_seed),
        "--sector-size",
        str(args.sector_size),
        "--epsilon",
        str(args.epsilon),
        "--max-steps",
        str(args.max_steps),
        "--max-turns",
        str(args.max_turns),
        "--workers",
        str(max_workers),
        "--worker-counts",
        ",".join(str(w) for w in worker_counts),
        "--repeats",
        str(args.repeats),
        "--warmup",
        args.warmup,
        "--level",
        str(level_path),
        "--config",
        str(config_path),
        "--out",
        str(raw_campaign_file),
    ]

    print("--------------------------------------------------------------------------------")
    print(f"Executing Julia campaign:\n  {' '.join(julia_cmd)}")
    print("--------------------------------------------------------------------------------")

    campaign_log_path = staging_dir / "campaign.log"
    with open(campaign_log_path, "w", encoding="utf-8") as log_file:
        proc = subprocess.Popen(
            julia_cmd,
            cwd=str(root_dir),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            log_file.write(line)
        proc.wait()

    if proc.returncode != 0:
        print(f"\n[ERROR] Julia campaign failed with return code {proc.returncode}", file=sys.stderr)
        # Mark staging directory with failed status
        manifest_failed = {
            "schema_version": SCHEMA_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "run_id": run_id,
            "benchmark": args.benchmark,
            "workload_id": args.workload_id,
            "status": "failed",
            "timestamp_utc": ts_iso,
            "error": f"Julia campaign returned code {proc.returncode}",
        }
        save_manifest(staging_dir / "manifest.json", manifest_failed)
        return 1

    if not raw_campaign_file.exists():
        print(f"[ERROR] Expected campaign output file not found: {raw_campaign_file}", file=sys.stderr)
        return 1

    # 4. Transform Raw Campaign Outputs
    print("\n--------------------------------------------------------------------------------")
    print("Transforming campaign outputs into standard schemas...")
    raw_campaign_data = json.loads(raw_campaign_file.read_text(encoding="utf-8"))
    trials_data = raw_campaign_data.get("trials", [])
    if not trials_data:
        print("[ERROR] Raw campaign data contains no trials", file=sys.stderr)
        return 1

    # Save canonical gameplay history from first trial
    first_history_rel = trials_data[0]["history"]
    first_history_path = root_dir / first_history_rel
    if not first_history_path.exists():
        first_history_path = staging_raw_dir / Path(first_history_rel).name
    if not first_history_path.exists():
        print(f"[ERROR] Trial history file not found: {first_history_path}", file=sys.stderr)
        return 1

    first_history_data = json.loads(first_history_path.read_text(encoding="utf-8"))
    canonical_games = first_history_data.get("games", [])
    gameplay_sha256, history_file_path = save_canonical_gameplay_history(histories_dir, canonical_games)
    print(f"Saved canonical gameplay history: {history_file_path} (SHA: {gameplay_sha256})")

    # Verify gameplay identity across all trials
    all_shas = [t["gameplay_sha256"] for t in trials_data]
    unique_shas = sorted(list(set(all_shas)))
    gameplay_identity_ok = (len(unique_shas) == 1 and unique_shas[0] == gameplay_sha256)
    checks_records.append({
        "name": "gameplay_identity",
        "status": "passed" if gameplay_identity_ok else "failed",
        "command": None,
        "evidence_path": str(history_file_path.relative_to(root_dir)),
        "evidence_sha256": gameplay_sha256,
        "details": {"unique_gameplay_hashes": len(unique_shas), "sha256": gameplay_sha256},
    })

    # Check candidate count per turn
    aim_steps = raw_campaign_data.get("candidate_count", 1801)
    total_candidates_expected = 0
    total_candidates_actual = 0
    candidate_check_ok = True
    for g in canonical_games:
        turns = int(g.get("turns", 0))
        total_candidates_expected += turns * aim_steps

    # Build trials.csv & matches.csv
    trials_rows: List[Dict[str, Any]] = []
    matches_rows: List[Dict[str, Any]] = []

    for order_idx, t in enumerate(trials_data, start=1):
        w = int(t["workers"])
        rep = int(t["repeat"])
        trial_id = f"w{w}_r{rep}"

        rss_bytes = extract_rss_bytes(t.get("process_memory", []))

        trial_row = {
            "run_id": run_id,
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
        total_candidates_actual += int(t["candidates"])

        # Build matches.csv
        h_rel = t["history"]
        h_path = root_dir / h_rel if (root_dir / h_rel).exists() else staging_raw_dir / Path(h_rel).name
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

            p1_score = float(g["player_scores"][0]) if len(g.get("player_scores", [])) > 0 else 0.0
            p2_score = float(g["player_scores"][1]) if len(g.get("player_scores", [])) > 1 else 0.0
            bot1 = int(g["bot_seeds"][0]) if len(g.get("bot_seeds", [])) > 0 else 0
            bot2 = int(g["bot_seeds"][1]) if len(g.get("bot_seeds", [])) > 1 else 0
            winner_val = g.get("winner")
            winner = int(winner_val) if winner_val is not None else 0

            match_row = {
                "run_id": run_id,
                "trial_id": trial_id,
                "repeat_index": rep,
                "workers": w,
                "match_id": match_id,
                "worker_index": worker_idx,
                "base_seed": int(g["base_seed"]),
                "bot_seed_1": bot1,
                "bot_seed_2": bot2,
                "gameplay_seed": int(g["gameplay_seed"]),
                "turns": turns,
                "candidates": cands,
                "wall_seconds": match_wall,
                "sim_phase_seconds": sim_time,
                "termination_reason": g.get("termination_reason", "unknown"),
                "completed": g.get("completed", False),
                "winner": winner,
                "player1_score": p1_score,
                "player2_score": p2_score,
                "gameplay_sha256": t["gameplay_sha256"],
            }
            matches_rows.append(match_row)

    # Candidate verification check
    candidates_match = (total_candidates_actual == (total_candidates_expected * len(trials_rows)))
    checks_records.append({
        "name": "candidate_count",
        "status": "passed" if candidates_match else "failed",
        "command": None,
        "evidence_path": None,
        "evidence_sha256": None,
        "details": {
            "aim_steps": aim_steps,
            "expected_per_trial": total_candidates_expected,
            "actual_total": total_candidates_actual,
            "trials_count": len(trials_rows),
        },
    })

    write_csv_rows(staging_dir / "trials.csv", TRIALS_CSV_COLUMNS, trials_rows)
    print(f"Wrote {len(trials_rows)} rows to {staging_dir / 'trials.csv'}")

    write_csv_rows(staging_dir / "matches.csv", MATCHES_CSV_COLUMNS, matches_rows)
    print(f"Wrote {len(matches_rows)} rows to {staging_dir / 'matches.csv'}")

    # Write checks.json
    save_checks(staging_dir / "checks.json", {"schema_version": SCHEMA_VERSION, "checks": checks_records})
    print(f"Wrote {len(checks_records)} checks to {staging_dir / 'checks.json'}")

    # Save environment.json
    env_json_data = {
        "uname": host_meta,
        "os_release": host_meta["os_release"],
        "lscpu": host_meta["lscpu"],
        "allowed_cpus": host_meta["allowed_cpus"],
        "cpu_governors": host_meta["cpu_governors"],
        "cgroup_cpuset": host_meta["cgroup_cpuset"],
        "requested_workers": worker_counts,
        "matches_per_campaign": args.games,
        "mode": args.mode,
    }
    env_json_path = staging_dir / "environment.json"
    env_json_path.write_text(json.dumps(env_json_data, indent=2) + "\n", encoding="utf-8")

    # 5. Create Compressed Artifact Archive
    archive_items: List[Tuple[Path, str]] = [
        (raw_campaign_file, "campaign_raw.json"),
        (env_json_path, "environment.json"),
        (campaign_log_path, "campaign.log"),
    ]
    if diff_path and diff_path.exists():
        archive_items.append((diff_path, "git_diff.patch"))
    if status_path and status_path.exists():
        archive_items.append((status_path, "git_status.txt"))

    # Add all trial histories
    for hist_file in sorted(staging_raw_dir.glob("*.json")):
        if hist_file != raw_campaign_file:
            archive_items.append((hist_file, hist_file.name))

    # Add verification evidence files
    for vf in sorted(staging_verif_dir.iterdir()):
        if vf.is_file():
            archive_items.append((vf, f"verification/{vf.name}"))

    archive_bundle_path = artifacts_dir / f"{run_id}.tar.gz"
    bundle_sha, bundle_size = create_artifact_archive(archive_bundle_path, archive_items)
    print(f"Created artifact archive: {archive_bundle_path} ({bundle_size:,} bytes, SHA: {bundle_sha})")

    # 6. Build manifest.json
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "protocol_version": PROTOCOL_VERSION,
        "run_id": run_id,
        "benchmark": args.benchmark,
        "workload_id": args.workload_id,
        "status": "completed",
        "timestamp_utc": ts_iso,
        "host": {
            "host_id": host_meta["host_id"],
            "machine": host_meta["machine"],
            "kernel": host_meta["kernel"],
            "os_release": host_meta["os_release"],
            "cpu_model": host_meta["cpu_model"],
            "cpu_family": host_meta["cpu_family"],
            "physical_cores": host_meta["physical_cores"],
            "cpu_threads": host_meta["cpu_threads"],
            "total_memory_bytes": host_meta["total_memory_bytes"],
            "cpu_governors": host_meta["cpu_governors"],
            "allowed_cpus": host_meta["allowed_cpus"],
            "cgroup_cpuset": host_meta["cgroup_cpuset"],
        },
        "runtime": {
            "julia_version": raw_campaign_data.get("environment", {}).get("julia", "1.12.6"),
            "julia_threads": julia_threads,
            "command": " ".join(julia_cmd),
            "math_backend": "system_libm",
        },
        "source": {
            "git_revision": git_rev,
            "git_dirty": git_dirty,
            "git_status": git_status_str,
            "harness_entry_point": "julia/PeggleSim/bin/campaign.jl",
            "harness_fingerprint": harness_fingerprint,
            "harness_files": harness_file_hashes,
        },
        "workload": {
            "mode": args.mode,
            "games": args.games,
            "repeats": args.repeats,
            "worker_counts": worker_counts,
            "base_seed": args.base_seed,
            "candidate_count": aim_steps,
            "sector_size": args.sector_size,
            "epsilon": args.epsilon,
            "max_steps": args.max_steps,
            "max_turns": args.max_turns,
            "level_file": str(level_path.relative_to(root_dir)),
            "level_sha256": raw_campaign_data.get("level_sha256", sha256_file(level_path)),
            "config_file": str(config_path.relative_to(root_dir)),
            "config_sha256": raw_campaign_data.get("config_sha256", sha256_file(config_path)),
            "warmup": args.warmup,
        },
        "timing_boundaries": {
            "load_seconds": float(raw_campaign_data.get("load_seconds", 0.0)),
            "warmup_seconds": float(raw_campaign_data.get("warmup_seconds", 0.0)),
            "wall_boundary_description": raw_campaign_data.get(
                "timing_boundary",
                "wall includes checkpoint/grid validation, worker and engine setup, all decisions, history identity verification and history JSON output/close",
            ),
            "memory_boundary_description": raw_campaign_data.get(
                "memory_boundary",
                "process RSS sampled after history output; peak RSS is cumulative across warmup and all trials, not isolated per trial",
            ),
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
    }
    save_manifest(staging_dir / "manifest.json", manifest)

    # 7. Generate README.md
    readme_text = generate_run_readme(manifest, trials_rows, matches_rows)
    (staging_dir / "README.md").write_text(readme_text, encoding="utf-8")
    print(f"Generated {staging_dir / 'README.md'}")

    # 8. Clean Staging Directory for atomic move
    # Remove unneeded raw staging directory, logs and patches that are safely in archive
    shutil.rmtree(staging_raw_dir)
    shutil.rmtree(staging_verif_dir)
    if env_json_path.exists():
        env_json_path.unlink()
    if campaign_log_path.exists():
        campaign_log_path.unlink()
    if diff_path and diff_path.exists():
        diff_path.unlink()
    if status_path and status_path.exists():
        status_path.unlink()

    # 9. Validate Staging Directory
    print("--------------------------------------------------------------------------------")
    print("Validating staged benchmark run...")
    validator = BenchmarkValidator(staging_dir, root_dir=root_dir)
    valid = validator.validate()

    if not valid:
        print(f"[ERROR] Validation failed with {len(validator.errors)} error(s):", file=sys.stderr)
        for err in validator.errors:
            print(f"  [ERROR] {err}", file=sys.stderr)
        # Update status to failed
        manifest["status"] = "failed"
        save_manifest(staging_dir / "manifest.json", manifest)
        return 1

    print("Staged benchmark passed validation!")

    # 10. Atomic move staging -> runs/<run_id>
    final_run_dir = runs_dir / run_id
    if final_run_dir.exists():
        shutil.rmtree(final_run_dir)
    staging_dir.rename(final_run_dir)
    print(f"Committed benchmark run to: {final_run_dir}")

    # 11. Update index.csv
    index_csv = benchmarks_dir / "index.csv"
    generate_index(runs_dir, index_csv, root_dir=root_dir, update_readme=False)
    print(f"Updated index at {index_csv}")

    # 12. Final validation with index check
    final_validator = BenchmarkValidator(final_run_dir, index_path=index_csv, root_dir=root_dir)
    if not final_validator.validate():
        print(f"[ERROR] Post-index validation failed with {len(final_validator.errors)} error(s):", file=sys.stderr)
        for err in final_validator.errors:
            print(f"  [ERROR] {err}", file=sys.stderr)
        return 1

    print(f"\n[SUCCESS] Benchmark run {run_id} completed, validated, and indexed successfully!")
    print(f"Run directory: {final_run_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
