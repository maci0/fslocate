# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.3.x (current) | Yes — fixes land on the latest release |
| < 0.3.0 | No |

## Reporting a vulnerability

No dedicated disclosure channel has been published for this project yet.
To report a security issue, open an issue or contact the repository
maintainer through the hosting platform's private reporting mechanism (if
available). Please include the fslocate version, the exact command line,
the filesystem type, and — for parser issues — the backend in use
(`--backend auto|native|walk`). Do not attach mounted filesystem images or
sensitive path listings from other systems.

## Security posture (what the code actually does)

- **Read-only by construction.** fslocate enumerates directory metadata
  only; it never opens, reads, writes, or deletes file contents. There is
  no database, index, daemon, network listener, or stored credential.
- **No privilege escalation.** The binary never elevates itself, prompts,
  or invokes `sudo`. Native Btrfs/XFS metadata queries require
  `CAP_SYS_ADMIN`, which the caller must already hold (e.g. via `sudo`);
  without it, `auto` mode falls back to unprivileged directory scanning.
  See `src/main.zig` and `src/backends.zig`.
- **Symlink-safe traversal.** Directories are opened component-by-component
  without following symlinks (`openat2` `RESOLVE_NO_SYMLINKS` on Linux,
  `src/linux.zig:openDirNoSymlinks`; fallback in `src/walk.zig`). The
  search root itself is resolved once before searching. Directory symlinks
  inside the root are listed but not traversed.
- **Privileged output is sensitive.** Run under root, results can include
  path names inaccessible to an ordinary user. Treat output accordingly.
- **Results are not a security boundary.** The search reads a live tree;
  concurrent modifications can change results, and output is unsorted.
  Do not feed results into destructive operations on a tree being
  modified by an untrusted process.
- **Metadata parsing is bounds-checked.** Native ioctl records are
  validated (length, kind, name rules via `src/linux.zig:validName`)
  before use; malformed records fail the search with exit status 2.
  Build with `-Doptimize=ReleaseSafe` (the documented build) so these
  checks are enforced.

See `docs/THREAT_MODEL.md` for the full threat model.
