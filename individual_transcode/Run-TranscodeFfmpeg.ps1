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
  For .avs: ffprobe/resume rules use DirectShowSource path embedded in the AVS when present (fisheye_temp template AVS);
  otherwise finds source two folders up (..\\..\\); basename drops StreamTo3D., optional embedded media ext
  (e.g. .mp4 in name.mp4.avs), then .avs; flat DLNA segment mux always uses -readrate 1 (segment_wrap 2 viewing pace);
  height/bitrate probes are logged only (legacy -re gates removed for flat path). Seek (-ss) is checked against ffprobe format=duration on the same probe path
  unless -NoClampSeek: if resume is past the usable end (duration minus 0.25s tail), ffmpeg is skipped (exit 0) so the
  orchestrator can treat the clip as done and continue the playlist. Pass -NoClampSeek to send the raw seek to ffmpeg instead.
  By default a transcript is appended under .\transcode_logs\ next to
  before starting so the same path can be reused (wrap / rotate).
  Log and failure-summary paths are rooted at this script's folder (directory of the .ps1 file that PowerShell loaded),
  not at Get-Location / Explorer's working directory - so logs always sit beside the copy of Run-TranscodeFfmpeg.ps1 that
  actually ran. If you duplicate scripts to another drive or tree but Explorer still launches an older path, logs stay
  under that older path: re-run Install-ContextMenu.ps1 from the folder whose launcher you want, or pass an explicit
  -TranscodeScript to the orchestrator. After a successful context-menu .avs transcode, the follow-up orchestrator is
  started with -TranscodeScript set to this same script file's full path, so queued child transcodes keep using that
  same transcode_logs\ root until the registered launcher or -TranscodeScript changes.
  Explorer context menu (-ContextMenu or parent explorer.exe): after a successful .avs transcode, runs
  Run-TranscodeOrchestrator.ps1 (playlist.m3u beside orchestrator in the parent folder, or found walking up from .avs)
  with -SkipPotPlayer and -SkipCompanionBinaries so the orchestrator does not spawn PotPlayer for the DPL preview gate or
  relaunch AutoHotkey companions on that handover.
  Direct media (.mp4 etc., not .avs): prefers 3d_playlist_local\standardized\{filename} when present
  (Resolve-StandardizedMediaPath.ps1; same rule as batch listings / fisheye prepare).
  Queue order uses M3U
  plus playlist.m3u.transcode_queue_last / optional # transcode-queue-last: lines; per-clip ffmpeg -ss still uses RememberFiles registry lookup.
  This script reads PotPlayer/DAUM RememberFiles for resume seek but does not write/update PotPlayer registry entries.
  New seek positions are only updated by PotPlayer itself when media is played there.
  If this process ends with exit code -1073741510 (0xC000013A, STATUS_CONTROL_C_EXIT), Windows aborted the session
  (e.g. you closed this console or Ctrl+C); the orchestrator documents the same code when a child transcode window is closed.
  Safety timeout: this script is capped at 1.5 hours (5400s) by default, including mutex wait and ffmpeg runtime.
  Override with -TranscodeTimeoutSec (default 5400s). Pass -1 to disable per-invocation timeout
  (fisheye chase uses -1; parent workflow deadline still applies). On timeout it
  stops ffmpeg process tree if running and exits with code 124.
  With -NoLogFile, any non-zero exit still appends a short block to transcode_logs\transcode_failures.log (timestamp,
  input path, exit code, ffmpeg command when built) for later review without a full transcript. That file does not
  capture ffmpeg stderr or host output - only the echoed command line. For full ffmpeg and console traces, run the same
  clip once without -NoLogFile so Start-Transcript records everything under transcode_logs\.

.PARAMETER LiteralPath
  Input file path (context menu passes this). If omitted, script tries clipboard text.

.PARAMETER SsMsOverride
  Seek in milliseconds when >= 0. Default -1 reads RememberFiles registry position (else 0 ms).

.PARAMETER OutputDirectory
  Output folder. Default: F:\f1_media\3d_fullsbs_trans\flat (minute segments). Fisheye pass-2 /
  prepare pass -SegmentOutputDirectory / -OutputDirectory for ...\fisheye. The file name pattern is fixed
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

  Optional -Fisheye on StreamTo3D .avs: after AviSynth renders SBS, ffmpeg applies per-eye v360 fisheye with black
  padding (skips a separate pre-StreamTo3D fisheye encode). Use flat source in StreamTo3D; pass -Fisheye here.

.PARAMETER Fisheye
  With .avs input only: split SBS halves, v360 flat->fisheye each eye on black, hstack back to SBS before av1_qsv encode.

.PARAMETER FisheyeEyeSize
  Square output pixels per eye for -Fisheye. Default 0 = auto from probed SBS (per-eye native, no upscaling).

.PARAMETER FisheyeMaxEyeSize
  Speed cap on auto eye size (default 1280 for ~1x v360). 1080p SBS native is 1920 and often runs ~0.5x; use 0 for no cap (3840 max) or 1920 for full native.

.PARAMETER FisheyeInputHFov
  v360 input horizontal FOV (degrees) for each flat eye half. Default 90.

.PARAMETER FisheyeInputVFov
  v360 input vertical FOV (degrees). Default -1 = derive from probed per-eye aspect and FisheyeInputHFov.

.PARAMETER FisheyeOutputHFov
  v360 output fisheye horizontal FOV. Default 180.

.PARAMETER FisheyeOutputVFov
  v360 output fisheye vertical FOV. Default 180.

.PARAMETER FisheyeInterp
  v360 interpolation for -Fisheye: line (fastest, can band), cube (default), lanczos (sharpest).

.PARAMETER FisheyeScaleFlags
  ffmpeg scale flags when downsampling flat halves before v360. Default bicubic (reduces thin bands vs fast_bilinear).

