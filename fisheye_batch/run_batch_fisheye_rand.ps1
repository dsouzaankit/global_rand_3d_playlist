# global_rand_3d_playlist fisheye batch (2d_media_paths.txt). Transcode stack synced from 3d_playlist_local.
# Not 3d_playlist_local\run_batch_fisheye_v360.ps1 (that uses media_files.txt beside a media root).
# Uses Run-V360PrepareFisheye.ps1 -AutoChaseTranscode -ChaseSync (inline chase loop, no extra worker window).

param(
    [int] $InterClipWaitSec = 0,
    [int] $MezzanineReadyTimeoutSec = 180,
    [int] $MezzanineReadyMinBytes = 1048576,
    [int] $ChasePollDelaySec = 3,
    [int] $ChaseMaxStaleWaits = 120,
    [int] $BatchTimeoutSec = 5400,
    [string] $ResumeAfter = '',
    [switch] $SkipPotPlayer,
    [string] $PotPlayerExe = '',
    [string] $CompanionBinaryFolder = '',
    [switch] $SkipCompanionBinaries,
    [switch] $SkipPotPlayerSeek,
    [ValidateSet('Poll', 'Sync')]
    [string] $PrepareWaitMode = 'Poll',
    [int] $PrepareHeartbeatSec = 0,
    [int] $PrepareHeartbeatDivisor = 5,
    [switch] $NoBatchLog,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
try { $PSNativeCommandUseErrorActionPreference = $false } catch { }

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    [System.IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
}
# global_rand_3d_playlist: fisheye_batch\ script, project root is parent
if ((Split-Path -Leaf $scriptDir) -ieq 'fisheye_batch') {
    $projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $scriptDir))
} else {
    $projectRoot = $scriptDir
}
$randPathsScript = Join-Path $scriptDir 'Resolve-RandSharedPaths.ps1'
if (-not (Test-Path -LiteralPath $randPathsScript -PathType Leaf)) {
    throw "Resolve-RandSharedPaths.ps1 not found: $randPathsScript"
}
. $randPathsScript
$playlistLocal = $projectRoot
$mediaRoot = $projectRoot
$syncSource = Get-RandTranscodeSyncSource

# Ensure Skybox DLNA root (dummy subst M: + AppData store) before any Join-Path on M:\... (pwsh validates drive letters).
$leafEarly = Join-Path $syncSource 'individual_transcode\Invoke-LeafFfmpegControl.ps1'
if (-not (Test-Path -LiteralPath $leafEarly -PathType Leaf)) {
    $leafEarly = Join-Path $projectRoot 'individual_transcode\Invoke-LeafFfmpegControl.ps1'
}
if (Test-Path -LiteralPath $leafEarly -PathType Leaf) {
    . $leafEarly
}
if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    [void](Ensure-DlnaSegmentRoot -Force)
    $fisheyeTempRoot = Get-FisheyeTempRoot
} else {
    throw "Ensure-DlnaSegmentRoot not found. Sync individual_transcode from $syncSource (Invoke-LeafFfmpegControl.ps1)."
}
$fisheyeAvsDir = [System.IO.Path]::Combine($fisheyeTempRoot, 'avs')
$prepareScript = Join-Path $projectRoot 'individual_transcode\Run-V360PrepareFisheye.ps1'
$asisCopyScript = Join-Path $projectRoot 'individual_transcode\Run-SegmentCopyAsIs.ps1'
$potPlayerGateScript = Join-Path $projectRoot 'individual_transcode\Invoke-BatchPotPlayerGate.ps1'
$mediaListFile = Join-Path $projectRoot '2d_media_paths.txt'
$randMediaResolver = Join-Path $scriptDir 'Resolve-Rand2dMediaList.ps1'
$randCompanionScript = Join-Path $scriptDir 'Start-RandPotPlayerCompanions.ps1'

Set-Location -LiteralPath $projectRoot
Write-Host "Project root: $projectRoot"
Write-Host "Media list:   $mediaListFile (2d pointers; offline paths kept for PotPlayer gate)"

try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -ErrorAction Stop
} catch {
    Write-Host "Note: Set-ExecutionPolicy skipped (effective policy unchanged): $($_.Exception.Message)"
}

function Invoke-SafeNativeCommand {
    param(
        [scriptblock] $Command,
        [int[]] $SuccessExitCodes = @(0)
    )
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    try { $prevNative = $PSNativeCommandUseErrorActionPreference } catch { }
    try {
        $ErrorActionPreference = 'Continue'
        try { $PSNativeCommandUseErrorActionPreference = $false } catch { }
        & $Command
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) {
            try { $PSNativeCommandUseErrorActionPreference = $prevNative } catch { }
        }
    }
    return @{
        ExitCode = $exitCode
        Ok = ($SuccessExitCodes -contains $exitCode)
    }
}

function Invoke-SafeRobocopySync {
    param(
        [string] $Source,
        [string] $Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Warning "Robocopy skipped (source missing): $Source"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($Destination)
    }
    $result = Invoke-SafeNativeCommand -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -Command {
        robocopy.exe $Source $Destination /E /XF *.log /NFL /NDL /NJH /NJS /NP | Out-Null
    }
    if ($result.Ok) {
        Write-Host "Robocopy synced (exit $($result.ExitCode)): $Source -> $Destination"
        return $true
    }
    Write-Warning "Robocopy failed (exit $($result.ExitCode)): $Source -> $Destination"
    return $false
}

