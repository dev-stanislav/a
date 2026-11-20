[CmdletBinding()]
param(
    [string]$BindAddr = '0.0.0.0',
    [int]$UdpPort = 7777,
    [int]$HttpPort = 8080,
    [int]$TickRate = 60,
    [int]$SnapshotRate = 30,
    [string]$DatabaseUrl = '',
    [switch]$Release,
    [switch]$UsePrebuiltBinary,
    [switch]$SkipPgStart,
    [switch]$EphemeralDb
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $RepoRoot 'server'
$CargoToml = Join-Path $ServerDir 'Cargo.toml'

if (-not (Test-Path $CargoToml)) {
    throw "Rust server Cargo.toml not found at '$CargoToml'. Ensure the server crate is present."
}

if (-not $EphemeralDb) {
    if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
        if (-not [string]::IsNullOrWhiteSpace($env:DATABASE_URL)) {
            $DatabaseUrl = $env:DATABASE_URL
        } else {
            $DatabaseUrl = 'postgres://postgres@127.0.0.1:15432/phantom_court'
        }
    }

    if (-not $SkipPgStart -and $DatabaseUrl -match '127\.0\.0\.1:15432') {
        & (Join-Path $PSScriptRoot 'start_local_pg.ps1')
    }
    $env:DATABASE_URL = $DatabaseUrl
} else {
    Remove-Item Env:\DATABASE_URL -ErrorAction SilentlyContinue
}

$env:PCO_BIND_ADDR = $BindAddr
$env:PCO_UDP_PORT = "$UdpPort"
$env:PCO_HTTP_PORT = "$HttpPort"
$env:PCO_TICK_RATE = "$TickRate"
$env:PCO_SNAPSHOT_RATE = "$SnapshotRate"
if ([string]::IsNullOrWhiteSpace($env:RUST_LOG)) {
    $env:RUST_LOG = 'info'
}

$profileDir = if ($Release) { 'release' } else { 'debug' }
$prebuiltExe = Join-Path $ServerDir "target\$profileDir\phantom-court-server.exe"

Write-Host "[server] Starting Phantom Court Online server (Bind=$BindAddr, UDP=$UdpPort, HTTP=$HttpPort, Tick=$TickRate Hz, Snap=$SnapshotRate Hz, EphemeralDb=$EphemeralDb)..."

if ($UsePrebuiltBinary -and (Test-Path $prebuiltExe)) {
    $binArgs = @(
        '--bind', $BindAddr,
        '--udp-port', "$UdpPort",
        '--http-port', "$HttpPort",
        '--tick-rate', "$TickRate",
        '--snapshot-rate', "$SnapshotRate"
    )
    if ($EphemeralDb) {
        $binArgs += '--ephemeral-db'
    }
    & $prebuiltExe @binArgs
    exit $LASTEXITCODE
}

$cargoArgs = @('run')
if ($Release) {
    $cargoArgs += '--release'
}
$cargoArgs += @(
    '--',
    '--bind', $BindAddr,
    '--udp-port', "$UdpPort",
    '--http-port', "$HttpPort",
    '--tick-rate', "$TickRate",
    '--snapshot-rate', "$SnapshotRate"
)
if ($EphemeralDb) {
    $cargoArgs += '--ephemeral-db'
}

Push-Location $ServerDir
try {
    & cargo @cargoArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
