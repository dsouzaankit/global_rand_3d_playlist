#Requires -Version 5.1
# Shared PotPlayer DPL gate + playlist resume helpers (orchestrator + fisheye batch).

function Invoke-SafeNativeCommand {
    param(
        [scriptblock] $Command,
        [int[]] $SuccessExitCodes = @(0)
    )
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    try { $prevNative = $PSNativeCommandUseErrorActionPreference } catch { }
    try {
        $ErrorActionPreference = 'Continue'
        try { $PSNativeCommandUseErrorActionPreference = $false } catch { }
        & $Command
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) {
            try { $PSNativeCommandUseErrorActionPreference = $prevNative } catch { }
        }
    }
    return @{
        ExitCode = $exitCode
        Ok = ($SuccessExitCodes -contains $exitCode)
    }
}

function Invoke-SafeRobocopySync {
    param(
        [string] $Source,
        [string] $Destination,
        [string[]] $ExtraArgs = @('/E', '/XF', '*.log', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Warning "Robocopy skipped (source missing): $Source"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($Destination)
    }
    $result = Invoke-SafeNativeCommand -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -Command {
        robocopy.exe $Source $Destination @ExtraArgs | Out-Null
    }
    if ($result.Ok) {
        Write-Host "Robocopy synced (exit $($result.ExitCode)): $Source -> $Destination"
        return $true
    }
    Write-Warning "Robocopy failed (exit $($result.ExitCode)): $Source -> $Destination"
    return $false
}

function Resolve-BatchScriptPath {
    param(
        [string] $LocalPath,
        [string] $SyncSourceRoot,
        [string] $RelativePath
    )
    if (-not [string]::IsNullOrWhiteSpace($LocalPath) -and (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($LocalPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($SyncSourceRoot) -and -not [string]::IsNullOrWhiteSpace($RelativePath)) {
        $fallback = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($SyncSourceRoot, $RelativePath))
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            Write-Warning "Using sync-source script (local copy missing): $fallback"
            return $fallback
        }
    }
    return $null
}

function Get-FullPathOrNull {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $null
    }
}

function Resolve-M3uMediaEntry {
    param(
        [string] $PlaylistDir,
        [string] $Entry
    )
    $e = $Entry.Trim()
    if ($e.Length -gt 0 -and [int][char]$e[0] -eq 0xFEFF) {
        $e = $e.Substring(1).TrimStart()
    }
    if ($e -eq '') { return $null }
    if ($e.StartsWith('file:///', [StringComparison]::OrdinalIgnoreCase)) {
        $e = [Uri]::UnescapeDataString($e.Substring(8)).Replace('/', [System.IO.Path]::AltDirectorySeparatorChar)
        $e = $e.Replace([System.IO.Path]::AltDirectorySeparatorChar, [System.IO.Path]::DirectorySeparatorChar)
    }
    if ($e -match '^(?i)(https?|ftp)://') {
        return $null
    }
    try {
        if ([System.IO.Path]::IsPathRooted($e)) {
            return [System.IO.Path]::GetFullPath($e)
        }
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PlaylistDir, $e))
    } catch {
        return $null
    }
}

function Read-DplPlaybackState {
    param([string] $DplPath)
    if (-not (Test-Path -LiteralPath $DplPath -PathType Leaf)) { return $null }
    $lines = Get-Content -LiteralPath $DplPath -ErrorAction SilentlyContinue
    $playname = $null
    $playtimeMs = $null
    foreach ($line in $lines) {
        if ($null -eq $playname) {
            $mName = [regex]::Match($line, '^\s*playname\s*=\s*(.*?)\s*$')
            if ($mName.Success) {
                $val = $mName.Groups[1].Value.Trim()
                if ($val -ne '') { $playname = $val }
            }
        }
        if ($null -eq $playtimeMs) {
            $mTime = [regex]::Match($line, '^\s*playtime\s*=\s*(.*?)\s*$')
            if ($mTime.Success) {
                $raw = $mTime.Groups[1].Value.Trim()
                if ($raw -match '^\d+$') {
                    try { $playtimeMs = [int64]$raw } catch { $playtimeMs = $null }
                }
            }
        }
        if ($null -ne $playname -and $null -ne $playtimeMs) { break }
    }
    if ($null -eq $playname -and $null -eq $playtimeMs) { return $null }
    return @{
        PlayName = $playname
        PlayTimeMs = $playtimeMs
    }
}

