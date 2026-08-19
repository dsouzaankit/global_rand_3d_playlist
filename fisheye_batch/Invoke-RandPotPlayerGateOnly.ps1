#Requires -Version 5.1
# Open PotPlayer on fisheye_batch_potplayer.dpl built from 2d_media_paths.txt (no transcode).

param(
    [string] $MediaListFile = '',
    [string] $PotPlayerExe = '',
    [string] $CompanionBinaryFolder = '',
    [switch] $SkipCompanionBinaries
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($MediaListFile)) {
    $MediaListFile = Join-Path $projectRoot '2d_media_paths.txt'
}
. (Join-Path $PSScriptRoot 'Resolve-RandSharedPaths.ps1')
$gateScript = Join-Path $projectRoot 'individual_transcode\Invoke-BatchPotPlayerGate.ps1'
$syncSource = Get-RandTranscodeSyncSource
if (-not (Test-Path -LiteralPath $gateScript)) {
    $srcGate = Join-Path $syncSource 'individual_transcode\Invoke-BatchPotPlayerGate.ps1'
    if (Test-Path -LiteralPath $srcGate) {
        $dest = Join-Path $projectRoot 'individual_transcode'
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        Copy-Item -LiteralPath $srcGate -Destination $gateScript -Force
    }
}
if (-not (Test-Path -LiteralPath $gateScript)) {
    throw "Invoke-BatchPotPlayerGate.ps1 not found. Run run_batch_fisheye_rand.ps1 once to sync scripts."
}

. (Join-Path $PSScriptRoot 'Resolve-Rand2dMediaList.ps1')
. $gateScript

$list = Read-Rand2dMediaPathLines -ListFile $MediaListFile
if ($list.Paths.Count -eq 0) { throw "No paths in $MediaListFile" }

$bundle = Write-BatchPotPlayerPlaylists -MediaFullPaths $list.Paths -PlaylistDir $projectRoot `
    -M3uFileName 'fisheye_batch.m3u' -DplStem 'fisheye_batch'
Write-Host "Built: $($bundle.M3uPath)"
Write-Host "       $($bundle.DplPath)"
Write-Host 'Triple-left-click in PotPlayer video area (or File > Exit) when start clip is chosen.'

$companionFolder = Resolve-RandCompanionFolder -ProjectRoot $projectRoot -Preferred $CompanionBinaryFolder
if (-not $SkipCompanionBinaries.IsPresent -and -not [string]::IsNullOrWhiteSpace($companionFolder)) {
    . (Join-Path $PSScriptRoot 'Start-RandPotPlayerCompanions.ps1')
    [void](Start-RandPotPlayerCompanions -CompanionFolder $companionFolder)
}

Invoke-BatchPotPlayerDplGate -DplFullPath $bundle.DplPath -PotPlayerExePath $PotPlayerExe `
    -CompanionBinaryFolder $companionFolder -SkipCompanionBinaries
