#Requires -Version 5.1
<#
.SYNOPSIS
  Choose flat vs fisheye workflow from source bitrate + video codec.

.DESCRIPTION
  Flat when:
    - bitrate < 4 Mbps AND codec is not HEVC/H.265/AV1, OR
    - bitrate < 2 Mbps AND codec is HEVC/H.265/AV1
  Otherwise fisheye.

  Bitrate prefers format=bit_rate; falls back to video stream bit_rate when format is missing.
#>

function Get-HybridFfprobeExePath {
    param([string] $FfmpegExe = 'ffmpeg')
    if (-not [string]::IsNullOrWhiteSpace($FfmpegExe)) {
        $dir = [System.IO.Path]::GetDirectoryName($FfmpegExe)
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            $candidate = Join-Path $dir 'ffprobe.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-HybridFfprobeOutput {
    param(
        [string] $FfprobeExe,
        [string[]] $ArgumentList
    )
    if ([string]::IsNullOrWhiteSpace($FfprobeExe) -or -not (Test-Path -LiteralPath $FfprobeExe -PathType Leaf)) {
        return $null
    }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $FfprobeExe @ArgumentList 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-HybridFormatBitrateBps {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-show_entries', 'format=bit_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq 'N/A') { return $null }
    $n = 0L
    if (-not [int64]::TryParse($s, [ref]$n)) { return $null }
    if ($n -le 0) { return $null }
    return $n
}

function Get-HybridVideoStreamBitrateBps {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=bit_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    if ($null -eq $raw) { return $null }
    foreach ($line in @($raw)) {
        $s = ([string]$line).Trim()
        if ($s -eq '' -or $s -eq 'N/A') { continue }
        $n = 0L
        if ([int64]::TryParse($s, [ref]$n) -and $n -gt 0) {
            return $n
        }
    }
    return $null
}

function Get-HybridVideoCodecName {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_name',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    if ($null -eq $raw) { return $null }
    foreach ($line in @($raw)) {
        $s = ([string]$line).Trim()
        if ($s -eq '' -or $s -eq 'N/A') { continue }
        return $s.ToLowerInvariant()
    }
    return $null
}

function Test-HybridHevcOrAv1Codec {
    param([string] $CodecName)
    if ([string]::IsNullOrWhiteSpace($CodecName)) { return $false }
    $c = $CodecName.Trim().ToLowerInvariant()
    return ($c -eq 'hevc' -or $c -eq 'h265' -or $c -eq 'hev1' -or $c -eq 'hvc1' -or $c -eq 'av1')
}

function Resolve-HybridWorkflowRoute {
    <#
    .SYNOPSIS
      Returns workflow kind 'flat' or 'fisheye' plus probe details for logging.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaFullPath,
        [string] $FfprobeExe = '',
        [long] $FlatNonHevcAv1MaxBps = 4000000L,
        [long] $FlatHevcAv1MaxBps = 2000000L
    )
    $full = [System.IO.Path]::GetFullPath($MediaFullPath)
    if ([string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $FfprobeExe = Get-HybridFfprobeExePath
    }
    $codec = $null
    $bps = $null
    $bpsSource = ''
    if (-not [string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $codec = Get-HybridVideoCodecName -MediaPath $full -FfprobeExe $FfprobeExe
        $bps = Get-HybridFormatBitrateBps -MediaPath $full -FfprobeExe $FfprobeExe
        if ($null -ne $bps) {
            $bpsSource = 'format'
        } else {
            $bps = Get-HybridVideoStreamBitrateBps -MediaPath $full -FfprobeExe $FfprobeExe
            if ($null -ne $bps) { $bpsSource = 'stream' }
        }
    }

    $isHevcAv1 = Test-HybridHevcOrAv1Codec -CodecName $codec
    $codecLabel = if ([string]::IsNullOrWhiteSpace($codec)) { 'unknown' } else { $codec }
    $kbpsLabel = if ($null -eq $bps) { 'unknown' } else { [string][math]::Round([double]$bps / 1000.0) }

    $kind = 'fisheye'
    $reason = ''
    if ($null -eq $bps) {
        $kind = 'fisheye'
        $reason = "bitrate unavailable (codec=$codecLabel); default fisheye"
    } elseif ($isHevcAv1) {
        if ($bps -lt $FlatHevcAv1MaxBps) {
            $kind = 'flat'
            $reason = "hevc/av1 ~${kbpsLabel} kbps < 2000 kbps -> flat"
        } else {
            $kind = 'fisheye'
            $reason = "hevc/av1 ~${kbpsLabel} kbps >= 2000 kbps -> fisheye"
        }
    } else {
        if ($bps -lt $FlatNonHevcAv1MaxBps) {
            $kind = 'flat'
            $reason = "non-hevc/av1 ($codecLabel) ~${kbpsLabel} kbps < 4000 kbps -> flat"
        } else {
            $kind = 'fisheye'
            $reason = "non-hevc/av1 ($codecLabel) ~${kbpsLabel} kbps >= 4000 kbps -> fisheye"
        }
    }

    # Segment suffixes: Full_SBS (flat); LR_180_FISHEYE (fisheye trial).
    $suffix = if ($kind -eq 'flat') { 'Full_SBS' } else { 'LR_180_FISHEYE' }
    return @{
        Kind       = $kind
        Suffix     = $suffix
        CodecName  = $codecLabel
        BitrateBps = $bps
        BitrateKbps = if ($null -eq $bps) { $null } else { [math]::Round([double]$bps / 1000.0) }
        BitrateSource = $bpsSource
        IsHevcAv1  = $isHevcAv1
        Reason     = $reason
        MediaPath  = $full
    }
}

function Get-HybridVideoFrameRateFraction {
    param(
        [string] $MediaPath,
        [string] $FfprobeExe
    )
    if ([string]::IsNullOrWhiteSpace($MediaPath) -or -not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $FfprobeExe = Get-HybridFfprobeExePath
    }
    $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
        '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=avg_frame_rate',
        '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
    )
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq '0/0' -or $s -eq 'N/A') {
        $raw = Invoke-HybridFfprobeOutput -FfprobeExe $FfprobeExe -ArgumentList @(
            '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate',
            '-of', 'default=noprint_wrappers=1:nokey=1', '--', $MediaPath
        )
        $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    }
    if ($s -match '^(\d+)/(\d+)$') {
        $num = [int64]$Matches[1]
        $den = [int64]$Matches[2]
        if ($num -gt 0 -and $den -gt 0) {
            return @{ Num = $num; Den = $den }
        }
    }
    return $null
}

