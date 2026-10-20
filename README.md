# fslocate

Find paths using live filesystem metadata. No database, indexing daemon,
scheduled update, or file-content scanning. No runtime dependencies.
Written in Zig 0.17, using only the standard library.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fslocate --root ~/Documents invoice
./zig-out/bin/fslocate -i -r ~/Projects readme
./zig-out/bin/fslocate -0 -r . '.zig' | xargs -0 -r ls -l
sudo ./zig-out/bin/fslocate --backend native --root /home invoice
```

Install with `zig build -Doptimize=ReleaseSafe --prefix ~/.local`.
The build requires Zig 0.17.x. No packages need to be downloaded.

## Search behavior

`fslocate [OPTIONS] PATTERN [ROOT]` searches below ROOT, which defaults to the
current directory. Set it with `-r ROOT` / `--root ROOT`; the positional ROOT
form is also supported. Do not combine the two forms. To search the whole mounted
tree, use `--root /`.
PATTERN is a **literal substring of the full absolute path**, not a glob or
regular expression. Quote shell metacharacters; an empty pattern lists all
entries. The root itself is not included.

- Hidden entries, directories, symlinks, and special files are included.
- Directory symlinks beneath the root are listed but not traversed. An explicitly
  supplied root symlink is resolved once before searching.
- Mount points are traversed. Searching `/` includes mounted network and virtual
  filesystems, which can be slow; narrow the root when possible.
- Paths are unsorted and emitted in buffered batches as directories are scanned.
- `-i` / `--ignore-case` ignores ASCII case; other filename bytes are unchanged.
- `-r ROOT` / `--root ROOT` selects the search directory, before or after PATTERN.
- `-b MODE` / `--backend MODE` selects `auto`, `native`, or `walk` (details below).
- `-0` / `--null` preserves arbitrary Unix filenames for machine consumption.
  Default newline output is ambiguous for names containing newlines.
- `-j N` / `--threads N` sets the worker limit (1–256); default is up to 8 CPUs.
  If thread creation reaches a system limit, the search uses fewer workers. Try
  `-j 1` on spinning disks or when parallel I/O is slower. This controls the
  directory and Btrfs backends; XFS native queries currently run serially.
- `--` ends option parsing, e.g. `fslocate -r . -- '-report'`.
- `-h` / `--help` and `-V` / `--version` show help and version.
- `schema` prints the clispec 0.3 document as one JSON document and exits 0. `schema search` returns that document filtered to the search command. It needs no root and no pattern.
- `-o` / `--output` selects `auto` (default), `text`, or `json`. Text is one path per line on a terminal and when piped. `json` prints one document, `{"items":[{"path":"..."}],"total":N}`. A page that stops early sets `"truncated":true` and omits `total`.
- JSON is emitted in buffered batches during the search. A directory error
  preserves the available items, adds `"incomplete":true`, omits `total`, and
  exits 2. Output failures can leave a partial document; always check the exit
  status. JSON stderr contains one error object per line, with path and error
  details for directory failures.
- Valid UTF-8 paths appear directly in JSON's `path` field. For other filename
  bytes, `path` is display text and `path_bytes_base64` contains the exact
  absolute path bytes in standard base64. Use that field as the path identity
  when present. It accompanies `path` even with `--fields path`; `-0` text
  output also preserves the original bytes.
- `--limit N` and `--offset N` page matches in arrival order. Order is not stable
  across runs. Text stops at the last requested match; JSON checks one extra
  match to determine whether the page is truncated.
- `--fields` selects `path`, `path_bytes_base64`, or both in JSON. Explicitly
  selecting `path_bytes_base64` includes it for every item, including UTF-8 paths.
- `search` is an optional command word: `fslocate search PATTERN [ROOT]`.
  `fslocate search schema` searches for `schema`. In the shorthand form, use
  `--` before a pattern named `schema` or `search`, e.g. `fslocate -- schema`.
- Long options that take a value accept both `--root DIR` and `--root=DIR` forms.
  `schema` rejects search-only options and accepts an optional command filter.

Exit statuses: **0** for matches (including a page that starts past the last match), **1** for no matches, **2** for invalid input,
an output error, or an incomplete search. Unreadable directories are reported to
stderr while other directories continue. Closing a pipe early is handled cleanly.
Unprivileged searches respect your existing filesystem permissions. Native
metadata queries require `CAP_SYS_ADMIN`, usually obtained by running with
`sudo`. Privileged results can include names inaccessible to an ordinary user.

## Filesystems and privileges

| Filesystem | Native metadata backend | Without privileges |
| --- | --- | --- |
| Btrfs | `BTRFS_IOC_TREE_SEARCH_V2` reads directory-index records | Directory scan |
| XFS with parent pointers | `XFS_IOC_BULKSTAT` + `XFS_IOC_GETPARENTS_BY_HANDLE` | Directory scan |
| XFS without parent pointers | No supported native filename backend | Directory scan |
| ext2 / ext3 / ext4 | No equivalent mounted filename-search ioctl | Directory scan |
| tmpfs / ramfs / F2FS | No supported native filename-search API | Directory scan |
| FAT / exFAT / NTFS3 | No supported native filename-search API | Directory scan |
| OverlayFS | No supported native filename-search API; scan merged view | Directory scan |
| SquashFS / EROFS | No supported native filename-search API; scan read-only mount | Directory scan |
| OpenZFS | Object-to-path ioctl cannot return all hardlink names | Directory scan |
| NFS / SMB (CIFS) | No supported native filename-search API; scan client namespace | Directory scan |
| Other filesystems | No native backend currently implemented | Directory scan |

- **`auto`** (default): detect the root's filesystem, probe its native interface,
  and fall back to directory scanning if privileges or features are unavailable.
  It never prompts for elevation or invokes `sudo` itself.
- **`native`**: require the native API; fail with status 2 if unsupported or
  denied. Use `sudo fslocate --backend native -r ROOT PATTERN`.
- **`walk`**: always use directory metadata through ordinary OS enumeration,
  with or without privileges.

Native APIs are enabled on x86-64 and AArch64 Linux. Other Unix targets use
directory scans.
The binary uses Zig's standard library and direct Linux syscalls; no filesystem
development headers, runtime libraries, or external filesystem tools are needed
to build or search.

Btrfs queries each directory's inode and `DIR_INDEX` keys in 64 KiB batches.
This also handles nested subvolumes. In `auto`, nested unsupported mounts and
encrypted directories use directory enumeration; forced `native` reports an
error instead. Btrfs can defer directory changes in memory, so the native backend
calls `syncfs` once for each encountered Btrfs filesystem before querying it.
This flushes that filesystem's pending writes and can add noticeable latency.
Concurrent updates after that flush can still change the results.

XFS native search enumerates allocated inodes in batches and reads their parent
pointers, including every hardlink. It reconstructs paths under ROOT and keeps
only a temporary directory-path cache for the duration of the query. The mounted
filesystem must already have the parent-pointer feature enabled. Existing classic
XFS filesystems work through the directory backend without changing their format.
Native XFS searches the underlying filesystem's metadata: it does not enter
nested mounts and can return underlying names hidden by those mounts. Use `walk`
when you need the mounted namespace's exact view.
Inodes that disappear or are reused between bulkstat and parent queries are
skipped. Bulkstat requests use 64-bit extent counters so highly fragmented files
do not overflow the older counter format.

Ext4's directory HTree and XFS's older inode APIs do not provide the filename
records needed for an equivalent native search. They are supported through
directory enumeration; `native` fails explicitly instead of silently substituting
another backend. Raw block-device parsers are not implemented.

The additional filesystems share the buffered directory reader, instantiated
through compile-time backend types with filesystem-specific detection and
diagnostics. Both ordinary and elevated searches work; elevation does not add
a native filename index on these filesystems. OverlayFS searches its merged
view rather than the upper or lower layers. Network results depend on server
permissions, mount credentials, client caching, and filename encoding. Local
root privileges do not bypass server-side access controls.

OpenZFS's `ZFS_IOC_NEXT_OBJ` enumerates objects, but `ZFS_IOC_OBJ_TO_PATH` returns
only one pathname for an object. Its implementation follows a single stored
parent and looks up one directory entry. In the integration probe, a file with
34 hardlinks returned one alias outside the requested subtree, losing all 33
in-root names if used as a native search. There is no complete native ZFS
filename backend here: `auto`/`walk` enumerate all visible names, while `native`
reports unsupported. This preserves hardlinks and mounted child datasets without
adding a database. See the [OpenZFS ioctl implementation](https://github.com/openzfs/zfs/blob/master/module/zfs/zfs_ioctl.c)
and [object-to-path implementation](https://github.com/openzfs/zfs/blob/master/module/zfs/zfs_znode.c).

The dispatcher is a compile-time registry in `src/backends.zig`, using `inline
for` to select backend types by runtime filesystem magic. Backends expose
`supports`, `native`, `probe` (for native implementations), and `search`.
The directory walker specializes on its reader type; `@hasDecl` supplies the
Btrfs reader's shared synchronization state. There are no virtual methods or
runtime plugin dependencies.

This is a live search, not a snapshot. Concurrent renames, removals, permission
changes, or symlink replacements can change what is returned or traversed.
Results are not a security boundary; avoid using them for destructive operations
in a tree being modified by an untrusted process.

## Why it can be fast—and its limit

Filesystem metadata is already the source of truth. fslocate uses the OS's
buffered directory enumeration and kernel metadata caches, reuses directory
entry file types where available, and scans independent directories in parallel.
Only pending directory paths are queued in memory; matches are written in
bounded batches. Regular file contents are never opened.

The directory backend uses buffered `getdents64` calls on Linux. On filesystems
providing `d_type` (including Btrfs and ext4), learning an entry's type generally
does not require a separate `stat`. fslocate performs a non-following metadata
lookup only when a filesystem does not provide an entry type. Directory reads
use a 64 KiB buffer; workers reuse path and output buffers between directories.

A filesystem's index is **not a global substring index of all paths**, even
through a privileged ioctl. For
example, ext4's directory index is keyed by a name hash within a directory.
An arbitrary recursive substring query still requires enumerating entries:
work grows with the number of entries in the search tree. A persistent locate
index can outperform this scan; fslocate trades that index for current results
and zero index maintenance. Cold caches, HDDs, and remote filesystems can be slow.

Native access removes ordinary enumeration where supported; it is not guaranteed
to be faster than cached directory scans. Btrfs flush latency and XFS's per-inode
parent queries can dominate a search. All backends query filesystem metadata;
none maintain a persistent index.

References: [Zig 0.17](https://ziglang.org/documentation/0.17.0/),
[Linux directory enumeration](https://man7.org/linux/man-pages/man3/readdir.3.html),
[ext4 directory indexes](https://kernel.org/doc/html/latest/filesystems/ext4/directory.html),
[Btrfs custom ioctls](https://btrfs.readthedocs.io/en/latest/Custom-ioctls.html),
[XFS parent queries](https://man7.org/linux/man-pages/man2/ioctl_xfs_getparents.2.html),
[ext4 ioctl implementation](https://github.com/torvalds/linux/blob/master/fs/ext4/ioctl.c).

## Verify

Requires Zig 0.17.x; CLI tests also use Python 3's standard library.

```sh
zig fmt --check build.zig src
zig build test
zig build -Doptimize=ReleaseSafe
python3 -m unittest discover -s tests -v
```

CLI tests use `/dev/shm` when available to avoid disk-load interference.
Set `TMPDIR=/path/on/filesystem` to choose a different location. Streaming
fixtures still exceed 64 KiB, and long-path fixtures still exceed `PATH_MAX`.
Mounted-filesystem integration checks below retain their real filesystem images.

Privileged integration checks use disposable Btrfs, ext2 without directory-entry
file types, ext3, ext4, XFS with parent pointers, and classic XFS images. They
verify native/fallback parity, missing file-type metadata, pagination,
512 hardlinks, deep trees, moved directories, raw filename bytes, subtree scope,
live changes, output errors, privilege-denied behavior, Btrfs subvolumes, nested
Btrfs filesystems, and mixed Btrfs/ext4 mounts:

```sh
python3 tests/filesystems.py
```

This requires Zig 0.17.x, passwordless sudo, loop-mount support, `mkfs.btrfs`, `mkfs.ext2`,
`mkfs.ext3`, `mkfs.ext4`, and `mkfs.xfs`. Only newly created image files are
formatted. Temporary mounts
and images are removed afterward. The XFS parent-pointer fixture also compiles
and runs a kernel-backed stale-handle regression test. JSON byte identities and
text/JSON pagination are checked against the mounted fixtures.

Additional mounted-filesystem checks use an independent expected-path manifest
and verify ordinary/elevated searches, single/multiple workers, Unicode and
hidden names, literal and ASCII-case matching, NUL output, live changes,
read-only behavior, permissions, supported hardlinks, and explicit native-mode
diagnostics:

```sh
python3 tests/extra_filesystems.py --only tmpfs ramfs f2fs fat exfat ntfs3 overlay squashfs erofs
python3 tests/extra_filesystems.py --only zfs nfs smb
```

The first command requires Linux mount support for the named drivers plus
`mkfs.f2fs`, `mkfs.fat`, `mkfs.exfat`, `mkfs.ntfs`, `mksquashfs`, and `mkfs.erofs`.
NTFS is mounted explicitly with the kernel `ntfs3` driver. Both commands run as
an ordinary user with passwordless sudo. Missing tools or drivers fail the test;
they are not silently skipped. Mounts, images, exports, temporary servers, and
pools are removed afterward. Run the network and ZFS checks in a disposable
guest with `zfsutils-linux`, `libzfslinux-dev`, `gcc`, `nfs-kernel-server`,
`nfs-common`, `samba`, and `cifs-utils`. NFS must be running. SMB's test server
uses a private configuration and high loopback port. Its client mount requires
the kernel `nls_utf8` module; Ubuntu's minimal cloud image needs the matching
`linux-modules-extra-$(uname -r)` package. The test-only C probe wraps libzfs's
object-to-path ioctl; the fslocate binary remains entirely Zig with no libzfs
dependency.

Verified all 18 mounted configurations on 2026-10-13: local filesystems on
x86-64 Linux 7.2.9, and OpenZFS 2.2.2, NFS 4.2, and SMB 3.1.1 inside a libvirt
Ubuntu 24.04 guest on Linux 6.8.0-142. The ZFS check covers a file-backed pool,
34 hardlinks across the search boundary, and a mounted child dataset. OverlayFS
checks hidden lower entries and replacement directories. These are correctness
checks, not performance benchmarks or a claim about every filesystem version.

## Local benchmark

For the unprivileged directory backend on this machine's Btrfs filesystem,
using Zig 0.17.0 in ReleaseSafe mode:
100,000 files across 1,000 directories, 1,000 matching paths, warm metadata
cache, median of seven runs including process startup, stdout sent to `/dev/null`.
Each tool's output was checked against all expected matches before timing.

| Tool | Time |
| --- | ---: |
| fslocate walk, 8 threads | 3.60 ms |
| fslocate walk, 1 thread | 14.97 ms |
| fd, 8 threads | 11.92 ms |
| find | 28.33 ms |
| fslocate Btrfs native, 8 threads, including sudo and sync | 46.26 ms |

A syscall trace of fslocate's single-worker run showed 2,002 `getdents64` calls,
1,003 `openat` calls, and no `statx` or `newfstatat` calls. Directories are opened;
regular files are not.

These are synthetic local results, not a speed guarantee. Cold-cache performance
and other filesystems were not benchmarked. Reproduce on your own filesystem:

```sh
zig build -Doptimize=ReleaseSafe
python3 tests/benchmark.py
```

The benchmark temporarily creates 100,000 empty files inside the project and
removes them afterward. `find` and `fd` are compared when installed.
Fixture setup and correctness checks are excluded from timing. Runs rotate and
reverse tool order, and report median elapsed time, the elapsed-time range, and
search-process CPU time summed across threads. CPU time excludes descheduling
and I/O waits; elapsed time measures the latency you experience. Neither metric
is immune to CPU frequency changes, cache contention, or filesystem load.
CPU time includes waited child processes, but excludes separate filesystem
servers and kernel workers.

Workloads can be selected independently. `selective` is the default; `all`,
`json`, `ignore-case`, `missing`, and `deep` exercise other search paths. JSON is
compared only between fslocate builds. Every tool must match an independently
generated expected-path manifest before timing starts.

```sh
cp zig-out/bin/fslocate /tmp/fslocate-before
# Build the changed version, then compare on the same fixtures:
zig build -Doptimize=ReleaseSafe
python3 tests/benchmark.py --compare /tmp/fslocate-before --case selective all json ignore-case missing deep --runs 15
# Smaller fixtures for a quick benchmark smoke check:
python3 tests/benchmark.py --directories 20 --files-per-dir 10 --runs 3
# Memory-backed fixtures to separate disk load from warm metadata/CPU work:
python3 tests/benchmark.py --fixture-parent /dev/shm --case selective deep --runs 15
```

`--binary PATH` selects the candidate build. `--compare PATH` adds the previous
build and reports paired before/current CPU and elapsed-time ratios. On Linux,
`--cpus 2,3,4,5,6,7,8,9` pins the runner and its children to those CPUs; choose
CPUs allowed by your environment. Benchmarks run serially, outside correctness
test execution, to avoid competing with their own fixture and build work.
`--fixture-parent PATH` chooses the filesystem under test. Memory-backed runs
measure tmpfs and must not be presented as Btrfs, XFS, or storage performance.

Preparation can also run independently of builds and timing:

```sh
python3 tests/benchmark.py --prepare /dev/shm/fslocate-bench --case all deep
python3 tests/benchmark.py --fixture /dev/shm/fslocate-bench --case selective all json ignore-case missing deep --runs 15
```

`--prepare` requires a new directory and exits after generating data; it needs
no fslocate binary. `all deep` prepares both layouts, covering every workload.
`--fixture` reuses the data without creating or deleting entries. A small
`fixture.json` records layout version, dimensions, and prepared layouts.
Saved dimensions are used automatically; conflicting size flags are rejected.
Every reused layout is checked for missing, extra, or changed entry types before
timing, and each tool still verifies its results. Fixtures persist until you
remove them; `/dev/shm` fixtures disappear on reboot.

Linux traversal uses [openat2](https://man7.org/linux/man-pages/man2/openat2.2.html)
to resolve multiple components without following symlinks. Long paths are split
at component boundaries. Kernels or sandboxes without that interface retain the
component-by-component directory opener.

Add `--native` to the benchmark command to include privileged native search;
this needs passwordless sudo and a supported filesystem. The native timing above
includes privilege-launch and synchronization costs, with the first flush done
during the correctness check before timing.
