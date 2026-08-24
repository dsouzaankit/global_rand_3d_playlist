#Requires -Version 5.1
<#
.SYNOPSIS
  Remux already-3D source into rotating DLNA minute segments with stream copy (like 3d_loop_segments).

.DESCRIPTION
  ffmpeg: -re + -c copy + -f segment -segment_time 60 -segment_wrap 2 -reset_timestamps 1
  Output pattern: 3d_op_%02d_LR_180.mkv (Skybox LR_180; distinct from flat Full_SBS / fisheye LR_180_FISHEYE).
  No DLNA idle monitor - parent hybrid/fisheye batch owns lifetime.
  Space pauses/resumes leaf export; Enter cancels when -AllowEnterCancel (via console poll).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $LiteralPath,
    [string] $OutputDirectory = 'M:\m1_media\3d_fullsbs_trans\hybrid',
    [string] $SegmentNameSuffix = 'LR_180',
    [int] $SsMsOverride = -1,
    [string] $Ffmpeg = 'ffmpeg',
    [string] $WorkflowDeadlineUtc = '',
    [int] $OrchestratorPid = 0,
    [string] $OrchestratorStartTimeUtc = '',
    [int] $TranscodeTimeoutSec = -1,
    [switch] $NoPause,
    [switch] $NoClampSeek,
    [switch] $DryRun,
    [switch] $AllowEnterCancel,
    [string] $BatchStdOutLog = ''
)

$ErrorActionPreference = 'Stop'
$script:ExitCodeTimeout = 124
$script:ExitCodeCancel = 130

$thisScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    [System.IO.Path]::GetFullPath($PSCommandPath)
} else {
    [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
}
$thisScriptDir = [System.IO.Path]::GetDirectoryName($thisScriptPath)

$potPlayerRegistrySeekScript = Join-Path $thisScriptDir 'Get-PotPlayerRegistrySeek.ps1'
if (Test-Path -LiteralPath $potPlayerRegistrySeekScript -PathType Leaf) {
    . $potPlayerRegistrySeekScript
}
$leafFfmpegControlScript = Join-Path $thisScriptDir 'Invoke-LeafFfmpegControl.ps1'
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
}
# Recreate dummy M:\m1_media\3d_fullsbs_trans (Skybox DLNA path) via %AppData% junction+subst.
if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    [void](Ensure-DlnaSegmentRoot -Force)
}
if (Get-Command Convert-DlnaPlaceholderSharePath -ErrorAction SilentlyContinue) {
    $OutputDirectory = Convert-DlnaPlaceholderSharePath -Path $OutputDirectory
}
$resolveFisheyeScript = Join-Path $thisScriptDir 'Resolve-FisheyePlaylistMedia.ps1'
if (Test-Path -LiteralPath $resolveFisheyeScript -PathType Leaf) {
    . $resolveFisheyeScript
}

if ([string]::IsNullOrWhiteSpace($SegmentNameSuffix) -and (Get-Command Get-AsIsDlnaSegmentSuffix -ErrorAction SilentlyContinue)) {
    $SegmentNameSuffix = Get-AsIsDlnaSegmentSuffix -FullPath $LiteralPath
}
if ([string]::IsNullOrWhiteSpace($SegmentNameSuffix)) {
    $SegmentNameSuffix = 'LR_180'
}

$HardcodedOutputFilePattern = if (Get-Command Get-DlnaSegmentOutputPattern -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputPattern -Suffix $SegmentNameSuffix
} else {
    ("3d_op_%02d_{0}.mkv" -f ($SegmentNameSuffix.Trim() -replace '[\\/:*?"<>|]', '_'))
}
$DlnaSegmentLeafNames = if (Get-Command Get-DlnaSegmentOutputLeaves -ErrorAction SilentlyContinue) {
    @(Get-DlnaSegmentOutputLeaves -Suffix $SegmentNameSuffix)
} else {
    @(
        ("3d_op_00_{0}.mkv" -f ($SegmentNameSuffix.Trim() -replace '[\\/:*?"<>|]', '_')),
        ("3d_op_01_{0}.mkv" -f ($SegmentNameSuffix.Trim() -replace '[\\/:*?"<>|]', '_'))
    )
}

function Get-AsIsFfprobeExePath {
    param([string] $FfmpegExe)
    if (-not [string]::IsNullOrWhiteSpace($FfmpegExe)) {
        $dir = [System.IO.Path]::GetDirectoryName($FfmpegExe)
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            $candidate = Join-Path $dir 'ffprobe.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-AsIsFormatDurationSeconds {
    param([string] $MediaPath, [string] $FfprobeExe)
    if ([string]::IsNullOrWhiteSpace($FfprobeExe) -or -not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
        return $null
    }
    try {
        $raw = & $FfprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
        $s = ([string]$raw).Trim()
        $n = 0.0
        if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -gt 0) {
            return $n
        }
    } catch { }
    return $null
}

