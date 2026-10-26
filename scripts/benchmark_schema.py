#!/usr/bin/env python3
"""Standard benchmark result, schema, and provenance definitions for julia_clone.

Defines schemas, canonical JSON encoding, hashing, archive creation, and I/O
helpers for benchmarks under results/benchmarks/.
"""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import re
import statistics
import subprocess
import tarfile
from typing import Any, Dict, List, Optional, Tuple, Union

SCHEMA_VERSION = "1.0.0"
PROTOCOL_VERSION = "1.0.0"

MAX_SAFE_INTEGER = 9007199254740992  # 2^53

HARNESS_DEFAULT_FILES = [
    "campaigns/ribbon/config.source.lua",
    "campaigns/ribbon/game.source.lua",
    "julia/PeggleSim/Manifest.toml",
    "julia/PeggleSim/bin/campaign.jl",
    "julia/PeggleSim/src/campaign.jl",
    "scripts/sync_campaign_config.jl",
]

INDEX_CSV_COLUMNS = [
    "run_id",
    "benchmark",
    "timestamp_utc",
    "host_id",
    "git_revision",
    "workload_id",
    "protocol_version",
    "schema_version",
    "status",
    "manifest_path",
]

TRIALS_CSV_COLUMNS = [
    "run_id",
    "trial_id",
    "execution_order",
    "repeat_index",
    "mode",
    "workers",
    "wall_seconds",
    "campaign_setup_and_sim_seconds",
    "verification_and_output_seconds",
    "sim_phase_seconds",
    "candidate_reset_phase_seconds",
    "selection_phase_seconds",
    "actual_shot_phase_seconds",
    "checkpoint_phase_seconds",
    "completed_matches",
    "candidates",
    "candidates_per_second",
    "completed_matches_per_hour",
    "decision_mean_seconds",
    "decision_p50_seconds",
    "decision_p95_seconds",
    "process_rss_bytes",
    "process_peak_rss_bytes",
    "allocated_bytes",
    "gc_collections",
    "gc_seconds",
    "gameplay_sha256",
]

MATCHES_CSV_COLUMNS = [
    "run_id",
    "trial_id",
    "repeat_index",
    "workers",
    "match_id",
    "worker_index",
    "base_seed",
    "bot_seed_1",
    "bot_seed_2",
    "gameplay_seed",
    "turns",
    "candidates",
    "wall_seconds",
    "sim_phase_seconds",
    "termination_reason",
    "completed",
    "winner",
    "player1_score",
    "player2_score",
    "gameplay_sha256",
]


# ==============================================================================
# Project Canonical JSON & Hashing
# ==============================================================================

def canonical_json(val: Any) -> str:
    """Encode an object using the project canonical JSON convention.

    Compatible with tools/canonical_json.lua and PeggleSim.canonical_json.
    This is not RFC 8785: negative zero and %.17g formatting are preserved.
    - Dict keys sorted lexicographically (Unicode code point order).
    - Array order preserved.
    - Integral numbers with |v| < 2^53 emitted as integers without decimal point.
    - Other floats formatted with %.17g.
    - Negative zero preserved as '-0'.
    - NaN and infinities rejected.
    - No whitespace between tokens.
    """
    parts: list[str] = []
    _encode_canonical_value(val, parts)
    return "".join(parts)


def _encode_canonical_value(val: Any, parts: list[str]) -> None:
    if val is None:
        parts.append("null")
    elif isinstance(val, bool):
        parts.append("true" if val else "false")
    elif isinstance(val, int):
        parts.append(str(val))
    elif isinstance(val, float):
        if math.isnan(val) or math.isinf(val):
            raise ValueError(f"CanonicalJSON: cannot encode NaN or infinity: {val}")
        if val == 0.0:
            if math.copysign(1.0, val) < 0.0:
                parts.append("-0")
            else:
                parts.append("0")
        elif val.is_integer() and abs(val) < MAX_SAFE_INTEGER:
            parts.append(str(int(val)))
        else:
            parts.append(f"{val:.17g}")
    elif isinstance(val, str):
        parts.append(json.dumps(val, ensure_ascii=False))
    elif isinstance(val, (list, tuple)):
        parts.append("[")
        for i, item in enumerate(val):
            if i > 0:
                parts.append(",")
            _encode_canonical_value(item, parts)
        parts.append("]")
    elif isinstance(val, dict):
        parts.append("{")
        keys = sorted(str(k) for k in val.keys())
        for i, k in enumerate(keys):
            if i > 0:
                parts.append(",")
            parts.append(json.dumps(k, ensure_ascii=False))
            parts.append(":")
            _encode_canonical_value(val[k], parts)
        parts.append("}")
    else:
        raise TypeError(f"CanonicalJSON: cannot encode type {type(val)}")


