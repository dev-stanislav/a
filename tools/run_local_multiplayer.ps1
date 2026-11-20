[CmdletBinding()]
param(
    [ValidateRange(1, 6)]
    [int]$ClientCount = 2,
    [int]$UdpPort = 7777,
    [int]$HttpPort = 8080,
    [int]$WindowWidth = 920,
    [int]$WindowHeight = 540,
    [switch]$EphemeralDb,
    [switch]$NoServer,
    [switch]$DebugServer
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ClientDir = Join-Path $RepoRoot 'client'
$GodotExe = Join-Path $RepoRoot 'tools\godot\Godot_v4.7.2-stable_win64.exe'

if (-not (Test-Path $GodotExe)) {
    throw "Godot binary not found at '$GodotExe'. Run tools\setup_toolchain.ps1 first."
}

$ArchetypeCycle = @('speedster', 'sharpshooter', 'playmaker', 'powerhouse', 'all_rounder', 'speedster')
$CallsignCycle = @('Volt', 'Deadeye', 'Mirage', 'Titan', 'Eclipse', 'Phantom')

$serverProc = $null
if (-not $NoServer) {
    if (-not $EphemeralDb) {
        & (Join-Path $PSScriptRoot 'start_local_pg.ps1')
    }

    $serverScript = Join-Path $PSScriptRoot 'start_server.ps1'
    $serverArgsList = @(
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$serverScript`"",
        '-UdpPort', "$UdpPort",
        '-HttpPort', "$HttpPort",
        '-UsePrebuiltBinary',
        '-SkipPgStart'
    )
    if (-not $DebugServer) {
        $releaseExe = Join-Path $RepoRoot 'server\target\release\phantom-court-server.exe'
        if (Test-Path $releaseExe) {
            $serverArgsList += '-Release'
        }
    }
    if ($EphemeralDb) {
        $serverArgsList += '-EphemeralDb'
    }

    Write-Host "[multiplayer] Launching authoritative server window (UDP=$UdpPort, HTTP=$HttpPort)..."
    $serverProc = Start-Process -FilePath 'powershell.exe' -ArgumentList ($serverArgsList -join ' ') -WorkingDirectory $RepoRoot -PassThru

    $healthUrl = "http://127.0.0.1:${HttpPort}/health"
    $ready = $false
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        Start-Sleep -Milliseconds 700
        try {
            $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {
            # Server still compiling or binding
        }
    }
    if (-not $ready) {
        Write-Warning "[multiplayer] Server health endpoint $healthUrl did not respond within ~30s; launching clients anyway."
    } else {
        Write-Host "[multiplayer] Server healthy at $healthUrl (200 OK)"
    }
}

$clientPids = @()
for ($i = 1; $i -le $ClientCount; $i++) {
    $idx = ($i - 1) % $ArchetypeCycle.Count
    $arch = $ArchetypeCycle[$idx]
    $playerName = "$($CallsignCycle[$idx])$i"

    $col = ($i - 1) % 2
    $row = [math]::Floor(($i - 1) / 2)
    $posX = 30 + ($col * ($WindowWidth + 24))
    $posY = 40 + ($row * ($WindowHeight - 40))

    $clientArgs = @(
        '--path', "`"$ClientDir`"",
        '--resolution', "${WindowWidth}x${WindowHeight}",
        '--position', "${posX},${posY}",
        '--',
        '--host', '127.0.0.1',
        '--port', "$UdpPort",
        '--http-port', "$HttpPort",
        '--name', $playerName,
        '--archetype', $arch
    )
    Write-Host "[multiplayer] Launching Client #$i -> Name='$playerName' Archetype='$arch' Window=${WindowWidth}x${WindowHeight}@(${posX},${posY})..."
    $proc = Start-Process -FilePath $GodotExe -ArgumentList $clientArgs -WorkingDirectory $RepoRoot -PassThru
    $clientPids += $proc.Id
    Start-Sleep -Milliseconds 350
}

Write-Host ""
Write-Host "========================================================================"
Write-Host " PHANTOM COURT ONLINE — Local Multiplayer Testbed Active"
Write-Host "------------------------------------------------------------------------"
Write-Host " Server Endpoints : UDP 127.0.0.1:$UdpPort  |  HTTP http://127.0.0.1:$HttpPort/health"
if ($serverProc) {
    Write-Host " Server Window PID: $($serverProc.Id)"
}
Write-Host " Client PIDs      : $($clientPids -join ', ')"
Write-Host "------------------------------------------------------------------------"
Write-Host " How to test:"
Write-Host "   1. In each client window, click ONLINE MATCHMAKING."
Write-Host "   2. Queue Ranked 1v1/2v2/3v3 (with 'Fill Empty Slots with Server AI' if desired)"
Write-Host "      OR Create a Private Room in Client 1 and Join by 6-char Code in Client 2!"
Write-Host "   3. Toggle READY UP in the Lobby and click ENTER COURT."
Write-Host " Teardown when finished:"
Write-Host "   - Close client & server windows (or Stop-Process -Id $($clientPids -join ','))"
if (-not $EphemeralDb -and -not $NoServer) {
    Write-Host "   - Stop local PostgreSQL: powershell -ExecutionPolicy Bypass -File .\tools\stop_local_pg.ps1"
}
Write-Host "========================================================================"
