import base64
import fcntl
import json
import os
import resource
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/fslocate"
STREAMING_ENTRIES = 600  # Long names still exceed the 64 KiB output buffer.
TEST_TMPDIR = (
    "/dev/shm"
    if not os.environ.get("TMPDIR") and os.path.isdir("/dev/shm") and os.access("/dev/shm", os.W_OK | os.X_OK)
    else None
)


def wait_for_pipe_write(process):
    deadline = time.monotonic() + 10
    while process.poll() is None:
        states = [path.read_text() for path in Path(f"/proc/{process.pid}/task").glob("*/wchan")]
        if any("pipe_write" in state for state in states):
            return
        if time.monotonic() >= deadline:
            process.kill()
            raise AssertionError("search did not block while writing output")
        time.sleep(0.001)
    raise AssertionError("search exited before writing output")


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="fslocate-test-", dir=TEST_TMPDIR))
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "nested").mkdir()
        for name in ("README.md", ".hidden", "[literal]*", "line\nbreak"):
            (self.root / "nested" / name).touch()

    def run_search(self, pattern, *options):
        return subprocess.run(
            [BINARY, *options, "--root", self.root, "--", pattern],
            capture_output=True,
            timeout=10,
        )

    def paths(self, pattern, *options):
        result = self.run_search(pattern, "-0", *options)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertTrue(not result.stdout or result.stdout.endswith(b"\0"), result.stdout)
        entries = result.stdout.split(b"\0")[:-1] if result.stdout else []
        self.assertEqual(len(entries), len(set(entries)))
        return set(entries)

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
        result = subprocess.run([BINARY, "deep-leaf", alias], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, os.fsencode(leaf) + b"\n")

    def test_symlinks_are_listed_but_not_followed(self):
        (self.root / "nested/loop").symlink_to(self.root, target_is_directory=True)
        (self.root / "broken-link").symlink_to(self.root / "missing")
        result = self.paths("")
        self.assertEqual(len(result), 7)
        self.assertIn(os.fsencode(self.root / "nested/loop"), result)
        self.assertIn(os.fsencode(self.root / "broken-link"), result)

    def test_paths_longer_than_path_max(self):
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        components = ["x" * 200] * 22
        try:
            for component in components:
                os.mkdir(component, dir_fd=fd)
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd)
                os.close(fd)
                fd = child
            os.close(os.open("deep-leaf", os.O_CREAT | os.O_WRONLY, 0o600, dir_fd=fd))
        finally:
            os.close(fd)
        expected = os.fsencode(self.root) + b"/" + b"/".join(map(os.fsencode, components)) + b"/deep-leaf"
        self.assertGreater(len(expected), 4096)
        self.assertEqual(self.paths("deep-leaf", "-b", "walk", "-j", "1"), {expected})

    @unittest.skipUnless(
        Path("/proc/self/wchan").exists() and hasattr(fcntl, "F_GETPIPE_SZ"),
        "requires Linux pipe and process inspection",
    )
    def test_intermediate_directory_replaced_by_symlink_is_not_followed(self):
        root = self.root / "race"
        victim = root / "victim"
        (victim / "child").mkdir(parents=True)
        outside = self.root / "outside"
        (outside / "child").mkdir(parents=True)
        (outside / "child/outside-secret").touch()
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"x" * fcntl.fcntl(write_fd, fcntl.F_GETPIPE_SZ))
        with os.fdopen(read_fd, "rb") as output:
            with subprocess.Popen(
                [BINARY, "-b", "walk", "-j", "1", "-r", root, "/victim/child"],
                stdout=write_fd,
                stderr=subprocess.PIPE,
            ) as process:
                os.close(write_fd)
                wait_for_pipe_write(process)
                # Only child matches, so victim/child is queued before this write blocks.
                victim.rename(root / "moved")
                victim.symlink_to(outside, target_is_directory=True)
                contents = output.read()
                status = process.wait(timeout=10)
                stderr = process.stderr.read()
        self.assertEqual(status, 2, stderr)
        self.assertNotIn(b"outside-secret", contents)
        self.assertIn(b"victim", stderr)

    @unittest.skipUnless(os.name == "posix", "requires resource limits")
    def test_worker_creation_limit_uses_fewer_threads(self):

        def limit_memory():
            resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024,) * 2)

        result = subprocess.run(
            [BINARY, "-b", "walk", "-j", "256", "README", self.root],
            capture_output=True,
            timeout=10,
            preexec_fn=limit_memory,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout, os.fsencode(self.root / "nested/README.md") + b"\n")

    @unittest.skipUnless(
        Path("/proc/self/wchan").exists() and hasattr(fcntl, "F_GETPIPE_SZ"),
        "requires Linux pipe and process inspection",
    )
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
            with subprocess.Popen(
                [BINARY, "-b", "walk", "-j", "1", "-r", root, ""],
                stdout=write_fd,
                stderr=subprocess.PIPE,
            ) as process:
                os.close(write_fd)
                wait_for_pipe_write(process)
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
        for i in range(32):
            directory = self.root / f"d{i}"
            directory.mkdir()
            expected.add(os.fsencode(directory))
            for j in range(16):
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

    def test_text_pages_flush_all_accepted_matches(self):
        expected = {os.fsencode(self.root / f"page-item-{i}") for i in range(40)}
        for path in expected:
            Path(os.fsdecode(path)).touch()
        for threads in (1, 8):
            for offset, limit in ((0, 0), (0, 1), (3, 5), (39, 5), (50, 5), (0, 40)):
                with self.subTest(threads=threads, offset=offset, limit=limit):
                    result = self.run_search(
                        "page-item-",
                        "-b",
                        "walk",
                        "-0",
                        "-j",
                        str(threads),
                        "--offset",
                        str(offset),
                        "--limit",
                        str(limit),
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, b"")
                    paths = result.stdout.split(b"\0")[:-1] if result.stdout else []
                    self.assertEqual(len(paths), min(limit, max(0, len(expected) - offset)))
                    self.assertEqual(len(paths), len(set(paths)))
                    self.assertTrue(set(paths) <= expected)

    def test_default_root_and_option_terminator(self):
        path = self.root / "-needle"
        path.touch()
        result = subprocess.run([BINARY, "--", "-needle"], cwd=self.root, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, os.fsencode(path) + b"\n")

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_text_limit_stops_at_the_last_requested_match(self):
        target = self.root / "page-stop-target"
        target.touch()
        blocked = self.root / "blocked"
        blocked.mkdir()
        blocked.chmod(0)
        try:
            result = self.run_search("page-stop-target", "-b", "walk", "-j", "1", "--limit", "1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, b"")
            self.assertEqual(result.stdout, os.fsencode(target) + b"\n")
        finally:
            blocked.chmod(0o700)

    def test_root_options_and_positional_compatibility(self):
        expected = os.fsencode(self.root / "nested/README.md") + b"\n"
        for args in (
            ["-r", self.root, "README"],
            ["README", "--root", self.root],
            ["--root", ".", "README"],
            ["README", self.root],
        ):
            result = subprocess.run([BINARY, *args], cwd=self.root, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

        path = self.root / "-needle"
        path.touch()
        result = subprocess.run([BINARY, "-r", self.root, "--", "-needle"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, os.fsencode(path) + b"\n")

    def test_invalid_arguments_and_roots(self):
        for args in (
            [],
            ["--unknown"],
            ["-r"],
            ["--root"],
            ["--root", self.root],
            ["--root", self.root, "x", self.root],
            ["x", self.root, "--root", self.root],
            ["x", "--root", self.root / "missing"],
            ["x", "-r", self.root / "nested/README.md"],
            ["-j"],
            ["-j", "0", "x"],
            ["-j", "257", "x"],
            ["-j", "abc", "x"],
            ["x", self.root / "missing"],
            ["x", self.root / "nested/README.md"],
            ["x", ".", "."],
        ):
            result = subprocess.run([BINARY, *args], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2, (args, result.stderr))
            self.assertTrue(result.stderr)

    def test_help_and_version(self):
        version = self.declared_version()
        for option, expected in (
            ("--help", b"Usage:"),
            ("--version", version),
            ("--help", b"schema"),
        ):
            result = subprocess.run([BINARY, option], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertIn(expected, result.stdout)
            self.assertEqual(result.stderr, b"")

    def declared_version(self):
        repo = Path(__file__).resolve().parents[1]
        pyproject = (repo / "pyproject.toml").read_text()
        main = (repo / "src/main.zig").read_text()
        changelog = (repo / "CHANGELOG.md").read_text()
        security = (repo / "SECURITY.md").read_text()
        import re

        pyproject_version = re.search(r'^version = "([^"]+)"', pyproject, re.M).group(1)
        zig_version = re.search(r'const version = "([^"]+)";', main).group(1)
        self.assertEqual(pyproject_version, zig_version)
        self.assertIn(f'"{pyproject_version}"', main)
        self.assertIn(f"## [{pyproject_version}]", changelog)
        major_minor = ".".join(pyproject_version.split(".")[:2])
        self.assertIn(f"{major_minor}.x (current)", security)
        for version_literal in re.findall(r'"version":"([^"]+)"', main):
            self.assertEqual(version_literal, zig_version)
        return zig_version.encode()

    def test_backend_selection(self):
        expected = self.paths("README", "--backend", "walk")
        self.assertEqual(self.paths("README", "-b", "auto"), expected)
        for args in (["--backend"], ["--backend", "invalid", "README"]):
            result = subprocess.run([BINARY, *args], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)

    @unittest.skipUnless(Path("/dev/full").exists(), "requires /dev/full")
    def test_output_errors_are_reported(self):
        with open("/dev/full", "wb") as output:
            result = subprocess.run(
                [BINARY, "README", self.root],
                stdout=output,
                stderr=subprocess.PIPE,
                timeout=10,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"stdout", result.stderr)

    def test_json_output_error_is_reported_once(self):

        for i in range(STREAMING_ENTRIES):
            (self.root / (f"entry-{i}-" + "x" * 100)).touch()
        for pattern in ("README", ""):
            for threads in (1, 8):
                with (
                    self.subTest(pattern=pattern, threads=threads),
                    open("/dev/full", "wb") as output,
                ):
                    result = subprocess.run(
                        [BINARY, "-o", "json", "-j", str(threads), pattern, self.root],
                        stdout=output,
                        stderr=subprocess.PIPE,
                        timeout=10,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
                    error = json.loads(result.stderr)["error"]
                    self.assertEqual(error["path"], "stdout")
                    self.assertEqual(error["message"], "NoSpaceLeft")

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_text_error_escapes_filename_controls(self):
        blocked = self.root / "blocked-\nFAKE\x1b\x7f"
        blocked.mkdir()
        blocked.chmod(0)
        try:
            result = self.run_search("README", "-b", "walk")
            self.assertEqual(result.returncode, 2)
            self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
            self.assertIn(b"blocked-\\u000aFAKE\\u001b\\u007f", result.stderr)
        finally:
            blocked.chmod(0o700)

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
        for i in range(STREAMING_ENTRIES):
            (self.root / (f"f{i}-" + "x" * 100)).touch()
        for options in ([], ["-o", "json"], ["-o", "json", "--limit", "1"]):
            with self.subTest(options=options):
                with subprocess.Popen(
                    [BINARY, *options, "", self.root],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                ) as process:
                    process.stdout.close()
                    self.assertEqual(process.wait(timeout=10), 0)
                    self.assertEqual(process.stderr.read(), b"")


class ClispecTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="fslocate-test-", dir=TEST_TMPDIR))
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "nested").mkdir()
        (self.root / "nested" / "README.md").touch()
        (self.root / "nested" / "notes.txt").touch()

    def test_usage_errors_follow_the_effective_output_option(self):

        for args, structured in (
            (["-r", "--", "-o", "json"], True),
            (["-r", "-o", "json", "--unknown"], False),
            (["-r", "--output=json", "--unknown"], False),
            (["-o", "json", "-o", "text", "--unknown"], False),
            (["-o", "text", "-o", "json", "--unknown"], True),
            (["--limit", "bad", "-o", "json", "x"], True),
            (["--", "-o", "json", "extra"], False),
        ):
            with self.subTest(args=args):
                result = subprocess.run([BINARY, *args], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
                if structured:
                    self.assertEqual(json.loads(result.stderr)["error"]["kind"], "usage")
                else:
                    self.assertTrue(result.stderr.startswith(b"fslocate:"), result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_json_directory_errors_are_json_lines_with_context(self):

        blocked = self.root / 'blocked-"\nname'
        blocked.mkdir()
        blocked.chmod(0)
        try:
            result = subprocess.run(
                [BINARY, "-o", "json", "-b", "walk", "-r", self.root, "README"],
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 2)
            errors = [json.loads(line)["error"] for line in result.stderr.splitlines()]
            self.assertEqual(len(errors), 1)
            self.assertEqual(errors[0]["kind"], "failure")
            self.assertEqual(errors[0]["path"], str(blocked))
            self.assertIn("AccessDenied", errors[0]["message"])
            document = json.loads(result.stdout)
            self.assertEqual(document["items"], [{"path": str(self.root / "nested/README.md")}])
            self.assertTrue(document["incomplete"])
            self.assertNotIn("total", document)
        finally:
            blocked.chmod(0o700)

    @unittest.skipUnless(Path("/dev/shm").is_dir(), "requires tmpfs mount")
    def test_unsupported_native_json_errors_have_no_text_prefix(self):

        result = subprocess.run(
            [BINARY, "-o", "json", "-b", "native", "-r", "/dev/shm", ""],
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)["error"]["kind"], "failure")

    def test_json_preserves_distinct_raw_path_identities(self):

        expected = {
            os.fsencode(self.root) + b"/raw-\xff",
            os.fsencode(self.root) + b"/raw-\xc3\xbf",
        }
        for path in expected:
            fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
            os.close(fd)
        for fields in ("path", "path,path_bytes_base64", "path_bytes_base64"):
            with self.subTest(fields=fields):
                result = subprocess.run(
                    [BINARY, "-o", "json", "--fields", fields, "-r", self.root, "raw-"],
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                items = json.loads(result.stdout)["items"]
                identities = {
                    base64.b64decode(item["path_bytes_base64"], validate=True)
                    if "path_bytes_base64" in item
                    else item["path"].encode("utf-8")
                    for item in items
                }
                self.assertEqual(len(items), 2)
                self.assertEqual(identities, expected)
                self.assertEqual(
                    sum("path_bytes_base64" in item for item in items),
                    1 if fields == "path" else 2,
                )
                if fields == "path_bytes_base64":
                    self.assertTrue(all(set(item) == {"path_bytes_base64"} for item in items))

    def test_command_words_are_literal_patterns_after_search(self):
        for pattern in ("search", "schema"):
            path = self.root / (pattern + "-file")
            path.touch()
            for args in (
                ["search", pattern, self.root],
                ["search", "-r", self.root, pattern],
                ["-r", self.root, "--", pattern],
            ):
                with self.subTest(args=args):
                    result = subprocess.run([BINARY, *args], capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, os.fsencode(path) + b"\n")

    def test_inline_option_values_match_separate_values(self):
        options = [
            ("--root", str(self.root)),
            ("--backend", "walk"),
            ("--threads", "1"),
            ("--offset", "0"),
            ("--limit", "1"),
            ("--output", "json"),
            ("--fields", "path"),
        ]
        separate = [part for pair in options for part in pair]
        inline = [f"{name}={value}" for name, value in options]
        baseline = subprocess.run([BINARY, *separate, "README"], capture_output=True, timeout=10)
        result = subprocess.run([BINARY, *inline, "README"], capture_output=True, timeout=10)
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        for option in (
            "--limit=bad",
            "--threads=0",
            "--ignore-case=true",
            "--help=true",
            "--root",
        ):
            result = subprocess.run([BINARY, "-o", "json", option], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2, (option, result.stderr))

    def test_schema_rejects_search_only_options(self):
        for args in (
            ["schema", "--root", self.root],
            ["-i", "schema"],
            ["schema", "--fields=path"],
            ["schema", "--limit=1"],
        ):
            with self.subTest(args=args):
                result = subprocess.run([BINARY, *args], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")

    @unittest.skipUnless(
        Path("/proc/self/wchan").exists() and hasattr(fcntl, "F_GETPIPE_SZ"),
        "requires Linux pipe and process inspection",
    )
    def test_json_streams_before_finishing_the_tree(self):

        child = self.root / "child"
        child.mkdir()
        for i in range(STREAMING_ENTRIES):
            (self.root / (f"bulk-{i}-" + "x" * 100)).touch()
        read_fd, write_fd = os.pipe()
        capacity = fcntl.fcntl(write_fd, fcntl.F_GETPIPE_SZ)
        os.write(write_fd, b"x" * capacity)
        with os.fdopen(read_fd, "rb") as output:
            with subprocess.Popen(
                [
                    BINARY,
                    "-b",
                    "walk",
                    "-j",
                    "1",
                    "-o",
                    "json",
                    "-r",
                    self.root,
                    "bulk-",
                ],
                stdout=write_fd,
                stderr=subprocess.PIPE,
            ) as process:
                os.close(write_fd)
                wait_for_pipe_write(process)
                late = child / "bulk-added-after-first-output"
                late.touch()
                self.assertEqual(output.read(capacity), b"x" * capacity)
                document = json.loads(output.read())
                self.assertEqual(process.wait(timeout=10), 0, process.stderr.read())
        self.assertEqual(document["total"], STREAMING_ENTRIES + 1)
        self.assertIn({"path": str(late)}, document["items"])

    def test_schema_is_offline_json(self):

        result = subprocess.run([BINARY, "schema"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        doc = json.loads(result.stdout)
        self.assertEqual(doc["clispec"], "0.3")
        self.assertEqual(doc["name"], "fslocate")
        self.assertEqual(doc["version"].encode(), self.declared_version())
        self.assertEqual(doc["output"]["piped"], "text")
        names = [command["name"] for command in doc["commands"]]
        self.assertEqual(names, ["schema", "search"])
        schema = doc["commands"][0]
        self.assertEqual({field["name"] for field in schema["output_fields"]}, set(doc))
        self.assertEqual(schema["args"][0]["name"], "COMMAND")
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
        self.assertEqual(
            [command["name"] for command in json.loads(again.stdout)["commands"]],
            ["schema"],
        )

    def test_json_items_text_mode_and_usage_envelope(self):

        listed = subprocess.run(
            [
                BINARY,
                "-o",
                "json",
                "--limit",
                "1",
                "--fields",
                "path",
                "nested",
                self.root,
            ],
            capture_output=True,
            timeout=10,
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
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertTrue(text.stdout.endswith(b"\n"))
        self.assertNotIn(b"{", text.stdout)
        self.assertIn(b"README.md", text.stdout)

        piped = subprocess.run(
            [BINARY, "README.md", self.root],
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(piped.returncode, 0)
        self.assertIn(b"README.md", piped.stdout)
        self.assertNotIn(b"{", piped.stdout)

        missing = subprocess.run(
            [BINARY, "-o", "json", "no-such-name", self.root],
            capture_output=True,
            timeout=10,
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
            cwd=self.root,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(encoded.returncode, 0, encoded.stderr)
        payload = json.loads(encoded.stdout)
        self.assertTrue(any(item["path"].endswith("raw-\u00ff") for item in payload["items"]))

    def test_numeric_arguments_reject_overflow_and_garbage(self):
        import json

        # parseInt(usize) must reject out-of-range values at the trust
        # boundary (CLI args) rather than truncating or wrapping. Zig's
        # stdlib parser already enforces range checks; pin them so a
        # future switch to unchecked parsing fails loudly.
        for option in ("--limit", "--offset", "--threads"):
            for value in ("18446744073709551616", "999999999999999999999999999999", "0x10", "", " 5", "-1"):
                with self.subTest(option=option, value=value):
                    result = subprocess.run(
                        [BINARY, "-o", "json", option, value, "x", self.root],
                        capture_output=True,
                        timeout=10,
                    )
                    self.assertEqual(result.returncode, 2, (option, value, result.stderr))
                    self.assertEqual(result.stdout, b"")
        # Huge-but-valid values must behave as unbounded, not wrap.
        result = subprocess.run(
            [BINARY, "-o", "json", "--limit", "18446744073709551615", "README", self.root],
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["total"], len(document["items"]))
        self.assertNotIn("truncated", document)


if __name__ == "__main__":
    unittest.main()