.PARAMETER FisheyeQsvPreset
  Intel av1_qsv preset when -Fisheye is active. Default fast (fewer encode bands than veryfast).

.PARAMETER FisheyeSharpen
  Optional luma unsharp on each flat half before v360 (0 = off). Default off for speed; try 0.35 on soft sources.

.PARAMETER SegmentVideoBitrateMbps
  Flat / fisheye pass-2 segment encode CBR (av1_qsv). Default 0 = auto:
  LOOP_SEGMENTS_SEGMENT_VIDEO_BITRATE_MBPS env, then lan_throughput / lan_recommended_segment_bitrate.json
  sidecars on L:\pcld_ios_media (from Measure-LoopSegmentsLanThroughput.ps1), else 30M.

.PARAMETER OrchestratorPid
  Optional parent orchestrator PID. When provided (with OrchestratorStartTimeUtc), this script monitors parent liveness
  and cancels ffmpeg if that exact orchestrator process disappears (e.g. window closed).

.PARAMETER OrchestratorStartTimeUtc
  ISO-8601 UTC start timestamp for the parent orchestrator process. Used with OrchestratorPid to avoid PID reuse mismatch.

.PARAMETER WorkflowDeadlineUtc
  Optional ISO-8601 UTC deadline from parent batch/orchestrator/prepare (-WorkflowDeadlineUtc). When set with
  TranscodeTimeoutSec -1, the ffmpeg wait loop still stops leaf export at this wall-clock time (exit 124).

.PARAMETER SegmentNameSuffix
  Optional Skybox token(s) inserted before .mkv in the minute-segment pattern
  (e.g. LR_180_FISHEYE -> 3d_op_%02d_LR_180_FISHEYE.mkv, Full_SBS -> 3d_op_%02d_Full_SBS.mkv).
  Empty keeps legacy 3d_op_%02d.mkv. See https://skybox.xyz/support/How-to-Adjust-2D&3D&VR-Video-Formats
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $LiteralPath,
    [string] $OutputDirectory = 'F:\f1_media\3d_fullsbs_trans\flat',
    [int] $SsMsOverride = -1,
    [string] $Ffmpeg = 'ffmpeg',
    [string] $LogFile = '',
    [switch] $NoLogFile,
    [switch] $DryRun,
    [switch] $NoPause,
    [switch] $ContextMenu,
    [switch] $SkipOrchestrator,
    [switch] $NoClampSeek,
    [switch] $Fisheye,
    [int] $FisheyeEyeSize = 0,
    [int] $FisheyeMaxEyeSize = 1280,
    [double] $FisheyeInputHFov = 90,
    [double] $FisheyeInputVFov = -1,
    [double] $FisheyeOutputHFov = 180,
    [double] $FisheyeOutputVFov = 180,
    [ValidateSet('line', 'cube', 'lanczos')]
    [string] $FisheyeInterp = 'cube',
    [string] $FisheyeScaleFlags = 'bicubic',
    [ValidateSet('veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow')]
    [string] $FisheyeQsvPreset = 'fast',
    [double] $FisheyeSharpen = 0,
    [int] $SegmentVideoBitrateMbps = 0,
    [int] $OrchestratorPid = 0,
    [string] $OrchestratorStartTimeUtc = '',

    [string] $WorkflowDeadlineUtc = '',

    [string] $ChaseResumeStateFile = '',

    # Fisheye pass-2 DLNA segment mux: first 60s file index (0 -> 3d_op_00, 1 -> 3d_op_01). Chase alternates so short rounds still refresh both slots.
    [int] $DlnaSegmentStartNumber = 0,

    [string] $SegmentNameSuffix = '',

    [int] $TranscodeTimeoutSec = 0
)

$ErrorActionPreference = 'Stop'
$script:ExitCodeTimeout = 124
if ($TranscodeTimeoutSec -gt 0) {
    $script:TranscodeTimeoutSeconds = $TranscodeTimeoutSec
} elseif ($TranscodeTimeoutSec -lt 0) {
    $script:TranscodeTimeoutSeconds = 0
} else {
    $script:TranscodeTimeoutSeconds = 5400
}
$thisScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    [System.IO.Path]::GetFullPath($PSCommandPath)
} else {
    [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
}
$thisScriptDir = [System.IO.Path]::GetDirectoryName($thisScriptPath)
$potPlayerRegistrySeekScript = Join-Path $thisScriptDir 'Get-PotPlayerRegistrySeek.ps1'
if (-not (Test-Path -LiteralPath $potPlayerRegistrySeekScript)) {
    throw "Get-PotPlayerRegistrySeek.ps1 not found beside transcode script: $potPlayerRegistrySeekScript"
}
. $potPlayerRegistrySeekScript
$resolveStdMediaScript = Join-Path $thisScriptDir 'Resolve-StandardizedMediaPath.ps1'
if (Test-Path -LiteralPath $resolveStdMediaScript -PathType Leaf) {
    . $resolveStdMediaScript
}
$leafFfmpegControlScript = Join-Path $thisScriptDir 'Invoke-LeafFfmpegControl.ps1'
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
}
# Recreate F:\f1_media\3d_fullsbs_trans (Skybox DLNA path) via %AppData% junction+subst when F: is missing.
if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    [void](Ensure-DlnaSegmentRoot -Force)
}

# Segmented output pattern; ffmpeg rotates 2 segment files (wrap 2). Skybox suffixes: LR_180_FISHEYE / Full_SBS.
$HardcodedOutputFilePattern = if (Get-Command Get-DlnaSegmentOutputPattern -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputPattern -Suffix $SegmentNameSuffix
} elseif ([string]::IsNullOrWhiteSpace($SegmentNameSuffix)) {
    '3d_op_%02d.mkv'
} else {
    ("3d_op_%02d_{0}.mkv" -f ($SegmentNameSuffix.Trim() -replace '[\\/:*?"<>|]', '_'))
}
$DlnaSegmentLeafNames = if (Get-Command Get-DlnaSegmentOutputLeaves -ErrorAction SilentlyContinue) {
    @(Get-DlnaSegmentOutputLeaves -Suffix $SegmentNameSuffix)
} else {
    @('3d_op_00.mkv', '3d_op_01.mkv', '3d_op_%02d.mkv')
}
$InstanceMutexName = 'Local\FfmpegAvsTranscodeLock'
$TranscodeLogMaxBytes = 2L * 1024L * 1024L

