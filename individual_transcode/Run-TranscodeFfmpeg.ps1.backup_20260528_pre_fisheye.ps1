#Requires -Version 5.1
<#
.SYNOPSIS
  Transcode media with ffmpeg; default -ss from HKCU DAUM RememberFiles last-played position.
  Quick seek override: press 0/1/2/3/4 within 5s for 0/10/15/30/45 min (or wait for registry resume).

.NOTES
  Mutex behavior: this script enforces a global transcode mutex named Local\FfmpegAvsTranscodeLock so only one transcode
  run executes at a time across orchestrator child launches, context-menu launches, and manual invocations.
  If multiple orchestrators are used, orchestrator-level per-playlist mutexes prevent duplicate queue runners while this
  mutex remains the process-wide final gate for ffmpeg execution.

  Prefer wifi 6E (6Ghz) network if available!
  Wait for ffmpeg to output the first segment file!
  Output folder contains '_fullsbs_' for Skybox 3D auto-detection (restart playback to fix full SBS match glitch)!
  For .avs: finds source two folders up (..\\..\\); basename drops StreamTo3D., optional embedded media ext
  (e.g. .mp4 in name.mp4.avs), then .avs; ffprobe: first video stream height < 1080 -> -re; for that source,
  format bit_rate < 2500 kbps also -> -re. Seek (-ss) is checked against ffprobe format=duration on the same probe path
  unless -NoClampSeek: if resume is past the usable end (duration minus 0.25s tail), ffmpeg is skipped (exit 0) so the
  orchestrator can treat the clip as done and continue the playlist. Pass -NoClampSeek to send the raw seek to ffmpeg instead.
  By default a transcript is appended under .\transcode_logs\ next to
  before starting so the same path can be reused (wrap / rotate).
  Log and failure-summary paths are rooted at this script's folder (directory of the .ps1 file that PowerShell loaded),
  not at Get-Location / Explorer's working directory—so logs always sit beside the copy of Run-TranscodeFfmpeg.ps1 that
  actually ran. If you duplicate scripts to another drive or tree but Explorer still launches an older path, logs stay
  under that older path: re-run Install-ContextMenu.ps1 from the folder whose launcher you want, or pass an explicit
  -TranscodeScript to the orchestrator. After a successful context-menu .avs transcode, the follow-up orchestrator is
  started with -TranscodeScript set to this same script file's full path, so queued child transcodes keep using that
  same transcode_logs\ root until the registered launcher or -TranscodeScript changes.
  Explorer context menu (-ContextMenu or parent explorer.exe): after a successful .avs transcode, runs
  Run-TranscodeOrchestrator.ps1 (playlist.m3u beside orchestrator in the parent folder, or found walking up from .avs)
  with -SkipPotPlayer and -SkipCompanionBinaries so the orchestrator does not spawn PotPlayer for the DPL preview gate or
  relaunch AutoHotkey companions on that handover.
  Queue order uses M3U
  plus playlist.m3u.transcode_queue_last / optional # transcode-queue-last: lines; per-clip ffmpeg -ss still uses RememberFiles registry lookup.
  This script reads PotPlayer/DAUM RememberFiles for resume seek but does not write/update PotPlayer registry entries.
  New seek positions are only updated by PotPlayer itself when media is played there.
  If this process ends with exit code -1073741510 (0xC000013A, STATUS_CONTROL_C_EXIT), Windows aborted the session
  (e.g. you closed this console or Ctrl+C); the orchestrator documents the same code when a child transcode window is closed.
  Safety timeout: this script is capped at 1.5 hours (5400s), including mutex wait and ffmpeg runtime. On timeout it
  stops ffmpeg process tree if running and exits with code 124.
  With -NoLogFile, any non-zero exit still appends a short block to transcode_logs\transcode_failures.log (timestamp,
  input path, exit code, ffmpeg command when built) for later review without a full transcript. That file does not
  capture ffmpeg stderr or host output—only the echoed command line. For full ffmpeg and console traces, run the same
  clip once without -NoLogFile so Start-Transcript records everything under transcode_logs\.

.PARAMETER LiteralPath
  Input file path (context menu passes this). If omitted, script tries clipboard text.

.PARAMETER SsMsOverride
  Seek in milliseconds when >= 0. Default -1 reads RememberFiles registry position (else 0 ms).

.PARAMETER OutputDirectory
  Output folder. Default: F:\f1_media\3d_fullsbs_trans. The file name pattern is fixed
  (see $HardcodedOutputFilePattern below).

.PARAMETER NoPause
  Do not wait 5 seconds before exiting (default: wait once at the end). Orchestrator passes this on child runs.

.PARAMETER ContextMenu
  Set when launched from Explorer context menu (Install-ContextMenu.ps1). After a successful .avs transcode,
  runs Run-TranscodeOrchestrator.ps1 (if found with playlist.m3u in the same folder as the orchestrator) after releasing
  the transcode mutex, passing -SkipPotPlayer and -SkipCompanionBinaries on that handover.

