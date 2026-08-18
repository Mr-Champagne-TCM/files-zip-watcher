<#
.SYNOPSIS
    Watches the Downloads folder for `files.zip` (Claude "Download All"), timestamps it, and
    extracts it flat into Downloads.

.DESCRIPTION
    Long-running, low-power watcher. For a completed download named exactly `files.zip`:

        1. Waits until the download is genuinely finished (see Wait-DownloadComplete).
        2. Renames it to  files-<timestamp>.zip   (default: files-2026-08-05-19-32.zip)
        3. Extracts the archive contents into the watch folder itself -- NOT into a subfolder.
        4. Overwrites any colliding files.
        5. Keeps the renamed .zip (configurable).

    Everything else in the folder is ignored.

    LOW-POWER DESIGN: detection is event-driven (FileSystemWatcher filtered to the single
    filename). The safety-net sweep is an O(1) Test-Path on one known path -- it never
    enumerates the directory -- and runs infrequently (default every 5 minutes). Idle CPU is
    effectively zero and the working set is trimmed after every wake.

.PARAMETER ConfigPath
    Path to config.json. Defaults to ..\config.json relative to this script.

.PARAMETER Once
    Process anything already present, then exit. Used by tests and manual catch-up runs.

.PARAMETER Live
    Show live output. If a watcher is already running (the normal case -- the scheduled task runs
    windowless under S4U), this ATTACHES to its log as a read-only viewer, so closing the window
    cannot affect it. If nothing is running, it runs one in the foreground instead. Prefer the
    `watch-live.ps1` wrapper at the repo root.