# Strip trailing media token from .avs basename before ..\..\ match; longest first (.m2ts before .ts)
$AvsLinkedSourceMediaExtensions = @(
    '.mp4', '.mkv', '.avi', '.m2ts', '.ts', '.mov', '.wmv', '.m4v', '.webm',
    '.mpeg', '.mpg', '.divx'
)
$AvsLinkedSourceMediaExtensionsLongFirst = @($AvsLinkedSourceMediaExtensions | Sort-Object { $_.Length } -Descending)

function Get-RemainingTimeoutMs {
    param([datetime] $TimeoutAtUtc)
    $remaining = [int64][Math]::Floor(($TimeoutAtUtc - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -lt 0) { return 0 }
    if ($remaining -gt [int64][int]::MaxValue) { return [int]::MaxValue }
    return [int]$remaining
}

function Invoke-SafeFfprobeOutput {
    param(
        [string] $FfprobeExe,
        [string[]] $ArgumentList
    )
    if ([string]::IsNullOrWhiteSpace($FfprobeExe) -or -not (Test-Path -LiteralPath $FfprobeExe)) {
        return $null
    }
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    try { $prevNative = $PSNativeCommandUseErrorActionPreference } catch { }
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        try { $PSNativeCommandUseErrorActionPreference = $false } catch { }
        return & $FfprobeExe @ArgumentList 2>$null
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) {
            try { $PSNativeCommandUseErrorActionPreference = $prevNative } catch { }
        }
    }
}

function Get-VideoFrameRateArg {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    if ([string]::IsNullOrWhiteSpace($MediaPath) -or -not (Test-Path -LiteralPath $MediaPath)) {
        return $null
    }
    $raw = Invoke-SafeFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=avg_frame_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq '0/0' -or $s -eq 'N/A') {
        $raw = Invoke-SafeFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
            '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate',
            '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
        )
        $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    }
    if ($s -eq '' -or $s -eq '0/0' -or $s -eq 'N/A') { return $null }
    $fps = 0.0
    if ($s -match '^(\d+)/(\d+)$') {
        $num = [int64]$Matches[1]; $den = [int64]$Matches[2]
        if ($num -le 0 -or $den -le 0) { return $null }
        $fps = [double]$num / [double]$den
    } elseif (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$fps)) {
        return $null
    }
    if ($fps -lt 5 -or $fps -gt 120) { return $null }
    return $fps.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-FisheyeFlatPreV360Chain {
    param(
        [int] $EyeSize,
        [int] $PerEyeW,
        [int] $PerEyeH,
        [double] $SharpenAmount,
        [string] $V360Filter,
        [string] $ScaleFlags = 'bicubic'
    )
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($SharpenAmount -gt 0) {
        $sa = $SharpenAmount.ToString('0.###', $inv)
        $parts.Add("unsharp=3:3:${sa}:3:3:0.0")
    }
    if ($PerEyeW -gt $EyeSize -and $PerEyeH -gt 0) {
        $sh = [int][Math]::Round($EyeSize * ([double]$PerEyeH / [double]$PerEyeW))
        if ($sh -lt 2) { $sh = 2 }
        if ($sh % 2 -ne 0) { $sh++ }
        $sf = if ([string]::IsNullOrWhiteSpace($ScaleFlags)) { 'bicubic' } else { $ScaleFlags.Trim() }
        $parts.Add("scale=${EyeSize}:${sh}:flags=${sf}")
    }
    $parts.Add($V360Filter)
    return ($parts -join ',')
}