.PARAMETER SkipOrchestrator
  Suppress post-transcode orchestrator (used when this script is spawned by the orchestrator).

.PARAMETER NoClampSeek
  Do not compare resume seek to ffprobe duration (default: if seek is past usable end, skip ffmpeg with exit 0; otherwise transcode).
  With this switch, the raw seek is passed to ffmpeg even past EOF (may error or behave oddly).

.PARAMETER LogFile
  Transcript path (Start-Transcript -Append). Relative paths resolve from this script's directory (not the process
  current directory). Default when omitted: transcode_logs\transcode_yyyyMMdd_HHmmss_pid.log under this script's folder.
  If the log file already exists and is over 2 MB, it is removed so the next transcript starts fresh at the same path.

.PARAMETER NoLogFile
  Disable transcript logging (overrides default log under transcode_logs). On any non-zero exit, a short summary
  (timestamp, input, exit code, ffmpeg command line when reached) is still appended to transcode_logs\transcode_failures.log.
  That summary does not include ffmpeg stderr; omit -NoLogFile (or pass -LogFile) when you need a full diagnostic transcript.

.PARAMETER OrchestratorPid
  Optional parent orchestrator PID. When provided (with OrchestratorStartTimeUtc), this script monitors parent liveness
  and cancels ffmpeg if that exact orchestrator process disappears (e.g. window closed).

.PARAMETER OrchestratorStartTimeUtc
  ISO-8601 UTC start timestamp for the parent orchestrator process. Used with OrchestratorPid to avoid PID reuse mismatch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $LiteralPath,
    [string] $OutputDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [int] $SsMsOverride = -1,
    [string] $Ffmpeg = 'ffmpeg',
    [string] $LogFile = '',
    [switch] $NoLogFile,
    [switch] $DryRun,
    [switch] $NoPause,
    [switch] $ContextMenu,
    [switch] $SkipOrchestrator,
    [switch] $NoClampSeek,
    [int] $OrchestratorPid = 0,
    [string] $OrchestratorStartTimeUtc = ''
)

