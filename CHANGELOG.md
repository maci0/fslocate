# Changelog

All notable changes to fslocate are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Release policy (inferred from tag history, not yet stated in README/CONTRIBUTING):
> fslocate is `0.x`, so per SemVer §4 a minor bump signals new functionality or
> an intentionally unstable/changeable surface, and a patch bump signals
> backward-compatible fixes. Tags are `vX.Y.Z` and match the version in
> `src/main.zig`, `pyproject.toml`, and the `schema` clispec document.
> A release that adds a consumer-visible feature or extends a public output
> field must bump the minor; a release that only fixes defects must bump the
> patch; no consumer-visible break has been shipped at either level so far.
> Consumers should expect any `0.x` surface (CLI flags, `schema` output, JSON
> fields) to be able to change in a minor bump until `1.0.0`.

## [Unreleased]

## [0.4.0] - 2026-11-05

### Fixed

- JSON and text output-error reports now name the failing stream
  (`"path":"stdout"` in JSON, `fslocate: "stdout": …` in text) so a single
  error object is emitted per failure instead of being silently dropped or
  duplicated. Scripts parsing the old `{"message","hint"}`-only error JSON
  must tolerate the additional `path` field.
- A missing or inaccessible search root now reports
  `root does not exist or is not accessible` instead of the raw error name.
- Retry `fstatfs` on `EINTR` when detecting the root filesystem, so a
  signal-interrupted syscall no longer fails the search.
- Directory search falls back to fewer workers after a partial thread-spawn failure; failure to start the first worker is reported.

### Documentation

- Added this changelog and a `SECURITY.md` support policy
  (`0.4.x` only; `< 0.4.0` unsupported, fixes on latest release only).

## [0.3.0] - 2026-10-21

### Added

- `--fields` selects `path` and the new `path_bytes_base64` field; JSON
  `path` is display text for non-UTF-8 paths and `path_bytes_base64` carries
  the exact absolute path bytes (present when requested or when `path` is not
  valid UTF-8, including with `--fields path`).
- All long options accept `--flag=value` in addition to `--flag value`
  (e.g. `--root=DIR`, `--output=json`), and options that take no value now
  reject an attached `=value` with a usage error.
- `schema` rejects search-only options (`-i`, `-0`, `-r`, `-b`, `-j`,
  `--limit`, `--offset`, `--fields`) with a usage error instead of ignoring them.
- JSON output is streamed in buffered batches during the search; a directory
  error preserves emitted items, adds `"incomplete":true`, omits `total`,
  and exits 2; a page that stops early sets `"truncated":true` and omits `total`.

### Changed

- Legacy `0.2.0` JSON encoded non-UTF-8 path bytes as `\u00XX` in `path`;
  `0.3.0` emits display text in `path` plus lossless `path_bytes_base64`.
  Consumers using `path` as path identity for non-UTF-8 names must switch to
  `path_bytes_base64` (see README “Search behavior”).
- `--fields` error messages now read `use path or path_bytes_base64`
  instead of `--fields only accepts path`.
- `fslocate search PATTERN` treats `search` as a command word only once;
  a second `search` is the pattern, and `fslocate -- schema` is required to
  search for a pattern named `schema` or `search`.

### Fixed

- Search correctness and error handling across the directory, Btrfs, and
  XFS backends (metadata bounds checks, stale-handle skipping, parent-record
  validation, native-mode error reporting).

## [0.2.0] - 2026-10-21

Initial public release: live filesystem-metadata search with no database,
index, or daemon (`-i`, `-0`, `-r`, `-b auto|native|walk`, `-j`, `-o
auto|text|json`, `--limit`, `--offset`, `--fields path`, `schema`, exit
codes 0/1/2).

[Unreleased]: https://github.com/maci0/fslocate/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/maci0/fslocate/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/maci0/fslocate/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/maci0/fslocate/releases/tag/v0.2.0
