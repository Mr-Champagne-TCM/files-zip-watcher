<#
.SYNOPSIS
    End-to-end self-test for FilesZipWatcher. Safe: runs entirely in a temp sandbox,
    never touches your real Downloads folder.

.DESCRIPTION
    Builds a synthetic files.zip containing a plain file, a nested folder, a file that will
    collide with an existing one, and a malicious zip-slip entry. Runs the watcher in -Once
    mode against a sandbox config, then asserts the outcome.

.EXAMPLE
    .\tests\Invoke-SelfTest.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$Root    = Split-Path $PSScriptRoot -Parent
$Watcher = Join-Path $Root 'src\FilesZipWatcher.ps1'

$pass = 0; $fail = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else            { $script:fail++; Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red }
}

# --- sandbox -------------------------------------------------------------
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("fzw-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
$watch   = Join-Path $sandbox 'Downloads'
$logs    = Join-Path $sandbox 'logs'
New-Item -ItemType Directory -Force -Path $watch, $logs | Out-Null
Write-Host "Sandbox: $sandbox`n" -ForegroundColor Cyan

try {
    # Pre-existing file that the archive should OVERWRITE
    Set-Content -Path (Join-Path $watch 'collide.txt') -Value 'ORIGINAL' -Encoding UTF8

    # --- build synthetic files.zip ---------------------------------------
    $staging = Join-Path $sandbox 'staging'
    New-Item -ItemType Directory -Force -Path (Join-Path $staging 'nested') | Out-Null
    Set-Content (Join-Path $staging 'hello.txt')        'hello world' -Encoding UTF8
    Set-Content (Join-Path $staging 'collide.txt')      'FROM_ZIP'    -Encoding UTF8
    Set-Content (Join-Path $staging 'nested\deep.txt')  'deep'        -Encoding UTF8

    $zipPath = Join-Path $watch 'files.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipPath)

    # Append a zip-slip entry that tries to escape the destination
    $fs = [IO.File]::Open($zipPath, 'Open', 'ReadWrite')
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Update)
    $evil = $za.CreateEntry('..\..\evil.txt')
    $sw = New-Object IO.StreamWriter($evil.Open()); $sw.Write('pwned'); $sw.Close()
    $za.Dispose(); $fs.Close()

    Assert-That 'synthetic files.zip created' (Test-Path $zipPath)

    # --- sandbox config --------------------------------------------------
    $cfg = Join-Path $sandbox 'config.json'
    @{
        WatchFolder = $watch; ExtractTo = $watch; LogDir = $logs
        MatchPattern = '^files(?: \(\d+\))?\.zip$'
        TimestampFormat = 'yyyy-MM-dd-HH-mm'; RenamePrefix = 'files-'
        KeepZipAfterExtract = $true; Overwrite = $true
        StableSeconds = 1; StableChecks = 1; PollSeconds = 1; SettleTimeoutSeconds = 60
        LogRetentionDays = 1
    } | ConvertTo-Json | Set-Content $cfg -Encoding UTF8

    # --- run -------------------------------------------------------------
    Write-Host "`nRunning watcher (-Once)...`n" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Watcher -ConfigPath $cfg -Once | Out-Null

    # --- assertions ------------------------------------------------------
    Write-Host "`nResults:" -ForegroundColor Cyan
    $renamed = Get-ChildItem $watch -Filter 'files-*.zip' -File

    Assert-That 'original files.zip no longer present'  (-not (Test-Path $zipPath))
    Assert-That 'renamed to files-<stamp>.zip'          ($renamed.Count -eq 1) "found $($renamed.Count)"
    if ($renamed.Count -eq 1) {
        Assert-That 'stamp matches yyyy-MM-dd-HH-mm'    ($renamed[0].Name -match '^files-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}\.zip$') $renamed[0].Name
    }
    Assert-That 'hello.txt extracted flat'              (Test-Path (Join-Path $watch 'hello.txt'))
    Assert-That 'nested structure preserved'            (Test-Path (Join-Path $watch 'nested\deep.txt'))
    Assert-That 'collision overwritten'                 ((Get-Content (Join-Path $watch 'collide.txt') -Raw).Trim() -eq 'FROM_ZIP')
    Assert-That 'NO wrapper folder created'             (-not (Test-Path (Join-Path $watch ($renamed[0].BaseName))))
    Assert-That 'zip-slip entry refused'                (-not (Test-Path (Join-Path $sandbox '..\evil.txt'))) 'evil.txt escaped!'
    Assert-That 'log file written'                      ((Get-ChildItem $logs -Filter '*.log' -EA SilentlyContinue).Count -ge 1)

    # non-matching archive must be ignored
    Copy-Item $renamed[0].FullName (Join-Path $watch 'somethingelse.zip')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Watcher -ConfigPath $cfg -Once | Out-Null
    Assert-That 'non-matching zip ignored'              (Test-Path (Join-Path $watch 'somethingelse.zip'))

    Write-Host ""
    if ($fail -eq 0) { Write-Host "ALL $pass CHECKS PASSED" -ForegroundColor Green }
    else             { Write-Host "$pass passed, $fail FAILED" -ForegroundColor Red }
}
finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Sandbox cleaned up."
}

if ($fail -gt 0) { exit 1 }
