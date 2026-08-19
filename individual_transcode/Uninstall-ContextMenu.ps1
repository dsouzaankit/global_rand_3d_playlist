#Requires -Version 5.1
<#
.SYNOPSIS
  Removes all menu entries including retired inline -Fisheye (.avs TranscodeFfmpegResume).

.NOTES
  No admin required. Restart Explorer if the old item still appears until refresh:
  Stop-Process -Name explorer -Force; Start-Process explorer
#>
$ErrorActionPreference = 'Stop'

$verbs = @(
    'shell\TranscodeFfmpegResume',
    'shell\TranscodeFfmpegResumeSbs',
    'shell\PrepareV360FisheyeFragAvs',
    'shell\TranscodeV360FragAvsSegments',
    'shell\TranscodeV360FisheyePipeline',
    'shell\TranscodeFFmpegPotPlayer'
)

$sourceMediaExtensions = @(
    '.mp4', '.mkv', '.mov', '.m4v', '.avi', '.wmv', '.ts', '.m2ts', '.webm'
)
foreach ($ext in (@('.avs') + $sourceMediaExtensions)) {
    foreach ($base in @(
        "HKCU:\Software\Classes\$ext",
        "HKCU:\Software\Classes\SystemFileAssociations\$ext"
    )) {
        foreach ($verb in $verbs) {
            $shellKey = Join-Path $base $verb
            if (Test-Path -LiteralPath $shellKey) {
                Remove-Item -LiteralPath $shellKey -Recurse -Force
                Write-Host "Removed: $shellKey"
            } else {
                Write-Host "Not present (skipped): $shellKey"
            }
        }
    }
}

Write-Host ""
Write-Host 'Done. If Explorer still shows the old command, restart it:'
Write-Host '  Stop-Process -Name explorer -Force; Start-Process explorer'
