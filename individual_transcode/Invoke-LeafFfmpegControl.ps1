#Requires -Version 5.1
# Leaf DLNA export ffmpeg (3d_op_*.mkv): NtSuspend/NtResume + Space toggle for wait loops.
$script:LeafFfmpegNtApiInitialized = $false
$script:LeafFfmpegExportSuspended = $false
$script:LeafFfmpegSuspendedPids = [System.Collections.Generic.List[int]]::new()
# Segment mux pattern: 3d_op_%02d_<SkyboxTokens>.mkv
# Skybox auto-detect keywords (filename or folder): https://skybox.xyz/support/How-to-Adjust-2D&3D&VR-Video-Formats
#   Flat Full SBS theater: Full_SBS / fullsbs (+ parent folder _fullsbs_)
#   Fisheye: LR (stereo) + 180 + FISHEYE (trial suffix LR_180_FISHEYE); also VR180/F180/SBS per docs.
# Keep unsuffixed + current + as-is LR_180 + legacy VR180 / VR180_SBS / VR190 so Space pause works across workflows.
$script:DlnaSegmentSuffixFlat = 'Full_SBS'
$script:DlnaSegmentSuffixFisheye = 'LR_180_FISHEYE'
$script:DlnaSegmentSuffixAsIs = 'LR_180'
$script:LeafFfmpegOutputLeaves = @(
    '3d_op_00.mkv', '3d_op_01.mkv', '3d_op_%02d.mkv',
    '3d_op_00_Full_SBS.mkv', '3d_op_01_Full_SBS.mkv', '3d_op_%02d_Full_SBS.mkv',
    '3d_op_00_LR_180_FISHEYE.mkv', '3d_op_01_LR_180_FISHEYE.mkv', '3d_op_%02d_LR_180_FISHEYE.mkv',
    '3d_op_00_LR_180.mkv', '3d_op_01_LR_180.mkv', '3d_op_%02d_LR_180.mkv',
    '3d_op_00_VR180.mkv', '3d_op_01_VR180.mkv', '3d_op_%02d_VR180.mkv',
    '3d_op_00_VR180_SBS.mkv', '3d_op_01_VR180_SBS.mkv', '3d_op_%02d_VR180_SBS.mkv',
    '3d_op_00_VR190.mkv', '3d_op_01_VR190.mkv', '3d_op_%02d_VR190.mkv'
)
# Minute segments: flat -> ...\flat\, fisheye -> ...\fisheye\, hybrid batch -> ...\hybrid\ (under this root).
# Preferred path is the Skybox web-client DLNA share folder (dummy subst, AppData store).
# Prefer M:; if M: is a real volume or someone else's subst, pick a free D-Z letter
# and warn to remap the folder in the Skybox PC client.
$script:DlnaSegmentRootShareParent = 'm1_media'
$script:DlnaSegmentRootShareParentLegacyNames = @('f1_media', 'k1_media')
$script:DlnaSegmentRootShareRelative = 'm1_media\3d_fullsbs_trans'
$script:DlnaSegmentRootDriveLetter = 'M'
$script:DlnaSegmentRootPreferred = ('{0}:\{1}' -f $script:DlnaSegmentRootDriveLetter, $script:DlnaSegmentRootShareRelative)
$script:DlnaSegmentRootDefault = $script:DlnaSegmentRootPreferred
$script:DlnaSegmentRootAppDataLeaf = '3d_playlist_local'
$script:DlnaSegmentRootSubstLeaf = 'm1_media_dlna_subst'
$script:DlnaSegmentRootSubstLeafLegacyNames = @('k1_media_dlna_subst', 'f1_media_dlna_subst', 'f1_media_F_subst')
$script:DlnaExportSegmentKeepCountDefault = 2
$script:DlnaSegmentRootEnsured = $false
$script:DlnaSegmentRootEnsureMode = ''
$script:DlnaWorkflowQuitCleanupDone = $false
# Quit hides media from DLNA/Skybox by renaming; startup restores. Manual Cleanup-DlnaSegmentRoot.ps1 deletes.
# Example: hybrid\3d_op_00_Full_SBS.mkv -> hybrid\<sha256(relpath)>.tmp (+ scrambled .dlna_obf_map.json).
$script:DlnaObfuscationMapLeaf = '.dlna_obf_map.json'
$script:DlnaObfuscationMapMagic = 'DLNAOBF1:'
# Local scramble key material only (hides plaintext paths from casual inspection; not strong crypto).
$script:DlnaObfuscationMapKeyMaterial = '3d_playlist_local.dlna_obf_map.v1'
$script:DlnaObfuscationTmpSuffix = '.tmp'
# Legacy rename forms (still restored if found).
$script:DlnaObfuscationPrefix = '_dlna_obf_'
$script:DlnaObfuscationSuffix = '.dlna_obf'
# Playable DLNA media plus AviSynth scripts under the share root (fisheye_temp\avs).
$script:DlnaMediaExtensions = @(
    '.mkv', '.mp4', '.m4v', '.mov', '.webm', '.ts', '.m2ts', '.mts',
    '.avi', '.wmv', '.mpg', '.mpeg', '.m2v', '.flv', '.3gp', '.ogv', '.ogg',
    '.avs'
)

function Get-DlnaSegmentRootAppDataFallback {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = $env:APPDATA
    }
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'APPDATA is not set; cannot resolve 3d_playlist_local DLNA fallback.'
    }
    return [System.IO.Path]::GetFullPath((Join-Path $appData $script:DlnaSegmentRootAppDataLeaf))
}

function Get-DlnaSegmentRootSubstMount {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = $env:APPDATA
    }
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'APPDATA is not set; cannot resolve dummy DLNA subst mount.'
    }
    $canonical = [System.IO.Path]::GetFullPath((Join-Path $appData $script:DlnaSegmentRootSubstLeaf))
    foreach ($legacyLeaf in @($script:DlnaSegmentRootSubstLeafLegacyNames)) {
        $legacy = [System.IO.Path]::GetFullPath((Join-Path $appData $legacyLeaf))
        if ((Test-Path -LiteralPath $legacy -PathType Container) -and
            -not (Test-Path -LiteralPath $canonical -PathType Container)) {
            try {
                Move-Item -LiteralPath $legacy -Destination $canonical -Force -ErrorAction Stop
            } catch {
                return $legacy
            }
        }
    }
    return $canonical
}

function Test-DlnaSegmentRootDrivePresent {
    param([string] $Letter = $script:DlnaSegmentRootDriveLetter)
    $root = ('{0}:\' -f $Letter.TrimEnd(':'))
    try {
        return [System.IO.Directory]::Exists($root)
    } catch {
        return $false
    }
}

function Get-SubstDriveMappings {
    $map = @{}
    $lines = @()
    try {
        $lines = @(& subst.exe 2>$null)
    } catch {
        return $map
    }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # subst lines look like: M:\: => C:\Users\...\m1_media_dlna_subst
        if ($line -match '^\s*([A-Za-z]):\\:\s*=>\s*(.+?)\s*$') {
            $letter = $Matches[1].ToUpperInvariant()
            $target = [System.IO.Path]::GetFullPath($Matches[2].Trim().Trim('"'))
            $map[$letter] = $target
        }
    }
    return $map
}

function Get-SubstDriveTarget {
    param([string] $Letter = $script:DlnaSegmentRootDriveLetter)
    $want = $Letter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $map = Get-SubstDriveMappings
    if ($map.ContainsKey($want)) {
        return $map[$want]
    }
    return $null
}

function Set-DlnaSegmentRootActiveLetter {
    param([Parameter(Mandatory = $true)][string] $Letter)
    $ch = $Letter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $script:DlnaSegmentRootDriveLetter = $ch
    $script:DlnaSegmentRootPreferred = ('{0}:\{1}' -f $ch, $script:DlnaSegmentRootShareRelative)
}

