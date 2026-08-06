# DESIGN — why files-zip-watcher is built this way

Notes for future-us. The *what* is in the README; this is the *why*, plus the edge cases that
drove each decision.

## Origin

Claude web sessions have a **"Download All"** button that emits a single `files.zip` into
`~/Downloads`. Unpacking it by hand every time — and losing track of which `files.zip` came from
which session, because Chrome just appends `(1)`, `(2)` — was the annoyance this removes.

Requirements as given (2026-08-05):

- always-running service, starts at boot
- watch `~/Downloads` for `files.zip` from Chrome, wait for the download to *complete*
- rename to a timestamped name
- extract into `~/Downloads` **flat** (no `files-<stamp>/` wrapper)
- overwrite collisions
- only `files.zip`; ignore everything else

## Decision log

### 1. Scheduled Task, not a Windows Service

A real service needs `sc.exe create` / a service wrapper (NSSM) and **admin rights**. The install
shell available was non-elevated, and more importantly the elevation buys nothing: the watch
target is a *user profile* folder fed by a *user session* browser. Chrome cannot download while
nobody is logged in, so a boot-scoped service would idle until logon anyway.

The task is configured with service-like semantics (no execution time limit, restart-on-failure,
survives battery, hidden window). `install.ps1 -AtBoot` upgrades to a SYSTEM/AtStartup task for
anyone who later needs it.

**Trade-off accepted:** if a *non-interactive* process ever drops `files.zip` into that folder
while logged out, the default install won't see it until logon. Deemed irrelevant for the use
case.

### 2. Completion detection is four-layered

The single biggest failure mode of a naive `FileSystemWatcher` is firing on `Created`, which
Chrome raises when the file is **zero bytes**. Extracting then either fails or, worse, half-works.

Layers, cheapest first:

1. **`.crdownload` sibling absent.** Chrome's in-progress marker. Fast and definitive while present.
2. **Size stable** across N samples. Catches the window after the rename but before flush.
3. **Exclusive open** (`FileShare.None`). Proves no other process holds a handle. This is the
   real "Chrome is done" signal.
4. **Valid zip parse.** Central directory reads and entries enumerate — proves the archive is
   structurally whole, not merely quiet.

All four must hold. Any failure resets the stability counter rather than proceeding.

**Why not just `.crdownload`?** Because Chrome's "save as" path, resumed downloads, and some
extensions don't always produce one. Belt and braces.

### 3. FileSystemWatcher **and** a polling sweep

`FileSystemWatcher` is famously lossy: it silently drops events under buffer pressure, and misses
everything that happens while the process is down. The polling sweep (`PollSeconds`, default 5 s)
makes the system **self-healing** — restart the machine mid-download and the sweep picks the
archive up on next start. The watcher provides latency; the sweep provides correctness.

### 4. Flat extraction, structure preserved

"Into `~/Downloads`, not `~/Downloads/files-<stamp>/`" means no *wrapper* folder. Folders that
exist *inside* the archive are still recreated — `sub/b.txt` becomes `~/Downloads/sub/b.txt`.
Anything else would flatten distinct files onto each other.

### 5. Manual entry-by-entry extraction

`Expand-Archive` and `ExtractToDirectory` were both rejected:

- `ExtractToDirectory` **throws on the first collision** and has no overwrite mode in .NET
  Framework 4.x — and overwriting was a hard requirement.
- Neither lets us **refuse zip-slip entries**.

So entries are walked manually with `ZipFileExtensions::ExtractToFile($entry, $target, $true)`.
This also gives us the new/overwritten/skipped/error counts that show up in the log.

### 6. Zip-slip protection

An archive entry named `..\..\evil.txt` would otherwise write outside the destination. Guard is
two-stage: reject on the raw entry string (leading separator, drive letter, or a `..` path
segment), then re-verify that the *resolved absolute path* still starts with the destination
root. The self-test ships a real malicious entry to prove the guard holds.

This matters more than usual here: the tool auto-runs on files arriving from a browser.

### 7. Single-instance mutex

Both an AtLogon and an AtStartup trigger can fire; a user can also run the script by hand. Two
copies racing on the same archive would double-rename or half-extract. A named global mutex means
the second copy logs and exits.

`MultipleInstances = IgnoreNew` on the task is the same guarantee at the scheduler level.

### 8. Timestamp format deviation — deliberate

The spec said `YYYY-DD-HH-MM`. **It has no month.** Two archives from the 5th of different months
at the same time of day would collide, and text-sorting a folder would interleave months.
Implemented as `yyyy-MM-dd-HH-mm` and surfaced as config, with the deviation documented in the
README rather than silently applied. Collision suffixes (`-1`, `-2`) exist regardless, so even
the literal original format can't destroy data.

### 9. Archive kept by default

The requirement said "rename … then unzip", not "delete". Keeping it makes the rename meaningful
(you retain a timestamped record of each session's payload) and makes re-extraction possible.
`KeepZipAfterExtract: false` for anyone who disagrees.

## Known limitations

- **Interactive-session scope** by default (see decision 1).
- **No content dedupe.** Two identical `files.zip` downloads produce two timestamped archives and
  overwrite the same extracted files. Deliberate — matches the "overwrite collisions" requirement.
- **Minute resolution.** Two archives completing in the same minute get `-1` suffixes. Bump to
  `yyyy-MM-dd-HH-mm-ss` if that becomes common.
- **No notification.** Success/failure is only in the log. A toast on completion would be the
  obvious next feature.
- **PowerShell 5.1 targeted.** Avoids `??`/ternary and PS7-only cmdlets so it runs on stock
  Windows with no install.

## Possible next steps

- Toast notification on extract (`BurntToast` or raw `Windows.UI.Notifications`).
- Per-session subfolder mode as an option (`ExtractMode: flat | perArchive`).
- Content hash of the archive in the log line, for tracing which payload produced which files.
- Optional quarantine: extract to a temp dir, scan, then move into place.
