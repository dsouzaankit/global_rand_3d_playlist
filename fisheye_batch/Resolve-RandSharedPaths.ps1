#Requires -Version 5.1
# Shared path helpers. Scripts live on P: (F:\all_scripts hub retired; same as 3d_playlist_local).

function Get-RandEditSourceRoot {
    return 'P:\all_scripts\global_rand_3d_playlist'
}

function Get-RandTranscodeSyncSource {
    # Canonical transcode scripts (edit copy on P:)
    return 'P:\all_scripts\3d_playlist_local'
}

function Get-RandSharedAutoHotkeySource {
    foreach ($path in @(
        'P:\all_scripts\AutoHotkey'
    )) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            return [System.IO.Path]::GetFullPath($path)
        }
    }
    $fallback = Join-Path (Get-RandTranscodeSyncSource) 'AutoHotkey'
    if (Test-Path -LiteralPath $fallback -PathType Container) {
        return [System.IO.Path]::GetFullPath($fallback)
    }
    return $null
}

function Resolve-RandCompanionFolder {
    param(
        [string] $ProjectRoot,
        [string] $Preferred = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($Preferred) -and (Test-Path -LiteralPath $Preferred -PathType Container)) {
        return [System.IO.Path]::GetFullPath($Preferred)
    }
    $local = Join-Path $ProjectRoot 'AutoHotkey'
    if (Test-Path -LiteralPath $local -PathType Container) {
        return [System.IO.Path]::GetFullPath($local)
    }
    return Get-RandSharedAutoHotkeySource
}
