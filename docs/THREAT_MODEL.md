# Threat Model — fslocate

Last reviewed: 2026-11-04 (starter model; verify against code on each release).
Scope: the `fslocate` CLI binary only (`src/`, `build.zig`). No network
service, daemon, library API, or stored state exists. Out of scope: tests
(`tests/`) and CI workflows except where they document deployment surface.

fslocate is a local, read-only filesystem-metadata search tool. It takes
untrusted input from exactly one place — its own CLI arguments and the live
filesystem it searches — and writes only to stdout/stderr. It never opens,
reads, writes, or deletes file contents.

## Risk-ranked summary

| # | Risk | Why it matters | Where |
|---|------|----------------|-------|
| 1 | Privileged run (`sudo`/root) discloses path names the user cannot otherwise see | Born by design; names (not contents) of files outside the caller's permissions leak to stdout. Callers must treat output as sensitive. | `src/main.zig:294`, `README.md:72-73` |
| 2 | Symlink race (TOCTOU) during traversal if the tree is modified concurrently | Results are explicitly not a security boundary; a hostile process mutating the tree can change what is returned/traversed between checks. Mitigated by design for directory traversal (below), but the live-read model itself is the residual risk. | `README.md:154-156`, `src/walk.zig:58-69` |
| 3 | Denial of service via unbounded search (no quota, no timeout) | Searching `/` or a large/network filesystem is O(tree size) with up to 256 threads; no rate limit or result cap by default. Local-only, so impact is the caller's own resources. | `src/main.zig: threads 1-256` |
| 4 | Malformed filesystem metadata reaching the parser (kernel/fs bug or corrupt image) | Native ioctl record parsing trusts kernel-supplied length/kind/name fields; every field is bounds-checked, but a parser bug would be memory-unsafe in Zig safe mode it is a panic, not corruption. | `src/btrfs.zig:parseEntry`, `src/xfs.zig:parseParent`, `src/linux.zig:validName` |
| 5 | `syncfs` side effect on Btrfs native search | One `syncfs` per Btrfs filesystem flushes pending writes system-wide — a global, slow, observable side effect from a nominally read-only tool. | `src/btrfs.zig:State.prepare`, `src/linux.zig:syncFs` |
| 6 | Output injection into downstream consumers | Filenames are attacker-controlled bytes (newlines, non-UTF-8, terminal escapes none emitted — no color codes). Newline output is ambiguous for names containing `\n`; `-0`/JSON+base64 exist for machine use. | `src/common.zig:appendJsonString`, `README.md:33-34,49-53` |

No secrets, credentials, tokens, signing keys, or network endpoints exist
anywhere in the codebase. There is nothing to steal from the process itself;
the asset is the *output* (path names) and the *host's* filesystem metadata.

## Attack surface inventory

### Entry points (all local, all in `src/main.zig:parseOptions` / `searchOnce`)

| Entry point | Source | Notes |
|---|---|---|
| CLI args: `PATTERN`, `ROOT`, `--root`, `--backend`, `--threads`, `--output`, `--limit`, `--offset`, `--fields`, `-i`, `-0`, `schema`, `search` | `src/main.zig` (full parse) | Only untrusted input the process consumes. No stdin, no env vars, no config files, no network. |
| `schema [search\|schema]` subcommand | `src/main.zig:schema_*` | Prints a static JSON document; no filesystem access. |
| Root directory path (resolved once via `realPathFileAlloc`) | `src/main.zig:searchOnce` | Root symlink resolved once before searching; then opened with `openDirAbsolute`. |
| Filesystem metadata (names, types, inode numbers) | `src/directory.zig` (`getdents64` via std), `src/btrfs.zig` (`BTRFS_IOC_TREE_SEARCH_V2`), `src/xfs.zig` (`XFS_IOC_BULKSTAT` + `XFS_IOC_GETPARENTS_BY_HANDLE`) | Attacker-controllable if the tree is attacker-populated; validated by `validName` and per-record bounds checks. |
| stdout / stderr (including broken-pipe handling) | `src/common.zig:Collector`, `src/walk.zig:write` | Output is the product; see Risk 6. |
| Exit status + JSON error objects | `src/main.zig:run`, `src/common.zig:reportSearchError` | — |

No network listeners, RPC, message consumers, webhooks, upload parsers,
scheduled jobs, IPC, or admin/debug endpoints exist. No dependencies beyond
Zig's standard library (`build.zig` — no package fetches).

### Deployment surface

- Single static binary; no setuid/setgid bit, no capabilities set by the
  build, no systemd unit or service file in the repo.
- Privilege is obtained only by the caller explicitly running under `sudo`
  or root for `CAP_SYS_ADMIN` native ioctls (`src/main.zig:294-298`).
  The binary never elevates itself, prompts, or invokes `sudo`
  (`README.md:93`).
