#Requires -Version 5.1
<#
.SYNOPSIS
  Register HKCU context menu: right-click common video types / .avs -> Transcode with FFmpeg (RememberFiles resume)

.NOTES
  Run once per user. No admin required (uses HKCU:\Software\Classes).
  To remove these entries, run Uninstall-ContextMenu.ps1 from the same folder.

  The registry command embeds the full path to Run-TranscodeFfmpeg.ps1 under $PSScriptRoot (the folder from which you
  ran this installer). Explorer always invokes that path; transcode_logs\, transcode_failures.log, and default -LogFile
  resolution follow that same script directory. Copying scripts elsewhere does not redirect logs until you run this
  installer again from the copy you want Explorer to use (then restart Explorer if the menu still shows old behavior).

  Fisheye workflow (v360 mezzanine + template AVS; context menu auto pass-2 chase):
    1. Source video (.mp4, .mkv, .mov, .m4v, .avi, .wmv, .ts, .m2ts, .webm) -> Run-V360PrepareFisheye.ps1 -ContextMenu -SegmentNameSuffix LR_180_FISHEYE
       (LR_180_FISHEYE trial suffix; standardized path if present; pass 1 RememberFiles + pass-2 chase; may hand off to run_batch_fisheye_v360.ps1 -ResumeAfter)
    2. .avs -> flat Run-TranscodeFfmpeg.ps1 on fisheye_temp\avs (manual pass 2 if needed; LR_180_FISHEYE suffix on v360 frag menu)

  Other menu entries:
    Same source extensions -> plain SBS transcode with -SegmentNameSuffix Full_SBS (Skybox Full_SBS; standardized path if present under 3d_playlist_local\standardized)
    .avs  -> flat SBS transcode for playlist AVS (StreamTo3D batch / non-fisheye_temp)

  Re-run after copying scripts to a new folder so Explorer uses that launcher's path.
  Re-run also after SegmentNameSuffix / flat|fisheye output folders were added so Explorer picks up naming.
  On Windows 11, registry shell verbs usually appear in the classic menu (Shift+F10,
  "Show more options", or third-party "classic menu" tweaks), not the short top-level
  menu. This script sets Position=Top so the entry is grouped near the top there.
  Restart Explorer if it does not show up (see messages at end of script).
#>
$ErrorActionPreference = 'Stop'

$installDir = $PSScriptRoot
$launcher = Join-Path $installDir 'Run-TranscodeFfmpeg.ps1'
$v360Prepare = Join-Path $installDir 'Run-V360PrepareFisheye.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Error "Launcher not found: $launcher"
    exit 1
}
if (-not (Test-Path -LiteralPath $v360Prepare)) {
    Write-Error "V360 prepare script not found: $v360Prepare"
    exit 1
}

