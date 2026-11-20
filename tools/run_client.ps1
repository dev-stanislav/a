[CmdletBinding()]
param(
    [string]$ServerHost = '',
    [int]$Port = 0,
    [int]$HttpPort = 0,
    [string]$PlayerName = '',
    [string]$Archetype = '',
    [string]$Mode = '',
    [string]$WindowPosition = '',
    [string]$WindowResolution = '',
    [switch]$QuickPlay,
    [switch]$Headless,
    [switch]$VerboseLog,
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ClientDir = Join-Path $RepoRoot 'client'
$ExeName = if ($Headless) { 'Godot_v4.7.2-stable_win64_console.exe' } else { 'Godot_v4.7.2-stable_win64.exe' }
$GodotExe = Join-Path $RepoRoot "tools\godot\$ExeName"

if (-not (Test-Path $GodotExe)) {
    throw "Godot binary not found at '$GodotExe'. Run tools\setup_toolchain.ps1 first."
}
if (-not (Test-Path (Join-Path $ClientDir 'project.godot'))) {
    throw "Godot project.godot not found in '$ClientDir'."
}

$godotArgs = @('--path', $ClientDir)
if ($Headless) {
    $godotArgs += '--headless'
}
if ($VerboseLog) {
    $godotArgs += '--verbose'
}
if (-not [string]::IsNullOrWhiteSpace($WindowPosition)) {
    $godotArgs += @('--position', $WindowPosition)
}
if (-not [string]::IsNullOrWhiteSpace($WindowResolution)) {
    $godotArgs += @('--resolution', $WindowResolution)
}

$userArgs = @()
if (-not [string]::IsNullOrWhiteSpace($ServerHost)) {
    $userArgs += @('--host', $ServerHost)
}
if ($Port -gt 0) {
    $userArgs += @('--port', "$Port")
}
if ($HttpPort -gt 0) {
    $userArgs += @('--http-port', "$HttpPort")
}
if (-not [string]::IsNullOrWhiteSpace($PlayerName)) {
    $userArgs += @('--name', $PlayerName)
}
if (-not [string]::IsNullOrWhiteSpace($Archetype)) {
    $userArgs += @('--archetype', $Archetype)
}
if (-not [string]::IsNullOrWhiteSpace($Mode)) {
    $userArgs += @('--mode', $Mode)
}
if ($QuickPlay) {
    $userArgs += '--quickplay'
}
if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
    $userArgs += $ExtraArgs
}

if ($userArgs.Count -gt 0) {
    $godotArgs += '--'
    $godotArgs += $userArgs
}

Write-Host "[client] Launching $ExeName with args: $($godotArgs -join ' ')"
& $GodotExe @godotArgs
exit $LASTEXITCODE