def sha256_bytes(data: bytes) -> str:
    """Return lowercase hex SHA-256 digest of bytes."""
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Union[str, Path]) -> str:
    """Return lowercase hex SHA-256 digest of file contents."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def compute_harness_fingerprint(
    root_dir: Path,
    files: Optional[List[str]] = None,
    precomputed_hashes: Optional[Dict[str, str]] = None,
) -> Tuple[str, Dict[str, str]]:
    """Compute harness fingerprint from sorted manifest of relevant source files.

    Returns (fingerprint_sha256, {relpath: file_sha256}).
    """
    if files is None:
        files = HARNESS_DEFAULT_FILES

    file_hashes: Dict[str, str] = {}
    manifest_lines: List[str] = []

    for rel_path in sorted(files):
        if precomputed_hashes and rel_path in precomputed_hashes:
            h = precomputed_hashes[rel_path]
        else:
            full_path = root_dir / rel_path
            if not full_path.exists():
                raise FileNotFoundError(f"Harness file not found: {full_path}")
            h = sha256_file(full_path)
        file_hashes[rel_path] = h
        manifest_lines.append(f"{h}  {rel_path}\n")

    manifest_content = "".join(manifest_lines)
    fingerprint = sha256_bytes(manifest_content.encode("utf-8"))
    return fingerprint, file_hashes


# ==============================================================================
# Canonical Gameplay History & Artifact Handling
# ==============================================================================

def save_canonical_gameplay_history(
    histories_dir: Path, games: list
) -> Tuple[str, Path]:
    """Serialize games using project canonical JSON and write to <sha256>.json.

    Returns (gameplay_sha256, path_to_history_file).
    """
    histories_dir.mkdir(parents=True, exist_ok=True)
    c_json = canonical_json(games)
    c_bytes = c_json.encode("utf-8")
    h = sha256_bytes(c_bytes)
    out_path = histories_dir / f"{h}.json"
    if not out_path.exists():
        out_path.write_bytes(c_bytes)
    return h, out_path


def create_artifact_archive(
    archive_path: Path,
    file_items: List[Tuple[Path, str]],
) -> Tuple[str, int]:
    """Create a compressed tar.gz bundle containing file_items [(abs_path, arcname)].

    Deterministic ordering of entries in archive.
    Returns (sha256, size_bytes).
    """
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    sorted_items = sorted(file_items, key=lambda x: x[1])

    with tarfile.open(archive_path, "w:gz") as tar:
        for src_path, arcname in sorted_items:
            tar.add(src_path, arcname=arcname)

    digest = sha256_file(archive_path)
    size = archive_path.stat().st_size
    return digest, size


# ==============================================================================
# CSV & Manifest I/O
# ==============================================================================

def read_csv_rows(path: Path) -> List[Dict[str, str]]:
    """Read CSV file and return list of row dictionaries."""
    if not path.exists():
        raise FileNotFoundError(f"CSV file not found: {path}")
    with open(path, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        return list(reader)


def write_csv_rows(
    path: Path, fieldnames: List[str], rows: List[Dict[str, Any]]
) -> None:
    """Write list of row dictionaries to CSV file with documented minimal quoting."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=fieldnames,
            quoting=csv.QUOTE_MINIMAL,
            lineterminator="\n",
        )
        writer.writeheader()
        for r in rows:
            out_row = {}
            for col in fieldnames:
                v = r.get(col)
                if v is None:
                    out_row[col] = ""
                elif isinstance(v, float):
                    out_row[col] = f"{v:.17g}" if not v.is_integer() else str(int(v))
                elif isinstance(v, bool):
                    out_row[col] = "true" if v else "false"
                else:
                    out_row[col] = str(v)
            writer.writerow(out_row)


