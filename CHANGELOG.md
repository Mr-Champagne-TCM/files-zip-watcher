# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.2.0] — 2026-08-05

Provenance and integrity. Driven by a real incident the same day: two `files.zip` payloads landed
hours apart, and there was **no way to tell whether their contents differed** — the earlier archive
had been deleted and its files overwritten in place. Separately, an unattended run replaced 8 files
with nothing in the log but the number `8`.

### Added
- **Manifest sidecar per extraction.** Alongside `files-<stamp>.zip`, writes
  `files-<stamp>.sha256`: one line per extracted file **plus a line for the archive itself**.
  Deliberately plain `sha256sum` format, so `sha256sum -c files-<stamp>.sha256` verifies the whole
  payload with no bespoke tooling — and two extractions can be compared with `diff`.
- **Post-extract verification.** Each entry's decompressed bytes are SHA-256'd as they stream to
  disk; the file is then **read back off disk and hashed again**. A mismatch is logged as an ERROR
  and counted (`verify-failed N`).
  *This is not a re-check of the archive* — .NET validates each entry's CRC-32 during inflation, so
  a corrupt archive already throws. What this verifies is **the write**: truncation, a full disk, a
  kill mid-write, or something modifying the file immediately after us (AV quarantine, sync client,
  a second writer).
- **Overwrites logged by name**, not just counted — `~ mockup_gen.py` per replaced file.
- Archive is **retained even when `KeepZipAfterExtract: false`** if any file failed verification —
  it is then the only trustworthy copy.
- Config: `WriteManifest` (default `true`), `ManifestExtension` (default `.sha256`).
- Self-test grown 13 → 23 assertions covering the manifest, its format, hash-vs-disk agreement,
  by-name overwrite logging, and LF termination.

### Fixed
- **Sidecar was written CRLF, which broke `sha256sum -c` entirely** — GNU coreutils treats the
  trailing `\r` as part of the filename and reports *"No such file or directory"* for every line,
  defeating the whole reason for using a standard format. Now LF-terminated, with a regression test
  asserting zero CR bytes. Found on the first real-payload run, not by the unit test (PowerShell's
  `Get-Content` strips CRLF, hiding it).

### Verified on real data
Re-ran the actual 15-file 05F payload through it: `verify-failed 0`, all 15 hashes cross-check
against the project's own source manifest (`mockup_gen.py e6704117…`, `MU16 460cee36…`,
`MU13 0ddd58e3…`), `sha256sum -c` reports OK for every line, and diffing two separate extractions
of the same archive shows them byte-identical.

## [1.1.0] — 2026-08-05

Power/footprint pass and exact-name policy, per feedback after the v1.0.0 live install.

### Changed
- **Exact filename only.** `MatchPattern` (regex, matched dedupe variants) replaced by
  `WatchFileName` (default `files.zip`). Chrome's `files (1).zip` variants are no longer
  processed — rationale in README → *Why only `files.zip`*: a healthy watcher renames the archive
  within seconds, so a variant existing at all means the watcher was down.
- **Hot path is now O(1).** The safety-net check is a single `Test-Path` on one known path
  instead of enumerating and regex-filtering every `*.zip` in the folder.
- **`PollSeconds` default 5 → 300.** Detection is event-driven (`FileSystemWatcher` filtered to
  the single filename), so the poll is a pure safety net. Timer wakeups: 720/hr → 12/hr.
- **Single-instance mutex is now scoped per watch folder** (was one global name).

### Added
- Working-set trimming (`EmptyWorkingSet`) after startup, after each processed archive, and on
  each quiet wake.
- Orphan warning: `files (N).zip` present at startup logs a WARN naming the file and how to have
  it handled, instead of being silently ignored.
- Two more self-test assertions (13 total) covering the dedupe-variant refusal and its warning.

### Fixed
- **Global mutex locked out the self-test and manual `-Once` runs** whenever the installed
  service was live — the second instance exited with "Another instance is already running" even
  when pointed at a completely different folder. Now scoped by a hash of the watch folder path.

### Measured (steady-state idle, startup excluded)
| | Idle CPU | RAM | Wakes/hr |
|---|---|---|---|
| 1.0.0 | 0.33 % | 63 MB | 720 |
| 1.1.0 | 0.078 % | 18 MB | 12 |

≈22.5 CPU-seconds per 8-hour day.

## [1.0.0] — 2026-08-05

Initial release.

### Added
- `src/FilesZipWatcher.ps1` — long-running watcher for `files.zip` in `~/Downloads`.
  - Four-layer download-completion detection: no `.crdownload` sibling, stable byte size,
    exclusive-open success, valid zip parse.
  - `FileSystemWatcher` for latency + polling sweep for correctness (recovers archives that
    arrived while the watcher was stopped).
  - Timestamped rename to `files-<yyyy-MM-dd-HH-mm>.zip` with `-1`/`-2` collision suffixes.
  - Flat extraction into the watch folder (archive-internal folders preserved, no wrapper
    folder created), overwriting collisions.
  - Zip-slip protection: entries with absolute paths, drive letters, or `..` traversal are
    refused and logged.
  - Single-instance global mutex.
  - Daily log files with configurable retention.
  - `-Once` mode for manual catch-up runs and testing.
- `install.ps1` — registers a service-like Scheduled Task (AtLogon, no execution time limit,
  restart-on-failure, hidden). `-AtBoot` opt-in for an elevated SYSTEM/AtStartup install.
  `-Restart` to apply config changes.
- `uninstall.ps1` — stops and removes the task, kills stray watcher processes, optional
  `-PurgeLogs`.
- `config.json` — all tunables, `%ENVVAR%` expansion supported.
- `tests/Invoke-SelfTest.ps1` — sandboxed end-to-end test, 11 assertions, never touches the real
  Downloads folder. Includes a genuine zip-slip attack entry.
- `README.md`, `docs/DESIGN.md` — usage, configuration, troubleshooting, and the decision log.

### Notes
- **Timestamp format deviates from the original request.** `YYYY-DD-HH-MM` was specified but
  omits the month, which causes cross-month filename collisions and mis-sorting. Shipped as
  `yyyy-MM-dd-HH-mm` and exposed in `config.json`. See README → *Timestamp format*.
- Default install is **logon-scoped**, not boot-scoped, because it needs no admin rights and
  Chrome cannot download while logged out. See `docs/DESIGN.md` → decision 1.
