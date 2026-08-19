#Requires -Version 5.1
<#
.SYNOPSIS
  Deletes transcode/fisheye log files (double-click friendly).

.DESCRIPTION
  Default: delete all *.log under every discoverable playlist transcode_logs\ tree
  (F:\f1_media, P:\bbf_media, P:\all_scripts, F:\all_scripts) plus global fisheye_temp\logs.
  Removes fisheye_batch_prepare\*.finished markers.

  Locked logs (active encode/batch) are truncated to zero bytes when delete fails.

  See LOGS.md for a full list of log types and producers.

.PARAMETER LogsRoot
  Single transcode_logs folder only (skips discovery). Use for one playlist.

.PARAMETER LocalOnly
  Only this script's transcode_logs\ (no scan of media/deploy copies).

.PARAMETER DiscoverMediaRoots
  Top-level folders to search for *\3d_playlist_local\individual_transcode\transcode_logs.
  Default: F:\f1_media, P:\bbf_media, P:\all_scripts, F:\all_scripts

.PARAMETER IncludeFisheyeTempLogs
  Also delete *.log under FisheyeTempLogsRoot. Default: true.

.PARAMETER FisheyeTempLogsRoot
  Global fisheye pass-1 / chase-worker logs. Default: F:\f1_media\3d_fullsbs_trans\fisheye_temp\logs

.PARAMETER NoFisheyeTempLogs
  Skip fisheye_temp\logs.

.PARAMETER TruncateInstead
  Empty files in place instead of deleting (files remain in Explorer).

.PARAMETER PruneByCount
  Legacy mode: delete old transcode_*.log and orchestrator_child logs by count/age;
  trim transcode_failures.log by size instead of clearing everything.

.PARAMETER MaxTranscriptFiles
  PruneByCount only: keep this many newest transcode_*.log files. Default: 2.

.PARAMETER MaxChildLogFiles
  PruneByCount only: keep this many newest orchestrator_child logs. Default: 2.

.PARAMETER ChildLogMaxAgeDays
  PruneByCount only: delete child logs older than this many days. Default: 14.

.PARAMETER MaxFailuresLogBytes
  PruneByCount only: trim transcode_failures.log when larger than this. Default: 2MB.

.PARAMETER TailFailureLogLines
  PruneByCount only: lines to keep when trimming failures log. Default: 800.

.PARAMETER NoPause
  Skip 5-second wait before exit (double-click default pauses briefly).

.EXAMPLE
  .\Cleanup-TranscodeLogs.ps1

  Deletes logs under all discoverable playlist transcode_logs trees and fisheye_temp\logs.

.EXAMPLE
  .\Cleanup-TranscodeLogs.ps1 -LocalOnly

  Only deletes logs next to this script (one playlist copy).

.EXAMPLE
  .\Cleanup-TranscodeLogs.ps1 -PruneByCount -LocalOnly

  Old retention on a single transcode_logs folder.
#>
[CmdletBinding()]
param(
    [string] $LogsRoot = '',
    [switch] $LocalOnly,
    [string[]] $DiscoverMediaRoots = @('F:\f1_media', 'P:\bbf_media', 'P:\all_scripts', 'F:\all_scripts'),
    [switch] $IncludeFisheyeTempLogs,
    [string] $FisheyeTempLogsRoot = 'F:\f1_media\3d_fullsbs_trans\fisheye_temp\logs',
    [switch] $NoFisheyeTempLogs,
    [switch] $TruncateInstead,
    [switch] $PruneByCount,
    [int] $MaxTranscriptFiles = 2,
    [int] $MaxChildLogFiles = 2,
    [int] $ChildLogMaxAgeDays = 14,
    [long] $MaxFailuresLogBytes = 2L * 1024L * 1024L,
    [int] $TailFailureLogLines = 800,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('IncludeFisheyeTempLogs') -and -not $NoFisheyeTempLogs) {
    $IncludeFisheyeTempLogs = $true
}

$leafFfmpegControlScript = Join-Path $PSScriptRoot 'Invoke-LeafFfmpegControl.ps1'
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
}
if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    try {
        [void](Ensure-DlnaSegmentRoot)
        if ($FisheyeTempLogsRoot -eq 'F:\f1_media\3d_fullsbs_trans\fisheye_temp\logs' -and
            (Get-Command Get-FisheyeTempRoot -ErrorAction SilentlyContinue)) {
            $FisheyeTempLogsRoot = Join-Path (Get-FisheyeTempRoot) 'logs'
        }
    } catch {
        Write-Warning ("Ensure-DlnaSegmentRoot skipped: {0}" -f $_.Exception.Message)
    }
}

function Remove-OlderFilesByCount {
    param(
        [System.IO.FileInfo[]] $Files,
        [int] $KeepNewest
    )
    if ($null -eq $Files -or $Files.Count -le $KeepNewest) { return 0 }
    $remove = @($Files | Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepNewest)
    foreach ($f in $remove) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
    }
    return $remove.Count
}