def load_manifest(path: Path) -> Dict[str, Any]:
    """Load manifest.json."""
    if not path.exists():
        raise FileNotFoundError(f"Manifest not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def save_manifest(path: Path, manifest: Dict[str, Any]) -> None:
    """Save manifest.json formatted cleanly."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def load_checks(path: Path) -> Dict[str, Any]:
    """Load checks.json."""
    if not path.exists():
        raise FileNotFoundError(f"Checks file not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def save_checks(path: Path, checks: Dict[str, Any]) -> None:
    """Save checks.json."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(checks, indent=2) + "\n", encoding="utf-8")


# ==============================================================================
# README Summary Generator
# ==============================================================================

def generate_run_readme(
    manifest: Dict[str, Any],
    trials_rows: List[Dict[str, Any]],
    matches_rows: List[Dict[str, Any]],
) -> str:
    """Generate Markdown README from manifest and CSV rows."""
    run_id = manifest.get("run_id", "unknown")
    benchmark = manifest.get("benchmark", "unknown")
    workload_id = manifest.get("workload_id", "unknown")
    timestamp = manifest.get("timestamp_utc", "unknown")
    host = manifest.get("host", {})
    runtime = manifest.get("runtime", {})
    source = manifest.get("source", {})
    workload = manifest.get("workload", {})
    importer = manifest.get("importer")

    # Aggregate worker scaling stats
    worker_groups: Dict[int, List[Dict[str, Any]]] = {}
    for r in trials_rows:
        w = int(r["workers"])
        worker_groups.setdefault(w, []).append(r)

    sorted_workers = sorted(worker_groups.keys())
    repeat_indices = sorted({int(r["repeat_index"]) for r in trials_rows})
    repeat_header = "| Workers | " + " | ".join(f"Repeat {r} (s)" for r in repeat_indices) + " |"
    repeat_separator = "| ---: |" + " ---: |" * len(repeat_indices)
    repeat_counts = {len(rows) for rows in worker_groups.values()}
    repetitions = (f"{next(iter(repeat_counts))} repetition(s) per worker count"
                   if len(repeat_counts) == 1 else "the available repetitions per worker count")
    completion_summary = ("all completed" if matches_rows and
                          all(str(m.get("completed", "")).lower() == "true" for m in matches_rows)
                          else "completion status recorded below")

    def artifact_link(name: str) -> str:
        item = manifest.get("artifacts", {}).get(name, {})
        location = item.get("uri") or item.get("path")
        if not location:
            return "unavailable"
        if "://" in location or location.startswith("/"):
            target = location
        else:
            # Manifest artifact paths are repository-relative; README lives at
            # results/benchmarks/runs/<id>/README.md.
            import os
            target = os.path.relpath(location, f"results/benchmarks/runs/{run_id}")
        return f"[`{location}`](<{target}>)"

    # Baseline wall time for worker 1
    w1_wall_median = 0.0
    if 1 in worker_groups:
        w1_walls = [float(r["wall_seconds"]) for r in worker_groups[1]]
        w1_wall_median = statistics.median(w1_walls)

    scaling_rows = []
    repeat_rows = []
    latency_rows = []
    phase_rows = []

    for w in sorted_workers:
        rows = worker_groups[w]
        walls = [float(r["wall_seconds"]) for r in rows]
        cands_sec = [float(r["candidates_per_second"]) for r in rows]
        matches_hr = [float(r["completed_matches_per_hour"]) for r in rows]

        wall_med = statistics.median(walls)
        cands_med = statistics.median(cands_sec)
        matches_hr_med = statistics.median(matches_hr)
        speedup = (w1_wall_median / wall_med) if wall_med > 0 and w1_wall_median > 0 else None
        speedup_text = f"{speedup:.2f}×" if speedup is not None else "N/A"
        efficiency_text = f"{speedup / w * 100.0:.1f}%" if speedup is not None else "N/A"

        scaling_rows.append(
            f"| {w} | {wall_med:.3f} | {matches_hr_med:.1f} | {cands_med:,.1f} | {speedup_text} | {efficiency_text} |"
        )

        walls_by_repeat = {int(r["repeat_index"]): float(r["wall_seconds"]) for r in rows}
        repeat_values = [f"{walls_by_repeat[r]:.3f}" if r in walls_by_repeat else "-"
                         for r in repeat_indices]
        repeat_rows.append(f"| {w} | " + " | ".join(repeat_values) + " |")

        # Latencies
        mean_dec = statistics.median(float(r["decision_mean_seconds"]) for r in rows)
        p50_dec = statistics.median(float(r["decision_p50_seconds"]) for r in rows)
        p95_dec = statistics.median(float(r["decision_p95_seconds"]) for r in rows)
        verif_out = statistics.median(float(r["verification_and_output_seconds"]) for r in rows)
        latency_rows.append(
            f"| {w} | {mean_dec:.3f} | {p50_dec:.3f} | {p95_dec:.3f} | {verif_out:.4f} |"
        )

        # Phases
        sim_p = statistics.median(float(r["sim_phase_seconds"]) for r in rows)
        reset_p = statistics.median(float(r["candidate_reset_phase_seconds"]) for r in rows)
        sel_p = statistics.median(float(r["selection_phase_seconds"]) for r in rows) * 1000.0
        shot_p = statistics.median(float(r["actual_shot_phase_seconds"]) for r in rows) * 1000.0
        ckpt_p = statistics.median(float(r["checkpoint_phase_seconds"]) for r in rows) * 1000.0
        phase_rows.append(
            f"| {w} | {sim_p:.3f} | {reset_p:.3f} | {sel_p:.3f} | {shot_p:.3f} | {ckpt_p:.3f} |"
        )

    # Match summary table (from first trial matches)
    match_table_rows = []
    if matches_rows:
        first_trial_id = trials_rows[0]["trial_id"] if trials_rows else matches_rows[0]["trial_id"]
        t1_matches = [m for m in matches_rows if m["trial_id"] == first_trial_id]
        t1_matches.sort(key=lambda x: int(x["match_id"]))
        for m in t1_matches:
            p1_score = f"{int(float(m['player1_score'])):,}"
            p2_score = f"{int(float(m['player2_score'])):,}"
            match_table_rows.append(
                f"| {m['match_id']} | {p1_score} | {p2_score} | {m['winner']} | {m['turns']} | {m['termination_reason']} |"
            )

    # Memory summary
    rss_values = [
        int(r["process_rss_bytes"])
        for r in trials_rows
        if r.get("process_rss_bytes") and r["process_rss_bytes"] != ""
    ]
    peak_rss_values = [
        int(r["process_peak_rss_bytes"])
        for r in trials_rows
        if r.get("process_peak_rss_bytes") and r["process_peak_rss_bytes"] != ""
    ]

    rss_summary = ""
    if rss_values and peak_rss_values:
        min_rss_mib = min(rss_values) / (1024 * 1024)
        max_rss_mib = max(rss_values) / (1024 * 1024)
        peak_mib = max(peak_rss_values) / (1024 * 1024)
        rss_summary = (
            f"Process RSS after output ranges from **{min_rss_mib:.1f} to {max_rss_mib:.1f} MiB**.\n"
            f"Cumulative process peak RSS is **{peak_mib:.1f} MiB**."
        )

    importer_section = ""
    if importer:
        importer_section = f"""## Importer Provenance

- **Imported at**: `{importer.get('imported_at_utc')}`
- **Importer Git revision**: `{importer.get('importer_git_revision')}`
- **Legacy source file**: `{importer.get('legacy_baseline_file')}`
- **Notes**: {importer.get('notes', 'None')}
"""

    readme = f"""# Benchmark Run: `{run_id}`

- **Benchmark**: `{benchmark}`
- **Workload**: `{workload_id}`
- **Status**: `{manifest.get('status', 'unknown')}`
- **Timestamp (UTC)**: `{timestamp}`
- **Host**: `{host.get('host_id', 'unknown')}` (`{host.get('cpu_model', 'unknown')}`, {host.get('physical_cores', '?')} physical cores / {host.get('cpu_threads', '?')} threads)
- **Runtime**: Julia `{runtime.get('julia_version', 'unknown')}` with `{runtime.get('julia_threads', '?')}` threads
- **Git revision**: `{source.get('git_revision', 'unknown')}` (dirty: `{source.get('git_dirty', False)}`)
- **Harness fingerprint**: `{source.get('harness_fingerprint', 'unknown')}`
- **Canonical gameplay hash**: `{manifest.get('artifacts', {}).get('canonical_gameplay_history', {}).get('sha256', 'unknown')}`

## Worker Scaling

Summary metrics (medians across {repetitions}):

| Workers | Campaign wall (s) | Completed matches/hour | Candidates/second | Speedup | Efficiency |
| ---: | ---: | ---: | ---: | ---: | ---: |
{chr(10).join(scaling_rows)}

### Wall Time by Repeat

{repeat_header}
{repeat_separator}
{chr(10).join(repeat_rows)}

### Decision Latencies

| Workers | Mean decision (s) | p50 decision (s) | p95 decision (s) | Verification/output (s) |
| ---: | ---: | ---: | ---: | ---: |
{chr(10).join(latency_rows)}

### Phase Durations

Values are summed worker wall durations across all matches:

| Workers | Simulation (s) | Candidate reset (s) | Selection (ms) | Actual shot (ms) | Checkpoint (ms) |
| ---: | ---: | ---: | ---: | ---: | ---: |
{chr(10).join(phase_rows)}

{rss_summary}

## Match Results

Seeded matches ({workload.get('games', 8)} matches per campaign, {len(trials_rows)} trials, {completion_summary}):

| Match | Player 1 score | Player 2 score | Winner | Turns | Termination |
| --- | ---: | ---: | ---: | ---: | --- |
{chr(10).join(match_table_rows)}

## Workload Configuration

- Mode: `{workload.get('mode', '1v1')}`
- Matches: `{workload.get('games', 8)}`
- Base seed: `{workload.get('base_seed', 20261024)}`
- Candidates per turn: `{workload.get('candidate_count', 1801)}`
- Level: `{workload.get('level_file')}` (`{workload.get('level_sha256')}`)
- Config: `{workload.get('config_file')}` (`{workload.get('config_sha256')}`)

{importer_section}
## Artifacts

- Canonical gameplay history: {artifact_link('canonical_gameplay_history')}
- Full archive bundle: {artifact_link('archive_bundle')}
"""
    return readme


# ==============================================================================
# Harness execution helpers
#
# These live here (rather than in the Julia runner) only for the remaining
# Python analysis scripts: import_legacy_benchmark.py and
# run_campaign_diagnostics.py. The benchmark execution path itself is
# scripts/run_campaign_benchmark.jl, which has its own Julia implementation.
# ==============================================================================

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
    except Exception as exc:
        raise RuntimeError("Cannot inspect source Git status") from exc

    return rev, is_dirty, status


def reserve_run(benchmarks_dir: Path, run_id: str) -> Path:
    """Reserve an ID before writing evidence; existing attempts are immutable."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", run_id):
        raise ValueError("run_id must be a single safe path component")
    staging = benchmarks_dir / ".staging" / run_id
    for path in (staging, benchmarks_dir / "runs" / run_id,
                 benchmarks_dir / "artifacts" / f"{run_id}.tar.gz"):
        if path.exists():
            raise FileExistsError(f"Run ID already exists: {path}; use a new run ID")
    staging.parent.mkdir(parents=True, exist_ok=True)
    staging.mkdir()  # exclusive reservation also protects concurrent invocations
    return staging


def create_archive_exclusive(path: Path, items: List[Tuple[Path, str]]) -> Tuple[str, int]:
    """Publish a complete archive without replacing an existing destination."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    with temporary.open("xb"):
        pass
    digest, size = create_artifact_archive(temporary, items)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.link(temporary, path)  # fails atomically if the final archive already exists
    temporary.unlink()
    return digest, size


def harness_files(root_dir: Path) -> List[str]:
    """Source files that define the current (Julia) execution harness."""
    paths = ["campaigns/ribbon/config.source.lua", "campaigns/ribbon/game.source.lua",
             "julia/PeggleSim/Manifest.toml", "julia/PeggleSim/Project.toml",
             "scripts/sync_campaign_config.jl", "scripts/run_campaign_benchmark.jl",
             "scripts/bench_process.jl", "scripts/bench_process_resource.py",
             "scripts/verify_reference.sh",
             "scripts/benchmark_schema.py",
             "tools/capture_match_rules.lua", "tools/canonical_json.lua",
             "fixtures/matches/rules.v1.json"]
    for directory, pattern in (("julia/PeggleSim/src", "*.jl"),
                               ("julia/PeggleSim/bin", "*.jl"),
                               ("scripts/benchmark", "*.jl")):
        paths.extend(str(p.relative_to(root_dir)) for p in (root_dir / directory).rglob(pattern))
    if (root_dir / "native").exists():
        paths.extend(str(p.relative_to(root_dir)) for p in (root_dir / "native").rglob("*")
                     if p.is_file() and p.suffix in {".c", ".h", ".toml"})
    return sorted(set(paths))


def capture_source_snapshot(root_dir: Path, staging_dir: Path,
                            extra_paths: List[Path] | None = None) -> Tuple[Path, Dict[str, str]]:
    """Retain tracked binary changes and every relevant untracked source file."""
    patch = subprocess.check_output(["git", "-C", str(root_dir), "diff", "--binary", "HEAD"])
    patch_path = staging_dir / "git_diff.patch"
    patch_path.write_bytes(patch)
    paths = set(harness_files(root_dir))
    paths.update(str(p.resolve().relative_to(root_dir)) for p in extra_paths or [])
    untracked = subprocess.check_output(["git", "-C", str(root_dir), "ls-files", "--others",
                                         "--exclude-standard", "-z"])
    for name in untracked.decode().split("\0"):
        if name and name.split("/", 1)[0] in {"julia", "scripts", "tools", "campaigns", "fixtures", "native"}:
            paths.add(name)
    hashes = {name: sha256_file(root_dir / name) for name in sorted(paths)
              if (root_dir / name).is_file()}
    status_path = staging_dir / "git_status.txt"
    status_path.write_bytes(subprocess.check_output(["git", "-C", str(root_dir), "status", "--porcelain"]))
    inventory = staging_dir / "source_files.json"
    save_manifest(inventory, {"files": hashes, "git_diff_sha256": sha256_file(patch_path),
                              "restore": "Checkout source.git_revision, apply git_diff.patch with git apply --binary, then overlay source/."})
    snapshot = staging_dir / "source_snapshot.tar.gz"
    create_artifact_archive(snapshot, [(root_dir / name, f"source/{name}") for name in hashes] +
                            [(patch_path, patch_path.name), (status_path, status_path.name), (inventory, inventory.name)])
    return snapshot, hashes


def collect_host_metadata() -> Dict[str, Any]:
    """Collect comprehensive host environment metadata."""
    uname = os.uname()
    host_id = uname.nodename
    machine = platform.machine()
    kernel = uname.sysname

    os_release = ""
    os_release_path = Path("/etc/os-release")
    if os_release_path.exists():
        os_release = os_release_path.read_text(encoding="utf-8")

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

    try:
        total_memory_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except Exception:
        total_memory_bytes = 0

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

    try:
        allowed_cpus = sorted(list(os.sched_getaffinity(0)))
    except Exception:
        allowed_cpus = list(range(os.cpu_count() or 1))

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
