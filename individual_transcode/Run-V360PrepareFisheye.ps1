#Requires -Version 5.1
<#
.SYNOPSIS
  Step 1: v360 fragmented fisheye encode + custom StreamTo3D .avs export.

.DESCRIPTION
  Context-menu step 1 on source media (.mp4, .mkv, .mov, .m4v, .avi, .wmv, .ts, .m2ts, .webm):
    1. Starts Run-FisheyeV360.ps1 in background (mezzanine, playable while encoding).
       Pass-1 -ss from PotPlayer RememberFiles (same as flat transcode) + optional 5s quick-key override.
    2. Overwrites one AVS named for the current source (DirectShowSource -> mezzanine path).
    3. With -ContextMenu (Explorer right-click): resolves 3d_playlist_local\standardized\{filename}
       when present (same rule as generate_media_listings_lcl.py / selective_stdize.ps1), launches
       for pass-2, then auto-closes in 8 seconds on success. When media_files.txt has later clips,
       hands off to run_batch_fisheye_v360.ps1 -ResumeAfter (SkipPotPlayer / SkipPotPlayerSeek).

  Workflow timeout (same semantics as run_batch_fisheye_v360.ps1 -BatchTimeoutSec, scoped to one clip):
    -Default WorkflowTimeoutSec 5400 wall-clock from prepare start; shared -WorkflowDeadlineUtc with pass-2 worker.
    -No duration-based scaling on -ContextMenu (batch uses -WorkflowDeadlineUtc from queue start; no scaling either).
    -Pass-2 ffmpeg uses TranscodeTimeoutSec -1; only the workflow deadline stops encode (exit 124).

  Output under F:\f1_media\3d_fullsbs_trans\fisheye_temp (scripts in individual_transcode\):
   - mezzanine pass 1: fisheye_temp\{base}.fisheye.frag.mp4 (av1_qsv 50M)
   - AVS (one at a time): fisheye_temp\avs\StreamTo3D.fisheye_temp.{sourceFile}.avs
      (passthrough template; no StreamTo3D MDepan / motion stereo on fisheye mezzanine)
   - Each prepare run clears fisheye_temp media (mezzanine, avs, logs). Pass-2 overwrites 3d_op_00/3d_op_01 as 60s segments; chase alternates segment_start_number so short rounds still refresh both slots.

.EXAMPLE
  .\Run-V360PrepareFisheye.ps1 -LiteralPath "E:\media\clip.mp4" -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $LiteralPath,
    [string] $FisheyeOutputRoot = 'F:\f1_media\3d_fullsbs_trans\fisheye_temp',
    [string] $SegmentOutputDirectory = '',
    [string] $SegmentNameSuffix = '',
    [int] $SegmentVideoBitrateMbps = 0,
    [string] $TemplatePath = '',
    [string] $FisheyeV360Script = '',
    [int] $MezzanineVideoBitrateMbps = 50,
    [switch] $ContextMenu,
    [switch] $AutoChaseTranscode,
    [switch] $NoAutoChaseTranscode,
    [switch] $ChaseOnly,
    [switch] $ChaseWorker,
    [switch] $ChaseSync,
    [string] $ChaseAvsPath = '',
    [string] $ChaseMezzaninePath = '',
    [string] $TranscodeScript = '',
    [int] $MezzanineReadyTimeoutSec = 180,
    [int] $MezzanineReadyMinBytes = 1048576,
    [int] $Pass2StartDelaySec = 0,
    [int] $ChasePollDelaySec = 3,
    [int] $ChaseMaxStaleWaits = 120,
    [int] $WorkflowTimeoutSec = 5400,  # Same default as run_batch_fisheye_v360.ps1 -BatchTimeoutSec (per clip when -ContextMenu)
    [string] $WorkflowDeadlineUtc = '',
    [int64] $ChaseInitialSeekMs = -1,  # DPL playtime (ms): pass-1 mezzanine -ss; pass-2 chase starts at mezz t=0
    [int] $ParentPid = 0,
    [string] $ParentStartTimeUtc = '',
    [int] $OrchestratorPid = 0,
    [string] $OrchestratorStartTimeUtc = '',
    [string] $BatchStdOutLog = '',
    [switch] $NoPause,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
try { $PSNativeCommandUseErrorActionPreference = $false } catch { }
$script:ExitCodeWorkflowTimeout = 124
$script:ExitCodeParentClosed = 130
$script:FisheyeWorkflowDeadlineUtc = [datetime]::MaxValue
$script:FisheyeWorkflowTimeoutSec = 5400
$script:LauncherParentPid = 0
$script:LauncherParentStartTimeUtc = ''

$thisScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    [System.IO.Path]::GetFullPath($PSCommandPath)
} else {
    [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
}
$thisScriptDir = [System.IO.Path]::GetDirectoryName($thisScriptPath)
$prepareHeartbeatScript = Join-Path $thisScriptDir 'Get-FisheyePrepareHeartbeat.ps1'
if (Test-Path -LiteralPath $prepareHeartbeatScript -PathType Leaf) {
    . $prepareHeartbeatScript
}
$resolveStdMediaScript = Join-Path $thisScriptDir 'Resolve-StandardizedMediaPath.ps1'
if (Test-Path -LiteralPath $resolveStdMediaScript -PathType Leaf) {
    . $resolveStdMediaScript
}
$resolveMediaScript = Join-Path $thisScriptDir 'Resolve-FisheyePlaylistMedia.ps1'
if (Test-Path -LiteralPath $resolveMediaScript -PathType Leaf) {
    . $resolveMediaScript
}
$leafFfmpegControlScript = Join-Path $thisScriptDir 'Invoke-LeafFfmpegControl.ps1'
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
}
# Recreate dummy F:\f1_media\3d_fullsbs_trans (Skybox DLNA path) via %AppData% junction+subst.
if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    [void](Ensure-DlnaSegmentRoot -Force)
}
if ((Get-Command Get-FisheyeTempRoot -ErrorAction SilentlyContinue) -and
    ($FisheyeOutputRoot -eq 'F:\f1_media\3d_fullsbs_trans\fisheye_temp')) {
    # Prefer helper so fisheye_temp lands under the ensured root (same path string after subst).
    $FisheyeOutputRoot = Get-FisheyeTempRoot
}
$fisheyeOutputRootFull = [System.IO.Path]::GetFullPath($FisheyeOutputRoot)
$segmentOutputRootFull = if (-not [string]::IsNullOrWhiteSpace($SegmentOutputDirectory)) {
    [System.IO.Path]::GetFullPath($SegmentOutputDirectory)
} elseif (Get-Command Get-DlnaSegmentOutputDirectory -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputDirectory -Kind fisheye
} else {
    Join-Path ([System.IO.Path]::GetDirectoryName($fisheyeOutputRootFull)) 'fisheye'
}
$script:SegmentNameSuffix = if ([string]::IsNullOrWhiteSpace($SegmentNameSuffix)) { '' } else { $SegmentNameSuffix.Trim() }
$script:SegmentVideoBitrateMbps = if ($SegmentVideoBitrateMbps -gt 0) {
    $SegmentVideoBitrateMbps
} elseif ([string]$env:LOOP_SEGMENTS_SEGMENT_VIDEO_BITRATE_MBPS -match '^\s*(\d+)\s*$' -and [int]$Matches[1] -gt 0) {
    [int]$Matches[1]
} else {
    0
}
$script:DlnaSegmentPattern = if (Get-Command Get-DlnaSegmentOutputPattern -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputPattern -Suffix $script:SegmentNameSuffix
} elseif ([string]::IsNullOrWhiteSpace($script:SegmentNameSuffix)) {
    '3d_op_%02d.mkv'
} else {
    ("3d_op_%02d_{0}.mkv" -f ($script:SegmentNameSuffix -replace '[\\/:*?"<>|]', '_'))
}
$script:DlnaSegmentLeafNames = if (Get-Command Get-DlnaSegmentOutputLeaves -ErrorAction SilentlyContinue) {
    @(Get-DlnaSegmentOutputLeaves -Suffix $script:SegmentNameSuffix)
} else {
    @('3d_op_00.mkv', '3d_op_01.mkv', '3d_op_%02d.mkv')
}
$fragDir = $fisheyeOutputRootFull
$avsDir = Join-Path $fisheyeOutputRootFull 'avs'

function Write-BatchPrepareFinishedMarker {
    param([string] $BatchStdOutLog)
    if ([string]::IsNullOrWhiteSpace($BatchStdOutLog)) { return }
    $marker = "$BatchStdOutLog.finished"
    try {
        [System.IO.File]::WriteAllText($marker, (Get-Date).ToUniversalTime().ToString('o'))
    } catch {
        Write-Warning "Could not write batch finished marker ($marker): $_"
    }
}

function Wait-PressEnterToClose {
    param([string] $Prompt = 'Press Enter to close this window...')
    try {
        Read-Host $Prompt | Out-Null
    } catch {
        # Non-interactive host: fall back to a short pause.
        Start-Sleep -Seconds 2
    }
}

function Get-SafeProcessStartTimeUtc {
    param([int] $ProcessId = $PID)
    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    } catch {
        Write-Warning "Could not read start time for pid=$ProcessId; parent watch will use PID only."
        return ''
    }
}

function Test-LauncherParentAlive {
    if ($script:LauncherParentPid -le 0) { return $true }
    try {
        $null = Get-Process -Id $script:LauncherParentPid -ErrorAction Stop
    } catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($script:LauncherParentStartTimeUtc)) { return $true }
    try {
        $expected = [datetime]::Parse(
            $script:LauncherParentStartTimeUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $actual = (Get-Process -Id $script:LauncherParentPid -ErrorAction Stop).StartTime.ToUniversalTime()
        if ([Math]::Abs(($actual - $expected).TotalSeconds) -gt 2.0) {
            Write-Warning "Launcher parent pid=$($script:LauncherParentPid) start-time mismatch; using PID-only watch."
            $script:LauncherParentStartTimeUtc = ''
        }
    } catch {
        Write-Warning "Launcher parent start-time check failed; using PID-only watch."
        $script:LauncherParentStartTimeUtc = ''
    }
    return $true
}

function Assert-LauncherParentAlive {
    param([string] $Stage)
    if (Test-LauncherParentAlive) { return }
    Stop-FisheyeWorkflowProcesses -FisheyeTempRoot $fisheyeOutputRootFull
    throw "Launcher parent closed during $Stage; stopping pass-2 chase."
}

