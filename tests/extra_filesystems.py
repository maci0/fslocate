"""Verify mounted namespaces on additional Linux filesystems.

Run as an ordinary user with passwordless sudo. Only fresh temporary images
are formatted. Network tests require a disposable guest with NFS/smbd installed;
their servers and exports are bound to loopback. See README.md for prerequisites.
"""

import argparse
import base64
import errno
import json
import os
import pwd
import socket
import subprocess
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path

BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/fslocate"
FILESYSTEMS = {
    "tmpfs": ("tmpfs", "1021994"),
    "ramfs": ("ramfs", "858458f6"),
    "f2fs": ("F2FS", "f2f52010"),
    "fat": ("FAT", "4d44"),
    "exfat": ("exFAT", "2011bab0"),
    "ntfs3": ("NTFS3", "7366746e"),
    "overlay": ("OverlayFS", "794c7630"),
    "squashfs": ("SquashFS", "73717368"),
    "erofs": ("EROFS", "e0f5e1e2"),
    "zfs": ("OpenZFS", "2fc12fc1"),
    "nfs": ("NFS", "6969"),
    "smb": ("SMB/CIFS", "fe534d42"),
}


def command(args):
    result = subprocess.run(args, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(
            f"{args!r}: exit {result.returncode}; "
            + result.stderr.decode(errors="replace")
            + result.stdout.decode(errors="replace")
        )
    return result


def sudo(*args):
    return command(["sudo", "-n", *args])


def own(path):
    sudo("chown", f"{os.getuid()}:{os.getgid()}", path)


def mounted(stack, source, target, kind, options=None):
    args = ["mount", "-t", kind]
    if options:
        args += ["-o", options]
    sudo(*args, source, target)
    stack.callback(sudo, "umount", target)


def image(work, size):
    path = work / "filesystem.img"
    with path.open("wb") as handle:
        handle.truncate(size * 1024 * 1024)
    return path


def fixture(root, posix, hardlinks=False):
    """Return an independent manifest; never derive expectations from fslocate."""
    root.mkdir()
    expected = set()

    def add(relative, kind="file", target=None):
        relative = os.fsencode(relative)
        path = os.fsencode(root) + b"/" + relative
        if kind == "dir":
            os.mkdir(path)
        elif kind == "link":
            os.link(os.fsencode(root) + b"/" + os.fsencode(target), path)
        elif kind == "symlink":
            os.symlink(os.fsencode(target), path)
        elif kind == "fifo":
            os.mkfifo(path)
        else:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            os.close(fd)
        expected.add(relative)

    add("nested", "dir")
    for name in ("README.md", ".hidden", "space name", "[literal]", "café-文件"):
        add("nested/" + name)
    add("many", "dir")
    for i in range(800):
        add(f"many/entry-{i:04d}-" + "x" * 120)
    deep = ""
    for _ in range(20):
        deep += "deep/"
        add(deep.rstrip("/"), "dir")
    add(deep + "leaf")
    if posix or hardlinks:
        for i in range(32):
            add(f"README-alias-{i:02d}", "link", "nested/README.md")
    if posix:
        add("loop", "symlink", root)
        add("broken", "symlink", root / "absent")
        add("fifo", "fifo")
        add(b"raw-\xff", "dir")
        add(b"raw-\xff/file-\xfe")
        add("line\nbreak")
    return expected


def search(root, pattern=b"", backend="auto", privileged=False, threads=8, ignore_case=False):
    args = [BINARY, "-0", "-r", root, "-b", backend, "-j", str(threads)]
    if ignore_case:
        args += ["-i"]
    args += ["--", pattern]
    if privileged:
        args = ["sudo", "-n", *args]
    return subprocess.run(args, capture_output=True, timeout=45)


def check(result, expected):
    assert result.returncode == (0 if expected else 1), result.stderr
    assert result.stderr == b"", result.stderr
    assert not result.stdout or result.stdout.endswith(b"\0")
    entries = result.stdout.split(b"\0")[:-1] if result.stdout else []
    assert len(entries) == len(set(entries)), "duplicate paths"
    actual = set(entries)
    assert actual == expected, (
        "missing",
        expected - actual,
        "extra",
        actual - expected,
    )


def verify(kind, root, manifest, writable, posix):
    label, magic = FILESYSTEMS[kind]
    actual_magic = command(["stat", "-f", "-c", "%t", root]).stdout.strip().decode()
    assert actual_magic == magic, (kind, "wrong filesystem/driver", actual_magic)
    prefix = os.fsencode(root) + b"/"
    expected = {prefix + relative for relative in manifest}
    for backend, privileged, threads in (
        ("walk", False, 1),
        ("auto", False, 8),
        ("walk", True, 8),
        ("auto", True, 1),
    ):
        for pattern in (
            b"",
            b"README",
            b"nested",
            b"[literal]",
            b"leaf",
            b"no-such-filename",
        ):
            check(
                search(root, pattern, backend, privileged, threads),
                {path for path in expected if pattern in path},
            )
        check(
            search(root, b"readme", backend, privileged, threads, True),
            {path for path in expected if b"readme" in path.lower()},
        )
    for privileged in (False, True):
        args = [BINARY, "-o", "json", "-r", root, ""]
        result = command(["sudo", "-n", *args] if privileged else args)
        document = json.loads(result.stdout)
        identities = [
            base64.b64decode(item["path_bytes_base64"], validate=True)
            if "path_bytes_base64" in item
            else item["path"].encode("utf-8")
            for item in document["items"]
        ]
        assert len(identities) == len(set(identities)) and set(identities) == expected, kind
        assert document["total"] == len(expected), document
    unsupported = search(root, backend="native", privileged=True)
    assert unsupported.returncode == 2 and label.encode() in unsupported.stderr, unsupported.stderr
    assert b"NativeUnsupported" in unsupported.stderr and not unsupported.stdout
    if writable:
        old, new = root / "fresh-old", root / "fresh-new"
        old.touch()
        check(search(root, b"fresh-"), {os.fsencode(old)})
        old.rename(new)
        check(search(root, b"fresh-", privileged=True), {os.fsencode(new)})
        new.unlink()
        check(search(root, b"fresh-"), set())
    else:
        try:
            (root / "must-be-readonly").touch()
        except OSError as error:
            assert error.errno == errno.EROFS, error
        else:
            raise AssertionError("image mount is not read-only")
    if writable and posix:
        locked = root / "locked"
        locked.mkdir()
        (locked / "secret").touch()
        locked.chmod(0)
        try:
            result = search(root, b"secret")
            assert result.returncode == 2 and b"locked" in result.stderr, result.stderr
            assert not result.stdout
            check(
                search(root, b"secret", privileged=True),
                {os.fsencode(locked / "secret")},
            )
        finally:
            locked.chmod(0o700)
    print(
        f"{kind}: {len(expected)} paths; user/root, 1/8 workers, hardlinks where supported, "
        "namespace, live/read-only behavior OK",
        flush=True,
    )


def run(kind):
    posix = kind not in {"fat", "exfat", "ntfs3", "smb"}
    writable = kind not in {"squashfs", "erofs"}
    with (
        tempfile.TemporaryDirectory(prefix=f"fslocate-{kind}-") as temporary,
        ExitStack() as stack,
    ):
        work = Path(temporary)
        mount = work / "mnt"
        mount.mkdir()
        root = mount / "search-root"
        manifest = None
        if kind in {"tmpfs", "ramfs"}:
            mounted(stack, kind, mount, kind, "size=64m" if kind == "tmpfs" else None)
            own(mount)
        elif kind in {"f2fs", "fat", "exfat", "ntfs3"}:
            formatting = {
                "f2fs": (512, ["mkfs.f2fs", "-f"], "f2fs"),
                "fat": (128, ["mkfs.fat", "-F", "32"], "vfat"),
                "exfat": (128, ["mkfs.exfat"], "exfat"),
                "ntfs3": (128, ["mkfs.ntfs", "-Q", "-F"], "ntfs3"),
            }
            size, mkfs, driver = formatting[kind]
            disk = image(work, size)
            command([*mkfs, disk])
            options = "loop"
            if not posix:
                options += f",uid={os.getuid()},gid={os.getgid()},umask=022"
                if kind == "fat":
                    options += ",iocharset=utf8"
            mounted(stack, disk, mount, driver, options)
            if posix:
                own(mount)
        elif kind == "overlay":
            stack.callback(sudo, "chown", "-R", f"{os.getuid()}:{os.getgid()}", work)
            lower, upper, layer_work = (work / name for name in ("lower", "upper", "work"))
            for path in (lower, upper, layer_work):
                path.mkdir()
            manifest = fixture(lower / "search-root", True)
            (lower / "search-root/whiteout").touch()
            (lower / "search-root/opaque").mkdir()
            (lower / "search-root/opaque/hidden").touch()
            mounted(
                stack,
                "overlay",
                mount,
                "overlay",
                f"lowerdir={lower},upperdir={upper},workdir={layer_work}",
            )
            (root / "whiteout").unlink()
            (root / "opaque/hidden").unlink()
            (root / "opaque").rmdir()
            (root / "opaque").mkdir()
            (root / "opaque/visible").touch()
            (root / "nested/README.md").write_text("upper copy")
            manifest.update({b"opaque", b"opaque/visible"})
        elif kind in {"squashfs", "erofs"}:
            stage = work / "stage"
            stage.mkdir()
            manifest = fixture(stage / "search-root", True)
            disk = work / "readonly.img"
            if kind == "squashfs":
                command(
                    [
                        "mksquashfs",
                        stage,
                        disk,
                        "-noappend",
                        "-quiet",
                        "-processors",
                        "2",
                    ]
                )
            else:
                command(["mkfs.erofs", disk, stage])
            mounted(stack, disk, mount, kind, "loop,ro")
        elif kind == "zfs":
            pool = "fslocate_" + work.name.rsplit("-", 1)[-1]
            sudo("zpool", "create", "-O", f"mountpoint={mount}", pool, image(work, 512))
            stack.callback(sudo, "zpool", "destroy", pool)
            own(mount)
            manifest = fixture(root, True)
            (mount / "outside").mkdir()
            os.link(root / "nested/README.md", mount / "outside/alias")
            child = root / "child-dataset"
            sudo("zfs", "create", "-o", f"mountpoint={child}", pool + "/child")
            own(child)
            (child / "README-child").touch()
            manifest.update({b"child-dataset", b"child-dataset/README-child"})
            probe = work / "zfs_native_api"
            command(
                [
                    "gcc",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-D_GNU_SOURCE",
                    "-I/usr/include/libzfs",
                    "-I/usr/include/libspl",
                    Path(__file__).with_name("zfs_native_api.c"),
                    "-lzfs",
                    "-o",
                    probe,
                ]
            )
            sudo("zpool", "sync", pool)
            result = sudo(probe, pool, pool, root / "nested/README.md").stdout.splitlines()
            assert len(result) == 2 and result[0] == b"34", result
            aliases = {os.fsencode(root) + b"/" + name for name in manifest if b"README" in name}
            aliases.add(os.fsencode(mount / "outside/alias"))
            assert result[1] in aliases, result
            print(
                f"zfs native API: 34 hardlinks, OBJ_TO_PATH returned one alias: {result[1]!r}",
                flush=True,
            )
        elif kind == "nfs":
            source = work / "source"
            source.mkdir()
            manifest = fixture(source / "search-root", True)
            export = f"127.0.0.1:{source}"
            sudo(
                "exportfs",
                "-i",
                "-o",
                "rw,sync,no_subtree_check,no_root_squash",
                export,
            )
            stack.callback(sudo, "exportfs", "-u", export)
            mounted(stack, export, mount, "nfs", "vers=4.2,proto=tcp,actimeo=0")
        elif kind == "smb":
            stack.callback(sudo, "chown", "-R", f"{os.getuid()}:{os.getgid()}", work)
            source = work / "source"
            source.mkdir()
            manifest = fixture(source / "search-root", False)
            # One task-specific server, using a high port and private state directories.
            config = work / "smb.conf"
            port = 20000 + os.getpid() % 20000
            user = pwd.getpwuid(os.getuid()).pw_name
            sudo("install", "-d", "-m", "0700", work / "private", work / "ncalrpc")
            config.write_text(f"""[global]
interfaces = 127.0.0.1
bind interfaces only = yes
smb ports = {port}
map to guest = Bad User
guest account = {user}
pid directory = {work}
lock directory = {work}
state directory = {work}
cache directory = {work}
private dir = {work}/private
ncalrpc dir = {work}/ncalrpc
log file = {work}/smb.log
[files]
path = {source}
guest ok = yes
read only = no
force user = {user}
""")
            server = subprocess.Popen(
                [
                    "sudo",
                    "-n",
                    "smbd",
                    "--daemon",
                    "--foreground",
                    "--no-process-group",
                    "-s",
                    config,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )

            def stop_server():
                if server.poll() is None:
                    # The foreground PID belongs only to this invocation.
                    sudo("kill", "-TERM", str(server.pid))
                server.wait(timeout=15)

            stack.callback(stop_server)
            for _ in range(50):
                if server.poll() is not None:
                    log = work / "smb.log"
                    raise RuntimeError(
                        f"smbd exited {server.returncode}: "
                        + server.stderr.read().decode()
                        + (log.read_text() if log.exists() else "")
                    )
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("temporary SMB server did not become ready")
            mounted(
                stack,
                "//127.0.0.1/files",
                mount,
                "cifs",
                f"guest,port={port},vers=3.1.1,uid={os.getuid()},gid={os.getgid()},iocharset=utf8,cache=none,actimeo=0",
            )
        if manifest is None:
            manifest = fixture(root, posix, hardlinks=kind == "ntfs3")
        verify(kind, root, manifest, writable, posix)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", nargs="+", choices=FILESYSTEMS, default=list(FILESYSTEMS))
    args = parser.parse_args()
    assert os.geteuid() != 0, "run as an ordinary user with passwordless sudo"
    sudo("true")
    for filesystem in args.only:
        run(filesystem)
