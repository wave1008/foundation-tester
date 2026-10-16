import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("migrate-fm-retries.py")


class FMRetryMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fm-retry-migration-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "results" / "runs"
        self.scenarios = self.root / "2026-10" / "run-one" / "scenarios"
        self.scenarios.mkdir(parents=True)

    def write(self, name="sample.json", fm=None):
        record = {"schemaVersion": 1, "scenarioID": "日本語.S0010", "passed": True,
                  "notes": {"preserve": ["unrelated", 17]}}
        if fm is not None:
            record["fm"] = fm
        path = self.scenarios / name
        path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        return path

    def invoke(self, *options, root=None):
        return subprocess.run([sys.executable, str(SCRIPT), "--root", str(root or self.root), *options],
                              capture_output=True, text=True, check=False)

    def test_dry_run_then_atomic_migration_and_idempotence(self):
        path = self.write(fm={"calls": 3, "failures": 1, "byKind": {"occlusion": {"calls": 3}}})
        path.chmod(0o640)
        original = path.read_bytes()
        original_stat = path.stat()
        dry_run = self.invoke("--dry-run")
        self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
        self.assertEqual(json.loads(dry_run.stdout)["wouldChange"], 1)
        self.assertEqual(path.read_bytes(), original)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["changed"], 1)
        migrated = json.loads(path.read_bytes())
        expected = json.loads(original)
        expected["fm"].update(retries=0, retrySuccesses=0)
        expected["fm"]["byKind"]["occlusion"].update(retries=0, retrySuccesses=0)
        self.assertEqual(migrated, expected)
        self.assertNotEqual(path.stat().st_ino, original_stat.st_ino)
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        after = path.read_bytes()
        after_stat = path.stat()
        again = self.invoke()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(json.loads(again.stdout)["changed"], 0)
        self.assertEqual(path.read_bytes(), after)
        self.assertEqual(path.stat().st_mtime_ns, after_stat.st_mtime_ns)
        self.assertEqual(list(self.scenarios.glob("*.tmp")), [])

    def test_nonzero_current_counters_and_records_without_fm_are_untouched(self):
        usage = {"calls": 5, "retries": 3, "retrySuccesses": 2,
                 "byKind": {"occlusion": {"retries": 2, "retrySuccesses": 1},
                            "screenLooksLike": {"retries": 1, "retrySuccesses": 1}}}
        current = self.write("current.json", usage)
        no_fm = self.write("no-fm.json")
        originals = {path: path.read_bytes() for path in (current, no_fm)}
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["changed"], 0)
        for path, original in originals.items():
            self.assertEqual(path.read_bytes(), original)

    def test_partial_zero_migration_is_completed(self):
        path = self.write(fm={"retries": 0, "byKind": {"occlusion": {"retrySuccesses": 0}}})
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        fm = json.loads(path.read_bytes())["fm"]
        self.assertEqual((fm["retries"], fm["retrySuccesses"]), (0, 0))
        self.assertEqual((fm["byKind"]["occlusion"]["retries"], fm["byKind"]["occlusion"]["retrySuccesses"]), (0, 0))

    def test_corrupt_or_ambiguous_records_abort_before_any_write(self):
        valid = self.write("a-valid.json", {"byKind": {"occlusion": {}}})
        original = valid.read_bytes()
        invalid = self.scenarios / "z-invalid.json"
        invalid_records = [
            b"{broken", b'{"schemaVersion":1,"schemaVersion":1}',
            json.dumps({"schemaVersion": 2}).encode(),
            json.dumps({"schemaVersion": 1, "fm": []}).encode(),
            json.dumps({"schemaVersion": 1, "fm": {"byKind": []}}).encode(),
            json.dumps({"schemaVersion": 1, "fm": {"retries": 2, "byKind": {}}}).encode(),
            json.dumps({"schemaVersion": 1, "fm": {"retries": True, "retrySuccesses": 0, "byKind": {}}}).encode(),
            json.dumps({"schemaVersion": 1, "fm": {"retries": 0, "retrySuccesses": 1, "byKind": {}}}).encode(),
            json.dumps({"schemaVersion": 1, "fm": {"retries": 1, "retrySuccesses": 0, "byKind": {}}}).encode(),
        ]
        for contents in invalid_records:
            with self.subTest(contents=contents):
                invalid.write_bytes(contents)
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("z-invalid.json", result.stderr)
                self.assertEqual(valid.read_bytes(), original)
                self.assertEqual(invalid.read_bytes(), contents)

    def test_symlink_files_and_directories_are_not_followed(self):
        outside = self.base / "outside"
        outside.mkdir()
        external = outside / "external.json"
        original = b'{"schemaVersion":1,"fm":{"byKind":{}}}'
        external.write_bytes(original)
        (self.scenarios / "linked.json").symlink_to(external)
        (self.root / "linked-month").symlink_to(outside, target_is_directory=True)
        (self.root / "2026-10" / "linked-run").symlink_to(outside, target_is_directory=True)
        extra_run = self.root / "2026-10" / "run-two"
        extra_run.mkdir()
        (extra_run / "scenarios").symlink_to(outside, target_is_directory=True)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["scanned"], 0)
        self.assertEqual(summary["symlinksSkipped"], 4)
        self.assertEqual(external.read_bytes(), original)
        self.assertTrue((self.scenarios / "linked.json").is_symlink())
        linked_root = self.base / "linked-root"
        linked_root.symlink_to(self.root, target_is_directory=True)
        refused = self.invoke(root=linked_root)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("symlink", refused.stderr)

    def test_run_metadata_and_json_outside_scenarios_are_not_migrated(self):
        run = self.scenarios.parent
        metadata = run / "run.json"
        other = run / "unrelated.json"
        metadata.write_bytes(b'{"schemaVersion":1,"finishedAt":"2026-10-17T00:00:00Z","pid":1234}')
        original = metadata.read_bytes()
        original_stat = metadata.stat()
        other.write_bytes(b"not valid JSON; outside migration scope")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["scanned"], 0)
        self.assertEqual(metadata.read_bytes(), original)
        self.assertEqual(metadata.stat().st_mtime_ns, original_stat.st_mtime_ns)
        self.assertEqual(other.read_bytes(), b"not valid JSON; outside migration scope")

    def test_superseded_is_migrated_and_finished_run_metadata_is_only_touched_once(self):
        self.write(fm={"byKind": {"occlusion": {}}})
        run = self.scenarios.parent
        superseded = run / "superseded"
        superseded.mkdir()
        archived = superseded / "sample.1.json"
        archived.write_bytes(b'{"schemaVersion":1,"fm":{"byKind":{}}}')
        metadata = run / "run.json"
        metadata.write_bytes(b'{"schemaVersion":1,"startedAt":"2026-10-16T23:00:00Z","finishedAt":"2026-10-17T00:00:00Z","pid":1234}')
        original = metadata.read_bytes()
        original_stat = metadata.stat()
        dry_run = self.invoke("--dry-run")
        self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
        self.assertEqual(metadata.stat().st_mtime_ns, original_stat.st_mtime_ns)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["changed"], 2)
        self.assertEqual(summary["finishedRunsTouched"], 1)
        self.assertEqual(json.loads(archived.read_bytes())["fm"]["retries"], 0)
        self.assertEqual(metadata.read_bytes(), original)
        self.assertGreaterEqual(metadata.stat().st_mtime_ns, self.scenarios.stat().st_mtime_ns)
        after = metadata.stat()
        repeated = self.invoke()
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(json.loads(repeated.stdout)["finishedRunsTouched"], 0)
        self.assertEqual(metadata.stat().st_mtime_ns, after.st_mtime_ns)
        self.assertEqual(metadata.read_bytes(), original)

    def test_unfinished_metadata_is_never_touched(self):
        self.write(fm={"byKind": {"occlusion": {}}})
        metadata = self.scenarios.parent / "run.json"
        metadata.write_bytes(b'{"schemaVersion":1,"startedAt":"2026-10-16T23:00:00Z","pid":1234}')
        original = metadata.read_bytes()
        before = metadata.stat()
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["changed"], 1)
        self.assertEqual(json.loads(result.stdout)["finishedRunsTouched"], 0)
        self.assertEqual(metadata.read_bytes(), original)
        self.assertEqual(metadata.stat().st_mtime_ns, before.st_mtime_ns)


if __name__ == "__main__":
    unittest.main()
