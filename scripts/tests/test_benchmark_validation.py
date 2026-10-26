"""Regression tests for benchmark finalization and retained-evidence validation."""
import csv
import json
import hashlib
import tarfile
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_benchmark import BenchmarkValidator

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / 'results/benchmarks/runs'


class BenchmarkValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.original = next(p for p in RUNS.iterdir() if p.name.endswith('beb3'))
        self.run = Path(self.temp.name) / self.original.name
        shutil.copytree(self.original, self.run)

    def validate(self):
        validator = BenchmarkValidator(self.run, root_dir=ROOT)
        valid = validator.validate()
        return valid, validator.errors

    def change_json(self, name, change):
        path = self.run / name
        data = json.loads(path.read_text())
        change(data)
        path.write_text(json.dumps(data))

    def change_csv(self, name, change):
        path = self.run / name
        with path.open(newline='') as f:
            reader = csv.DictReader(f)
            fields = reader.fieldnames
            rows = list(reader)
        change(rows)
        with path.open('w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

    def test_committed_runs_are_valid(self):
        for run in RUNS.iterdir():
            with self.subTest(run=run.name):
                validator = BenchmarkValidator(run, root_dir=ROOT)
                self.assertTrue(validator.validate(), validator.errors)

    def test_failed_check_rejects_completed_run(self):
        self.change_json('checks.json', lambda d: d['checks'][0].update(status='failed'))
        self.assertFalse(self.validate()[0])

    def test_missing_checks_rejected(self):
        self.change_json('checks.json', lambda d: d.update(checks=[]))
        self.assertFalse(self.validate()[0])

    def test_required_not_collected_rejected(self):
        self.change_json('checks.json', lambda d: d['checks'][0].update(status='not_collected'))
        self.assertFalse(self.validate()[0])

    def test_evidence_hash_is_verified_inside_archive(self):
        self.change_json('checks.json', lambda d: d['checks'][0].update(evidence_sha256='f'*64))
        self.assertFalse(self.validate()[0])

    def test_missing_evidence_rejected(self):
        self.change_json('checks.json', lambda d: d['checks'][0].update(evidence_path='missing.txt'))
        self.assertFalse(self.validate()[0])

    def test_missing_evidence_checksum_rejected(self):
        self.change_json('checks.json', lambda d: d['checks'][0].update(evidence_sha256=None))
        self.assertFalse(self.validate()[0])

    def test_duplicate_checks_rejected(self):
        self.change_json('checks.json', lambda d: d['checks'].append(d['checks'][0]))
        self.assertFalse(self.validate()[0])

    def test_unsupported_manifest_schema_rejected(self):
        self.change_json('manifest.json', lambda d: d.update(schema_version='999.0.0'))
        self.assertFalse(self.validate()[0])

    def test_unsupported_checks_schema_rejected(self):
        self.change_json('checks.json', lambda d: d.update(schema_version='999.0.0'))
        self.assertFalse(self.validate()[0])

    def test_duplicate_matches_rejected(self):
        self.change_csv('matches.csv', lambda rows: rows[1].update(match_id=rows[0]['match_id']))
        self.assertFalse(self.validate()[0])

    def test_orphan_match_rejected(self):
        self.change_csv('matches.csv', lambda rows: rows[0].update(trial_id='absent'))
        self.assertFalse(self.validate()[0])

    def test_table_hash_must_reference_artifact(self):
        for name in ('matches.csv', 'trials.csv'):
            self.change_csv(name, lambda rows: [r.update(gameplay_sha256='f'*64) for r in rows])
        self.assertFalse(self.validate()[0])

    def test_match_fields_must_match_canonical_games(self):
        self.change_csv('matches.csv', lambda rows: rows[0].update(base_seed='123'))
        self.assertFalse(self.validate()[0])

    def test_invalid_numeric_values_do_not_crash(self):
        for value in ('nan', '-1', '1.5', 'nope', ''):
            with self.subTest(value=value):
                self.change_csv('trials.csv', lambda rows: rows[0].update(completed_matches=value))
                self.assertFalse(self.validate()[0])

    def test_nonfinite_match_duration_rejected(self):
        self.change_csv('matches.csv', lambda rows: rows[0].update(wall_seconds='nan'))
        self.assertFalse(self.validate()[0])

    def test_completed_run_rejects_incomplete_match(self):
        self.change_csv('matches.csv', lambda rows: rows[0].update(completed='false'))
        self.assertFalse(self.validate()[0])

    def test_failed_attempt_can_retain_minimal_manifest(self):
        self.change_json('manifest.json', lambda d: [d.pop(k, None) for k in ('host', 'runtime', 'source', 'workload', 'artifacts')])
        self.change_json('manifest.json', lambda d: d.update(status='failed'))
        for name in ('trials.csv', 'matches.csv', 'checks.json'):
            (self.run/name).unlink()
        valid, errors = self.validate()
        self.assertTrue(valid, errors)

    def use_v2_provenance(self):
        manifest = json.loads((self.run/'manifest.json').read_text())
        archive = ROOT / manifest['artifacts']['archive_bundle']['path']
        with tarfile.open(archive) as tar:
            member = tar.getmember('campaign.log')
            digest = hashlib.sha256(tar.extractfile(member).read()).hexdigest()
        files = {'test/source.py': 'a'*64}
        fingerprint = hashlib.sha256(('a'*64 + '  test/source.py\n').encode()).hexdigest()
        self.change_json('manifest.json', lambda d: d['source'].update(
            fingerprint_version='2', run_kind='exploratory', git_dirty=True,
            harness_files=files, harness_fingerprint=fingerprint,
            source_snapshot={'archive_member': 'campaign.log', 'sha256': digest, 'size_bytes': member.size}))

    def test_v2_provenance_checks_archived_snapshot(self):
        self.use_v2_provenance()
        self.assertTrue(self.validate()[0], self.validate()[1])
        self.change_json('manifest.json', lambda d: d['source']['source_snapshot'].update(sha256='f'*64))
        self.assertFalse(self.validate()[0])

    def test_v2_dirty_source_requires_snapshot(self):
        self.use_v2_provenance()
        self.change_json('manifest.json', lambda d: d['source'].pop('source_snapshot'))
        self.assertFalse(self.validate()[0])

    def test_v2_snapshot_size_is_checked(self):
        self.use_v2_provenance()
        self.change_json('manifest.json', lambda d: d['source']['source_snapshot'].update(size_bytes=0))
        self.assertFalse(self.validate()[0])

    def test_v2_fingerprint_manifest_consistency(self):
        self.use_v2_provenance()
        self.change_json('manifest.json', lambda d: d['source'].update(harness_fingerprint='f'*64))
        self.assertFalse(self.validate()[0])

    def test_official_run_cannot_have_dirty_source(self):
        self.use_v2_provenance()
        self.change_json('manifest.json', lambda d: d['source'].update(run_kind='official'))
        self.assertFalse(self.validate()[0])

    def test_run_directory_identity_must_match(self):
        self.change_json('manifest.json', lambda d: d.update(run_id='different'))
        self.assertFalse(self.validate()[0])

    def test_bad_manifest_type_reports_error(self):
        (self.run/'manifest.json').write_text('[]')
        self.assertFalse(self.validate()[0])

    def test_short_csv_row_reports_error(self):
        path = self.run/'trials.csv'
        lines = path.read_text().splitlines()
        lines[1] = lines[1].rsplit(',', 2)[0]
        path.write_text('\n'.join(lines)+'\n')
        self.assertFalse(self.validate()[0])


if __name__ == '__main__':
    unittest.main()
