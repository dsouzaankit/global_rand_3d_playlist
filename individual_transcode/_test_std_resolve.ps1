. (Join-Path $PSScriptRoot 'Resolve-FisheyePlaylistMedia.ps1')
$orig = 'F:\f1_media\test_fisheye_batch\0h824lixwwrb57q95armg_720p_ap.mp4'
$r = Resolve-StandardizedMediaPath -MediaFullPath $orig
Write-Host "clicked:  $orig"
Write-Host "resolved: $r"
if ($r -like '*\standardized\*') { exit 0 } else { exit 1 }
