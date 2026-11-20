[CmdletBinding()]
param(
    [string]$BindHost = '127.0.0.1',
    [int]$Port = 15432,
    [string]$Database = 'phantom_court',
    [string]$User = 'postgres'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PgBinDir = Join-Path $RepoRoot 'tools\postgres\bin'
$DataDir = Join-Path $RepoRoot '.pgdata'
$LogFile = Join-Path $DataDir 'postgres.log'

$Initdb = Join-Path $PgBinDir 'initdb.exe'
$PgCtl = Join-Path $PgBinDir 'pg_ctl.exe'
$Postgres = Join-Path $PgBinDir 'postgres.exe'
$PgIsReady = Join-Path $PgBinDir 'pg_isready.exe'
$Psql = Join-Path $PgBinDir 'psql.exe'
$LibPq = Join-Path $PgBinDir 'libpq.dll'

foreach ($required in @($Initdb, $PgCtl, $Postgres, $LibPq)) {
    if (-not (Test-Path $required)) {
        throw "PostgreSQL binary missing at '$required'. Run tools\setup_toolchain.ps1 first."
    }
}

$env:PATH = "$PgBinDir;$env:PATH"
$env:LC_ALL = 'C'
$env:LC_MESSAGES = 'C'

function Initialize-LibPqBridge {
    if (-not ('PhantomPg.LibPq' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace PhantomPg {
    public static class LibPq {
        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        public static extern int PQping(string conninfo);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        public static extern IntPtr PQconnectdb(string conninfo);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int PQstatus(IntPtr conn);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        public static extern IntPtr PQexec(IntPtr conn, string query);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int PQresultStatus(IntPtr res);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int PQntuples(IntPtr res);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr PQgetvalue(IntPtr res, int rowNumber, int columnNumber);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr PQerrorMessage(IntPtr conn);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern void PQclear(IntPtr res);

        [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern void PQfinish(IntPtr conn);

        public static string PtrToAnsi(IntPtr ptr) {
            return ptr == IntPtr.Zero ? string.Empty : Marshal.PtrToStringAnsi(ptr);
        }
    }
}
"@
    }
}

$PgVersionFile = Join-Path $DataDir 'PG_VERSION'
if (-not (Test-Path $PgVersionFile)) {
    if ((Test-Path $DataDir) -and (Get-ChildItem -Force $DataDir | Measure-Object).Count -gt 0) {
        throw "Data directory '$DataDir' exists and is not empty, yet PG_VERSION is missing."
    }
    Write-Host "[pg] Initializing database cluster in $DataDir ..."
    & $Initdb --locale=C --encoding=UTF8 -A trust -U $User -D $DataDir
    if ($LASTEXITCODE -ne 0) {
        throw "initdb.exe failed with exit code $LASTEXITCODE"
    }
}

& $PgCtl status -D $DataDir | Out-Null
$isRunning = ($LASTEXITCODE -eq 0)

if (-not $isRunning) {
    Write-Host "[pg] Starting PostgreSQL on ${BindHost}:${Port} ..."
    $pgOpts = "-h $BindHost -p $Port"
    & $PgCtl start -D $DataDir -l $LogFile -o $pgOpts -w
    if ($LASTEXITCODE -ne 0) {
        throw "pg_ctl.exe start failed with exit code $LASTEXITCODE. Check $LogFile"
    }
} else {
    Write-Host "[pg] PostgreSQL cluster is already running."
}

$connInfo = "host=$BindHost port=$Port user=$User dbname=postgres connect_timeout=5"

if (Test-Path $PgIsReady) {
    & $PgIsReady -h $BindHost -p $Port -U $User
    if ($LASTEXITCODE -ne 0) {
        throw "pg_isready.exe failed for ${BindHost}:${Port} (exit code $LASTEXITCODE)"
    }
} else {
    Initialize-LibPqBridge
    $ping = [PhantomPg.LibPq]::PQping($connInfo)
    if ($ping -ne 0) {
        throw "libpq PQping failed for ${BindHost}:${Port} (status=$ping)"
    }
    Write-Host "[pg] ${BindHost}:${Port} - accepting connections (PQping=0 OK)"
}

if (Test-Path $Psql) {
    $dbExists = (& $Psql -h $BindHost -p $Port -U $User -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$Database'") | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Failed checking database '$Database' (exit code $LASTEXITCODE)"
    }
    if ($dbExists.Trim() -ne '1') {
        Write-Host "[pg] Creating database '$Database' ..."
        & $Psql -h $BindHost -p $Port -U $User -d postgres -c "CREATE DATABASE $Database;"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed creating database '$Database' (exit code $LASTEXITCODE)"
        }
    } else {
        Write-Host "[pg] Database '$Database' already exists."
    }
} else {
    Initialize-LibPqBridge
    $conn = [PhantomPg.LibPq]::PQconnectdb($connInfo)
    try {
        if ($conn -eq [IntPtr]::Zero -or [PhantomPg.LibPq]::PQstatus($conn) -ne 0) {
            $err = [PhantomPg.LibPq]::PtrToAnsi([PhantomPg.LibPq]::PQerrorMessage($conn))
            throw "Failed connecting to PostgreSQL via libpq: $err"
        }
        $checkRes = [PhantomPg.LibPq]::PQexec($conn, "SELECT 1 FROM pg_database WHERE datname = '$Database';")
        try {
            if ([PhantomPg.LibPq]::PQresultStatus($checkRes) -ne 2) {
                $err = [PhantomPg.LibPq]::PtrToAnsi([PhantomPg.LibPq]::PQerrorMessage($conn))
                throw "Failed querying pg_database: $err"
            }
            $hasDb = ([PhantomPg.LibPq]::PQntuples($checkRes) -gt 0)
        }
        finally {
            [PhantomPg.LibPq]::PQclear($checkRes)
        }

        if (-not $hasDb) {
            Write-Host "[pg] Creating database '$Database' ..."
            $createRes = [PhantomPg.LibPq]::PQexec($conn, "CREATE DATABASE $Database;")
            try {
                if ([PhantomPg.LibPq]::PQresultStatus($createRes) -ne 1) {
                    $err = [PhantomPg.LibPq]::PtrToAnsi([PhantomPg.LibPq]::PQerrorMessage($conn))
                    throw "Failed creating database '$Database': $err"
                }
            }
            finally {
                [PhantomPg.LibPq]::PQclear($createRes)
            }
        } else {
            Write-Host "[pg] Database '$Database' already exists."
        }
    }
    finally {
        if ($conn -ne [IntPtr]::Zero) {
            [PhantomPg.LibPq]::PQfinish($conn)
        }
    }
}

Write-Host "[pg] Ready: postgres://${User}@${BindHost}:${Port}/${Database}"
