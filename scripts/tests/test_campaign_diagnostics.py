import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run_campaign_diagnostics import generate_report, validate_reports


class DiagnosticChecks(unittest.TestCase):
    def setUp(self):
        self.report = dict(kind="timing", warmup_gameplay_sha256="a" * 64,
                           trials=[dict(gameplay_sha256="a" * 64, completed_matches=8,
                                        candidates=142279)])

    def test_identity_includes_warmups_profiles_and_all_trials(self):
        self.assertEqual(validate_reports([self.report], 8), "a" * 64)
        other = copy.deepcopy(self.report)
        other["warmup_gameplay_sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "hashes differ"):
            validate_reports([self.report, other], 8)
        other = copy.deepcopy(self.report)
        other["trials"][0]["gameplay_sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "hashes differ"):
            validate_reports([self.report, other], 8)

    def test_truncation_is_not_success(self):
        self.report["trials"][0]["completed_matches"] = 7
        with self.assertRaisesRegex(ValueError, "incomplete"):
            validate_reports([self.report], 8)
        validate_reports([self.report], 8, allow_incomplete=True)

    def test_candidate_disagreement(self):
        other = copy.deepcopy(self.report)
        other["trials"][0]["candidates"] += 1
        with self.assertRaisesRegex(ValueError, "candidate"):
            validate_reports([self.report, other], 8)

    def test_empty_or_truncated_cpu_profile_fails(self):
        self.report["kind"] = "cpu"
        trial = self.report["trials"][0]
        for samples, full in ((0, False), (20, True)):
            trial["cpu"] = dict(samples=samples, buffer_full=full)
            with self.assertRaisesRegex(ValueError, "empty or truncated"):
                validate_reports([self.report], 8)


if __name__ == "__main__":
    unittest.main()