function Initialize-LauncherParentWatch {
    param(
        [int] $ParentPid,
        [string] $ParentStartTimeUtc
    )
    $script:LauncherParentPid = if ($ParentPid -gt 0) { $ParentPid } else { 0 }
    $script:LauncherParentStartTimeUtc = if ($null -ne $ParentStartTimeUtc) { [string]$ParentStartTimeUtc } else { '' }
    if ($script:LauncherParentPid -gt 0) {
        Write-Host "Watching launcher parent pid=$($script:LauncherParentPid) (worker stops if that window closes)"
    }
}

function Format-ProcessArgumentLine {
    param([string[]] $Arguments)
    # Legacy single-string escaping for tools that require one ArgumentList string.
    return ($Arguments | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s":+]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
}

function Format-FisheyeWorkflowDeadlineUtcIso {
    param([datetime] $DeadlineUtc)
    return $DeadlineUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffK', [Globalization.CultureInfo]::InvariantCulture)
}

function Test-WorkflowHasActiveDeadline {
    return $script:FisheyeWorkflowDeadlineUtc -lt [datetime]::MaxValue.AddDays(-1)
}

function Convert-WorkflowRemainingSeconds {
    param([datetime] $DeadlineUtc)
    if ($DeadlineUtc -ge [datetime]::MaxValue.AddDays(-1)) {
        return $null
    }
    $remaining = [Math]::Floor(($DeadlineUtc - [DateTime]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) { return 1 }
    if ($remaining -gt [int]::MaxValue) { return [int]::MaxValue }
    return [int]$remaining
}

function Initialize-WorkflowDeadline {
    param(
        [string] $ExplicitDeadlineUtc,
        [int] $TimeoutSec,
        [string] $FisheyeTempRoot
    )
    $useTimeout = [string]::IsNullOrWhiteSpace($ExplicitDeadlineUtc)
    if (-not $useTimeout) {
        try {
            $parsed = [datetime]::Parse(
                $ExplicitDeadlineUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
            if ($parsed -ge [datetime]::MaxValue.AddDays(-1)) {
                $useTimeout = $true
            } else {
                $script:FisheyeWorkflowDeadlineUtc = $parsed
            }
        } catch {
            Write-Warning "Could not parse WorkflowDeadlineUtc '$ExplicitDeadlineUtc'; using timeout budget instead."
            $useTimeout = $true
        }
    }
    if ($useTimeout) {
        if ($TimeoutSec -lt 1) { $TimeoutSec = 5400 }
        $script:FisheyeWorkflowDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    }
    $script:FisheyeWorkflowTimeoutSec = if ($TimeoutSec -gt 0) { $TimeoutSec } else { 5400 }
    $remainingSec = Convert-WorkflowRemainingSeconds -DeadlineUtc $script:FisheyeWorkflowDeadlineUtc
    if ($null -eq $remainingSec) { $remainingSec = $TimeoutSec }
    Write-Host "Fisheye workflow deadline (UTC): $(Format-FisheyeWorkflowDeadlineUtcIso -DeadlineUtc $script:FisheyeWorkflowDeadlineUtc) (~${remainingSec}s remaining)"
    try {
        $logDir = Join-Path $FisheyeTempRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $payload = @{
            deadlineUtc = (Format-FisheyeWorkflowDeadlineUtcIso -DeadlineUtc $script:FisheyeWorkflowDeadlineUtc)
            timeoutSec  = $TimeoutSec
            pid         = $PID
        }
        Set-Content -LiteralPath (Join-Path $logDir 'workflow_deadline.json') -Value ($payload | ConvertTo-Json -Compress) -Encoding utf8
    } catch {
        Write-Warning "Could not write workflow_deadline.json: $_"
    }
}

function Get-WorkflowRemainingSec {
    $remaining = Convert-WorkflowRemainingSeconds -DeadlineUtc $script:FisheyeWorkflowDeadlineUtc
    if ($null -ne $remaining) { return $remaining }
    $fallback = if ($WorkflowTimeoutSec -gt 0) { $WorkflowTimeoutSec } else { 5400 }
    return $fallback
}

function Test-WorkflowExpired {
    if (-not (Test-WorkflowHasActiveDeadline)) { return $false }
    return [DateTime]::UtcNow -ge $script:FisheyeWorkflowDeadlineUtc
}

function Stop-FfmpegUsingOutputLeaf {
    param([string[]] $LeafNames)
    $needles = @($LeafNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($needles.Count -lt 1) { return }
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if (-not $cmd) { continue }
        foreach ($leaf in $needles) {
            if ($cmd -like "*$leaf*") {
                Write-Host "Stopping ffmpeg pid=$($proc.ProcessId) using output leaf '$leaf'"
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }
    Start-Sleep -Milliseconds 300
}

function Stop-FisheyeWorkflowProcesses {
    param([string] $FisheyeTempRoot)
    Write-Warning 'Stopping fisheye pass-1 mezzanine and pass-2 DLNA ffmpeg processes (workflow timeout)...'
    Stop-FfmpegUsingFisheyeTemp -FisheyeTempRoot $FisheyeTempRoot
    $leaves = if ($null -ne $script:DlnaSegmentLeafNames -and $script:DlnaSegmentLeafNames.Count -gt 0) {
        $script:DlnaSegmentLeafNames
    } else {
        @('3d_op_00.mkv', '3d_op_01.mkv', '3d_op_%02d.mkv')
    }
    Stop-FfmpegUsingOutputLeaf -LeafNames $leaves
}

function Assert-WorkflowNotExpired {
    param([string] $Stage)
    if (-not (Test-WorkflowExpired)) { return }
    Stop-FisheyeWorkflowProcesses -FisheyeTempRoot $fisheyeOutputRootFull
    $limitNote = if (-not [string]::IsNullOrWhiteSpace($WorkflowDeadlineUtc)) {
        'batch workflow deadline'
    } elseif ($WorkflowTimeoutSec -gt 0) {
        "${script:FisheyeWorkflowTimeoutSec}s workflow timeout"
    } else {
        'workflow timeout'
    }
    throw "Fisheye $limitNote exceeded during: $Stage"
}

function Wait-WorkflowSleep {
    param([int] $Seconds)
    if ($Seconds -le 0) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Assert-WorkflowNotExpired 'wait'
        Assert-LauncherParentAlive 'wait'
        if (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-TranscodeConsoleKeyPoll)
        }
        Start-Sleep -Milliseconds 500
    }
}

function Resolve-FisheyeExitCodeFromError {
    param([object] $ErrorRecord)
    $msg = if ($null -ne $ErrorRecord) { [string]$ErrorRecord } else { '' }
    if ($msg -match 'Fisheye workflow timeout') { return $script:ExitCodeWorkflowTimeout }
    if ($msg -match 'Launcher parent closed') { return $script:ExitCodeParentClosed }
    return 1
}

function Get-ScaledWorkflowTimeoutSec {
    param(
        [int] $RequestedTimeoutSec,
        [string] $SourceMediaPath,
        [string] $FfprobeExe
    )
    $min = if ($RequestedTimeoutSec -gt 0) { $RequestedTimeoutSec } else { 5400 }
    if ([string]::IsNullOrWhiteSpace($SourceMediaPath) -or -not (Test-Path -LiteralPath $SourceMediaPath -PathType Leaf)) {
        return $min
    }
    $dur = Get-SafeFfprobeDurationSeconds -MediaPath $SourceMediaPath -FfprobeExe $FfprobeExe
    if ($null -eq $dur -or $dur -le 0) { return $min }
    $scaled = [int][Math]::Ceiling($dur * 2.5 + 1200)
    if ($scaled -gt $min) {
        Write-Host "Workflow timeout scaled ${min}s -> ${scaled}s (source ~$([math]::Round($dur))s; pass-1 + realtime pass-2 margin)"
        return $scaled
    }
    return $min
}

function Resolve-FisheyeWorkflowTimeoutSec {
    param(
        [string] $WorkflowDeadlineUtc,
        [int] $WorkflowTimeoutSec,
        [switch] $ContextMenu,
        [string] $SourceMediaPath = '',
        [string] $FfprobeExe = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($WorkflowDeadlineUtc)) {
        if ($WorkflowTimeoutSec -gt 0) { return $WorkflowTimeoutSec }
        return 5400
    }
    if ($ContextMenu) {
        if ($WorkflowTimeoutSec -lt 1) { return 5400 }
        return $WorkflowTimeoutSec
    }
    return Get-ScaledWorkflowTimeoutSec -RequestedTimeoutSec $WorkflowTimeoutSec `
        -SourceMediaPath $SourceMediaPath -FfprobeExe $FfprobeExe
}

function Test-FisheyePass1V360Failed {
    param(
        [string] $MezzaninePath,
        [switch] $AllowWhileRunning
    )
    if (-not $AllowWhileRunning.IsPresent) {
        if (Test-FisheyeMezzanineFfmpegRunning -MezzaninePath $MezzaninePath) { return $false }
    }
    $logDir = Join-Path ([System.IO.Path]::GetDirectoryName($MezzaninePath)) 'logs'
    $logPath = Join-Path $logDir (([System.IO.Path]::GetFileNameWithoutExtension($MezzaninePath)) + '_v360.stderr.log')
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return $false }
    try {
        $tail = @(Get-Content -LiteralPath $logPath -Tail 24 -ErrorAction Stop)
        $text = ($tail -join "`n")
        if ($text -match 'Conversion failed!') { return $true }
        if ($text -match 'Decode error rate .* exceeds maximum') { return $true }
        return $false
    } catch {
        return $false
    }
}

function Assert-FisheyePass1Healthy {
    param([string] $MezzaninePath)
    if (-not (Test-FisheyePass1V360Failed -MezzaninePath $MezzaninePath)) { return }
    throw @(
        "Pass-1 mezzanine ffmpeg failed (see fisheye_temp\logs\*_v360.stderr.log)."
        'Source may be corrupt or unreadable (common on network/removable drives).'
    ) -join ' '
}

function Get-FisheyeMezzanineFileName {
    param([string] $MediaBase)
    return ($MediaBase + '.fisheye.frag.mp4')
}

function Get-FisheyeTempAvsFileName {
    param([string] $MediaFullPath)
    $name = [System.IO.Path]::GetFileName($MediaFullPath)
    return "StreamTo3D.fisheye_temp.$name.avs"
}

function Get-FisheyeTempAvsFullPath {
    param(
        [string] $MediaFullPath,
        [string] $AvsDirectory
    )
    return Join-Path $AvsDirectory (Get-FisheyeTempAvsFileName -MediaFullPath $MediaFullPath)
}

function Resolve-FisheyeV360ScriptPath {
    param(
        [string] $ExplicitPath,
        [string] $ScriptDir
    )
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return [System.IO.Path]::GetFullPath($ExplicitPath)
    }
    $candidate = Join-Path $ScriptDir 'Run-FisheyeV360.ps1'
    if (Test-Path -LiteralPath $candidate) {
        return [System.IO.Path]::GetFullPath($candidate)
    }
    return $null
}

function Resolve-TemplatePath {
    param(
        [string] $ExplicitPath,
        [string] $ScriptDir
    )
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return [System.IO.Path]::GetFullPath($ExplicitPath)
    }
    $fisheyeCandidate = Join-Path $ScriptDir 'StreamTo3D.fisheye_temp.template.avs'
    if (Test-Path -LiteralPath $fisheyeCandidate) {
        return [System.IO.Path]::GetFullPath($fisheyeCandidate)
    }
    return $fisheyeCandidate
}

