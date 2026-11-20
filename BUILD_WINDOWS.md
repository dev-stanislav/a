# Windows 10/11 (x64) Build, Test & Packaging Guide

This guide covers complete setup, compilation, local PostgreSQL 16 administration, local multiplayer execution, automated verification, hardware benchmarking, and standalone `.exe` packaging on **Windows 10 / 11 (64-bit)**.

---

## 1. Prerequisites

- **OS:** Windows 10 or Windows 11 (64-bit) with PowerShell 5.1+ and `C:\Windows\System32\tar.exe` (included in Windows).
- **Rust & MSVC Linker:** `rustup` with stable `x86_64-pc-windows-msvc` (`rustc` / `cargo`) and Visual Studio C++ Build Tools.
- **Git:** Git for Windows.

> **No manual Godot or PostgreSQL installation needed:** `tools\setup_toolchain.ps1` automatically downloads and verifies official **Godot 4.7.2-stable (win64)** and portable **PostgreSQL 16.4 (win64)** inside `tools\godot\` and `tools\postgres\`.

---

## 2. Install Portable Toolchain (Godot 4.7.2 + PostgreSQL 16.4)

From the repository root (`phantom-court-online`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\setup_toolchain.ps1
```

This installs and verifies:
- `tools\godot\Godot_v4.7.2-stable_win64.exe` (Windowed GUI runtime & editor)
- `tools\godot\Godot_v4.7.2-stable_win64_console.exe` (Console/headless test & export binary)
- `tools\postgres\bin\{initdb.exe, pg_ctl.exe, postgres.exe, pg_isready.exe, libpq.dll}` (`PostgreSQL 16.4`)

Pass `-Force` to re-download and re-extract cleanly.

---

## 3. Local PostgreSQL 16.4 Management

- **Initialize `.pgdata` (first run) & start PostgreSQL on `127.0.0.1:15432`:**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_local_pg.ps1
  ```
  - Creates database `phantom_court` automatically if missing.
  - Default URL: `postgres://postgres@127.0.0.1:15432/phantom_court`
  - Logs to `.pgdata\postgres.log`.

- **Check readiness directly:**
  ```powershell
  .\tools\postgres\bin\pg_isready.exe -h 127.0.0.1 -p 15432
  ```

- **Stop PostgreSQL cleanly:**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\stop_local_pg.ps1
  ```

---

## 4. Build & Run the Authoritative Rust Dedicated Server

### Compile Debug & Release Binaries
```powershell
Push-Location .\server
cargo build
cargo build --release
Pop-Location
```
Output binaries:
- Release: `server\target\release\phantom-court-server.exe`
- Debug: `server\target\debug\phantom-court-server.exe`

### Start the Server
- **With local PostgreSQL 16 persistence (auto-starts PG if needed):**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_server.ps1 -Release -UsePrebuiltBinary
  ```
- **In-memory ephemeral mode (no PostgreSQL required):**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_server.ps1 -Release -UsePrebuiltBinary -EphemeralDb
  ```
- **Health Check:**
  ```powershell
  Invoke-RestMethod -Uri http://127.0.0.1:8080/health
  ```

Supported server flags / env vars:
- `--bind` / `PCO_BIND_ADDR` (default `0.0.0.0`)
- `--udp-port` / `PCO_UDP_PORT` (default `7777`)
- `--http-port` / `PCO_HTTP_PORT` (default `8080`)
- `--tick-rate` / `PCO_TICK_RATE` (default `60`)
- `--snapshot-rate` / `PCO_SNAPSHOT_RATE` (default `30`)
- `DATABASE_URL` / `--ephemeral-db`

---

## 5. Run the Godot Client & Local Multiplayer Testbed

### Single Client Window
```powershell
# Boot into Main Menu
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_client.ps1

# Boot directly into an offline court match (--quickplay)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_client.ps1 -QuickPlay -Archetype sharpshooter -Mode 3v3
```

### One-Command Local Multiplayer (Server + N Side-by-Side Clients)
Starts portable PostgreSQL 16.4, launches `phantom-court-server.exe`, waits for `GET /health` `200 OK`, and opens tiled `920×540` client windows with distinct callsigns and archetypes:

```powershell
# Launch 2 clients + PostgreSQL + Release Server
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_local_multiplayer.ps1 -ClientCount 2

# Launch 4 clients for 2v2 testing (ephemeral DB mode)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_local_multiplayer.ps1 -ClientCount 4 -EphemeralDb
```
When finished, close the client/server windows and stop PostgreSQL via `.\tools\stop_local_pg.ps1`.

---

## 6. Run the Automated Test Suites

### Full Godot Client Test Suite (1,751 Assertions across Phases 1–14)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_local_pg.ps1
try {
    .\tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path client -s res://tests/run_all_tests.gd
} finally {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\stop_local_pg.ps1
}
```
Run a single phase suite with `-- --filter`:
```powershell
.\tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path client -s res://tests/run_all_tests.gd -- --filter test_phase14
```

### Full Rust Server Test Suite (18 Unit, Sim, Net, Lobby, PostgreSQL & Load Tests)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_local_pg.ps1
Push-Location .\server
try {
    cargo test
} finally {
    Pop-Location
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\stop_local_pg.ps1
}
```

---

## 7. Run Real Hardware GPU & 120-Client Server Load Benchmarks

### Windowed Forward+ Vulkan GPU Benchmark (600 Frames, 3v3 + Dual Zone)
*(Requires an interactive desktop GPU session — runs windowed without `--headless`)*
```powershell
.\tools\godot\Godot_v4.7.2-stable_win64_console.exe --path client -s res://tests/fps_benchmark.gd
```

### Authoritative Server 20-Room / 120-Client 60 Hz Load Benchmark
```powershell
Push-Location .\server
cargo test --release --test load_bench -- --nocapture
Pop-Location
```
Full measured output is documented in `tools\benchmarks\BENCHMARK_RESULTS.md`.

---

## 8. Export Standalone Windows Desktop `.exe`

`client\export_presets.cfg` defines the `"Windows Desktop"` x86_64 preset targeting `builds\windows\PhantomCourtOnline.exe` (`embed_pck=true`, `tests/*` excluded).

1. Ensure Godot `4.7.2.stable` export templates are installed under `%APPDATA%\Godot\export_templates\4.7.2.stable\` (download `Godot_v4.7.2-stable_export_templates.tpz` from the official Godot 4.7.2 GitHub release and extract its `templates/` contents there, or install via **Editor -> Manage Export Templates** in `tools\godot\Godot_v4.7.2-stable_win64.exe --editor --path client`).
2. Build the standalone Windows executable:
   ```powershell
   New-Item -ItemType Directory -Path .\builds\windows -Force | Out-Null
   .\tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path client --export-release "Windows Desktop" ..\builds\windows\PhantomCourtOnline.exe
   ```
3. Distribute `builds\windows\PhantomCourtOnline.exe` alongside `server\target\release\phantom-court-server.exe` for dedicated server hosting.