function Read-AnchorPathFromSidecar {
    param([string] $SidecarPath)
    if (-not (Test-Path -LiteralPath $SidecarPath)) { return $null }
    $line = @(Get-Content -LiteralPath $SidecarPath -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    $t = [string]$line[0].Trim()
    if ($t -eq '') { return $null }
    try {
        return [System.IO.Path]::GetFullPath($t)
    } catch {
        return $null
    }
}

function Write-TranscodeProgressSidecar {
    param(
        [string] $SidecarPath,
        [string] $CompletedFullPath
    )
    $dir = [System.IO.Path]::GetDirectoryName($SidecarPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    Set-Content -LiteralPath $SidecarPath -Value ([System.IO.Path]::GetFullPath($CompletedFullPath)) -Encoding utf8
}

function Test-PlaylistEntryMatchesResumeAnchor {
    param(
        [string] $PlaylistEntryFullPath,
        [string] $AnchorFullPath
    )
    if ([string]::IsNullOrWhiteSpace($PlaylistEntryFullPath) -or [string]::IsNullOrWhiteSpace($AnchorFullPath)) {
        return $false
    }
    $p = Get-FullPathOrNull -Path $PlaylistEntryFullPath
    $a = Get-FullPathOrNull -Path $AnchorFullPath
    if ($null -eq $p -or $null -eq $a) { return $false }
    $entryLeaf = [System.IO.Path]::GetFileName($p)
    $anchorLeaf = [System.IO.Path]::GetFileName($a)
    if ($entryLeaf.Equals($anchorLeaf, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($anchorLeaf.Length -gt 4 -and $anchorLeaf.EndsWith('.avs', [StringComparison]::OrdinalIgnoreCase)) {
        $withoutAvs = $anchorLeaf.Substring(0, $anchorLeaf.Length - 4)
        if ($entryLeaf.Equals($withoutAvs, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-M3uOrderRotatedAfterPath {
    param(
        [string[]] $OrderedPaths,
        [string] $AfterFullPath
    )
    if ($null -eq $OrderedPaths -or $OrderedPaths.Count -eq 0) { return [string[]]@() }
    if ([string]::IsNullOrWhiteSpace($AfterFullPath)) { return [string[]]$OrderedPaths }
    $idx = -1
    for ($i = 0; $i -lt $OrderedPaths.Count; $i++) {
        if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $OrderedPaths[$i] -AnchorFullPath $AfterFullPath) {
            $idx = $i
            break
        }
    }
    if ($idx -lt 0) { return [string[]]$OrderedPaths }
    $n = $OrderedPaths.Count
    $rot = New-Object System.Collections.Generic.List[string]
    for ($j = $idx + 1; $j -lt $n; $j++) {
        [void]$rot.Add($OrderedPaths[$j])
    }
    for ($j = 0; $j -le $idx; $j++) {
        [void]$rot.Add($OrderedPaths[$j])
    }
    return [string[]]$rot.ToArray()
}

function Get-M3uOrderRotatedAtPath {
    param(
        [string[]] $OrderedPaths,
        [string] $AnchorFullPath
    )
    if ($null -eq $OrderedPaths -or $OrderedPaths.Count -eq 0) { return [string[]]@() }
    if ([string]::IsNullOrWhiteSpace($AnchorFullPath)) { return [string[]]$OrderedPaths }
    $idx = -1
    for ($i = 0; $i -lt $OrderedPaths.Count; $i++) {
        if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $OrderedPaths[$i] -AnchorFullPath $AnchorFullPath) {
            $idx = $i
            break
        }
    }
    if ($idx -lt 0) { return [string[]]$OrderedPaths }
    if ($idx -eq 0) { return [string[]]$OrderedPaths }
    return [string[]]@($OrderedPaths[$idx..($OrderedPaths.Count - 1)] + $OrderedPaths[0..($idx - 1)])
}

function Read-M3uOrderedFullPaths {
    param([string] $M3uPath)
    if (-not (Test-Path -LiteralPath $M3uPath -PathType Leaf)) { return @() }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $M3uPath -ErrorAction SilentlyContinue)) {
        $t = [string]$line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $full = Get-FullPathOrNull -Path $t
        if (-not [string]::IsNullOrWhiteSpace($full)) {
            [void]$paths.Add($full)
        }
    }
    return @($paths.ToArray())
}

function Test-MediaPathListSequenceEqual {
    param(
        [string[]] $Left,
        [string[]] $Right
    )
    $a = @($Left | ForEach-Object { Get-FullPathOrNull -Path $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $b = @($Right | ForEach-Object { Get-FullPathOrNull -Path $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -ne $b[$i]) { return $false }
    }
    return $true
}

function Read-DplPotPlayerHeaderFields {
    param([string] $DplPath)
    if (-not (Test-Path -LiteralPath $DplPath -PathType Leaf)) { return $null }
    $playname = $null
    $playtimeMs = $null
    $topIndex = $null
    foreach ($line in @(Get-Content -LiteralPath $DplPath -ErrorAction SilentlyContinue)) {
        if ($null -eq $playname) {
            $mName = [regex]::Match($line, '^\s*playname\s*=\s*(.*?)\s*$')
            if ($mName.Success) {
                $val = $mName.Groups[1].Value.Trim()
                if ($val -ne '') { $playname = $val }
            }
        }
        if ($null -eq $playtimeMs) {
            $mTime = [regex]::Match($line, '^\s*playtime\s*=\s*(.*?)\s*$')
            if ($mTime.Success) {
                $raw = $mTime.Groups[1].Value.Trim()
                if ($raw -match '^\d+$') {
                    try { $playtimeMs = [int64]$raw } catch { $playtimeMs = $null }
                }
            }
        }
        if ($null -eq $topIndex) {
            $mTop = [regex]::Match($line, '^\s*topindex\s*=\s*(\d+)\s*$')
            if ($mTop.Success) {
                try { $topIndex = [int]$mTop.Groups[1].Value } catch { $topIndex = $null }
            }
        }
    }
    if ($null -eq $playname -and $null -eq $playtimeMs -and $null -eq $topIndex) { return $null }
    return @{
        PlayName = $playname
        PlayTimeMs = $playtimeMs
        TopIndex = $topIndex
    }
}

function Test-DplPlayNameInMediaList {
    param(
        [string] $PlayName,
        [string[]] $MediaFullPaths,
        [string] $PlaylistDir
    )
    if ([string]::IsNullOrWhiteSpace($PlayName)) { return $false }
    $resolved = Resolve-M3uMediaEntry -PlaylistDir $PlaylistDir -Entry $PlayName
    $resolvedFull = Get-FullPathOrNull -Path $resolved
    if ([string]::IsNullOrWhiteSpace($resolvedFull)) { return $false }
    foreach ($mediaPath in $MediaFullPaths) {
        if (Test-PlaylistEntryMatchesResumeAnchor -PlaylistEntryFullPath $mediaPath -AnchorFullPath $resolvedFull) {
            return $true
        }
    }
    return $false
}

function Write-BatchPotPlayerPlaylists {
    # Rebuilds fisheye_batch.m3u + _potplayer.dpl. Preserves prior playname/playtime/topindex when the new
    # path list matches the existing m3u (order-sensitive). If playname no longer resolves to a list entry,
    # playback fields reset even though the list is unchanged. List add/remove/reorder always resets playback.
    param(
        [string[]] $MediaFullPaths,
        [string] $PlaylistDir,
        [string] $M3uFileName = 'fisheye_batch.m3u',
        [string] $DplStem = 'fisheye_batch'
    )
    if ($null -eq $MediaFullPaths -or $MediaFullPaths.Count -eq 0) {
        throw 'Write-BatchPotPlayerPlaylists: no media paths'
    }
    if (-not (Test-Path -LiteralPath $PlaylistDir -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($PlaylistDir)
    }
    $playlistDir = [System.IO.Path]::GetFullPath($PlaylistDir)
    $m3uPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($playlistDir, $M3uFileName))
    $dplPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($playlistDir, "${DplStem}_potplayer.dpl"))

    $newPaths = @($MediaFullPaths | ForEach-Object { [System.IO.Path]::GetFullPath($_) })
    $priorPaths = @(Read-M3uOrderedFullPaths -M3uPath $m3uPath)
    $listUnchanged = ($priorPaths.Count -gt 0) -and (Test-MediaPathListSequenceEqual -Left $priorPaths -Right $newPaths)

    $playNameLine = ''
    $topIndexLine = 'topindex=0'
    $playTimeLine = $null
    $preservedPlayback = $false
    if ($listUnchanged) {
        $priorHeader = Read-DplPotPlayerHeaderFields -DplPath $dplPath
        if ($null -ne $priorHeader) {
            $keepPlayback = $false
            if (-not [string]::IsNullOrWhiteSpace($priorHeader.PlayName)) {
                if (Test-DplPlayNameInMediaList -PlayName $priorHeader.PlayName -MediaFullPaths $newPaths -PlaylistDir $playlistDir) {
                    $playNameLine = "playname=$($priorHeader.PlayName)"
                    $keepPlayback = $true
                }
            }
            if ($keepPlayback) {
                if ($null -ne $priorHeader.TopIndex -and $priorHeader.TopIndex -ge 0) {
                    $topIndexLine = "topindex=$($priorHeader.TopIndex)"
                }
                if ($null -ne $priorHeader.PlayTimeMs -and $priorHeader.PlayTimeMs -ge 0) {
                    $playTimeLine = "playtime=$($priorHeader.PlayTimeMs)"
                }
                $preservedPlayback = $true
                Write-Host "Fisheye batch playlist unchanged; preserved DPL playname/playtime (topindex from prior DPL)."
            } else {
                Write-Host 'Fisheye batch playlist unchanged; prior DPL playname not in list - resetting playname/playtime.'
            }
        }
    } else {
        if ($priorPaths.Count -gt 0) {
            Write-Host 'Fisheye batch playlist changed; resetting DPL playname/playtime.'
        }
    }

    $m3uLines = New-Object System.Collections.Generic.List[string]
    [void]$m3uLines.Add('#EXTM3U')
    foreach ($p in $newPaths) {
        [void]$m3uLines.Add($p)
    }
    Set-Content -LiteralPath $m3uPath -Value ($m3uLines -join "`r`n") -Encoding utf8

    $dplLines = New-Object System.Collections.Generic.List[string]
    [void]$dplLines.Add('DAUMPLAYLIST')
    if ($preservedPlayback -and -not [string]::IsNullOrWhiteSpace($playNameLine)) {
        [void]$dplLines.Add($playNameLine)
    } else {
        [void]$dplLines.Add('playname=')
    }
    [void]$dplLines.Add($topIndexLine)
    [void]$dplLines.Add('saveplaypos=1')
    if (-not [string]::IsNullOrWhiteSpace($playTimeLine)) {
        [void]$dplLines.Add($playTimeLine)
    }
    for ($idx = 0; $idx -lt $newPaths.Count; $idx++) {
        $full = $newPaths[$idx]
        $title = [System.IO.Path]::GetFileName($full)
        $n = $idx + 1
        [void]$dplLines.Add("${n}*file*${full}")
        [void]$dplLines.Add("${n}*title*${title}")
    }
    Set-Content -LiteralPath $dplPath -Value ($dplLines -join "`r`n") -Encoding utf8

    return @{
        M3uPath = $m3uPath
        DplPath = $dplPath
        SidecarPath = "$dplPath.transcode_queue_last"
        PlaylistDir = $playlistDir
        PlaylistUnchanged = $listUnchanged
        PreservedDplPlayback = $preservedPlayback
    }
}

function Get-BatchAdjustedDplSeekMs {
    param(
        [Nullable[int64]] $PlayTimeMs,
        [int64] $BackoffMs = 30000
    )
    if ($null -eq $PlayTimeMs -or $PlayTimeMs -lt 0) { return $null }
    $adj = [int64]$PlayTimeMs - [int64]$BackoffMs
    if ($adj -lt 0) { return 0 }
    return $adj
}

function Get-BatchFfprobeExePath {
    $candidates = @(
        'C:\Program Files\StreamTo3D\tools\FFmpeg\ffmpeg-8.0.1-essentials_build\bin\ffprobe.exe',
        'C:\Program Files\ffmpeg\bin\ffprobe.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    return $null
}

function Get-BatchMediaDurationSeconds {
    param([string] $MediaFullPath)
    if ([string]::IsNullOrWhiteSpace($MediaFullPath) -or -not (Test-Path -LiteralPath $MediaFullPath -PathType Leaf)) {
        return $null
    }
    $ffprobeExe = Get-BatchFfprobeExePath
    if ([string]::IsNullOrWhiteSpace($ffprobeExe)) { return $null }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $raw = & $ffprobeExe -v error -show_entries format=duration `
            -of default=noprint_wrappers=1:nokey=1 -- $MediaFullPath 2>$null
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq 'N/A') { return $null }
    $n = 0.0
    if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $null
    }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -le 0) { return $null }
    return $n
}

function Limit-BatchSeekMsToMediaDuration {
    param(
        [int64] $SeekMs,
        [string] $MediaFullPath,
        [double] $EdgeSec = 5.0
    )
    if ($SeekMs -le 0) { return $SeekMs }
    $durSec = Get-BatchMediaDurationSeconds -MediaFullPath $MediaFullPath
    if ($null -eq $durSec) { return $SeekMs }
    $capMs = [int64][Math]::Floor([Math]::Max(0.0, $durSec - $EdgeSec) * 1000.0)
    if ($SeekMs -gt $capMs) {
        Write-Warning ("DPL seek {0} ms exceeds source duration {1}s; clamping pass-2 start to {2} ms." -f `
            $SeekMs, [math]::Round($durSec, 2), $capMs)
        return $capMs
    }
    return $SeekMs
}

function Resolve-BatchPotPlayerInitialSeekMs {
    param(
        [string] $DplPath,
        [string] $MediaFullPath,
        [string] $PlaylistDir
    )
    $state = Read-DplPlaybackStateWithRetry -DplPath $DplPath
    if ($null -eq $state -or $null -eq $state.PlayTimeMs -or $state.PlayTimeMs -lt 0) {
        Write-Warning 'PotPlayer DPL playtime missing; pass-1 mezzanine and pass-2 DLNA start at 0s.'
        return 0L
    }
    if (-not [string]::IsNullOrWhiteSpace($state.PlayName)) {
        $fromDpl = Resolve-M3uMediaEntry -PlaylistDir $PlaylistDir -Entry $state.PlayName
        if (-not [string]::IsNullOrWhiteSpace($fromDpl)) {
            $dplMedia = Get-FullPathOrNull -Path $fromDpl
            $want = Get-FullPathOrNull -Path $MediaFullPath
            if (-not [string]::IsNullOrWhiteSpace($dplMedia) -and -not [string]::IsNullOrWhiteSpace($want) `
                -and $dplMedia -ne $want) {
                Write-Host "DPL playtime is for $dplMedia; this clip starts pass-1/pass-2 at 0s."
                return 0L
            }
        }
    }
    $adj = Get-BatchAdjustedDplSeekMs -PlayTimeMs $state.PlayTimeMs
    if ($null -eq $adj) { return 0L }
    $adj = Limit-BatchSeekMsToMediaDuration -SeekMs $adj -MediaFullPath $MediaFullPath
    Write-Host "Pass-1 mezzanine seek from PotPlayer DPL playtime: raw=$($state.PlayTimeMs) ms adjusted=$adj ms (~$([math]::Round($adj / 60000.0, 2)) min)"
    return [int64]$adj
}

function Resolve-BatchPlaylistAnchor {
    param(
        [string] $DplPath,
        [string] $SidecarPath,
        [string] $PlaylistDir,
        [string] $ResumeAfter = ''
    )
    $anchorPath = ''
    $anchorMode = ''
    if (-not [string]::IsNullOrWhiteSpace($ResumeAfter)) {
        $anchorPath = Get-FullPathOrNull -Path $ResumeAfter
        if (-not [string]::IsNullOrWhiteSpace($anchorPath)) {
            $anchorMode = 'after'
            Write-Host "Batch resume anchor (parameter): $anchorPath"
        }
        return @{ AnchorPath = $anchorPath; AnchorMode = $anchorMode }
    }
    $dplState = Read-DplPlaybackStateWithRetry -DplPath $DplPath
    if ($null -ne $dplState -and -not [string]::IsNullOrWhiteSpace($dplState.PlayName)) {
        $fromDpl = Resolve-M3uMediaEntry -PlaylistDir $PlaylistDir -Entry $dplState.PlayName
        if (-not [string]::IsNullOrWhiteSpace($fromDpl)) {
            $anchorPath = Get-FullPathOrNull -Path $fromDpl
            if (-not [string]::IsNullOrWhiteSpace($anchorPath)) {
                $anchorMode = 'at'
                Write-Host "Batch resume anchor (PotPlayer DPL playname): $anchorPath"
            }
        } else {
            Write-Warning "PotPlayer playname could not be resolved (starting from top): $($dplState.PlayName)"
        }
    }
    if ([string]::IsNullOrWhiteSpace($anchorPath)) {
        $fromSidecar = Read-AnchorPathFromSidecar -SidecarPath $SidecarPath
        if (-not [string]::IsNullOrWhiteSpace($fromSidecar)) {
            $anchorPath = Get-FullPathOrNull -Path $fromSidecar
            if (-not [string]::IsNullOrWhiteSpace($anchorPath)) {
                $anchorMode = 'after'
                Write-Host "Batch resume anchor ($SidecarPath): $anchorPath"
            }
        }
    }
    return @{ AnchorPath = $anchorPath; AnchorMode = $anchorMode }
}

function Read-DplPlaybackStateWithRetry {
    param(
        [string] $DplPath,
        [int] $Attempts = 5,
        [int] $DelayMs = 600
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        $state = Read-DplPlaybackState -DplPath $DplPath
        if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.PlayName)) {
            return $state
        }
        if ($i -lt $Attempts) {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return Read-DplPlaybackState -DplPath $DplPath
}

function Get-BatchOrderRotatedForAnchor {
    param(
        [string[]] $OrderedPaths,
        [string] $AnchorPath,
        [string] $AnchorMode
    )
    if ([string]::IsNullOrWhiteSpace($AnchorPath)) {
        return [string[]]$OrderedPaths
    }
    if ($AnchorMode -eq 'at') {
        $rot = [string[]](Get-M3uOrderRotatedAtPath -OrderedPaths $OrderedPaths -AnchorFullPath $AnchorPath)
        Write-Host 'Batch queue rotated to start at PotPlayer-selected clip.'
        return $rot
    }
    $rot = [string[]](Get-M3uOrderRotatedAfterPath -OrderedPaths $OrderedPaths -AfterFullPath $AnchorPath)
    Write-Host 'Batch queue rotated to start after last completed clip.'
    return $rot
}

function Resolve-PotPlayerExecutable {
    param([string] $ExplicitPath = '')
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($ExplicitPath)
        }
        Write-Warning "PotPlayerExe not found: $ExplicitPath"
        return $null
    }
    foreach ($exeName in @('PotPlayerMini64.exe', 'PotPlayerMini.exe', 'PotPlayer.exe')) {
        try {
            $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
            if ($cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source) -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
                return $cmd.Source
            }
        } catch { }
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $dirs = @(
        [System.IO.Path]::Combine($env:ProgramFiles, 'DAUM', 'PotPlayer'),
        [System.IO.Path]::Combine($env:ProgramFiles, 'PotPlayer')
    )
    if (-not [string]::IsNullOrWhiteSpace($pf86)) {
        $dirs += @(
            [System.IO.Path]::Combine($pf86, 'DAUM', 'PotPlayer'),
            [System.IO.Path]::Combine($pf86, 'PotPlayer')
        )
    }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($exeName in @('PotPlayerMini64.exe', 'PotPlayerMini.exe', 'PotPlayer.exe')) {
            $candidate = Join-Path $dir $exeName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }
    return $null
}

function Request-PotPlayerMainWindowFullscreenKick {
    param(
        [int] $ProcessId,
        [int] $TimeoutSec = 18
    )
    if ($ProcessId -le 0) { return }
    if (-not ('BatchPotWin32' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class BatchPotWin32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
        } catch { }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $hwnd = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($null -eq $proc) {
                Start-Sleep -Milliseconds 300
                continue
            }
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                $hwnd = $proc.MainWindowHandle
                break
            }
        } catch { }
        Start-Sleep -Milliseconds 300
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Warning 'PotPlayer: main window not ready in time; Alt+Enter fullscreen kick skipped.'
        return
    }
    try {
        if ('BatchPotWin32' -as [type]) {
            [void][BatchPotWin32]::ShowWindow($hwnd, 9)
            Start-Sleep -Milliseconds 150
            [void][BatchPotWin32]::SetForegroundWindow($hwnd)
            Start-Sleep -Milliseconds 250
        }
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.SendKeys('%({ENTER})')
        Write-Host 'PotPlayer: Alt+Enter sent for fullscreen (best effort).'
    } catch {
        Write-Warning "PotPlayer fullscreen kick failed: $_"
    }
}

function Get-BatchPotPlayerRunningIds {
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($name in @('PotPlayerMini64', 'PotPlayerMini', 'PotPlayer')) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($null -ne $p -and $p.Id -gt 0) {
                [void]$ids.Add($p.Id)
            }
        }
    }
    # Prevent PowerShell from unwrapping a 1-element HashSet into a bare [int].
    Write-Output -NoEnumerate $ids
}

function ConvertTo-BatchPotPlayerIdSet {
    param($Ids)
    if ($null -eq $Ids) {
        return [System.Collections.Generic.HashSet[int]]::new()
    }
    if ($Ids -is [System.Collections.Generic.HashSet[int]]) {
        Write-Output -NoEnumerate $Ids
        return
    }
    # ,$hash / pipeline wrap: Object[] { HashSet } or single unwrapped int
    if ($Ids -is [System.Array] -and $Ids.Length -eq 1) {
        ConvertTo-BatchPotPlayerIdSet -Ids $Ids.GetValue(0)
        return
    }
    $set = [System.Collections.Generic.HashSet[int]]::new()
    if ($Ids -is [int] -or $Ids -is [long] -or $Ids -is [uint32]) {
        [void]$set.Add([int]$Ids)
        Write-Output -NoEnumerate $set
        return
    }
    foreach ($rawId in @($Ids)) {
        if ($null -eq $rawId) { continue }
        if ($rawId -is [System.Collections.Generic.HashSet[int]]) {
            foreach ($inner in $rawId) { [void]$set.Add([int]$inner) }
            continue
        }
        try { [void]$set.Add([int]$rawId) } catch { }
    }
    Write-Output -NoEnumerate $set
}

function Test-BatchProcessRunning {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return $false }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Invoke-SilentTaskkillTree {
    param([int] $PidToKill)
    if ($PidToKill -le 0) { return }
    if (-not (Test-BatchProcessRunning -ProcessId $PidToKill)) { return }
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) "batch_taskkill_$PidToKill.err"
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) "batch_taskkill_$PidToKill.out"
    $prevEap = $ErrorActionPreference
    $prevNative = $null
    try { $prevNative = $PSNativeCommandUseErrorActionPreference } catch { }
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        try { $PSNativeCommandUseErrorActionPreference = $false } catch { }
        Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', "$PidToKill", '/T', '/F') `
            -Wait -WindowStyle Hidden -RedirectStandardError $errFile -RedirectStandardOutput $outFile | Out-Null
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) {
            try { $PSNativeCommandUseErrorActionPreference = $prevNative } catch { }
        }
        Remove-Item -LiteralPath $errFile, $outFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PotPlayerGateErrorText {
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return 'Unknown PotPlayer gate error.' }
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        if ($null -ne $ErrorRecord.Exception -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.Message)) {
            return $ErrorRecord.Exception.Message
        }
        if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ToString())) {
            return $ErrorRecord.ToString()
        }
    }
    return [string]$ErrorRecord
}

function Test-BatchPotPlayerAnyRunning {
    param(
        [int] $StarterPid = 0,
        $BaselineIds = $null
    )
    try {
        $session = Get-BatchPotPlayerSessionRunningIds -StarterPid $StarterPid -BaselineIds $BaselineIds
        return ($session.Count -gt 0)
    } catch {
        return $false
    }
}

function Get-BatchPotPlayerSessionRunningIds {
    param(
        [int] $StarterPid = 0,
        $BaselineIds = $null
    )
    $baseline = ConvertTo-BatchPotPlayerIdSet -Ids $BaselineIds
    $session = [System.Collections.Generic.HashSet[int]]::new()
    $current = ConvertTo-BatchPotPlayerIdSet -Ids (Get-BatchPotPlayerRunningIds)
    if ($StarterPid -gt 0 -and $current.Contains([int]$StarterPid)) {
        [void]$session.Add([int]$StarterPid)
    }
    foreach ($id in $current) {
        if (-not $baseline.Contains([int]$id)) {
            [void]$session.Add([int]$id)
        }
    }
    Write-Output -NoEnumerate $session
}

$script:BatchConsoleKeyPollNativeLoaded = $false

function Initialize-BatchConsoleKeyPollNative {
    if ($script:BatchConsoleKeyPollNativeLoaded) { return $true }
    try {
        if (-not ([System.Management.Automation.PSTypeName]'BatchConsoleKeyPollNative').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class BatchConsoleKeyPollNative
{
    private const int STD_INPUT_HANDLE = -10;
    private const ushort KEY_EVENT = 0x0001;
    private const ushort VK_RETURN = 0x0D;

    [StructLayout(LayoutKind.Sequential)]
    private struct InputRecord
    {
        public ushort EventType;
        public ushort Padding;
        public KeyEventRecord KeyEvent;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyEventRecord
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char UnicodeChar;
        public uint dwControlKeyState;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint count);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PeekConsoleInput(IntPtr h, [Out] InputRecord[] buffer, uint length, out uint read);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadConsoleInput(IntPtr h, [Out] InputRecord[] buffer, uint length, out uint read);

    private static bool TryFindEnterKeyDown(InputRecord[] buffer, uint read, out int index)
    {
        index = -1;
        for (int i = 0; i < read; i++)
        {
            InputRecord rec = buffer[i];
            if (rec.EventType == KEY_EVENT && rec.KeyEvent.bKeyDown && rec.KeyEvent.wVirtualKeyCode == VK_RETURN)
            {
                index = i;
                return true;
            }
        }
        return false;
    }

    public static bool TryConsumeEnterKeyPress()
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;

        uint count;
        if (!GetNumberOfConsoleInputEvents(handle, out count) || count == 0) return false;

        InputRecord[] buffer = new InputRecord[count];
        uint read;
        if (!PeekConsoleInput(handle, buffer, count, out read) || read == 0) return false;

        int enterIndex;
        if (!TryFindEnterKeyDown(buffer, read, out enterIndex)) return false;

        InputRecord[] consume = new InputRecord[enterIndex + 1];
        uint consumed;
        ReadConsoleInput(handle, consume, (uint)(enterIndex + 1), out consumed);
        return true;
    }

    public static bool IsEnterKeyPending()
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;

        uint count;
        if (!GetNumberOfConsoleInputEvents(handle, out count) || count == 0) return false;

        InputRecord[] buffer = new InputRecord[count];
        uint read;
        if (!PeekConsoleInput(handle, buffer, count, out read) || read == 0) return false;

        int enterIndex;
        return TryFindEnterKeyDown(buffer, read, out enterIndex);
    }
}
'@ -ErrorAction Stop
        }
        $script:BatchConsoleKeyPollNativeLoaded = $true
        return $true
    } catch {
        return $false
    }
}

