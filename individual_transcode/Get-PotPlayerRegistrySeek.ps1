#Requires -Version 5.1
# Dot-source only. PotPlayer RememberFiles resume shared by Run-TranscodeFfmpeg.ps1 and Run-V360PrepareFisheye.ps1.

function Normalize-MatchPath {
    param([string] $P)
    if ([string]::IsNullOrWhiteSpace($P)) { return '' }
    try {
        return [System.IO.Path]::GetFullPath($P).ToLowerInvariant()
    } catch {
        return $P.Trim().ToLowerInvariant()
    }
}

function ConvertFrom-RememberLine {
    param([object] $Data)
    if ($null -eq $Data) { return $null }
    [string] $s = $null
    if ($Data -is [byte[]]) {
        $b = [byte[]]$Data
        if ($b.Length -eq 0) { return $null }
        try {
            $s = [Text.Encoding]::Unicode.GetString($b).TrimEnd([char]0)
        } catch {
            $s = [Text.Encoding]::UTF8.GetString($b)
        }
    } else {
        $s = [string]$Data
    }
    $s = $s.Trim()
    if ($s -notmatch '^(\d+)=(.*)$') { return $null }
    return @{
        Ms   = [int64]$Matches[1]
        Path = $Matches[2].Trim().Trim('"')
    }
}

function Get-RememberEntries {
    $list = New-Object System.Collections.Generic.List[object]
    $rememberFilesRegistryPath = 'SOFTWARE\DAUM\PotPlayerMini64\RememberFiles'
    $reg = $null
    try {
        $reg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($rememberFilesRegistryPath)
        if (-not $reg) { return $list }

        foreach ($name in $reg.GetValueNames()) {
            if ($name -eq 'MRUList') { continue }
            $val = $reg.GetValue($name)
            $parsed = ConvertFrom-RememberLine $val
            if ($parsed) { [void]$list.Add($parsed) }
        }

        foreach ($skName in $reg.GetSubKeyNames()) {
            $sk = $reg.OpenSubKey($skName)
            if ($sk) {
                try {
                    $val = $sk.GetValue('', $null)
                    $parsed = ConvertFrom-RememberLine $val
                    if ($parsed) { [void]$list.Add($parsed) }
                } finally {
                    $sk.Dispose()
                }
            }
        }
    } finally {
        if ($reg) { $reg.Dispose() }
    }
    return $list
}

function Get-SeekMsForRememberedPath {
    param(
        [string] $TargetPath,
        [string[]] $AlternatePaths = @()
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return 0L }

    $pathCandidates = New-Object System.Collections.Generic.List[string]
    [void]$pathCandidates.Add([System.IO.Path]::GetFullPath($TargetPath))
    foreach ($alt in @($AlternatePaths)) {
        if ([string]::IsNullOrWhiteSpace($alt)) { continue }
        try {
            $fullAlt = [System.IO.Path]::GetFullPath($alt)
            if (-not $pathCandidates.Contains($fullAlt)) { [void]$pathCandidates.Add($fullAlt) }
        } catch { }
    }

    $entries = @(Get-RememberEntries)
    foreach ($candidate in $pathCandidates) {
        $want = Normalize-MatchPath $candidate
        $bestMs = 0L
        $bestLen = -1
        foreach ($e in $entries) {
            if ((Normalize-MatchPath $e.Path) -eq $want) {
                $len = $e.Path.Length
                if ($len -gt $bestLen) {
                    $bestLen = $len
                    $bestMs = $e.Ms
                }
            }
        }
        if ($bestMs -gt 0) { return [Math]::Max(0L, $bestMs) }
    }

    $leaf = [System.IO.Path]::GetFileName($TargetPath)
    if ([string]::IsNullOrWhiteSpace($leaf)) { return 0L }
    $filenameMs = 0L
    foreach ($e in $entries) {
        $entryLeaf = [System.IO.Path]::GetFileName($e.Path)
        if ($entryLeaf.Equals($leaf, [StringComparison]::OrdinalIgnoreCase) -and $e.Ms -gt $filenameMs) {
            $filenameMs = $e.Ms
        }
    }
    if ($filenameMs -gt 0) {
        Write-Host "PotPlayer RememberFiles matched by filename '$leaf' (registry path differs from transcode input)."
    }
    return [Math]::Max(0L, $filenameMs)
}

function Get-QuickSeekOverrideMs {
    [OutputType([Nullable[int64]])]
    param()

    Write-Host 'Quick seek override: press 0/1/2/3/4 within 5s for 0/10/15/30/45 min (or wait for registry resume).'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.KeyChar) {
                    '0' { return 0L }
                    '1' { return 10L * 60L * 1000L }
                    '2' { return 15L * 60L * 1000L }
                    '3' { return 30L * 60L * 1000L }
                    '4' { return 45L * 60L * 1000L }
                    default { return $null }
                }
            }
        } catch {
            return $null
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}