function Write-AsIsBatchFinishedMarker {
    param([string] $StdOutPath, [int] $Code)
    if ([string]::IsNullOrWhiteSpace($StdOutPath)) { return }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($StdOutPath)
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Match prepare/hybrid wait: marker is "<BatchStdOutLog>.finished" (e.g. *.stdout.log.finished).
        Add-Content -LiteralPath $StdOutPath -Value ("[batch-finished] exit={0}" -f $Code) -Encoding utf8
        $marker = "$StdOutPath.finished"
        [System.IO.File]::WriteAllText($marker, (Get-Date).ToUniversalTime().ToString('o'))
    } catch {
        Write-Warning "Could not write as-is batch finished marker ($StdOutPath): $_"
    }
}

$exitCode = 1
try {
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Input not found: $LiteralPath"
    }
    $fullInput = [System.IO.Path]::GetFullPath($LiteralPath)

    $ssMs = [int64]0
    if ($SsMsOverride -ge 0) {
        $ssMs = [int64]$SsMsOverride
    } elseif (Get-Command Get-SeekMsForRememberedPath -ErrorAction SilentlyContinue) {
        $ssMs = [int64](Get-SeekMsForRememberedPath $fullInput)
        if (Get-Command Get-QuickSeekOverrideMs -ErrorAction SilentlyContinue) {
            $quick = Get-QuickSeekOverrideMs
            if ($null -ne $quick) { $ssMs = [int64]$quick }
        }
    }

    $root = [System.IO.Path]::GetFullPath($OutputDirectory)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $outPath = Join-Path $root $HardcodedOutputFilePattern

    $ffmpegExe = $Ffmpeg
    if (-not [System.IO.Path]::IsPathRooted($ffmpegExe)) {
        $cmdFfmpeg = Get-Command $ffmpegExe -ErrorAction SilentlyContinue
        if (-not $cmdFfmpeg) { throw "ffmpeg not found: $Ffmpeg" }
        $ffmpegExe = $cmdFfmpeg.Source
    }
    $ffprobeExe = Get-AsIsFfprobeExePath -FfmpegExe $ffmpegExe

    if (-not $NoClampSeek -and $ffprobeExe) {
        $durSec = Get-AsIsFormatDurationSeconds -MediaPath $fullInput -FfprobeExe $ffprobeExe
        if ($null -ne $durSec) {
            $maxStartSec = [Math]::Max(0.0, $durSec - 0.25)
            if (([double]$ssMs / 1000.0) -gt $maxStartSec) {
                Write-Host "Resume seek past usable end (duration $([math]::Round($durSec, 3)) s). Skipping ffmpeg (exit 0)."
                $exitCode = 0
                Write-AsIsBatchFinishedMarker -StdOutPath $BatchStdOutLog -Code 0
                return
            }
        }
    }

    $ssSec = [double]$ssMs / 1000.0
    $fmtSec = $ssSec.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
    $argList = @(
        '-hide_banner', '-y',
        '-ss', $fmtSec,
        '-re',
        '-i', $fullInput,
        '-map', '0:v',
        '-map', '0:a?',
        '-c', 'copy',
        '-f', 'segment',
        '-segment_time', '60',
        '-segment_wrap', '2',
        '-reset_timestamps', '1',
        $outPath
    )
    $commandLine = (@($ffmpegExe) + $argList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '

    Write-Host "As-is segment copy (-c copy -re) -> $outPath"
    Write-Host ("Resume (-ss): {0} min | suffix={1}" -f [math]::Round($ssSec / 60.0, 4), $SegmentNameSuffix)
    Write-Host "FFmpeg command: $commandLine"

    if ($DryRun) {
        $exitCode = 0
        Write-AsIsBatchFinishedMarker -StdOutPath $BatchStdOutLog -Code 0
        return
    }

    $deadlineUtc = $null
    if (Get-Command Convert-TranscodeWorkflowDeadlineUtc -ErrorAction SilentlyContinue) {
        $deadlineUtc = Convert-TranscodeWorkflowDeadlineUtc -UtcIso $WorkflowDeadlineUtc
    }
    $timeoutAtUtc = [datetime]::MaxValue
    if ($TranscodeTimeoutSec -gt 0) {
        $timeoutAtUtc = [DateTime]::UtcNow.AddSeconds($TranscodeTimeoutSec)
    }

    $logsRoot = Join-Path $thisScriptDir 'transcode_logs\ffmpeg_process'
    if (-not (Test-Path -LiteralPath $logsRoot)) {
        New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeBase = ($([System.IO.Path]::GetFileNameWithoutExtension($fullInput)) -replace '[\\/:*?"<>|]', '_').Substring(0, [Math]::Min(40, ([System.IO.Path]::GetFileNameWithoutExtension($fullInput)).Length))
    $stdErrPath = Join-Path $logsRoot ("{0}_{1}_asis_{2}.stderr.log" -f $stamp, $PID, $safeBase)
    $stdOutPath = Join-Path $logsRoot ("{0}_{1}_asis_{2}.stdout.log" -f $stamp, $PID, $safeBase)

    # Single ArgumentList string (same as Run-TranscodeFfmpeg / 3d_loop_segments) so paths with spaces stay intact.
    $ffArgLine = ($argList | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
    $proc = Start-Process -FilePath $ffmpegExe -ArgumentList $ffArgLine `
        -WorkingDirectory $root -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdOutPath -RedirectStandardError $stdErrPath
    Write-Host "As-is ffmpeg pid=$($proc.Id) stderr=$stdErrPath"
    Write-Host 'Console: Space=pause/resume leaf DLNA export; Enter=cancel (when parent allows).'
    if (-not [string]::IsNullOrWhiteSpace($BatchStdOutLog)) {
        try {
            Add-Content -LiteralPath $BatchStdOutLog -Value ("As-is ffmpeg pid={0} stderr={1}" -f $proc.Id, $stdErrPath) -Encoding utf8
        } catch { }
    }

    $cancelled = $false
    while (-not $proc.HasExited) {
        if ($null -ne $deadlineUtc -and (Get-Command Test-TranscodeWorkflowDeadlineExpired -ErrorAction SilentlyContinue) `
            -and (Test-TranscodeWorkflowDeadlineExpired -DeadlineUtc $deadlineUtc)) {
            Write-Warning 'Workflow deadline reached; stopping as-is segment copy.'
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            $exitCode = $script:ExitCodeTimeout
            break
        }
        if ($timeoutAtUtc -lt [datetime]::MaxValue -and [DateTime]::UtcNow -ge $timeoutAtUtc) {
            Write-Warning 'TranscodeTimeoutSec reached; stopping as-is segment copy.'
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            $exitCode = $script:ExitCodeTimeout
            break
        }
        if ($OrchestratorPid -gt 0) {
            $parentAlive = $null -ne (Get-Process -Id $OrchestratorPid -ErrorAction SilentlyContinue)
            if (-not $parentAlive) {
                Write-Warning "Parent pid=$OrchestratorPid gone; stopping as-is segment copy."
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
                $exitCode = $script:ExitCodeCancel
                break
            }
        }

        $enterCancel = $false
        if (Get-Command Invoke-TranscodeConsoleKeyPoll -ErrorAction SilentlyContinue) {
            [void](Invoke-TranscodeConsoleKeyPoll -AllowEnterCancel:$AllowEnterCancel.IsPresent -EnterCancel ([ref]$enterCancel))
        }
        if ($enterCancel) {
            Write-Host 'Enter pressed - cancelling as-is segment copy.'
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            $cancelled = $true
            $exitCode = $script:ExitCodeCancel
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $cancelled -and $exitCode -ne $script:ExitCodeTimeout -and $exitCode -ne $script:ExitCodeCancel) {
        try {
            $proc.Refresh()
            if ($proc.HasExited) { $exitCode = [int]$proc.ExitCode } else { $exitCode = 1 }
        } catch {
            $exitCode = 1
        }
    }

    if ($exitCode -eq 0) {
        $readyLeaves = 0
        foreach ($leaf in $DlnaSegmentLeafNames) {
            $p = Join-Path $root $leaf
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                try {
                    if ((Get-Item -LiteralPath $p).Length -ge 1048576L) { $readyLeaves++ }
                } catch { }
            }
        }
        Write-Host ("As-is segment check: {0}/{1} leaves >= 1 MiB under {2}" -f $readyLeaves, $DlnaSegmentLeafNames.Count, $root)
        if ($readyLeaves -lt 1) {
            Write-Warning "As-is remux exit 0 but no playable DLNA segments under $root (check stderr: $stdErrPath)."
            $exitCode = 1
        }
    }
}
catch {
    Write-Error $_
    $exitCode = 1
}
finally {
    Write-AsIsBatchFinishedMarker -StdOutPath $BatchStdOutLog -Code $exitCode
    if (-not $NoPause) {
        Write-Host 'Done. Pausing 5s...'
        Start-Sleep -Seconds 5
    }
}

exit $exitCode