.NOTES
    Repo    : https://github.com/Mr-Champagne-TCM/files-zip-watcher
    Requires: Windows PowerShell 5.1+ (no external modules)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once,
    [switch]$Live
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Working-set trimmer: returns pages to the OS after each wake so an idle watcher
# holds ~10-15 MB instead of the ~60 MB PowerShell startup footprint.
if (-not ('FZW.Native' -as [type])) {
    Add-Type -Namespace FZW -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(System.IntPtr hProcess);
'@
}
function Compress-Footprint {
    try {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        [void][FZW.Native]::EmptyWorkingSet([Diagnostics.Process]::GetCurrentProcess().Handle)
    } catch { }
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-WatcherConfig {
    param([string]$Path)

    $defaults = [ordered]@{
        WatchFolder     = (Join-Path $env:USERPROFILE 'Downloads')
        ExtractTo       = (Join-Path $env:USERPROFILE 'Downloads')
        # EXACT filename only. Chrome dedupe variants are deliberately NOT processed --
        # if the watcher is healthy the archive is renamed within seconds, so Chrome never
        # needs to create "files (1).zip". Seeing one means we were down; we warn instead.
        WatchFileName   = 'files.zip'
        OrphanWarnPattern = '^files \(\d+\)\.zip$'
        # v1.3.0: startup catch-up may now PROCESS dedupe orphans instead of only warning.
        # Steady-state detection is unchanged and still exact-name-only -- this is startup only.
        ProcessOrphansOnStartup = $true
        # v1.3.0: periodic "still alive" line so a silent log means DEAD, not merely idle.
        # 0 disables. Bounds the unknown window on a death to this many minutes.
        HeartbeatMinutes = 60
        # yyyy-MM-dd-HH-mm  ->  files-2026-08-05-19-32.zip
        TimestampFormat = 'yyyy-MM-dd-HH-mm'
        RenamePrefix    = 'files-'
        KeepZipAfterExtract = $true
        Overwrite       = $true
        # v1.2.0 integrity: sidecar manifest + post-extract verification
        WriteManifest     = $true
        ManifestExtension = '.sha256'
        StableSeconds   = 2      # size must hold steady this long
        StableChecks    = 3      # ...across this many consecutive samples
        PollSeconds     = 300    # safety-net only; FileSystemWatcher does the real work
        SettleTimeoutSeconds = 900   # give up waiting on a stalled download
        LogDir          = (Join-Path $env:LOCALAPPDATA 'FilesZipWatcher\logs')
        LogRetentionDays = 30
    }

    if ($Path -and (Test-Path $Path)) {
        $json = Get-Content $Path -Raw | ConvertFrom-Json
        foreach ($k in @($defaults.Keys)) {
            if ($json.PSObject.Properties.Name -contains $k) {
                $v = $json.$k
                if ($null -ne $v -and "$v" -ne '') { $defaults[$k] = $v }
            }
        }
    }

    foreach ($k in 'WatchFolder','ExtractTo','LogDir') {
        $defaults[$k] = [Environment]::ExpandEnvironmentVariables([string]$defaults[$k])
    }
    return $defaults
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$script:LogFile = $null
$script:LogDir  = $null

function Get-LogPath {
    param([string]$Dir)
    return (Join-Path $Dir ("watcher-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')))
}

function Initialize-Log {
    param($Config)
    if (-not (Test-Path $Config.LogDir)) {
        New-Item -ItemType Directory -Force -Path $Config.LogDir | Out-Null
    }
    $script:LogDir  = $Config.LogDir
    $script:LogFile = Get-LogPath -Dir $Config.LogDir

    Get-ChildItem $Config.LogDir -Filter 'watcher-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1 * [int]$Config.LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    # Roll to today's file. Initialize-Log runs ONCE at startup, so without this a watcher that
    # stays up for days keeps writing into the file named for the day it started -- which would
    # make the v1.3.0 heartbeat useless for dating a death (beats for 08-18 landing in the
    # 08-17 log). Cheap: a string compare per line.
    if ($script:LogDir) {
        $want = Get-LogPath -Dir $script:LogDir
        if ($want -ne $script:LogFile) { $script:LogFile = $want }
    }

    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Start-LiveTail {
    <#
        -Live ATTACH MODE. The production watcher runs windowless (Task Scheduler S4U), so there
        is no console to look at and nothing to attach a debugger to. Instead we follow its log
        file, which is the same stream its Write-Host would have produced.

        This is strictly a READER. It never touches the watch folder, never takes the lock, and
        the running watcher neither knows nor cares that it exists -- so closing this window can
        not affect the watcher in any way. That is the whole point.

        Follows across midnight: the log path is recomputed every poll, so a roll to tomorrow's
        file is picked up instead of silently tailing yesterday's forever.
    #>
    param($Config, [int]$TailLines = 25)

    $path = Get-LogPath -Dir $Config.LogDir
    Write-Host ''
    Write-Host '  FilesZipWatcher -- LIVE (attached to the running watcher)' -ForegroundColor Cyan
    Write-Host "  log: $path" -ForegroundColor DarkGray
    Write-Host '  Read-only view. Closing this window does NOT stop the watcher.' -ForegroundColor Green
    Write-Host '  Ctrl+C to detach.' -ForegroundColor DarkGray
    Write-Host ''

    $pos = 0
    if (Test-Path -LiteralPath $path) {
        Get-Content -LiteralPath $path -Tail $TailLines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        try { $pos = (Get-Item -LiteralPath $path -Force).Length } catch { $pos = 0 }
    } else {
        Write-Host '  (no log file yet -- waiting for the watcher to write one)' -ForegroundColor DarkGray
    }

    while ($true) {
        Start-Sleep -Milliseconds 500

        $cur = Get-LogPath -Dir $Config.LogDir
        if ($cur -ne $path) {
            Write-Host ''
            Write-Host "  --- log rolled to $(Split-Path $cur -Leaf) ---" -ForegroundColor DarkGray
            $path = $cur; $pos = 0
        }
        if (-not (Test-Path -LiteralPath $path)) { continue }

        try { $len = (Get-Item -LiteralPath $path -Force).Length } catch { continue }
        if ($len -lt $pos) { $pos = 0 }      # truncated or replaced under us
        if ($len -le $pos) { continue }

        # FileShare ReadWrite -- must NOT lock the file, or we would block the watcher's own
        # Add-Content and turn a read-only viewer into something that can break production.
        try {
            $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                [void]$fs.Seek($pos, [IO.SeekOrigin]::Begin)
                $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                while (-not $sr.EndOfStream) { Write-Host $sr.ReadLine() }
                $pos = $fs.Position
            } finally { $fs.Dispose() }
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# Download-completion detection
# ---------------------------------------------------------------------------

function Test-FileLocked {
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'None')   # exclusive
        $fs.Close(); $fs.Dispose()
        return $false
    } catch { return $true }
}

function Test-ValidZip {
    param([string]$Path)
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($Path)
        $null = @($z.Entries).Count
        $z.Dispose()
        return $true
    } catch { return $false }
}

function Wait-DownloadComplete {
    <#
        Complete when ALL hold: no .crdownload sibling; byte size unchanged across N samples;
        file opens exclusively (Chrome released its handle); parses as a valid zip.
    #>
    param([string]$Path, $Config)

    $deadline = (Get-Date).AddSeconds([int]$Config.SettleTimeoutSeconds)
    $lastSize = -1
    $stable   = 0

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path $Path)) {
            Write-Log "Vanished before completion (user moved/deleted?): $Path" 'WARN'
            return $false
        }

        if (Test-Path "$Path.crdownload") { $stable = 0; Start-Sleep -Seconds ([int]$Config.StableSeconds); continue }

        try { $size = (Get-Item $Path -Force).Length } catch { Start-Sleep -Seconds 1; continue }

        if ($size -eq $lastSize -and $size -gt 0) { $stable++ } else { $stable = 0; $lastSize = $size }

        if ($stable -ge [int]$Config.StableChecks) {
            if (Test-FileLocked $Path) { $stable = 0 }
            elseif (Test-ValidZip $Path) { return $true }
            else { $stable = 0 }
        }
        Start-Sleep -Seconds ([int]$Config.StableSeconds)
    }

    Write-Log "Timed out after $($Config.SettleTimeoutSeconds)s waiting for: $Path" 'ERROR'
    return $false
}

# ---------------------------------------------------------------------------
# Rename + extract
# ---------------------------------------------------------------------------

function Get-TimestampedName {
    param([string]$Folder, $Config)

    $stamp = Get-Date -Format $Config.TimestampFormat
    $base  = "{0}{1}" -f $Config.RenamePrefix, $stamp
    $candidate = Join-Path $Folder "$base.zip"
    $n = 1
    while (Test-Path $candidate) {
        $candidate = Join-Path $Folder ("{0}-{1}.zip" -f $base, $n)
        $n++
    }
    return $candidate
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs  = [IO.File]::OpenRead($Path)
    try   { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-','').ToLowerInvariant() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Expand-ArchiveFlat {
    <#
        Extract into $Destination preserving the archive's internal folder structure but with
        NO wrapper folder. Overwrites when configured. Refuses zip-slip entries.

        INTEGRITY (v1.2.0): each entry's DECOMPRESSED bytes are SHA-256'd as they stream to disk,
        then the file is read back off disk and hashed again. A mismatch means the bytes did not
        land correctly -- truncated write, disk full, killed mid-write, or something modified the
        file immediately after us (AV quarantine, sync client, a second writer).

        Note this is deliberately NOT a re-check of the archive: .NET validates each entry's
        CRC-32 during inflation and throws on mismatch, so a corrupt archive is already caught.
        What is verified here is the WRITE.

        Returns counts plus a per-file record used to build the manifest sidecar.
    #>
    param([string]$ZipPath, [string]$Destination, $Config)

    $result = [ordered]@{
        Extracted = 0; Overwritten = 0; Skipped = 0; Errors = 0; VerifyFailed = 0
        Files = New-Object System.Collections.ArrayList
        OverwrittenNames = New-Object System.Collections.ArrayList
    }
    $destFull = [IO.Path]::GetFullPath($Destination.TrimEnd('\') + '\')

    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }   # directory entry

            $rel = $entry.FullName -replace '/', '\'
            if ($rel -match '^[\\/]' -or $rel -match '^[A-Za-z]:' -or $rel -split '\\' -contains '..') {
                Write-Log "  ! zip-slip entry refused: $($entry.FullName)" 'WARN'
                $result.Skipped++; continue
            }

            $target = [IO.Path]::GetFullPath((Join-Path $destFull $rel))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "  ! entry escapes destination, refused: $($entry.FullName)" 'WARN'
                $result.Skipped++; continue
            }

            $existed = Test-Path $target
            if ($existed -and -not $Config.Overwrite) {
                Write-Log "  - exists, overwrite disabled: $rel" 'WARN'
                $result.Skipped++; continue
            }

            $dir = Split-Path $target -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

            try {
                # Stream the entry to disk, hashing the decompressed bytes on the way through.
                $sha = [Security.Cryptography.SHA256]::Create()
                $src = $entry.Open()
                $dst = [IO.File]::Create($target)
                try {
                    $buf = New-Object byte[] 81920
                    while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
                        $null = $sha.TransformBlock($buf, 0, $n, $null, 0)
                        $dst.Write($buf, 0, $n)
                    }
                    $null = $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                    $expected = ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
                } finally { $dst.Dispose(); $src.Dispose(); $sha.Dispose() }

                # Read it back off disk. This is the actual verification.
                $actual = Get-FileSha256 $target
                $ok = ($actual -eq $expected)

                if ($ok) {
                    if ($existed) {
                        $result.Overwritten++
                        [void]$result.OverwrittenNames.Add($rel)
                    } else { $result.Extracted++ }
                } else {
                    $result.VerifyFailed++
                    Write-Log "  !! POST-EXTRACT VERIFY FAILED: '$rel'" 'ERROR'
                    Write-Log "     expected $expected" 'ERROR'
                    Write-Log "     on disk  $actual" 'ERROR'
                }

                [void]$result.Files.Add([pscustomobject]@{
                    Path = $rel; Sha256 = $expected; OnDisk = $actual
                    Verified = $ok; Overwrote = $existed; Bytes = $entry.Length
                })
            } catch {
                Write-Log "  ! extract failed for '$rel': $($_.Exception.Message)" 'ERROR'
                $result.Errors++
            }
        }
    } finally { $zip.Dispose() }

    return $result
}