function Remove-StaleFisheyeTempAvs {
    param(
        [string] $AvsDir,
        [string] $KeepAvsFullPath
    )
    if (-not (Test-Path -LiteralPath $AvsDir -PathType Container)) { return }
    $keep = [System.IO.Path]::GetFullPath($KeepAvsFullPath)
    foreach ($f in Get-ChildItem -LiteralPath $AvsDir -Filter '*.avs' -File -ErrorAction SilentlyContinue) {
        if ($f.FullName.Equals($keep, [StringComparison]::OrdinalIgnoreCase)) { continue }
        Remove-Item -LiteralPath $f.FullName -Force
        Write-Host "Removed stale AVS: $($f.FullName)"
    }
}

function Stop-FfmpegUsingFisheyeTemp {
    param([string] $FisheyeTempRoot)
    $rootNorm = $FisheyeTempRoot.TrimEnd('\')
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if (-not $cmd) { continue }
        if ($cmd -like "*$rootNorm*" -or $cmd -like "*$([System.IO.Path]::GetFileName($rootNorm))*") {
            Write-Host "Stopping ffmpeg pid=$($proc.ProcessId) using fisheye_temp output"
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 300
}

function Stop-StaleFisheyeChaseWorkers {
    param([string] $PrepareScriptLeaf = 'Run-V360PrepareFisheye.ps1')
    foreach ($procName in @('powershell.exe', 'pwsh.exe')) {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='$procName'" -ErrorAction SilentlyContinue)
        foreach ($proc in $procs) {
            if ($proc.ProcessId -eq $PID) { continue }
            $cmd = [string]$proc.CommandLine
            if (-not $cmd) { continue }
            if ($cmd -notmatch [regex]::Escape($PrepareScriptLeaf)) { continue }
            if ($cmd -notmatch '-ChaseWorker') { continue }
            Write-Host "Stopping stale pass-2 chase worker pid=$($proc.ProcessId)"
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 500
}

function Clear-FisheyeTempLogFile {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return
    } catch { }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.SetLength(0)
        $fs.Close()
        Write-Host "Truncated locked log: $Path"
    } catch {
        Write-Warning "Could not remove or truncate log (may be locked): $Path"
    }
}

function Clear-FisheyeTempMedia {
    param([string] $FisheyeTempRoot)
    $mediaExtensions = @('.mp4', '.mkv', '.mov', '.m4v', '.avi', '.wmv', '.ts', '.m2ts', '.webm', '.avs')
    if (-not (Test-Path -LiteralPath $FisheyeTempRoot -PathType Container)) { return }

    Stop-FfmpegUsingFisheyeTemp -FisheyeTempRoot $FisheyeTempRoot
    Stop-StaleFisheyeChaseWorkers
    Write-Host "Clearing fisheye_temp media: $FisheyeTempRoot"

    foreach ($f in Get-ChildItem -LiteralPath $FisheyeTempRoot -File -ErrorAction SilentlyContinue) {
        if ($mediaExtensions -contains $f.Extension.ToLowerInvariant()) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                Write-Host "Removed mezzanine: $($f.FullName)"
            } catch {
                Write-Warning "Could not remove mezzanine (may be locked): $($f.FullName)"
            }
        }
    }

    $avsDirectory = Join-Path $FisheyeTempRoot 'avs'
    if (Test-Path -LiteralPath $avsDirectory -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $avsDirectory -Filter '*.avs' -File -ErrorAction SilentlyContinue) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                Write-Host "Removed AVS: $($f.FullName)"
            } catch {
                Write-Warning "Could not remove AVS (may be locked): $($f.FullName)"
            }
        }
    }

    $logDirectory = Join-Path $FisheyeTempRoot 'logs'
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        foreach ($f in Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction SilentlyContinue) {
            Clear-FisheyeTempLogFile -Path $f.FullName
        }
        Write-Host "Cleared v360 logs: $logDirectory"
    }
}

function Export-AvsFromFisheyeTemplate {
    param(
        [string] $TemplatePath,
        [string] $FragMediaFullPath,
        [string] $AvsOutFullPath,
        [string] $SourceMediaFullPath = '',
        [string] $FfprobeExe = ''
    )
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Template not found: $TemplatePath"
    }
    $template = [IO.File]::ReadAllText($TemplatePath)
    $placeholder = 'StreamTo3D_input.mp4'
    $count = ([regex]::Matches($template, [regex]::Escape($placeholder))).Count
    if ($count -lt 1) {
        throw "Template missing placeholder '$placeholder': $TemplatePath"
    }
    $fpsNum = 30000
    $fpsDen = 1001
    $fpsProbePath = if (-not [string]::IsNullOrWhiteSpace($SourceMediaFullPath)) { $SourceMediaFullPath } else { $FragMediaFullPath }
    $fpsParts = Get-VideoFrameRateFraction -MediaPath $fpsProbePath -FfprobeExe $FfprobeExe
    if ($null -ne $fpsParts) {
        $fpsNum = $fpsParts.Num
        $fpsDen = $fpsParts.Den
    }
    $qsvFps = ConvertTo-QsvIntegerFrameRateFraction -Num $fpsNum -Den $fpsDen
    $fpsNum = $qsvFps.Num
    $fpsDen = $qsvFps.Den
    $fragPath = [System.IO.Path]::GetFullPath($FragMediaFullPath)
    $avsContent = $template.Replace($placeholder, $fragPath)
    $avsContent = $avsContent.Replace('StreamTo3D_fps_num=30000', "StreamTo3D_fps_num=$fpsNum")
    $avsContent = $avsContent.Replace('StreamTo3D_fps_den=1001', "StreamTo3D_fps_den=$fpsDen")
    $outAvsDir = [System.IO.Path]::GetDirectoryName($AvsOutFullPath)
    if (-not (Test-Path -LiteralPath $outAvsDir)) {
        New-Item -ItemType Directory -Path $outAvsDir -Force | Out-Null
    }
    [IO.File]::WriteAllText($AvsOutFullPath, $avsContent, [Text.UTF8Encoding]::new($false))
    Write-Host "Exported AVS ($count x '$placeholder' -> frag path; fps ${fpsNum}/${fpsDen}): $AvsOutFullPath"
}

function ConvertTo-QsvIntegerFrameRateFraction {
    param([int64] $Num, [int64] $Den)
    $fps = if ($Num -gt 0 -and $Den -gt 0) { [double]$Num / [double]$Den } else { 30.0 }
    $snapped = 30
    $hit = $false
    foreach ($t in @(24, 25, 30, 50, 60, 120)) {
        if ([Math]::Abs($fps - $t) -lt 0.08) {
            $snapped = $t
            $hit = $true
            break
        }
    }
    if (-not $hit) {
        $snapped = [int][Math]::Round($fps)
        if ($snapped -lt 5) { $snapped = 5 }
        if ($snapped -gt 120) { $snapped = 120 }
    }
    return @{ Num = [int64]$snapped; Den = 1L }
}

function Get-VideoFrameRateFraction {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    if ([string]::IsNullOrWhiteSpace($MediaPath) -or -not (Test-Path -LiteralPath $MediaPath)) {
        return $null
    }
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    try { $prevNative = $PSNativeCommandUseErrorActionPreference } catch { }
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        try { $PSNativeCommandUseErrorActionPreference = $false } catch { }
        $raw = $null
        if ($FfprobeExe -and (Test-Path -LiteralPath $FfprobeExe)) {
            $raw = & $FfprobeExe -v error -select_streams v:0 -show_entries stream=avg_frame_rate `
                -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
            $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
            if ($s -eq '' -or $s -eq '0/0' -or $s -eq 'N/A') {
                $raw = & $FfprobeExe -v error -select_streams v:0 -show_entries stream=r_frame_rate `
                    -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
            }
        }
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) {
            try { $PSNativeCommandUseErrorActionPreference = $prevNative } catch { }
        }
    }
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -match '^(\d+)/(\d+)$') {
        $num = [int64]$Matches[1]; $den = [int64]$Matches[2]
        if ($num -gt 0 -and $den -gt 0) {
            return @{ Num = [int]$num; Den = [int]$den }
        }
    }
    return $null
}

function Get-FfprobeExePath {
    param([string] $FfmpegExe)
    if (-not [string]::IsNullOrWhiteSpace($FfmpegExe)) {
        $dir = [System.IO.Path]::GetDirectoryName($FfmpegExe)
        $candidate = Join-Path $dir 'ffprobe.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-FisheyeMezzanineFfmpegRunning {
    param([string] $MezzaninePath)
    $leaf = [System.IO.Path]::GetFileName($MezzaninePath)
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $false }
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        if ($proc.CommandLine -and ($proc.CommandLine -like "*$leaf*")) { return $true }
    }
    return $false
}

