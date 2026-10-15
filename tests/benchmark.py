"""Compare live searches on 100,000 generated files; remove the tree afterward."""

from pathlib import Path
import argparse
import shutil
import statistics
import subprocess
import tempfile
import time


project = Path(__file__).resolve().parents[1]
binary = project / "zig-out/bin/fslocate"
query = "file-000042"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--native", action="store_true", help="also time sudo native search (requires passwordless sudo)")
options = parser.parse_args()

with tempfile.TemporaryDirectory(prefix=".fslocate-bench-", dir=project) as folder:
    root = Path(folder)
    for d in range(1000):
        directory = root / f"dir-{d:04d}"
        directory.mkdir()
        for f in range(100):
            (directory / f"file-{f:06d}").touch()

    commands = {
        "fslocate walk (1 thread)": [binary, "-b", "walk", "-j", "1", "-r", root, query],
        "fslocate walk (8 threads)": [binary, "-b", "walk", "-j", "8", "-r", root, query],
    }
    if options.native:
        commands["fslocate native (8 threads, including sudo)"] = [
            "sudo", "-n", binary, "-b", "native", "-j", "8", "-r", root, query,
        ]
    if shutil.which("find"):
        commands["find"] = ["find", root, "-path", "*" + query + "*"]
    if shutil.which("fd"):
        commands["fd (8 threads)"] = [
            "fd", "-F", "-p", "-H", "-I", "--color", "never", "-j", "8", query, root,
        ]

    expected = {str(root / f"dir-{d:04d}" / query) for d in range(1000)}
    timings = {name: [] for name in commands}
    for name, command in commands.items():
        result = subprocess.run(command, capture_output=True, timeout=30, check=True)
        paths = result.stdout.decode().splitlines()
        assert set(paths) == expected and len(paths) == len(expected), name

    for _ in range(7):
        for name, command in commands.items():
            start = time.perf_counter()
            subprocess.run(command, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=30, check=True)
            timings[name].append((time.perf_counter() - start) * 1000)

    print("100,000 files; 1,000 directories; 1,000 matches; warm cache; median of 7 runs")
    for name, measurements in timings.items():
        print(f"{name}: {statistics.median(measurements):.2f} ms")