function Remove-OlderFilesByAgeDays {
    param(
        [System.IO.FileInfo[]] $Files,
        [int] $MaxAgeDays
    )
    if ($MaxAgeDays -lt 0) { return 0 }
    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    $remove = @($Files | Where-Object { $_.LastWriteTime -lt $cutoff })
    foreach ($f in $remove) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
    }
    return $remove.Count
}

function Clear-LogFileContents {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.SetLength(0)
        $fs.Close()
        return $true
    } catch {
        try {
            Set-Content -LiteralPath $Path -Value '' -Encoding utf8 -NoNewline -ErrorAction Stop
            return $true
        } catch {
            Write-Warning "Could not truncate: $Path ($_)"
            return $false
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Remove-OrTruncateLogFile {
    param(
        [string] $Path,
        [bool] $TruncateOnly
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }
    if ($TruncateOnly) {
        return $(if (Clear-LogFileContents -Path $Path) { 'truncated' } else { 'failed' })
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return 'deleted'
    } catch {
        if (Clear-LogFileContents -Path $Path) {
            Write-Warning "In use; truncated instead of deleted: $Path"
            return 'truncated_locked'
        }
        Write-Warning "Could not delete or truncate: $Path ($_)"
        return 'failed'
    }
}

function Get-TranscodeLogFilesRecursive {
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.log' })
}

function Remove-FisheyePrepareFinishedMarkers {
    param([string] $TranscodeLogsRoot)
    $prepareDir = Join-Path $TranscodeLogsRoot 'fisheye_batch_prepare'
    if (-not (Test-Path -LiteralPath $prepareDir -PathType Container)) { return 0 }
    $markers = @(Get-ChildItem -LiteralPath $prepareDir -Filter '*.finished' -File -ErrorAction SilentlyContinue)
    foreach ($m in $markers) {
        Remove-Item -LiteralPath $m.FullName -Force -ErrorAction SilentlyContinue
    }
    return $markers.Count
}

function Get-DiscoverableTranscodeLogsRoots {
    param(
        [string] $ScriptTranscodeLogsRoot,
        [string[]] $MediaRoots
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$seen.Add([System.IO.Path]::GetFullPath($ScriptTranscodeLogsRoot))

    foreach ($mediaRoot in $MediaRoots) {
        if ([string]::IsNullOrWhiteSpace($mediaRoot) -or -not (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
            continue
        }
        $playlistDirs = @(Get-ChildItem -LiteralPath $mediaRoot -Directory -Recurse -Filter '3d_playlist_local' -ErrorAction SilentlyContinue)
        foreach ($pd in $playlistDirs) {
            $logs = Join-Path $pd.FullName 'individual_transcode\transcode_logs'
            if (Test-Path -LiteralPath $logs -PathType Container) {
                [void]$seen.Add([System.IO.Path]::GetFullPath($logs))
            }
        }
    }

    return @($seen | Sort-Object)
}

function Invoke-DeleteAllLogsUnderRoot {
    param(
        [string] $Root,
        [string] $Label,
        [bool] $TruncateOnly
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Write-Host "[$Label] not found: $Root"
        return @{ Deleted = 0; Truncated = 0; Failed = 0; FinishedRemoved = 0 }
    }

    $files = Get-TranscodeLogFilesRecursive -Root $Root
    $deleted = 0
    $truncated = 0
    $failed = 0
    foreach ($f in $files) {
        switch (Remove-OrTruncateLogFile -Path $f.FullName -TruncateOnly $TruncateOnly) {
            'deleted' { $deleted++ }
            { $_ -in @('truncated', 'truncated_locked') } { $truncated++ }
            'failed' { $failed++ }
        }
    }

    $finishedRemoved = 0
    if ($Label -match 'transcode_logs') {
        $finishedRemoved = Remove-FisheyePrepareFinishedMarkers -TranscodeLogsRoot $Root
    }

    $action = if ($TruncateOnly) { 'truncated' } else { 'deleted' }
    Write-Host "[$Label] $action $deleted log file(s); truncated $truncated; failed $failed - $Root"
    if ($finishedRemoved -gt 0) {
        Write-Host "[$Label] removed $finishedRemoved stale .finished marker(s) in fisheye_batch_prepare"
    }
    return @{ Deleted = $deleted; Truncated = $truncated; Failed = $failed; FinishedRemoved = $finishedRemoved }
}

function Invoke-PruneByCountCleanup {
    param([string] $LogsRootPath)
    $childRoot = Join-Path $LogsRootPath 'orchestrator_child'
    $failuresPath = Join-Path $LogsRootPath 'transcode_failures.log'

    $removedTranscripts = 0
    $removedChildByAge = 0
    $removedChildByCount = 0
    $trimmedFailures = $false

    $transcriptLogs = @(
        Get-ChildItem -LiteralPath $LogsRootPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'transcode_*.log' -and $_.Name -ne 'transcode_failures.log' }
    )
    $removedTranscripts = Remove-OlderFilesByCount -Files $transcriptLogs -KeepNewest $MaxTranscriptFiles

    if (Test-Path -LiteralPath $childRoot -PathType Container) {
        $childLogs = @(
            Get-ChildItem -LiteralPath $childRoot -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ieq '.log' }
        )
        $removedChildByAge = Remove-OlderFilesByAgeDays -Files $childLogs -MaxAgeDays $ChildLogMaxAgeDays
        $childLogsAfterAge = @(
            Get-ChildItem -LiteralPath $childRoot -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ieq '.log' }
        )
        $removedChildByCount = Remove-OlderFilesByCount -Files $childLogsAfterAge -KeepNewest $MaxChildLogFiles
    }

    if (Test-Path -LiteralPath $failuresPath -PathType Leaf) {
        $fi = Get-Item -LiteralPath $failuresPath -ErrorAction Stop
        if ($fi.Length -gt $MaxFailuresLogBytes) {
            $tail = @(Get-Content -LiteralPath $failuresPath -ErrorAction SilentlyContinue | Select-Object -Last $TailFailureLogLines)
            Set-Content -LiteralPath $failuresPath -Value $tail -Encoding utf8
            $trimmedFailures = $true
        }
    }

    Write-Host "PruneByCount: removed transcript logs: $removedTranscripts"
    Write-Host "PruneByCount: removed child logs by age: $removedChildByAge"
    Write-Host "PruneByCount: removed child logs by count: $removedChildByCount"
    if ($trimmedFailures) {
        Write-Host "PruneByCount: trimmed transcode_failures.log (kept last $TailFailureLogLines lines)."
    } else {
        Write-Host 'PruneByCount: transcode_failures.log size is within limit.'
    }
}

$scriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    [System.IO.Path]::GetFullPath($PSCommandPath)
} else {
    [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
}
$scriptDir = [System.IO.Path]::GetDirectoryName($scriptPath)
$localLogsRoot = if ([string]::IsNullOrWhiteSpace($LogsRoot)) {
    [System.IO.Path]::Combine($scriptDir, 'transcode_logs')
} else {
    [System.IO.Path]::GetFullPath($LogsRoot)
}

$modeLabel = if ($PruneByCount) {
    'PruneByCount (legacy)'
} elseif ($TruncateInstead) {
    'Truncate in place (files remain)'
} else {
    'Delete all *.log (default)'
}
Write-Host "Cleanup mode: $modeLabel"
Write-Host "This script: $scriptPath"
if ($IncludeFisheyeTempLogs -and -not $NoFisheyeTempLogs) {
    Write-Host "Fisheye temp logs: $([System.IO.Path]::GetFullPath($FisheyeTempLogsRoot))"
}
Write-Host 'See LOGS.md for log type reference.'
Write-Host ''

$anyRoot = $false
$totalDeleted = 0
$totalTruncated = 0
$totalFailed = 0

if ($PruneByCount) {
    if (Test-Path -LiteralPath $localLogsRoot -PathType Container) {
        $anyRoot = $true
        Invoke-PruneByCountCleanup -LogsRootPath $localLogsRoot
    } else {
        Write-Host "Nothing to clean (transcode_logs not found): $localLogsRoot"
    }
} else {
    $transcodeRoots = if ($PSBoundParameters.ContainsKey('LogsRoot') -or $LocalOnly) {
        @($localLogsRoot)
    } else {
        Get-DiscoverableTranscodeLogsRoots -ScriptTranscodeLogsRoot $localLogsRoot -MediaRoots $DiscoverMediaRoots
    }

    Write-Host "Playlist transcode_logs roots ($($transcodeRoots.Count)):"
    foreach ($r in $transcodeRoots) { Write-Host "  $r" }
    Write-Host ''

    foreach ($root in $transcodeRoots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            $anyRoot = $true
            $stats = Invoke-DeleteAllLogsUnderRoot -Root $root -Label 'transcode_logs' -TruncateOnly:$TruncateInstead
            $totalDeleted += $stats.Deleted
            $totalTruncated += $stats.Truncated
            $totalFailed += $stats.Failed
        } else {
            Write-Host "[transcode_logs] skip (not found): $root"
        }
    }

    if ($IncludeFisheyeTempLogs -and -not $NoFisheyeTempLogs) {
        $fisheyeRoot = [System.IO.Path]::GetFullPath($FisheyeTempLogsRoot)
        if (Test-Path -LiteralPath $fisheyeRoot -PathType Container) {
            $anyRoot = $true
            $stats = Invoke-DeleteAllLogsUnderRoot -Root $fisheyeRoot -Label 'fisheye_temp' -TruncateOnly:$TruncateInstead
            $totalDeleted += $stats.Deleted
            $totalTruncated += $stats.Truncated
            $totalFailed += $stats.Failed
        } else {
            Write-Host "[fisheye_temp] not found: $fisheyeRoot"
        }
    }

    if ($anyRoot) {
        Write-Host ''
        Write-Host "Total: deleted $totalDeleted, truncated $totalTruncated, failed $totalFailed"
    }
}

if (-not $anyRoot) {
    Write-Host 'No log roots found to clean.'
}

if (-not $NoPause) {
    Write-Host ''
    Write-Host 'Cleanup complete. Exiting in 5 seconds...'
    Start-Sleep -Seconds 5
}

exit 0
