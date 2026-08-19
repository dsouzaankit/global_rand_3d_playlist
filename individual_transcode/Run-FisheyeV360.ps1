#Requires -Version 5.1
<#
.SYNOPSIS
  Fisheye v360 mezzanine export (fragmented MP4, playable while encoding).
  Flat = one fisheye eye; SBS = L/R hstack. Defaults: native eye, lanczos v360, av1_qsv 50M mezzanine.

.EXAMPLE
  .\Run-FisheyeV360.ps1 -LiteralPath "D:\clip.mp4" -DryRun
.EXAMPLE
  .\Run-FisheyeV360.ps1 -LiteralPath "D:\clip.mp4" -DurationSec 120
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $LiteralPath,
    [string] $OutputDirectory = '',
    [string] $Ffmpeg = 'ffmpeg',
    [double] $SsSec = 0,
    [int] $DurationSec = 0,
    [int] $FisheyeEyeSize = 0,
    [int] $FisheyeMaxEyeSize = 0,
    [double] $FisheyeInputHFov = 90,
    [double] $FisheyeInputVFov = -1,
    [double] $FisheyeOutputHFov = 180,
    [double] $FisheyeOutputVFov = 180,
    [ValidateSet('line', 'cube', 'lanczos')]
    [string] $FisheyeInterp = 'lanczos',
    [string] $FisheyeScaleFlags = 'bicubic',
    [ValidateSet('veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow')]
    [string] $FisheyeQsvPreset = 'slow',
    [int] $GlobalQuality = 18,
    [int] $VideoBitrateMbps = 50,
    [double] $FisheyeSharpen = 0,
    [string] $OutputFile = '',
    [switch] $Background,
    [switch] $ClearOutputOnly,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

function Format-ProcessArgumentLine {
    param([string[]] $Arguments)
    return ($Arguments | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s":+]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
}

function Get-DefaultFisheyeMezzanineFileName {
    param([string] $MediaBase)
    return ($MediaBase + '.fisheye.frag.mp4')
}

function Clear-ExistingFisheyeFragOutput {
    param([string] $OutputPath)
    $outFull = [System.IO.Path]::GetFullPath($OutputPath)
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if ($cmd -and ($cmd -like "*$outFull*" -or $cmd -like "*$([System.IO.Path]::GetFileName($outFull))*")) {
            Write-Host "Stopping ffmpeg pid=$($proc.ProcessId) for overwrite: $outFull"
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $outFull -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $outFull -Force
            Write-Host "Removed existing fragmented output (overwrite): $outFull"
        } catch {
            Write-Warning "Could not remove existing fragmented output (close players/transcode using it): $outFull ($_)"
            throw
        }
    }
}

