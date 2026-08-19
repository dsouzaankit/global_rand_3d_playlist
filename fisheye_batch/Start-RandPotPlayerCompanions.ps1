#Requires -Version 5.1
# Launch triple-click PotPlayer close helper (.exe or .ahk fallback).

function Resolve-AutoHotkeyRuntime {
    param([string] $SearchDir = '')
    foreach ($exeName in @('AutoHotkey64.exe', 'AutoHotkey32.exe', 'AutoHotkey.exe')) {
        if (-not [string]::IsNullOrWhiteSpace($SearchDir)) {
            $candidate = Join-Path $SearchDir $exeName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
        $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
        if ($cmd -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
            return $cmd.Source
        }
    }
    return $null
}

function Start-RandPotPlayerCompanions {
    param(
        [string] $CompanionFolder,
        [switch] $DryRun
    )
    if ($DryRun) {
        Write-Host "DryRun: would start companions from $CompanionFolder"
        return $false
    }
    if (-not (Test-Path -LiteralPath $CompanionFolder -PathType Container)) {
        Write-Warning "Companion folder missing: $CompanionFolder"
        return $false
    }

    $runtimeExeNames = @('AutoHotkey64.exe', 'AutoHotkey32.exe', 'AutoHotkey.exe')
    $started = 0
    foreach ($exe in @(Get-ChildItem -LiteralPath $CompanionFolder -File -Filter '*.exe' -ErrorAction SilentlyContinue)) {
        if ($runtimeExeNames -contains $exe.Name) { continue }
        try {
            Write-Host "  -> $($exe.Name)"
            Start-Process -FilePath $exe.FullName -WorkingDirectory $CompanionFolder | Out-Null
            $started++
        } catch {
            Write-Warning "Could not start $($exe.Name): $_"
        }
    }
    if ($started -gt 0) {
        Write-Host "Companion executables started: $started"
        return $true
    }

    $ahk = Resolve-AutoHotkeyRuntime -SearchDir $CompanionFolder
    if ([string]::IsNullOrWhiteSpace($ahk)) {
        $ahk = Resolve-AutoHotkeyRuntime
    }
    if ([string]::IsNullOrWhiteSpace($ahk)) {
        Write-Warning 'No AutoHotkey runtime found; triple-click close unavailable (use File > Exit).'
        return $false
    }

    $scripts = @('PotPlayer-TripleLButton-Close.ahk')
    foreach ($scriptName in $scripts) {
        $scriptPath = Join-Path $CompanionFolder $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { continue }
        try {
            Write-Host "  -> $scriptName (via $([System.IO.Path]::GetFileName($ahk)))"
            Start-Process -FilePath $ahk -ArgumentList "`"$scriptPath`"" -WorkingDirectory $CompanionFolder | Out-Null
            $started++
        } catch {
            Write-Warning "Could not start $scriptName : $_"
        }
    }
    return ($started -gt 0)
}
