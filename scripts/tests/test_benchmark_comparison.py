"""Compatibility and generated-summary regressions; no simulations required."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_schema import generate_run_readme, read_csv_rows
from compare_benchmarks import compatibility_checks, compare_runs, get_medians_by_worker, main

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / 'results/benchmarks/runs/20261025T093415Z_omarchy_v_beb3'


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((RUN / 'manifest.json').read_text())
        self.trials = read_csv_rows(RUN / 'trials.csv')
        self.matches = read_csv_rows(RUN / 'matches.csv')

    def test_workload_changes_are_incompatible(self):
        for key, value in [('base_seed', 999), ('games', 8), ('config_sha256', 'f' * 64),
                           ('level_sha256', 'f' * 64), ('max_steps', 100),
                           ('epsilon', 9), ('warmup', 'full')]:
            with self.subTest(key=key):
                other = copy.deepcopy(self.manifest)
                other['workload'][key] = value
                self.assertTrue(any(a != b for _, a, b in compatibility_checks(self.manifest, other)))

    def test_execution_settings_may_differ(self):
        other = copy.deepcopy(self.manifest)
        other['workload'].update(repeats=5, worker_counts=[1, 2, 4])
        other['source']['git_revision'] = 'f' * 40
        other['host']['host_id'] = 'second-host'
        self.assertTrue(all(a == b for _, a, b in compatibility_checks(self.manifest, other)))

    def test_missing_warmup_cannot_establish_compatibility(self):
        self.manifest['workload'].pop('warmup')
        checks = compatibility_checks(self.manifest, self.manifest)
        self.assertIn(('warmup', None, None), checks)

    def test_incompatible_runs_omit_performance_tables(self):
        other = copy.deepcopy(self.manifest)
        other['workload']['base_seed'] = 999
        output = io.StringIO()
        with patch('compare_benchmarks.load_manifest', side_effect=[self.manifest, other]), contextlib.redirect_stdout(output):
            self.assertFalse(compare_runs(RUN, RUN, root_dir=ROOT))
        self.assertIn('performance comparison omitted', output.getvalue())
        self.assertNotIn('Worker Scaling & Wall Times', output.getvalue())

    def test_cli_exits_nonzero_for_incompatible_runs(self):
        other = copy.deepcopy(self.manifest)
        other['workload']['warmup'] = 'full'
        args = ['compare_benchmarks.py', str(RUN), str(RUN)]
        with patch('sys.argv', args), patch('compare_benchmarks.load_manifest',
                                           side_effect=[self.manifest, other]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(), 1)

    def test_valid_self_comparison_emits_tables(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertTrue(compare_runs(RUN, RUN, root_dir=ROOT))
        self.assertIn('[PARITY VERIFIED]', output.getvalue())
        self.assertIn('Worker Scaling & Wall Times', output.getvalue())
        self.assertIn('N/A', output.getvalue())

    def test_matching_hash_labels_without_evidence_do_not_verify_parity(self):
        other = copy.deepcopy(self.manifest)
        other['artifacts']['canonical_gameplay_history']['path'] = '/missing/history.json'
        output = io.StringIO()
        with patch('compare_benchmarks.load_manifest', side_effect=[other, other]), contextlib.redirect_stdout(output):
            self.assertFalse(compare_runs(RUN, RUN, root_dir=ROOT))
        self.assertNotIn('[PARITY VERIFIED]', output.getvalue())

    def test_no_sequential_baseline_means_unknown_scaling(self):
        for stats in get_medians_by_worker(self.trials).values():
            self.assertIsNone(stats['speedup'])
            self.assertIsNone(stats['efficiency'])
        readme = generate_run_readme(self.manifest, self.trials, self.matches)
        self.assertIn('| N/A | N/A |', readme)
        self.assertIn('1 repetition(s) per worker count', readme)
        self.assertNotIn('Repeat 3', readme)
        self.assertIn('](<../../histories/', readme)

    def test_every_repeat_is_rendered(self):
        trials = []
        for repeat in range(1, 6):
            row = dict(self.trials[0], repeat_index=str(repeat), wall_seconds=str(repeat))
            trials.append(row)
        readme = generate_run_readme(self.manifest, trials, [])
        self.assertIn('Repeat 5 (s)', readme)
        self.assertIn('| 2 | 1.000 | 2.000 | 3.000 | 4.000 | 5.000 |', readme)
        self.assertIn('5 repetition(s) per worker count', readme)


if __name__ == '__main__':
    unittest.main()