function Wait-FisheyeV360Launcher {
    param(
        [System.Diagnostics.Process] $LauncherProc,
        [string] $MezzaninePath,
        [string] $FisheyeV360ScriptPath,
        [int] $TimeoutSec = 20
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        Assert-WorkflowNotExpired 'pass-1 launcher wait'
        Assert-LauncherParentAlive 'pass-1 launcher wait'
        if ($LauncherProc.HasExited) {
            if ($LauncherProc.ExitCode -ne 0) {
                throw @(
                    "Pass 1 launcher failed (exit $($LauncherProc.ExitCode)): $FisheyeV360ScriptPath"
                    'Ensure Run-FisheyeV360.ps1 beside prepare is synced from P:\all_scripts\3d_playlist_local.'
                ) -join ' '
            }
            break
        }
        Start-Sleep -Milliseconds 200
    }
    for ($i = 0; $i -lt 15; $i++) {
        Assert-WorkflowNotExpired 'pass-1 startup poll'
        Assert-LauncherParentAlive 'pass-1 startup poll'
        if (Test-FisheyeMezzanineFfmpegRunning -MezzaninePath $MezzaninePath) {
            Write-Host "Pass 1 ffmpeg confirmed for mezzanine."
            return
        }
        if (Test-Path -LiteralPath $MezzaninePath) {
            $sz = (Get-Item -LiteralPath $MezzaninePath).Length
            if ($sz -gt 0) {
                Write-Host "Pass 1 mezzanine file present ($([math]::Round($sz/1MB, 2)) MB)."
                return
            }
        }
        Start-Sleep -Seconds 1
    }
    throw @(
        "Pass 1 did not start (no ffmpeg or mezzanine file): $MezzaninePath"
        "Check Run-FisheyeV360.ps1 is synced and see fisheye_temp\logs\*_v360.stderr.log if present."
    ) -join ' '
}

function Get-SafeFfprobeDurationSeconds {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    if ([string]::IsNullOrWhiteSpace($FfprobeExe) -or -not (Test-Path -LiteralPath $FfprobeExe)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
        return $null
    }
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    try { $prevNative = $PSNativeCommandUseErrorActionPreference } catch { }
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        try { $PSNativeCommandUseErrorActionPreference = $false } catch { }
        $raw = & $FfprobeExe -v error -show_entries format=duration `
            -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) {
            try { $PSNativeCommandUseErrorActionPreference = $prevNative } catch { }
        }
    }
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq 'N/A') { return $null }
    $n = 0.0
    if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $null
    }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -le 0) {
        return $null
    }
    return $n
}

function Resolve-FisheyePass1StartSeekMs {
    param(
        [int64] $ChaseInitialSeekMs,
        [string] $MediaFullPath,
        [string[]] $AlternateMediaPaths = @(),
        [string] $FfprobeExe,
        [string] $ScriptDir,
        [switch] $UseRegistryResume
    )
    $plan = @{
        Pass1SeekMs             = 0L
        Pass2ChaseInitialSeekMs = $ChaseInitialSeekMs
        Source                  = 'none'
    }
    if ($ChaseInitialSeekMs -ge 0) {
        $plan.Pass1SeekMs = $ChaseInitialSeekMs
        $plan.Pass2ChaseInitialSeekMs = -1
        $plan.Source = 'DPL'
        return $plan
    }
    if (-not $UseRegistryResume) { return $plan }

    $registrySeekScript = Join-Path $ScriptDir 'Get-PotPlayerRegistrySeek.ps1'
    if (-not (Test-Path -LiteralPath $registrySeekScript)) {
        Write-Warning "Get-PotPlayerRegistrySeek.ps1 not found; pass-1 starts at 0s."
        return $plan
    }
    . $registrySeekScript

    $ssMs = Get-SeekMsForRememberedPath -TargetPath $MediaFullPath -AlternatePaths $AlternateMediaPaths
    if ($ssMs -gt 0) {
        Write-Host "PotPlayer RememberFiles resume for pass-1: $ssMs ms (~$([math]::Round($ssMs / 60000.0, 2)) min)"
    }
    $quickSeekMs = Get-QuickSeekOverrideMs
    if ($null -ne $quickSeekMs) {
        $ssMs = [int64]$quickSeekMs
        Write-Host "Quick seek override for pass-1: $ssMs ms"
    }
    if ($ssMs -le 0) { return $plan }

    if ($FfprobeExe) {
        $durSec = Get-SafeFfprobeDurationSeconds -MediaPath $MediaFullPath -FfprobeExe $FfprobeExe
        if ($null -ne $durSec) {
            $capMs = [int64][Math]::Floor([Math]::Max(0.0, $durSec - 5.0) * 1000.0)
            if ($ssMs -gt $capMs) {
                Write-Warning ("RememberFiles seek {0} ms exceeds source duration {1}s; clamping pass-1 start to {2} ms." -f `
                    $ssMs, [math]::Round($durSec, 2), $capMs)
                $ssMs = $capMs
            }
        }
    }
    if ($ssMs -le 0) { return $plan }

    $plan.Pass1SeekMs = $ssMs
    $plan.Pass2ChaseInitialSeekMs = -1
    $plan.Source = 'RememberFiles'
    return $plan
}

