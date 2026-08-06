# files-zip-watcher

An always-running Windows watcher for the `files.zip` archives that Claude's **"Download All"**
button drops into `~/Downloads`.

When one lands, it:

1. **Waits** until Chrome has genuinely finished writing it.
2. **Renames** it `files-<timestamp>.zip` — e.g. `files-2026-08-05-18-42.zip`
3. **Extracts** the contents **into `~/Downloads` itself** — *not* into a subfolder.
4. **Overwrites** any colliding files.
5. **Keeps** the renamed archive (configurable).

Everything else in the folder is ignored.

```
~/Downloads/files.zip                    ~/Downloads/files-2026-08-05-18-42.zip
      (contains a.txt, sub/b.txt)   ->   ~/Downloads/a.txt
                                         ~/Downloads/sub/b.txt
```

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
| Execution time limit | *none* | Never killed for running "too long" |
| Restart on failure | 3 ×, 1 min apart | Survives a crash |
| Multiple instances | `IgnoreNew` | Never double-processes |
| On battery | keeps running | Laptop-safe |
| Window | hidden | No console popup |

If you ever genuinely need it before login, run **from an elevated PowerShell**:

```powershell
.\install.ps1 -AtBoot      # adds an AtStartup trigger, runs as SYSTEM
```

A single-instance mutex (`Global\FilesZipWatcher_SingleInstance`) guarantees only one copy
processes archives even if both triggers fire.

---

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
| `MatchPattern` | `^files(?: \(\d+\))?\.zip$` | Regex on **file name**. Matches `files.zip` **and** Chrome's dedupe variants `files (1).zip` |
| `TimestampFormat` | `yyyy-MM-dd-HH-mm` | See above |
| `RenamePrefix` | `files-` | Prefix for the renamed archive |
| `KeepZipAfterExtract` | `true` | `false` deletes the archive after a successful extract |
| `Overwrite` | `true` | `false` skips colliding files instead |
| `StableSeconds` / `StableChecks` | `2` / `3` | Quiet period before "complete" |
| `PollSeconds` | `5` | Safety-net sweep interval |
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
entry) and asserts 11 behaviours including flat extraction, overwrite, no wrapper folder,
traversal refusal, and that non-matching zips are ignored.

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