function Format-BatchProcessArgumentLine {
    param([string[]] $Arguments)
    return ($Arguments | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s":+]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
}

function Start-BatchHiddenPowerShellFile {
    param(
        [string[]] $Arguments,
        [string] $WorkingDirectory,
        [string] $ShellExe = ''
    )
    if ([string]::IsNullOrWhiteSpace($ShellExe)) {
        $ShellExe = (Get-Command powershell -ErrorAction Stop).Source
    }
    $hiddenArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden') + $Arguments
    return Start-Process -FilePath $ShellExe `
        -ArgumentList (Format-BatchProcessArgumentLine $hiddenArgs) `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -PassThru
}

function Get-BatchOrchestratorStartTimeUtc {
    try {
        return (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    } catch {
        Write-Warning "Could not read batch start time for pid=$PID; parent watch will use PID only."
        return ''
    }
}

function Convert-BatchUtcIsoToDateTime {
    param([string] $UtcIso)
    if ([string]::IsNullOrWhiteSpace($UtcIso)) { return $null }
    try {
        return [datetime]::Parse(
            $UtcIso,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    } catch {
        return $null
    }
}

function Get-BatchDeadlineUtcIso {
    param(
        [string] $StartUtcIso,
        [int] $TimeoutSec
    )
    if ($TimeoutSec -lt 1) { return '' }
    $start = Convert-BatchUtcIsoToDateTime -UtcIso $StartUtcIso
    if ($null -eq $start) {
        $start = [DateTime]::UtcNow
    }
    return $start.AddSeconds($TimeoutSec).ToString('o')
}

function Get-BatchRemainingSeconds {
    param([datetime] $DeadlineUtc)
    if ($null -eq $DeadlineUtc) { return $null }
    $rem = [Math]::Floor(($DeadlineUtc - [DateTime]::UtcNow).TotalSeconds)
    if ($rem -lt 0) { return 0 }
    return [int]$rem
}

function Test-BatchDeadlineExpired {
    param([datetime] $DeadlineUtc)
    if ($null -eq $DeadlineUtc) { return $false }
    return [DateTime]::UtcNow -ge $DeadlineUtc
}

function Stop-FisheyeBatchProcessTree {
    param([System.Diagnostics.Process] $Proc)
    if ($null -eq $Proc -or $Proc.HasExited) { return }
    try {
        & taskkill.exe /PID $Proc.Id /T /F 2>$null | Out-Null
    } catch {
        try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-FisheyeBatchFfmpeg {
    Write-Warning 'Stopping fisheye batch ffmpeg processes...'
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if (-not $cmd) { continue }
        if ($cmd -like "*$fisheyeTempRoot*" -or $cmd -like '*3d_op_*') {
            Write-Host "Stopping ffmpeg pid=$($proc.ProcessId)"
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 300
}

function Test-PrepareBatchLogShowsClipFinished {
    param([string] $StdOutPath)
    $joined = Get-PrepareLogTailText -StdOutPath $StdOutPath
    if ([string]::IsNullOrWhiteSpace($joined)) { return $false }
    if ($joined -match '\[batch-finished\]') { return $true }
    return ($joined -match 'Pass-2 chase loop finished successfully' `
        -and $joined -match 'Done\.\s+Pass-1 mezzanine \+ pass-2 DLNA chase finished')
}

function Get-BatchFinishedExitCodeFromLog {
    param([string] $StdOutPath)
    $joined = Get-PrepareLogTailText -StdOutPath $StdOutPath
    if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
    $m = [regex]::Match($joined, '\[batch-finished\]\s+exit=(-?\d+)')
    if ($m.Success) {
        return [int]$m.Groups[1].Value
    }
    return $null
}

function Get-BatchPrepareLogTailText {
    param(
        [string] $StdOutPath,
        [int] $MaxChars = 24576
    )
    return Get-PrepareLogTailText -StdOutPath $StdOutPath -MaxChars $MaxChars
}

function Get-BatchPrepareFinishedMarkerPath {
    param([string] $StdOutPath)
    return "$StdOutPath.finished"
}

function Test-PrepareBatchClipFinished {
    param([string] $StdOutPath)
    if ([string]::IsNullOrWhiteSpace($StdOutPath)) { return $false }
    $marker = Get-BatchPrepareFinishedMarkerPath -StdOutPath $StdOutPath
    if (Test-Path -LiteralPath $marker -PathType Leaf) { return $true }
    return (Test-PrepareBatchLogShowsClipFinished -StdOutPath $StdOutPath)
}

function Clear-BatchPrepareFinishedMarker {
    param([string] $StdOutPath)
    if ([string]::IsNullOrWhiteSpace($StdOutPath)) { return }
    $marker = Get-BatchPrepareFinishedMarkerPath -StdOutPath $StdOutPath
    if (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
}

function Test-BatchProcessIdStillRunning {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return $false }
    return $null -ne (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue)
}

function Test-BatchPrepareProcessGone {
    param([System.Diagnostics.Process] $Proc)
    if ($null -eq $Proc) { return $true }
    try {
        $Proc.Refresh()
        if ($Proc.HasExited) { return $true }
    } catch {
        return $true
    }
    return -not (Test-BatchProcessIdStillRunning -ProcessId $Proc.Id)
}

function Get-NormalizedPrepareExitCode {
    param(
        [System.Diagnostics.Process] $Proc,
        [string] $StdOutPath = '',
        [int] $MaxWaitSec = 20
    )
    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PrepareBatchClipFinished -StdOutPath $StdOutPath) {
            $fromLog = Get-BatchFinishedExitCodeFromLog -StdOutPath $StdOutPath
            if ($null -ne $fromLog) {
                Write-Host ("Prepare clip finished (marker/log) - exit {0} from [batch-finished]." -f $fromLog)
                return [int]$fromLog
            }
            Write-Host 'Prepare clip finished (marker/log) - treating as exit 0.'
            return 0
        }
        if ($null -ne $Proc) {
            try {
                $Proc.Refresh()
                if ($Proc.HasExited) {
                    $ec = [int]$Proc.ExitCode
                    if ($ec -eq 0 -or $ec -eq 130) { return $ec }
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 400
    }
    if (Test-PrepareBatchClipFinished -StdOutPath $StdOutPath) {
        $fromLog = Get-BatchFinishedExitCodeFromLog -StdOutPath $StdOutPath
        if ($null -ne $fromLog) {
            Write-Host ("Prepare clip finished (marker/log) - exit {0} from [batch-finished]." -f $fromLog)
            return [int]$fromLog
        }
        Write-Host 'Prepare clip finished (marker/log) - treating as exit 0.'
        return 0
    }
    if ($null -ne $Proc -and -not (Test-BatchProcessIdStillRunning -ProcessId $Proc.Id)) {
        try {
            $Proc.Refresh()
            if ($Proc.HasExited) { return [int]$Proc.ExitCode }
        } catch { }
        Write-Warning "Prepare shell exited without marker/log success: $StdOutPath"
        return 1
    }
    Write-Warning "Timed out waiting for prepare completion marker/log: $StdOutPath"
    return 1
}

function New-FisheyeBatchPrepareLogPaths {
    param(
        [string] $LogsRoot,
        [string] $MediaFullPath,
        [string] $Kind = 'prepare'
    )
    if (-not (Test-Path -LiteralPath $LogsRoot)) {
        [void][System.IO.Directory]::CreateDirectory($LogsRoot)
    }
    $safe = [System.IO.Path]::GetFileNameWithoutExtension($MediaFullPath) -replace '[^\w\-.]+', '_'
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $kindSafe = ($Kind -replace '[^\w\-.]+', '_').ToLowerInvariant()
    $base = Join-Path $LogsRoot "fisheye_batch_${kindSafe}_${stamp}_${safe}"
    return @{
        StdOut = "${base}.stdout.log"
        StdErr = "${base}.stderr.log"
    }
}

$setupVenvBat = 'P:\all_scripts\setup_venv.bat'
if (Test-Path -LiteralPath $setupVenvBat -PathType Leaf) {
    $venvResult = Invoke-SafeNativeCommand -SuccessExitCodes @(0) -Command { & $setupVenvBat }
    if (-not $venvResult.Ok) {
        Write-Warning "setup_venv.bat exited $($venvResult.ExitCode); continuing batch."
    }
} else {
    Write-Warning "setup_venv.bat not found: $setupVenvBat; continuing batch."
}

$transcodeSyncDest = Join-Path $projectRoot 'individual_transcode'
Invoke-SafeRobocopySync -Source (Join-Path $syncSource 'individual_transcode') -Destination $transcodeSyncDest | Out-Null

$companionSyncSource = Get-RandSharedAutoHotkeySource
$companionLocal = Join-Path $projectRoot 'AutoHotkey'
if (-not [string]::IsNullOrWhiteSpace($companionSyncSource)) {
    Write-Host "AutoHotkey sync: $companionSyncSource -> $companionLocal"
    Invoke-SafeRobocopySync -Source $companionSyncSource -Destination $companionLocal | Out-Null
} else {
    Write-Warning "Shared AutoHotkey not found (P:\all_scripts\AutoHotkey); using local copy if present: $companionLocal"
}
Set-Location -LiteralPath $projectRoot

$batchTranscriptActive = $false
$batchTranscriptPath = ''
if (-not $NoBatchLog.IsPresent) {
    $batchLogDir = Join-Path $playlistLocal 'individual_transcode\transcode_logs\fisheye_batch'
    if (-not (Test-Path -LiteralPath $batchLogDir)) {
        [void][System.IO.Directory]::CreateDirectory($batchLogDir)
    }
    $batchTranscriptPath = Join-Path $batchLogDir ("fisheye_batch_console_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)
    try {
        Start-Transcript -Path $batchTranscriptPath -Force -ErrorAction Stop | Out-Null
        $batchTranscriptActive = $true
        Write-Host "Batch transcript (console + file): $batchTranscriptPath"
    } catch {
        Write-Warning "Batch transcript failed ($_); continuing with console output only."
    }
}

$potPlayerGateScript = Join-Path $playlistLocal 'individual_transcode\Invoke-BatchPotPlayerGate.ps1'
if (-not (Test-Path -LiteralPath $potPlayerGateScript)) {
    $potPlayerGateScript = Join-Path $syncSource 'individual_transcode\Invoke-BatchPotPlayerGate.ps1'
}
if (-not (Test-Path -LiteralPath $potPlayerGateScript)) {
    throw "Invoke-BatchPotPlayerGate.ps1 not found after sync. Expected under $playlistLocal or $syncSource"
}
. $potPlayerGateScript
$prepareHeartbeatScript = Join-Path $playlistLocal 'individual_transcode\Get-FisheyePrepareHeartbeat.ps1'
if (-not (Test-Path -LiteralPath $prepareHeartbeatScript -PathType Leaf)) {
    $prepareHeartbeatScript = Join-Path $syncSource 'individual_transcode\Get-FisheyePrepareHeartbeat.ps1'
}
if (-not (Test-Path -LiteralPath $prepareHeartbeatScript -PathType Leaf)) {
    throw "Get-FisheyePrepareHeartbeat.ps1 not found after sync. Expected under $playlistLocal or $syncSource"
}
. $prepareHeartbeatScript

$leafFfmpegControlScript = Join-Path $playlistLocal 'individual_transcode\Invoke-LeafFfmpegControl.ps1'
if (-not (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf)) {
    $leafFfmpegControlScript = Join-Path $syncSource 'individual_transcode\Invoke-LeafFfmpegControl.ps1'
}
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
} else {
    Write-Warning "Invoke-LeafFfmpegControl.ps1 not found; Space pause/resume unavailable this run."
}
if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    [void](Ensure-DlnaSegmentRoot -Force)
}
if (Get-Command Get-FisheyeTempRoot -ErrorAction SilentlyContinue) {
    $fisheyeTempRoot = Get-FisheyeTempRoot
    $fisheyeAvsDir = Join-Path $fisheyeTempRoot 'avs'
}

function Wait-FisheyeBatchProcessOrEnterCancel {
    param(
        [System.Diagnostics.Process] $Proc,
        [ref] $CancelledByEnter,
        [string] $StdOutPath = '',
        [int] $HeartbeatSeconds = 60,
        [string] $PrepareWaitMode = 'Poll',
        [datetime] $BatchDeadlineUtc = [datetime]::MinValue,
        [ref] $TimedOutByBatch = $null,
        [string] $HandoffDirectory = '',
        [string] $HandoffActiveSuffix = ''
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $handoffSw = [System.Diagnostics.Stopwatch]::StartNew()
    $warnedNoConsole = $false
    $processGoneAt = $null
    while ($true) {
        if ($PrepareWaitMode -ne 'Sync') {
            $pollEnterCancel = $false
            if (Get-Command Invoke-BatchConsoleControlPoll -ErrorAction SilentlyContinue) {
                [void](Invoke-BatchConsoleControlPoll -CancelledByEnter ([ref]$pollEnterCancel))
            } elseif (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
                [void](Invoke-TranscodeConsoleKeyPoll -AllowEnterCancel -EnterCancel ([ref]$pollEnterCancel))
            } elseif (Test-BatchConsoleCancelKeyPressed) {
                $pollEnterCancel = $true
            }
            if ($pollEnterCancel) {
                $CancelledByEnter.Value = $true
                Write-Host ''
                Write-Host 'Enter pressed - cancelling clip (prepare shell + v360 + ffmpeg)...'
                Stop-FisheyeBatchProcessTree -Proc $Proc
                Stop-FisheyeBatchFfmpeg
                return
            }
        }

        if ($BatchDeadlineUtc -gt [datetime]::MinValue -and (Test-BatchDeadlineExpired -DeadlineUtc $BatchDeadlineUtc)) {
            Write-Host ''
            Write-Warning 'Batch deadline reached; stopping prepare/chase shell and ffmpeg...'
            if ($null -ne $TimedOutByBatch) { $TimedOutByBatch.Value = $true }
            Stop-FisheyeBatchProcessTree -Proc $Proc
            Stop-FisheyeBatchFfmpeg
            return
        }

        # Marker/log before Enter-cancel poll: [Console]::In.Peek() can block until a keypress in Poll mode.
        if (Test-PrepareBatchClipFinished -StdOutPath $StdOutPath) {
            Write-Host ''
            Write-Host 'Prepare clip finished (marker/log).'
            if (Test-BatchProcessIdStillRunning -ProcessId $Proc.Id) {
                Start-Sleep -Seconds 1
                if (Test-BatchProcessIdStillRunning -ProcessId $Proc.Id) {
                    Stop-FisheyeBatchProcessTree -Proc $Proc
                }
            }
            return
        }

        $stillRunning = Test-BatchProcessIdStillRunning -ProcessId $Proc.Id
        if (-not $stillRunning) {
            if ([string]::IsNullOrWhiteSpace($StdOutPath)) {
                Write-Host ''
                Write-Host 'Child process exited.'
                return
            }
            if ($null -eq $processGoneAt) {
                $processGoneAt = Get-Date
            }
            $goneSec = ((Get-Date) - $processGoneAt).TotalSeconds
            if ($goneSec -ge 20) {
                Write-Host ''
                Write-Warning "Prepare shell gone ${goneSec}s without marker/log; continuing batch evaluation."
                return
            }
        } else {
            $processGoneAt = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($HandoffDirectory) -and `
            -not [string]::IsNullOrWhiteSpace($HandoffActiveSuffix) -and `
            $handoffSw.Elapsed.TotalSeconds -ge 2 -and `
            (Get-Command Sync-DlnaHybridSegmentHandoff -ErrorAction SilentlyContinue)) {
            Sync-DlnaHybridSegmentHandoff -Directory $HandoffDirectory -ActiveSuffix $HandoffActiveSuffix | Out-Null
            $handoffSw.Restart()
        }

        if (-not $warnedNoConsole -and $PrepareWaitMode -ne 'Sync') {
            try {
                $null = [Console]::KeyAvailable
            } catch {
                Write-Warning 'Console Enter-cancel may be unavailable in this host; close the batch window to stop.'
                $warnedNoConsole = $true
            }
        }
        if ($HeartbeatSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $HeartbeatSeconds) {
            $elapsedSec = [int][Math]::Floor($sw.Elapsed.TotalSeconds)
            $statusHint = if (-not [string]::IsNullOrWhiteSpace($StdOutPath)) {
                Get-PrepareLogStatusHint -StdOutPath $StdOutPath
            } else { '' }
            $statusNote = if ($statusHint) { " last: $statusHint" } else { '' }
            $goneNote = if ($null -ne $processGoneAt) {
                " prepareShellGone=$([int][Math]::Floor(((Get-Date) - $processGoneAt).TotalSeconds))s"
            } else { '' }
            Write-Host "[wait] Prepare/chase still running (${elapsedSec}s).$statusNote$goneNote Space=pause/resume DLNA export; Enter=cancel."
            $sw.Restart()
        }
        Start-Sleep -Milliseconds 250
    }
}

function Wait-FisheyeBatchSleepOrEnterCancel {
    param(
        [int] $Seconds,
        [ref] $CancelledByEnter,
        [datetime] $BatchDeadlineUtc = [datetime]::MinValue,
        [ref] $TimedOutByBatch = $null
    )
    if ($Seconds -le 0) { return }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($BatchDeadlineUtc -gt [datetime]::MinValue -and (Test-BatchDeadlineExpired -DeadlineUtc $BatchDeadlineUtc)) {
            Write-Host ''
            Write-Warning 'Batch deadline reached during inter-clip wait.'
            if ($null -ne $TimedOutByBatch) { $TimedOutByBatch.Value = $true }
            Stop-FisheyeBatchFfmpeg
            return
        }
        $pollEnterCancel = $false
        if (Get-Command Invoke-BatchConsoleControlPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-BatchConsoleControlPoll -CancelledByEnter ([ref]$pollEnterCancel))
        } elseif (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-TranscodeConsoleKeyPoll -AllowEnterCancel -EnterCancel ([ref]$pollEnterCancel))
        } elseif (Test-BatchConsoleCancelKeyPressed) {
            $pollEnterCancel = $true
        }
        if ($pollEnterCancel) {
            $CancelledByEnter.Value = $true
            Write-Host ''
            Write-Host 'Enter pressed - cancelling batch.'
            Stop-FisheyeBatchFfmpeg
            return
        }
        Start-Sleep -Milliseconds 200
    }
}

$prepareScript = Resolve-BatchScriptPath -LocalPath $prepareScript -SyncSourceRoot $syncSource `
    -RelativePath 'individual_transcode\Run-V360PrepareFisheye.ps1'
$asisCopyScript = Resolve-BatchScriptPath -LocalPath $asisCopyScript -SyncSourceRoot $syncSource `
    -RelativePath 'individual_transcode\Run-SegmentCopyAsIs.ps1'

if (Test-Path -LiteralPath $randMediaResolver -PathType Leaf) {
    . $randMediaResolver
} else {
    throw "Resolve-Rand2dMediaList.ps1 not found: $randMediaResolver"
}

$resolveMediaScript = Join-Path $projectRoot 'individual_transcode\Resolve-FisheyePlaylistMedia.ps1'
if (Test-Path -LiteralPath $resolveMediaScript -PathType Leaf) {
    . $resolveMediaScript
}

function Test-SkipStreamTo3DMediaName {
    param(
        [string] $FileName = '',
        [string] $FullPath = ''
    )
    if (Get-Command Test-RandSkipStreamTo3DMediaName -ErrorAction SilentlyContinue) {
        return (Test-RandSkipStreamTo3DMediaName -FileName $FileName -FullPath $FullPath)
    }
    if (Get-Command Test-Skip3dFormattedMediaName -ErrorAction SilentlyContinue) {
        return (Test-Skip3dFormattedMediaName -FileName $FileName -FullPath $FullPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($FileName) -and $FileName -match '(?i)((_3D)|(\.SBS\.)|(\.TB\.)|(\.HSBS\.)|(\.HTB\.)|(\.3DA\.)|(Full_?SBS)|(Half_?SBS)|(LR_?180_?FISHEYE)|(3d_op_)|(^|[^A-Za-z0-9])(FISHEYE|VR180|VR190|F180|SBS|HSBS|HTB|3DA)([^A-Za-z0-9]|$))') {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($FullPath) -and $FullPath -match '(?i)([\\/]_?fullsbs_?[\\/]|[\\/]_?halfsbs_?[\\/]|[\\/](?:sbs|fisheye|vr180)[\\/])') {
        return $true
    }
    return $false
}

function Get-FisheyeTempAvsFileName {
    param([string] $MediaFullPath)
    $name = [System.IO.Path]::GetFileName($MediaFullPath)
    return "StreamTo3D.fisheye_temp.$name.avs"
}

function Get-FisheyeMezzanineFileName {
    param([string] $MediaBase)
    return ($MediaBase + '.fisheye.frag.mp4')
}

function Get-FisheyeMezzaninePath {
    param([string] $MediaFullPath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($MediaFullPath)
    return Join-Path $fisheyeTempRoot (Get-FisheyeMezzanineFileName -MediaBase $base)
}

if (-not (Test-Path -LiteralPath $prepareScript)) {
    throw "Prepare script not found: $prepareScript (sync from $syncSource or run robocopy manually)"
}
if (-not (Test-Path -LiteralPath $asisCopyScript)) {
    throw "As-is segment copy script not found: $asisCopyScript (sync from $syncSource or run robocopy manually)"
}
if (-not (Test-Path -LiteralPath $mediaListFile)) { throw "2d_media_paths.txt not found: $mediaListFile" }

$listResult = Read-Rand2dMediaPathLines -ListFile $mediaListFile
$mediaLines = @($listResult.Paths)
if ($mediaLines.Count -eq 0) {
    throw "No eligible paths in 2d_media_paths.txt: $mediaListFile"
}
$existingCount = @($mediaLines | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count
$missingCount = $mediaLines.Count - $existingCount
if ($missingCount -gt 0) {
    Write-Warning "$missingCount path(s) not on disk yet (kept in PotPlayer playlist; skipped during transcode until present)."
}

$playlistBundle = Write-BatchPotPlayerPlaylists -MediaFullPaths $mediaLines -PlaylistDir $playlistLocal
$batchSidecarPath = $playlistBundle.SidecarPath

Write-Host "2d_media_paths.txt: $($listResult.RawCount) line(s), $($mediaLines.Count) in PotPlayer queue ($existingCount reachable now)"
Write-Host "Prepare:         $prepareScript"
Write-Host "As-is copy:      $asisCopyScript"
Write-Host "PotPlayer DPL:   $($playlistBundle.DplPath)"
Write-Host "Flow:            PotPlayer start clip + DPL playtime -> asis copy | prepare + pass-1 mezzanine + pass-2 chase sync"
if ($SkipPotPlayerSeek) {
    Write-Host 'DPL playtime:    ignored (-SkipPotPlayerSeek); pass-1 and pass-2 start at 0s for every clip'
} else {
    Write-Host 'DPL playtime:    first clip pass-1 mezzanine starts at PotPlayer position (30s backoff, clamped to source duration); pass-2 chase from mezzanine t=0'
}
if ($InterClipWaitSec -gt 0) {
    Write-Host "Inter-clip wait: ${InterClipWaitSec}s (DLNA buffer between clips; pass -InterClipWaitSec 0 to disable)"
} else {
    Write-Host 'Inter-clip wait: 0s (next clip starts immediately after pass-2 finishes)'
}
Write-Host "Batch timeout: ${BatchTimeoutSec}s for entire queue (pass-1 + pass-2 per clip; stops ffmpeg and closes shells)"
if ($PrepareHeartbeatSec -gt 0) {
    Write-Host "Prepare wait heartbeat: fixed ${PrepareHeartbeatSec}s per clip (-PrepareHeartbeatSec)"
} elseif ($PrepareHeartbeatDivisor -gt 0) {
    Write-Host "Prepare wait heartbeat: source_duration/${PrepareHeartbeatDivisor}s per clip (ffprobe; fallback 60s if unknown)"
} else {
    Write-Host 'Prepare wait heartbeat: disabled'
}
Write-Host "Pass 1:          av1_qsv 50M fragmented mezzanine"
Write-Host "Pass 2:          av1_qsv 75M DLNA segments (-readrate 1 viewing pace, preset slow)"
$fisheyeSegmentOutDir = if (Get-Command Get-DlnaSegmentOutputDirectory -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputDirectory -Kind fisheye
} else {
    Join-Path (Get-DlnaSegmentRoot) 'fisheye'
}
$hybridSegmentOutDir = if (Get-Command Get-DlnaSegmentOutputDirectory -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputDirectory -Kind hybrid
} else {
    Join-Path (Get-DlnaSegmentRoot) 'hybrid'
}
Write-Host "Fisheye DLNA:    $fisheyeSegmentOutDir\3d_op_%02d_LR_180_FISHEYE.mkv"
Write-Host "As-is DLNA:      $hybridSegmentOutDir\3d_op_%02d_LR_180.mkv (-c copy -re)"

$mutexName = 'Global\V360FisheyeBatchRand'
$timeoutSeconds = 30 * 60
$mutex = $null
$hasHandle = $false
$failures = [System.Collections.Generic.List[string]]::new()
$processed = 0
$skipped = 0
$companionsStarted = $false
$batchCancelled = $false
$batchTimedOut = $false
$batchExitCode = 0
$batchFatalError = $false
$lastSuccessfulMedia = ''
$batchOrchestratorStartUtc = Get-BatchOrchestratorStartTimeUtc
$batchDeadlineUtcIso = Get-BatchDeadlineUtcIso -StartUtcIso $batchOrchestratorStartUtc -TimeoutSec $BatchTimeoutSec
$batchDeadlineUtc = Convert-BatchUtcIsoToDateTime -UtcIso $batchDeadlineUtcIso
if ($BatchTimeoutSec -gt 0 -and -not [string]::IsNullOrWhiteSpace($batchDeadlineUtcIso)) {
    Write-Host "Batch deadline (UTC): $batchDeadlineUtcIso (~$(Get-BatchRemainingSeconds -DeadlineUtc $batchDeadlineUtc)s remaining)"
}
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -ne $pwshCmd) {
    $batchShellExe = $pwshCmd.Source
} else {
    $batchShellExe = (Get-Command powershell -ErrorAction Stop).Source
}
Write-Host "Batch child shell: $batchShellExe"
$batchPrepareLogsRoot = Join-Path $playlistLocal 'individual_transcode\transcode_logs\fisheye_batch_prepare'

try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$hasHandle)
    $mutexDeadline = (Get-Date).AddSeconds($timeoutSeconds)
    $mutexAcquired = $false
    while ((Get-Date) -lt $mutexDeadline) {
        if ($mutex.WaitOne([TimeSpan]::FromSeconds(2))) {
            $mutexAcquired = $true
            break
        }
        $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'run_batch_fisheye_rand|Run-V360PrepareFisheye' })
        $otherNote = if ($others.Count -gt 0) {
            " (other batch/prepare pid(s): $(($others | ForEach-Object { $_.ProcessId }) -join ', '))"
        } else { '' }
        Write-Host "Waiting for fisheye batch mutex...${otherNote} Press Ctrl+C to abort wait."
    }
    if (-not $mutexAcquired) {
        Write-Warning "Another fisheye batch already running or ${timeoutSeconds}s wait timed out. Exiting"
        return
    }

    Write-Host 'Mutex acquired. Starting fisheye v360 batch...'

    if (-not $DryRun -and -not $SkipPotPlayer -and -not $SkipCompanionBinaries) {
        $companionFolder = Resolve-RandCompanionFolder -ProjectRoot $projectRoot -Preferred $CompanionBinaryFolder
        if ([string]::IsNullOrWhiteSpace($companionFolder)) {
            $companionFolder = Resolve-CompanionBinaryFolder -Preferred '' -PlaylistLocal $playlistLocal
        }
        if (Test-Path -LiteralPath $companionFolder -PathType Container) {
            Write-Host "PotPlayer companions folder: $companionFolder"
            $companionsStarted = Start-BatchCompanionBinaries -FolderPath $companionFolder
            if (-not $companionsStarted -and (Test-Path -LiteralPath $randCompanionScript -PathType Leaf)) {
                . $randCompanionScript
                $companionsStarted = Start-RandPotPlayerCompanions -CompanionFolder $companionFolder
            }
            if (-not $companionsStarted) {
                Write-Warning 'Triple-click close not started; exit PotPlayer with File > Exit (or triple-left-click in video area if AHK is running).'
            } else {
                Start-Sleep -Seconds 2
            }
        } else {
            Write-Warning "AutoHotkey companion folder not found ($companionFolder); exit PotPlayer with File > Exit during the gate."
        }
    }

    try {
        Invoke-BatchPotPlayerDplGate -DplFullPath $playlistBundle.DplPath `
            -DryRun:($DryRun.IsPresent) -Skip:($SkipPotPlayer.IsPresent) -PotPlayerExePath $PotPlayerExe `
            -CompanionBinaryFolder $CompanionBinaryFolder -SkipCompanionBinaries:($SkipCompanionBinaries.IsPresent -or $companionsStarted) | Out-Null
    } catch {
        throw "PotPlayer start-clip gate failed: $(Get-PotPlayerGateErrorText $_)"
    }

    if ($companionsStarted) {
        Write-Host 'PotPlayer gate done; stopping AutoHotkey companions before transcode queue...'
        Stop-BatchCompanionBinaries
        $companionsStarted = $false
        Start-Sleep -Seconds 1
    }

    Write-Host 'Resolving batch queue anchor from PotPlayer DPL...'
    try {
        $anchor = Resolve-BatchPlaylistAnchor -DplPath $playlistBundle.DplPath `
            -SidecarPath $batchSidecarPath -PlaylistDir $playlistBundle.PlaylistDir -ResumeAfter $ResumeAfter
        $mediaLines = @(Get-BatchOrderRotatedForAnchor -OrderedPaths $mediaLines `
            -AnchorPath $anchor.AnchorPath -AnchorMode $anchor.AnchorMode)
    } catch {
        Write-Warning "PotPlayer anchor ignored; using full queue order: $($_.Exception.Message)"
    }

    Write-Host "Batch queue: $($mediaLines.Count) clip(s) to process."
    Write-Host "Batch control window pid=$PID - Space=pause/resume leaf export; Enter=cancel clip/batch."
    Write-Host ''

    # DPL gate: start clip + playtime (30s backoff). First batch clip only: pass-1 mezzanine -ss from DPL;
    # pass-2 chase starts at mezzanine t=0 (mezzanine already begins at the PotPlayer position).
    $applyPotPlayerSeek = -not $SkipPotPlayerSeek.IsPresent
    $dplSeekApplied = $false

    if ($DryRun) {
        $dryRunIdx = 0
        foreach ($line in $mediaLines) {
            $mediaFull = [System.IO.Path]::GetFullPath($line)
            $baseName = [System.IO.Path]::GetFileName($mediaFull)
            if (-not (Test-Path -LiteralPath $mediaFull -PathType Leaf)) {
                Write-Host "[DryRun][Missing] $mediaFull"
                continue
            }
            if (Test-SkipStreamTo3DMediaName -FileName $baseName -FullPath $mediaFull) {
                $asisSuffix = if (Get-Command Get-AsIsDlnaSegmentSuffix -ErrorAction SilentlyContinue) {
                    Get-AsIsDlnaSegmentSuffix -FileName $baseName -FullPath $mediaFull
                } else { 'LR_180' }
                Write-Host ("[DryRun][AsIs] suffix={0} :: already-3D stream copy -> hybrid" -f $asisSuffix)
                Write-Host "  media: $mediaFull"
                Write-Host ("  DLNA:  {0}\3d_op_%02d_{1}.mkv (-c copy -re)" -f $hybridSegmentOutDir, $asisSuffix)
            } else {
                $avs = Join-Path $fisheyeAvsDir (Get-FisheyeTempAvsFileName -MediaFullPath $mediaFull)
                $frag = Get-FisheyeMezzaninePath -MediaFullPath $mediaFull
                Write-Host "[DryRun][Clip] prepare -AutoChaseTranscode -ChaseSync -SegmentNameSuffix LR_180_FISHEYE -> wait ${InterClipWaitSec}s"
                Write-Host "  media: $mediaFull"
                Write-Host "  mezz:  $frag"
                Write-Host "  avs:   $avs"
                Write-Host "  dlna:  $fisheyeSegmentOutDir\3d_op_%02d_LR_180_FISHEYE.mkv"
            }
            if ($dryRunIdx -eq 0) {
                if ($applyPotPlayerSeek) {
                    $drySeek = Resolve-BatchPotPlayerInitialSeekMs -DplPath $playlistBundle.DplPath `
                        -MediaFullPath $mediaFull -PlaylistDir $playlistBundle.PlaylistDir
                    Write-Host "  pass-1 mezzanine seek (first clip, from DPL playtime): $drySeek ms (pass-2 from mezz t=0)"
                } else {
                    Write-Host '  pass-1 mezzanine seek: 0 ms (-SkipPotPlayerSeek or no DPL playtime)'
                }
            }
            $dryRunIdx++
        }
        return
    }

    for ($idx = 0; $idx -lt $mediaLines.Count; $idx++) {
        if ($batchCancelled -or $batchTimedOut) { break }
        if (Test-BatchDeadlineExpired -DeadlineUtc $batchDeadlineUtc) {
            Write-Warning "Batch deadline reached before starting clip $($idx + 1)/$($mediaLines.Count)."
            $batchTimedOut = $true
            break
        }
        $line = $mediaLines[$idx]
        $mediaFull = [System.IO.Path]::GetFullPath($line)
        $baseName = [System.IO.Path]::GetFileName($mediaFull)

        if (-not (Test-Path -LiteralPath $mediaFull -PathType Leaf)) {
            Write-Warning "[Missing] $mediaFull"
            $failures.Add("Missing: $mediaFull")
            continue
        }

        Write-Host ''
        Write-Host "=== Clip $($idx + 1)/$($mediaLines.Count): $mediaFull ==="

        try {
            $initialSeekMs = -1
            if ($applyPotPlayerSeek -and -not $dplSeekApplied) {
                $initialSeekMs = Resolve-BatchPotPlayerInitialSeekMs -DplPath $playlistBundle.DplPath `
                    -MediaFullPath $mediaFull -PlaylistDir $playlistBundle.PlaylistDir
                $dplSeekApplied = $true
            }

            $isAsIs3d = Test-SkipStreamTo3DMediaName -FileName $baseName -FullPath $mediaFull
            $routeKind = if ($isAsIs3d) { 'asis' } else { 'fisheye' }
            $routeSuffix = 'LR_180_FISHEYE'
            $segmentOutDir = $fisheyeSegmentOutDir
            if ($isAsIs3d) {
                $routeSuffix = if (Get-Command Get-AsIsDlnaSegmentSuffix -ErrorAction SilentlyContinue) {
                    Get-AsIsDlnaSegmentSuffix -FileName $baseName -FullPath $mediaFull
                } else { 'LR_180' }
                $segmentOutDir = $hybridSegmentOutDir
            }
            if (-not (Test-Path -LiteralPath $segmentOutDir -PathType Container)) {
                New-Item -ItemType Directory -Path $segmentOutDir -Force | Out-Null
            }
            Write-Host ("Route: {0} -> {1}\3d_op_%02d_{2}.mkv" -f $routeKind, $segmentOutDir, $routeSuffix)

            $childProc = $null
            $childLogs = $null
            $childStdOutForWait = ''
            $handoffDirForWait = ''
            $handoffSuffixForWait = ''

            if ($routeKind -eq 'asis') {
                $asisArgs = @(
                    '-File', $asisCopyScript,
                    '-LiteralPath', $mediaFull, '-NoPause',
                    '-SegmentNameSuffix', $routeSuffix,
                    '-OutputDirectory', $segmentOutDir,
                    '-TranscodeTimeoutSec', '-1',
                    '-WorkflowDeadlineUtc', $batchDeadlineUtcIso,
                    '-OrchestratorPid', "$PID",
                    '-OrchestratorStartTimeUtc', $batchOrchestratorStartUtc
                )
                if ($initialSeekMs -ge 0) {
                    $asisArgs += @('-SsMsOverride', "$initialSeekMs")
                } else {
                    $asisArgs += @('-SsMsOverride', '0')
                }
                $childLogs = New-FisheyeBatchPrepareLogPaths -LogsRoot $batchPrepareLogsRoot -MediaFullPath $mediaFull -Kind 'asis'
                Clear-BatchPrepareFinishedMarker -StdOutPath $childLogs.StdOut
                $asisArgs += @('-BatchStdOutLog', $childLogs.StdOut)
                Clear-BatchPendingConsoleKeys
                $childProc = Start-BatchHiddenPowerShellFile -Arguments $asisArgs `
                    -WorkingDirectory $playlistLocal -ShellExe $batchShellExe `
                    -RedirectStandardError $childLogs.StdErr
                if ($null -eq $childProc) {
                    throw 'Could not start as-is segment copy shell.'
                }
                $childStdOutForWait = $childLogs.StdOut
                $handoffDirForWait = $segmentOutDir
                $handoffSuffixForWait = $routeSuffix
                Write-Host ("As-is copy shell pid={0} (suffix {1}; -c copy -re)" -f $childProc.Id, $routeSuffix)
            } else {
                $prepareArgs = @(
                    '-File', $prepareScript,
                    '-LiteralPath', $mediaFull, '-NoPause', '-AutoChaseTranscode', '-ChaseSync',
                    '-MezzanineReadyTimeoutSec', "$MezzanineReadyTimeoutSec",
                    '-MezzanineReadyMinBytes', "$MezzanineReadyMinBytes",
                    '-ChasePollDelaySec', "$ChasePollDelaySec",
                    '-ChaseMaxStaleWaits', "$ChaseMaxStaleWaits",
                    '-WorkflowDeadlineUtc', $batchDeadlineUtcIso,
                    '-OrchestratorPid', "$PID",
                    '-OrchestratorStartTimeUtc', $batchOrchestratorStartUtc,
                    '-SegmentNameSuffix', 'LR_180_FISHEYE',
                    '-SegmentOutputDirectory', $segmentOutDir
                )
                if ($initialSeekMs -ge 0) {
                    $prepareArgs += @('-ChaseInitialSeekMs', "$initialSeekMs")
                }

                $childLogs = New-FisheyeBatchPrepareLogPaths -LogsRoot $batchPrepareLogsRoot -MediaFullPath $mediaFull -Kind 'prepare'
                Clear-BatchPrepareFinishedMarker -StdOutPath $childLogs.StdOut
                $prepareArgs += @('-BatchStdOutLog', $childLogs.StdOut)
                Clear-BatchPendingConsoleKeys
                $childProc = Start-BatchHiddenPowerShellFile -Arguments $prepareArgs `
                    -WorkingDirectory $playlistLocal -ShellExe $batchShellExe `
                    -RedirectStandardError $childLogs.StdErr
                if ($null -eq $childProc) {
                    throw 'Could not start prepare/chase shell.'
                }
                $childStdOutForWait = $childLogs.StdOut
                Write-Host "Prepare/chase shell pid=$($childProc.Id) (output -> $($childLogs.StdOut))"
                Write-Host 'Pass-2 chase: -readrate 1 (~1x DLNA viewing pace; preset slow).'
            }

            Write-Host "Prepare wait mode: $PrepareWaitMode"
            $clipHeartbeatSec = Resolve-PrepareWaitHeartbeatSeconds -MediaFullPath $mediaFull `
                -FixedHeartbeatSec $PrepareHeartbeatSec -Divisor $PrepareHeartbeatDivisor
            if ($PrepareHeartbeatSec -gt 0) {
                Write-Host "Prepare wait heartbeat: ${clipHeartbeatSec}s (fixed)"
            } else {
                $durHint = Get-BatchMediaDurationSeconds -MediaFullPath $mediaFull
                $durNote = if ($null -ne $durHint -and $durHint -gt 0) {
                    "~$([math]::Round($durHint))s source / $PrepareHeartbeatDivisor"
                } else { 'duration unknown; fallback 60s' }
                Write-Host "Prepare wait heartbeat: ${clipHeartbeatSec}s ($durNote)"
            }

            $enterCancel = $false
            $clipTimedOut = $false
            Wait-FisheyeBatchProcessOrEnterCancel -Proc $childProc -CancelledByEnter ([ref]$enterCancel) `
                -StdOutPath $childStdOutForWait -PrepareWaitMode $PrepareWaitMode `
                -HeartbeatSeconds $clipHeartbeatSec -BatchDeadlineUtc $batchDeadlineUtc `
                -TimedOutByBatch ([ref]$clipTimedOut) `
                -HandoffDirectory $handoffDirForWait -HandoffActiveSuffix $handoffSuffixForWait
            $prepareExitCode = Get-NormalizedPrepareExitCode -Proc $childProc -StdOutPath $childStdOutForWait
            if ($clipTimedOut) {
                $batchTimedOut = $true
                $prepareExitCode = 124
            }
            Write-Host ("{0} finished (exit {1}) for: {2}" -f $routeKind, $prepareExitCode, $mediaFull)

            if ($routeKind -eq 'asis') {
                if (Get-Command Sync-DlnaHybridSegmentHandoff -ErrorAction SilentlyContinue) {
                    Sync-DlnaHybridSegmentHandoff -Directory $segmentOutDir -ActiveSuffix $routeSuffix -Finalize | Out-Null
                } elseif (Get-Command Clear-DlnaExportSegments -ErrorAction SilentlyContinue) {
                    Clear-DlnaExportSegments -Directory $segmentOutDir -ActiveSuffix $routeSuffix -KeepCount 2 | Out-Null
                }
            }

            if ($enterCancel -or $prepareExitCode -eq 130) {
                if (-not [string]::IsNullOrWhiteSpace($lastSuccessfulMedia)) {
                    Write-TranscodeProgressSidecar -SidecarPath $batchSidecarPath -CompletedFullPath $lastSuccessfulMedia
                    Write-Host "Saved last completed clip on cancel: $lastSuccessfulMedia"
                }
                Write-Warning "Batch cancelled during clip (exit $prepareExitCode): $mediaFull"
                $batchCancelled = $true
                break
            }
            if ($prepareExitCode -eq 124) {
                Write-Warning "Batch deadline reached during clip (prepare exit 124)."
                $batchTimedOut = $true
                break
            }
            if ($prepareExitCode -ne 0) {
                throw "$routeKind exited with code $prepareExitCode (see $($childLogs.StdErr))"
            }

            $processed++
            $lastSuccessfulMedia = $mediaFull
            Write-TranscodeProgressSidecar -SidecarPath $batchSidecarPath -CompletedFullPath $mediaFull
            Write-Host "Clip completed (exit 0, ${routeKind}): $mediaFull"
            if ($idx -lt ($mediaLines.Count - 1)) {
                Write-Host "Next in queue: $($mediaLines[$idx + 1])"
            }
            if ($idx -lt ($mediaLines.Count - 1) -and $InterClipWaitSec -gt 0) {
                Write-Host ('Waiting {0}s for DLNA to finish viewing last exported minute...' -f $InterClipWaitSec)
                $enterCancel = $false
                $interClipTimedOut = $false
                Wait-FisheyeBatchSleepOrEnterCancel -Seconds $InterClipWaitSec -CancelledByEnter ([ref]$enterCancel) `
                    -BatchDeadlineUtc $batchDeadlineUtc -TimedOutByBatch ([ref]$interClipTimedOut)
                if ($interClipTimedOut) {
                    $batchTimedOut = $true
                    break
                }
                if ($enterCancel) {
                    if (-not [string]::IsNullOrWhiteSpace($lastSuccessfulMedia)) {
                        Write-TranscodeProgressSidecar -SidecarPath $batchSidecarPath -CompletedFullPath $lastSuccessfulMedia
                        Write-Host "Saved last completed clip on cancel: $lastSuccessfulMedia"
                    }
                    Write-Warning 'Batch cancelled during inter-clip wait.'
                    $batchCancelled = $true
                    break
                }
            }
        } catch {
            $errText = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
            Write-Warning "Clip failed: $mediaFull : $errText"
            $failures.Add("$mediaFull : $errText")
        }
    }

    Write-Host ''
    if ($batchTimedOut) {
        Write-Warning "Fisheye batch timed out after ${BatchTimeoutSec}s (batch deadline exceeded). Processed=$processed Skipped=$skipped Failed=$($failures.Count)"
        $batchExitCode = 124
    } elseif ($batchCancelled) {
        Write-Host "Fisheye batch cancelled. Processed=$processed Skipped=$skipped Failed=$($failures.Count)"
    } else {
        Write-Host "Fisheye batch finished. Processed=$processed Skipped=$skipped Failed=$($failures.Count)"
    }
    if ($failures.Count -gt 0) {
        Write-Host 'Failures:'
        $failures | ForEach-Object { Write-Host "  $_" }
        if ($batchExitCode -eq 0) { $batchExitCode = 1 }
    }
}
catch [System.UnauthorizedAccessException] {
    Write-Warning "Access denied for mutex '$mutexName'."
    $batchFatalError = $true
    if ($batchExitCode -eq 0) { $batchExitCode = 1 }
    Start-Sleep -Seconds 8
}
catch {
    $errText = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
    Write-Warning "Batch stopped: $errText"
    $batchFatalError = $true
    if ($batchExitCode -eq 0) { $batchExitCode = 1 }
    Write-Host 'Batch window closing in 12 seconds (check messages above)...'
    Start-Sleep -Seconds 12
}
finally {
    if ($batchTranscriptActive) {
        try { Stop-Transcript | Out-Null } catch { }
        $batchTranscriptActive = $false
        if (-not [string]::IsNullOrWhiteSpace($batchTranscriptPath)) {
            Write-Host "Batch transcript saved: $batchTranscriptPath"
        }
    }
    if ($companionsStarted) {
        Stop-BatchCompanionBinaries
    }
    if ($batchCancelled -or $batchTimedOut) {
        Stop-FisheyeBatchFfmpeg
    }
    if (-not $DryRun -and (Get-Command Invoke-DlnaWorkflowQuitCleanup -ErrorAction SilentlyContinue)) {
        $isTimeoutOrCancel = $batchTimedOut -or $batchCancelled -or
            ($batchExitCode -eq 124) -or ($batchExitCode -eq 130)
        $keepLogsOnError = (-not $isTimeoutOrCancel) -and (
            $batchFatalError -or ($failures.Count -gt 0) -or ($batchExitCode -ne 0)
        )
        try {
            [void](Invoke-DlnaWorkflowQuitCleanup -KeepLogs:$keepLogsOnError)
        } catch {
            Write-Warning ("DLNA quit cleanup failed: {0}" -f $_.Exception.Message)
        }
    } elseif (-not $DryRun -and (Get-Command Obfuscate-DlnaSegmentRootMedia -ErrorAction SilentlyContinue)) {
        $isTimeoutOrCancel = $batchTimedOut -or $batchCancelled -or
            ($batchExitCode -eq 124) -or ($batchExitCode -eq 130)
        $keepLogsOnError = (-not $isTimeoutOrCancel) -and (
            $batchFatalError -or ($failures.Count -gt 0) -or ($batchExitCode -ne 0)
        )
        try {
            [void](Obfuscate-DlnaSegmentRootMedia -KeepLogs:$keepLogsOnError)
        } catch {
            Write-Warning ("DLNA root media obfuscate on quit failed: {0}" -f $_.Exception.Message)
        }
        if (Get-Command Remove-DlnaSegmentRootSubst -ErrorAction SilentlyContinue) {
            try { [void](Remove-DlnaSegmentRootSubst) } catch {
                Write-Warning ("DLNA root F: subst cleanup on quit failed: {0}" -f $_.Exception.Message)
            }
        }
    }
    if ($null -ne $mutex -and $mutexAcquired) {
        try { $mutex.ReleaseMutex() | Out-Null } catch { }
        try { $mutex.Dispose() } catch { }
        Write-Host 'Mutex released.'
    }
}

if ($batchExitCode -ne 0) {
    exit $batchExitCode
}
