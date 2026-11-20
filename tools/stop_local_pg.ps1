[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$env:LC_ALL = 'C'
$env:LC_MESSAGES = 'C'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PgCtl = Join-Path $RepoRoot 'tools\postgres\bin\pg_ctl.exe'
$DataDir = Join-Path $RepoRoot '.pgdata'

if (-not (Test-Path $PgCtl)) {
    throw "pg_ctl.exe not found at '$PgCtl'. Run tools\setup_toolchain.ps1 first."
}

if (-not (Test-Path (Join-Path $DataDir 'PG_VERSION'))) {
    Write-Host "[pg] No initialized cluster found at $DataDir. Nothing to stop."
    exit 0
}

& $PgCtl status -D $DataDir | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[pg] PostgreSQL is not running."
    exit 0
}

Write-Host "[pg] Stopping PostgreSQL cluster in $DataDir ..."
& $PgCtl stop -D $DataDir -m fast -w
if ($LASTEXITCODE -ne 0) {
    throw "pg_ctl.exe stop failed with exit code $LASTEXITCODE"
}

Write-Host "[pg] Stopped cleanly."
