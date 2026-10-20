"""Check native/fallback parity on disposable mounted filesystem images.

Requires passwordless sudo, loop mounts, mkfs.btrfs, mkfs.ext2/3/4, and mkfs.xfs.
Only images created by this script are formatted. No existing device is touched.
"""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/fslocate"


def command(args):
    try:
        return subprocess.run(args, capture_output=True, timeout=60, check=True)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr.decode(errors="replace")) from error


def search(root, pattern=b"", backend="auto", privileged=False, threads=8):
    args = [BINARY, "-0", "-j", str(threads), "--root", root, "--backend", backend, "--", pattern]
    if privileged:
        args = ["sudo", "-n", *args]
    return subprocess.run(args, capture_output=True, timeout=30)


def paths(result):
    assert result.returncode == 0, result.stderr
    assert result.stderr == b"", result.stderr
    assert not result.stdout or result.stdout.endswith(b"\0"), result.stdout
    entries = result.stdout.split(b"\0")[:-1] if result.stdout else []
    assert len(entries) == len(set(entries)), "duplicate paths"
    return set(entries)


command(["sudo", "-n", "true"])
for filesystem, native, size, mkfs in (
    ("btrfs", True, 256, ["mkfs.btrfs", "-q"]),
    ("ext2-no-filetype", False, 64, ["mkfs.ext2", "-q", "-O", "^filetype"]),
    ("ext3", False, 96, ["mkfs.ext3", "-q"]),
    ("ext4", False, 96, ["mkfs.ext4", "-q"]),
    ("xfs-parent", True, 512, ["mkfs.xfs", "-q", "-n", "parent=1"]),
    ("xfs-classic", False, 512, ["mkfs.xfs", "-q", "-n", "parent=0"]),
):
    work = Path(tempfile.mkdtemp(prefix="fslocate-fs-test-"))
    mounted = False
    nested_mounts = []
    try:
        image = work / "filesystem.img"
        with image.open("wb") as handle:
            handle.truncate(size * 1024 * 1024)
        mount = work / "mnt"
        mount.mkdir()
        command([*mkfs, image])
        command(["sudo", "-n", "mount", "-o", "loop", image, mount])
        mounted = True
        command(["sudo", "-n", "chown", f"{os.getuid()}:{os.getgid()}", mount])
        root = mount / "search-root"
        root.mkdir()
        (mount / "excluded").mkdir()
        (mount / "excluded/README-outside").touch()
        nested = root / "nested"
        nested.mkdir()
        for name in ("README.md", ".hidden", "line\nbreak", "[literal]*"):
            (nested / name).touch()
        (root / "loop").symlink_to(root, target_is_directory=True)
        (root / "broken").symlink_to(root / "absent")
        os.mkfifo(root / "fifo")
        raw_dir = os.fsencode(root) + b"/raw-\xff"
        os.mkdir(raw_dir)
        fd = os.open(raw_dir + b"/file-\xfe", os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
        many = root / "many"
        many.mkdir()
        for i in range(3000):
            (many / (f"entry-{i:04d}-" + "x" * 150)).touch()
        for i in range(512):
            os.link(nested / "README.md", root / f"README-link-{i:04d}")
        os.link(nested / "README.md", mount / "excluded/README-hardlink")
        deep = root
        for _ in range(80):
            deep /= "deep"
            deep.mkdir()
        (deep / "leaf").touch()
        early = root / "early"
        early.mkdir()
        (early / "moved-file").touch()
        late = root / "late"
        late.mkdir()
        early.rename(late / "renamed")

        if filesystem == "btrfs":
            subvolume = root / "subvolume"
            command(["sudo", "-n", "btrfs", "subvolume", "create", subvolume])
            command(["sudo", "-n", "chown", f"{os.getuid()}:{os.getgid()}", subvolume])
            (subvolume / "README-subvolume").touch()
            second = work / "second.img"
            with second.open("wb") as handle:
                handle.truncate(256 * 1024 * 1024)
            command(["mkfs.btrfs", "-q", second])
            second_mount = root / "second-filesystem"
            second_mount.mkdir()
            command(["sudo", "-n", "mount", "-o", "loop", second, second_mount])
            nested_mounts.append(second_mount)
            command(["sudo", "-n", "chown", f"{os.getuid()}:{os.getgid()}", second_mount])
            (second_mount / "README-second-filesystem").touch()

        expected = paths(search(root, backend="walk"))
        for pattern in (b"", b"README", b"nested", b"\xff", b"[literal]*", b"leaf", b"line\nbreak"):
            baseline = paths(search(root, pattern, "walk"))
            assert paths(search(root, pattern)) == baseline
            assert paths(search(root, pattern, privileged=True)) == baseline
            result = search(root, pattern, "native", privileged=True)
            if native:
                assert paths(result) == baseline, (filesystem, pattern)
            else:
                assert result.returncode == 2 and b"NativeUnsupported" in result.stderr, result.stderr

        assert all(os.fsencode(mount / "excluded") not in path for path in expected)
        for mode in ("walk", "auto", "native") if native else ("walk", "auto"):
            result = command(["sudo", "-n", BINARY, "-o", "json", "-b", mode, "-r", root, ""])
            document = json.loads(result.stdout)
            actual = {base64.b64decode(item["path_bytes_base64"], validate=True)
                      if "path_bytes_base64" in item else item["path"].encode("utf-8")
                      for item in document["items"]}
            assert actual == expected and document["total"] == len(expected), (filesystem, mode)
            for output in ("text", "json"):
                result = command(["sudo", "-n", BINARY, "-0", "-o", output, "-b", mode,
                                  "--limit", "3", "-r", root, "README"])
                if output == "json":
                    page = json.loads(result.stdout)
                    assert len(page["items"]) == 3 and page["truncated"] and "total" not in page
                else:
                    assert len(result.stdout.split(b"\0")[:-1]) == 3, (filesystem, mode, result.stdout)
        if native and os.geteuid() != 0:
            result = search(root, "README", "native")
            assert result.returncode == 2 and b"CAP_SYS_ADMIN" in result.stderr, result.stderr

        if filesystem == "xfs-parent":
            probe_binary = work / "stale-handle-test"
            command(["zig", "test", BINARY.parents[2] / "src/xfs.zig", "--test-filter", "XFS stale",
                     "--test-no-exec", "-femit-bin=" + str(probe_binary)])
            result = subprocess.run(["sudo", "-n", probe_binary], cwd=mount,
                                    capture_output=True, timeout=30)
            assert result.returncode == 0, result.stderr
            assert b"SKIP" not in result.stderr, result.stderr

        fresh = root / "fresh-old"
        fresh.touch()
        mode = "native" if native else "auto"
        assert paths(search(root, "fresh-", mode, True)) == {os.fsencode(fresh)}
        new = root / "fresh-new"
        fresh.rename(new)
        assert paths(search(root, "fresh-", mode, True)) == {os.fsencode(new)}
        new.unlink()
        assert search(root, "fresh-", mode, True).returncode == 1

        if native:
            with open("/dev/full", "wb") as full:
                result = subprocess.run(["sudo", "-n", BINARY, "-b", "native", "-r", root, "README"],
                                        stdout=full, stderr=subprocess.PIPE, timeout=30)
            assert result.returncode == 2, result.stderr
            with subprocess.Popen(["sudo", "-n", BINARY, "-b", "native", "-r", root, ""],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                process.stdout.close()
                assert process.wait(timeout=30) == 0, process.stderr.read()

        if filesystem == "btrfs":
            ext_image = work / "nested-ext.img"
            with ext_image.open("wb") as handle:
                handle.truncate(96 * 1024 * 1024)
            command(["mkfs.ext4", "-q", ext_image])
            ext_mount = root / "ext-mount"
            ext_mount.mkdir()
            command(["sudo", "-n", "mount", "-o", "loop", ext_image, ext_mount])
            nested_mounts.append(ext_mount)
            command(["sudo", "-n", "chown", f"{os.getuid()}:{os.getgid()}", ext_mount])
            (ext_mount / "README-ext-mount").touch()
            assert paths(search(root, "README", privileged=True)) == paths(search(root, "README", "walk", True))
            unprivileged = search(root, "README")
            assert unprivileged.returncode == 2 and b"lost+found" in unprivileged.stderr
            assert b"README-ext-mount" in unprivileged.stdout
            result = search(root, "README", "native", True, threads=1)
            assert result.returncode == 2 and b"NativeUnsupported" in result.stderr, result.stderr
            native_expected = {path for path in paths(search(root, "README", "walk", True))
                               if not path.startswith(os.fsencode(ext_mount) + b"/")}
            assert set(result.stdout.split(b"\0")[:-1]) == native_expected, result.stdout

        print(f"{filesystem}: native={native}; {len(expected)} paths; parity, paging, hardlinks, root scope, live changes OK", flush=True)
    finally:
        for nested_mount in reversed(nested_mounts):
            command(["sudo", "-n", "umount", nested_mount])
        if mounted:
            command(["sudo", "-n", "umount", work / "mnt"])
        shutil.rmtree(work)
