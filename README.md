# files-zip-watcher

An always-running Windows watcher for the `files.zip` archives that Claude's **"Download All"**
button drops into `~/Downloads`.

When one lands, it:

1. **Waits** until Chrome has genuinely finished writing it.
2. **Renames** it `files-<timestamp>.zip` — e.g. `files-2026-08-05-18-42.zip`
3. **Extracts** the contents **into `~/Downloads` itself** — *not* into a subfolder.
4. **Overwrites** any colliding files.
5. **Keeps** the renamed archive (configurable).

6. **Verifies** every extracted file against its own decompressed hash, and writes a
   `files-<timestamp>.sha256` manifest recording the archive and everything that came out of it.

Everything else in the folder is ignored.

```
~/Downloads/files.zip                    ~/Downloads/files-2026-08-05-19-32.zip
      (contains a.txt, sub/b.txt)   ->   ~/Downloads/a.txt
                                         ~/Downloads/sub/b.txt
```

**Runs light — measured, not estimated:**

| | Idle CPU | RAM | Timer wakes/hr |
|---|---|---|---|
| v1.0.0 | 0.33 % | 63 MB | 720 |
| **v1.1.0** | **0.078 %** | **18 MB** | **12** |

That's **22.5 CPU-seconds per 8-hour day** — no perceptible battery impact. See
[Running light](#running-light).

---

## Quick start

```powershell
git clone https://github.com/Mr-Champagne-TCM/files-zip-watcher.git
cd files-zip-watcher
.\install.ps1
```

That's it — it starts immediately and every time you log in. No admin rights needed.

**Verify it's alive:**

```powershell
Get-ScheduledTask -TaskName FilesZipWatcher | Select-Object State
Get-Content "$env:LOCALAPPDATA\FilesZipWatcher\logs\watcher-$(Get-Date -f yyyy-MM-dd).log" -Tail 20
```

**Remove it:**

```powershell
.\uninstall.ps1            # add -PurgeLogs to delete logs too
```

---

## Why a scheduled task and not a "real" Windows Service?

A true Windows Service (or a task that runs *before* anyone logs in) requires administrator
rights to install. This watcher does not need that scope, because **Chrome only downloads while
you are logged in** — so a logon-triggered task that runs continuously in your session covers
100% of the real cases, and installs with zero elevation.

The task is configured to behave like a service anyway:

| Setting | Value | Why |
|---|---|---|
| Trigger | At log on | Starts with your session |
| Trigger | **every 15 min** | **Self-heal — see below** |
| Execution time limit | *none* | Never killed for running "too long" |
| Restart on failure | 3 ×, 1 min apart | Survives a crash |
| Multiple instances | `IgnoreNew` | Never double-processes |
| On battery | keeps running | Laptop-safe |
| Window | hidden | No console popup |

### Why the repeating trigger (added in 1.3.0)

A logon-only trigger has a nasty failure mode, and it bit for real on **2026-08-14**: something
external closed the watcher mid-session (exit `0xC000013A` — a console-control close, not a
crash, so the script's own error handler never ran and logged nothing). The machine did not
reboot for three days, so the logon trigger never fired again. The watcher stayed dead until
**08-17** and silently missed a download.

`RestartOnFailure` did not save it — Windows recorded the task as *completed with an error code*,
not *failed to start*, so the restart policy never applied.

The repeating trigger is the fix: a dead watcher revives itself within one interval, no reboot
needed. Redundant starts are free — the per-folder mutex makes a second instance exit 0
immediately.

```powershell
.\install.ps1 -RepeatMinutes 30   # default 15; 0 = logon only (not recommended)
```

> ⚠️ **`-AtBoot` runs the task as SYSTEM**, and there is only one task — so the *logon* trigger
> runs as SYSTEM too. Under SYSTEM `%USERPROFILE%` resolves to
> `C:\Windows\system32\config\systemprofile`, meaning the watcher would sit watching a folder no
> browser ever writes to while reporting itself perfectly healthy. Since 1.3.0 `install.ps1`
> **refuses** `-AtBoot` unless `WatchFolder`/`ExtractTo` are absolute paths.

```powershell
.\install.ps1 -AtBoot      # elevated; requires absolute paths in config.json
```

A single-instance mutex (scoped per watch folder) guarantees only one copy processes archives
even if several triggers fire.

### How do I tell a dead watcher from an idle one?

Before 1.3.0 you could not — both produced a log that simply stopped. Since 1.3.0 the watcher
writes a heartbeat every `HeartbeatMinutes` (default 60):

```
2026-08-17 13:03:13 [INFO ] Heartbeat: alive, idle.
```

A log whose last heartbeat is hours old means the process is **gone**, and brackets the death to
within one interval.

---

### Does it still work when the desktop is locked?

**Yes — locked is not the same as signed out.** Locking secures the desktop; it does not suspend
your session. Chrome (and Claude Desktop) keep running and downloads complete, and the watcher is
running in that same session, so an archive landing at 3 a.m. behind a lock screen is processed
at 3 a.m.

| State | Downloads happen? | Watcher running? | Covered |
|---|---|---|---|
| Locked | yes | yes | ✅ |
| Signed out | no — the browser is gone too | no | ✅ nothing to miss |
| Sleep / hibernate | suspended | resumes on wake, sweep catches up | ✅ |

Confirmed on the installed task: `RunOnlyIfIdle=False`, `StopOnIdleEnd=False`, no execution time
limit, `LogonType=Interactive`, process in interactive session 1.

The only genuine gap is a writer running *outside* your interactive session — a SYSTEM service or
a scheduled job dropping `files.zip` while nobody is signed in. That is what `install.ps1 -AtBoot`
is for.

### Does it only work with Chrome?

No. Only one of the four completion checks (the `.crdownload` part file) is Chrome-specific — the
other three are writer-agnostic. **Claude Desktop**, Edge, Firefox, `curl`, or a file copy all
work: they simply satisfy stable-size + exclusive-open + valid-zip-parse instead.

## How "download complete" is detected

This is the part that matters most — extracting a half-written zip is the classic failure of
naive folder watchers. A file is only processed once **all four** conditions hold:

1. **No `.crdownload` sibling.** Chrome writes `files.zip.crdownload` while downloading and
   renames it at the end.
2. **Size is stable** across `StableChecks` consecutive samples `StableSeconds` apart
   (default: unchanged for ~6 s).
3. **The file opens exclusively** (`FileShare.None`) — proving Chrome has released its handle.
4. **It parses as a valid zip** — the central directory reads and entries enumerate.

If those never converge within `SettleTimeoutSeconds` (default 15 min), the file is logged and
abandoned rather than processed half-formed.

Detection is **event-driven** (`FileSystemWatcher`) with a **polling sweep** every
`PollSeconds` as a safety net — the sweep also catches archives that landed while the watcher
was stopped, so a reboot mid-download still gets handled.

---

## Provenance and integrity

Every extraction leaves a receipt. Next to `files-2026-08-05-21-28.zip` you get
`files-2026-08-05-21-28.sha256`:

```
710e3e07…  *files-2026-08-05-21-28.zip     <- the archive itself
e6704117…  *mockup_gen.py
460cee36…  *MU16_frame_param.svg
0ddd58e3…  *MU13_front_param.svg
…
```

Plain `sha256sum` format on purpose — no bespoke tooling required:

```bash
sha256sum -c files-2026-08-05-21-28.sha256      # verify the whole payload
diff <(tail -n +2 A.sha256|sort) <(tail -n +2 B.sha256|sort)   # did two payloads differ?
```

That second command is why this exists. On 2026-08-05 two `files.zip` payloads landed hours apart
and there was **no way to answer whether their contents differed** — the earlier archive was gone
and its files had been overwritten in place. It cost hours. Now it costs one `diff`.

**Post-extract verification.** Each entry's decompressed bytes are hashed as they stream to disk,
then the file is read back off disk and hashed again. Mismatch → logged as ERROR, counted as
`verify-failed`, and the archive is retained even if `KeepZipAfterExtract` is `false`.

This is **not** a re-check of the archive — .NET validates each entry's CRC-32 while inflating, so
a corrupt archive already throws. What is verified here is **the write**: truncation, a full disk,
a process kill mid-write, or something touching the file right after we close it (AV quarantine, a
sync client, a second writer).

**Overwrites are named, not counted.** A bare `overwritten 8` tells you nothing at 3 a.m.
**Every** replaced file gets its own line — the count and the list always agree:

```
[OK   ] Extracted-> C:\Users\jerem\Downloads  (new 0, overwritten 15, skipped 0, errors 0, verify-failed 0)
[WARN ] OVERWROTE 15 existing file(s):
[WARN ]     ~ CLAUDE_CODE_PROMPT_2026-08-05F-v2.md
[WARN ]     ~ ADDENDUM_2026-08-05F-4.md
[WARN ]     ~ hashes_05F.txt
[WARN ]     ~ mockup_gen.py
[WARN ]     ~ MU16_frame_param.svg
[WARN ]     ~ MU12_side_param.svg
[WARN ]     ~ MU13_front_param.svg
[WARN ]     ~ MU14_back_param.svg
[WARN ]     ~ MU15_bottom_param.svg
[WARN ]     ~ verify_sheets.py
[WARN ]     ~ verify_junctions.py
[WARN ]     ~ ADDENDUM_2026-08-05F-3.md
[WARN ]     ~ ADDENDUM_2026-08-05F-2.md
[WARN ]     ~ ADDENDUM_2026-08-05F.md
[WARN ]     ~ CAPTURE_NOTE_2026-08-05F.md
[OK   ] Integrity: all 15 extracted file(s) verified against their decompressed hash
[OK   ] Manifest -> files-2026-08-05-21-28.sha256  (15 files + archive)
```

(Real output from 2026-08-05 21:28, unabridged.)

## Running light

Design goal: **zero perceptible battery drain**. Three things get it there.

**1. It never enumerates the folder.** Because only the exact name `files.zip` is of interest,
the safety-net check is a single `Test-Path` on one known path — O(1), regardless of how many
thousands of files live in Downloads. v1.0.0 listed and regex-filtered every `*.zip` in the
folder 720 times an hour; that was essentially all of its CPU cost.

**2. Detection is event-driven, so the timer can be slow.** The `FileSystemWatcher` is filtered
to the single filename, so the OS only signals the process for that one name — reaction is
immediate. The poll loop is therefore a pure safety net (for FSW's known event-dropping under
buffer pressure, and for archives that land while the watcher is stopped), and runs every
**300 s** instead of 5 s. `Wait-Event -Timeout` genuinely blocks; it is not a spin loop.

**3. The working set is trimmed after every wake.** `EmptyWorkingSet` returns pages to the OS
after startup, after each processed archive, and on each quiet-path wake, which is what takes
resident memory from ~60 MB down to ~18 MB.

Measured on this machine (steady-state delta over 180 s, startup cost excluded):

```
Idle CPU : 0.0781 % of one core   ->  22.5 CPU-seconds per 8-hour day
RAM      : 18.5 MB working set
Wakeups  : 12/hour
Priority : BelowNormal
```

If you want it even quieter, raise `PollSeconds` — the event watcher still catches everything
promptly; you are only lengthening the safety net.

## Why only `files.zip`

Only the **exact** filename is processed. Chrome's dedupe variants — `files (1).zip`,
`files (2).zip` — are deliberately **not** handled, for the reason you'd hope:

> If the watcher is healthy, `files.zip` is renamed within seconds of the download finishing,
> so Chrome never has a reason to create a `(1)` variant in the first place.

A variant appearing therefore *means something*: the watcher was down when that download landed.

**In steady state that is still true** — the live FileSystemWatcher is filtered to one exact
name, which is what keeps the hot path O(1).

**On startup, since 1.3.0, orphans are processed rather than merely reported.** The original
warn-only policy was the wrong call in practice: an orphan exists precisely *because* the watcher
was down, so refusing to touch it stranded the very payload the tool was meant to catch — you got
a warning instead of your files. The signal is preserved by logging it loudly, not by withholding
the work:

```
[WARN ] Startup catch-up: 2 archive(s) waiting, 1 of them Chrome dedupe orphan(s)
        -- the watcher was down when those arrived.
[INFO ] Catch-up 1/2: 'files.zip' (modified 2026-08-17 09:14:02)
[INFO ] Catch-up 2/2: 'files (1).zip' (modified 2026-08-17 11:31:47)
```

### Ordering: oldest first

Archives are processed **oldest-first by `LastWriteTime`**, so the newest download extracts last
and wins any collision.

The tempting shortcut — "process `files.zip` first, then the variants" — is **wrong**. Chrome
creates `files (1).zip` only *because* `files.zip` already existed, so the orphan is normally the
**newer** download. Handling the exact-name file first would let a stale archive overwrite fresher
files. There is a regression test for exactly this.

Set `"ProcessOrphansOnStartup": false` for the 1.1.0–1.2.0 warn-only behaviour:

```
[WARN ] Orphan found (watcher was down when it arrived): 'files (1).zip'.
        Not processed -- ProcessOrphansOnStartup is false. Rename it to 'files.zip'.
```

## Timestamp format

> ⚠️ **Note on the original spec.** The request specified `YYYY-DD-HH-MM`, which has **no month**.
> That makes `2026-05-14-30` ambiguous between *any* month's 5th at 14:30 — causing filename
> collisions and wrong chronological sorting. The default here is **`yyyy-MM-dd-HH-mm`**
> (`files-2026-08-05-18-42.zip`): same fields, month restored, sorts correctly as text.

To use the literal original format anyway, set in `config.json`:

```json
"TimestampFormat": "yyyy-dd-HH-mm"
```

Any [.NET format string](https://learn.microsoft.com/dotnet/standard/base-types/custom-date-and-time-format-strings)
works. If a target name already exists, `-1`, `-2`, … is appended, so nothing is ever clobbered.

---

## Configuration

All settings live in [`config.json`](config.json). Paths accept `%ENVVAR%`.
After editing, apply with `.\install.ps1 -Restart`.

| Key | Default | Meaning |
|---|---|---|
| `WatchFolder` | `%USERPROFILE%\Downloads` | Folder to watch |
| `ExtractTo` | `%USERPROFILE%\Downloads` | Where contents land (no wrapper folder) |
| `WatchFileName` | `files.zip` | **Exact** filename. See [Why only `files.zip`](#why-only-fileszip) |
| `OrphanWarnPattern` | `^files \(\d+\)\.zip$` | Identifies Chrome dedupe variants |
| `ProcessOrphansOnStartup` | `true` | Startup sweep also processes dedupe orphans, oldest-first. `false` = warn only |
| `HeartbeatMinutes` | `60` | Periodic "alive, idle" log line so silence means dead. `0` disables |
| `TimestampFormat` | `yyyy-MM-dd-HH-mm` | See above |
| `RenamePrefix` | `files-` | Prefix for the renamed archive |
| `KeepZipAfterExtract` | `true` | `false` deletes the archive after a successful extract |
| `Overwrite` | `true` | `false` skips colliding files instead |
| `WriteManifest` | `true` | Write the `.sha256` sidecar per extraction |
| `ManifestExtension` | `.sha256` | Sidecar extension |
| `StableSeconds` / `StableChecks` | `2` / `3` | Quiet period before "complete" |
| `PollSeconds` | `300` | Safety-net interval. Detection is event-driven, so long is fine |
| `SettleTimeoutSeconds` | `900` | Give up on a stalled download |
| `LogDir` | `%LOCALAPPDATA%\FilesZipWatcher\logs` | Log location |
| `LogRetentionDays` | `30` | Older logs auto-pruned |

---

## Safety

- **Zip-slip protected.** Entries with absolute paths, drive letters, or `..` traversal are
  refused and logged — a malicious archive cannot write outside `ExtractTo`. Covered by a test.
- **Nothing else is touched.** The tool only ever creates a scheduled task and log files. It
  never modifies the registry, system settings, or files outside `ExtractTo`.
- **Only `files.zip` is ever acted on.** Every other file — including other `.zip` files — is
  ignored.
- **Overwrites are intentional** (that was the requirement) and are counted in the log so you
  can see what was replaced.

---

## Logs

```
%LOCALAPPDATA%\FilesZipWatcher\logs\watcher-YYYY-MM-DD.log
```

A processed archive looks like:

```
2026-08-05 18:42:09 [INFO ] Detected: files.zip
2026-08-05 18:42:15 [INFO ] Download complete (4.21 MB). Processing.
2026-08-05 18:42:15 [OK   ] Renamed  -> files-2026-08-05-18-42.zip
2026-08-05 18:42:15 [OK   ] Extracted-> C:\Users\jerem\Downloads  (new 7, overwritten 2, skipped 0, errors 0)
```

---

## Testing

```powershell
.\tests\Invoke-SelfTest.ps1
```

Runs entirely in a temp sandbox — **it never touches your real Downloads folder**. It builds a
synthetic `files.zip` (plain file, nested folder, a deliberate collision, and a zip-slip attack
entry) and asserts **31** behaviours including flat extraction, overwrite, no wrapper folder,
traversal refusal, non-matching zips ignored, manifest format and hash-vs-disk agreement, and
both orphan modes.

Three of those checks exist because of the 1.3.0 outage specifically:

- **oldest-first ordering** — a genuinely older `files.zip` must lose the collision to a newer
  `files (1).zip`, since that is the real-world arrangement Chrome produces
- **heartbeat beats while idle** — runs the *real* loop (not `-Once`), then kills it the way the
  08-14 death happened, and asserts the log recorded liveness
- **heartbeat lands in today's log file** — guards the log-rolling fix

Takes roughly 30 seconds; the heartbeat check deliberately spends ~12 s watching a live loop.

The single-instance mutex is scoped **per watch folder**, so the self-test and manual `-Once`
runs work normally while the installed service is live.

Manual catch-up run without installing anything:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\FilesZipWatcher.ps1 -Once
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing happens | `Get-ScheduledTask FilesZipWatcher \| Select State` — should be `Running` |
| Task shows `Ready`, not `Running` | It exited. Read today's log; then `Start-ScheduledTask -TaskName FilesZipWatcher` |
| Archive renamed but not extracted | Log will show the extract error — usually a locked destination file |
| Two copies seem to run | Impossible by design (mutex); confirm with `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"` |
| Want it to react faster | Lower `StableSeconds`, but you trade off against truncated-download risk |
| Config edit not applied | `.\install.ps1 -Restart` |

---

## Layout

```
files-zip-watcher/
├─ src/FilesZipWatcher.ps1     # the watcher (detection, rename, extract)
├─ tests/Invoke-SelfTest.ps1   # sandboxed end-to-end test, 11 assertions
├─ config.json                 # all tunables
├─ install.ps1                 # register + start the task
├─ uninstall.ps1               # stop + remove (optionally purge logs)
├─ docs/DESIGN.md              # why it's built this way; edge cases
├─ CHANGELOG.md
└─ LICENSE                     # MIT
```

## License

MIT — see [LICENSE](LICENSE).
