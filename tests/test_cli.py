import os
import fcntl
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/fslocate"


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="fslocate-test-"))
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "nested").mkdir()
        for name in ("README.md", ".hidden", "[literal]*", "line\nbreak"):
            (self.root / "nested" / name).touch()

    def run_search(self, pattern, *options):
        return subprocess.run(
            [BINARY, *options, "--root", self.root, "--", pattern],
            capture_output=True, timeout=10,
        )

    def paths(self, pattern, *options):
        result = self.run_search(pattern, "-0", *options)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        return set(result.stdout.rstrip(b"\0").split(b"\0"))

    def test_literals_case_and_hidden_entries(self):
        self.assertEqual(len(self.paths("[literal]*")), 1)
        self.assertEqual(len(self.paths(".hidden")), 1)
        self.assertEqual(len(self.paths("readme", "-i")), 1)
        result = self.run_search("readme")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")

    def test_raw_filenames_and_nul_output(self):
        raw = os.fsencode(self.root / "nested") + b"/raw-\xff"
        fd = os.open(raw, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
        self.assertIn(raw, self.paths(b"\xff"))
        self.assertIn(os.fsencode(self.root / "nested/line\nbreak"), self.paths("line\nbreak"))

    def test_live_changes(self):
        old = self.root / "fresh-old"
        new = self.root / "fresh-new"
        old.touch()
        self.assertEqual(self.paths("fresh-"), {os.fsencode(old)})
        old.rename(new)
        self.assertEqual(self.paths("fresh-"), {os.fsencode(new)})
        new.unlink()
        self.assertEqual(self.run_search("fresh-").returncode, 1)

    def test_metadata_only_search_and_special_files(self):
        unreadable = self.root / "unreadable-file"
        unreadable.touch()
        unreadable.chmod(0)
        fifo = self.root / "named-pipe"
        os.mkfifo(fifo)
        self.assertEqual(self.paths("unreadable-file"), {os.fsencode(unreadable)})
        self.assertEqual(self.paths("named-pipe"), {os.fsencode(fifo)})

    def test_full_paths_deep_trees_and_root_symlink(self):
        self.assertEqual(len(self.paths("/nested")), 5)
        deep = self.root
        for _ in range(80):
            deep /= "deep"
            deep.mkdir()
        leaf = deep / "deep-leaf"
        leaf.touch()
        self.assertEqual(self.paths("deep-leaf"), {os.fsencode(leaf)})
        alias = self.root / "root-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        result = subprocess.run([BINARY, "deep-leaf", alias],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, os.fsencode(leaf) + b"\n")

    def test_symlinks_are_listed_but_not_followed(self):
        (self.root / "nested/loop").symlink_to(self.root, target_is_directory=True)
        (self.root / "broken-link").symlink_to(self.root / "missing")
        result = self.paths("")
        self.assertEqual(len(result), 7)
        self.assertIn(os.fsencode(self.root / "nested/loop"), result)
        self.assertIn(os.fsencode(self.root / "broken-link"), result)

    @unittest.skipUnless(Path("/proc/self/wchan").exists() and hasattr(fcntl, "F_GETPIPE_SZ"),
                         "requires Linux pipe and process inspection")
    def test_queued_directory_replaced_by_symlink_is_not_followed(self):
        root = self.root / "race"
        root.mkdir()
        victim = root / "victim"
        victim.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "outside-secret").touch()
        read_fd, write_fd = os.pipe()
        capacity = fcntl.fcntl(write_fd, fcntl.F_GETPIPE_SZ)
        os.write(write_fd, b"x" * capacity)
        with os.fdopen(read_fd, "rb") as output:
            with subprocess.Popen([BINARY, "-b", "walk", "-j", "1", "-r", root, ""],
                                  stdout=write_fd, stderr=subprocess.PIPE) as process:
                os.close(write_fd)
                deadline = time.monotonic() + 10
                while True:
                    self.assertIsNone(process.poll(), "search exited before emitting the directory")
                    states = [path.read_text() for path in Path(f"/proc/{process.pid}/task").glob("*/wchan")]
                    if any("pipe_write" in state for state in states):
                        break
                    if time.monotonic() >= deadline:
                        process.kill()
                        self.fail("search did not block while writing its directory result")
                    time.sleep(0.001)
                # Backpressure pauses the scan after queuing victim, before opening it.
                victim.rmdir()
                victim.symlink_to(outside, target_is_directory=True)
                contents = output.read()
                status = process.wait(timeout=10)
                stderr = process.stderr.read()
        self.assertEqual(status, 2, stderr)
        self.assertNotIn(b"outside-secret", contents)
        self.assertIn(b"victim", stderr)

    def test_parallel_scan_has_no_missing_or_duplicate_paths(self):
        expected = self.paths("", "-j", "1")
        for i in range(64):
            directory = self.root / f"d{i}"
            directory.mkdir()
            expected.add(os.fsencode(directory))
            for j in range(32):
                path = directory / f"f{j}"
                path.touch()
                expected.add(os.fsencode(path))
        for threads in (1, 2, 8):
            for _ in range(3):
                result = self.run_search("", "-0", "-j", str(threads))
                self.assertEqual(result.returncode, 0, result.stderr)
                paths = result.stdout.rstrip(b"\0").split(b"\0")
                self.assertEqual(len(paths), len(expected))
                self.assertEqual(set(paths), expected)

    def test_default_root_and_option_terminator(self):
        path = self.root / "-needle"
        path.touch()
        result = subprocess.run([BINARY, "--", "-needle"], cwd=self.root,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, os.fsencode(path) + b"\n")

    def test_root_options_and_positional_compatibility(self):
        expected = os.fsencode(self.root / "nested/README.md") + b"\n"
        for args in (["-r", self.root, "README"],
                     ["README", "--root", self.root],
                     ["--root", ".", "README"],
                     ["README", self.root]):
            result = subprocess.run([BINARY, *args], cwd=self.root,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

        path = self.root / "-needle"
        path.touch()
        result = subprocess.run([BINARY, "-r", self.root, "--", "-needle"],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, os.fsencode(path) + b"\n")

    def test_invalid_arguments_and_roots(self):
        for args in ([], ["--unknown"], ["-r"], ["--root"], ["--root", self.root],
                     ["--root", self.root, "x", self.root],
                     ["x", self.root, "--root", self.root],
                     ["x", "--root", self.root / "missing"],
                     ["x", "-r", self.root / "nested/README.md"],
                     ["-j"], ["-j", "0", "x"],
                     ["-j", "257", "x"], ["-j", "abc", "x"],
                     ["x", self.root / "missing"],
                     ["x", self.root / "nested/README.md"], ["x", ".", "."]):
            result = subprocess.run([BINARY, *args], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2, (args, result.stderr))
            self.assertTrue(result.stderr)

    def test_help_and_version(self):
        for option, expected in (("--help", b"Usage:"), ("--version", b"0.2.0"), ("--help", b"schema")):
            result = subprocess.run([BINARY, option], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertIn(expected, result.stdout)
            self.assertEqual(result.stderr, b"")

    def test_backend_selection(self):
        expected = self.paths("README", "--backend", "walk")
        self.assertEqual(self.paths("README", "-b", "auto"), expected)
        for args in (["--backend"], ["--backend", "invalid", "README"]):
            result = subprocess.run([BINARY, *args], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)

    @unittest.skipUnless(Path("/dev/full").exists(), "requires /dev/full")
    def test_output_errors_are_reported(self):
        with open("/dev/full", "wb") as output:
            result = subprocess.run([BINARY, "README", self.root],
                                    stdout=output, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"stdout", result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_unreadable_directory_reports_incomplete_search(self):
        blocked = self.root / "blocked"
        blocked.mkdir()
        (blocked / "secret").touch()
        blocked.chmod(0)
        try:
            result = self.run_search("README")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"README.md", result.stdout)
            self.assertIn(b"blocked", result.stderr)
        finally:
            blocked.chmod(0o700)

    def test_closed_pipe_exits_cleanly(self):
        for i in range(3000):
            (self.root / (f"f{i}-" + "x" * 100)).touch()
        with subprocess.Popen([BINARY, "", self.root], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            process.stdout.close()
            self.assertEqual(process.wait(timeout=10), 0)
            self.assertEqual(process.stderr.read(), b"")


class ClispecTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="fslocate-test-"))
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "nested").mkdir()
        (self.root / "nested" / "README.md").touch()
        (self.root / "nested" / "notes.txt").touch()

    def test_schema_is_offline_json(self):
        import json
        result = subprocess.run([BINARY, "schema"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        doc = json.loads(result.stdout)
        self.assertEqual(doc["clispec"], "0.3")
        self.assertEqual(doc["name"], "fslocate")
        self.assertEqual(doc["version"], "0.2.0")
        self.assertEqual(doc["output"]["piped"], "text")
        names = [command["name"] for command in doc["commands"]]
        self.assertEqual(names, ["schema", "search"])
        search = doc["commands"][1]
        self.assertEqual(search["cardinality"], "unbounded")
        self.assertEqual(search["pagination"]["offset_arg"], "--offset")
        self.assertEqual(search["pagination"]["limit_arg"], "--limit")
        self.assertEqual(search["fields_arg"], "--fields")
        self.assertTrue(any(item["kind"] == "usage" and item["exit_code"] == 2 for item in doc["errors"]))
        self.assertTrue(any(item["name"] == "no_match" and item["code"] == 1 for item in doc["outcomes"]))
        filtered = subprocess.run([BINARY, "schema", "search"], capture_output=True, timeout=10)
        self.assertEqual(filtered.returncode, 0)
        narrowed = json.loads(filtered.stdout)
        self.assertEqual([command["name"] for command in narrowed["commands"]], ["search"])
        again = subprocess.run([BINARY, "schema", "schema"], capture_output=True, timeout=10)
        self.assertEqual([command["name"] for command in json.loads(again.stdout)["commands"]], ["schema"])

    def test_json_items_text_mode_and_usage_envelope(self):
        import json
        listed = subprocess.run(
            [BINARY, "-o", "json", "--limit", "1", "--fields", "path", "nested", self.root],
            capture_output=True, timeout=10,
        )
        self.assertEqual(listed.returncode, 0, listed.stderr)
        doc = json.loads(listed.stdout)
        self.assertEqual(len(doc["items"]), 1)
        self.assertIn("path", doc["items"][0])
        self.assertTrue(doc["truncated"])
        self.assertNotIn("total", doc)
        self.assertFalse(listed.stderr.rstrip().startswith(b"{"))

        text = subprocess.run(
            [BINARY, "-o", "text", "README.md", self.root],
            capture_output=True, timeout=10,
        )
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertTrue(text.stdout.endswith(b"\n"))
        self.assertNotIn(b"{", text.stdout)
        self.assertIn(b"README.md", text.stdout)

        piped = subprocess.run(
            [BINARY, "README.md", self.root],
            capture_output=True, timeout=10,
        )
        self.assertEqual(piped.returncode, 0)
        self.assertIn(b"README.md", piped.stdout)
        self.assertNotIn(b"{", piped.stdout)

        missing = subprocess.run(
            [BINARY, "-o", "json", "no-such-name", self.root],
            capture_output=True, timeout=10,
        )
        self.assertEqual(missing.returncode, 1)
        empty = json.loads(missing.stdout)
        self.assertEqual(empty, {"items": [], "total": 0})
        self.assertEqual(missing.stderr, b"")

        usage = subprocess.run([BINARY, "-o", "json", "schema", "missing"], capture_output=True, timeout=10)
        self.assertEqual(usage.returncode, 2)
        last = usage.stderr.strip().splitlines()[-1]
        err = json.loads(last)
        self.assertEqual(err["error"]["kind"], "usage")
        self.assertIn("hint", err["error"])

        raw = os.fsencode(self.root / "nested") + b"/raw-\xff"
        fd = os.open(raw, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
        encoded = subprocess.run(
            [BINARY, "-o", "json", "--", b"\xff"],
            cwd=self.root, capture_output=True, timeout=10,
        )
        self.assertEqual(encoded.returncode, 0, encoded.stderr)
        payload = json.loads(encoded.stdout)
        self.assertTrue(any(item["path"].endswith("raw-\u00ff") for item in payload["items"]))


if __name__ == "__main__":
    unittest.main()