function Initialize-BatchConsoleCancelNative {
    return (Initialize-BatchConsoleKeyPollNative)
}

$script:BatchConsoleCancelNativeLoaded = $false

function Clear-BatchPendingConsoleKeys {
    try {
        while ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
        }
    } catch {
        try {
            while ($Host.UI.RawUI.KeyAvailable) {
                [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            }
        } catch { }
    }
}

function Test-BatchConsoleEnterKeyPending {
    if (Initialize-BatchConsoleKeyPollNative) {
        try {
            return [BatchConsoleKeyPollNative]::IsEnterKeyPending()
        } catch { }
    }
    return $false
}

function Test-BatchConsoleCancelKeyPressed {
    # Enter only - native consume; never ReadKey here (would swallow Space/other keys).
    if (Initialize-BatchConsoleKeyPollNative) {
        try {
            return [BatchConsoleKeyPollNative]::TryConsumeEnterKeyPress()
        } catch { }
    }
    return $false
}

function Invoke-BatchConsoleControlPoll {
    param([ref] $CancelledByEnter)
    if (Initialize-BatchConsoleKeyPollNative) {
        try {
            if ([BatchConsoleKeyPollNative]::TryConsumeEnterKeyPress()) {
                if ($null -ne $CancelledByEnter) { $CancelledByEnter.Value = $true }
                return 'Enter'
            }
        } catch { }
    }
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Spacebar) {
                if (Get-Command Toggle-LeafFfmpegExportSuspend -ErrorAction SilentlyContinue) {
                    [void](Toggle-LeafFfmpegExportSuspend)
                }
                return 'Space'
            }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                if ($null -ne $CancelledByEnter) { $CancelledByEnter.Value = $true }
                return 'Enter'
            }
        }
    } catch { }
    try {
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.VirtualKeyCode -eq 32) {
                if (Get-Command Toggle-LeafFfmpegExportSuspend -ErrorAction SilentlyContinue) {
                    [void](Toggle-LeafFfmpegExportSuspend)
                }
                return 'Space'
            }
            if ($key.VirtualKeyCode -eq 13 -or $key.Character -eq [char]13) {
                if ($null -ne $CancelledByEnter) { $CancelledByEnter.Value = $true }
                return 'Enter'
            }
        }
    } catch { }
    return $null
}

