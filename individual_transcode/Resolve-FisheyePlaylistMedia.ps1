#Requires -Version 5.1
# Shared fisheye context-menu helpers: batch queue follow-up (standardized path in Resolve-StandardizedMediaPath.ps1).

$resolveStdMediaScript = Join-Path $PSScriptRoot 'Resolve-StandardizedMediaPath.ps1'
if (Test-Path -LiteralPath $resolveStdMediaScript -PathType Leaf) {
    . $resolveStdMediaScript
}

function Find-FisheyeBatchBundle {
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaFullPath
    )
    $cur = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($MediaFullPath))
    for ($depth = 0; $depth -lt 12; $depth++) {
        $playlistLocal = Join-Path $cur '3d_playlist_local'
        $batchScriptRoot = Join-Path $cur 'run_batch_fisheye_v360.ps1'
        $batchScriptSynced = Join-Path $playlistLocal 'run_batch_fisheye_v360.ps1'
        $batchScript = $null
        if (Test-Path -LiteralPath $batchScriptSynced -PathType Leaf) {
            $batchScript = $batchScriptSynced
        } elseif (Test-Path -LiteralPath $batchScriptRoot -PathType Leaf) {
            $batchScript = $batchScriptRoot
        }
        if ((Test-Path -LiteralPath $playlistLocal -PathType Container) -and $null -ne $batchScript) {
            return @{
                MediaRoot     = [System.IO.Path]::GetFullPath($cur)
                BatchScript   = [System.IO.Path]::GetFullPath($batchScript)
                PlaylistLocal = [System.IO.Path]::GetFullPath($playlistLocal)
                MediaListFile = Join-Path $cur 'media_files.txt'
                DplPath       = Join-Path $playlistLocal 'fisheye_batch_potplayer.dpl'
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return $null
}

function Test-Skip3dFormattedMediaName {
    <#
    .SYNOPSIS
      True when the leaf name (or path) already looks 3D-formatted (as-is segment-copy candidate).
    .NOTES
      Matches StreamTo3D "3D File Name Pattern" plus Skybox / common SBS-fisheye tokens
      (e.g. source_sbs.mp4, Full_SBS, LR_180_FISHEYE, VR180). Batches remux these with -c copy
      instead of flat/fisheye re-encode (see Run-SegmentCopyAsIs.ps1 / Get-AsIsDlnaSegmentSuffix).
    #>
    param(
        [string] $FileName = '',
        [string] $FullPath = ''
    )
    $leaf = $FileName
    if ([string]::IsNullOrWhiteSpace($leaf) -and -not [string]::IsNullOrWhiteSpace($FullPath)) {
        try { $leaf = [System.IO.Path]::GetFileName($FullPath) } catch { $leaf = '' }
    }
    if (-not [string]::IsNullOrWhiteSpace($leaf)) {
        # StreamTo3D GUI pattern + Skybox tokens + _sbs / fisheye / VR180 style tags + DLNA export leaves.
        if ($leaf -match '(?i)((_3D)|(\.SBS\.)|(\.TB\.)|(\.HSBS\.)|(\.HTB\.)|(\.3DA\.)|(Full_?SBS)|(Half_?SBS)|(LR_?180_?FISHEYE)|(3d_op_)|(^|[^A-Za-z0-9])(FISHEYE|VR180|VR190|F180|SBS|HSBS|HTB|3DA)([^A-Za-z0-9]|$))') {
            return $true
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FullPath)) {
        # Folder tokens that mark already-converted trees (not 3d_playlist_local itself).
        if ($FullPath -match '(?i)([\\/]_?fullsbs_?[\\/]|[\\/]_?halfsbs_?[\\/]|[\\/](?:sbs|fisheye|vr180)[\\/])') {
            return $true
        }
    }
    return $false
}

function Get-AsIsDlnaSegmentSuffix {
    <#
    .SYNOPSIS
      Skybox segment suffix for already-3D as-is remux: always LR_180
      (3d_op_%02d_LR_180.mkv) so as-is is distinct from flat Full_SBS / fisheye LR_180_FISHEYE.
    #>
    param(
        [string] $FileName = '',
        [string] $FullPath = ''
    )
    return 'LR_180'
}

function Test-FisheyeSkipStreamTo3DMediaName {
    param(
        [string] $FileName = '',
        [string] $FullPath = ''
    )
    return (Test-Skip3dFormattedMediaName -FileName $FileName -FullPath $FullPath)
}

function Get-FisheyeBatchEligibleMediaPaths {
    param([string[]] $MediaLines)
    $eligible = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $MediaLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $mediaFull = [System.IO.Path]::GetFullPath($line.Trim())
        if (Get-Command Resolve-StandardizedMediaPath -ErrorAction SilentlyContinue) {
            $mediaFull = Resolve-StandardizedMediaPath -MediaFullPath $mediaFull
        }
        # Already-3D stays eligible; batches route to Run-SegmentCopyAsIs.
        if (-not (Test-Path -LiteralPath $mediaFull -PathType Leaf)) { continue }
        [void]$eligible.Add($mediaFull)
    }
    return [string[]]$eligible.ToArray()
}

function Test-FisheyeMediaPathMatchesAnchor {
    param(
        [string] $PlaylistEntryFullPath,
        [string] $AnchorFullPath
    )
    if ([string]::IsNullOrWhiteSpace($PlaylistEntryFullPath) -or [string]::IsNullOrWhiteSpace($AnchorFullPath)) {
        return $false
    }
    $entryLeaf = [System.IO.Path]::GetFileName([System.IO.Path]::GetFullPath($PlaylistEntryFullPath))
    $anchorLeaf = [System.IO.Path]::GetFileName([System.IO.Path]::GetFullPath($AnchorFullPath))
    return $entryLeaf.Equals($anchorLeaf, [StringComparison]::OrdinalIgnoreCase)
}

function Format-FisheyeHandoffArgumentLine {
    param([string[]] $Arguments)
    return ($Arguments | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s":+]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '
}

function Test-FisheyeBatchHasRemainingAfterClip {
    param(
        [string[]] $OrderedPaths,
        [string] $CompletedFullPath
    )
    # Hand off when 2+ eligible clips: batch -ResumeAfter rotates after the anchor (last clip wraps to first).
    if ($null -eq $OrderedPaths -or $OrderedPaths.Count -le 1) { return $false }
    if ([string]::IsNullOrWhiteSpace($CompletedFullPath)) { return $false }

    for ($i = 0; $i -lt $OrderedPaths.Count; $i++) {
        if (Test-FisheyeMediaPathMatchesAnchor -PlaylistEntryFullPath $OrderedPaths[$i] -AnchorFullPath $CompletedFullPath) {
            return $true
        }
    }
    return $false
}

function Write-FisheyeContextHandoffLog {
    param(
        [string] $MediaRoot,
        [string] $Message
    )
    if ([string]::IsNullOrWhiteSpace($MediaRoot)) { return }
    $logPath = Join-Path $MediaRoot 'fisheye_context_handoff.log'
    try {
        Add-Content -LiteralPath $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding utf8
    } catch {
        Write-Warning "Could not write $logPath : $_"
    }
}

function Start-FisheyeBatchQueueFollowUp {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CompletedMediaFullPath,
        [Parameter(Mandatory = $true)]
        [string] $ScriptDir
    )
    $completedFull = [System.IO.Path]::GetFullPath($CompletedMediaFullPath)
    $bundle = Find-FisheyeBatchBundle -MediaFullPath $completedFull
    if ($null -eq $bundle) {
        $msg = 'No run_batch_fisheye_v360.ps1 beside 3d_playlist_local; skipping queue follow-up.'
        Write-Host $msg
        return
    }
    if (-not (Test-Path -LiteralPath $bundle.MediaListFile -PathType Leaf)) {
        $msg = "media_files.txt not found ($($bundle.MediaListFile)); skipping queue follow-up."
        Write-Warning $msg
        Write-FisheyeContextHandoffLog -MediaRoot $bundle.MediaRoot -Message $msg
        return
    }

    $gateScript = Join-Path $ScriptDir 'Invoke-BatchPotPlayerGate.ps1'
    if (-not (Test-Path -LiteralPath $gateScript -PathType Leaf)) {
        $msg = 'Invoke-BatchPotPlayerGate.ps1 not found; skipping queue follow-up.'
        Write-Warning $msg
        Write-FisheyeContextHandoffLog -MediaRoot $bundle.MediaRoot -Message $msg
        return
    }
    . $gateScript

    $linesRaw = @(Get-Content -LiteralPath $bundle.MediaListFile -Encoding UTF8 `
        | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $eligible = @(Get-FisheyeBatchEligibleMediaPaths -MediaLines $linesRaw)
    if ($eligible.Count -eq 0) {
        $msg = 'No eligible media in media_files.txt; skipping queue follow-up.'
        Write-Warning $msg
        Write-FisheyeContextHandoffLog -MediaRoot $bundle.MediaRoot -Message $msg
        return
    }
    if (-not (Test-FisheyeBatchHasRemainingAfterClip -OrderedPaths $eligible -CompletedFullPath $completedFull)) {
        $msg = if ($eligible.Count -le 1) {
            'Only one eligible clip in media_files.txt; skipping queue follow-up.'
        } else {
            'Completed clip not found in media_files.txt; skipping queue follow-up.'
        }
        Write-Host $msg
        Write-FisheyeContextHandoffLog -MediaRoot $bundle.MediaRoot -Message "$msg completed=$completedFull"
        return
    }

    $sidecarPath = "$($bundle.DplPath).transcode_queue_last"
    try {
        Write-TranscodeProgressSidecar -SidecarPath $sidecarPath -CompletedFullPath $completedFull
    } catch {
        Write-Warning "Could not write batch sidecar ($sidecarPath): $_"
    }

    Write-Host ''
    Write-Host 'Starting fisheye batch for remaining queue...'
    Write-Host "  Completed: $completedFull"
    Write-Host "  Batch:     $($bundle.BatchScript)"
    $handoffMsg = "Launching batch -ResumeAfter $completedFull -SkipPotPlayer -SkipCompanionBinaries -SkipPotPlayerSeek"
    Write-FisheyeContextHandoffLog -MediaRoot $bundle.MediaRoot -Message $handoffMsg
    try {
        $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
            (Get-Command pwsh -ErrorAction Stop).Source
        } else {
            (Get-Command powershell -ErrorAction Stop).Source
        }
        $argList = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bundle.BatchScript,
            '-ResumeAfter', $completedFull,
            '-SkipPotPlayer',
            '-SkipCompanionBinaries',
            '-SkipPotPlayerSeek'
        )
        $proc = Start-Process -FilePath $shell `
            -ArgumentList (Format-FisheyeHandoffArgumentLine $argList) `
            -WorkingDirectory $bundle.MediaRoot `
            -WindowStyle Normal -PassThru
        if ($null -ne $proc) {
            Write-Host "  Follow-up batch pid=$($proc.Id) (see fisheye_context_handoff.log in media root)"
            Write-FisheyeContextHandoffLog -MediaRoot $bundle.MediaRoot -Message "Started pid=$($proc.Id)"
        }
    } catch {
        Write-Warning "Fisheye batch follow-up failed: $_"
        Write-FisheyeContextHandoffLog -MediaRoot $bundle.MediaRoot -Message "FAILED: $_"
    }
}