# %L = long path; Explorer expands it before PowerShell runs.
# Keep F:\f1_media\3d_fullsbs_trans in the registry so Skybox DLNA share path stays stable;
# Ensure-DlnaSegmentRoot recreates that path via %AppData% junction+subst when F: is missing.
$leafFfmpegControlScript = Join-Path $installDir 'Invoke-LeafFfmpegControl.ps1'
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
}
$dlnaSegmentRoot = if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
    Ensure-DlnaSegmentRoot
} else {
    'F:\f1_media\3d_fullsbs_trans'
}
$flatSegmentDir = if (Get-Command Get-DlnaSegmentOutputDirectory -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputDirectory -Kind flat -Root $dlnaSegmentRoot
} else {
    Join-Path $dlnaSegmentRoot 'flat'
}
$fisheyeSegmentDir = if (Get-Command Get-DlnaSegmentOutputDirectory -ErrorAction SilentlyContinue) {
    Get-DlnaSegmentOutputDirectory -Kind fisheye -Root $dlnaSegmentRoot
} else {
    Join-Path $dlnaSegmentRoot 'fisheye'
}
$cmdPlain = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -LiteralPath `"%L`" -ContextMenu -SegmentNameSuffix Full_SBS -OutputDirectory `"$flatSegmentDir`""
$cmdV360Prepare = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$v360Prepare`" -LiteralPath `"%L`" -ContextMenu -SegmentNameSuffix LR_180_FISHEYE -SegmentOutputDirectory `"$fisheyeSegmentDir`""
$cmdV360FragAvs = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -LiteralPath `"%L`" -ContextMenu -SkipOrchestrator -SegmentNameSuffix LR_180_FISHEYE -OutputDirectory `"$fisheyeSegmentDir`""

# Match Run-V360PrepareFisheye.ps1 + generate_media_listings_lcl.py + Run-TranscodeFfmpeg.ps1 linked-source types.
$sourceMediaExtensions = @(
    '.mp4', '.mkv', '.mov', '.m4v', '.avi', '.wmv', '.ts', '.m2ts', '.webm'
)

$menuEntries = [System.Collections.Generic.List[hashtable]]::new()
foreach ($ext in $sourceMediaExtensions) {
    [void]$menuEntries.Add(@{
        Ext      = $ext
        Verb     = 'PrepareV360FisheyeFragAvs'
        Label    = 'Prepare v360 fisheye + chase DLNA segments'
        Command  = $cmdV360Prepare
        Position = 'Top'
    })
    [void]$menuEntries.Add(@{
        Ext      = $ext
        Verb     = 'TranscodeFfmpegResume'
        Label    = 'Transcode (3dSbs flat, ffmpeg re ss)'
        Command  = $cmdPlain
        Position = 'Top'
    })
}
[void]$menuEntries.Add(@{
    Ext      = '.avs'
    Verb     = 'TranscodeV360FragAvsSegments'
    Label    = 'Transcode (v360 frag avs -> 60s segments)'
    Command  = $cmdV360FragAvs
    Position = 'Top'
})
[void]$menuEntries.Add(@{
    Ext      = '.avs'
    Verb     = 'TranscodeFfmpegResumeSbs'
    Label    = 'Transcode (3dSbs flat, ffmpeg re ss)'
    Command  = $cmdPlain
    Position = 'Top'
})

foreach ($entry in $menuEntries) {
    foreach ($base in @(
        "HKCU:\Software\Classes\$($entry.Ext)",
        "HKCU:\Software\Classes\SystemFileAssociations\$($entry.Ext)"
    )) {
        $shellKey = Join-Path $base "shell\$($entry.Verb)"
        $commandKey = Join-Path $shellKey 'command'

        New-Item -Path $shellKey -Force | Out-Null
        New-Item -Path $commandKey -Force | Out-Null

        Set-ItemProperty -LiteralPath $shellKey -Name '(default)' -Value $entry.Label
        Set-ItemProperty -LiteralPath $shellKey -Name 'Position' -Type String -Value $entry.Position
        Set-ItemProperty -LiteralPath $commandKey -Name '(default)' -Value $entry.Command

        Write-Host "Installed: $shellKey -> $($entry.Label)"
    }
}

# Retire inline -Fisheye .avs menu (same verb name as .mp4 flat; old installs pointed here).
foreach ($base in @(
    'HKCU:\Software\Classes\.avs',
    'HKCU:\Software\Classes\SystemFileAssociations\.avs'
)) {
    $retiredKey = Join-Path $base 'shell\TranscodeFfmpegResume'
    if (Test-Path -LiteralPath $retiredKey) {
        Remove-Item -LiteralPath $retiredKey -Recurse -Force
        Write-Host "Retired: $retiredKey (inline -Fisheye transcode)"
    }
}

Write-Host "Source video extensions: $($sourceMediaExtensions -join ', ')"
Write-Host "v360 prepare:          $cmdV360Prepare"
Write-Host ".avs v360 segments:    $cmdV360FragAvs"
Write-Host "flat transcode (.avs): $cmdPlain"
Write-Host ""
Write-Host "If the item is missing: restart Explorer (taskbar disappears briefly):"
Write-Host '  Stop-Process -Name explorer -Force; Start-Process explorer'
Write-Host 'Windows 11: custom HKCU verbs are usually under "Show more options" (classic menu); Position=Top applies there.'