function Write-ManifestSidecar {
    <#
        Writes <archive-basename>.sha256 next to the archive: one sha256sum-format line per
        extracted file, PLUS a line for the archive itself. Pure sha256sum format on purpose --
        `sha256sum -c files-<stamp>.sha256` verifies the whole payload with no bespoke tooling.

        This is the record that was missing on 2026-08-05: two extractions landed and there was
        no way to tell whether their payloads differed.
    #>
    param([string]$ZipPath, $Result, $Config)

    $manifest = [IO.Path]::ChangeExtension($ZipPath, $Config.ManifestExtension)
    $lines = New-Object System.Collections.ArrayList

    try { [void]$lines.Add(("{0} *{1}" -f (Get-FileSha256 $ZipPath), (Split-Path $ZipPath -Leaf))) }
    catch { Write-Log "  ! could not hash archive for manifest: $($_.Exception.Message)" 'WARN' }

    foreach ($f in $Result.Files) {
        [void]$lines.Add(("{0} *{1}" -f $f.Sha256, $f.Path))
    }

    try {
        # MUST be LF-terminated, not CRLF. GNU sha256sum -c treats a trailing \r as part of the
        # filename and fails every line with "No such file or directory" -- which defeats the
        # entire purpose of emitting a standard-format manifest. (Found on the first real run.)
        $text = ($lines -join "`n") + "`n"
        [IO.File]::WriteAllText($manifest, $text, (New-Object Text.UTF8Encoding($false)))
        Write-Log "Manifest -> $(Split-Path $manifest -Leaf)  ($($Result.Files.Count) files + archive)" 'OK'
    } catch {
        Write-Log "  ! manifest write failed: $($_.Exception.Message)" 'ERROR'
    }
}

