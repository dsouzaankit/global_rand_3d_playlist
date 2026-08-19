#Requires -Version 5.1
# Prefer 3d_playlist_local\standardized\{filename} when present (selective_stdize.ps1 / generate_media_listings_lcl.py).

function Resolve-StandardizedMediaPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaFullPath
    )
    $full = [System.IO.Path]::GetFullPath($MediaFullPath)
    $fileName = [System.IO.Path]::GetFileName($full)
    if ([string]::IsNullOrWhiteSpace($fileName)) { return $full }

    $cur = [System.IO.Path]::GetDirectoryName($full)
    for ($depth = 0; $depth -lt 12; $depth++) {
        foreach ($stdPath in @(
            (Join-Path (Join-Path $cur 'standardized') $fileName),
            (Join-Path (Join-Path (Join-Path $cur '3d_playlist_local') 'standardized') $fileName)
        )) {
            if (Test-Path -LiteralPath $stdPath -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($stdPath)
            }
        }
        if (Test-Path -LiteralPath (Join-Path $cur '3d_playlist_local') -PathType Container) {
            break
        }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return $full
}