function Get-FisheyeSbsFilterComplex {
    param(
        [int] $EyeSize,
        [int] $PerEyeW,
        [int] $PerEyeH,
        [double] $InputHFov,
        [double] $InputVFov,
        [double] $OutputHFov,
        [double] $OutputVFov,
        [string] $Interp = 'cube',
        [double] $SharpenAmount = 0,
        [string] $ScaleFlags = 'bicubic'
    )
    if ($EyeSize -lt 256 -or ($EyeSize % 2) -ne 0) {
        throw "FisheyeEyeSize must be an even integer >= 256 (got $EyeSize)."
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $ih = $InputHFov.ToString('0.######', $inv)
    $iv = $InputVFov.ToString('0.######', $inv)
    $oh = $OutputHFov.ToString('0.######', $inv)
    $ov = $OutputVFov.ToString('0.######', $inv)
    $v360 = "v360=input=flat:output=fisheye:ih_fov=${ih}:iv_fov=${iv}:h_fov=${oh}:v_fov=${ov}:w=${EyeSize}:h=${EyeSize}:interp=${Interp}:alpha_mask=1,format=yuva420p"
    $flatChain = Get-FisheyeFlatPreV360Chain -EyeSize $EyeSize -PerEyeW $PerEyeW -PerEyeH $PerEyeH `
        -SharpenAmount $SharpenAmount -V360Filter $v360 -ScaleFlags $ScaleFlags
    return "color=c=black:s=${EyeSize}x${EyeSize}[bgl];color=c=black:s=${EyeSize}x${EyeSize}[bgr];" +
        "[0:v]crop=iw/2:ih:0:0[lflat];[0:v]crop=iw/2:ih:iw/2:0[rflat];" +
        "[lflat]${flatChain}[fgl];[bgl][fgl]overlay=shortest=1[lout];" +
        "[rflat]${flatChain}[fgr];[bgr][fgr]overlay=shortest=1[rout];" +
        "[lout][rout]hstack=inputs=2,format=nv12[outv]"
}

function Get-VideoStreamDimensions {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-SafeFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height',
        '-of', 'csv=p=0:s=x', '--', $MediaPath
    )
    if ($null -eq $raw) { return $null }
    $s = ([string]$raw).Trim()
    if ($s -notmatch '^(\d+)x(\d+)$') { return $null }
    $w = [int]$Matches[1]
    $h = [int]$Matches[2]
    if ($w -le 0 -or $h -le 0) { return $null }
    return @{ Width = $w; Height = $h }
}

function Resolve-FisheyeTranscodeSettings {
    param(
        [string] $AvsPath,
        [string] $FfprobeExe,
        [int] $RequestedEyeSize,
        [int] $MaxEyeSize,
        [double] $InputHFov,
        [double] $InputVFov,
        [double] $OutputHFov,
        [double] $OutputVFov
    )
    $maxEyeCap = 3840
    $perEyeW = 0
    $perEyeH = 0
    $dims = $null
    if ($FfprobeExe -and -not [string]::IsNullOrWhiteSpace($AvsPath)) {
        $dims = Get-VideoStreamDimensions -MediaPath $AvsPath -FfprobeExe $FfprobeExe
    }
    if ($null -ne $dims) {
        $perEyeW = [int][Math]::Floor($dims.Width / 2.0)
        $perEyeH = [int]$dims.Height
        if ($perEyeW -lt 2) { $perEyeW = 2 }
        if ($perEyeH -lt 2) { $perEyeH = 2 }
        if ($perEyeW % 2 -ne 0) { $perEyeW-- }
        if ($perEyeH % 2 -ne 0) { $perEyeH-- }
    }
    $nativeEye = 0
    if ($perEyeW -gt 0 -and $perEyeH -gt 0) {
        $nativeEye = [Math]::Max($perEyeW, $perEyeH)
        $nativeEye = [int][Math]::Floor($nativeEye / 2.0) * 2
    }
    $eyeSize = if ($RequestedEyeSize -le 0) {
        if ($nativeEye -ge 256) { [Math]::Min($maxEyeCap, $nativeEye) } else { 1920 }
    } else {
        if ($nativeEye -ge 256) { [Math]::Min($RequestedEyeSize, $nativeEye) } else { $RequestedEyeSize }
    }
    if ($eyeSize -lt 256) { $eyeSize = 256 }
    if ($eyeSize % 2 -ne 0) { $eyeSize-- }
    if ($MaxEyeSize -ge 256 -and $eyeSize -gt $MaxEyeSize) { $eyeSize = $MaxEyeSize }
    $ih = $InputHFov
    $iv = $InputVFov
    if ($iv -lt 0 -and $perEyeW -gt 0 -and $perEyeH -gt 0) {
        $iv = $ih * ([double]$perEyeH / [double]$perEyeW)
    } elseif ($iv -lt 0) {
        $iv = 56
    }
    return @{
        EyeSize    = [int]$eyeSize
        InputHFov  = [double]$ih
        InputVFov  = [double]$iv
        OutputHFov = [double]$OutputHFov
        OutputVFov = [double]$OutputVFov
        SbsWidth   = if ($null -ne $dims) { $dims.Width } else { 0 }
        SbsHeight  = if ($null -ne $dims) { $dims.Height } else { 0 }
        PerEyeW    = $perEyeW
        PerEyeH    = $perEyeH
        NativeEye  = $nativeEye
    }
}

function Get-FisheyeVideoBitrateMbps {
    param([int] $EyeSize)
    $baseEye = 1920
    $baseMbps = 100
    $mbps = [int][Math]::Round($baseMbps * ([double]$EyeSize / [double]$baseEye), 0)
    if ($mbps -lt 50) { $mbps = 50 }
    if ($mbps -gt 100) { $mbps = 100 }
    return $mbps
}

function Resolve-SegmentVideoBitrateMbps {
    param([int] $ExplicitMbps = 0)
    if ($ExplicitMbps -gt 0) { return $ExplicitMbps }

    $envRaw = [string]$env:LOOP_SEGMENTS_SEGMENT_VIDEO_BITRATE_MBPS
    if ($envRaw -match '^\s*(\d+)\s*$') {
        $fromEnv = [int]$Matches[1]
        if ($fromEnv -gt 0) {
            Write-Host ("DLNA segment bitrate: {0}M from LOOP_SEGMENTS_SEGMENT_VIDEO_BITRATE_MBPS" -f $fromEnv)
            return $fromEnv
        }
    }

    $sidecarCandidates = @(
        'L:\pcld_ios_media\scripts\lan_throughput.json'
        'L:\pcld_ios_media\archive\lan_recommended_segment_bitrate.json'
        'L:\pcld_ios_media\lan_recommended_segment_bitrate.json'
    )
    foreach ($sidecar in $sidecarCandidates) {
        if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { continue }
        try {
            $doc = Get-Content -LiteralPath $sidecar -Raw -ErrorAction Stop | ConvertFrom-Json
            $rec = 0
            if ($null -ne $doc.recommendedMaxMediaBitrateMbps) {
                $rec = [int]$doc.recommendedMaxMediaBitrateMbps
            }
            if ($rec -gt 0) {
                Write-Host ("DLNA segment bitrate: {0}M from LAN sidecar {1} (measured {2} Mbps)" -f `
                    $rec, $sidecar, $doc.measuredMbps)
                return $rec
            }
        } catch {
            Write-Warning ("Could not read LAN bitrate sidecar {0}: {1}" -f $sidecar, $_.Exception.Message)
        }
    }

    return 30
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

