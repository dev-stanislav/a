[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ToolsDir = $PSScriptRoot
$TmpDir = Join-Path $ToolsDir '.tmp'
$GodotDir = Join-Path $ToolsDir 'godot'
$PostgresDir = Join-Path $ToolsDir 'postgres'

$GodotVersion = '4.7.2-stable'
$GodotUrl = "https://github.com/godotengine/godot/releases/download/$GodotVersion/Godot_v${GodotVersion}_win64.exe.zip"
$GodotExeName = "Godot_v${GodotVersion}_win64.exe"
$GodotConsoleName = "Godot_v${GodotVersion}_win64_console.exe"

$PgVersion = '16.4.0'
$PgJarUrl = "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-windows-amd64/$PgVersion/embedded-postgres-binaries-windows-amd64-$PgVersion.jar"

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $parent = Split-Path -Parent $OutFile
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path $OutFile) {
        Remove-Item -Path $OutFile -Force
    }
    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fSL --retry 3 --retry-delay 2 -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed downloading $Url (exit code $LASTEXITCODE)"
        }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
        throw "Downloaded file missing or empty: $OutFile"
    }
}

New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {
    # -------------------------------------------------------------------------
    # 1. Godot 4.7.2-stable (Windows 64-bit Standard)
    # -------------------------------------------------------------------------
    $GodotExePath = Join-Path $GodotDir $GodotExeName
    $GodotConsolePath = Join-Path $GodotDir $GodotConsoleName

    if ($Force -or -not (Test-Path $GodotExePath) -or -not (Test-Path $GodotConsolePath)) {
        Write-Host "[setup] Downloading Godot $GodotVersion from $GodotUrl ..."
        $godotZip = Join-Path $TmpDir 'godot_win64.zip'
        Invoke-DownloadFile -Url $GodotUrl -OutFile $godotZip

        if (Test-Path $GodotDir) {
            Remove-Item -Path $GodotDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $GodotDir -Force | Out-Null

        $godotUnpackTmp = Join-Path $TmpDir 'godot_unpack'
        if (Test-Path $godotUnpackTmp) {
            Remove-Item -Path $godotUnpackTmp -Recurse -Force
        }
        Expand-Archive -Path $godotZip -DestinationPath $godotUnpackTmp -Force

        $foundExe = Get-ChildItem -Path $godotUnpackTmp -Filter $GodotExeName -Recurse | Select-Object -First 1
        $foundConsole = Get-ChildItem -Path $godotUnpackTmp -Filter $GodotConsoleName -Recurse | Select-Object -First 1
        if (-not $foundExe -or -not $foundConsole) {
            throw "Expected Godot binaries ($GodotExeName, $GodotConsoleName) not found in archive."
        }
        Copy-Item -Path $foundExe.FullName -Destination $GodotExePath -Force
        Copy-Item -Path $foundConsole.FullName -Destination $GodotConsolePath -Force
        Write-Host "[setup] Installed Godot binaries into $GodotDir"
    } else {
        Write-Host "[setup] Godot binaries already present in $GodotDir"
    }

    $godotVerOutput = (& $GodotConsolePath --version) | Out-String
    $godotVerOutput = $godotVerOutput.Trim()
    if ($LASTEXITCODE -ne 0 -or $godotVerOutput -notmatch '4\.7\.2\.stable') {
        throw "Unexpected Godot --version output (exit $LASTEXITCODE): '$godotVerOutput'"
    }
    Write-Host "[setup] Verified Godot version: $godotVerOutput"

    # -------------------------------------------------------------------------
    # 2. Portable PostgreSQL 16.4 (Windows x64)
    # -------------------------------------------------------------------------
    $PgInitdb = Join-Path $PostgresDir 'bin\initdb.exe'
    $PgCtl = Join-Path $PostgresDir 'bin\pg_ctl.exe'
    $PgPostgres = Join-Path $PostgresDir 'bin\postgres.exe'
    $PgLibPq = Join-Path $PostgresDir 'bin\libpq.dll'

    if ($Force -or -not (Test-Path $PgInitdb) -or -not (Test-Path $PgCtl) -or -not (Test-Path $PgPostgres) -or -not (Test-Path $PgLibPq)) {
        Write-Host "[setup] Downloading PostgreSQL $PgVersion binaries from $PgJarUrl ..."
        # Save as .zip so Expand-Archive opens the JAR (ZIP) cleanly on Windows PowerShell 5.1
        $pgZip = Join-Path $TmpDir 'embedded-postgres-win64.zip'
        Invoke-DownloadFile -Url $PgJarUrl -OutFile $pgZip

        $pgJarUnpack = Join-Path $TmpDir 'pg_jar_unpack'
        if (Test-Path $pgJarUnpack) {
            Remove-Item -Path $pgJarUnpack -Recurse -Force
        }
        Expand-Archive -Path $pgZip -DestinationPath $pgJarUnpack -Force

        $txzFile = Get-ChildItem -Path $pgJarUnpack -Filter '*.txz' -Recurse | Select-Object -First 1
        if (-not $txzFile) {
            throw "Could not locate inner .txz archive inside $PgJarUrl"
        }

        $tarExe = 'C:\Windows\System32\tar.exe'
        if (-not (Test-Path $tarExe)) {
            throw "System tar.exe not found at $tarExe"
        }

        if (Test-Path $PostgresDir) {
            Remove-Item -Path $PostgresDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $PostgresDir -Force | Out-Null

        $pgTxzUnpack = Join-Path $TmpDir 'pg_txz_unpack'
        if (Test-Path $pgTxzUnpack) {
            Remove-Item -Path $pgTxzUnpack -Recurse -Force
        }
        New-Item -ItemType Directory -Path $pgTxzUnpack -Force | Out-Null

        Write-Host "[setup] Unpacking $($txzFile.Name) with $tarExe ..."
        & $tarExe -xf $txzFile.FullName -C $pgTxzUnpack
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe failed unpacking $($txzFile.FullName) (exit code $LASTEXITCODE)"
        }

        $binExe = Get-ChildItem -Path $pgTxzUnpack -Filter 'pg_ctl.exe' -Recurse | Select-Object -First 1
        if (-not $binExe) {
            throw "pg_ctl.exe not found after extracting $($txzFile.Name)"
        }
        $pgExtractedRoot = Split-Path -Parent (Split-Path -Parent $binExe.FullName)
        Get-ChildItem -Path $pgExtractedRoot -Force | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination (Join-Path $PostgresDir $_.Name) -Recurse -Force
        }
        Write-Host "[setup] Installed PostgreSQL binaries into $PostgresDir"
    } else {
        Write-Host "[setup] PostgreSQL binaries already present in $PostgresDir"
    }

    $pgVerOutput = (& $PgPostgres --version) | Out-String
    $pgVerOutput = $pgVerOutput.Trim()
    if ($LASTEXITCODE -ne 0 -or $pgVerOutput -notmatch '16\.4') {
        throw "postgres --version failed or unexpected version (exit $LASTEXITCODE): '$pgVerOutput'"
    }
    Write-Host "[setup] Verified PostgreSQL version: $pgVerOutput"

    # Ensure pg_isready.exe exists in tools\postgres\bin (Zonky archive ships libpq.dll without pg_isready.exe)
    $PgIsReadyExe = Join-Path $PostgresDir 'bin\pg_isready.exe'
    if ($Force -or -not (Test-Path $PgIsReadyExe)) {
        $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (Test-Path $csc) {
            $csPath = Join-Path $TmpDir 'pg_isready.cs'
            $csCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

internal static class PgIsReadyShim {
    [DllImport("libpq.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private static extern int PQping(string conninfo);

    private static int Main(string[] args) {
        string host = "127.0.0.1";
        string port = "5432";
        string user = "postgres";
        string dbname = "postgres";
        string timeout = "3";
        bool quiet = false;

        for (int i = 0; i < args.Length; i++) {
            string a = args[i];
            if ((a == "-h" || a == "--host") && i + 1 < args.Length) host = args[++i];
            else if ((a == "-p" || a == "--port") && i + 1 < args.Length) port = args[++i];
            else if ((a == "-U" || a == "--username") && i + 1 < args.Length) user = args[++i];
            else if ((a == "-d" || a == "--dbname") && i + 1 < args.Length) dbname = args[++i];
            else if ((a == "-t" || a == "--timeout") && i + 1 < args.Length) timeout = args[++i];
            else if (a == "-q" || a == "--quiet") quiet = true;
            else if (a == "-V" || a == "--version") {
                Console.WriteLine("pg_isready (PostgreSQL) 16.4 (libpq)");
                return 0;
            }
        }

        string conn = string.Format("host={0} port={1} user={2} dbname={3} connect_timeout={4}", host, port, user, dbname, timeout);
        int rc = PQping(conn);
        if (!quiet) {
            string msg = rc == 0 ? "accepting connections"
                       : rc == 1 ? "rejecting connections"
                       : rc == 2 ? "no response"
                       : "no attempt";
            Console.WriteLine("{0}:{1} - {2}", host, port, msg);
        }
        return rc;
    }
}
'@
            Set-Content -Path $csPath -Value $csCode -Encoding UTF8
            & $csc /nologo /optimize+ /platform:x64 /target:exe "/out:$PgIsReadyExe" $csPath | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $PgIsReadyExe)) {
                throw "Failed building pg_isready.exe wrapper against libpq.dll"
            }
            Write-Host "[setup] Built pg_isready.exe (libpq PQping) in $(Split-Path -Parent $PgIsReadyExe)"
        }
    }
}
finally {
    if (Test-Path $TmpDir) {
        Remove-Item -Path $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
