#Requires -Version 5.1
<#
.SYNOPSIS
  Manually delete/truncate all files under the DLNA segment root (3d_fullsbs_trans).

.DESCRIPTION
  Workflows (flat / fisheye / hybrid) obfuscate media filenames on quit instead of deleting.
  Use this script when you want the former delete-on-quit behavior. It calls the function
  Clear-DlnaSegmentRootContents (not a folder) in individual_transcode\Invoke-LeafFfmpegControl.ps1:
    - stop leaf 3d_op_* ffmpeg
    - delete or truncate files under M:\m1_media\3d_fullsbs_trans
      (flat / fisheye / hybrid / fisheye_temp segments + avs\*.avs, <hash>.tmp,
      .dlna_obf_map.json, logs)
    - recreate empty flat / fisheye / hybrid / fisheye_temp trees

  Lives beside Readme.txt / Purge-OldAvs.ps1 so you can double-click it from the playlist
  root. The delete logic stays in Invoke-LeafFfmpegControl.ps1.

  Double-click friendly. See Readme.txt / LOGS.md.

.PARAMETER Root
  Override DLNA root. Default: Ensure-DlnaSegmentRoot (preferred M:\m1_media\3d_fullsbs_trans).

.PARAMETER KeepLogs
  Leave *.log and logs\ trees in place.

.PARAMETER DryRun
  Report actions without deleting.

.PARAMETER NoStopLeafExport
  Do not taskkill leaf DLNA export ffmpeg first.

.EXAMPLE
  .\Cleanup-DlnaSegmentRoot.ps1

.EXAMPLE
  .\Cleanup-DlnaSegmentRoot.ps1 -KeepLogs -DryRun
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [switch] $KeepLogs,
    [switch] $DryRun,
    [switch] $NoStopLeafExport
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$leafControl = Join-Path $here 'individual_transcode\Invoke-LeafFfmpegControl.ps1'
if (-not (Test-Path -LiteralPath $leafControl -PathType Leaf)) {
    throw "Invoke-LeafFfmpegControl.ps1 not found: $leafControl"
}
. $leafControl

if (-not (Get-Command Clear-DlnaSegmentRootContents -ErrorAction SilentlyContinue)) {
    throw 'Clear-DlnaSegmentRootContents is not available after loading Invoke-LeafFfmpegControl.ps1'
}

Write-Host 'Cleanup-DlnaSegmentRoot: deleting media/logs under DLNA segment root (manual).'
$result = Clear-DlnaSegmentRootContents `
    -Root $Root `
    -KeepLogs:$KeepLogs.IsPresent `
    -DryRun:$DryRun.IsPresent `
    -NoStopLeafExport:$NoStopLeafExport.IsPresent

Write-Host ("Done. Root={0} Deleted={1} Truncated={2} Failed={3} StoppedLeafFfmpeg={4}" -f `
    $result.Root, $result.Deleted, $result.Truncated, $result.Failed, $result.Stopped)

if ($Host.Name -eq 'ConsoleHost' -and -not $DryRun.IsPresent) {
    Write-Host 'Press Enter to close...'
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 3 }
}
