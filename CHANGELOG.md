# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