$ErrorActionPreference = 'Stop'
$script:ExitCodeTimeout = 124
$script:TranscodeTimeoutSeconds = 5400
$thisScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    [System.IO.Path]::GetFullPath($PSCommandPath)
} else {
    [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
}

# Segmented output pattern; ffmpeg rotates 3 segment files
$HardcodedOutputFilePattern = '3d_op_%02d.mkv'
$InstanceMutexName = 'Local\FfmpegAvsTranscodeLock'
$TranscodeLogMaxBytes = 2L * 1024L * 1024L

# Strip trailing media token from .avs basename before ..\..\ match; longest first (.m2ts before .ts)
$AvsLinkedSourceMediaExtensions = @(
    '.mp4', '.mkv', '.avi', '.m2ts', '.ts', '.mov', '.wmv', '.m4v', '.webm',
    '.mpeg', '.mpg', '.divx'
)
$AvsLinkedSourceMediaExtensionsLongFirst = @($AvsLinkedSourceMediaExtensions | Sort-Object { $_.Length } -Descending)

function Normalize-MatchPath {
    param([string] $P)
    if ([string]::IsNullOrWhiteSpace($P)) { return '' }
    try {
        return [System.IO.Path]::GetFullPath($P).ToLowerInvariant()
    } catch {
        return $P.Trim().ToLowerInvariant()
    }
}

function Get-RemainingTimeoutMs {
    param([datetime] $TimeoutAtUtc)
    $remaining = [int64][Math]::Floor(($TimeoutAtUtc - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -lt 0) { return 0 }
    if ($remaining -gt [int64][int]::MaxValue) { return [int]::MaxValue }
    return [int]$remaining
}

function ConvertFrom-RememberLine {
    param([object] $Data)
    if ($null -eq $Data) { return $null }
    [string] $s = $null
    if ($Data -is [byte[]]) {
        $b = [byte[]]$Data
        if ($b.Length -eq 0) { return $null }
        try {
            $s = [Text.Encoding]::Unicode.GetString($b).TrimEnd([char]0)
        } catch {
            $s = [Text.Encoding]::UTF8.GetString($b)
        }
    } else {
        $s = [string]$Data
    }
    $s = $s.Trim()
    if ($s -notmatch '^(\d+)=(.*)$') { return $null }
    return @{
        Ms   = [int64]$Matches[1]
        Path = $Matches[2].Trim().Trim('"')
    }
}

function Get-RememberEntries {
    $list = New-Object System.Collections.Generic.List[object]
    $rememberFilesRegistryPath = 'SOFTWARE\DAUM\PotPlayerMini64\RememberFiles'
    $reg = $null
    try {
        $reg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($rememberFilesRegistryPath)
        if (-not $reg) { return $list }

        foreach ($name in $reg.GetValueNames()) {
            if ($name -eq 'MRUList') { continue }
            $val = $reg.GetValue($name)
            $parsed = ConvertFrom-RememberLine $val
            if ($parsed) { [void]$list.Add($parsed) }
        }

        foreach ($skName in $reg.GetSubKeyNames()) {
            $sk = $reg.OpenSubKey($skName)
            if ($sk) {
                try {
                    $val = $sk.GetValue('', $null)
                    $parsed = ConvertFrom-RememberLine $val
                    if ($parsed) { [void]$list.Add($parsed) }
                } finally {
                    $sk.Dispose()
                }
            }
        }
    } finally {
        if ($reg) { $reg.Dispose() }
    }
    return $list
}

function Get-SeekMsForRememberedPath {
    param([string] $TargetPath)
    $want = Normalize-MatchPath $TargetPath
    $bestMs = 0L
    $bestLen = -1
    foreach ($e in Get-RememberEntries) {
        if ((Normalize-MatchPath $e.Path) -eq $want) {
            $len = $e.Path.Length
            if ($len -gt $bestLen) {
                $bestLen = $len
                $bestMs = $e.Ms
            }
        }
    }
    return [Math]::Max(0L, $bestMs)
}

function Get-QuickSeekOverrideMs {
    [OutputType([Nullable[int64]])]
    param()

    Write-Host 'Quick seek override: press 0/1/2/3/4 within 5s for 0/10/15/30/45 min (or wait for registry resume).'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.KeyChar) {
                    '0' { return 0L }
                    '1' { return 10L * 60L * 1000L }
                    '2' { return 15L * 60L * 1000L }
                    '3' { return 30L * 60L * 1000L }
                    '4' { return 45L * 60L * 1000L }
                    default { return $null }
                }
            }
        } catch {
            # No interactive console available; skip override.
            return $null
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Get-AvsRemainderBaseName {
    param([string] $AvsFullPath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($AvsFullPath)
    $prefix = 'StreamTo3D.'
    if ($base.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $base = $base.Substring($prefix.Length)
    }
    foreach ($ext in $AvsLinkedSourceMediaExtensionsLongFirst) {
        if ($base.EndsWith($ext, [StringComparison]::OrdinalIgnoreCase)) {
            return $base.Substring(0, $base.Length - $ext.Length)
        }
    }
    return $base
}

function Find-SourceMediaInAvsGrandparent {
    param(
        [string] $AvsFullPath,
        [string] $Remainder
    )
    if ([string]::IsNullOrWhiteSpace($Remainder)) {
        return $null
    }
    $avsDir = [System.IO.Path]::GetDirectoryName($AvsFullPath)
    $searchRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($avsDir, '..\..'))
    if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
        Write-Warning "Source search folder not found: $searchRoot"
        return $null
    }

    $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $AvsLinkedSourceMediaExtensions) { [void]$allowed.Add($e) }

    $files = @(Get-ChildItem -LiteralPath $searchRoot -File -ErrorAction Stop | Where-Object { $allowed.Contains($_.Extension) })
    $exact = @($files | Where-Object { $_.BaseName -eq $Remainder })
    if ($exact.Count -ge 1) {
        if ($exact.Count -gt 1) {
            Write-Warning "Multiple files with basename '$Remainder' in $searchRoot; using: $($exact[0].FullName)"
        }
        return $exact[0].FullName
    }

    $partial = $files | Where-Object {
        $_.BaseName.IndexOf($Remainder, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } | Select-Object -First 1

    if ($partial) {
        Write-Host "Matched source by substring: $($partial.FullName)"
        return $partial.FullName
    }

    Write-Warning "No source media found for remainder '$Remainder' under $searchRoot"
    return $null
}

function Get-FfprobeExePath {
    param([string] $FfmpegExe)
    $dir = [System.IO.Path]::GetDirectoryName($FfmpegExe)
    $candidate = Join-Path $dir 'ffprobe.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    return $null
}

function Get-FormatBitrateBps {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = & $FfprobeExe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq 'N/A') {
        return $null
    }
    $n = 0L
    if (-not [int64]::TryParse($s, [ref]$n)) {
        return $null
    }
    if ($n -le 0) {
        return $null
    }
    return $n
}

function Get-VideoStreamHeight {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = & $FfprobeExe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
    if ($null -eq $raw) { return $null }
    foreach ($line in @($raw)) {
        $s = ([string]$line).Trim()
        if ($s -eq '' -or $s -eq 'N/A') { continue }
        $n = 0
        if ([int32]::TryParse($s, [ref]$n) -and $n -gt 0) {
            return $n
        }
    }
    return $null
}

function Get-FormatDurationSeconds {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = & $FfprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq 'N/A') {
        return $null
    }
    $n = 0.0
    if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $null
    }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -le 0) {
        return $null
    }
    return $n
}

