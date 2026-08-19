#Requires -Version 5.1
# Shared prepare/chase wait heartbeat: interval from source duration + log tail status hints.
$PrepareWaitHeartbeatDivisorDefault = 5

function Get-PrepareWaitHeartbeatDivisorDefault {
    if ($PrepareWaitHeartbeatDivisorDefault -gt 0) { return $PrepareWaitHeartbeatDivisorDefault }
    return 5
}

function Get-PrepareLogTailText {
    param(
        [string] $StdOutPath,
        [int] $MaxChars = 24576
    )
    if ([string]::IsNullOrWhiteSpace($StdOutPath) -or -not (Test-Path -LiteralPath $StdOutPath -PathType Leaf)) {
        return ''
    }
    try {
        $fs = [System.IO.File]::Open($StdOutPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -le 0) { return '' }
            $readLen = [Math]::Min($len, $MaxChars)
            [void]$fs.Seek($len - $readLen, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] $readLen
            [void]$fs.Read($buf, 0, $readLen)
            return [System.Text.Encoding]::UTF8.GetString($buf)
        } finally {
            $fs.Dispose()
        }
    } catch {
        try {
            return ((Get-Content -LiteralPath $StdOutPath -Tail 40 -ErrorAction Stop) -join "`n")
        } catch {
            return ''
        }
    }
}

function Get-PrepareLogStatusHint {
    param([string] $StdOutPath)
    $joined = Get-PrepareLogTailText -StdOutPath $StdOutPath -MaxChars 4096
    if ([string]::IsNullOrWhiteSpace($joined)) { return 'no log output yet' }
    $lines = @($joined -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return 'no log output yet' }
    $last = $lines[-1].Trim()
    if ($last.Length -gt 120) { $last = $last.Substring(0, 117) + '...' }
    return $last
}

function Get-PrepareMediaDurationSeconds {
    param([string] $MediaFullPath)
    if ([string]::IsNullOrWhiteSpace($MediaFullPath) -or -not (Test-Path -LiteralPath $MediaFullPath -PathType Leaf)) {
        return $null
    }
    $ffprobeExe = $null
    if (Get-Command Get-BatchFfprobeExePath -ErrorAction SilentlyContinue) {
        $ffprobeExe = Get-BatchFfprobeExePath
    }
    if ([string]::IsNullOrWhiteSpace($ffprobeExe)) {
        $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { $ffprobeExe = $cmd.Source }
    }
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

function Resolve-PrepareWaitHeartbeatSeconds {
    param(
        [string] $MediaFullPath = '',
        [int] $FixedHeartbeatSec = 0,
        [int] $Divisor = $(Get-PrepareWaitHeartbeatDivisorDefault)
    )
    if ($FixedHeartbeatSec -gt 0) { return $FixedHeartbeatSec }
    if ($Divisor -le 0) { return 60 }
    $durSec = $null
    if (Get-Command Get-BatchMediaDurationSeconds -ErrorAction SilentlyContinue) {
        $durSec = Get-BatchMediaDurationSeconds -MediaFullPath $MediaFullPath
    }
    if ($null -eq $durSec) {
        $durSec = Get-PrepareMediaDurationSeconds -MediaFullPath $MediaFullPath
    }
    if ($null -eq $durSec -or $durSec -le 0) { return 60 }
    $n = [int][Math]::Ceiling($durSec / [double]$Divisor)
    if ($n -lt 1) { return 1 }
    return $n
}