function Get-DlnaFreeDriveLetters {
    $occupied = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.Name.Length -ge 1) {
            [void]$occupied.Add($d.Name.Substring(0, 1))
        }
    }
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
        $n = [string]$_.Name
        if ($n.Length -eq 1) { [void]$occupied.Add($n) }
    }
    foreach ($letter in (Get-SubstDriveMappings).Keys) {
        [void]$occupied.Add($letter)
    }
    $free = [System.Collections.Generic.List[string]]::new()
    foreach ($code in 68..90) {
        $ch = [string][char]$code
        if (-not $occupied.Contains($ch) -and -not [System.IO.Directory]::Exists("${ch}:\")) {
            $free.Add($ch)
        }
    }
    return @($free)
}

function Write-DlnaSkyboxDriveConflictWarning {
    param(
        [Parameter(Mandatory = $true)][string] $PreferredLetter,
        [Parameter(Mandatory = $true)][string] $ActualLetter
    )
    $preferred = $PreferredLetter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $actual = $ActualLetter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $actualPath = ('{0}:\{1}' -f $actual, $script:DlnaSegmentRootShareRelative)
    Write-Warning ("Drive {0}: is in use. Dummy DLNA is {1} for this run." -f $preferred, $actualPath)
    Write-Warning ("If Skybox is running, the workflow will try to update Add folders to {0}. Otherwise add that path yourself." -f $actualPath)
}


# Skybox PC client: process + AirScreen share from P:\all_scripts\Skybox_vr_pc;
# 3d_fullsbs_trans mapping and workflow-started marker in Get-PlaylistSkybox.ps1.
$playlistSkybox = Join-Path $PSScriptRoot 'Get-PlaylistSkybox.ps1'
if (-not (Test-Path -LiteralPath $playlistSkybox -PathType Leaf)) {
    throw ("Get-PlaylistSkybox.ps1 not found: {0}" -f $playlistSkybox)
}
. $playlistSkybox

function Resolve-DlnaSegmentRootDriveLetter {
    param([Parameter(Mandatory = $true)][string] $SubstMount)
    $preferred = $script:DlnaSegmentRootDriveLetter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $mappings = Get-SubstDriveMappings
    $ourLetter = $null
    foreach ($letter in $mappings.Keys) {
        if ($mappings[$letter].Equals($SubstMount, [StringComparison]::OrdinalIgnoreCase)) {
            $ourLetter = $letter
            break
        }
    }
    $preferredTaken = $mappings.ContainsKey($preferred) -or (Test-DlnaSegmentRootDrivePresent -Letter $preferred)
    if (-not [string]::IsNullOrWhiteSpace($ourLetter)) {
        if ($ourLetter -eq $preferred) {
            return $preferred
        }
        if (-not $preferredTaken) {
            try { & subst.exe "${ourLetter}:" /d 2>&1 | Out-Null } catch { }
            Write-Host ("DLNA root: moved dummy subst {0}: -> preferred {1}:." -f $ourLetter, $preferred)
            return $preferred
        }
        Write-DlnaSkyboxDriveConflictWarning -PreferredLetter $preferred -ActualLetter $ourLetter
        return $ourLetter
    }
    if (-not $preferredTaken) {
        return $preferred
    }
    $free = @(Get-DlnaFreeDriveLetters)
    if ($free.Count -eq 0) {
        throw ("Drive {0}: is in use and no free D-Z letter is left for dummy DLNA subst -> {1}." -f `
            $preferred, $SubstMount)
    }
    $picked = [string]($free | Get-Random)
    Write-DlnaSkyboxDriveConflictWarning -PreferredLetter $preferred -ActualLetter $picked
    return $picked
}

function Ensure-DirectoryJunction {
    param(
        [Parameter(Mandatory = $true)][string] $LinkPath,
        [Parameter(Mandatory = $true)][string] $TargetPath
    )
    $linkFull = [System.IO.Path]::GetFullPath($LinkPath)
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($targetFull)
    }
    if (Test-Path -LiteralPath $linkFull) {
        $item = Get-Item -LiteralPath $linkFull -Force
        $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isReparse) {
            $existingTarget = $null
            try {
                if ($null -ne $item.Target -and $item.Target.Count -gt 0) {
                    $existingTarget = [System.IO.Path]::GetFullPath([string]$item.Target[0])
                }
            } catch { }
            if ([string]::IsNullOrWhiteSpace($existingTarget) -or
                -not $existingTarget.Equals($targetFull, [StringComparison]::OrdinalIgnoreCase)) {
                cmd.exe /c rmdir "$linkFull" | Out-Null
            } else {
                return $linkFull
            }
        } else {
            # Real directory already at link path - leave it (data usable for DLNA).
            return $linkFull
        }
    }
    $parent = [System.IO.Path]::GetDirectoryName($linkFull)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $mklink = cmd.exe /c mklink /J "$linkFull" "$targetFull" 2>&1
    if (-not (Test-Path -LiteralPath $linkFull)) {
        throw ("Failed to create junction {0} -> {1}: {2}" -f $linkFull, $targetFull, $mklink)
    }
    return $linkFull
}

function Remove-DlnaSegmentRootLegacyShareParents {
    <#
      After dummy letter moved F: / K: -> M:, subst mount was renamed to m1_media_dlna_subst
      but leftover f1_media\ / k1_media\ (+ old 3d_fullsbs_trans junction) can remain inside it.
      Media stay in %AppData%\3d_playlist_local; this only drops unused dummy parents.
    #>
    param([Parameter(Mandatory = $true)][string] $SubstMount)
    $mount = [System.IO.Path]::GetFullPath($SubstMount)
    foreach ($legacyParent in @($script:DlnaSegmentRootShareParentLegacyNames)) {
        if ([string]::Equals($legacyParent, $script:DlnaSegmentRootShareParent, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $legacyDir = Join-Path $mount $legacyParent
        if (-not (Test-Path -LiteralPath $legacyDir)) { continue }
        $legacyJunction = Join-Path $legacyDir '3d_fullsbs_trans'
        if (Test-Path -LiteralPath $legacyJunction) {
            try {
                $item = Get-Item -LiteralPath $legacyJunction -Force
                $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
                if ($isReparse) {
                    cmd.exe /c rmdir "$legacyJunction" | Out-Null
                }
            } catch { }
        }
        try {
            $left = @(Get-ChildItem -LiteralPath $legacyDir -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) {
                Remove-Item -LiteralPath $legacyDir -Force -ErrorAction Stop
                Write-Host ("DLNA root: removed leftover dummy parent {0}" -f $legacyDir)
            } else {
                Write-Warning ("DLNA root: leftover dummy parent still has files, left in place: {0}" -f $legacyDir)
            }
        } catch {
            Write-Warning ("DLNA root: could not remove leftover dummy parent {0}: {1}" -f $legacyDir, $_.Exception.Message)
        }
    }
}

function Initialize-DlnaSegmentRootTree {
    param([Parameter(Mandatory = $true)][string] $Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    [void][System.IO.Directory]::CreateDirectory($rootFull)
    foreach ($leaf in @('flat', 'fisheye', 'hybrid', 'fisheye_temp')) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $rootFull $leaf))
    }
    [void][System.IO.Directory]::CreateDirectory((Join-Path $rootFull 'fisheye_temp\avs'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $rootFull 'fisheye_temp\logs'))
    return $rootFull
}

function Complete-DlnaSegmentRootEnsure {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Mode
    )
    $root = Initialize-DlnaSegmentRootTree -Root $Root
    $script:DlnaSegmentRootDefault = $root
    $script:DlnaSegmentRootEnsureMode = $Mode
    $script:DlnaSegmentRootEnsured = $true
    try {
        [void](Restore-DlnaObfuscatedMedia -Root $root)
    } catch {
        Write-Warning ("DLNA root restore obfuscated media failed: {0}" -f $_.Exception.Message)
    }
    return $root
}

function Ensure-DlnaSegmentRoot {
    <#
    .SYNOPSIS
      Resolve the DLNA segment root used by flat / fisheye / hybrid workflows.
      Always store under %AppData%\3d_playlist_local. During the run, subst a dummy letter
      to %AppData%\m1_media_dlna_subst + junction so {letter}:\m1_media\3d_fullsbs_trans is the
      Skybox share path (prefer M:; random free D-Z if M: is taken - remap that folder in the Skybox PC client).
      Never write onto a real M:.
      Quit clears the dummy letter we mapped. Used by flat, fisheye, and hybrid.
      On ensure, restores any <sha256>.tmp media left from a prior quit (via .dlna_obf_map.json).
      Starts the Skybox PC client if idle via P:\all_scripts\Skybox_vr_pc (tray hide + AirScreen share),
      then adds the live 3d_fullsbs_trans Add-folders mapping. Log/manual cleanup passes -SkipSkyboxClient.
    #>
    param(
        [switch] $Force,
        [switch] $SkipSkyboxClient
    )
    if ($script:DlnaSegmentRootEnsured -and -not $Force.IsPresent) {
        return $script:DlnaSegmentRootDefault
    }

    $appDataRoot = Get-DlnaSegmentRootAppDataFallback
    $substMount = Get-DlnaSegmentRootSubstMount
    $letter = Resolve-DlnaSegmentRootDriveLetter -SubstMount $substMount
    Set-DlnaSegmentRootActiveLetter -Letter $letter
    $preferred = $script:DlnaSegmentRootPreferred

    # One-time rename from legacy %AppData%\3d_fullsbs_trans if present and new path empty/missing.
    $appDataParent = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appDataParent)) { $appDataParent = $env:APPDATA }
    if (-not [string]::IsNullOrWhiteSpace($appDataParent)) {
        $legacyAppDataRoot = [System.IO.Path]::GetFullPath((Join-Path $appDataParent '3d_fullsbs_trans'))
        if ((Test-Path -LiteralPath $legacyAppDataRoot -PathType Container) -and
            -not (Test-Path -LiteralPath $appDataRoot -PathType Container)) {
            try {
                Move-Item -LiteralPath $legacyAppDataRoot -Destination $appDataRoot -Force -ErrorAction Stop
                Write-Host ("DLNA root: moved legacy %AppData%\3d_fullsbs_trans -> {0}" -f $appDataRoot)
            } catch {
                Write-Warning ("DLNA root: could not move legacy AppData folder: {0}" -f $_.Exception.Message)
            }
        }
    }

    [void][System.IO.Directory]::CreateDirectory($appDataRoot)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $substMount $script:DlnaSegmentRootShareParent))
    [void](Ensure-DirectoryJunction -LinkPath (Join-Path $substMount $script:DlnaSegmentRootShareRelative) -TargetPath $appDataRoot)
    Remove-DlnaSegmentRootLegacyShareParents -SubstMount $substMount

    $existingSubst = Get-SubstDriveTarget -Letter $letter
    if (-not [string]::IsNullOrWhiteSpace($existingSubst)) {
        if (-not $existingSubst.Equals($substMount, [StringComparison]::OrdinalIgnoreCase)) {
            throw ("Drive {0}: is already subst'd to {1}; dummy DLNA must map to {2}." -f `
                $letter, $existingSubst, $substMount)
        }
    } elseif (Test-DlnaSegmentRootDrivePresent -Letter $letter) {
        throw ("Drive {0}: is a real volume (not our dummy subst). Unmount it so Explorer can keep dummy {0}: -> {1}." -f `
            $letter, $substMount)
    } else {
        $substOut = & subst.exe "${letter}:" "$substMount" 2>&1
        if (-not (Test-DlnaSegmentRootDrivePresent -Letter $letter)) {
            throw ("Failed to subst dummy {0}: -> {1}: {2}" -f $letter, $substMount, $substOut)
        }
        Write-Host ("DLNA root: dummy {0}: subst -> {1} (store %AppData%\{2}; Skybox path {3})." -f `
            $letter, $substMount, $script:DlnaSegmentRootAppDataLeaf, $preferred)
    }

    if (-not (Test-Path -LiteralPath $preferred -PathType Container)) {
        throw ("Dummy subst is mapped but preferred Skybox path is missing: {0}" -f $preferred)
    }

    if (-not $SkipSkyboxClient.IsPresent) {
        try {
            [void](Start-SkyboxPcClientIfNeeded)
        } catch {
            Write-Warning ("Skybox PC client start failed: {0}" -f $_.Exception.Message)
        }
        try {
            Sync-SkyboxDlnaShareMapping -ExpectedRoot $preferred
        } catch {
            Write-Warning ("Skybox PC client folder-mapping check failed: {0}" -f $_.Exception.Message)
        }
    }

    return (Complete-DlnaSegmentRootEnsure -Root $preferred -Mode 'appdata-subst')
}