function Test-InvokedFromExplorerShell {
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        $ppid = [int]$me.ParentProcessId
        if ($ppid -le 0) { return $false }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction Stop
        return ($null -ne $parent.Name -and $parent.Name.Equals('explorer.exe', [StringComparison]::OrdinalIgnoreCase))
    } catch {
        return $false
    }
}

function Find-OrchestratorPlaylistBundle {
    param(
        [string] $AvsFullPath,
        [string] $TranscodeScriptFullPath
    )
    $avsDir = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($AvsFullPath))
    $cur = $avsDir
    for ($depth = 0; $depth -lt 12; $depth++) {
        $orch = Join-Path $cur 'Run-TranscodeOrchestrator.ps1'
        $pl = Join-Path $cur 'playlist.m3u'
        if ((Test-Path -LiteralPath $orch) -and (Test-Path -LiteralPath $pl)) {
            return @{
                OrchestratorScript = [System.IO.Path]::GetFullPath($orch)
                PlaylistFile       = [System.IO.Path]::GetFullPath($pl)
                AvsFolder          = $avsDir
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { break }
        $cur = $parent
    }
    $td = [System.IO.Path]::GetDirectoryName($TranscodeScriptFullPath)
    $repoParent = [System.IO.Path]::GetDirectoryName($td)
    $orchRepo = Join-Path $repoParent 'Run-TranscodeOrchestrator.ps1'
    if (Test-Path -LiteralPath $orchRepo) {
        $plSibling = Join-Path $repoParent 'playlist.m3u'
        $plResolved = ''
        if (Test-Path -LiteralPath $plSibling) {
            $plResolved = [System.IO.Path]::GetFullPath($plSibling)
        }
        return @{
            OrchestratorScript = [System.IO.Path]::GetFullPath($orchRepo)
            PlaylistFile       = $plResolved
            AvsFolder          = $avsDir
        }
    }
    return $null
}

function Get-HostPowerShellExeForOrchestrator {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return (Get-Command pwsh -ErrorAction Stop).Source
    }
    return (Get-Command powershell -ErrorAction Stop).Source
}

function Stop-ProcessTreeByPid {
    param([int] $PidToKill)
    if ($PidToKill -le 0) { return }
    try {
        & taskkill.exe /PID $PidToKill /T /F 2>$null | Out-Null
    } catch {
        try { Stop-Process -Id $PidToKill -Force -ErrorAction Stop } catch { }
    }
}

function Test-OrchestratorStillAlive {
    param(
        [int] $OrchProcessId,
        [string] $ExpectedStartUtc
    )
    if ($OrchProcessId -le 0) { return $true }
    try {
        $p = Get-Process -Id $OrchProcessId -ErrorAction Stop
    } catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedStartUtc)) { return $true }
    try {
        $expected = [datetime]::Parse($ExpectedStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $actual = $p.StartTime.ToUniversalTime()
        if ([Math]::Abs(($actual - $expected).TotalSeconds) -gt 2.0) {
            return $false
        }
    } catch {
        # If parse fails, fall back to PID-only check.
    }
    return $true
}

function Write-TranscodeFailureAppendLog {
    # Appends a small text block only (no ffmpeg stderr); full traces require transcript (omit -NoLogFile).
    param(
        [string] $ScriptDir,
        [string] $InputPath,
        [int] $Code,
        [string] $FfmpegCommandLine
    )
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptDir)) { return }
        $logsRoot = Join-Path $ScriptDir 'transcode_logs'
        [void][System.IO.Directory]::CreateDirectory($logsRoot)
        $path = Join-Path $logsRoot 'transcode_failures.log'
        $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $sep = ('=' * 72)
        $lines = @(
            $sep,
            "$when | exit=$Code",
            "input: $InputPath"
        )
        if (-not [string]::IsNullOrWhiteSpace($FfmpegCommandLine)) {
            $lines += "ffmpeg: $FfmpegCommandLine"
        }
        $lines += $sep
        Add-Content -LiteralPath $path -Value ($lines -join [Environment]::NewLine) -Encoding utf8
        Write-Host "Failure summary appended to: $path"
    } catch {
        Write-Warning "Could not write transcode_failures.log: $_"
    }
}

function New-FfmpegProcessLogPaths {
    param(
        [string] $ScriptPath,
        [string] $InputPath
    )
    $scriptDir = [System.IO.Path]::GetDirectoryName($ScriptPath)
    $logsRoot = Join-Path $scriptDir 'transcode_logs'
    [void][System.IO.Directory]::CreateDirectory($logsRoot)
    $ffmpegRoot = Join-Path $logsRoot 'ffmpeg_process'
    [void][System.IO.Directory]::CreateDirectory($ffmpegRoot)

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeStem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    if ([string]::IsNullOrWhiteSpace($safeStem)) { $safeStem = 'input' }
    $safeStem = [regex]::Replace($safeStem, '[^\w\.\-]+', '_')
    if ($safeStem.Length -gt 80) { $safeStem = $safeStem.Substring(0, 80) }
    $base = "${stamp}_${PID}_${safeStem}"
    return @{
        StdOut = Join-Path $ffmpegRoot ($base + '.stdout.log')
        StdErr = Join-Path $ffmpegRoot ($base + '.stderr.log')
    }
}

