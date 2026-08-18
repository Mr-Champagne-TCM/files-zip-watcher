# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.4.0] — 2026-08-18

Silence. v1.3.0 fixed the watcher dying; this fixes **why it kept dying** — and closes a
single-instance hole that v1.3.0's own fix exposed.

### The window nobody asked for
The task ran with `LogonType: Interactive` and `-WindowStyle Hidden`. On Windows 11 that switch
**does not work**: it governs PowerShell's own legacy console, but the default console host is
Windows Terminal — a separate process that opens its own visible window and renders the output.
So every launch popped a terminal showing the log.

Closing that window sends `CTRL_CLOSE_EVENT`, and the process exits with **`0xC000013A`** — the
exact code from the 2026-08-14 outage. That window was almost certainly the original cause: close
it once, and with a logon-only trigger the watcher was gone until the next sign-in. v1.3.0's
15-minute self-heal then turned a silent one-shot failure into a window that reappeared every few
minutes, which is how it was finally noticed.

### Added
- **Windowless by default.** The task now registers with `LogonType: S4U` ("run whether user is
  logged on or not"), running non-interactively in session 0 as the same user. No window can
  exist, so no window can be closed. `%USERPROFILE%` still resolves correctly — unlike
  `-AtBoot`/SYSTEM, which does not. Registering S4U **requires an elevated shell**; if that
  fails, `install.ps1` falls back to Interactive and says loudly what you are getting.
- **`watch-live.ps1` — the live view, made safe.** Attaches to the running watcher's log as a
  **read-only** follower: no lock, no writes, nothing the watcher can notice. Close it whenever
  you like. If no watcher is running it instead runs one in the foreground, and says so. Follows
  the log across midnight rollover.
- `-Live` switch on the watcher script, which `watch-live.ps1` wraps.
- `install.ps1 -Interactive` to deliberately opt back into the desktop/windowed task, with a
  warning explaining the hazard.

### Fixed
- **Single-instance guard was per-session, so two watchers could run at once.** The guard took a
  `Global\` named mutex and silently fell back to `Local\` on failure — and creating a `Global\`
  object needs `SeCreateGlobalPrivilege`, which a non-elevated token lacks. Both sides therefore
  took the **per-session** `Local\` name. Once the watcher moved to session 0 and a live viewer
  ran on the desktop in session 1, each concluded it was alone: **two watchers on one folder,
  able to double-process an archive.** Caught on the first real S4U run, by the viewer announcing
  "no background watcher was running" while one plainly was.
  Replaced with an **exclusively-opened lock file** — machine-wide, needs no privilege, and
  released by the OS on process death, so there is no stale lock to clean up.
- **`install.ps1` failed opaquely when replacing an elevated task.** It stopped the task, then
  `Unregister-ScheduledTask` threw a raw CIM "Access is denied" — leaving no watcher running and
  no clue why. Now caught, with the reason and the one command needed to recover.

### Note for anyone diagnosing this later
A session-0 process reports `CommandLine` as `$null` to a non-elevated caller, so the obvious
`Win32_Process | Where CommandLine -like '*FilesZipWatcher*'` liveness check returns **zero
matches while the watcher is running fine**. Use the task state, a session-0 `powershell.exe`,
and heartbeat freshness instead.

### Self-test
31 → **38 assertions**, adding: the viewer attaches instead of refusing, announces it is safe to
close, streams real log content, and — the guarantee that matters — **killing the viewer leaves
the watcher both running and still able to process a zip.**

## [1.3.0] — 2026-08-17

Survivability. Driven by a real three-day outage: the watcher was killed mid-session on 08-14
(exit `0xC000013A`, an external console-control close — **not** a crash; the script's own error
path never ran) and **stayed dead until 08-17**, silently missing a download. The machine never
rebooted in between, and the task's only trigger was `AtLogOn` — so nothing ever restarted it.
Task Scheduler's configured `RestartOnFailure` did not apply either: Windows recorded the task as
*completed with an error code*, not *failed to start*.

Diagnosis was also harder than it should have been. `Microsoft-Windows-TaskScheduler/Operational`
was disabled, and the watcher's log had been silent since the moment it came up — so a **dead**
watcher and a merely **idle** one produced byte-identical logs.

### Added
- **Self-heal trigger (`install.ps1 -RepeatMinutes`, default 15).** The task now carries a daily
  trigger repeating every 15 minutes alongside the logon trigger, so a dead watcher revives itself
  within one interval instead of waiting for the next sign-in. Redundant starts cost nothing — the
  per-folder mutex makes a second instance exit 0 immediately, and `MultipleInstances=IgnoreNew`
  backs it up. The installer **asserts the repetition round-tripped** into the registered task and
  warns loudly if it did not; that setting is known to come back empty on PS 5.1.
- **Heartbeat (`HeartbeatMinutes`, default 60).** Writes a periodic `Heartbeat: alive, idle.` line,
  so a silent log now proves the watcher is **dead** rather than idle, and brackets an unexplained
  death to within one interval. `0` disables.
- **Startup catch-up now processes Chrome dedupe orphans** (`ProcessOrphansOnStartup`, default
  `true`) instead of only warning about them — the orphans exist precisely because the watcher was
  down, so refusing to process them stranded the very payloads it was supposed to catch.
  Archives are handled **oldest-first**, so the newest download wins any collision.
  Set `false` for the 1.1.0–1.2.0 warn-only behaviour.

### Fixed
- **Log file never rolled past the startup date.** `Initialize-Log` runs once, so a watcher up for
  days kept writing into the file named for the day it *started*. Harmless when every run was
  short; fatal to the new heartbeat, which would have filed a Tuesday beat under Monday. `Write-Log`
  now rolls to today's file.
- **`-AtBoot` would have silently watched the wrong folder.** It switches the principal to SYSTEM,
  and since there is only one task the logon trigger runs as SYSTEM too — where `%USERPROFILE%`
  resolves to `C:\Windows\system32\config\systemprofile`. The watcher would have reported itself
  perfectly healthy while catching nothing. `install.ps1` now refuses `-AtBoot` unless
  `WatchFolder`/`ExtractTo` are absolute.

### Not done
- **Conversion to a real Windows service** was considered and rejected for now. The repeating
  trigger addresses the same failure at a fraction of the complexity.

### Ordering note
Catch-up sorts by `LastWriteTime`, and **does not assume `files.zip` is the newest archive** —
Chrome creates `files (1).zip` only *because* `files.zip` already existed, so the orphan is
normally the newer download. Sorting by name or processing the exact-name file first would let a
stale archive overwrite fresher files. Covered by a regression test.

### Self-test
Grown 23 → **31 assertions**, adding orphan-catch-up on/off, the oldest-first ordering guarantee
(a genuinely older `files.zip` must lose to a newer `files (1).zip`), and a live heartbeat check
that runs the real loop and kills it the way the 08-14 death happened.

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