function Invoke-ProcessZip {
    param([string]$Path, $Config)

    Write-Log "Detected: $(Split-Path $Path -Leaf)"

    if (-not (Wait-DownloadComplete -Path $Path -Config $Config)) { return }

    $sizeMB = [math]::Round((Get-Item $Path -Force).Length / 1MB, 2)
    Write-Log "Download complete ($sizeMB MB). Processing."

    $newPath = Get-TimestampedName -Folder (Split-Path $Path -Parent) -Config $Config
    try {
        Move-Item -LiteralPath $Path -Destination $newPath -Force
        Write-Log "Renamed  -> $(Split-Path $newPath -Leaf)" 'OK'
    } catch {
        Write-Log "Rename failed: $($_.Exception.Message)" 'ERROR'; return
    }

    try {
        $r = Expand-ArchiveFlat -ZipPath $newPath -Destination $Config.ExtractTo -Config $Config
        Write-Log ("Extracted-> {0}  (new {1}, overwritten {2}, skipped {3}, errors {4}, verify-failed {5})" -f `
                   $Config.ExtractTo, $r.Extracted, $r.Overwritten, $r.Skipped, $r.Errors, $r.VerifyFailed) 'OK'

        # Name every file we replaced. A bare count told us nothing on 2026-08-05.
        if ($r.OverwrittenNames.Count -gt 0) {
            Write-Log "OVERWROTE $($r.OverwrittenNames.Count) existing file(s):" 'WARN'
            foreach ($n in $r.OverwrittenNames) { Write-Log "    ~ $n" 'WARN' }
        }

        if ($r.VerifyFailed -gt 0) {
            Write-Log ("INTEGRITY: {0} file(s) FAILED post-extract verification - archive retained, do not trust these files" -f $r.VerifyFailed) 'ERROR'
        } elseif ($r.Files.Count -gt 0) {
            Write-Log "Integrity: all $($r.Files.Count) extracted file(s) verified against their decompressed hash" 'OK'
        }

        if ($Config.WriteManifest) { Write-ManifestSidecar -ZipPath $newPath -Result $r -Config $Config }
    } catch {
        Write-Log "Extract failed: $($_.Exception.Message)" 'ERROR'; return
    }

    # Never discard the archive if anything failed verification - it is the only clean copy.
    if ($r.VerifyFailed -gt 0 -and -not $Config.KeepZipAfterExtract) {
        Write-Log 'Archive RETAINED despite KeepZipAfterExtract=false (verification failures present)' 'WARN'
    }
    elseif (-not $Config.KeepZipAfterExtract) {
        try { Remove-Item -LiteralPath $newPath -Force; Write-Log 'Removed archive (KeepZipAfterExtract=false)' }
        catch { Write-Log "Could not remove archive: $($_.Exception.Message)" 'WARN' }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'
}
$Config = Get-WatcherConfig -Path $ConfigPath
Initialize-Log -Config $Config

if (-not (Test-Path $Config.WatchFolder)) {
    Write-Log "Watch folder does not exist: $($Config.WatchFolder)" 'ERROR'; exit 1
}
if (-not (Test-Path $Config.ExtractTo)) {
    New-Item -ItemType Directory -Force -Path $Config.ExtractTo | Out-Null
}

# Single-instance guard, scoped PER WATCH FOLDER.
# A global name would (and did) block the sandboxed self-test and any manual -Once catch-up
# run whenever the installed service was live. Two watchers on *different* folders are fine;
# two on the *same* folder would double-process.
$folderKey = ([Security.Cryptography.MD5]::Create().ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($Config.WatchFolder.ToLowerInvariant().TrimEnd('\'))
             ) | ForEach-Object { $_.ToString('x2') }) -join ''
# v1.4.0: a LOCK FILE, not a mutex.
#
# The old guard took a `Global\` named mutex and silently fell back to `Local\` if that failed.
# Creating a Global\ object needs SeCreateGlobalPrivilege, which a non-elevated token does not
# have -- so in practice both sides took the per-SESSION Local\ name. Once the watcher moved to
# S4U (session 0) and a -Live viewer ran on the desktop (session 1), the two lived in different
# namespaces, each concluded it was alone, and TWO watchers could run on one folder and
# double-process an archive. Caught on the first real S4U run.
#
# An exclusively-opened file has none of those problems: the lock is machine-wide, needs no
# privilege, and the OS releases it automatically when the holder dies -- so there is no such
# thing as a stale lock to clean up.
$lockPath = Join-Path $Config.LogDir ("watcher-{0}.lock" -f $folderKey.Substring(0,16))
$lock = $null
try {
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stamp = [Text.Encoding]::UTF8.GetBytes(("pid={0} session={1} started={2}`n" -f `
                $PID, [Diagnostics.Process]::GetCurrentProcess().SessionId, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $lock.SetLength(0); $lock.Write($stamp, 0, $stamp.Length); $lock.Flush()
} catch {
    $lock = $null
}

if (-not $lock) {
    # Somebody else owns this watch folder.
    if ($Live) {
        # Expected case: the scheduled task is running windowless and we just want to watch it.
        # Attach to its log rather than refusing -- and hold no lock of our own.
        Start-LiveTail -Config $Config
        exit 0
    }
    Write-Log "Another watcher is already running for '$($Config.WatchFolder)'. Exiting." 'WARN'
    exit 0
}

if ($Live) {
    # Nothing else is running, so -Live becomes a real foreground watcher with visible output.
    # Closing this window DOES stop this instance -- but the scheduled task's self-heal trigger
    # brings the background watcher back within its repeat interval, so nothing stays broken.
    Write-Host ''
    Write-Host '  FilesZipWatcher -- LIVE (foreground; no background watcher was running)' -ForegroundColor Yellow
    Write-Host '  Closing this window stops THIS instance; the scheduled task self-heals within 15 min.' -ForegroundColor DarkGray
    Write-Host ''
}

# The single path we care about. O(1) checks -- never a directory enumeration.
$script:TargetPath = Join-Path $Config.WatchFolder $Config.WatchFileName
$script:Busy = $false

Write-Log '=== FilesZipWatcher starting ==='
Write-Log ("Watching  : {0}" -f $script:TargetPath)
Write-Log ("Extract to: {0}" -f $Config.ExtractTo)
Write-Log ("Stamp fmt : {0}  (e.g. {1})" -f $Config.TimestampFormat, (Get-Date -Format $Config.TimestampFormat))
Write-Log ("Power     : event-driven; safety sweep every {0}s" -f $Config.PollSeconds)

function Invoke-Check {
    param($Config)
    if ($script:Busy) { return }
    if (-not (Test-Path -LiteralPath $script:TargetPath)) { return }
    $script:Busy = $true
    try     { Invoke-ProcessZip -Path $script:TargetPath -Config $Config }
    catch   { Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR' }
    finally { $script:Busy = $false; Compress-Footprint }
}

function Get-OrphanArchive {
    <#
        A "files (1).zip" means Chrome had to dedupe -- i.e. the watcher was NOT running when
        that download landed. One directory read, startup only.
    #>
    param($Config)
    try {
        return @(Get-ChildItem -LiteralPath $Config.WatchFolder -Filter 'files (*.zip' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match $Config.OrphanWarnPattern })
    } catch { return @() }
}

function Invoke-StartupCatchUp {
    <#
        Startup-only sweep. Processes everything waiting in the watch folder -- the exact-name
        archive AND (when ProcessOrphansOnStartup) any Chrome dedupe orphans left behind while
        we were down. Steady-state detection is untouched: still one O(1) Test-Path on one path.

        ORDERING IS OLDEST-FIRST, and that is deliberate. Collisions are won by whichever
        archive extracts LAST, so the newest download must go last. Do NOT assume 'files.zip'
        is the newest -- Chrome only creates 'files (1).zip' *because* 'files.zip' already
        existed, so the orphan is normally the NEWER of the two. Sorting by LastWriteTime is
        the only ordering that is correct regardless of naming.
    #>
    param($Config)

    $orphans = @(Get-OrphanArchive -Config $Config)

    if (-not $Config.ProcessOrphansOnStartup) {
        foreach ($o in $orphans) {
            Write-Log ("Orphan found (watcher was down when it arrived): '{0}'. Not processed -- ProcessOrphansOnStartup is false. Rename it to '{1}' to have it handled." -f $o.Name, $Config.WatchFileName) 'WARN'
        }
        Invoke-Check -Config $Config
        return
    }

    $candidates = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $script:TargetPath) {
        try { [void]$candidates.Add((Get-Item -LiteralPath $script:TargetPath -Force)) } catch { }
    }
    foreach ($o in $orphans) { [void]$candidates.Add($o) }

    if ($candidates.Count -eq 0) { return }

    if ($orphans.Count -gt 0) {
        Write-Log ("Startup catch-up: {0} archive(s) waiting, {1} of them Chrome dedupe orphan(s) -- the watcher was down when those arrived." -f $candidates.Count, $orphans.Count) 'WARN'
    }

    $ordered = @($candidates | Sort-Object LastWriteTime)
    $n = 0
    foreach ($c in $ordered) {
        $n++
        if (-not (Test-Path -LiteralPath $c.FullName)) { continue }   # a prior iteration consumed it
        if ($ordered.Count -gt 1) {
            Write-Log ("Catch-up {0}/{1}: '{2}' (modified {3})" -f $n, $ordered.Count, $c.Name, $c.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
        }
        $script:Busy = $true
        try     { Invoke-ProcessZip -Path $c.FullName -Config $Config }
        catch   { Write-Log "Catch-up failed for '$($c.Name)': $($_.Exception.Message)" 'ERROR' }
        finally { $script:Busy = $false; Compress-Footprint }
    }
}

try {
    # Startup only: one directory read, then never again. Handles the exact-name archive and
    # any dedupe orphans together, oldest-first.
    Invoke-StartupCatchUp -Config $Config

    if ($Once) { Write-Log 'ONCE mode complete.'; exit 0 }

    # Filtered to the single filename -- the OS only signals us for this exact name.
    $fsw = New-Object IO.FileSystemWatcher $Config.WatchFolder, $Config.WatchFileName
    $fsw.IncludeSubdirectories = $false
    $fsw.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::Size
    $fsw.EnableRaisingEvents = $true

    Register-ObjectEvent $fsw Created -SourceIdentifier FZW_Created | Out-Null
    Register-ObjectEvent $fsw Renamed -SourceIdentifier FZW_Renamed | Out-Null

    Compress-Footprint
    # [double], not [int]: fractional values let the self-test exercise a real beat in seconds
    # instead of idling a minute. Users set whole minutes.
    $hbMin = [double]$Config.HeartbeatMinutes
    if ($hbMin -gt 0) { Write-Log ("Heartbeat : every {0} min (a silent log now means DEAD, not idle)" -f $hbMin) }
    Write-Log 'Watching. Idle until files.zip appears.' 'OK'

    $script:LastBeat = Get-Date

    while ($true) {
        # Blocks (no CPU) until an event fires or the long safety timeout elapses.
        $evt = Wait-Event -Timeout ([int]$Config.PollSeconds)
        if ($evt) { Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue }
        Invoke-Check -Config $Config

        # The whole point of A2: an abrupt external kill (taskkill, console close, 0xC000013A)
        # leaves NO log line at all, so previously a dead watcher and an idle one were
        # indistinguishable. Now the last beat brackets the death to within HeartbeatMinutes.
        if ($hbMin -gt 0 -and ((Get-Date) - $script:LastBeat).TotalMinutes -ge $hbMin) {
            Write-Log 'Heartbeat: alive, idle.'
            $script:LastBeat = Get-Date
        }

        if (-not $evt) { Compress-Footprint }   # periodic trim on the quiet path
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    Unregister-Event -SourceIdentifier FZW_Created -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier FZW_Renamed -ErrorAction SilentlyContinue
    # Releases the single-instance lock. The OS would do this anyway on process death (including
    # a hard kill), which is exactly why a lock FILE is safer than a named mutex here.
    if ($lock) { try { $lock.Dispose() } catch { } }
    Write-Log '=== FilesZipWatcher stopped ==='
}