function Format-GateProcessArgumentLine {
    param([string[]] $Arguments)
    return ($Arguments | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s":+]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
}

function Wait-BatchPotPlayerUserFinished {
    param(
        [int] $StarterPid,
        $BaselineIds = $null,
        [int] $StartupTimeoutSec = 180
    )
    $baseline = ConvertTo-BatchPotPlayerIdSet -Ids $BaselineIds
    Write-Host 'Waiting for PotPlayer to close (exit PotPlayer when start-clip selection is done)...'
    Write-Host '  Exit PotPlayer: File > Exit (or triple-left-click if TripleL companion is running).'
    if ($baseline.Count -gt 0) {
        Write-Host ("  Ignoring {0} pre-existing PotPlayer pid(s): {1}" -f `
            $baseline.Count, ((@($baseline) | Sort-Object) -join ', '))
    }
    $startupDeadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    $sessionSeen = $false
    $lastStatusAt = [datetime]::MinValue
    while ($true) {
        $sessionIds = ConvertTo-BatchPotPlayerIdSet -Ids (
            Get-BatchPotPlayerSessionRunningIds -StarterPid $StarterPid -BaselineIds $baseline
        )
        $running = $sessionIds.Count -gt 0
        if (-not $sessionSeen) {
            if ($running) {
                $sessionSeen = $true
                Write-Host ("PotPlayer session detected (pid {0}); waiting for you to exit PotPlayer..." -f `
                    ((@($sessionIds) | Sort-Object) -join ', '))
            } elseif ((Get-Date) -gt $startupDeadline) {
                throw "PotPlayer did not start within ${StartupTimeoutSec}s; start-clip gate aborted."
            }
        } elseif (-not $running) {
            Write-Host 'PotPlayer closed; continuing batch.'
            return
        } elseif (((Get-Date) - $lastStatusAt).TotalSeconds -ge 30) {
            $lastStatusAt = Get-Date
            Write-Host ("Still waiting for gate PotPlayer to exit (pid {0})..." -f `
                ((@($sessionIds) | Sort-Object) -join ', '))
        }
        Start-Sleep -Milliseconds 400
    }
}

$script:BatchCompanionJobHandle = [IntPtr]::Zero
$script:BatchCompanionRootPids = [System.Collections.Generic.List[int]]::new()
$script:BatchCompanionsStopped = $false

function Ensure-BatchCompanionJobNativeType {
    if ('BatchCompanionJobNative' -as [type]) { return }
    if ('OrchestratorCompanionJobNative' -as [type]) { return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BatchCompanionJobNative {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool SetInformationJobObject(IntPtr hJob, int jobObjectInfoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInformation, uint cbJobObjectInformationLength);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool CloseHandle(IntPtr hObject);
  public const int JobObjectExtendedLimitInformation = 9;
  public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public Int64 PerProcessUserTimeLimit;
    public Int64 PerJobUserTimeLimit;
    public UInt32 LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public UInt32 ActiveProcessLimit;
    public UIntPtr Affinity;
    public UInt32 PriorityClass;
    public UInt32 SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS {
    public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }
  public static bool TryCreateKillOnCloseJob(out IntPtr jobHandle) {
    jobHandle = IntPtr.Zero;
    IntPtr h = CreateJobObject(IntPtr.Zero, null);
    if (h == IntPtr.Zero) return false;
    var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    uint cb = (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    if (!SetInformationJobObject(h, JobObjectExtendedLimitInformation, ref info, cb)) {
      CloseHandle(h);
      return false;
    }
    jobHandle = h;
    return true;
  }
}
'@
    } catch {
        Write-Warning "Batch companion job API unavailable: $_"
    }
}

function Initialize-BatchCompanionKillOnCloseJob {
    Ensure-BatchCompanionJobNativeType
    if ($script:BatchCompanionJobHandle -ne [IntPtr]::Zero) { return }
    $nativeType = if ('BatchCompanionJobNative' -as [type]) { 'BatchCompanionJobNative' } elseif ('OrchestratorCompanionJobNative' -as [type]) { 'OrchestratorCompanionJobNative' } else { $null }
    if ($null -eq $nativeType) { return }
    [IntPtr]$jh = [IntPtr]::Zero
    if ($nativeType -eq 'BatchCompanionJobNative') {
        $ok = [BatchCompanionJobNative]::TryCreateKillOnCloseJob([ref]$jh)
    } else {
        $ok = [OrchestratorCompanionJobNative]::TryCreateKillOnCloseJob([ref]$jh)
    }
    if (-not $ok -or $jh -eq [IntPtr]::Zero) {
        Write-Warning 'Could not create Kill-On-Close job for companions.'
        return
    }
    $script:BatchCompanionJobHandle = $jh
}

function Register-BatchCompanionProcessInKillJob {
    param([System.Diagnostics.Process] $Process)
    if ($null -eq $Process -or $Process.Id -le 0) { return }
    if ($script:BatchCompanionJobHandle -eq [IntPtr]::Zero) { return }
    $nativeType = if ('BatchCompanionJobNative' -as [type]) { 'BatchCompanionJobNative' } else { 'OrchestratorCompanionJobNative' }
    if ($null -eq ($nativeType -as [type])) { return }
    try {
        if ($Process.HasExited) { return }
        $Process.Refresh()
        if ($Process.HasExited) { return }
        $h = $Process.Handle
        $ok = if ($nativeType -eq 'BatchCompanionJobNative') {
            [BatchCompanionJobNative]::AssignProcessToJobObject($script:BatchCompanionJobHandle, $h)
        } else {
            [OrchestratorCompanionJobNative]::AssignProcessToJobObject($script:BatchCompanionJobHandle, $h)
        }
        if (-not $ok) {
            Write-Verbose "AssignProcessToJobObject skipped for companion PID $($Process.Id)."
        }
    } catch { }
}

function Close-BatchCompanionKillOnCloseJob {
    if ($script:BatchCompanionJobHandle -eq [IntPtr]::Zero) { return }
    try {
        if ('BatchCompanionJobNative' -as [type]) {
            [void][BatchCompanionJobNative]::CloseHandle($script:BatchCompanionJobHandle)
        } elseif ('OrchestratorCompanionJobNative' -as [type]) {
            [void][OrchestratorCompanionJobNative]::CloseHandle($script:BatchCompanionJobHandle)
        }
    } catch { }
    $script:BatchCompanionJobHandle = [IntPtr]::Zero
}

function Stop-BatchCompanionProcessTree {
    param([int] $PidToKill)
    Invoke-SilentTaskkillTree -PidToKill $PidToKill
}

function Stop-BatchCompanionBinaries {
    if ($script:BatchCompanionsStopped) { return }
    $script:BatchCompanionsStopped = $true
    try {
        if ($null -ne $script:BatchCompanionRootPids -and $script:BatchCompanionRootPids.Count -gt 0) {
            Write-Host "Stopping $($script:BatchCompanionRootPids.Count) companion process tree(s)..."
            foreach ($cid in @($script:BatchCompanionRootPids | Sort-Object -Unique -Descending)) {
                Stop-BatchCompanionProcessTree -PidToKill $cid
            }
        }
    } finally {
        if ($null -ne $script:BatchCompanionRootPids) {
            [void]$script:BatchCompanionRootPids.Clear()
        }
        Close-BatchCompanionKillOnCloseJob
    }
}

function Resolve-AutoHotkeyExecutable {
    param([string] $CompanionFolder = '')
    foreach ($exeName in @('AutoHotkey64.exe', 'AutoHotkey32.exe', 'AutoHotkey.exe')) {
        try {
            $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
            if ($cmd -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
                return $cmd.Source
            }
        } catch { }
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($CompanionFolder)) {
        foreach ($exeName in @('AutoHotkey64.exe', 'AutoHotkey32.exe', 'AutoHotkey.exe')) {
            [void]$candidates.Add([System.IO.Path]::Combine($CompanionFolder, $exeName))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        [void]$candidates.Add([System.IO.Path]::Combine($localAppData, 'Programs', 'AutoHotkey', 'v2', 'AutoHotkey64.exe'))
        [void]$candidates.Add([System.IO.Path]::Combine($localAppData, 'Programs', 'AutoHotkey', 'v2', 'AutoHotkey32.exe'))
        [void]$candidates.Add([System.IO.Path]::Combine($localAppData, 'Programs', 'AutoHotkey', 'AutoHotkey64.exe'))
    }
    [void]$candidates.Add([System.IO.Path]::Combine($env:ProgramFiles, 'AutoHotkey', 'v2', 'AutoHotkey64.exe'))
    [void]$candidates.Add([System.IO.Path]::Combine($env:ProgramFiles, 'AutoHotkey', 'v2', 'AutoHotkey32.exe'))
    [void]$candidates.Add([System.IO.Path]::Combine($env:ProgramFiles, 'AutoHotkey', 'AutoHotkey64.exe'))
    [void]$candidates.Add([System.IO.Path]::Combine($env:ProgramFiles, 'AutoHotkey', 'AutoHotkey.exe'))
    if (-not [string]::IsNullOrWhiteSpace($pf86)) {
        [void]$candidates.Add([System.IO.Path]::Combine($pf86, 'AutoHotkey', 'v2', 'AutoHotkey64.exe'))
        [void]$candidates.Add([System.IO.Path]::Combine($pf86, 'AutoHotkey', 'AutoHotkey.exe'))
    }
    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or $seen.ContainsKey($candidate)) { continue }
        $seen[$candidate] = $true
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Resolve-CompanionBinaryFolder {
    param(
        [string] $Preferred = '',
        [string] $PlaylistLocal = ''
    )
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        try { [void]$candidates.Add([System.IO.Path]::GetFullPath($Preferred)) } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($PlaylistLocal)) {
        [void]$candidates.Add([System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PlaylistLocal, 'AutoHotkey')))
    }
    foreach ($c in @(
        'P:\all_scripts\AutoHotkey',
        'D:\all_scripts\AutoHotkey'
    )) {
        [void]$candidates.Add($c)
    }
    $seen = @{}
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c) -or $seen.ContainsKey($c)) { continue }
        $seen[$c] = $true
        if (Test-Path -LiteralPath $c -PathType Container) {
            return $c
        }
    }
    return $null
}

function Register-BatchCompanionLaunch {
    param([System.Diagnostics.Process] $Process)
    if ($null -eq $Process -or $Process.Id -le 0) { return $false }
    Register-BatchCompanionProcessInKillJob -Process $Process
    [void]$script:BatchCompanionRootPids.Add($Process.Id)
    return $true
}

function Start-BatchCompanionBinaries {
    param(
        [string] $FolderPath,
        [switch] $Skip,
        [switch] $DryRun
    )
    $script:BatchCompanionsStopped = $false
    if ($script:BatchCompanionRootPids) {
        [void]$script:BatchCompanionRootPids.Clear()
    } else {
        $script:BatchCompanionRootPids = [System.Collections.Generic.List[int]]::new()
    }
    if ($Skip) {
        Write-Host 'Skipping companion binaries (-SkipCompanionBinaries).'
        return $false
    }
    if ($DryRun) {
        Write-Host 'DryRun: skipping companion binary launch.'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        Write-Warning "Companion binary folder missing; AutoHotkey helpers not started: $FolderPath"
        return $false
    }
    $folder = [System.IO.Path]::GetFullPath($FolderPath)
    $runtimeExeNames = @('AutoHotkey64.exe', 'AutoHotkey32.exe', 'AutoHotkey.exe')
    $companionExes = @(Get-ChildItem -LiteralPath $folder -File -Filter '*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $runtimeExeNames -notcontains $_.Name } |
        Sort-Object { $_.Name })
    if ($companionExes.Count -eq 0) {
        Write-Warning "No companion *.exe in: $folder (copy/compile PotPlayer-TripleLButton-Close.exe beside batch or set -CompanionBinaryFolder)"
        return $false
    }
    Write-Host "Starting $($companionExes.Count) companion executable(s) from: $folder"
    Initialize-BatchCompanionKillOnCloseJob
    $started = 0
    foreach ($exeFile in $companionExes) {
        try {
            Write-Host "  -> $($exeFile.Name)"
            $pp = Start-Process -FilePath $exeFile.FullName -WorkingDirectory $folder -PassThru -WindowStyle Normal
            if (Register-BatchCompanionLaunch -Process $pp) { $started++ }
        } catch {
            Write-Warning "Could not start companion '$($exeFile.Name)': $($_.Exception.Message)"
        }
    }
    if ($started -eq 0) {
        Write-Warning 'No companion processes started.'
        return $false
    }
    Write-Host "Companion launch complete ($started running)."
    return $true
}

function Invoke-BatchPotPlayerDplGate {
    param(
        [string] $DplFullPath,
        [switch] $DryRun,
        [switch] $Skip,
        [string] $PotPlayerExePath = '',
        [string] $CompanionBinaryFolder = 'P:\all_scripts\AutoHotkey',
        [switch] $SkipCompanionBinaries
    )
    if ($Skip) {
        Write-Host 'Skipping PotPlayer DPL gate (-SkipPotPlayer).'
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($DplFullPath) -or -not (Test-Path -LiteralPath $DplFullPath -PathType Leaf)) {
        Write-Warning "PotPlayer DPL gate skipped (DPL not found): $DplFullPath"
        return $true
    }
    if ($DryRun) {
        Write-Host "DryRun: PotPlayer DPL gate would launch: $DplFullPath"
        return $true
    }
    $exe = Resolve-PotPlayerExecutable -ExplicitPath $PotPlayerExePath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        throw 'PotPlayer executable not found; cannot run start-clip gate (install PotPlayer or pass -PotPlayerExe).'
    }

    $companionFolder = Resolve-CompanionBinaryFolder -Preferred $CompanionBinaryFolder `
        -PlaylistLocal ([System.IO.Path]::GetDirectoryName($DplFullPath))
    if (-not $SkipCompanionBinaries.IsPresent) {
        if ([string]::IsNullOrWhiteSpace($companionFolder)) {
            Write-Warning 'AutoHotkey companion folder not found; exit PotPlayer with File > Exit during the gate.'
        } else {
            $started = Start-BatchCompanionBinaries -FolderPath $companionFolder
            if (-not $started) {
                Write-Warning 'AutoHotkey companions did not start; exit PotPlayer with File > Exit during the gate.'
            } elseif ($started) {
                Start-Sleep -Seconds 2
            }
        }
    }

    Write-Host "PotPlayer DPL gate: starting `"$exe`" with DPL:"
    Write-Host "  $DplFullPath"
    Write-Host 'Browse to your starting clip, then exit PotPlayer - batch continues after PotPlayer closes.'
    $baselineIds = ConvertTo-BatchPotPlayerIdSet -Ids (Get-BatchPotPlayerRunningIds)
    if ($baselineIds.Count -gt 0) {
        Write-Warning ("Pre-existing PotPlayer still running (pid {0}); gate wait will ignore it and only track this launch." -f `
            ((@($baselineIds) | Sort-Object) -join ', '))
    }
    try {
        $pp = Start-Process -FilePath $exe -ArgumentList (Format-GateProcessArgumentLine @($DplFullPath)) -PassThru -ErrorAction Stop
    } catch {
        throw "PotPlayer Start-Process failed: $($_.Exception.Message)"
    }
    if ($null -eq $pp) {
        throw 'Start-Process did not return a PotPlayer process object.'
    }
    $starterPid = 0
    try { $starterPid = [int]$pp.Id } catch { $starterPid = 0 }
    Request-PotPlayerMainWindowFullscreenKick -ProcessId $starterPid
    Wait-BatchPotPlayerUserFinished -StarterPid $starterPid -BaselineIds $baselineIds
    Write-Host 'Sleeping 3 seconds for DPL file (playname/playtime) to update...'
    Start-Sleep -Seconds 3
    Write-Host 'PotPlayer gate complete; continuing batch queue.'
    return $true
}
