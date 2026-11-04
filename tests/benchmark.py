"""Compare checked-in search workloads; fixture setup is never timed."""

import argparse
import base64
import json
import os
import resource
import shutil
import statistics
import subprocess
import tempfile
import time
from contextlib import nullcontext
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
CASES = ("selective", "all", "json", "ignore-case", "missing", "deep")


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def create_fixture(root, directories, files):
    root.mkdir()
    for d in range(directories):
        directory = root / f"dir-{d:04d}"
        directory.mkdir()
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for f in range(files):
                name = f"file-{f:06d}"
                os.close(os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=fd))
        finally:
            os.close(fd)


def create_deep_fixture(root):
    root.mkdir()
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for _ in range(200):
            os.mkdir("abcdefghij", dir_fd=fd)
            child = os.open("abcdefghij", os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
        os.close(os.open("deep-leaf", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=fd))
    finally:
        os.close(fd)


def expected_fixture(root, directories, files):
    paths = {}
    for d in range(directories):
        directory = os.fsencode(root / f"dir-{d:04d}")
        paths[directory] = True
        paths.update((directory + f"/file-{f:06d}".encode(), False) for f in range(files))
    return paths


def expected_deep_fixture(root):
    paths = {os.fsencode(root) + b"/abcdefghij" * depth: True for depth in range(1, 201)}
    paths[os.fsencode(root) + b"/abcdefghij" * 200 + b"/deep-leaf"] = False
    return paths


def validate_fixture(root, expected):
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"missing fixture directory: {root}")
    pending = [root]
    seen = set()
    while pending:
        with os.scandir(pending.pop()) as entries:
            for entry in entries:
                path = os.fsencode(entry.path)
                directory = entry.is_dir(follow_symlinks=False)
                if expected.get(path) is not directory or (not directory and not entry.is_file(follow_symlinks=False)):
                    raise ValueError(f"unexpected fixture entry or type: {entry.path!r}")
                seen.add(path)
                if directory:
                    pending.append(entry.path)
    if len(seen) != len(expected):
        raise ValueError(f"fixture entries missing in {root}")


def prepare_fixture(folder, directories, files, layouts):
    if "shallow" in layouts:
        create_fixture(folder / "search-root", directories, files)
    if "deep" in layouts:
        create_deep_fixture(folder / "deep-root")
    metadata = {
        "version": 1,
        "directories": directories,
        "files_per_dir": files,
        "layouts": sorted(layouts),
    }
    (folder / "fixture.json").write_text(json.dumps(metadata, sort_keys=True) + "\n")
    return metadata


def read_fixture(folder):
    metadata = json.loads((folder / "fixture.json").read_text())
    if not isinstance(metadata, dict) or type(metadata.get("version")) is not int or metadata["version"] != 1:
        raise ValueError("unsupported fixture version")
    for field in ("directories", "files_per_dir"):
        if type(metadata.get(field)) is not int or metadata[field] < 1:
            raise ValueError(f"invalid fixture {field}")
    layouts = metadata.get("layouts")
    if not isinstance(layouts, list) or not layouts or any(layout not in ("shallow", "deep") for layout in layouts):
        raise ValueError("invalid fixture layouts")
    return metadata


def commands(binary, compare, root, query, case, native):
    output = "json" if case == "json" else "text"
    flags = ["-i"] if case == "ignore-case" else []
    tools = {}
    for label, executable in (("current", binary), ("before", compare)):
        if executable is None:
            continue
        for threads in (1, 8):
            tools[f"{label} walk j{threads}"] = [
                executable,
                "-b",
                "walk",
                "-j",
                str(threads),
                "-0",
                "-o",
                output,
                *flags,
                "-r",
                root,
                "--",
                query,
            ]
    if native:
        tools["current native j8 (sudo)"] = [
            "sudo",
            "-n",
            binary,
            "-b",
            "native",
            "-j",
            "8",
            "-0",
            "-o",
            output,
            *flags,
            "-r",
            root,
            "--",
            query,
        ]
    if case != "json":
        if shutil.which("find"):
            tools["find"] = [
                "find",
                root,
                "-mindepth",
                "1",
                "-ipath" if flags else "-path",
                "*" + query + "*",
                "-print0",
            ]
        if shutil.which("fd"):
            tools["fd j8"] = [
                "fd",
                "-F",
                "-p",
                "-H",
                "-I",
                "--color",
                "never",
                "-j",
                "8",
                "-0",
                "-i" if flags else "-s",
                "--",
                query,
                root,
            ]
    return tools