function Get-DlnaSegmentRoot {
    return (Ensure-DlnaSegmentRoot)
}

function Get-FisheyeTempRoot {
    return [System.IO.Path]::GetFullPath((Join-Path (Ensure-DlnaSegmentRoot) 'fisheye_temp'))
}

function Test-DlnaPlaceholderSharePath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return [bool]($Path.Trim() -match '^[A-Za-z]:\\(?:m1_media|k1_media|f1_media)\\3d_fullsbs_trans(?:\\|$)')
}

function Convert-DlnaPlaceholderSharePath {
    <#
    .SYNOPSIS
      Retarget F:\ / K:\ / M:\ (or any letter) ...\m1_media\3d_fullsbs_trans\... (also legacy k1_media / f1_media) to the ensured dummy letter.
      Keeps the trailing folder (flat / fisheye / hybrid / fisheye_temp). Custom paths are left alone.
    #>
    param([string] $Path)
    if (-not (Test-DlnaPlaceholderSharePath -Path $Path)) {
        return $Path
    }
    $ensured = Ensure-DlnaSegmentRoot
    if ($Path -match '(?i)[A-Za-z]:\\(?:m1_media|k1_media|f1_media)\\3d_fullsbs_trans(?:\\(.*))?$') {
        $rest = $Matches[1]
        if ([string]::IsNullOrWhiteSpace($rest)) {
            return $ensured
        }
        return [System.IO.Path]::GetFullPath((Join-Path $ensured $rest))
    }
    return $ensured
}