- Build: `zig build -Doptimize=ReleaseSafe` (`build.zig`). `ReleaseSafe`
  gives bounds checks / overflow checks; no binary hardening flags are set
  in `build.zig` (no PIE/strip/RELRO configuration — stock Zig defaults).

## Trust boundaries and data flow

```
[caller shell] --argv--> [fslocate process] --getdents64/ioctl--> [kernel VFS]
                              |                                      |
                              +--- stdout/stderr --> [caller / pipe]  +--- filesystem metadata
[hostile tree writer] --rename/symlink--> [live tree] --(read)--> [fslocate]
```

| Boundary | Crossing | Validation / auth point |
|---|---|---|
| Caller → process | argv (pattern, root, flags) | Strict allow-list parsing; unknown options/values rejected with exit 2 (`src/main.zig:parseOptions`). `--threads` clamped to 1–256. No shell interpolation (argv only). |
| Process → kernel/filesystem | directory enumeration, ioctls | `openat2` with `RESOLVE_NO_SYMLINKS \| NOFOLLOW` (`src/linux.zig:openDirNoSymlinks`); component-by-component `openDir(..., .follow_symlinks=false)` fallback (`src/walk.zig:openDirectory`). Root symlink resolved exactly once (`src/main.zig:searchOnce`). |
| Kernel → process | ioctl/dirent records | Length, kind, name, and cursor bounds checked before use; names rejected if empty, `.`/`..`, >255 bytes, or containing NUL/`/` (`src/linux.zig:validName`, `src/btrfs.zig:parseEntry`, `src/xfs.zig:parseParent`); cursor-progress checks prevent infinite loops (`src/xfs.zig:Parents.next`). |
| Filesystem → process (privilege transition) | native ioctls under root/`CAP_SYS_ADMIN` | Kernel enforces capability; process maps `EPERM`/`EACCES` to `NativePermissionDenied` and, in `auto`, falls back to unprivileged directory scan (`src/backends.zig:search`, `src/btrfs.zig:Reader.init`). |
| Tree writer → process | concurrent rename/symlink replacement | Directory opens are symlink-free per component, so a replaced component is not followed (tests: `test_intermediate_directory_replaced_by_symlink_is_not_followed`, `test_queued_directory_replaced_by_symlink_is_not_followed` in `tests/test_cli.py:134,182`). Residual: results are a live view, never a snapshot. |
| Process → caller | stdout (text / `-0` / JSON) | JSON string escaping incl. non-UTF-8 → `\u00XX` and `path_bytes_base64` lossless fallback (`src/common.zig:appendJsonString`, `appendPathFields`). Text mode: no escaping — documented ambiguity for newline filenames. |

Secrets flow: none. No credentials enter, live, or leave the process.
No environment variables are read.

## Assets and impact

| Asset | Where it lives | Impact if compromised |
|---|---|---|
| Path names under searched roots (incl. names the caller cannot stat) | stdout; caller's pipe/file | Information disclosure: directory structure, often-sensitive filenames (e.g. `id_rsa`, medical/legal names). This is the tool's intended output — impact lands on whoever stores it. |
| Availability / latency of the host filesystem | `syncfs` flush; full-tree scan; up to 256 threads of parallel `getdents64` | Local DoS / I/O stall, incl. on network mounts (NFS/SMB traversed in client namespace). Caller-scoped only. |
| Integrity of search results | in-memory only | A concurrent tree writer can add/remove/rename entries mid-search; results may omit or include entries that no longer exist. Never use for destructive automation (`README.md:156`). |
| The binary itself | `zig-out/bin/fslocate` | No signing, checksum, or provenance in-repo; supply-chain trust rests on the Zig toolchain and source review. |

## Threats per boundary (STRIDE)

**Caller → process (argv)**
- *Spoofing*: none — no identity, no auth concept.
- *Tampering*: a hostile wrapper script could pass surprising args; mitigated by strict parsing and the `--` escape hatch. Pattern is a literal substring, never a glob/regex, so no pattern-injection class exists.
- *Information disclosure*: `--help`/`schema` reveal only static text.
- *DoS*: `--threads 256` + search of `/` = self-inflicted resource use; caller-chosen, not remotely triggerable.
- *Elevation*: none — the process cannot gain privilege; `--backend native` only *uses* privilege the caller already has.

**Process ↔ kernel/filesystem (metadata in)**
- *Tampering*: corrupt/malicious filesystem metadata (crafted image, kernel bug) flows into `parseEntry`/`parseParent`. Bounds + `validName` checks exist; a parser error yields `CorruptMetadata` → exit 2, not memory corruption (ReleaseSafe).
- *Information disclosure*: native Btrfs/XFS queries bypass directory read permissions under root (intended); XFS native search can return names hidden by nested mounts (`README.md:130-131`).
- *DoS*: a filesystem returning endless records is bounded by cursor-progress checks; bulkstat records are capped at 256/batch with monotonic-inode check (`src/xfs.zig:search`).