function Wait-FisheyeMezzanineReady {
    param(
        [string] $Path,
        [int] $TimeoutSec,
        [int] $MinBytes,
        [string] $FfprobeExe,
        [string] $HeartbeatMediaFullPath = ''
    )
    $effectiveTimeoutSec = $TimeoutSec
    if (Test-WorkflowHasActiveDeadline) {
        $remainingSec = Get-WorkflowRemainingSec
        if ($remainingSec -lt $effectiveTimeoutSec) { $effectiveTimeoutSec = $remainingSec }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($effectiveTimeoutSec)
    $lastHeartbeat = [DateTime]::MinValue
    $heartbeatDivisor = if (Get-Command Get-PrepareWaitHeartbeatDivisorDefault -ErrorAction SilentlyContinue) {
        Get-PrepareWaitHeartbeatDivisorDefault
    } else { 5 }
    $heartbeatDurPath = if (-not [string]::IsNullOrWhiteSpace($HeartbeatMediaFullPath)) {
        $HeartbeatMediaFullPath
    } else { $Path }
    $mezzHeartbeatSec = if (Get-Command Resolve-PrepareWaitHeartbeatSeconds -ErrorAction SilentlyContinue) {
        Resolve-PrepareWaitHeartbeatSeconds -MediaFullPath $heartbeatDurPath -Divisor $heartbeatDivisor
    } else { 10 }
    $chaseReadyBytes = [Math]::Max($MinBytes, 1048576)
    Write-Host "Waiting for mezzanine (min $MinBytes bytes, chase at >= $chaseReadyBytes while pass-1 runs, timeout ${effectiveTimeoutSec}s, heartbeat ${mezzHeartbeatSec}s): $Path"
    while ([DateTime]::UtcNow -lt $deadline) {
        Assert-WorkflowNotExpired 'mezzanine ready wait'
        Assert-LauncherParentAlive 'mezzanine ready wait'
        if (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-TranscodeConsoleKeyPoll)
        }
        if (Test-FisheyePass1V360Failed -MezzaninePath $Path -AllowWhileRunning) {
            Assert-FisheyePass1Healthy -MezzaninePath $Path
        }
        $now = [DateTime]::UtcNow
        if ($mezzHeartbeatSec -gt 0 -and ($now - $lastHeartbeat).TotalSeconds -ge $mezzHeartbeatSec) {
            if (-not (Test-Path -LiteralPath $Path)) {
                $ff = if (Test-FisheyeMezzanineFfmpegRunning -MezzaninePath $Path) { 'running' } else { 'not running' }
                Write-Host "  ... still waiting (file not created yet; pass-1 ffmpeg $ff)"
            } else {
                $lenNow = (Get-Item -LiteralPath $Path).Length
                $durNow = Get-SafeFfprobeDurationSeconds -MediaPath $Path -FfprobeExe $FfprobeExe
                $probeStatus = if ($null -ne $durNow -and $durNow -gt 0) { "$([math]::Round($durNow, 2))s" } else { 'no duration yet (fragmented MP4 still growing)' }
                $ff = if (Test-FisheyeMezzanineFfmpegRunning -MezzaninePath $Path) { 'running' } else { 'not running' }
                Write-Host "  ... waiting size=$([math]::Round($lenNow/1MB, 2)) MB probe=$probeStatus pass-1 ffmpeg $ff"
            }
            $lastHeartbeat = $now
        }

        if (Test-Path -LiteralPath $Path) {
            $len = (Get-Item -LiteralPath $Path).Length
            $pass1Running = Test-FisheyeMezzanineFfmpegRunning -MezzaninePath $Path
            if ($len -ge $MinBytes) {
                $dur = Get-SafeFfprobeDurationSeconds -MediaPath $Path -FfprobeExe $FfprobeExe
                if ($null -ne $dur -and $dur -gt 0) {
                    Write-Host "Mezzanine ready: $([math]::Round($len/1MB, 2)) MB, probed duration ${dur}s"
                    return
                }
                if ($pass1Running -and $len -ge $chaseReadyBytes) {
                    Write-Host "Mezzanine chase-ready: $([math]::Round($len/1MB, 2)) MB (pass-1 still encoding fragmented MP4)"
                    return
                }
                if (-not $pass1Running) {
                    Write-Host "Mezzanine ready: $([math]::Round($len/1MB, 2)) MB (pass-1 finished)"
                    return
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for mezzanine: $Path. Check fisheye_temp\logs and Run-FisheyeV360.ps1."
}

function Resolve-TranscodeScriptPath {
    param(
        [string] $ExplicitPath,
        [string] $ScriptDir
    )
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "Transcode script not found: $ExplicitPath"
        }
        return [System.IO.Path]::GetFullPath($ExplicitPath)
    }
    $candidate = Join-Path $ScriptDir 'Run-TranscodeFfmpeg.ps1'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Run-TranscodeFfmpeg.ps1 not found beside prepare script: $candidate"
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-FisheyeChaseResumeStatePath {
    param([string] $MezzanineFullPath)
    $logDir = Join-Path ([System.IO.Path]::GetDirectoryName($MezzanineFullPath)) 'logs'
    return Join-Path $logDir 'chase_resume_state.json'
}

function Read-FisheyeChaseResumeState {
    param([string] $StateFilePath)
    if (-not (Test-Path -LiteralPath $StateFilePath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $StateFilePath -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        Write-Warning "Could not read chase resume state: $StateFilePath ($_)"
        return $null
    }
}

function Invoke-FisheyePass2TranscodePass {
    param(
        [string] $AvsFullPath,
        [string] $TranscodeScriptPath,
        [int64] $SeekMs,
        [string] $ChaseResumeStateFile = '',
        [int] $DlnaSegmentStartNumber = 0
    )
    $chasePassParams = @{
        LiteralPath              = $AvsFullPath
        SkipOrchestrator         = $true
        NoPause                  = $true
        NoClampSeek              = $true
        SsMsOverride             = [int]$SeekMs
        NoLogFile                = $true
        TranscodeTimeoutSec      = -1
        DlnaSegmentStartNumber   = $DlnaSegmentStartNumber
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SegmentNameSuffix)) {
        $chasePassParams['SegmentNameSuffix'] = $script:SegmentNameSuffix
    }
    if ($script:SegmentVideoBitrateMbps -gt 0) {
        $chasePassParams['SegmentVideoBitrateMbps'] = $script:SegmentVideoBitrateMbps
    }
    if (-not [string]::IsNullOrWhiteSpace($segmentOutputRootFull)) {
        $chasePassParams['OutputDirectory'] = $segmentOutputRootFull
    }
    if (-not [string]::IsNullOrWhiteSpace($ChaseResumeStateFile)) {
        $chasePassParams['ChaseResumeStateFile'] = $ChaseResumeStateFile
    }
    if ($script:LauncherParentPid -gt 0) {
        $chasePassParams['OrchestratorPid'] = $script:LauncherParentPid
        $chasePassParams['OrchestratorStartTimeUtc'] = $script:LauncherParentStartTimeUtc
    }
    if ((Get-Command Test-WorkflowHasActiveDeadline -ErrorAction SilentlyContinue) -and (Test-WorkflowHasActiveDeadline)) {
        $chasePassParams['WorkflowDeadlineUtc'] = Format-FisheyeWorkflowDeadlineUtcIso -DeadlineUtc $script:FisheyeWorkflowDeadlineUtc
    }
    & $TranscodeScriptPath @chasePassParams
    return [int]$LASTEXITCODE
}

function Invoke-FisheyePass2DlnaTailRefresh {
    param(
        [string] $AvsFullPath,
        [string] $TranscodeScriptPath,
        [double] $MezzanineDurationSec,
        [double] $LastRoundProgressSec
    )
    if ($MezzanineDurationSec -le 0) { return }
    $tailSpanSec = [Math]::Min(120.0, $MezzanineDurationSec)
    $seekSec = [Math]::Max(0.0, $MezzanineDurationSec - $tailSpanSec)
    $seekMs = [int64][Math]::Floor($seekSec * 1000.0)
    Write-Host ''
    Write-Host ("Pass-2 DLNA tail refresh: last round wrote ~{0}s (<60s leaves one 3d_op slot stale); re-encoding {1}s from seek {2}s to refresh both 3d_op_00/3d_op_01" -f `
        [math]::Round($LastRoundProgressSec, 2), [math]::Round($tailSpanSec, 2), [math]::Round($seekSec, 2))
    $ec = Invoke-FisheyePass2TranscodePass -AvsFullPath $AvsFullPath -TranscodeScriptPath $TranscodeScriptPath `
        -SeekMs $seekMs
    if ($ec -eq 130) {
        throw 'Launcher parent closed during pass-2 DLNA tail refresh.'
    }
    if ($ec -ne 0) {
        Write-Warning "Pass-2 DLNA tail refresh exited with code $ec (3d_op segments may still be partially stale)."
    } else {
        Write-Host 'Pass-2 DLNA tail refresh finished (both segment slots should match clip end).'
    }
}

function Invoke-FisheyePass2ChaseLoop {
    param(
        [string] $AvsFullPath,
        [string] $MezzanineFullPath,
        [string] $TranscodeScriptPath,
        [string] $FfprobeExe,
        [int] $PollDelaySec = 3,
        [int] $MaxStaleWaits = 120,
        [int64] $InitialSeekMs = -1
    )
    $stateFile = Get-FisheyeChaseResumeStatePath -MezzanineFullPath $MezzanineFullPath
    $seekMs = if ($InitialSeekMs -ge 0) { [int64]$InitialSeekMs } else { 0L }
    $lastRoundProgressSec = 0.0
    if ($InitialSeekMs -ge 0) {
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
            Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
            Write-Host 'Cleared prior pass-2 chase resume state (new DPL initial seek for this clip).'
        }
        Write-Host "Pass-2 chase initial seek: $([math]::Round($seekMs / 1000.0, 2))s ($seekMs ms)"
    }
    $round = 0
    $staleWaits = 0
    $lastEncodedSec = 0.0

    Write-Host "Pass-2 chase loop: resume state $stateFile"
    while ($true) {
        Assert-WorkflowNotExpired 'pass-2 chase loop'
        Assert-LauncherParentAlive 'pass-2 chase loop'
        Assert-FisheyePass1Healthy -MezzaninePath $MezzanineFullPath
        if (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-TranscodeConsoleKeyPoll)
        }
        $round++
        $seekSec = [double]$seekMs / 1000.0
        $pass1RunningNow = Test-FisheyeMezzanineFfmpegRunning -MezzaninePath $MezzanineFullPath
        $mezzDurNow = Get-SafeFfprobeDurationSeconds -MediaPath $MezzanineFullPath -FfprobeExe $FfprobeExe
        $effectiveSeekMs = $seekMs
        if ($null -ne $mezzDurNow -and $seekMs -gt 0) {
            $edgeMs = [int64][Math]::Floor([Math]::Max(0.0, $mezzDurNow - 5.0) * 1000.0)
            if ($effectiveSeekMs -gt $edgeMs) {
                if ($pass1RunningNow) {
                    Write-Host ("Pass-2 round ${round}: waiting for pass-1 mezzanine to reach seek $([math]::Round($seekSec, 2))s (probed $([math]::Round($mezzDurNow, 2))s)...")
                    Wait-WorkflowSleep -Seconds $PollDelaySec
                    continue
                }
                Write-Host ("Pass-2 round ${round}: target seek $([math]::Round($seekSec, 2))s at/beyond mezzanine $([math]::Round($mezzDurNow, 2))s; encoding from edge $([math]::Round($edgeMs / 1000.0, 2))s")
                $effectiveSeekMs = $edgeMs
            } else {
                Write-Host ("Pass-2 chase round {0}: seek {1}s -> 3d_op_{2} (~{3}s workflow remaining)" -f `
                    $round, [math]::Round($seekSec, 2), ('{0:D2}' -f (($round - 1) % 2)), (Get-WorkflowRemainingSec))
            }
        } else {
            if ($seekMs -gt 0 -and $pass1RunningNow -and ($null -eq $mezzDurNow -or $mezzDurNow -le 0)) {
                Write-Host ("Pass-2 round ${round}: waiting for mezzanine duration probe before seek $([math]::Round($seekSec, 2))s...")
                Wait-WorkflowSleep -Seconds $PollDelaySec
                continue
            }
            Write-Host ("Pass-2 chase round {0}: seek {1}s -> 3d_op_{2} (~{3}s workflow remaining)" -f `
                $round, [math]::Round($seekSec, 2), ('{0:D2}' -f (($round - 1) % 2)), (Get-WorkflowRemainingSec))
        }

        $segmentStart = ($round - 1) % 2
        $ec = Invoke-FisheyePass2TranscodePass -AvsFullPath $AvsFullPath -TranscodeScriptPath $TranscodeScriptPath `
            -SeekMs $effectiveSeekMs -ChaseResumeStateFile $stateFile -DlnaSegmentStartNumber $segmentStart
        if ($ec -eq 130) {
            throw 'Launcher parent closed during pass-2 transcode.'
        }

        $seekStartSec = $seekSec
        $lastEncodedSec = [double]$effectiveSeekMs / 1000.0
        $state = Read-FisheyeChaseResumeState -StateFilePath $stateFile
        if ($null -ne $state) {
            if ($null -ne $state.seekStartSec) { $seekStartSec = [double]$state.seekStartSec }
            if ($null -ne $state.lastEncodedSec) { $lastEncodedSec = [double]$state.lastEncodedSec }
        }

        $progressSec = $lastEncodedSec - $seekStartSec
        if ($progressSec -ge 0.5) {
            $lastRoundProgressSec = $progressSec
        }
        if ($ec -eq $script:ExitCodeWorkflowTimeout) {
            if ($progressSec -ge 0.5) {
                Write-Warning "Pass-2 transcode timed out (exit 124) after ~$([math]::Round($progressSec, 2))s progress; continuing chase..."
            } else {
                throw "Fisheye workflow timeout ($($script:FisheyeWorkflowTimeoutSec)s) during pass-2 transcode (round $round seek $([math]::Round($seekSec, 2))s)"
            }
        } elseif ($ec -ne 0 -and $progressSec -lt 0.5) {
            throw "Pass-2 transcode exited with code $ec (round $round seek $([math]::Round($seekSec, 2))s)"
        } elseif ($ec -ne 0) {
            Write-Warning "Pass-2 transcode exit code $ec after ~$([math]::Round($progressSec, 2))s progress; continuing chase from $([math]::Round($lastEncodedSec, 2))s"
        }

        $pass1Running = Test-FisheyeMezzanineFfmpegRunning -MezzaninePath $MezzanineFullPath
        $mezzDur = Get-SafeFfprobeDurationSeconds -MediaPath $MezzanineFullPath -FfprobeExe $FfprobeExe
        $mezzDurText = if ($null -ne $mezzDur) { "$([math]::Round($mezzDur, 2))s" } else { 'unknown' }
        Write-Host ("Pass-2 round {0} done: encoded to {1}s (progress {2}s) pass-1={3} mezzanine={4}" -f `
            $round, [math]::Round($lastEncodedSec, 2), [math]::Round($progressSec, 2), `
            $(if ($pass1Running) { 'running' } else { 'finished' }), $mezzDurText)

        if ($progressSec -lt 0.5) {
            if ($pass1Running) {
                Assert-FisheyePass1Healthy -MezzaninePath $MezzanineFullPath
                $staleWaits++
                if ($staleWaits -ge $MaxStaleWaits) {
                    throw "Pass-2 chase stalled after $MaxStaleWaits waits for mezzanine growth (last seek $([math]::Round($seekSec, 2))s)"
                }
                Write-Host "  Mezzanine edge reached; waiting ${PollDelaySec}s for pass-1 (${staleWaits}/${MaxStaleWaits})..."
                Wait-WorkflowSleep -Seconds $PollDelaySec
                continue
            }
            Assert-FisheyePass1Healthy -MezzaninePath $MezzanineFullPath
            break
        }

        $staleWaits = 0
        $nextSeekMs = [int64][Math]::Floor($lastEncodedSec * 1000.0)
        if ($nextSeekMs -le $seekMs) { $nextSeekMs = $seekMs + 500L }
        $seekMs = $nextSeekMs

        if (-not $pass1Running) {
            if ($null -ne $mezzDur -and $lastEncodedSec -ge ($mezzDur - 1.0)) { break }
            if ($progressSec -lt 1.0) { break }
        }
    }

    Write-Host "Pass-2 chase loop finished after $round round(s); last encoded ~$([math]::Round($lastEncodedSec, 2))s"

    $mezzDurFinal = Get-SafeFfprobeDurationSeconds -MediaPath $MezzanineFullPath -FfprobeExe $FfprobeExe
    if ($null -ne $mezzDurFinal -and $mezzDurFinal -gt 0 -and $lastRoundProgressSec -gt 0 -and $lastRoundProgressSec -lt 60) {
        Invoke-FisheyePass2DlnaTailRefresh -AvsFullPath $AvsFullPath -TranscodeScriptPath $TranscodeScriptPath `
            -MezzanineDurationSec $mezzDurFinal -LastRoundProgressSec $lastRoundProgressSec
    }
}

function Get-FisheyeChaseLogPaths {
    param(
        [string] $MezzanineFullPath,
        [string] $AvsFullPath
    )
    $logDir = Join-Path ([System.IO.Path]::GetDirectoryName($MezzanineFullPath)) 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $avsLeaf = [System.IO.Path]::GetFileName($AvsFullPath)
    if ($avsLeaf.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
        $avsLeaf = $avsLeaf.Substring(0, $avsLeaf.Length - 4)
    }
    $safe = ($avsLeaf -replace '[\\/:*?"<>|]', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'chase' }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    return @{
        StdOut = Join-Path $logDir ("chase_${stamp}_${safe}.stdout.log")
        StdErr = Join-Path $logDir ("chase_${stamp}_${safe}.stderr.log")
    }
}

function Write-FisheyePass2WorkerLocation {
    param(
        [int] $WorkerPid,
        [string] $StdOutLog,
        [string] $StdErrLog,
        [string] $SegmentOutputDirectory
    )
    $segments = Join-Path $SegmentOutputDirectory $script:DlnaSegmentPattern
    Write-Host "Pass-2 hidden worker pid=$WorkerPid (no console window)"
    Write-Host "Pass-2 transcript:  $StdOutLog"
    Write-Host "Pass-2 stderr log:  $StdErrLog"
    Write-Host "Pass-2 DLNA output: $segments"
    Write-Host 'Pass-2 tail the transcript path above for live chase progress.'
}

function Start-FisheyePass2ChaseWorker {
    param(
        [string] $PrepareScriptPath,
        [string] $AvsFullPath,
        [string] $MezzanineFullPath,
        [string] $TranscodeScriptPath,
        [int] $MezzanineReadyTimeoutSec,
        [int] $MezzanineReadyMinBytes,
        [int] $Pass2StartDelaySec,
        [int] $ChasePollDelaySec,
        [int] $ChaseMaxStaleWaits,
        [string] $WorkflowDeadlineUtc,
        [string] $SegmentOutputDirectory = '',
        [int] $ParentLauncherPid = 0,
        [string] $ParentStartTimeUtc = ''
    )
    if (-not (Test-Path -LiteralPath $AvsFullPath -PathType Leaf)) {
        throw "Pass-2 chase AVS missing before worker launch: $AvsFullPath"
    }
    if ($ParentLauncherPid -le 0) {
        $ParentLauncherPid = $PID
    }
    if ([string]::IsNullOrWhiteSpace($ParentStartTimeUtc)) {
        $ParentStartTimeUtc = Get-SafeProcessStartTimeUtc -ProcessId $ParentLauncherPid
    }
    $shell = (Get-Command powershell -ErrorAction Stop).Source
    $logs = Get-FisheyeChaseLogPaths -MezzanineFullPath $MezzanineFullPath -AvsFullPath $AvsFullPath
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PrepareScriptPath,
        '-ChaseOnly',
        '-ChaseWorker',
        '-ChaseAvsPath', $AvsFullPath,
        '-ChaseMezzaninePath', $MezzanineFullPath,
        '-TranscodeScript', $TranscodeScriptPath,
        '-MezzanineReadyTimeoutSec', "$MezzanineReadyTimeoutSec",
        '-MezzanineReadyMinBytes', "$MezzanineReadyMinBytes",
        '-Pass2StartDelaySec', "$Pass2StartDelaySec",
        '-ChasePollDelaySec', "$ChasePollDelaySec",
        '-ChaseMaxStaleWaits', "$ChaseMaxStaleWaits",
        '-WorkflowDeadlineUtc', $WorkflowDeadlineUtc,
        '-ParentPid', "$ParentLauncherPid",
        '-ParentStartTimeUtc', $ParentStartTimeUtc,
        '-NoPause'
    )
    if (-not [string]::IsNullOrWhiteSpace($SegmentOutputDirectory)) {
        $argList += @('-SegmentOutputDirectory', $SegmentOutputDirectory)
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SegmentNameSuffix)) {
        $argList += @('-SegmentNameSuffix', $script:SegmentNameSuffix)
    }
    if ($script:SegmentVideoBitrateMbps -gt 0) {
        $argList += @('-SegmentVideoBitrateMbps', "$($script:SegmentVideoBitrateMbps)")
    }
    $p = Start-Process -FilePath $shell -ArgumentList (Format-ProcessArgumentLine $argList) -PassThru `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($PrepareScriptPath)) `
        -WindowStyle Hidden
    Write-FisheyePass2WorkerLocation -WorkerPid $p.Id -StdOutLog $logs.StdOut -StdErrLog $logs.StdErr `
        -SegmentOutputDirectory $SegmentOutputDirectory
    return @{
        Pid       = $p.Id
        Process   = $p
        StdOutLog = $logs.StdOut
        StdErrLog = $logs.StdErr
    }
}

function Wait-FisheyePass2ChaseWorker {
    param(
        [System.Diagnostics.Process] $WorkerProc,
        [string] $StdOutLog = '',
        [string] $MediaFullPath = '',
        [int] $PollMs = 500,
        [int] $HeartbeatSec = 0,
        [int] $HeartbeatDivisor = $(if (Get-Command Get-PrepareWaitHeartbeatDivisorDefault -ErrorAction SilentlyContinue) {
            Get-PrepareWaitHeartbeatDivisorDefault
        } else { 5 })
    )
    if ($null -eq $WorkerProc) { return $null }
    $effectiveHeartbeatSec = if ($HeartbeatSec -gt 0) {
        $HeartbeatSec
    } elseif (Get-Command Resolve-PrepareWaitHeartbeatSeconds -ErrorAction SilentlyContinue) {
        Resolve-PrepareWaitHeartbeatSeconds -MediaFullPath $MediaFullPath -Divisor $HeartbeatDivisor
    } else {
        60
    }
    if ($effectiveHeartbeatSec -gt 0 -and -not [string]::IsNullOrWhiteSpace($MediaFullPath) `
        -and (Get-Command Get-PrepareMediaDurationSeconds -ErrorAction SilentlyContinue)) {
        $durHint = Get-PrepareMediaDurationSeconds -MediaFullPath $MediaFullPath
        if ($null -ne $durHint -and $durHint -gt 0) {
            Write-Host ("Pass-2 wait heartbeat: ${effectiveHeartbeatSec}s (~$([math]::Round($durHint))s source / $HeartbeatDivisor)")
        } else {
            Write-Host "Pass-2 wait heartbeat: ${effectiveHeartbeatSec}s (duration unknown; fallback 60s)"
        }
    } elseif ($effectiveHeartbeatSec -gt 0) {
        Write-Host "Pass-2 wait heartbeat: ${effectiveHeartbeatSec}s"
    }
    Write-Host "Waiting for pass-2 worker pid=$($WorkerProc.Id) (transcript has live progress)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastHeartbeat = [DateTime]::UtcNow
    while ($true) {
        Assert-WorkflowNotExpired 'pass-2 worker wait'
        if (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-TranscodeConsoleKeyPoll)
        }
        $exited = $true
        try {
            $WorkerProc.Refresh()
            $exited = $WorkerProc.HasExited
        } catch {
            break
        }
        if ($exited) { break }
        if ($effectiveHeartbeatSec -gt 0 -and ([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge $effectiveHeartbeatSec) {
            $elapsedSec = [int][Math]::Floor($sw.Elapsed.TotalSeconds)
            $statusHint = if (-not [string]::IsNullOrWhiteSpace($StdOutLog) `
                -and (Get-Command Get-PrepareLogStatusHint -ErrorAction SilentlyContinue)) {
                Get-PrepareLogStatusHint -StdOutPath $StdOutLog
            } else { '' }
            $statusNote = if ($statusHint) { " last: $statusHint" } else { '' }
            Write-Host ("  ... pass-2 worker still running ({0}s elapsed, ~{1}s workflow remaining).{2}" -f `
                $elapsedSec, $(Get-WorkflowRemainingSec), $statusNote)
            $lastHeartbeat = [DateTime]::UtcNow
        }
        Start-Sleep -Milliseconds $PollMs
    }
    try {
        if (-not $WorkerProc.HasExited) { return $null }
        return [int]$WorkerProc.ExitCode
    } catch {
        return $null
    }
}

$TemplatePath = Resolve-TemplatePath -ExplicitPath $TemplatePath -ScriptDir $thisScriptDir
$FisheyeV360Script = Resolve-FisheyeV360ScriptPath -ExplicitPath $FisheyeV360Script -ScriptDir $thisScriptDir

$exitCode = 0
$batchTranscriptActive = $false
$pass2WorkerInfo = $null
$pass2WorkerWaited = $false
$fisheyeBatchFollowUpMedia = ''
$shouldPause = (-not $NoPause) -and $ContextMenu -and -not $ChaseOnly -and -not $DryRun
$isChaseWorker = $ChaseOnly -and $ChaseWorker

if ($ChaseOnly) {
    $chaseTranscriptActive = $false
    $chaseTranscriptPath = $null
    try {
        Initialize-WorkflowDeadline -ExplicitDeadlineUtc $WorkflowDeadlineUtc `
            -TimeoutSec (Resolve-FisheyeWorkflowTimeoutSec -WorkflowDeadlineUtc $WorkflowDeadlineUtc `
                -WorkflowTimeoutSec $WorkflowTimeoutSec -ContextMenu:$ContextMenu.IsPresent) `
            -FisheyeTempRoot $fisheyeOutputRootFull
        if ($ParentPid -gt 0) {
            Initialize-LauncherParentWatch -ParentPid $ParentPid -ParentStartTimeUtc $ParentStartTimeUtc
        }
        if ([string]::IsNullOrWhiteSpace($ChaseAvsPath) -or [string]::IsNullOrWhiteSpace($ChaseMezzaninePath)) {
            throw 'ChaseOnly requires -ChaseAvsPath and -ChaseMezzaninePath.'
        }
        $avsFull = [System.IO.Path]::GetFullPath($ChaseAvsPath)
        $mezzFull = [System.IO.Path]::GetFullPath($ChaseMezzaninePath)
        if (-not (Test-Path -LiteralPath $avsFull -PathType Leaf)) {
            throw "Chase AVS not found: $avsFull"
        }
        if ($isChaseWorker) {
            $chaseLogs = Get-FisheyeChaseLogPaths -MezzanineFullPath $mezzFull -AvsFullPath $avsFull
            $chaseTranscriptPath = $chaseLogs.StdOut
            try {
                Start-Transcript -Path $chaseTranscriptPath -Append -ErrorAction Stop | Out-Null
                $chaseTranscriptActive = $true
            } catch {
                Write-Warning "Chase transcript logging failed; console output only: $_"
            }
            Write-Host ''
            Write-Host '=== Pass-2 chase worker (hidden background) ===' -ForegroundColor Cyan
            if ($chaseTranscriptActive) {
                Write-Host "Transcript: $chaseTranscriptPath"
            }
            Write-Host ''
        }
        $transcodeFull = Resolve-TranscodeScriptPath -ExplicitPath $TranscodeScript -ScriptDir $thisScriptDir
        $ffprobeExe = Get-FfprobeExePath -FfmpegExe $null

        Write-Host "Pass-2 chase: AVS=$avsFull"
        Write-Host "Pass-2 chase: mezzanine=$mezzFull"
        Write-Host "Pass-2 chase: transcode=$transcodeFull"
        if ($Pass2StartDelaySec -gt 0) {
            Write-Host "Pass-2 delay: ${Pass2StartDelaySec}s before mezzanine poll..."
            Wait-WorkflowSleep -Seconds $Pass2StartDelaySec
        }

        Wait-FisheyeMezzanineReady -Path $mezzFull -TimeoutSec $MezzanineReadyTimeoutSec `
            -MinBytes $MezzanineReadyMinBytes -FfprobeExe $ffprobeExe -HeartbeatMediaFullPath $mezzFull

        Invoke-FisheyePass2ChaseLoop -AvsFullPath $avsFull -MezzanineFullPath $mezzFull `
            -TranscodeScriptPath $transcodeFull -FfprobeExe $ffprobeExe `
            -PollDelaySec $ChasePollDelaySec -MaxStaleWaits $ChaseMaxStaleWaits
        Write-Host 'Pass-2 chase loop finished successfully.'
    } catch {
        $exitCode = Resolve-FisheyeExitCodeFromError -ErrorRecord $_
        Write-Host ''
        if ($exitCode -eq $script:ExitCodeWorkflowTimeout) {
            Write-Host "PASS-2 CHASE TIMEOUT: $_" -ForegroundColor Red
        } elseif ($exitCode -eq $script:ExitCodeParentClosed) {
            Write-Host "PASS-2 CHASE STOPPED: $_" -ForegroundColor Yellow
        } else {
            Write-Host "PASS-2 CHASE ERROR: $_" -ForegroundColor Red
        }
    } finally {
        if ($shouldPause) {
            Write-Host ''
            Wait-PressEnterToClose -Prompt 'Press Enter to close this window...'
        } elseif ($isChaseWorker -and $exitCode -eq $script:ExitCodeParentClosed) {
            Write-Host ''
            Write-Host 'Launcher window closed; pass-2 chase stopped.'
        } elseif ($isChaseWorker -and $exitCode -eq $script:ExitCodeWorkflowTimeout) {
            Write-Host ''
            Write-Host "Pass-2 chase timed out ($($script:FisheyeWorkflowTimeoutSec)s workflow limit). Stopping ffmpeg and closing in 20 seconds..."
            Start-Sleep -Seconds 20
        } elseif ($isChaseWorker -and $exitCode -ne 0) {
            Write-Host ''
            Write-Host 'Pass-2 chase failed. See output above; transcript under fisheye_temp\logs\chase_*.stdout.log - closing in 20 seconds...'
            Start-Sleep -Seconds 20
        } elseif ($isChaseWorker -and $exitCode -eq 0) {
            Write-Host ''
            Write-Host 'Pass-2 chase complete. Closing in 8 seconds...'
            Start-Sleep -Seconds 8
        }
    }
    if ($chaseTranscriptActive) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    exit $exitCode
}