function Get-FfprobeExePath {
    param([string] $FfmpegExe)
    $dir = [System.IO.Path]::GetDirectoryName($FfmpegExe)
    $candidate = Join-Path $dir 'ffprobe.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-VideoStreamDimensions {
    param([string] $MediaPath, [string] $FfprobeExe)
    $raw = & $FfprobeExe -v error -select_streams v:0 -show_entries stream=width,height `
        -of csv=p=0:s=x -- $MediaPath 2>$null
    if ($null -eq $raw) { return $null }
    $s = ([string]$raw).Trim()
    if ($s -notmatch '^(\d+)x(\d+)$') { return $null }
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    if ($w -le 0 -or $h -le 0) { return $null }
    return @{ Width = $w; Height = $h }
}

function Get-VideoFrameRateArg {
    param([string] $MediaPath, [string] $FfprobeExe)
    if (-not $FfprobeExe -or [string]::IsNullOrWhiteSpace($MediaPath)) { return $null }
    $raw = & $FfprobeExe -v error -select_streams v:0 -show_entries stream=avg_frame_rate `
        -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq '0/0' -or $s -eq 'N/A') {
        $raw = & $FfprobeExe -v error -select_streams v:0 -show_entries stream=r_frame_rate `
            -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
        $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    }
    if ($s -eq '' -or $s -eq '0/0' -or $s -eq 'N/A') { return $null }
    if ($s -match '^(\d+)/(\d+)$') {
        $num = [int64]$Matches[1]; $den = [int64]$Matches[2]
        if ($num -le 0 -or $den -le 0) { return $null }
        $fps = [double]$num / [double]$den
        if ($fps -gt 0) {
            return $fps.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
        }
        return $null
    }
    $fps = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$fps) `
        -and $fps -gt 0) {
        return $fps.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

function Get-FisheyeFlatPreV360Chain {
    param(
        [int] $EyeSize, [int] $PerEyeW, [int] $PerEyeH,
        [double] $SharpenAmount, [string] $V360Filter, [string] $ScaleFlags = 'bicubic'
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

function Get-FisheyeFilterComplex {
    param(
        [int] $EyeSize, [int] $PerEyeW, [int] $PerEyeH,
        [double] $InputHFov, [double] $InputVFov,
        [double] $OutputHFov, [double] $OutputVFov,
        [string] $Interp = 'lanczos', [double] $SharpenAmount = 0, [string] $ScaleFlags = 'bicubic',
        [switch] $FlatSource
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
    if ($FlatSource) {
        return "color=c=black:s=${EyeSize}x${EyeSize}[bg];" +
            "[0:v]${flatChain}[fg];[bg][fg]overlay=shortest=1,format=nv12[outv]"
    }
    return "color=c=black:s=${EyeSize}x${EyeSize}[bgl];color=c=black:s=${EyeSize}x${EyeSize}[bgr];" +
        "[0:v]crop=iw/2:ih:0:0[lflat];[0:v]crop=iw/2:ih:iw/2:0[rflat];" +
        "[lflat]${flatChain}[fgl];[bgl][fgl]overlay=shortest=1[lout];" +
        "[rflat]${flatChain}[fgr];[bgr][fgr]overlay=shortest=1[rout];" +
        "[lout][rout]hstack=inputs=2,format=nv12[outv]"
}

function Resolve-FisheyeTranscodeSettings {
    param(
        [string] $AvsPath, [string] $FfprobeExe,
        [int] $RequestedEyeSize, [int] $MaxEyeSize,
        [double] $InputHFov, [double] $InputVFov,
        [double] $OutputHFov, [double] $OutputVFov
    )
    $maxEyeCap = 3840
    $perEyeW = 0; $perEyeH = 0; $dims = $null
    if ($FfprobeExe -and -not [string]::IsNullOrWhiteSpace($AvsPath)) {
        $dims = Get-VideoStreamDimensions -MediaPath $AvsPath -FfprobeExe $FfprobeExe
    }
    $isSbs = $false
    if ($null -ne $dims -and $dims.Height -gt 0) {
        $isSbs = ([double]$dims.Width / [double]$dims.Height) -ge 2.8
    }
    if ($null -ne $dims) {
        $perEyeW = if ($isSbs) { [int][Math]::Floor($dims.Width / 2.0) } else { [int]$dims.Width }
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
    $ih = $InputHFov; $iv = $InputVFov
    if ($iv -lt 0 -and $perEyeW -gt 0 -and $perEyeH -gt 0) {
        $iv = $ih * ([double]$perEyeH / [double]$perEyeW)
    } elseif ($iv -lt 0) { $iv = 56 }
    return @{
        EyeSize = [int]$eyeSize; InputHFov = [double]$ih; InputVFov = [double]$iv
        OutputHFov = [double]$OutputHFov; OutputVFov = [double]$OutputVFov
        SbsWidth = if ($null -ne $dims) { $dims.Width } else { 0 }
        SbsHeight = if ($null -ne $dims) { $dims.Height } else { 0 }
        PerEyeW = $perEyeW; PerEyeH = $perEyeH; NativeEye = $nativeEye; IsSbs = $isSbs
    }
}

$fullInput = [System.IO.Path]::GetFullPath($LiteralPath)
if (-not (Test-Path -LiteralPath $fullInput)) { throw "Input not found: $fullInput" }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = [System.IO.Path]::GetDirectoryName($fullInput)
}
$inputExt = [System.IO.Path]::GetExtension($fullInput).ToLowerInvariant()
# Keep in sync with Run-V360PrepareFisheye / Install-ContextMenu media extensions (+ .avs).
$allowedInputExt = @('.avs', '.mp4', '.mkv', '.mov', '.m4v', '.avi', '.wmv', '.ts', '.m2ts', '.webm')
if ($inputExt -notin $allowedInputExt) {
    throw "Input must be .avs (StreamTo3D SBS) or a video file ($(($allowedInputExt | Where-Object { $_ -ne '.avs' }) -join '/'))."
}

$ffmpegExe = $Ffmpeg
if (-not [System.IO.Path]::IsPathRooted($ffmpegExe)) {
    $cmd = Get-Command $ffmpegExe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "ffmpeg not found: $Ffmpeg" }
    $ffmpegExe = $cmd.Source
}
$ffprobeExe = Get-FfprobeExePath $ffmpegExe

$outDir = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$base = [System.IO.Path]::GetFileNameWithoutExtension($fullInput)
if ($base.EndsWith('.mp4', [StringComparison]::OrdinalIgnoreCase)) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($base)
}
if ($base.EndsWith('.faststart', [StringComparison]::OrdinalIgnoreCase)) {
    $base = $base.Substring(0, $base.Length - '.faststart'.Length)
}
$outFile = if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    [System.IO.Path]::GetFullPath($OutputFile)
} else {
    Join-Path $outDir (Get-DefaultFisheyeMezzanineFileName -MediaBase $base)
}
$outFileDir = [System.IO.Path]::GetDirectoryName($outFile)
if (-not (Test-Path -LiteralPath $outFileDir)) {
    New-Item -ItemType Directory -Path $outFileDir -Force | Out-Null
}

if ($ClearOutputOnly) {
    Clear-ExistingFisheyeFragOutput -OutputPath $outFile
    exit 0
}

$eyeCap = if ($FisheyeMaxEyeSize -ge 256) { $FisheyeMaxEyeSize } else { 0 }
$settings = Resolve-FisheyeTranscodeSettings -AvsPath $fullInput -FfprobeExe $ffprobeExe `
    -RequestedEyeSize $FisheyeEyeSize -MaxEyeSize $eyeCap `
    -InputHFov $FisheyeInputHFov -InputVFov $FisheyeInputVFov `
    -OutputHFov $FisheyeOutputHFov -OutputVFov $FisheyeOutputVFov
$filter = Get-FisheyeFilterComplex -EyeSize $settings.EyeSize `
    -PerEyeW $settings.PerEyeW -PerEyeH $settings.PerEyeH `
    -InputHFov $settings.InputHFov -InputVFov $settings.InputVFov `
    -OutputHFov $settings.OutputHFov -OutputVFov $settings.OutputVFov `
    -Interp $FisheyeInterp -SharpenAmount $FisheyeSharpen -ScaleFlags $FisheyeScaleFlags `
    -FlatSource:(-not $settings.IsSbs)
$sourceFpsArg = Get-VideoFrameRateArg -MediaPath $fullInput -FfprobeExe $ffprobeExe
$layout = if ($settings.IsSbs) { 'SBS L/R' } else { 'flat -> single fisheye eye' }
$mbps = $VideoBitrateMbps
if ($mbps -lt 1) { throw "VideoBitrateMbps must be >= 1 (got $VideoBitrateMbps)." }
$bufMbps = [Math]::Min(100, $mbps * 2)
$fpsNote = if ($sourceFpsArg) { " fps=$sourceFpsArg" } else { '' }
Write-Host ("Fisheye v360: {0} {1}x{2} -> eye {3}; mezzanine=av1_qsv preset={4} gq={5} VBR ~{6}M{7}; fragmented MP4; out {8}" -f `
    $layout, $settings.SbsWidth, $settings.SbsHeight, $settings.EyeSize, `
    $FisheyeQsvPreset, $GlobalQuality, $mbps, $fpsNote, $outFile)

$inv = [Globalization.CultureInfo]::InvariantCulture
$ssFmt = $SsSec.ToString('0.######', $inv)
$argList = @(
    '-hide_banner', '-y',
    '-ss', $ssFmt,
    '-fflags', '+genpts+discardcorrupt',
    '-err_detect', 'ignore_err',
    '-filter_complex_threads', '0',
    '-i', $fullInput,
    '-filter_complex', $filter,
    '-map', '[outv]',
    '-map', '0:a?'
)
$argList += @(
    '-c:v', 'av1_qsv',
    '-preset', $FisheyeQsvPreset,
    '-global_quality', [string]$GlobalQuality,
    '-g', '60',
    '-rc', 'vbr',
    '-b:v', "${mbps}M",
    '-maxrate', "${mbps}M",
    '-bufsize', "${bufMbps}M",
    '-c:a', 'aac',
    '-b:a', '192k',
    '-ar', '48000',
    '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
    '-flush_packets', '1'
)
if ($sourceFpsArg) {
    $argList += @('-r', $sourceFpsArg)
}
if ($DurationSec -gt 0) {
    $argList += @('-t', [string]$DurationSec)
}
$argList += $outFile

$commandLine = (@($ffmpegExe) + $argList | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
}) -join ' '
Write-Host "FFmpeg command: $commandLine"

if ($DryRun) { return }

Clear-ExistingFisheyeFragOutput -OutputPath $outFile

$logDir = Join-Path ([System.IO.Path]::GetDirectoryName($outFile)) 'logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logStem = [System.IO.Path]::GetFileNameWithoutExtension($outFile) + '_v360'
$logOut = Join-Path $logDir ($logStem + '.stdout.log')
$logErr = Join-Path $logDir ($logStem + '.stderr.log')

if ($Background) {
    $p = Start-Process -FilePath $ffmpegExe -ArgumentList (Format-ProcessArgumentLine $argList) -NoNewWindow -PassThru `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr
    Write-Host "V360 ffmpeg started pid=$($p.Id) -> $outFile"
    Write-Host "V360 ffmpeg logs: $logErr"
    exit 0
}
$p = Start-Process -FilePath $ffmpegExe -ArgumentList (Format-ProcessArgumentLine $argList) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $logOut -RedirectStandardError $logErr
Write-Host "FFmpeg exit code: $($p.ExitCode)"
exit $p.ExitCode
