import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import benchmark
from test_cli import TEST_TMPDIR


class FixtureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fslocate-benchmark-test-", dir=TEST_TMPDIR)
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name) / "fixture"

    def cli(self, *args):
        with patch.object(sys, "argv", ["benchmark.py", *map(str, args)]), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            benchmark.main()

    def prepare(self):
        self.cli("--prepare", self.folder, "--directories", 2, "--files-per-dir", 4,
                 "--case", "all", "deep", "--binary", "/no-binary-needed")

    def test_prepare_and_reuse_preserve_data(self):
        self.prepare()
        marker = self.folder / "fixture.json"
        file = self.folder / "search-root/dir-0000/file-000000"
        file.write_bytes(b"retain contents")
        before = [(path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes()) for path in (marker, file)]
        with patch.object(benchmark, "create_fixture", side_effect=AssertionError("fixture recreated")), \
                patch.object(benchmark, "create_deep_fixture", side_effect=AssertionError("fixture recreated")), \
                patch.object(benchmark, "benchmark") as runner:
            self.cli("--fixture", self.folder, "--binary", sys.executable, "--case", *benchmark.CASES)
        self.assertEqual([call.args[2] for call in runner.call_args_list], list(benchmark.CASES))
        self.assertEqual([len(call.args[1]) for call in runner.call_args_list], [2, 10, 10, 2, 0, 1])
        self.assertEqual(before, [(path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes()) for path in (marker, file)])

    def test_prepare_refuses_existing_directory(self):
        self.folder.mkdir()
        sentinel = self.folder / "keep"
        sentinel.write_bytes(b"unchanged")
        with self.assertRaises(SystemExit) as error:
            self.prepare()
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(sentinel.read_bytes(), b"unchanged")
        self.assertFalse((self.folder / "fixture.json").exists())

    def test_reuse_rejects_mutation_even_outside_query(self):
        self.prepare()
        file = self.folder / "search-root/dir-0000/file-000000"
        file.unlink()  # The selective query matches file-000003, not this entry.
        for kind in ("missing", "symlink", "directory"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    file.symlink_to("file-000001")
                elif kind == "directory":
                    file.mkdir()
                with patch.object(benchmark, "benchmark") as runner, self.assertRaises(SystemExit) as error:
                    self.cli("--fixture", self.folder, "--binary", sys.executable)
                self.assertEqual(error.exception.code, 2)
                runner.assert_not_called()
                if kind == "symlink":
                    file.unlink()
                elif kind == "directory":
                    file.rmdir()

    def test_reuse_rejects_incompatible_shape(self):
        self.prepare()
        marker = self.folder / "fixture.json"
        original = json.loads(marker.read_text())
        for change in ({"version": 2}, {"directories": True}, {"files_per_dir": 0}, {"layouts": ["unknown"]}):
            with self.subTest(change=change):
                marker.write_text(json.dumps(original | change))
                with self.assertRaises(SystemExit) as error:
                    self.cli("--fixture", self.folder, "--binary", sys.executable)
                self.assertEqual(error.exception.code, 2)
