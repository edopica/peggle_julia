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
import tarfile
import hashlib
from typing import Any, Dict, List, Set

from benchmark_schema import (
    SCHEMA_VERSION,
    PROTOCOL_VERSION,
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

        self.errors.clear()
        self.warnings.clear()
        manifest = None
        if not manifest_path.exists():
            self.log_error(f"Missing required file: {manifest_path}")
        else:
            try:
                manifest = load_manifest(manifest_path)
                self.validate_manifest(manifest)
            except Exception as e:
                self.log_error(f"Failed to parse or validate manifest.json: {e}")
                if not isinstance(manifest, dict):
                    manifest = None

        partial = bool(manifest and manifest.get("status") in {"failed", "interrupted", "invalid"})
        trials_rows = []
        if not trials_path.exists() and not partial:
            self.log_error(f"Missing required file: {trials_path}")
        elif trials_path.exists():
            try:
                trials_rows = read_csv_rows(trials_path)
                self.validate_trials_csv(trials_rows, manifest)
            except Exception as e:
                self.log_error(f"Failed to read or validate trials.csv: {e}")

        matches_rows = []
        if not matches_path.exists() and not partial:
            self.log_error(f"Missing required file: {matches_path}")
        elif matches_path.exists():
            try:
                matches_rows = read_csv_rows(matches_path)
                self.validate_matches_csv(matches_rows, manifest)
            except Exception as e:
                self.log_error(f"Failed to read or validate matches.csv: {e}")

        if trials_rows and matches_rows:
            try:
                self.validate_consistency(trials_rows, matches_rows, manifest)
            except (ValueError, TypeError, KeyError) as e:
                self.log_error(f"Invalid table consistency data: {e}")

        if not checks_path.exists() and not partial:
            self.log_error(f"Missing required file: {checks_path}")
        elif checks_path.exists():
            try:
                checks = load_checks(checks_path)
                self.validate_checks(checks, manifest)
            except Exception as e:
                self.log_error(f"Failed to parse or validate checks.json: {e}")

        if manifest:
            try:
                self.validate_artifacts(manifest)
                if trials_rows and matches_rows:
                    self.validate_history(manifest, trials_rows, matches_rows)
            except (OSError, ValueError, TypeError, KeyError) as e:
                self.log_error(f"Invalid artifact data: {e}")

        if self.index_path:
            self.validate_index(manifest)

        return len(self.errors) == 0

    def validate_manifest(self, m: Dict[str, Any]) -> None:
        if not isinstance(m, dict):
            raise ValueError("manifest.json must be an object")
        partial = m.get("status") in {"failed", "interrupted", "invalid"}
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
        if partial:
            required_keys = ["schema_version", "protocol_version", "run_id", "benchmark", "workload_id", "status", "timestamp_utc"]
        for key in required_keys:
            if key not in m:
                self.log_error(f"manifest.json missing required key '{key}'")

        if m.get("schema_version") != SCHEMA_VERSION:
            self.log_error(f"Unsupported result schema version: {m.get('schema_version')}")
        if m.get("protocol_version") != PROTOCOL_VERSION:
            self.log_error(f"Unsupported measurement protocol version: {m.get('protocol_version')}")

        valid_statuses = {"completed", "failed", "interrupted", "invalid"}
        status = m.get("status")
        if status not in valid_statuses:
            self.log_error(f"manifest.json status '{status}' not in valid set {valid_statuses}")

        if m.get("run_id") != self.run_dir.name:
            self.log_error(
                f"manifest.json run_id '{m.get('run_id')}' does not match directory name '{self.run_dir.name}'"
            )

        if partial:
            return

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
            if source.get("fingerprint_version") == "2":
                files = source.get("harness_files")
                if not isinstance(files, dict) or not files or any(not isinstance(path, str) or not self.valid_sha(digest) for path, digest in files.items()):
                    self.log_error("Source fingerprint requires a nonempty path/SHA-256 manifest")
                else:
                    encoded = "".join(f"{files[path]}  {path}\n" for path in sorted(files)).encode("utf-8")
                    if hashlib.sha256(encoded).hexdigest() != source.get("harness_fingerprint"):
                        self.log_error("Source harness fingerprint differs from harness_files manifest")
                if source.get("run_kind") not in {"official", "exploratory"}:
                    self.log_error("manifest.json source.run_kind must be official or exploratory")
                if source.get("run_kind") == "official" and source.get("git_dirty"):
                    self.log_error("Official benchmark runs require a committed source tree")
                if source.get("git_dirty"):
                    snapshot = source.get("source_snapshot")
                    if not isinstance(snapshot, dict) or not snapshot.get("archive_member") or not self.valid_sha(snapshot.get("sha256")):
                        self.log_error("Dirty source requires an archived source snapshot and SHA-256")

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
                    if not isinstance(item, dict) or not item.get("path") or not self.valid_sha(item.get("sha256")):
                        self.log_error(f"manifest.json artifact '{art_key}' must have 'path' and 'sha256'")

    @staticmethod
    def valid_sha(value: Any) -> bool:
        return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)

    def validate_number(self, row, column, context, *, integer=False, positive=False, optional=False):
        value = row.get(column)
        if optional and value == "":
            return
        try:
            number = int(value) if integer else float(value)
            if not math.isfinite(number) or number < 0 or (positive and number == 0):
                raise ValueError()
        except (ValueError, TypeError, OverflowError):
            self.log_error(f"{context}: invalid {'integer' if integer else 'number'} in '{column}': {value!r}")

    def validate_headers(self, rows, expected, filename):
        if not rows:
            self.log_error(f"{filename} is empty")
            return
        if list(rows[0]) != expected:
            self.log_error(f"{filename} headers do not match schema")
        for idx, row in enumerate(rows, 1):
            if None in row or any(value is None for value in row.values()):
                self.log_error(f"{filename} row {idx} has malformed column count")

    def validate_trials_csv(self, rows, manifest):
        self.validate_headers(rows, TRIALS_CSV_COLUMNS, "trials.csv")
        seen = set()
        for idx, row in enumerate(rows, 1):
            context = f"trials.csv row {idx}"
            trial_id = row.get("trial_id")
            if not trial_id or trial_id in seen:
                self.log_error(f"{context}: missing or duplicate trial_id {trial_id!r}")
            seen.add(trial_id)
            if manifest and row.get("run_id") != manifest.get("run_id"):
                self.log_error(f"{context}: run_id differs from manifest")
            for col in ("execution_order", "repeat_index", "workers"):
                self.validate_number(row, col, context, integer=True, positive=True)
            for col in ("completed_matches", "candidates"):
                self.validate_number(row, col, context, integer=True)
            optional = {"process_rss_bytes", "process_peak_rss_bytes", "allocated_bytes", "gc_collections", "gc_seconds"}
            integers = optional - {"gc_seconds"}
            for col in TRIALS_CSV_COLUMNS[6:-1]:
                if col in {"completed_matches", "candidates"}:
                    continue
                self.validate_number(row, col, context, integer=col in integers, optional=col in optional)
            if row.get("mode") not in {"sequential", "parallel"}:
                self.log_error(f"{context}: invalid mode")
            if not self.valid_sha(row.get("gameplay_sha256")):
                self.log_error(f"{context}: invalid gameplay SHA-256")

    def validate_matches_csv(self, rows, manifest):
        self.validate_headers(rows, MATCHES_CSV_COLUMNS, "matches.csv")
        seen = set()
        for idx, row in enumerate(rows, 1):
            context = f"matches.csv row {idx}"
            key = (row.get("trial_id"), row.get("match_id"))
            if not all(key) or key in seen:
                self.log_error(f"{context}: missing or duplicate trial/match ID {key!r}")
            seen.add(key)
            if manifest and row.get("run_id") != manifest.get("run_id"):
                self.log_error(f"{context}: run_id differs from manifest")
            for col in ("repeat_index", "workers", "match_id", "worker_index"):
                self.validate_number(row, col, context, integer=True, positive=True)
            for col in ("base_seed", "bot_seed_1", "bot_seed_2", "gameplay_seed", "turns", "candidates", "winner"):
                self.validate_number(row, col, context, integer=True)
            for col in ("wall_seconds", "sim_phase_seconds", "player1_score", "player2_score"):
                self.validate_number(row, col, context)
            if row.get("completed") not in {"true", "false"}:
                self.log_error(f"{context}: completed must be true or false")
            if not row.get("termination_reason"):
                self.log_error(f"{context}: termination_reason is required")
            if not self.valid_sha(row.get("gameplay_sha256")):
                self.log_error(f"{context}: invalid gameplay SHA-256")

    def validate_consistency(self, trials, matches, manifest=None):
        by_trial = {t["trial_id"]: [] for t in trials}
        for match in matches:
            trial_id = match.get("trial_id")
            if trial_id not in by_trial:
                self.log_error(f"matches.csv references unknown trial_id {trial_id!r}")
            else:
                by_trial[trial_id].append(match)
        for trial in trials:
            trial_id = trial["trial_id"]
            group = by_trial[trial_id]
            completed = sum(m.get("completed") == "true" for m in group)
            if completed != int(trial["completed_matches"]):
                self.log_error(f"Trial {trial_id}: completed match count differs from matches.csv")
            if sum(int(m["candidates"]) for m in group) != int(trial["candidates"]):
                self.log_error(f"Trial {trial_id}: candidate sum differs from matches.csv")
            if manifest and manifest.get("status") == "completed":
                expected = manifest.get("workload", {}).get("games")
                if len(group) != expected or completed != expected:
                    self.log_error(f"Trial {trial_id}: completed run must contain all {expected} completed matches")
            for match in group:
                for field in ("workers", "repeat_index", "gameplay_sha256"):
                    if match.get(field) != trial.get(field):
                        self.log_error(f"Trial {trial_id}: match {match.get('match_id')} has inconsistent {field}")
                if not 1 <= int(match["worker_index"]) <= int(trial["workers"]):
                    self.log_error(f"Trial {trial_id}: worker_index outside active worker count")

    def validate_checks(self, checks, manifest=None):
        if not isinstance(checks, dict) or checks.get("schema_version") != SCHEMA_VERSION:
            self.log_error("checks.json must be an object with supported schema_version")
            return
        items = checks.get("checks")
        if not isinstance(items, list):
            self.log_error("checks.json checks must be an array")
            return
        completed = bool(manifest and manifest.get("status") == "completed")
        required = {"reference_files", "current_config", "match_rule_oracle", "gameplay_identity"}
        seen = set()
        for item in items:
            if not isinstance(item, dict):
                self.log_error("checks.json record must be an object")
                continue
            name = item.get("name")
            if not isinstance(name, str) or not name or name in seen:
                self.log_error(f"checks.json missing or duplicate name {name!r}")
                continue
            seen.add(name)
            status = item.get("status")
            if status not in {"passed", "failed", "not_collected"}:
                self.log_error(f"Check {name}: invalid status {status!r}")
            if completed and (status == "failed" or name in required and status != "passed"):
                self.log_error(f"Completed run has unsuccessful check {name}: {status}")
            if status == "passed":
                path, digest = item.get("evidence_path"), item.get("evidence_sha256")
                if name == "candidate_count" and not path and not digest:
                    # Recomputed independently from canonical games and table rows below.
                    continue
                if not path or not self.valid_sha(digest):
                    self.log_error(f"Passed check {name} requires evidence path and SHA-256")
                elif manifest:
                    actual = self.evidence_hash(path, manifest)
                    if actual != digest:
                        self.log_error(f"Check {name}: evidence missing or SHA-256 mismatch ({path})")
        if completed:
            for name in sorted(required - seen):
                self.log_error(f"Completed run missing required check {name}")

    def evidence_hash(self, path, manifest):
        """Resolve archived evidence first; never extract untrusted tar members."""
        bundle = manifest.get("artifacts", {}).get("archive_bundle", {}).get("path")
        if bundle:
            archive = self.root_dir / bundle
            if archive.is_file():
                try:
                    with tarfile.open(archive, "r:gz") as tar:
                        member = tar.getmember(path)
                        if member.isfile():
                            stream = tar.extractfile(member)
                            if stream:
                                return hashlib.file_digest(stream, "sha256").hexdigest()
                except (KeyError, OSError, tarfile.TarError):
                    pass
        for candidate in (self.run_dir / path, self.root_dir / path):
            if candidate.is_file():
                return sha256_file(candidate)
        return None

    def validate_history(self, manifest, trials, matches):
        artifact = manifest.get("artifacts", {}).get("canonical_gameplay_history", {})
        path, digest = artifact.get("path"), artifact.get("sha256")
        if not path or not digest:
            return
        games = json.loads((self.root_dir / path).read_text(encoding="utf-8"))
        if not isinstance(games, list):
            raise ValueError("canonical gameplay history must be an array")
        by_id = {str(g["game"]): g for g in games}
        if len(by_id) != len(games):
            self.log_error("Canonical history has duplicate game IDs")
        if manifest.get("status") == "completed" and any(not g.get("completed") for g in games):
            self.log_error("Completed run has incomplete games in canonical history")
        if manifest.get("status") == "completed" and len(games) != manifest.get("workload", {}).get("games"):
            self.log_error("Canonical history game count differs from workload")
        for trial in trials:
            if trial.get("gameplay_sha256") != digest:
                self.log_error(f"Trial {trial.get('trial_id')}: gameplay hash differs from canonical artifact")
        aim_count = manifest.get("workload", {}).get("candidate_count")
        for match in matches:
            game = by_id.get(match.get("match_id"))
            if game is None:
                self.log_error(f"Match {match.get('match_id')} absent from canonical history")
                continue
            for col in ("turns", "base_seed", "gameplay_seed", "termination_reason"):
                if str(game[col]) != match.get(col):
                    self.log_error(f"Match {match['match_id']}: {col} differs from canonical history")
            if str(game["completed"]).lower() != match.get("completed"):
                self.log_error(f"Match {match['match_id']}: completion differs from canonical history")
            for col, value in (
                ("bot_seed_1", game.get("bot_seeds", [0])[0]),
                ("bot_seed_2", game["bot_seeds"][1] if len(game.get("bot_seeds", [])) > 1 else 0),
                ("winner", game.get("winner") or 0),
                ("player1_score", game.get("player_scores", [0])[0]),
                ("player2_score", game["player_scores"][1] if len(game.get("player_scores", [])) > 1 else 0),
            ):
                if float(match[col]) != value:
                    self.log_error(f"Match {match['match_id']}: {col} differs from canonical history")
            if aim_count and int(match["candidates"]) != int(game["turns"]) * aim_count:
                self.log_error(f"Match {match['match_id']}: candidate count differs from turns × grid size")

    def validate_artifacts(self, manifest: Dict[str, Any]) -> None:
        artifacts = manifest.get("artifacts", {})
        snapshot = manifest.get("source", {}).get("source_snapshot")
        if isinstance(snapshot, dict) and snapshot.get("archive_member"):
            if self.evidence_hash(snapshot["archive_member"], manifest) != snapshot.get("sha256"):
                self.log_error("Source snapshot is missing or has an invalid SHA-256")
            bundle_path = artifacts.get("archive_bundle", {}).get("path")
            if bundle_path:
                try:
                    with tarfile.open(self.root_dir / bundle_path, "r:gz") as tar:
                        member = tar.getmember(snapshot["archive_member"])
                        if not member.isfile() or member.size != snapshot.get("size_bytes"):
                            self.log_error("Source snapshot size differs from archived member")
                except (OSError, KeyError, tarfile.TarError) as e:
                    self.log_error(f"Unable to read archived source snapshot: {e}")
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
                        self.log_error(
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
                if len(matching) != 1:
                    self.log_error(f"index.csv duplicate run_id {run_id!r}")
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