function Remove-DlnaSegmentRootSubst {
    <#
    .SYNOPSIS
      On workflow quit: if the session dummy letter is our AppData subst, remove the 3d_fullsbs_trans junction
      and subst {letter}: /d. Does not touch a real volume or %AppData%\3d_playlist_local data.
    #>
    param(
        [switch] $Quiet,
        [switch] $DryRun
    )
    $letter = $script:DlnaSegmentRootDriveLetter
    $substMount = $null
    try {
        $substMount = Get-DlnaSegmentRootSubstMount
    } catch {
        return @{ Removed = $false; Reason = 'no-appdata' }
    }

    $substTarget = Get-SubstDriveTarget -Letter $letter
    if ([string]::IsNullOrWhiteSpace($substTarget)) {
        if (-not $Quiet.IsPresent) {
            Write-Host ("DLNA root subst cleanup: no {0}: subst mapping (nothing to remove)." -f $letter)
        }
        $script:DlnaSegmentRootEnsured = $false
        $script:DlnaSegmentRootEnsureMode = ''
        return @{ Removed = $false; Reason = 'no-subst' }
    }
    if (-not $substTarget.Equals($substMount, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $Quiet.IsPresent) {
            Write-Host ("DLNA root subst cleanup: {0}: maps to {1} (not our mount); leaving alone." -f `
                $letter, $substTarget)
        }
        return @{ Removed = $false; Reason = 'foreign-subst'; Target = $substTarget }
    }

    $junction = [System.IO.Path]::GetFullPath((Join-Path $substMount $script:DlnaSegmentRootShareRelative))
    $junctionRemoved = $false
    if (Test-Path -LiteralPath $junction) {
        try {
            $item = Get-Item -LiteralPath $junction -Force
            $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if ($isReparse) {
                if (-not $DryRun.IsPresent) {
                    cmd.exe /c rmdir "$junction" | Out-Null
                }
                $junctionRemoved = -not (Test-Path -LiteralPath $junction)
                if ($DryRun.IsPresent) { $junctionRemoved = $true }
            }
        } catch { }
    }

    $substRemoved = $false
    if (-not $DryRun.IsPresent) {
        try {
            & subst.exe "${letter}:" /d 2>&1 | Out-Null
        } catch { }
        $still = Get-SubstDriveTarget -Letter $letter
        $substRemoved = [string]::IsNullOrWhiteSpace($still)
    } else {
        $substRemoved = $true
    }

    $script:DlnaSegmentRootEnsured = $false
    $script:DlnaSegmentRootEnsureMode = ''
    $script:DlnaSegmentRootDefault = $script:DlnaSegmentRootPreferred

    if (-not $Quiet.IsPresent) {
        $verb = if ($DryRun.IsPresent) { 'would remove' } else { 'removed' }
        Write-Host ("DLNA root subst cleanup: {0} {1}: -> {2} (junction_removed={3}, subst_removed={4})." -f `
            $verb, $letter, $substMount, $junctionRemoved, $substRemoved)
    }

    return @{
        Removed          = ($junctionRemoved -or $substRemoved)
        JunctionRemoved  = $junctionRemoved
        SubstRemoved     = $substRemoved
        Mount            = $substMount
    }
}

function Invoke-DlnaWorkflowQuitCleanup {
    <#
    .SYNOPSIS
      Idempotent workflow quit: obfuscate media under DLNA root, then remove dummy M: (or fallback) subst.
      Safe to call from parent finally and from the robocopy re-invoke wrapper finally
      (success, abort, timeout). Removes Skybox Add-folders 3d_fullsbs_trans nodes while
      the client is still up, unmaps the Skybox_vr_pc AirScreen share, quits Skybox only if this
      workflow started it, obfuscates media, then drops dummy subst. Already-running Skybox is left alone.
    #>
    param(
        [switch] $KeepLogs,
        [switch] $Quiet,
        [switch] $DryRun
    )
    if ($script:DlnaWorkflowQuitCleanupDone -and -not $DryRun.IsPresent) {
        return @{ Done = $true; Skipped = $true }
    }
    if (-not $DryRun.IsPresent) {
        $script:DlnaWorkflowQuitCleanupDone = $true
    }

    $obf = $null
    $subst = $null
    if (-not $DryRun.IsPresent) {
        try {
            Sync-SkyboxDlnaShareMapping -ExpectedRoot $script:DlnaSegmentRootPreferred -Removed
        } catch {
            Write-Warning ("Skybox PC client mapping cleanup on quit failed: {0}" -f $_.Exception.Message)
        }
        try {
            Stop-SkyboxPcClient -OnlyIfWorkflowStarted
        } catch {
            Write-Warning ("Skybox PC client quit failed: {0}" -f $_.Exception.Message)
        }
    }
    try {
        if (Get-Command Obfuscate-DlnaSegmentRootMedia -ErrorAction SilentlyContinue) {
            $obf = Obfuscate-DlnaSegmentRootMedia -KeepLogs:$KeepLogs.IsPresent -Quiet:$Quiet.IsPresent -DryRun:$DryRun.IsPresent
        }
    } catch {
        Write-Warning ("DLNA root media obfuscate on quit failed: {0}" -f $_.Exception.Message)
    }
    try {
        if (Get-Command Remove-DlnaSegmentRootSubst -ErrorAction SilentlyContinue) {
            $subst = Remove-DlnaSegmentRootSubst -Quiet:$Quiet.IsPresent -DryRun:$DryRun.IsPresent
        }
    } catch {
        Write-Warning ("DLNA root F: subst cleanup on quit failed: {0}" -f $_.Exception.Message)
    }
    return @{ Done = $true; Skipped = $false; Obfuscate = $obf; Subst = $subst }
}

function Stop-LeafFfmpegExport {
    <#
    .SYNOPSIS
      Force-stop leaf DLNA export ffmpeg (3d_op_*.mkv) so segment files can be renamed or cleared.
    #>
    $pids = @(Get-LeafFfmpegProcessIds)
    $stopped = 0
    foreach ($procId in $pids) {
        try {
            & taskkill.exe /PID $procId /T /F 2>$null | Out-Null
            $stopped++
        } catch { }
    }
    $script:LeafFfmpegExportSuspended = $false
    if ($null -ne $script:LeafFfmpegSuspendedPids) {
        $script:LeafFfmpegSuspendedPids.Clear()
    }
    return $stopped
}

function Test-DlnaMediaFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    $ext = [System.IO.Path]::GetExtension($FileName)
    if ([string]::IsNullOrWhiteSpace($ext)) { return $false }
    return $script:DlnaMediaExtensions -contains $ext.ToLowerInvariant()
}

function Get-DlnaPathRelativeToRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $FullPath
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($FullPath)
    if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($rootFull.Length).TrimStart('\', '/')
    }
    return [System.IO.Path]::GetFileName($FullPath)
}

function Get-DlnaObfuscationMapPath {
    param([Parameter(Mandatory = $true)][string] $Root)
    return [System.IO.Path]::GetFullPath((Join-Path $Root $script:DlnaObfuscationMapLeaf))
}

function Get-DlnaObfuscationMapKeyBytes {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:DlnaObfuscationMapKeyMaterial))
    } finally {
        $sha.Dispose()
    }
}

function Protect-DlnaObfuscationMapText {
    param([Parameter(Mandatory = $true)][string] $PlainText)
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $key = Get-DlnaObfuscationMapKeyBytes
    $out = New-Object byte[] $plainBytes.Length
    for ($i = 0; $i -lt $plainBytes.Length; $i++) {
        $out[$i] = $plainBytes[$i] -bxor $key[$i % $key.Length]
    }
    return ($script:DlnaObfuscationMapMagic + [Convert]::ToBase64String($out))
}

function Unprotect-DlnaObfuscationMapText {
    param([Parameter(Mandatory = $true)][string] $ProtectedText)
    $raw = $ProtectedText.Trim()
    if (-not $raw.StartsWith($script:DlnaObfuscationMapMagic, [StringComparison]::Ordinal)) {
        return $null
    }
    $b64 = $raw.Substring($script:DlnaObfuscationMapMagic.Length)
    try {
        $bytes = [Convert]::FromBase64String($b64)
    } catch {
        return $null
    }
    $key = Get-DlnaObfuscationMapKeyBytes
    $out = New-Object byte[] $bytes.Length
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $out[$i] = $bytes[$i] -bxor $key[$i % $key.Length]
    }
    return [System.Text.Encoding]::UTF8.GetString($out)
}

function ConvertFrom-DlnaObfuscationMapJson {
    param([Parameter(Mandatory = $true)][string] $JsonText)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $map }
    $doc = $JsonText | ConvertFrom-Json
    if ($null -eq $doc) { return $map }
    foreach ($p in $doc.PSObject.Properties) {
        if ([string]::IsNullOrWhiteSpace($p.Name) -or $null -eq $p.Value) { continue }
        $map[[string]$p.Name] = [string]$p.Value
    }
    return $map
}

function Read-DlnaObfuscationMap {
    param([Parameter(Mandatory = $true)][string] $Root)
    $map = @{}
    $path = Get-DlnaObfuscationMapPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $map }
        $json = Unprotect-DlnaObfuscationMapText -ProtectedText $raw
        if ([string]::IsNullOrWhiteSpace($json)) {
            # Legacy plaintext JSON maps (pre-scramble).
            $json = $raw
        }
        $map = ConvertFrom-DlnaObfuscationMapJson -JsonText $json
    } catch { }
    return $map
}

function Write-DlnaObfuscationMap {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)]$Map,
        [switch] $DryRun
    )
    $path = Get-DlnaObfuscationMapPath -Root $Root
    if ($DryRun.IsPresent) { return }
    if ($null -eq $Map -or $Map.Count -eq 0) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return
    }
    $ordered = [ordered]@{}
    foreach ($key in @($Map.Keys | Sort-Object)) {
        $ordered[$key] = $Map[$key]
    }
    $json = $ordered | ConvertTo-Json -Compress
    $scrambled = Protect-DlnaObfuscationMapText -PlainText $json
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [System.IO.File]::WriteAllText($path, $scrambled)
}