$runAutoChase = ($AutoChaseTranscode -or ($ContextMenu -and -not $NoAutoChaseTranscode))

if (-not $ChaseOnly -and $OrchestratorPid -gt 0) {
    Initialize-LauncherParentWatch -ParentPid $OrchestratorPid -ParentStartTimeUtc $OrchestratorStartTimeUtc
}

try {
    if (-not [string]::IsNullOrWhiteSpace($BatchStdOutLog)) {
        $batchLogDir = [System.IO.Path]::GetDirectoryName($BatchStdOutLog)
        if (-not [string]::IsNullOrWhiteSpace($batchLogDir) -and -not (Test-Path -LiteralPath $batchLogDir)) {
            [void][System.IO.Directory]::CreateDirectory($batchLogDir)
        }
        try {
            Start-Transcript -Path $BatchStdOutLog -Force -ErrorAction Stop | Out-Null
            $batchTranscriptActive = $true
        } catch {
            Write-Warning "Batch prepare transcript failed ($_); logging to console only."
        }
    }
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        throw 'Input path not provided (-LiteralPath required for prepare).'
    }
    $clickedMediaFull = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not (Test-Path -LiteralPath $clickedMediaFull -PathType Leaf)) {
        throw "Input not found: $clickedMediaFull"
    }
    $mediaFull = if (Get-Command Resolve-StandardizedMediaPath -ErrorAction SilentlyContinue) {
        Resolve-StandardizedMediaPath -MediaFullPath $clickedMediaFull
    } else {
        $clickedMediaFull
    }
    if ($mediaFull -ne $clickedMediaFull) {
        Write-Host "Standardized variant found; using: $mediaFull (clicked: $clickedMediaFull)"
    }
    $mediaExt = [System.IO.Path]::GetExtension($mediaFull)
    if ($mediaExt -notin @('.mp4', '.mkv', '.mov', '.m4v', '.avi', '.wmv', '.ts', '.m2ts', '.webm')) {
        throw "Unsupported media extension '$mediaExt' (expected .mp4/.mkv/.mov/.m4v/.avi/.wmv/.ts/.m2ts/.webm)."
    }
    if (-not $FisheyeV360Script -or -not (Test-Path -LiteralPath $FisheyeV360Script)) {
        throw @(
            "Run-FisheyeV360.ps1 not found beside prepare script:",
            "  $(Join-Path $thisScriptDir 'Run-FisheyeV360.ps1')",
            "  (sync individual_transcode from P:\all_scripts\3d_playlist_local)"
        ) -join [Environment]::NewLine
    }
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Template not found: $TemplatePath (sync individual_transcode from P:\all_scripts\3d_playlist_local)"
    }

    $mediaBase = [System.IO.Path]::GetFileNameWithoutExtension($mediaFull)
    $fragFile = Join-Path $fragDir (Get-FisheyeMezzanineFileName -MediaBase $mediaBase)
    $avsFile = Get-FisheyeTempAvsFullPath -MediaFullPath $mediaFull -AvsDirectory $avsDir

    Write-Host "Media:          $mediaFull"
    Write-Host "Fisheye root:   $fisheyeOutputRootFull"
    Write-Host "Mezzanine:      $fragFile (av1_qsv ${MezzanineVideoBitrateMbps}M pass 1)"
    Write-Host "AVS output:     $avsFile"
    Write-Host "Template:       $TemplatePath"
    Write-Host "V360 script:    $FisheyeV360Script"
    if ($runAutoChase) {
        if ($ChaseSync) {
            Write-Host "Pass 2:         inline chase in this window -> $(Join-Path $segmentOutputRootFull $script:DlnaSegmentPattern)"
        } elseif ($ContextMenu) {
            Write-Host "Pass 2:         hidden background worker -> $(Join-Path $segmentOutputRootFull $script:DlnaSegmentPattern)"
        } else {
            Write-Host "Pass 2:         background worker after mezzanine ready -> $(Join-Path $segmentOutputRootFull $script:DlnaSegmentPattern)"
        }
    } else {
        Write-Host "Next step:      transcode the AVS above -> 60s segments in 3d_fullsbs_trans\fisheye"
    }
    if ($runAutoChase) {
        Write-Host 'Console:        Space=pause/resume leaf DLNA export ffmpeg (3d_op_*.mkv only; pass-1 mezzanine keeps running)'
    }

    if ($DryRun) {
        Write-Host "[DryRun] Would clear fisheye_temp mezzanine/AVS/logs (pass-2 overwrites 3d_op_* one segment at a time): $fisheyeOutputRootFull"
        if ($runAutoChase) {
            Write-Host '[DryRun] Would start v360 background, export AVS, and run pass-2 chase (sync or background worker).'
        } else {
            Write-Host '[DryRun] Would start v360 background and export AVS (no segment transcode).'
        }
        return
    }

    $effectiveWorkflowTimeoutSec = Resolve-FisheyeWorkflowTimeoutSec -WorkflowDeadlineUtc $WorkflowDeadlineUtc `
        -WorkflowTimeoutSec $WorkflowTimeoutSec -ContextMenu:$ContextMenu.IsPresent `
        -SourceMediaPath $mediaFull -FfprobeExe (Get-FfprobeExePath -FfmpegExe $null)
    if ($ContextMenu.IsPresent -and [string]::IsNullOrWhiteSpace($WorkflowDeadlineUtc)) {
        Write-Host "Workflow timeout: ${effectiveWorkflowTimeoutSec}s for this clip (pass-1 + pass-2; stops ffmpeg on deadline, exit 124)"
    }
    Initialize-WorkflowDeadline -ExplicitDeadlineUtc $WorkflowDeadlineUtc -TimeoutSec $effectiveWorkflowTimeoutSec `
        -FisheyeTempRoot $fisheyeOutputRootFull

    foreach ($dir in @($fragDir, $avsDir, $segmentOutputRootFull)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    Clear-FisheyeTempMedia -FisheyeTempRoot $fisheyeOutputRootFull

    $fisheyeV360Full = [System.IO.Path]::GetFullPath($FisheyeV360Script)
    $clearArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fisheyeV360Full,
        '-LiteralPath', $mediaFull,
        '-OutputFile', $fragFile,
        '-ClearOutputOnly'
    )
    Write-Host "Clearing prior mezzanine output (same path overwrite): $fragFile"
    & powershell.exe @clearArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Could not clear existing mezzanine output (exit $LASTEXITCODE): $fragFile"
    }

    $pass1SeekPlan = Resolve-FisheyePass1StartSeekMs -ChaseInitialSeekMs $ChaseInitialSeekMs `
        -MediaFullPath $mediaFull -AlternateMediaPaths @($clickedMediaFull) `
        -FfprobeExe (Get-FfprobeExePath -FfmpegExe $null) `
        -ScriptDir $thisScriptDir -UseRegistryResume:$ContextMenu.IsPresent
    $pass1SeekSec = [double]$pass1SeekPlan.Pass1SeekMs / 1000.0
    $pass2ChaseInitialSeekMs = $pass1SeekPlan.Pass2ChaseInitialSeekMs
    if ($pass1SeekPlan.Source -eq 'DPL' -and $ChaseInitialSeekMs -ge 0) {
        Write-Host ("Pass-1 mezzanine start seek: {0}s (PotPlayer DPL; pass-2 chase from mezzanine t=0)" -f `
            [math]::Round($pass1SeekSec, 2))
    } elseif ($pass1SeekPlan.Pass1SeekMs -gt 0) {
        Write-Host ("Pass-1 mezzanine start seek: {0}s (PotPlayer RememberFiles; pass-2 chase from mezzanine t=0)" -f `
            [math]::Round($pass1SeekSec, 2))
    }

    $v360Args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $fisheyeV360Full,
        '-LiteralPath', $mediaFull,
        '-OutputFile', $fragFile,
        '-VideoBitrateMbps', "$MezzanineVideoBitrateMbps",
        '-Background'
    )
    if ($pass1SeekSec -gt 0) {
        $ssFmt = $pass1SeekSec.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
        $v360Args += @('-SsSec', $ssFmt)
    }
    Write-Host "Starting v360 encode (background): $fisheyeV360Full"
    $pass1LogErr = Join-Path (Join-Path $fisheyeOutputRootFull 'logs') `
        ([System.IO.Path]::GetFileNameWithoutExtension($fragFile) + '_v360.stderr.log')
    Write-Host "Pass-1 hidden ffmpeg log: $pass1LogErr"
    $v360Proc = Start-Process -FilePath (Get-Command powershell -ErrorAction Stop).Source `
        -ArgumentList (Format-ProcessArgumentLine $v360Args) -PassThru `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($fisheyeV360Full)) `
        -WindowStyle Hidden
    Write-Host "V360 launcher pid=$($v360Proc.Id) (child ffmpeg logged by Run-FisheyeV360.ps1)"
    Wait-FisheyeV360Launcher -LauncherProc $v360Proc -MezzaninePath $fragFile -FisheyeV360ScriptPath $fisheyeV360Full

    Export-AvsFromFisheyeTemplate -TemplatePath $TemplatePath -FragMediaFullPath $fragFile `
        -AvsOutFullPath $avsFile -SourceMediaFullPath $mediaFull -FfprobeExe (Get-FfprobeExePath -FfmpegExe $null)
    Remove-StaleFisheyeTempAvs -AvsDir $avsDir -KeepAvsFullPath $avsFile

    if ($runAutoChase) {
        $transcodeFull = Resolve-TranscodeScriptPath -ExplicitPath $TranscodeScript -ScriptDir $thisScriptDir
        if ($ChaseSync) {
            $ffprobeForChase = Get-FfprobeExePath -FfmpegExe $null
            if ($Pass2StartDelaySec -gt 0) {
                Write-Host "Pass-2 delay: ${Pass2StartDelaySec}s before mezzanine poll..."
                Wait-WorkflowSleep -Seconds $Pass2StartDelaySec
            }
            Wait-FisheyeMezzanineReady -Path $fragFile -TimeoutSec $MezzanineReadyTimeoutSec `
                -MinBytes $MezzanineReadyMinBytes -FfprobeExe $ffprobeForChase -HeartbeatMediaFullPath $mediaFull
            Invoke-FisheyePass2ChaseLoop -AvsFullPath $avsFile -MezzanineFullPath $fragFile `
                -TranscodeScriptPath $transcodeFull -FfprobeExe $ffprobeForChase `
                -PollDelaySec $ChasePollDelaySec -MaxStaleWaits $ChaseMaxStaleWaits `
                -InitialSeekMs $pass2ChaseInitialSeekMs
            Write-Host 'Pass-2 chase loop finished successfully.'
        } else {
            $workerParentPid = if ($ContextMenu.IsPresent) { 0 } else { $PID }
            if ($ContextMenu.IsPresent) {
                Write-Host 'Pass-2 worker runs detached (closing this window early will not stop pass-2).'
            }
            $pass2WorkerInfo = Start-FisheyePass2ChaseWorker -PrepareScriptPath $thisScriptPath `
                -AvsFullPath $avsFile -MezzanineFullPath $fragFile -TranscodeScriptPath $transcodeFull `
                -MezzanineReadyTimeoutSec $MezzanineReadyTimeoutSec `
                -MezzanineReadyMinBytes $MezzanineReadyMinBytes -Pass2StartDelaySec $Pass2StartDelaySec `
                -ChasePollDelaySec $ChasePollDelaySec -ChaseMaxStaleWaits $ChaseMaxStaleWaits `
                -WorkflowDeadlineUtc (Format-FisheyeWorkflowDeadlineUtcIso -DeadlineUtc $script:FisheyeWorkflowDeadlineUtc) `
                -SegmentOutputDirectory $segmentOutputRootFull `
                -ParentLauncherPid $workerParentPid -ParentStartTimeUtc $(if ($workerParentPid -gt 0) {
                    Get-SafeProcessStartTimeUtc -ProcessId $workerParentPid
                } else {
                    ''
                })
            if ($ContextMenu.IsPresent -and $null -ne $pass2WorkerInfo.Process) {
                $workerExit = Wait-FisheyePass2ChaseWorker -WorkerProc $pass2WorkerInfo.Process `
                    -StdOutLog $pass2WorkerInfo.StdOutLog -MediaFullPath $mediaFull
                $pass2WorkerWaited = $true
                if ($null -ne $workerExit) {
                    if ($workerExit -ne 0) {
                        $exitCode = $workerExit
                        if ($workerExit -eq $script:ExitCodeParentClosed) {
                            Write-Warning 'Pass-2 stopped because this prepare window was closed.'
                        } elseif ($workerExit -eq $script:ExitCodeWorkflowTimeout) {
                            Write-Warning "Pass-2 timed out ($($script:FisheyeWorkflowTimeoutSec)s workflow limit)."
                        } else {
                            Write-Warning "Pass-2 worker exited with code $workerExit (see chase transcript)."
                        }
                    } else {
                        Write-Host 'Pass-2 chase loop finished successfully.'
                    }
                } else {
                    Write-Warning 'Could not read pass-2 worker exit code.'
                }
            }
        }
    }

    Write-Host ''
    if ($runAutoChase -and $ChaseSync) {
        Write-Host 'Done. Pass-1 mezzanine + pass-2 DLNA chase finished for this clip.'
        Write-BatchPrepareFinishedMarker -BatchStdOutLog $BatchStdOutLog
    } elseif ($pass2WorkerWaited -and $exitCode -eq 0) {
        Write-Host 'Done. Pass-1 mezzanine + pass-2 DLNA chase finished for this clip.'
        if ($ContextMenu.IsPresent -and (Get-Command Start-FisheyeBatchQueueFollowUp -ErrorAction SilentlyContinue)) {
            $fisheyeBatchFollowUpMedia = $mediaFull
        }
    } else {
        Write-Host 'Done. Pass-1 v360 ffmpeg still encoding in background (hidden).'
        if ($runAutoChase -and $null -ne $pass2WorkerInfo) {
            Write-Host ("Pass-2 hidden worker pid={0}; polls mezzanine then chases DLNA segments." -f $pass2WorkerInfo.Pid)
            Write-Host "Pass-2 transcript:  $($pass2WorkerInfo.StdOutLog)"
            Write-Host "Pass-2 DLNA output: $(Join-Path $segmentOutputRootFull $script:DlnaSegmentPattern)"
            Write-Host 'Close this prepare window (Enter or X) to stop the hidden pass-2 worker.'
        } elseif ($runAutoChase) {
            Write-Host 'Pass-2 chase worker was not started.'
        } else {
            Write-Host "When mezzanine is readable, transcode: $avsFile"
        }
    }
}
catch {
    $exitCode = Resolve-FisheyeExitCodeFromError -ErrorRecord $_
    Write-Host ''
    if ($exitCode -eq $script:ExitCodeWorkflowTimeout) {
        Write-Error "Fisheye workflow timed out ($($script:FisheyeWorkflowTimeoutSec)s): $_"
    } else {
        Write-Error $_
    }
}
finally {
    if ($runAutoChase -and $ChaseSync -and $exitCode -eq 0) {
        Write-BatchPrepareFinishedMarker -BatchStdOutLog $BatchStdOutLog
    }
    if ($batchTranscriptActive) {
        try { Stop-Transcript | Out-Null } catch { }
        $batchTranscriptActive = $false
    }
    if ($shouldPause) {
        Write-Host ''
        if ($pass2WorkerWaited -and $exitCode -eq 0) {
            Write-Host 'Fisheye prepare complete. Closing in 8 seconds...'
            Start-Sleep -Seconds 8
        } elseif ($exitCode -eq $script:ExitCodeWorkflowTimeout) {
            Wait-PressEnterToClose -Prompt 'Fisheye workflow timed out. Press Enter to close...'
        } elseif ($exitCode -ne 0) {
            Wait-PressEnterToClose -Prompt 'Pass-2 failed or stopped. Press Enter to close...'
        } elseif ($runAutoChase -and -not $ChaseSync) {
            $closePrompt = if ($null -ne $pass2WorkerInfo) {
                "Press Enter to close this prepare window (stops hidden pass-2 worker pid $($pass2WorkerInfo.Pid))..."
            } else {
                'Press Enter to close this prepare window (stops hidden pass-2 worker)...'
            }
            Wait-PressEnterToClose -Prompt $closePrompt
        } else {
            Wait-PressEnterToClose -Prompt 'Press Enter to close this window...'
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($fisheyeBatchFollowUpMedia) `
    -and (Get-Command Start-FisheyeBatchQueueFollowUp -ErrorAction SilentlyContinue)) {
    try {
        Start-FisheyeBatchQueueFollowUp -CompletedMediaFullPath $fisheyeBatchFollowUpMedia -ScriptDir $thisScriptDir
    } catch {
        Write-Warning "Fisheye batch queue follow-up failed: $_"
    }
}

exit $exitCode
