#Requires -Version 5.1
<#
.SYNOPSIS
  Register HKCU context menu: right-click .avs / .mp4 -> Transcode with FFmpeg (RememberFiles resume)

.NOTES
  Run once per user. No admin required (uses HKCU:\Software\Classes).
  To remove these entries, run Uninstall-ContextMenu.ps1 from the same folder.

  The registry command embeds the full path to Run-TranscodeFfmpeg.ps1 under $PSScriptRoot (the folder from which you
  ran this installer). Explorer always invokes that path; transcode_logs\, transcode_failures.log, and default -LogFile
  resolution follow that same script directory. Copying scripts elsewhere does not redirect logs until you run this
  installer again from the copy you want Explorer to use (then restart Explorer if the menu still shows old behavior).

  Registers under BOTH the extension key and SystemFileAssociations so the item still
  appears when the type is owned by a ProgID (default app).   On Windows 11, registry shell verbs usually appear in the classic menu (Shift+F10,
  "Show more options", or third-party "classic menu" tweaks), not the short top-level
  menu. This script sets Position=Top so the entry is grouped near the top there.
  Restart Explorer if it does not show up (see messages at end of script).
#>
$ErrorActionPreference = 'Stop'

$installDir = $PSScriptRoot
$launcher = Join-Path $installDir 'Run-TranscodeFfmpeg.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Error "Launcher not found: $launcher"
    exit 1
}

# %L = long path; Explorer expands it before PowerShell runs
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -LiteralPath `"%L`" -ContextMenu"

foreach ($ext in @('.avs', '.mp4')) {
    foreach ($base in @(
        "HKCU:\Software\Classes\$ext",
        "HKCU:\Software\Classes\SystemFileAssociations\$ext"
    )) {
        $shellKey = Join-Path $base 'shell\TranscodeFfmpegResume'
        $commandKey = Join-Path $shellKey 'command'

        New-Item -Path $shellKey -Force | Out-Null
        New-Item -Path $commandKey -Force | Out-Null

        Set-ItemProperty -LiteralPath $shellKey -Name '(default)' -Value 'Transcode (i/p:3dSbs, ffmpeg re ss)'
        # Near-top placement in the classic/full context menu (Explorer "shell" verbs).
        Set-ItemProperty -LiteralPath $shellKey -Name 'Position' -Type String -Value 'Top'
        Set-ItemProperty -LiteralPath $commandKey -Name '(default)' -Value $cmd

        Write-Host "Installed: $shellKey"
    }
}

Write-Host ""
Write-Host "Command: $cmd"
Write-Host ""
Write-Host "If the item is missing: restart Explorer (taskbar disappears briefly):"
Write-Host '  Stop-Process -Name explorer -Force; Start-Process explorer'
Write-Host 'Windows 11: custom HKCU verbs are usually under "Show more options" (classic menu); Position=Top applies there.'