function Get-DlnaContentHashLeaf {
    param([Parameter(Mandatory = $true)][string] $RelativeClearPath)
    $norm = (($RelativeClearPath -replace '/', '\').Trim().ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
    } finally {
        $sha.Dispose()
    }
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return ($hex + $script:DlnaObfuscationTmpSuffix)
}

function Test-DlnaHashTmpFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    # Current: <sha256>.tmp ; legacy: <sha256>_v.tmp
    return [bool]($FileName -match '^[0-9a-fA-F]{16,64}(_v)?\.tmp$')
}

function Test-DlnaLegacyObfuscatedFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    if (-not $FileName.StartsWith($script:DlnaObfuscationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if ($FileName.EndsWith($script:DlnaObfuscationSuffix, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return (Test-DlnaMediaFileName -FileName $FileName)
}

function Test-DlnaObfuscatedFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    if (Test-DlnaHashTmpFileName -FileName $FileName) { return $true }
    return (Test-DlnaLegacyObfuscatedFileName -FileName $FileName)
}

function Get-DlnaLegacyUnobfuscatedLeafName {
    param([Parameter(Mandatory = $true)][string] $LeafName)
    if (-not $LeafName.StartsWith($script:DlnaObfuscationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $LeafName
    }
    $mid = $LeafName.Substring($script:DlnaObfuscationPrefix.Length)
    if ($mid.EndsWith($script:DlnaObfuscationSuffix, [StringComparison]::OrdinalIgnoreCase)) {
        return $mid.Substring(0, $mid.Length - $script:DlnaObfuscationSuffix.Length)
    }
    return $mid
}

function Test-DlnaLogPath {
    param([Parameter(Mandatory = $true)][string] $FullPath)
    if ($FullPath -match '(?i)[\\/]logs[\\/]') { return $true }
    return ([System.IO.Path]::GetExtension($FullPath) -eq '.log')
}

function Clear-DlnaPathBestEffort {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $DryRun
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }
    if ($DryRun.IsPresent) {
        return 'dry-run'
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return 'deleted'
    } catch {
        try {
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Truncate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            $fs.Close()
            $fs.Dispose()
            return 'truncated'
        } catch {
            return 'failed'
        }
    }
}

function Rename-DlnaPathBestEffort {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $DestinationLeaf,
        [switch] $DryRun
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $dest = [System.IO.Path]::Combine($dir, $DestinationLeaf)
    if ($Path.Equals($dest, [StringComparison]::OrdinalIgnoreCase)) {
        return 'unchanged'
    }
    if ($DryRun.IsPresent) {
        return 'dry-run'
    }
    try {
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        }
        Rename-Item -LiteralPath $Path -NewName $DestinationLeaf -Force -ErrorAction Stop
        return 'renamed'
    } catch {
        return 'failed'
    }
}

function Restore-DlnaObfuscatedMedia {
    <#
    .SYNOPSIS
      Detect <sha256>.tmp (via .dlna_obf_map.json) and legacy _dlna_obf_* / *_v.tmp names; restore originals.
      If the clear dest already exists (stale leftover from a crashed run), overwrite it with the mapped .tmp.
    #>
    param(
        [string] $Root = '',
        [switch] $DryRun,
        [switch] $Quiet
    )
    $rootFull = $null
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $rootFull = [System.IO.Path]::GetFullPath($Root)
    } elseif ($script:DlnaSegmentRootEnsured -and -not [string]::IsNullOrWhiteSpace($script:DlnaSegmentRootDefault)) {
        $rootFull = $script:DlnaSegmentRootDefault
    } else {
        $rootFull = $script:DlnaSegmentRootPreferred
    }

    $restored = 0
    $skipped = 0
    $failed = 0
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        return @{ Root = $rootFull; Restored = 0; Skipped = 0; Failed = 0 }
    }

    $map = Read-DlnaObfuscationMap -Root $rootFull
    $mapDirty = $false

    $files = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne $script:DlnaObfuscationMapLeaf -and
            (Test-DlnaObfuscatedFileName -FileName $_.Name)
        })

    foreach ($f in $files) {
        $relObf = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath $f.FullName
        $clearRel = $null
        $clearLeaf = $null
        $destDir = $f.DirectoryName

        if (Test-DlnaHashTmpFileName -FileName $f.Name) {
            if ($map.ContainsKey($relObf)) {
                $clearRel = [string]$map[$relObf]
            } else {
                # Try match by leaf key only (older/partial maps).
                foreach ($k in @($map.Keys)) {
                    if ([System.IO.Path]::GetFileName([string]$k).Equals($f.Name, [StringComparison]::OrdinalIgnoreCase)) {
                        $clearRel = [string]$map[$k]
                        break
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($clearRel)) {
                $skipped++
                continue
            }
            $clearLeaf = [System.IO.Path]::GetFileName($clearRel)
            $clearParent = [System.IO.Path]::GetDirectoryName($clearRel)
            if (-not [string]::IsNullOrWhiteSpace($clearParent)) {
                $destDir = [System.IO.Path]::GetFullPath((Join-Path $rootFull $clearParent))
                if (-not $DryRun.IsPresent -and -not (Test-Path -LiteralPath $destDir -PathType Container)) {
                    [void][System.IO.Directory]::CreateDirectory($destDir)
                }
            }
        } else {
            $clearLeaf = Get-DlnaLegacyUnobfuscatedLeafName -LeafName $f.Name
            $clearRel = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath (Join-Path $f.DirectoryName $clearLeaf)
        }

        if ([string]::IsNullOrWhiteSpace($clearLeaf)) {
            $skipped++
            continue
        }

        $dest = [System.IO.Path]::Combine($destDir, $clearLeaf)
        # Leftover clear dest (crashed run / 0-byte 3d_op) is overwritten by Rename-DlnaPathBestEffort / Move-Item -Force.

        if ($destDir.Equals($f.DirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
            $action = Rename-DlnaPathBestEffort -Path $f.FullName -DestinationLeaf $clearLeaf -DryRun:$DryRun.IsPresent
        } else {
            if ($DryRun.IsPresent) {
                $action = 'dry-run'
            } else {
                try {
                    Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
                    $action = 'renamed'
                } catch {
                    $action = 'failed'
                }
            }
        }

        switch ($action) {
            { $_ -in @('renamed', 'dry-run') } {
                $restored++
                if ($map.ContainsKey($relObf)) {
                    $map.Remove($relObf)
                    $mapDirty = $true
                }
            }
            { $_ -in @('unchanged', 'missing') } { $skipped++ }
            default { $failed++ }
        }
    }

    if ($mapDirty -or ($map.Count -eq 0 -and (Test-Path -LiteralPath (Get-DlnaObfuscationMapPath -Root $rootFull)))) {
        Write-DlnaObfuscationMap -Root $rootFull -Map $map -DryRun:$DryRun.IsPresent
    }

    if (-not $Quiet.IsPresent -and ($restored -gt 0 -or $failed -gt 0)) {
        $verb = if ($DryRun.IsPresent) { 'would restore' } else { 'restored' }
        Write-Host ("DLNA root {0} obfuscated media: {1} (restored={2}, skipped={3}, failed={4})" -f `
            $verb, $rootFull, $restored, $skipped, $failed)
    }

    return @{
        Root     = $rootFull
        Restored = $restored
        Skipped  = $skipped
        Failed   = $failed
    }
}

function Obfuscate-DlnaSegmentRootMedia {
    <#
    .SYNOPSIS
      On workflow quit: stop leaf export ffmpeg, rename media under 3d_fullsbs_trans to
      <sha256(relativePath)>.tmp (scrambled map in .dlna_obf_map.json), including
      fisheye_temp\avs\*.avs, purge logs unless -KeepLogs.
      Does not delete media; use Clear-DlnaSegmentRootContents via Cleanup-DlnaSegmentRoot.ps1
      (playlist root, beside Readme.txt).
    .PARAMETER KeepLogs
      Skip deleting *.log / logs\ trees (error-exit diagnostics).
    #>
    param(
        [string] $Root = '',
        [switch] $DryRun,
        [switch] $NoStopLeafExport,
        [switch] $Quiet,
        [switch] $KeepLogs
    )
    $rootFull = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Root)) {
            $rootFull = Ensure-DlnaSegmentRoot -SkipSkyboxClient
        } else {
            $rootFull = [System.IO.Path]::GetFullPath($Root)
        }
    } catch {
        $rootFull = $script:DlnaSegmentRootPreferred
    }

    $obfuscated = 0
    $deleted = 0
    $truncated = 0
    $failed = 0
    $stopped = 0
    $keptLogs = 0
    $skipped = 0

    if (-not $NoStopLeafExport.IsPresent -and -not $DryRun.IsPresent) {
        try { $stopped = [int](Stop-LeafFfmpegExport) } catch { $stopped = 0 }
    }

    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        if (-not $DryRun.IsPresent) {
            try { [void](Initialize-DlnaSegmentRootTree -Root $rootFull) } catch { }
        }
        return @{
            Root       = $rootFull
            Obfuscated = 0
            Deleted    = 0
            Truncated  = 0
            Failed     = 0
            Stopped    = $stopped
            KeptLogs   = 0
            Skipped    = 0
        }
    }

    $map = Read-DlnaObfuscationMap -Root $rootFull
    $mapDirty = $false

    $files = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $script:DlnaObfuscationMapLeaf })
    foreach ($f in $files) {
        $isLog = Test-DlnaLogPath -FullPath $f.FullName
        if ($isLog) {
            if ($KeepLogs.IsPresent) {
                $keptLogs++
                continue
            }
            $action = Clear-DlnaPathBestEffort -Path $f.FullName -DryRun:$DryRun.IsPresent
            switch ($action) {
                'deleted' { $deleted++ }
                'truncated' { $truncated++ }
                'dry-run' { $deleted++ }
                'failed' { $failed++ }
            }
            continue
        }

        if (Test-DlnaHashTmpFileName -FileName $f.Name) {
            $skipped++
            continue
        }

        $clearLeaf = $f.Name
        $isLegacy = Test-DlnaLegacyObfuscatedFileName -FileName $f.Name
        if ($isLegacy) {
            $clearLeaf = Get-DlnaLegacyUnobfuscatedLeafName -LeafName $f.Name
        } elseif (-not (Test-DlnaMediaFileName -FileName $f.Name)) {
            $skipped++
            continue
        }

        $clearFullForHash = if ($isLegacy) {
            [System.IO.Path]::Combine($f.DirectoryName, $clearLeaf)
        } else {
            $f.FullName
        }
        $clearRel = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath $clearFullForHash
        $obfLeaf = Get-DlnaContentHashLeaf -RelativeClearPath $clearRel
        if ($obfLeaf.Equals($f.Name, [StringComparison]::OrdinalIgnoreCase)) {
            $skipped++
            continue
        }

        $action = Rename-DlnaPathBestEffort -Path $f.FullName -DestinationLeaf $obfLeaf -DryRun:$DryRun.IsPresent
        switch ($action) {
            { $_ -in @('renamed', 'dry-run') } {
                $obfuscated++
                $relObf = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath ([System.IO.Path]::Combine($f.DirectoryName, $obfLeaf))
                $map[$relObf] = $clearRel
                $mapDirty = $true
            }
            { $_ -in @('unchanged', 'missing') } { $skipped++ }
            default { $failed++ }
        }
    }

    if ($mapDirty) {
        Write-DlnaObfuscationMap -Root $rootFull -Map $map -DryRun:$DryRun.IsPresent
    }

    if (-not $DryRun.IsPresent) {
        try { [void](Initialize-DlnaSegmentRootTree -Root $rootFull) } catch { }
    }

    if (-not $Quiet.IsPresent) {
        $verb = if ($DryRun.IsPresent) { 'would obfuscate' } else { 'obfuscated' }
        $logNote = if ($KeepLogs.IsPresent) { ", kept_logs=$keptLogs" } else { ", logs_deleted=$deleted, logs_truncated=$truncated" }
        Write-Host ("DLNA root {0} media: {1} (obfuscated={2}, failed={3}, skipped={4}, stopped_leaf_ffmpeg={5}{6})" -f `
            $verb, $rootFull, $obfuscated, $failed, $skipped, $stopped, $logNote)
    }

    return @{
        Root       = $rootFull
        Obfuscated = $obfuscated
        Deleted    = $deleted
        Truncated  = $truncated
        Failed     = $failed
        Stopped    = $stopped
        KeptLogs   = $keptLogs
        Skipped    = $skipped
    }
}

function Clear-DlnaSegmentRootContents {
    <#
    .SYNOPSIS
      Delete/truncate files under 3d_fullsbs_trans (segments + fisheye_temp).
      Used by manual Cleanup-DlnaSegmentRoot.ps1 (playlist root) - workflows obfuscate media on quit instead.
      Keeps the Skybox DLNA share folder and recreates empty flat/fisheye/hybrid/fisheye_temp trees.
    .PARAMETER KeepLogs
      Skip deleting *.log files and anything under a logs\ folder (e.g. fisheye_temp\logs).
    #>
    param(
        [string] $Root = '',
        [switch] $DryRun,
        [switch] $NoStopLeafExport,
        [switch] $Quiet,
        [switch] $KeepLogs
    )
    $rootFull = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Root)) {
            $rootFull = Ensure-DlnaSegmentRoot -SkipSkyboxClient
        } else {
            $rootFull = [System.IO.Path]::GetFullPath($Root)
        }
    } catch {
        $rootFull = $script:DlnaSegmentRootPreferred
    }

    $deleted = 0
    $truncated = 0
    $failed = 0
    $stopped = 0
    $keptLogs = 0

    if (-not $NoStopLeafExport.IsPresent -and -not $DryRun.IsPresent) {
        try { $stopped = [int](Stop-LeafFfmpegExport) } catch { $stopped = 0 }
    }

    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        if (-not $DryRun.IsPresent) {
            try { [void](Initialize-DlnaSegmentRootTree -Root $rootFull) } catch { }
        }
        return @{
            Root      = $rootFull
            Deleted   = 0
            Truncated = 0
            Failed    = 0
            Stopped   = $stopped
            KeptLogs  = 0
        }
    }

    $files = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        if ($KeepLogs.IsPresent) {
            if (Test-DlnaLogPath -FullPath $f.FullName) {
                $keptLogs++
                continue
            }
        }
        $action = Clear-DlnaPathBestEffort -Path $f.FullName -DryRun:$DryRun.IsPresent
        switch ($action) {
            'deleted' { $deleted++ }
            'truncated' { $truncated++ }
            'dry-run' { $deleted++ }
            'failed' { $failed++ }
        }
    }

    $keepLeaves = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($leaf in @('flat', 'fisheye', 'hybrid', 'fisheye_temp', 'avs', 'logs')) {
        [void]$keepLeaves.Add($leaf)
    }
    $dirs = @(Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($d in $dirs) {
        if ($keepLeaves.Contains($d.Name)) { continue }
        if ($DryRun.IsPresent) { continue }
        try {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    if (-not $DryRun.IsPresent) {
        try { [void](Initialize-DlnaSegmentRootTree -Root $rootFull) } catch { }
    }

    if (-not $Quiet.IsPresent) {
        $verb = if ($DryRun.IsPresent) { 'would clear' } else { 'cleared' }
        $logNote = if ($KeepLogs.IsPresent) { ", kept_logs=$keptLogs" } else { '' }
        Write-Host ("DLNA root {0}: {1} (deleted={2}, truncated={3}, failed={4}, stopped_leaf_ffmpeg={5}{6})" -f `
            $verb, $rootFull, $deleted, $truncated, $failed, $stopped, $logNote)
    }

    return @{
        Root      = $rootFull
        Deleted   = $deleted
        Truncated = $truncated
        Failed    = $failed
        Stopped   = $stopped
        KeptLogs  = $keptLogs
    }
}

function Get-DlnaSegmentNameSuffix {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('flat', 'fisheye')]
        [string] $Kind
    )
    if ($Kind -eq 'fisheye') { return $script:DlnaSegmentSuffixFisheye }
    return $script:DlnaSegmentSuffixFlat
}

function Get-DlnaSegmentOutputDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('flat', 'fisheye', 'hybrid')]
        [string] $Kind,
        [string] $Root = ''
    )
    $base = if ([string]::IsNullOrWhiteSpace($Root)) {
        Ensure-DlnaSegmentRoot
    } else {
        $Root.TrimEnd('\', '/')
    }
    $dir = [System.IO.Path]::GetFullPath((Join-Path $base $Kind))
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    return $dir
}

function Get-DlnaSegmentOutputPattern {
    param([string] $Suffix = '')
    if ([string]::IsNullOrWhiteSpace($Suffix)) {
        return '3d_op_%02d.mkv'
    }
    $safe = ($Suffix.Trim() -replace '[\\/:*?"<>|]', '_')
    return ("3d_op_%02d_{0}.mkv" -f $safe)
}

function Get-DlnaSegmentOutputLeaves {
    param([string] $Suffix = '')
    if ([string]::IsNullOrWhiteSpace($Suffix)) {
        return @('3d_op_00.mkv', '3d_op_01.mkv', '3d_op_%02d.mkv')
    }
    $safe = ($Suffix.Trim() -replace '[\\/:*?"<>|]', '_')
    return @(
        ("3d_op_00_{0}.mkv" -f $safe),
        ("3d_op_01_{0}.mkv" -f $safe),
        ("3d_op_%02d_{0}.mkv" -f $safe)
    )
}

function Clear-DlnaExportSegments {
    <#
    .SYNOPSIS
      Retain only the newest N DLNA export segments under a folder (default 2).
      When -ActiveSuffix is set, also delete 3d_op_*.mkv leaves that are not that suffix's wrap pair
      so hybrid flat/fisheye multiplexing never leaves more than two playable slots.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $Directory,
        [string] $ActiveSuffix = '',
        [int] $KeepCount = -1,
        [switch] $DryRun
    )
    if ($KeepCount -lt 0) {
        $KeepCount = $script:DlnaExportSegmentKeepCountDefault
    }
    if ($KeepCount -lt 0) {
        throw "KeepCount must be >= 0 (got $KeepCount)."
    }
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @{ Deleted = 0; Kept = 0; Directory = $Directory }
    }
    $dirFull = [System.IO.Path]::GetFullPath($Directory)
    $files = @(Get-ChildItem -LiteralPath $dirFull -File -Filter '3d_op_*.mkv' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return @{ Deleted = 0; Kept = 0; Directory = $dirFull }
    }

    $protected = $null
    if (-not [string]::IsNullOrWhiteSpace($ActiveSuffix)) {
        $safe = ($ActiveSuffix.Trim() -replace '[\\/:*?"<>|]', '_')
        $protected = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        [void]$protected.Add(("3d_op_00_{0}.mkv" -f $safe))
        [void]$protected.Add(("3d_op_01_{0}.mkv" -f $safe))
    }

    $toDelete = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($f in $files) {
        if ($null -ne $protected -and -not $protected.Contains($f.Name)) {
            [void]$toDelete.Add($f)
        } else {
            [void]$candidates.Add($f)
        }
    }

    if ($KeepCount -eq 0) {
        foreach ($f in $candidates) { [void]$toDelete.Add($f) }
        $candidates.Clear()
    } elseif ($candidates.Count -gt $KeepCount) {
        $sorted = @($candidates | Sort-Object LastWriteTimeUtc -Descending)
        foreach ($f in @($sorted | Select-Object -Skip $KeepCount)) {
            [void]$toDelete.Add($f)
        }
        $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        foreach ($f in @($sorted | Select-Object -First $KeepCount)) {
            [void]$candidates.Add($f)
        }
    }

    $deleted = 0
    $failed = 0
    foreach ($f in $toDelete) {
        if ($DryRun) {
            Write-Host ("DLNA segment purge dry-run: would delete {0}" -f $f.FullName)
            $deleted++
            continue
        }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $deleted++
        } catch {
            $failed++
            Write-Warning ("DLNA segment purge failed: {0} ({1})" -f $f.FullName, $_.Exception.Message)
        }
    }

    $kept = $candidates.Count
    if ($deleted -gt 0 -or $failed -gt 0) {
        $suffixNote = if ([string]::IsNullOrWhiteSpace($ActiveSuffix)) { '' } else { " active=$ActiveSuffix;" }
        if ($DryRun) {
            Write-Host ("DLNA segment purge dry-run:{0} keep {1}, would delete {2} under {3}" -f `
                $suffixNote, $kept, $deleted, $dirFull)
        } else {
            Write-Host ("DLNA segment purge:{0} keep {1}, deleted {2} (failed {3}) under {4}" -f `
                $suffixNote, $kept, $deleted, $failed, $dirFull)
        }
    }
    return @{
        Deleted   = $deleted
        Failed    = $failed
        Kept      = $kept
        Directory = $dirFull
    }
}

function Sync-DlnaHybridSegmentHandoff {
    <#
    .SYNOPSIS
      Gradual hybrid-folder handoff when switching Skybox suffixes (flat Full_SBS <-> fisheye LR_180_FISHEYE).
      Keeps prior-suffix segments until the new wrap pair starts writing, then retires inactive leaves
      one-by-one so ~two playable files remain (never empties the folder before the new encode has output).
    .NOTES
      readyActive 0: keep all inactive (old pair still serves DLNA).
      readyActive 1: drop inactive until one remains (1 new + 1 old).
      readyActive 2 or -Finalize with readyActive>=1: drop all remaining inactive (active wrap pair only).
      -Finalize with readyActive 0: hold (do not empty the folder when the new clip wrote nothing).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $Directory,
        [Parameter(Mandatory = $true)]
        [string] $ActiveSuffix,
        [long] $MinBytes = 1048576L,
        [int] $KeepCount = -1,
        [switch] $Finalize,
        [switch] $DryRun
    )
    if ($KeepCount -lt 0) {
        $KeepCount = $script:DlnaExportSegmentKeepCountDefault
    }
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @{ Deleted = 0; ReadyActive = 0; InactiveLeft = 0; Directory = $Directory }
    }
    if ([string]::IsNullOrWhiteSpace($ActiveSuffix)) {
        throw 'ActiveSuffix is required for Sync-DlnaHybridSegmentHandoff.'
    }
    $dirFull = [System.IO.Path]::GetFullPath($Directory)
    $safe = ($ActiveSuffix.Trim() -replace '[\\/:*?"<>|]', '_')
    $activeNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$activeNames.Add(("3d_op_00_{0}.mkv" -f $safe))
    [void]$activeNames.Add(("3d_op_01_{0}.mkv" -f $safe))

    $files = @(Get-ChildItem -LiteralPath $dirFull -File -Filter '3d_op_*.mkv' -ErrorAction SilentlyContinue)
    $readyActive = 0
    $inactive = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($f in $files) {
        if ($activeNames.Contains($f.Name)) {
            if ($f.Length -ge $MinBytes) { $readyActive++ }
        } else {
            [void]$inactive.Add($f)
        }
    }

    if ($Finalize.IsPresent -and $readyActive -lt 1) {
        # Clip ended with no playable active output - keep prior-suffix pair for DLNA.
        if ($inactive.Count -gt 0) {
            Write-Host ("DLNA handoff finalize hold: active={0} ready=0; keeping {1} prior segment(s)" -f `
                $ActiveSuffix, $inactive.Count)
        }
        return @{
            Deleted      = 0
            Failed       = 0
            ReadyActive  = 0
            InactiveLeft = $inactive.Count
            Directory    = $dirFull
            Mode         = 'finalize-hold'
        }
    }

    if ($Finalize.IsPresent -or $readyActive -ge 2) {
        # Full retire of other suffix once both new slots are writing (or clip finished with output).
        $result = Clear-DlnaExportSegments -Directory $dirFull -ActiveSuffix $ActiveSuffix `
            -KeepCount $KeepCount -DryRun:$DryRun.IsPresent
        return @{
            Deleted      = [int]$result.Deleted
            Failed       = [int]$result.Failed
            ReadyActive  = $readyActive
            InactiveLeft = 0
            Directory    = $dirFull
            Mode         = 'finalize'
        }
    }

    $desiredInactiveKeep = [Math]::Max(0, $KeepCount - $readyActive)
    $removeCount = [Math]::Max(0, $inactive.Count - $desiredInactiveKeep)
    if ($removeCount -le 0) {
        return @{
            Deleted      = 0
            Failed       = 0
            ReadyActive  = $readyActive
            InactiveLeft = $inactive.Count
            Directory    = $dirFull
            Mode         = 'hold'
        }
    }

    $oldestFirst = @($inactive | Sort-Object LastWriteTimeUtc, Name)
    $toDelete = @($oldestFirst | Select-Object -First $removeCount)
    $deleted = 0
    $failed = 0
    foreach ($f in $toDelete) {
        if ($DryRun) {
            Write-Host ("DLNA handoff dry-run: would retire {0} (readyActive={1})" -f $f.Name, $readyActive)
            $deleted++
            continue
        }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            Write-Host ("DLNA handoff: retired {0} (readyActive={1}, keep ~{2})" -f $f.Name, $readyActive, $KeepCount)
            $deleted++
        } catch {
            $failed++
            Write-Warning ("DLNA handoff failed: {0} ({1})" -f $f.FullName, $_.Exception.Message)
        }
    }
    return @{
        Deleted      = $deleted
        Failed       = $failed
        ReadyActive  = $readyActive
        InactiveLeft = $inactive.Count - $deleted
        Directory    = $dirFull
        Mode         = 'step'
    }
}

function Test-FfmpegCommandLineIsLeafDlnaExport {
    param([string] $CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    # Broad match: hybrid suffixes + legacy unsuffixed patterns; mezzanine is *.fisheye.frag.mp4 (no 3d_op_).
    if ($CommandLine -like '*3d_op_*') { return $true }
    foreach ($leaf in $script:LeafFfmpegOutputLeaves) {
        if ($CommandLine -like "*$leaf*") { return $true }
    }
    return $false
}

function Initialize-LeafFfmpegNtSuspendApi {
    if ($script:LeafFfmpegNtApiInitialized) { return }
    if ('LeafFfmpegNtSuspend' -as [type]) {
        $script:LeafFfmpegNtApiInitialized = $true
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LeafFfmpegNtSuspend {
    [DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(IntPtr processHandle);
    [DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(IntPtr processHandle);
}
'@ -ErrorAction Stop
    $script:LeafFfmpegNtApiInitialized = $true
}

function Convert-TranscodeWorkflowDeadlineUtc {
    param([string] $UtcIso)
    if ([string]::IsNullOrWhiteSpace($UtcIso)) { return $null }
    try {
        return [datetime]::Parse(
            $UtcIso,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    } catch {
        return $null
    }
}

function Test-TranscodeWorkflowDeadlineExpired {
    param([datetime] $DeadlineUtc)
    if ($null -eq $DeadlineUtc -or $DeadlineUtc -le [datetime]::MinValue) { return $false }
    if ($DeadlineUtc -ge [datetime]::MaxValue.AddDays(-1)) { return $false }
    return [DateTime]::UtcNow -ge $DeadlineUtc
}

function Get-LeafFfmpegProcessIds {
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        if (Test-FfmpegCommandLineIsLeafDlnaExport -CommandLine $cmd) {
            [void]$ids.Add([int]$proc.ProcessId)
        }
    }
    return @($ids | Sort-Object)
}

function Set-LeafFfmpegProcessSuspended {
    param([int] $ProcessId)
    Initialize-LeafFfmpegNtSuspendApi
    $proc = $null
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $status = [LeafFfmpegNtSuspend]::NtSuspendProcess($proc.Handle)
        return ($status -eq 0)
    } catch {
        return $false
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

function Set-LeafFfmpegProcessResumed {
    param([int] $ProcessId)
    Initialize-LeafFfmpegNtSuspendApi
    $proc = $null
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $status = [LeafFfmpegNtSuspend]::NtResumeProcess($proc.Handle)
        return ($status -eq 0)
    } catch {
        return $false
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

function Suspend-LeafFfmpegExport {
    $pids = @(Get-LeafFfmpegProcessIds)
    if ($pids.Count -lt 1) {
        Write-Host '[leaf-export] No DLNA export ffmpeg (3d_op_*.mkv) running to pause.'
        return $false
    }
    $script:LeafFfmpegSuspendedPids.Clear()
    $ok = 0
    foreach ($procId in $pids) {
        if (Set-LeafFfmpegProcessSuspended -ProcessId $procId) {
            [void]$script:LeafFfmpegSuspendedPids.Add($procId)
            $ok++
        }
    }
    if ($ok -gt 0) {
        $script:LeafFfmpegExportSuspended = $true
        Write-Host "[leaf-export] Paused $ok DLNA export ffmpeg process(es): $($script:LeafFfmpegSuspendedPids -join ', ')"
        return $true
    }
    Write-Warning '[leaf-export] Could not pause DLNA export ffmpeg (process may have exited).'
    return $false
}

function Resume-LeafFfmpegExport {
    $targets = @($script:LeafFfmpegSuspendedPids)
    if ($targets.Count -lt 1) {
        $targets = @(Get-LeafFfmpegProcessIds)
    }
    if ($targets.Count -lt 1) {
        $script:LeafFfmpegExportSuspended = $false
        $script:LeafFfmpegSuspendedPids.Clear()
        Write-Host '[leaf-export] No DLNA export ffmpeg to resume.'
        return $false
    }
    $ok = 0
    foreach ($procId in $targets) {
        if (Set-LeafFfmpegProcessResumed -ProcessId $procId) { $ok++ }
    }
    $script:LeafFfmpegExportSuspended = $false
    $script:LeafFfmpegSuspendedPids.Clear()
    if ($ok -gt 0) {
        Write-Host "[leaf-export] Resumed $ok DLNA export ffmpeg process(es)."
        return $true
    }
    Write-Warning '[leaf-export] Could not resume DLNA export ffmpeg.'
    return $false
}

function Toggle-LeafFfmpegExportSuspend {
    if ($script:LeafFfmpegExportSuspended) {
        return (Resume-LeafFfmpegExport)
    }
    return (Suspend-LeafFfmpegExport)
}

function Invoke-TranscodeConsoleKeyPoll {
    param(
        [switch] $AllowEnterCancel,
        [ref] $EnterCancel
    )
    if ($AllowEnterCancel -and (Get-Command Invoke-BatchConsoleControlPoll -ErrorAction SilentlyContinue)) {
        $cancelled = $false
        $action = Invoke-BatchConsoleControlPoll -CancelledByEnter ([ref]$cancelled)
        if ($cancelled -and $null -ne $EnterCancel) { $EnterCancel.Value = $true }
        return [bool]$action
    }
    if (-not $AllowEnterCancel -and (Get-Command Test-BatchConsoleEnterKeyPending -ErrorAction SilentlyContinue)) {
        if (Test-BatchConsoleEnterKeyPending) { return $false }
    }
    try {
        if (-not [Console]::KeyAvailable) { return $false }
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Spacebar) {
            [void](Toggle-LeafFfmpegExportSuspend)
            return $true
        }
    } catch {
        # Non-interactive host: no console keys.
    }
    return $false
}
