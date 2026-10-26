import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_benchmark_index import generate_index


class IndexTests(unittest.TestCase):
    def test_invalid_manifest_preserves_existing_index(self):
        for malformed in (False, True):
            with self.subTest(malformed=malformed), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                runs = root / "runs"
                for name in ("a", "b"):
                    run = runs / name
                    run.mkdir(parents=True)
                    (run / "manifest.json").write_text(json.dumps({"run_id": "a"}))
                if malformed:
                    (runs / "b" / "manifest.json").write_text("{")
                index = root / "index.csv"
                index.write_text("previous index\n")
                with self.assertRaises(ValueError):
                    generate_index(runs, index, root, update_readme=False)
                self.assertEqual(index.read_text(), "previous index\n")

    def test_index_is_sorted_and_reproducible(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            for name in ("b", "a"):
                run = runs / name
                run.mkdir(parents=True)
                (run / "manifest.json").write_text(json.dumps({
                    "run_id": name, "timestamp_utc": "2026-10-25T00:00:00Z",
                }))
            index = root / "index.csv"
            rows = generate_index(runs, index, root, update_readme=False)
            self.assertEqual([row["run_id"] for row in rows], ["a", "b"])
            original = index.read_bytes()
            generate_index(runs, index, root, update_readme=False)
            self.assertEqual(index.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