function Get-FlatTempAvsFileName {
    param([string] $MediaFullPath)
    $name = [System.IO.Path]::GetFileName($MediaFullPath)
    return "StreamTo3D.flat_temp.$name.avs"
}

function Export-FlatPassthroughAvsFromTemplate {
    <#
    .SYNOPSIS
      Build a flat Full-SBS AVS from StreamTo3D.fisheye_temp.template.avs (no StreamTo3D GUI).
      Placeholder StreamTo3D_input.mp4 -> source media; mono/narrow frames are StackHorizontal-duplicated to SBS.
      convertfps=false (AssumeFPS only): DirectShow convertfps=true blends frames and blurs Full_SBS.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaFullPath,
        [Parameter(Mandatory = $true)]
        [string] $AvsOutFullPath,
        [string] $TemplatePath = '',
        [string] $FfprobeExe = ''
    )
    $mediaFull = [System.IO.Path]::GetFullPath($MediaFullPath)
    if (-not (Test-Path -LiteralPath $mediaFull -PathType Leaf)) {
        throw "Flat template AVS source media missing: $mediaFull"
    }

    if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
        $scriptDir = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($scriptDir)) {
            $scriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
        }
        $TemplatePath = Join-Path $scriptDir 'StreamTo3D.fisheye_temp.template.avs'
    }
    $templateFull = [System.IO.Path]::GetFullPath($TemplatePath)
    if (-not (Test-Path -LiteralPath $templateFull -PathType Leaf)) {
        throw "Flat AVS template not found: $templateFull"
    }

    $template = [IO.File]::ReadAllText($templateFull)
    $placeholder = 'StreamTo3D_input.mp4'
    $count = ([regex]::Matches($template, [regex]::Escape($placeholder))).Count
    if ($count -lt 1) {
        throw "Template missing placeholder '$placeholder': $templateFull"
    }

    $fpsNum = 30000
    $fpsDen = 1001
    if ([string]::IsNullOrWhiteSpace($FfprobeExe)) {
        $FfprobeExe = Get-HybridFfprobeExePath
    }
    $fpsParts = Get-HybridVideoFrameRateFraction -MediaPath $mediaFull -FfprobeExe $FfprobeExe
    if ($null -ne $fpsParts) {
        $fpsNum = $fpsParts.Num
        $fpsDen = $fpsParts.Den
    }

    $avsContent = $template.Replace($placeholder, $mediaFull)
    $avsContent = $avsContent.Replace('StreamTo3D_fps_num=30000', "StreamTo3D_fps_num=$fpsNum")
    $avsContent = $avsContent.Replace('StreamTo3D_fps_den=1001', "StreamTo3D_fps_den=$fpsDen")
    # Keep native frames. convertfps=true uses AviSynth ConvertFPS (blend) and blurs hybrid Full_SBS.
    $avsContent = $avsContent.Replace('convertfps=true', 'convertfps=false')

    $outAvsDir = [System.IO.Path]::GetDirectoryName($AvsOutFullPath)
    if (-not (Test-Path -LiteralPath $outAvsDir)) {
        New-Item -ItemType Directory -Path $outAvsDir -Force | Out-Null
    }
    $avsOutFull = [System.IO.Path]::GetFullPath($AvsOutFullPath)
    [IO.File]::WriteAllText($avsOutFull, $avsContent, [Text.UTF8Encoding]::new($false))
    Write-Host ("Exported flat AVS ({0}x '{1}' -> media; fps {2}/{3}): {4}" -f `
        $count, $placeholder, $fpsNum, $fpsDen, $avsOutFull)
    return $avsOutFull
}