**Tree writer → process (TOCTOU)**
- *Tampering / elevation*: symlink swap mid-traversal. Per-component no-follow opens mean the swap is detected as a different (non-directory) entry and not followed. Root is the exception: resolved once, deliberately.
- *Repudiation*: no audit log — a search leaves no trace of what was enumerated. Noted only; acceptable for a local read-only CLI.

**Process → caller (output)**
- *Tampering*: filenames with newlines/control bytes corrupt line-oriented consumers; mitigated by `-0` and JSON modes, not by text mode (documented).
- *Information disclosure*: terminal escape sequences are never emitted (no color codes), so output cannot drive a terminal; bytes ≥0x7f outside valid UTF-8 are escaped in JSON.

**Build → runtime**
- *Tampering*: no dependency pinning because there are no dependencies; risk concentrates in the Zig toolchain and in `ReleaseSafe` being the documented build mode. A non-safe build would lose the bounds-check safety net the parsers rely on.

## Mitigations mapping (existing controls → threats)

| Control | Covers | File |
|---|---|---|
| Strict argv allow-list, exit 2 on unknown/invalid | argv tampering, flag injection | `src/main.zig:parseOptions` |
| `openat2` `RESOLVE_NO_SYMLINKS`, component-wise no-follow opens | symlink traversal / TOCTOU escape from root | `src/linux.zig:openDirNoSymlinks`, `src/walk.zig:openDirectory` |
| Root symlink resolved once, then absolute open | consistent root identity | `src/main.zig:searchOnce` |
| `validName` + per-record length/kind/cursor checks | corrupt metadata → memory safety / path injection (`../` names cannot be synthesized) | `src/linux.zig`, `src/btrfs.zig`, `src/xfs.zig` |
| `EPERM`→`NativePermissionDenied`, `auto` fallback to directory scan | accidental privilege use; graceful degradation | `src/linux.zig:ioctl`, `src/backends.zig:search` |
| No self-elevation, no `sudo` invocation | privilege-transition surprise | `src/main.zig` (absence), `README.md:93` |
| JSON escaping + `path_bytes_base64` | output injection into JSON consumers | `src/common.zig:appendJsonString`, `appendPathFields` |
| No color/terminal codes | terminal escape injection | `src/main.zig` help text contract |
| `ReleaseSafe` documented build | bounds/overflow safety in parsers | `README.md`, `build.zig` |
| Bounded output batches (64 KiB), `--limit`/`--offset` paging | unbounded output memory | `src/common.zig:Collector`, `src/walk.zig:write` |

## Threats with no mitigation (ranked)

1. **Privileged disclosure by design** (Risk 1): no redaction/filtering of
   names returned under root. Accepted by design; documented in `README.md`.
2. **No search quota/timeout** (Risk 3): a runaway search on `/` or a slow
   network mount runs until the caller kills it. `--limit` caps *output*,
   not *traversal work*.
3. **`syncfs` global side effect** (Risk 5): Btrfs native search flushes the
   whole filesystem. Documented; no opt-out flag exists.
4. **No audit trail**: security-relevant events (privileged searches) are
   not logged anywhere. Noted only.
5. **No binary provenance**: no signing/checksum/reproducible-build
   statement in-repo. Noted only.

Single point of failure: the per-component no-follow open logic
(`src/walk.zig:openDirectory` + `src/linux.zig:openDirNoSymlinks`) carries
the entire symlink-escape threat class. Its tests are in
`tests/test_cli.py:134,182`.

## Abuse cases (documented scenarios, code path named)

- **Hostile authenticated user** — n/a: there is no authentication and no
  multi-user service; every run is the caller's own uid (or root if they
  chose `sudo`). The realistic abuse is a *caller* pointing the tool at
  trees they can enumerate but whose names they should not exfiltrate
  (e.g. `sudo fslocate -r /home pattern`), which is the documented design.
- **Resource exhaustion**: `fslocate -r / ''` (empty pattern matches
  everything) with `-j 256` on a network mount — unbounded traversal,
  `src/walk.zig:run` thread pool. Caller-triggered only.
- **Trust in client-side enforcement**: none — there is no enforcement
  boundary to bypass; results are advisory by design (`README.md:156`).
- **Downstream misuse**: `xargs`-style destructive automation on results
  from a concurrently modified tree — warned against in `README.md:156`.

## Response readiness (note only)

- No vulnerability-reporting channel is documented in-repo (no
  `SECURITY.md` existed before this pass — see `SECURITY.md` now).
- No audit logging exists; investigation of "what did a run enumerate"
  must rely on shell history / `sudo` logs outside this repo.