function Get-AvsDirectShowSourcePath {
    param([string] $AvsFullPath)
    if (-not (Test-Path -LiteralPath $AvsFullPath -PathType Leaf)) {
        return $null
    }
    try {
        $text = [IO.File]::ReadAllText($AvsFullPath)
        $match = [regex]::Match($text, 'DirectShowSource\s*\(\s*"([^"]+)"')
        if ($match.Success) {
            $path = $match.Groups[1].Value
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                return [System.IO.Path]::GetFullPath($path)
            }
        }
    } catch {
        Write-Warning "Could not read DirectShowSource from AVS: $AvsFullPath ($_)"
    }
    return $null
}

function Get-AvsEmbeddedFrameRateArg {
    param([string] $AvsFullPath)
    if ([string]::IsNullOrWhiteSpace($AvsFullPath) -or -not (Test-Path -LiteralPath $AvsFullPath -PathType Leaf)) {
        return $null
    }
    try {
        $text = [IO.File]::ReadAllText($AvsFullPath)
        $num = 0L
        $den = 0L
        if ($text -match '(?m)^\s*StreamTo3D_fps_num\s*=\s*(\d+)') {
            $num = [int64]$Matches[1]
        }
        if ($text -match '(?m)^\s*StreamTo3D_fps_den\s*=\s*(\d+)') {
            $den = [int64]$Matches[1]
        }
        if ($num -gt 0 -and $den -gt 0) {
            $fps = [double]$num / [double]$den
            if ($fps -ge 5 -and $fps -le 120) {
                return $fps.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
    } catch { }
    return $null
}

function Test-FisheyeTempTranscodeInput {
    param(
        [string] $AvsFullPath,
        [string] $DirectShowSourcePath
    )
    if (-not [string]::IsNullOrWhiteSpace($AvsFullPath)) {
        if ($AvsFullPath -match '(?i)\\fisheye_temp\\avs\\') { return $true }
        if ($AvsFullPath -match '(?i)StreamTo3D\.fisheye_temp\.') { return $true }
    }
    if (-not [string]::IsNullOrWhiteSpace($DirectShowSourcePath)) {
        if ($DirectShowSourcePath -match '(?i)\.fisheye\.frag\.mp4$') { return $true }
        if ($DirectShowSourcePath -match '(?i)\\fisheye_temp\\') { return $true }
    }
    return $false
}

function Get-FisheyePass2SegmentMuxerArgs {
    param(
        [int] $SegmentStartNumber = 0,
        [switch] $ChaseRound
    )
    $args = @('-f', 'segment', '-segment_time', '60', '-segment_wrap', '2', '-reset_timestamps', '1')
    if ($SegmentStartNumber -ge 1) {
        $args += @('-segment_start_number', "$SegmentStartNumber")
    }
    if ($ChaseRound.IsPresent) {
        $args = @('-t', '60') + $args
    }
    return $args
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
    $raw = Invoke-SafeFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-show_entries', 'format=bit_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
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
    $raw = Invoke-SafeFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=height',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
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
    $raw = Invoke-SafeFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
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
            Write-Warning "Orchestrator pid=$OrchProcessId start-time mismatch; using PID-only watch."
            return $true
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
        if ($joined -match '(?im)Exiting normally, received signal 15' -and $joined -match '(?im)\bframe=') {
            return $true
        }
    } catch { }
    return $false
}

function Get-FfmpegStderrMaxOutputTimeSec {
    param([string] $StdErrPath)
    if ([string]::IsNullOrWhiteSpace($StdErrPath)) { return 0.0 }
    if (-not (Test-Path -LiteralPath $StdErrPath -PathType Leaf)) { return 0.0 }
    $maxSec = 0.0
    try {
        $lines = Get-Content -LiteralPath $StdErrPath -ErrorAction Stop
        foreach ($line in @($lines)) {
            $s = [string]$line
            if ($s -notmatch 'time=') { continue }
            foreach ($m in [regex]::Matches($s, 'time=(\d+):(\d+):(\d+(?:\.\d+)?)')) {
                $sec = ([int]$m.Groups[1].Value * 3600) + ([int]$m.Groups[2].Value * 60) + [double]$m.Groups[3].Value
                if ($sec -gt $maxSec) { $maxSec = $sec }
            }
            foreach ($m in [regex]::Matches($s, 'time=(\d+):(\d+(?:\.\d+)?)(?:\s|bitrate)')) {
                if ($m.Groups[1].Value.Length -gt 2) { continue }
                $sec = ([int]$m.Groups[1].Value * 60) + [double]$m.Groups[2].Value
                if ($sec -gt $maxSec) { $maxSec = $sec }
            }
        }
    } catch { }
    return $maxSec
}

function Write-FisheyeChaseResumeState {
    param(
        [string] $StateFilePath,
        [double] $SeekStartSec,
        [double] $LastEncodedSec,
        [int] $ExitCode
    )
    if ([string]::IsNullOrWhiteSpace($StateFilePath)) { return }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($StateFilePath)
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $payload = @{
            seekStartSec   = [Math]::Round($SeekStartSec, 3)
            lastEncodedSec = [Math]::Round($LastEncodedSec, 3)
            exitCode       = $ExitCode
            utc            = (Get-Date).ToUniversalTime().ToString('o')
        }
        Set-Content -LiteralPath $StateFilePath -Value ($payload | ConvertTo-Json -Compress) -Encoding utf8
        Write-Host ("Chase resume state: seek {0}s -> encoded to {1}s ({2})" -f `
            $payload.seekStartSec, $payload.lastEncodedSec, $StateFilePath)
    } catch {
        Write-Warning "Could not write chase resume state: $_"
    }
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
$transcodeTimeoutAtUtc = if ($script:TranscodeTimeoutSeconds -gt 0) {
    [DateTime]::UtcNow.AddSeconds($script:TranscodeTimeoutSeconds)
} else {
    [datetime]::MaxValue
}
if ($script:TranscodeTimeoutSeconds -gt 0) {
    Write-Host "Transcode timeout: $($script:TranscodeTimeoutSeconds)s"
} else {
    Write-Host 'Transcode timeout: disabled (parent workflow/orchestrator controls stop)'
}
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
            $selfStartUtc = (Get-Date).ToUniversalTime().ToString('o')
            try {
                $selfProc = Get-Process -Id $PID -ErrorAction SilentlyContinue
                if ($null -ne $selfProc) {
                    $selfStartUtc = $selfProc.StartTime.ToUniversalTime().ToString('o')
                }
            } catch { }
            $lines = @(
                "mutex=$InstanceMutexName",
                "pid=$PID",
                "startUtc=$selfStartUtc",
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
    $clickedInputFull = $fullInput
    if (-not $fullInput.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
        if (Get-Command Resolve-StandardizedMediaPath -ErrorAction SilentlyContinue) {
            $resolvedInput = Resolve-StandardizedMediaPath -MediaFullPath $fullInput
            if ($resolvedInput -ne $fullInput) {
                Write-Host "Standardized variant found; using: $resolvedInput (clicked: $fullInput)"
                $fullInput = $resolvedInput
            }
        }
    }

    if ($SsMsOverride -ge 0) {
        $ssMs = [int64]$SsMsOverride
    } else {
        $ssMs = Get-SeekMsForRememberedPath -TargetPath $fullInput -AlternatePaths @($clickedInputFull)
        if (-not $SkipOrchestrator) {
            $quickSeekOverrideMs = Get-QuickSeekOverrideMs
            if ($null -ne $quickSeekOverrideMs) {
                $ssMs = [int64]$quickSeekOverrideMs
            }
        }
    }
    $root = [System.IO.Path]::GetFullPath($OutputDirectory)
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
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

    # Flat DLNA: always -readrate 1 (wrap-2 viewing pace). Fisheye pass-2: same. Height/bitrate logged only.
    $useReInput = $false
    $ffprobeExe = Get-FfprobeExePath $ffmpegExe
    $sourceMedia = $null
    if ($fullInput.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
        $directShowSource = Get-AvsDirectShowSourcePath -AvsFullPath $fullInput
        if ($directShowSource) {
            $sourceMedia = $directShowSource
            if (Test-Path -LiteralPath $directShowSource -PathType Leaf) {
                Write-Host "Using DirectShowSource from AVS for probe/resume rules: $sourceMedia"
            } else {
                Write-Host "Using DirectShowSource from AVS (file may still be growing): $sourceMedia"
            }
        } else {
            $remainder = Get-AvsRemainderBaseName $fullInput
            $sourceMedia = Find-SourceMediaInAvsGrandparent -AvsFullPath $fullInput -Remainder $remainder
        }
    }
    $probePath = if ($sourceMedia) { $sourceMedia } else { $fullInput }
    $isFisheyeTempPass2 = Test-FisheyeTempTranscodeInput -AvsFullPath $fullInput -DirectShowSourcePath $sourceMedia
    $outPath = Join-Path $root $HardcodedOutputFilePattern
    $fisheyePass2ChaseRound = $isFisheyeTempPass2 -and (-not [string]::IsNullOrWhiteSpace($ChaseResumeStateFile))
    $fisheyeSegmentMuxerArgs = if ($isFisheyeTempPass2) {
        Get-FisheyePass2SegmentMuxerArgs -SegmentStartNumber $DlnaSegmentStartNumber -ChaseRound:($fisheyePass2ChaseRound)
    } else {
        @()
    }
    $segmentMuxerOutArgs = if ($fisheyeSegmentMuxerArgs.Count -gt 0) {
        $fisheyeSegmentMuxerArgs
    } else {
        @('-f', 'segment', '-segment_time', '60', '-segment_wrap', '2', '-reset_timestamps', '1')
    }

    if (-not $ffprobeExe) {
        Write-Warning 'ffprobe not found (install with ffmpeg or on PATH); skipping height/bitrate -re rules.'
    } elseif ($isFisheyeTempPass2) {
        # readrate 1 for DLNA viewing pace. No readrate_initial_burst (burst + slow caused ~15s lag stalls).
        $useReInput = $true
        Write-Host 'Fisheye pass-2 DLNA: readrate 1 (viewing pace; av1_qsv preset slow).'
    } else {
        # Flat DLNA path always uses segment_wrap 2 (3d_op_00/01). Pace to ~1x so slots rotate on
        # wall-clock minutes during viewing. Height/bitrate probes only log; do not gate pacing.
        # Hybrid flat band is <4 Mbps non-hevc (and often 1080p + >=2.5 Mbps), which previously
        # skipped readrate and thrashed wrap-2 leaves at encode speed (~6x).
        $vidHeight = Get-VideoStreamHeight -MediaPath $probePath -FfprobeExe $ffprobeExe
        if ($null -ne $vidHeight) {
            Write-Host ("Video height {0} px (probe; flat DLNA always paces with readrate)" -f $vidHeight)
        } else {
            Write-Warning "Could not read video stream height for: $probePath"
        }

        if ($fullInput.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase) -and $sourceMedia) {
            $bps = Get-FormatBitrateBps -MediaPath $sourceMedia -FfprobeExe $ffprobeExe
            if ($null -eq $bps) {
                if (Test-FisheyeTempTranscodeInput -AvsFullPath $fullInput -DirectShowSourcePath $sourceMedia) {
                    Write-Host "Growing fisheye mezzanine: ffprobe bit_rate unavailable during chase (expected)."
                } else {
                    Write-Warning "Could not read format bit_rate for: $sourceMedia"
                }
            } else {
                $kbps = [double]$bps / 1000.0
                Write-Host ("Source total bitrate ~ {0} kbps (probe; flat DLNA always paces with readrate)" -f [math]::Round($kbps))
            }
        }

        $useReInput = $true
        Write-Host 'Flat DLNA segment encode: readrate 1 (viewing pace; segment_wrap 2).'
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
    if ($isFisheyeTempPass2) {
        if ($DryRun) {
            Write-Host ("[DryRun] Fisheye pass-2: would stop prior {0} segment ffmpeg; overwrite each 60s file in turn (-y segment_wrap 2)." -f $HardcodedOutputFilePattern)
        } else {
            Stop-FfmpegUsingOutputLeaf -LeafNames $DlnaSegmentLeafNames
            if ($fisheyePass2ChaseRound) {
                $slotLeaf = if (Get-Command Get-DlnaSegmentOutputPattern -ErrorAction SilentlyContinue) {
                    (Get-DlnaSegmentOutputPattern -Suffix $SegmentNameSuffix) -replace '%02d', ('{0:D2}' -f $DlnaSegmentStartNumber)
                } else {
                    ('3d_op_{0:D2}.mkv' -f $DlnaSegmentStartNumber)
                }
                Write-Host ("Fisheye pass-2 DLNA: 60s segment mux starting at {0} (max 60s this chase round; other slot stays playable)." -f $slotLeaf)
            } else {
                Write-Host ("Fisheye pass-2 DLNA: overwrite {0} one 60s segment at a time (other file stays playable until its turn)." -f ($DlnaSegmentLeafNames -join ' / '))
            }
        }
    }

    $ssSec = [double]$ssMs / 1000.0
    $ssMin = $ssSec / 60.0
    $fmtSec = $ssSec.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)

    $useFisheyeSbs = $false
    if ($Fisheye.IsPresent) {
        if ($fullInput.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
            $useFisheyeSbs = $true
        } else {
            Write-Warning '-Fisheye ignored: input is not .avs (StreamTo3D AviSynth script required).'
        }
    }

    if ($useFisheyeSbs -and $useReInput) {
        Write-Host 'Fisheye: not using -re (full-speed encode; preset/bitrate tuned for ~1x).'
        $useReInput = $false
    }

    $argList = @(
        '-hide_banner', '-y',
        '-ss', $fmtSec
    )
    if ($useReInput) {
        if ($isFisheyeTempPass2) {
            $argList += @('-readrate', '1', '-readrate_catchup', '1.05')
            Write-Host 'Fisheye pass-2 DLNA: -readrate 1 + catchup 1.05x (no burst; segments track playback, not full-speed fill).'
        } else {
            $readrateBurstSec = 20
            $readrateCatchup = '1.2'
            $argList += @('-readrate', '1', '-readrate_initial_burst', "$readrateBurstSec", '-readrate_catchup', $readrateCatchup)
            Write-Host "DLNA segment encode (flat): readrate 1 + initial_burst ${readrateBurstSec}s + catchup ${readrateCatchup}x."
        }
    }
    if ($useFisheyeSbs) {
        $speedEyeCap = if ($FisheyeMaxEyeSize -ge 256) { $FisheyeMaxEyeSize } else { 0 }
        $fisheyeSettings = Resolve-FisheyeTranscodeSettings -AvsPath $fullInput -FfprobeExe $ffprobeExe `
            -RequestedEyeSize $FisheyeEyeSize -MaxEyeSize $speedEyeCap `
            -InputHFov $FisheyeInputHFov -InputVFov $FisheyeInputVFov `
            -OutputHFov $FisheyeOutputHFov -OutputVFov $FisheyeOutputVFov
        $fisheyeFilter = Get-FisheyeSbsFilterComplex -EyeSize $fisheyeSettings.EyeSize `
            -PerEyeW $fisheyeSettings.PerEyeW -PerEyeH $fisheyeSettings.PerEyeH `
            -InputHFov $fisheyeSettings.InputHFov -InputVFov $fisheyeSettings.InputVFov `
            -OutputHFov $fisheyeSettings.OutputHFov -OutputVFov $fisheyeSettings.OutputVFov `
            -Interp $FisheyeInterp -SharpenAmount $FisheyeSharpen -ScaleFlags $FisheyeScaleFlags
        if ($fisheyeSettings.SbsWidth -gt 0) {
            $preScaleNote = if ($fisheyeSettings.PerEyeW -gt $fisheyeSettings.EyeSize) {
                "; pre-scale flat $($fisheyeSettings.PerEyeW)x$($fisheyeSettings.PerEyeH) before v360"
            } else { '' }
            $eyeNote = if ($speedEyeCap -ge 256 -and $fisheyeSettings.NativeEye -gt $fisheyeSettings.EyeSize) {
                " (eye capped $($fisheyeSettings.NativeEye)->$($fisheyeSettings.EyeSize)$preScaleNote)"
            } elseif ($preScaleNote) {
                $preScaleNote
            } else { '' }
            Write-Host ("Fisheye SBS probe: {0}x{1} -> per-eye {2}x{3}; native eye {4}; output eye {5}x{5}{6}" -f `
                $fisheyeSettings.SbsWidth, $fisheyeSettings.SbsHeight, `
                $fisheyeSettings.PerEyeW, $fisheyeSettings.PerEyeH, `
                $fisheyeSettings.NativeEye, $fisheyeSettings.EyeSize, $eyeNote)
        } else {
            Write-Host "Fisheye SBS: could not probe .avs dimensions; using eye $($fisheyeSettings.EyeSize)"
        }
        $fisheyeMbps = Get-FisheyeVideoBitrateMbps -EyeSize $fisheyeSettings.EyeSize
        $sharpenLog = if ($FisheyeSharpen -gt 0) { "pre-v360=$FisheyeSharpen" } else { 'off' }
        Write-Host ("Fisheye v360 ih/v={0}/{1} out h/v={2}/{3} interp={4} scale={5} {6} qsv={7} VBR ~{8}M max 100M" -f `
            $fisheyeSettings.InputHFov, $fisheyeSettings.InputVFov, `
            $fisheyeSettings.OutputHFov, $fisheyeSettings.OutputVFov, $FisheyeInterp, $FisheyeScaleFlags, `
            $sharpenLog, $FisheyeQsvPreset, $fisheyeMbps)
        $bufMbps = [Math]::Min(100, $fisheyeMbps * 2)
        $argList += @(
            '-filter_complex_threads', '0',
            '-i', $fullInput,
            '-filter_complex', $fisheyeFilter,
            '-map', '[outv]',
            '-map', '0:a?',
            '-c:v', 'av1_qsv',
            '-preset', $FisheyeQsvPreset,
            '-rc', 'vbr',
            '-b:v', "${fisheyeMbps}M",
            '-maxrate', '100M',
            '-bufsize', "${bufMbps}M",
            '-c:a', 'copy'
        ) + $segmentMuxerOutArgs + @($outPath)
    } else {
    $segmentMbps = Resolve-SegmentVideoBitrateMbps -ExplicitMbps $SegmentVideoBitrateMbps
    Write-Host "DLNA segment encode: ${segmentMbps}M CBR av1_qsv (flat / fisheye pass-2 path)"
    $segmentAudioArgs = if ($isFisheyeTempPass2) {
        @('-c:a', 'aac', '-b:a', '192k', '-ar', '48000')
    } else {
        @('-c:a', 'copy')
    }
    $segmentFpsArgs = @()
    if ($isFisheyeTempPass2) {
        # Prefer AVS / embedded fps: growing mezzanine ffprobe returns unstable huge fractions (e.g. 11988/1) that QSV rejects.
        $segmentFpsArg = $null
        foreach ($fpsPath in @($fullInput, $sourceMedia)) {
            if ([string]::IsNullOrWhiteSpace($fpsPath)) { continue }
            $segmentFpsArg = Get-VideoFrameRateArg -MediaPath $fpsPath -FfprobeExe $ffprobeExe
            if (-not [string]::IsNullOrWhiteSpace($segmentFpsArg)) { break }
        }
        if ([string]::IsNullOrWhiteSpace($segmentFpsArg)) {
            $segmentFpsArg = Get-AvsEmbeddedFrameRateArg -AvsFullPath $fullInput
        }
        if (-not [string]::IsNullOrWhiteSpace($segmentFpsArg)) {
            Write-Host "Fisheye pass-2 CFR: -r $segmentFpsArg"
            $segmentFpsArgs = @('-r', $segmentFpsArg)
        } else {
            Write-Warning 'Fisheye pass-2: could not probe fps; output timing may drift.'
        }
    } else {
        $segmentFpsArgs = @('-fps_mode', 'passthrough')
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
        '-b:v', "${segmentMbps}M",
        '-maxrate', "${segmentMbps}M"
    ) + $segmentFpsArgs + $segmentAudioArgs + $segmentMuxerOutArgs + @($outPath)
    }
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
    $workflowDeadlineAtUtc = [datetime]::MaxValue
    if (Get-Command Convert-TranscodeWorkflowDeadlineUtc -ErrorAction SilentlyContinue) {
        $parsedDeadline = Convert-TranscodeWorkflowDeadlineUtc -UtcIso $WorkflowDeadlineUtc
        if ($null -ne $parsedDeadline) {
            $workflowDeadlineAtUtc = $parsedDeadline
        }
    }
    while ($true) {
        if ([DateTime]::UtcNow -ge $transcodeTimeoutAtUtc) {
            Write-Warning "Transcode timeout reached ($($script:TranscodeTimeoutSeconds)s). Stopping ffmpeg process tree..."
            Stop-ProcessTreeByPid -PidToKill $ffProc.Id
            $exitCode = $script:ExitCodeTimeout
            break
        }
        if (Get-Command Test-TranscodeWorkflowDeadlineExpired -ErrorAction SilentlyContinue) {
            if (Test-TranscodeWorkflowDeadlineExpired -DeadlineUtc $workflowDeadlineAtUtc) {
                Write-Warning 'Workflow/batch deadline reached during leaf DLNA export. Stopping ffmpeg...'
                Stop-ProcessTreeByPid -PidToKill $ffProc.Id
                $exitCode = $script:ExitCodeTimeout
                break
            }
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
        if (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-TranscodeConsoleKeyPoll)
        }
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
        if ($exitCode -ne 0 -and $isFisheyeTempPass2 -and (Test-FfmpegAppearsSuccessfulFromStderr -StdErrPath $ffmpegStdErrLogPath)) {
            Write-Warning "Fisheye pass-2 ffmpeg exit $exitCode after usable progress (signal/stop); continuing chase from resume state."
            $exitCode = 0
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

    if (-not [string]::IsNullOrWhiteSpace($ChaseResumeStateFile)) {
        $outputDurationSec = 0.0
        if (-not [string]::IsNullOrWhiteSpace($ffmpegStdErrLogPath)) {
            $outputDurationSec = Get-FfmpegStderrMaxOutputTimeSec -StdErrPath $ffmpegStdErrLogPath
        }
        if ($isFisheyeTempPass2) {
            # segment mux uses -reset_timestamps 1; stderr time= is output-relative, not source timeline
            $encodedSec = $ssSec + $outputDurationSec
        } else {
            $encodedSec = $outputDurationSec
            if ($encodedSec -lt $ssSec) { $encodedSec = $ssSec }
        }
        Write-FisheyeChaseResumeState -StateFilePath $ChaseResumeStateFile `
            -SeekStartSec $ssSec -LastEncodedSec $encodedSec -ExitCode $exitCode
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
} catch {
    Write-Warning "Transcode script error: $_"
    if ($exitCode -eq 0) { $exitCode = 1 }
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
        if ($Fisheye.IsPresent) {
            $argList += '-Fisheye'
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