function Get-RobustProcessExitCode {
    param([System.Diagnostics.Process] $Process)
    if ($null -eq $Process) { return $null }
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $Process.Refresh()
            $raw = $Process.ExitCode
            if ($null -ne $raw) { return [int]$raw }
        } catch { }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Test-FfmpegAppearsSuccessfulFromStderr {
    param([string] $StdErrPath)
    if ([string]::IsNullOrWhiteSpace($StdErrPath)) { return $false }
    if (-not (Test-Path -LiteralPath $StdErrPath -PathType Leaf)) { return $false }
    try {
        $tail = Get-Content -LiteralPath $StdErrPath -Tail 120 -ErrorAction Stop
        if (-not $tail) { return $false }
        $joined = ($tail -join "`n")
        if ($joined -match '(?im)^\s*frame=.*\bLsize=' -or $joined -match '(?im)^\s*\[out#0/.+\]\s+video:') {
            if ($joined -notmatch '(?im)\berror\b|\bfailed\b|\binvalid\b|\bcannot\b') {
                return $true
            }
        }
    } catch { }
    return $false
}

$exitCode = 0
$instanceMutex = $null
$ownsMutex = $false
$orchestratorFollowUp = $null
$transcriptActive = $false
$failureLogCommandLine = $null
$lockOwnerPath = $null
$ffmpegStdOutLogPath = $null
$ffmpegStdErrLogPath = $null
$transcodeTimeoutAtUtc = [DateTime]::UtcNow.AddSeconds($script:TranscodeTimeoutSeconds)
Write-Host "Transcode timeout: $($script:TranscodeTimeoutSeconds)s"
try {
    $instanceMutex = New-Object System.Threading.Mutex($false, $InstanceMutexName)
    $scriptDirForLock = [System.IO.Path]::GetDirectoryName($thisScriptPath)
    $lockOwnerPath = [System.IO.Path]::Combine($scriptDirForLock, 'transcode_logs', 'transcode_lock_owner.txt')
    $alreadyRunning = $false
    try {
        $alreadyRunning = -not $instanceMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        # Previous owner crashed; we still gain ownership.
        $ownsMutex = $true
    }

    if (-not $ownsMutex) {
        if ($alreadyRunning) {
            Write-Host 'Another transcode run is active. Waiting for turn...'
            try {
                if (Test-Path -LiteralPath $lockOwnerPath) {
                    $who = Get-Content -LiteralPath $lockOwnerPath -ErrorAction SilentlyContinue
                    if ($who) {
                        Write-Host "Lock owner file: $lockOwnerPath"
                        Write-Host ($who -join [Environment]::NewLine)
                    }
                }
            } catch { }
        }
        try {
            $remainingMs = Get-RemainingTimeoutMs -TimeoutAtUtc $transcodeTimeoutAtUtc
            if ($remainingMs -le 0) {
                Write-Warning "Transcode timeout reached while waiting for mutex: $InstanceMutexName"
                $exitCode = $script:ExitCodeTimeout
                return
            }
            $acquired = $instanceMutex.WaitOne($remainingMs, $false)
            if (-not $acquired) {
                Write-Warning "Timed out waiting for mutex after $($script:TranscodeTimeoutSeconds)s: $InstanceMutexName"
                $exitCode = $script:ExitCodeTimeout
                return
            }
            $ownsMutex = $true
            if ($alreadyRunning) {
                Write-Host 'Lock acquired. Starting queued transcode now.'
            }
        } catch [System.Threading.AbandonedMutexException] {
            # Previous owner crashed; we still gain ownership.
            $ownsMutex = $true
            if ($alreadyRunning) {
                Write-Host 'Recovered abandoned lock. Starting queued transcode now.'
            }
        }
    }
    if ($ownsMutex) {
        try {
            $lockDir = [System.IO.Path]::GetDirectoryName($lockOwnerPath)
            [void][System.IO.Directory]::CreateDirectory($lockDir)
            $lines = @(
                "mutex=$InstanceMutexName",
                "pid=$PID",
                "startUtc=$((Get-Process -Id $PID -ErrorAction SilentlyContinue).StartTime.ToUniversalTime().ToString('o'))",
                "script=$thisScriptPath",
                "input=$LiteralPath"
            )
            Set-Content -LiteralPath $lockOwnerPath -Value $lines -Encoding utf8
        } catch { }
    }

    if (-not $NoLogFile) {
        try {
            $scriptDir = [System.IO.Path]::GetDirectoryName($thisScriptPath)
            if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
                $logFull = if ([System.IO.Path]::IsPathRooted($LogFile)) {
                    [System.IO.Path]::GetFullPath($LogFile)
                } else {
                    [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, $LogFile))
                }
            } else {
                $logsRoot = Join-Path $scriptDir 'transcode_logs'
                $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $logFull = Join-Path $logsRoot "transcode_${stamp}_$PID.log"
            }
            $logDir = [System.IO.Path]::GetDirectoryName($logFull)
            if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory($logDir)
            }
            if ((Test-Path -LiteralPath $logFull) -and ((Get-Item -LiteralPath $logFull).Length -gt $TranscodeLogMaxBytes)) {
                Remove-Item -LiteralPath $logFull -Force -ErrorAction Stop
                Write-Host "Log file exceeded 2 MB; rotated (fresh file at same path)."
            }
            Start-Transcript -Path $logFull -Append -ErrorAction Stop
            $transcriptActive = $true
            Write-Host "Transcript logging appended to: $logFull"
        } catch {
            Write-Warning "Transcript logging failed; continuing without file log: $_"
        }
    }

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        try {
            $clip = Get-Clipboard -Raw -ErrorAction Stop
            if ($null -ne $clip) {
                $LiteralPath = ([string]$clip).Trim()
            }
        } catch {
            # Clipboard unavailable in this host/session; keep fallback error below.
        }
    }

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        Write-Error 'Input path not provided and clipboard is empty.'
        $exitCode = 2
        if ($NoLogFile) {
            Write-TranscodeFailureAppendLog -ScriptDir ([System.IO.Path]::GetDirectoryName($thisScriptPath)) `
                -InputPath '(no input path)' -Code $exitCode -FfmpegCommandLine $null
        }
        return
    }

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        Write-Error "Input not found: $LiteralPath"
        $exitCode = 2
        if ($NoLogFile) {
            Write-TranscodeFailureAppendLog -ScriptDir ([System.IO.Path]::GetDirectoryName($thisScriptPath)) `
                -InputPath $LiteralPath -Code $exitCode -FfmpegCommandLine $null
        }
        return
    }

    $fullInput = [System.IO.Path]::GetFullPath($LiteralPath)

    if ($SsMsOverride -ge 0) {
        $ssMs = [int64]$SsMsOverride
    } else {
        $ssMs = Get-SeekMsForRememberedPath $fullInput
        $quickSeekOverrideMs = Get-QuickSeekOverrideMs
        if ($null -ne $quickSeekOverrideMs) {
            $ssMs = [int64]$quickSeekOverrideMs
        }
    }

    $root = [System.IO.Path]::GetFullPath($OutputDirectory)
    $outPath = Join-Path $root $HardcodedOutputFilePattern

    $outDir = [System.IO.Path]::GetDirectoryName($outPath)
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $ffmpegExe = $Ffmpeg
    if (-not [System.IO.Path]::IsPathRooted($ffmpegExe)) {
        $cmdFfmpeg = Get-Command $ffmpegExe -ErrorAction SilentlyContinue
        if (-not $cmdFfmpeg) {
            Write-Error "ffmpeg not found: $Ffmpeg"
            $exitCode = 1
            if ($NoLogFile) {
                Write-TranscodeFailureAppendLog -ScriptDir ([System.IO.Path]::GetDirectoryName($thisScriptPath)) `
                    -InputPath $LiteralPath -Code $exitCode -FfmpegCommandLine $null
            }
            return
        }
        $ffmpegExe = $cmdFfmpeg.Source
    }

    # -re: first video stream height < 1080 (any input; .avs probes resolved source if found else .avs path);
    #       plus .avs + resolved source: format bit_rate < 2500 kbps
    $useReInput = $false
    $ffprobeExe = Get-FfprobeExePath $ffmpegExe
    $sourceMedia = $null
    if ($fullInput.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
        $remainder = Get-AvsRemainderBaseName $fullInput
        $sourceMedia = Find-SourceMediaInAvsGrandparent -AvsFullPath $fullInput -Remainder $remainder
    }
    $probePath = if ($sourceMedia) { $sourceMedia } else { $fullInput }

    if (-not $ffprobeExe) {
        Write-Warning 'ffprobe not found (install with ffmpeg or on PATH); skipping height/bitrate -re rules.'
    } else {
        $vidHeight = Get-VideoStreamHeight -MediaPath $probePath -FfprobeExe $ffprobeExe
        if ($null -ne $vidHeight) {
            if ($vidHeight -lt 1080) {
                $useReInput = $true
                Write-Host "Video height $vidHeight px (< 1080) -> using -re"
            } else {
                Write-Host "Video height $vidHeight px (>= 1080) -> not using -re from height rule"
            }
        } else {
            Write-Warning "Could not read video stream height for: $probePath"
        }

        if ($fullInput.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase) -and $sourceMedia) {
            $bps = Get-FormatBitrateBps -MediaPath $sourceMedia -FfprobeExe $ffprobeExe
            if ($null -eq $bps) {
                Write-Warning "Could not read format bit_rate for: $sourceMedia"
            } else {
                $kbps = [double]$bps / 1000.0
                $thresholdBps = 2500L * 1000L
                if ($bps -lt $thresholdBps) {
                    $useReInput = $true
                    Write-Host "Source total bitrate ~ $([math]::Round($kbps)) kbps (< 2500 kbps) -> using -re"
                } else {
                    Write-Host "Source total bitrate ~ $([math]::Round($kbps)) kbps (>= 2500 kbps) -> not using -re from bitrate rule"
                }
            }
        }
    }

    $transcodeSkippedSeekPastEnd = $false
    if (-not $NoClampSeek -and $ffprobeExe -and -not [string]::IsNullOrWhiteSpace($probePath)) {
        $durSec = Get-FormatDurationSeconds -MediaPath $probePath -FfprobeExe $ffprobeExe
        if ($null -ne $durSec) {
            $tailSec = 0.25
            $maxStartSec = [Math]::Max(0.0, $durSec - $tailSec)
            $reqSec = [double]$ssMs / 1000.0
            if ($reqSec -gt $maxStartSec) {
                Write-Host "Resume seek $([math]::Round($reqSec, 3)) s ($ssMs ms) is at or past usable end (duration $([math]::Round($durSec, 3)) s; last $($tailSec)s not transcoded). Skipping ffmpeg (exit 0) so the queue can advance."
                $transcodeSkippedSeekPastEnd = $true
            }
        }
    }

    if (-not $transcodeSkippedSeekPastEnd) {
    $ssSec = [double]$ssMs / 1000.0
    $ssMin = $ssSec / 60.0
    $fmtSec = $ssSec.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)

    $argList = @(
        '-hide_banner', '-y',
        '-ss', $fmtSec
    )
    if ($useReInput) {
        $argList += '-re'
    }
    $argList += @(
        '-i', $fullInput,
        '-map', '0:v',
        # Audio may be absent for some sources; map optionally.
        '-map', '0:a?',
        '-c:v', 'av1_qsv',
        '-preset', 'slow',
        '-global_quality', '18',
        '-rc', 'cbr',
        '-b:v', '50M',
        '-maxrate', '50M',
        '-c:a', 'copy',
        '-f', 'segment',
        '-segment_time', '60',
        '-segment_wrap', '2',
        '-reset_timestamps', '1',
        $outPath
    )
    $all = @($ffmpegExe) + $argList
    $commandLine = ($all | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '

    Write-Host "Resume (-ss): $([math]::Round($ssMin, 4)) min | $([math]::Round($ssSec, 3)) s ($ssMs ms) -> $outPath"
    Write-Host "FFmpeg command: $commandLine"

    if ($DryRun) {
        Write-Host $commandLine
        $exitCode = 0
        return
    }

    $failureLogCommandLine = $commandLine
    $parentLost = $false
    if ($OrchestratorPid -gt 0) {
        Write-Host "Watching orchestrator: pid=$OrchestratorPid startUtc='$OrchestratorStartTimeUtc'"
    }
    $ffmpegChildLogs = New-FfmpegProcessLogPaths -ScriptPath $thisScriptPath -InputPath $fullInput
    $ffmpegStdOutLogPath = $ffmpegChildLogs.StdOut
    $ffmpegStdErrLogPath = $ffmpegChildLogs.StdErr
    Write-Host "FFmpeg stdout log: $ffmpegStdOutLogPath"
    Write-Host "FFmpeg stderr log: $ffmpegStdErrLogPath"
    # IMPORTANT: Start-Process joins string[] without proper quoting; build one quoted argument line.
    $ffArgLine = ($argList | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
    $ffProc = Start-Process -FilePath $ffmpegExe -ArgumentList $ffArgLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $ffmpegStdOutLogPath -RedirectStandardError $ffmpegStdErrLogPath
    while ($true) {
        if ([DateTime]::UtcNow -ge $transcodeTimeoutAtUtc) {
            Write-Warning "Transcode timeout reached ($($script:TranscodeTimeoutSeconds)s). Stopping ffmpeg process tree..."
            Stop-ProcessTreeByPid -PidToKill $ffProc.Id
            $exitCode = $script:ExitCodeTimeout
            break
        }
        $exited = $false
        try {
            $ffProc.Refresh()
            $exited = $ffProc.HasExited
        } catch {
            # If we can't query, assume it exited.
            $exited = $true
        }
        if ($exited) { break }
        if (-not (Test-OrchestratorStillAlive -OrchProcessId $OrchestratorPid -ExpectedStartUtc $OrchestratorStartTimeUtc)) {
            $parentLost = $true
            Write-Warning "Parent orchestrator no longer alive (pid=$OrchestratorPid); stopping ffmpeg child pid=$($ffProc.Id)..."
            Stop-ProcessTreeByPid -PidToKill $ffProc.Id
            break
        }
        Start-Sleep -Milliseconds 500
    }
    try { $ffProc.WaitForExit() } catch { }
    if ($exitCode -eq $script:ExitCodeTimeout) {
        # timeout already assigned
    } elseif ($parentLost) {
        $exitCode = 130
    } else {
        $robustEc = Get-RobustProcessExitCode -Process $ffProc
        if ($null -ne $robustEc) {
            $exitCode = $robustEc
        } else {
            if (Test-FfmpegAppearsSuccessfulFromStderr -StdErrPath $ffmpegStdErrLogPath) {
                Write-Warning 'FFmpeg process ExitCode unavailable; stderr indicates normal completion. Treating as exit code 0.'
                $exitCode = 0
            } else {
                # Last resort: treat as generic failure if ExitCode is unavailable.
                $exitCode = 1
            }
        }
    }
    Write-Host "FFmpeg exit code: $exitCode"
    if ($exitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($ffmpegStdOutLogPath)) { Write-Host "FFmpeg stdout log: $ffmpegStdOutLogPath" }
        if (-not [string]::IsNullOrWhiteSpace($ffmpegStdErrLogPath)) { Write-Host "FFmpeg stderr log: $ffmpegStdErrLogPath" }
        if (-not [string]::IsNullOrWhiteSpace($ffmpegStdErrLogPath) -and (Test-Path -LiteralPath $ffmpegStdErrLogPath)) {
            Write-Host 'FFmpeg stderr tail (last 60 lines):'
            try {
                $tail = Get-Content -LiteralPath $ffmpegStdErrLogPath -Tail 60 -ErrorAction Stop
                if ($tail) { Write-Host ($tail -join [Environment]::NewLine) }
            } catch {
                Write-Warning "Could not read FFmpeg stderr tail: $_"
            }
        }
    }

    }

    if ($exitCode -eq 0 -and -not $SkipOrchestrator -and -not $DryRun) {
        $fromCtx = ($ContextMenu -or (Test-InvokedFromExplorerShell))
        if ($fromCtx -and $fullInput.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
            $bundle = Find-OrchestratorPlaylistBundle -AvsFullPath $fullInput -TranscodeScriptFullPath $thisScriptPath
            if ($null -ne $bundle) {
                $orchestratorFollowUp = @{
                    OrchestratorScript = $bundle['OrchestratorScript']
                    PlaylistFile       = $bundle['PlaylistFile']
                    AvsFolder          = $bundle['AvsFolder']
                    ResumeAfter        = $fullInput
                }
            } else {
                Write-Warning "Run-TranscodeOrchestrator.ps1 + playlist.m3u not found (walked up from .avs folder); skipping orchestrator. Avs: $fullInput"
            }
        }
    }
} finally {
    if ($transcriptActive) {
        try {
            Stop-Transcript
        } catch {
            # Ignore if transcript was not running.
        }
        $transcriptActive = $false
    }
    if ($instanceMutex) {
        if ($ownsMutex) {
            [void]$instanceMutex.ReleaseMutex()
        }
        $instanceMutex.Dispose()
    }
    if ($ownsMutex -and $lockOwnerPath) {
        try { Remove-Item -LiteralPath $lockOwnerPath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

if ($null -ne $orchestratorFollowUp) {
    Write-Host ''
    Write-Host 'Starting orchestrator (mutex released)...'
    try {
        $sh = Get-HostPowerShellExeForOrchestrator
        $argList = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $orchestratorFollowUp['OrchestratorScript'],
            '-AvsFolder', $orchestratorFollowUp['AvsFolder'],
            '-TranscodeScript', $thisScriptPath,
            '-SkipPotPlayer',
            '-SkipCompanionBinaries',
            '-ResumePlaylistAfter', $orchestratorFollowUp['ResumeAfter']
        )
        if (-not [string]::IsNullOrWhiteSpace($orchestratorFollowUp['PlaylistFile'])) {
            $argList += @('-PlaylistFile', $orchestratorFollowUp['PlaylistFile'])
        }
        & $sh @argList
        $orchEc = $LASTEXITCODE
        if ($orchEc -ne 0) {
            Write-Warning "Orchestrator exit code: $orchEc"
            $exitCode = $orchEc
        }
    } catch {
        Write-Warning "Orchestrator failed: $_"
    }
}

if ($exitCode -ne 0 -and $NoLogFile) {
    $sd = [System.IO.Path]::GetDirectoryName($thisScriptPath)
    $inp = if ((Test-Path Variable:fullInput) -and -not [string]::IsNullOrWhiteSpace($fullInput)) {
        $fullInput
    } elseif (-not [string]::IsNullOrWhiteSpace($LiteralPath)) {
        $LiteralPath
    } else {
        '(unknown)'
    }
    Write-TranscodeFailureAppendLog -ScriptDir $sd -InputPath $inp -Code $exitCode -FfmpegCommandLine $failureLogCommandLine
}

if (-not $NoPause) {
    Write-Host ''
    Write-Host 'Exiting in 5 seconds...'
    Start-Sleep -Seconds 5
}
exit $exitCode
