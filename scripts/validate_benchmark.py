#!/usr/bin/env python3
"""Validator for benchmark run directories against julia_clone specifications.

Validates:
- manifest.json: required fields, types, status, provenance, artifact hashes.
- trials.csv: column headers with explicit units, numeric validity, stable IDs.
- matches.csv: column headers, numeric validity, consistency with trials.csv.
- checks.json: validation outcomes and status.
- Artifacts: canonical gameplay history and archive bundle file existence and SHA-256.
- Optional --index: consistency with index.csv.

Usage:
  python3 scripts/validate_benchmark.py <run-dir> [--index <index.csv>]
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys
from typing import Any, Dict, List, Set

from benchmark_schema import (
    INDEX_CSV_COLUMNS,
    MATCHES_CSV_COLUMNS,
    TRIALS_CSV_COLUMNS,
    load_checks,
    load_manifest,
    read_csv_rows,
    sha256_file,
)


class BenchmarkValidationError(Exception):
    pass


class BenchmarkValidator:
    def __init__(self, run_dir: Path, index_path: Path | None = None, root_dir: Path | None = None):
        self.run_dir = run_dir.resolve()
        self.root_dir = (root_dir or Path.cwd()).resolve()
        self.index_path = index_path.resolve() if index_path else None
        self.errors: List[str] = []
        self.warnings: List[str] = []

    def log_error(self, msg: str) -> None:
        self.errors.append(msg)

    def log_warning(self, msg: str) -> None:
        self.warnings.append(msg)

    def validate(self) -> bool:
        if not self.run_dir.exists() or not self.run_dir.is_dir():
            self.log_error(f"Run directory does not exist or is not a directory: {self.run_dir}")
            return False

        manifest_path = self.run_dir / "manifest.json"
        trials_path = self.run_dir / "trials.csv"
        matches_path = self.run_dir / "matches.csv"
        checks_path = self.run_dir / "checks.json"

        manifest = None
        if not manifest_path.exists():
            self.log_error(f"Missing required file: {manifest_path}")
        else:
            try:
                manifest = load_manifest(manifest_path)
                self.validate_manifest(manifest)
            except Exception as e:
                self.log_error(f"Failed to parse or validate manifest.json: {e}")

        trials_rows = []
        if not trials_path.exists():
            self.log_error(f"Missing required file: {trials_path}")
        else:
            try:
                trials_rows = read_csv_rows(trials_path)
                self.validate_trials_csv(trials_rows, manifest)
            except Exception as e:
                self.log_error(f"Failed to read or validate trials.csv: {e}")

        matches_rows = []
        if not matches_path.exists():
            self.log_error(f"Missing required file: {matches_path}")
        else:
            try:
                matches_rows = read_csv_rows(matches_path)
                self.validate_matches_csv(matches_rows, manifest)
            except Exception as e:
                self.log_error(f"Failed to read or validate matches.csv: {e}")

        if trials_rows and matches_rows:
            self.validate_consistency(trials_rows, matches_rows)

        if not checks_path.exists():
            self.log_error(f"Missing required file: {checks_path}")
        else:
            try:
                checks = load_checks(checks_path)
                self.validate_checks(checks)
            except Exception as e:
                self.log_error(f"Failed to parse or validate checks.json: {e}")

        if manifest:
            self.validate_artifacts(manifest)

        if self.index_path:
            self.validate_index(manifest)

        return len(self.errors) == 0

    def validate_manifest(self, m: Dict[str, Any]) -> None:
        required_keys = [
            "schema_version",
            "protocol_version",
            "run_id",
            "benchmark",
            "workload_id",
            "status",
            "timestamp_utc",
            "host",
            "runtime",
            "source",
            "workload",
            "artifacts",
        ]
        for key in required_keys:
            if key not in m:
                self.log_error(f"manifest.json missing required key '{key}'")

        valid_statuses = {"completed", "failed", "interrupted", "invalid"}
        status = m.get("status")
        if status not in valid_statuses:
            self.log_error(f"manifest.json status '{status}' not in valid set {valid_statuses}")

        if m.get("run_id") != self.run_dir.name:
            self.log_warning(
                f"manifest.json run_id '{m.get('run_id')}' does not match directory name '{self.run_dir.name}'"
            )

        # Host checks
        host = m.get("host", {})
        if not isinstance(host, dict):
            self.log_error("manifest.json 'host' must be an object")
        else:
            for k in ["host_id", "machine", "cpu_model"]:
                if k not in host or not host[k]:
                    self.log_error(f"manifest.json host missing or empty '{k}'")

        # Source / provenance checks
        source = m.get("source", {})
        if not isinstance(source, dict):
            self.log_error("manifest.json 'source' must be an object")
        else:
            for k in ["git_revision", "git_dirty", "harness_entry_point", "harness_fingerprint"]:
                if k not in source:
                    self.log_error(f"manifest.json source missing required provenance key '{k}'")
            if "git_dirty" in source and not isinstance(source["git_dirty"], bool):
                self.log_error("manifest.json source.git_dirty must be a boolean")

        # Workload checks
        workload = m.get("workload", {})
        if not isinstance(workload, dict):
            self.log_error("manifest.json 'workload' must be an object")
        else:
            for k in ["mode", "games", "base_seed", "candidate_count"]:
                if k not in workload:
                    self.log_error(f"manifest.json workload missing required key '{k}'")

        # Artifact references
        artifacts = m.get("artifacts", {})
        if not isinstance(artifacts, dict):
            self.log_error("manifest.json 'artifacts' must be an object")
        else:
            for art_key in ["canonical_gameplay_history", "archive_bundle"]:
                if art_key not in artifacts:
                    self.log_error(f"manifest.json artifacts missing '{art_key}'")
                else:
                    item = artifacts[art_key]
                    if not isinstance(item, dict) or "path" not in item or "sha256" not in item:
                        self.log_error(f"manifest.json artifact '{art_key}' must have 'path' and 'sha256'")

    def validate_trials_csv(
        self, rows: List[Dict[str, str]], manifest: Dict[str, Any] | None
    ) -> None:
        if not rows:
            self.log_error("trials.csv is empty")
            return

        headers = list(rows[0].keys())
        missing_headers = [h for h in TRIALS_CSV_COLUMNS if h not in headers]
        if missing_headers:
            self.log_error(f"trials.csv missing required headers: {missing_headers}")

        run_id = manifest.get("run_id") if manifest else None
        seen_trial_ids: Set[str] = set()

        for idx, r in enumerate(rows, start=1):
            t_id = r.get("trial_id", "")
            if not t_id:
                self.log_error(f"trials.csv row {idx} missing trial_id")
            elif t_id in seen_trial_ids:
                self.log_error(f"trials.csv duplicate trial_id '{t_id}' at row {idx}")
            seen_trial_ids.add(t_id)

            if run_id and r.get("run_id") != run_id:
                self.log_error(
                    f"trials.csv row {idx} run_id '{r.get('run_id')}' != manifest run_id '{run_id}'"
                )

            # Validate numeric values
            for num_col in [
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
            ]:
                val = r.get(num_col, "")
                if val == "":
                    self.log_error(f"trials.csv row {idx} ({t_id}) missing value for required column '{num_col}'")
                else:
                    try:
                        v = float(val)
                        if math.isnan(v) or math.isinf(v):
                            self.log_error(f"trials.csv row {idx} ({t_id}) invalid numeric value in '{num_col}'")
                    except ValueError:
                        self.log_error(f"trials.csv row {idx} ({t_id}) non-numeric value '{val}' in '{num_col}'")

            # Check gameplay hash format
            sha = r.get("gameplay_sha256", "")
            if len(sha) != 64 or not all(c in "0123456789abcdef" for c in sha.lower()):
                self.log_error(f"trials.csv row {idx} ({t_id}) invalid SHA-256 gameplay hash: '{sha}'")

    def validate_matches_csv(
        self, rows: List[Dict[str, str]], manifest: Dict[str, Any] | None
    ) -> None:
        if not rows:
            self.log_error("matches.csv is empty")
            return

        headers = list(rows[0].keys())
        missing_headers = [h for h in MATCHES_CSV_COLUMNS if h not in headers]
        if missing_headers:
            self.log_error(f"matches.csv missing required headers: {missing_headers}")

        run_id = manifest.get("run_id") if manifest else None

        for idx, r in enumerate(rows, start=1):
            if run_id and r.get("run_id") != run_id:
                self.log_error(
                    f"matches.csv row {idx} run_id '{r.get('run_id')}' != manifest run_id '{run_id}'"
                )

            for req in ["trial_id", "match_id", "turns", "candidates", "wall_seconds", "gameplay_sha256"]:
                if r.get(req, "") == "":
                    self.log_error(f"matches.csv row {idx} missing required field '{req}'")

            # Validate numeric
            for col in ["turns", "candidates", "match_id", "workers"]:
                val = r.get(col, "")
                if val != "":
                    try:
                        int(val)
                    except ValueError:
                        self.log_error(f"matches.csv row {idx} column '{col}' expected int, got '{val}'")

            for col in ["wall_seconds", "sim_phase_seconds", "player1_score", "player2_score"]:
                val = r.get(col, "")
                if val != "":
                    try:
                        float(val)
                    except ValueError:
                        self.log_error(f"matches.csv row {idx} column '{col}' expected float, got '{val}'")

    def validate_consistency(
        self, trials: List[Dict[str, str]], matches: List[Dict[str, str]]
    ) -> None:
        # Group matches by trial_id
        matches_by_trial: Dict[str, List[Dict[str, str]]] = {}
        for m in matches:
            t_id = m.get("trial_id", "")
            matches_by_trial.setdefault(t_id, []).append(m)

        for t in trials:
            t_id = t.get("trial_id", "")
            m_list = matches_by_trial.get(t_id, [])
            if not m_list:
                self.log_error(f"Consistency: trial '{t_id}' has no matching rows in matches.csv")
                continue

            completed_matches = int(t.get("completed_matches", 0))
            if len(m_list) != completed_matches:
                self.log_error(
                    f"Consistency: trial '{t_id}' has {len(m_list)} matches in matches.csv, "
                    f"expected {completed_matches} from trials.csv"
                )

            total_cands = sum(int(m["candidates"]) for m in m_list if m.get("candidates"))
            expected_cands = int(t.get("candidates", 0))
            if total_cands != expected_cands:
                self.log_error(
                    f"Consistency: trial '{t_id}' match candidates sum {total_cands} != "
                    f"trial candidates {expected_cands}"
                )

            trial_sha = t.get("gameplay_sha256")
            for m in m_list:
                if m.get("gameplay_sha256") != trial_sha:
                    self.log_error(
                        f"Consistency: match {m.get('match_id')} in trial '{t_id}' has "
                        f"gameplay_sha256 '{m.get('gameplay_sha256')}' != trial '{trial_sha}'"
                    )

    def validate_checks(self, checks: Any) -> None:
        check_items = []
        if isinstance(checks, dict):
            if "checks" in checks and isinstance(checks["checks"], (list, dict)):
                c = checks["checks"]
                check_items = list(c.values()) if isinstance(c, dict) else c
            else:
                check_items = list(checks.values())
        elif isinstance(checks, list):
            check_items = checks
        else:
            self.log_error("checks.json must be a JSON object or array")
            return

        valid_statuses = {"passed", "failed", "not_collected"}
        for item in check_items:
            if not isinstance(item, dict):
                self.log_error(f"checks.json record is not an object: {item}")
                continue
            name = item.get("name", "unnamed")
            status = item.get("status")
            if status not in valid_statuses:
                self.log_error(
                    f"checks.json check '{name}' has invalid status '{status}', must be one of {valid_statuses}"
                )

    def validate_artifacts(self, manifest: Dict[str, Any]) -> None:
        artifacts = manifest.get("artifacts", {})
        # 1. Canonical gameplay history
        c_art = artifacts.get("canonical_gameplay_history", {})
        rel_path = c_art.get("path")
        expected_sha = c_art.get("sha256")
        if rel_path and expected_sha:
            full_path = self.root_dir / rel_path
            if not full_path.exists():
                self.log_error(f"Artifact canonical gameplay history file does not exist: {full_path}")
            else:
                actual_sha = sha256_file(full_path)
                if actual_sha != expected_sha:
                    self.log_error(
                        f"Artifact canonical gameplay history SHA-256 mismatch: "
                        f"expected {expected_sha}, got {actual_sha}"
                    )

        # 2. Archive bundle
        b_art = artifacts.get("archive_bundle", {})
        b_rel_path = b_art.get("path")
        b_expected_sha = b_art.get("sha256")
        b_size = b_art.get("size_bytes")
        if b_rel_path and b_expected_sha:
            b_full_path = self.root_dir / b_rel_path
            if not b_full_path.exists():
                self.log_error(f"Artifact archive bundle file does not exist: {b_full_path}")
            else:
                actual_sha = sha256_file(b_full_path)
                if actual_sha != b_expected_sha:
                    self.log_error(
                        f"Artifact archive bundle SHA-256 mismatch: "
                        f"expected {b_expected_sha}, got {actual_sha}"
                    )
                if b_size is not None:
                    actual_size = b_full_path.stat().st_size
                    if actual_size != b_size:
                        self.log_warning(
                            f"Artifact archive bundle size mismatch: recorded {b_size}, actual {actual_size}"
                        )

    def validate_index(self, manifest: Dict[str, Any] | None) -> None:
        if not self.index_path or not self.index_path.exists():
            self.log_error(f"Index file does not exist: {self.index_path}")
            return

        try:
            rows = read_csv_rows(self.index_path)
        except Exception as e:
            self.log_error(f"Failed to read index.csv: {e}")
            return

        if not rows:
            self.log_error("index.csv is empty")
            return

        headers = list(rows[0].keys())
        missing_headers = [h for h in INDEX_CSV_COLUMNS if h not in headers]
        if missing_headers:
            self.log_error(f"index.csv missing headers: {missing_headers}")

        if manifest:
            run_id = manifest.get("run_id")
            matching = [r for r in rows if r.get("run_id") == run_id]
            if not matching:
                self.log_error(f"Run ID '{run_id}' not found in index.csv ({self.index_path})")
            else:
                row = matching[0]
                for field in ["benchmark", "status", "workload_id", "protocol_version", "schema_version"]:
                    if row.get(field) != manifest.get(field):
                        self.log_error(
                            f"index.csv mismatch for field '{field}': "
                            f"index has '{row.get(field)}', manifest has '{manifest.get(field)}'"
                        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path, help="Path to benchmark run directory")
    parser.add_argument("--index", type=Path, default=None, help="Optional path to index.csv to verify entry")
    parser.add_argument("--root", type=Path, default=None, help="Repository root directory")
    args = parser.parse_args()

    validator = BenchmarkValidator(args.run_dir, index_path=args.index, root_dir=args.root)
    valid = validator.validate()

    if validator.warnings:
        print(f"Validation warnings ({len(validator.warnings)}):")
        for w in validator.warnings:
            print(f"  [WARN] {w}")

    if not valid:
        print(f"Validation failed with {len(validator.errors)} error(s):", file=sys.stderr)
        for err in validator.errors:
            print(f"  [ERROR] {err}", file=sys.stderr)
        return 1

    print(f"Benchmark run at '{args.run_dir}' is valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