def run(command, capture):
    return subprocess.run(
        command,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=60,
    )


def verify(name, command, expected, case):
    result = run(command, True)
    assert result.returncode in (0, 1) and not result.stderr, (
        name,
        result.returncode,
        result.stderr,
    )
    if case == "json":
        document = json.loads(result.stdout)
        entries = [
            base64.b64decode(item["path_bytes_base64"], validate=True)
            if "path_bytes_base64" in item
            else item["path"].encode("utf-8")
            for item in document["items"]
        ]
        assert document["total"] == len(expected), (name, document)
    else:
        assert not result.stdout or result.stdout.endswith(b"\0"), name
        entries = [path.removesuffix(b"/") for path in result.stdout.split(b"\0")[:-1]]
    assert set(entries) == expected and len(entries) == len(expected), (
        name,
        "incorrect paths",
    )
    return result.returncode


def benchmark(tools, expected, case, runs):
    statuses = {name: verify(name, command, expected, case) for name, command in tools.items()}
    samples = {name: [] for name in tools}
    names = list(tools)
    for iteration in range(runs):
        offset = iteration % len(names)
        order = names[offset:] + names[:offset]
        if (iteration // len(names)) % 2:
            order.reverse()
        for name in order:
            usage = resource.getrusage(resource.RUSAGE_CHILDREN)
            start = time.perf_counter_ns()
            result = run(tools[name], False)
            wall = (time.perf_counter_ns() - start) / 1_000_000
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            cpu = ((after.ru_utime - usage.ru_utime) + (after.ru_stime - usage.ru_stime)) * 1000
            assert result.returncode == statuses[name] and not result.stderr, (
                name,
                result.returncode,
                result.stderr,
            )
            samples[name].append((wall, cpu))
    print(
        f"\n{case}: {len(expected):,} matches; warm cache; {runs} interleaved runs",
        flush=True,
    )
    print(f"{'tool':30s} {'wall ms':>10s} {'CPU ms':>10s} {'wall range ms':>19s}")
    for name, measurements in samples.items():
        wall, cpu = zip(*measurements)
        print(
            f"{name:30s} {statistics.median(wall):10.2f} {statistics.median(cpu):10.2f} {min(wall):8.2f}–{max(wall):8.2f}",
            flush=True,
        )
    for threads in (1, 8):
        before = samples.get(f"before walk j{threads}")
        if before:
            current = samples[f"current walk j{threads}"]
            # Guard zero denominators: perf_counter_ns deltas and
            # getrusage deltas are floats; a 0ms sample would raise
            # ZeroDivisionError and lose the whole report. Keep only
            # pairs with a non-zero denominator (matches CPU filter below).
            wall = statistics.median(old[0] / new[0] for old, new in zip(before, current) if new[0] > 0)
            cpu = [old[1] / new[1] for old, new in zip(before, current) if new[1] > 0]
            print(
                f"before/current j{threads}: {wall:.2f}x wall; {statistics.median(cpu):.2f}x CPU",
                flush=True,
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true", help="include sudo native search")
    parser.add_argument("--binary", type=Path, default=PROJECT / "zig-out/bin/fslocate")
    parser.add_argument("--compare", type=Path, help="also run a previous binary on the same fixture")
    parser.add_argument("--case", nargs="+", choices=CASES, default=["selective"])
    parser.add_argument("--runs", type=positive, default=7)
    parser.add_argument("--directories", type=positive, help="default: 1000, or saved fixture value")
    parser.add_argument("--files-per-dir", type=positive, help="default: 100, or saved fixture value")
    fixtures = parser.add_mutually_exclusive_group()
    fixtures.add_argument(
        "--fixture-parent",
        type=Path,
        default=PROJECT,
        help="filesystem for temporary data; /dev/shm avoids disk I/O",
    )
    fixtures.add_argument(
        "--prepare",
        type=Path,
        metavar="DIR",
        help="create a reusable fixture and exit; DIR must not exist",
    )
    fixtures.add_argument(
        "--fixture",
        type=Path,
        metavar="DIR",
        help="reuse a prepared fixture without modifying it",
    )
    parser.add_argument("--cpus", help="Linux CPU affinity, e.g. 2,3,4,5,6,7,8,9")
    options = parser.parse_args()
    layouts = {"deep" if case == "deep" else "shallow" for case in options.case}
    if options.prepare:
        folder = options.prepare.resolve()
        try:
            folder.mkdir(mode=0o700)
        except OSError as error:
            parser.error(f"cannot create fixture: {error}")
        try:
            prepare_fixture(
                folder,
                options.directories or 1000,
                options.files_per_dir or 100,
                layouts,
            )
        except BaseException:
            shutil.rmtree(folder)
            raise
        print(f"Prepared {folder}; layouts: {', '.join(sorted(layouts))}")
        return
    if options.fixture:
        folder = options.fixture.resolve()
        try:
            metadata = read_fixture(folder)
        except (OSError, ValueError) as error:
            parser.error(f"cannot read prepared fixture: {error}")
        if not layouts <= set(metadata["layouts"]):
            parser.error("requested workload was not prepared; create a new fixture with the required --case values")
        for field in ("directories", "files_per_dir"):
            value = getattr(options, field)
            if value is not None and value != metadata[field]:
                parser.error(f"{field} differs from the saved fixture")
            setattr(options, field, metadata[field])
        workspace = nullcontext(folder)
    else:
        options.directories = options.directories or 1000
        options.files_per_dir = options.files_per_dir or 100
        workspace = None
    if options.cpus is not None:
        try:
            cpus = {int(cpu) for cpu in options.cpus.split(",")}
            if not cpus <= os.sched_getaffinity(0):
                raise ValueError("CPU outside the current allowed set")
            os.sched_setaffinity(0, cpus)
        except (AttributeError, ValueError, OSError) as error:
            parser.error(f"invalid CPU affinity: {error}")
    binary = options.binary.resolve()
    compare = options.compare.resolve() if options.compare else None
    for executable in (binary, compare):
        if executable is not None and (not executable.is_file() or not os.access(executable, os.X_OK)):
            parser.error(f"not an executable file: {executable}")
    if workspace is None:
        workspace = tempfile.TemporaryDirectory(prefix=".fslocate-bench-", dir=options.fixture_parent)
    print(
        "Setup and correctness checks excluded. CPU sums search-process threads; wall includes waiting.",
        flush=True,
    )
    with workspace as folder:
        folder = Path(folder)
        if not options.fixture:
            prepare_fixture(folder, options.directories, options.files_per_dir, layouts)
        root = Path(folder) / "search-root"
        manifest = expected_fixture(root, options.directories, options.files_per_dir) if "shallow" in layouts else {}
        deep_manifest = expected_deep_fixture(folder / "deep-root") if "deep" in layouts else {}
        if options.fixture:
            try:
                if "shallow" in layouts:
                    validate_fixture(root, manifest)
                if "deep" in layouts:
                    validate_fixture(folder / "deep-root", deep_manifest)
            except (OSError, ValueError) as error:
                parser.error(f"invalid prepared fixture: {error}")
        for case in dict.fromkeys(options.case):
            query = "file-" + f"{min(42, options.files_per_dir - 1):06d}"
            case_root = root
            if case == "deep":
                case_root = Path(folder) / "deep-root"
                query = "deep-leaf"
                expected = {path for path in deep_manifest if os.fsencode(query) in path}
            else:
                if case in {"all", "json"}:
                    query = ""
                elif case == "missing":
                    query = "no-such-entry"
                expected = {path for path in manifest if os.fsencode(query) in path}
                if case == "ignore-case":
                    query = query.upper()
            benchmark(
                commands(binary, compare, case_root, query, case, options.native),
                expected,
                case,
                options.runs,
            )


if __name__ == "__main__":
    main()
