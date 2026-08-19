#Requires -Version 5.1
# Read 2d_media_paths.txt for fisheye/hybrid batch (paths may be offline pointers).

function Test-RandSkipStreamTo3DMediaName {
    <#
    .SYNOPSIS
      Alias for already-3D detect (as-is remux candidate). Kept name for callers; does not drop from list.
    #>
    param(
        [string] $FileName = '',
        [string] $FullPath = ''
    )
    if (Get-Command Test-Skip3dFormattedMediaName -ErrorAction SilentlyContinue) {
        return (Test-Skip3dFormattedMediaName -FileName $FileName -FullPath $FullPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($FileName) -and $FileName -match '(?i)((_3D)|(\.SBS\.)|(\.TB\.)|(\.HSBS\.)|(\.HTB\.)|(\.3DA\.)|(Full_?SBS)|(Half_?SBS)|(LR_?180_?FISHEYE)|(3d_op_)|(^|[^A-Za-z0-9])(FISHEYE|VR180|VR190|F180|SBS|HSBS|HTB|3DA)([^A-Za-z0-9]|$))') {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($FullPath) -and $FullPath -match '(?i)([\\/]_?fullsbs_?[\\/]|[\\/]_?halfsbs_?[\\/]|[\\/](?:sbs|fisheye|vr180)[\\/])') {
        return $true
    }
    return $false
}

function Read-Rand2dMediaPathLines {
    param(
        [string] $ListFile,
        [switch] $RequireExistingFile
    )
    if (-not (Test-Path -LiteralPath $ListFile -PathType Leaf)) {
        throw "2d media list not found: $ListFile"
    }
    $raw = @(Get-Content -LiteralPath $ListFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $eligible = [System.Collections.Generic.List[string]]::new()
    $missing = 0
    $asis3d = 0
    foreach ($line in $raw) {
        try {
            $mediaFull = [System.IO.Path]::GetFullPath($line)
        } catch {
            Write-Warning "Invalid path skipped: $line"
            continue
        }
        $baseName = [System.IO.Path]::GetFileName($mediaFull)
        # Already-3D stays in queue; batch routes to Run-SegmentCopyAsIs.
        if (Test-RandSkipStreamTo3DMediaName -FileName $baseName -FullPath $mediaFull) {
            $asis3d++
        }
        if ($RequireExistingFile.IsPresent) {
            if (-not (Test-Path -LiteralPath $mediaFull -PathType Leaf)) {
                $missing++
                continue
            }
        }
        [void]$eligible.Add($mediaFull)
    }
    return @{
        RawCount = $raw.Count
        Paths = [string[]]$eligible.ToArray()
        MissingSkipped = $missing
        AsIs3dFormatted = $asis3d
        # Back-compat alias (no longer means dropped from list)
        Skipped3dFormatted = 0
    }
}

function Get-Rand2dBatchEligibleMediaPaths {
    param(
        [string] $ListFile,
        [switch] $RequireExistingFile
    )
    $result = Read-Rand2dMediaPathLines -ListFile $ListFile -RequireExistingFile:$RequireExistingFile
    return $result.Paths
}
