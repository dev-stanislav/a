# PHANTOM COURT ONLINE — Canonical Architecture & Studio Contracts

This document defines the canonical simulation constants, scene/physics geometry, input/network structures, autoload APIs, and engineering rules for **Phantom Court Online**. Every client module, Rust server module, VFX/audio hook, and automated test MUST build against these exact contracts.

---

## 1. Repository Layout & Ownership Boundaries

```text
phantom-court-online/
├── ARCHITECTURE.md            # Canonical contracts (infra-shared)
├── BUILD_WINDOWS.md           # Windows toolchain & build guide (infra-shared)
├── PROGRESS.md                # Milestone & integration tracker (infra-shared)
├── README.md                  # Project overview & quickstart (infra-shared)
├── .gitignore                 # Ignores tools/godot, tools/postgres, .pgdata, etc.
├── tools/
│   ├── setup_toolchain.ps1    # Downloads Godot 4.7.2 + portable PostgreSQL 16.4
│   ├── start_local_pg.ps1     # Initializes & starts PG on 127.0.0.1:15432
│   ├── stop_local_pg.ps1      # Stops local PG cleanly
│   ├── start_server.ps1       # Runs Rust authoritative/backend server
│   ├── run_client.ps1         # Launches Godot client with CLI flags
│   └── run_local_multiplayer.ps1
├── client/                    # Godot 4.7.2-stable project
│   ├── project.godot
│   ├── icon.svg
│   ├── export_presets.cfg
│   ├── scenes/
│   │   ├── main.tscn          # Boot router owned by infra-shared
│   │   ├── court/             # Arena, hoops, scoreboard, court visuals
│   │   ├── characters/        # Player rig, visuals, animations
│   │   ├── vfx/               # Zone aura, trails, dunk shockwaves, sparks
│   │   └── ui/                # HUD, lobby, combo wheel, pause, end-screen
│   ├── scripts/
│   │   ├── main.gd            # Boot router owned by infra-shared
│   │   ├── autoload/
│   │   │   ├── event_bus.gd   # Canonical signal bus (infra-shared)
│   │   │   ├── game_state.gd  # Session/match/player/net state (infra-shared)
│   │   │   └── config_manager.gd # Graphics/audio/input/server config (infra-shared)
│   │   ├── court/             # Court/hoop/ball physics & match rules
│   │   ├── player/            # player_controller.gd, camera, animation
│   │   ├── combos/            # Dribble combos, skills, archetypes, Zone
│   │   ├── ai/                # Offline bot AI & input providers
│   │   ├── vfx/               # Procedural VFX & camera shake
│   │   ├── audio/             # Procedural SFX & dynamic music
│   │   ├── ui/                # HUD, menus, lobby, leaderboard UI
│   │   └── net/               # UDP prediction/reconciliation & HTTP REST client
│   └── tests/                 # Headless Godot test scripts (-s, quit(0/1))
└── server/                    # Rust workspace/crate (UDP game server + Axum HTTP + SQLx PG)
```

---

## 2. Physics & Simulation Tick Contract

- **Fixed Simulation Rate:** `60 Hz` (`dt = 1.0 / 60.0 = 0.0166666667 s`)
- **Godot Project Setting:** `physics/common/physics_ticks_per_second=60`
- **Authoritative Server Tick:** `60 Hz` (`tick: u64`, 1 tick = `1.0 / 60.0` seconds)
- Client prediction and server reconciliation MUST step using identical constants and the exact `dt = 1.0 / 60.0` fixed step.

---

## 3. Court, Hoop, and Scoring Geometry

Coordinate system: Godot right-handed Y-up (`+Y` up, `+X` right, `+Z` toward Hoop A).

### 3.1 Court Dimensions
- **Floor Plane:** `y = 0.0`
- **Playable Bounds:**
  - `x in [-7.5, +7.5]` (`15.0 m` width)
  - `z in [-14.0, +14.0]` (`28.0 m` length)
  - Center court: `(0.0, 0.0, 0.0)`

### 3.2 Hoops & Backboards
- **Hoop A** (Team `0` defends, Team `1` attacks):
  - Rim Center: `Vector3(0.0, 3.05, +12.425)`
  - Backboard Front Plane: `z = +12.80` (facing `-Z`)
- **Hoop B** (Team `1` defends, Team `0` attacks):
  - Rim Center: `Vector3(0.0, 3.05, -12.425)`
  - Backboard Front Plane: `z = -12.80` (facing `+Z`)
- **Rim Collider Specification:**
  - Inner Rim Radius: `0.225 m` (`0.45 m` diameter)
  - **CRITICAL:** The rim collider MUST be constructed from **12 discrete collider segments arranged in a hollow circle** (e.g., capsules/boxes around radius `0.225m + tube_radius`). **NEVER** use a solid cylinder for the rim collider, or shots cannot pass cleanly through the hoop.
- **Backboard Specification:**
  - Dimensions: `1.80 m` wide (`x in [-0.90, +0.90]`) × `1.05 m` tall (`y in [2.90, 3.95]`)
  - Bottom Edge Height: `y = 2.90 m`

### 3.3 Scoring Validation & 2pt / 3pt Line
- **Hoop Pass-Through Validation:**
  - Each hoop has two horizontal sensor gates centered at the rim XZ:
    - `UpperGate` at `y = 3.08 m`
    - `LowerGate` at `y = 2.86 m`
  - A basket is valid **ONLY** when the ball crosses `UpperGate` and then `LowerGate` within `0.60 s` while `ball.linear_velocity.y < 0.0` (downward motion).
- **2-Point vs 3-Point Classification:**
  - Evaluated from the shooter's horizontal floor position at shot takeoff/release relative to the target hoop's rim center `(0.0, 3.05, rim_z)`:
  - `dist_xz = Vector2(shot_pos.x, shot_pos.z).distance_to(Vector2(0.0, rim_z))`
  - **3-Pointer** if `dist_xz > 6.75` OR corner three `abs(shot_pos.x) > 6.60` (on the attacking half).
  - Otherwise **2-Pointer**.

---

## 4. Ball Physics & State Machine

- **Radius:** `0.12 m`
- **Mass:** `0.62 kg`
- **Gravity:** `9.81 m/s^2` (`Vector3(0.0, -9.81, 0.0)`)
- **Restitution (Bounce):**
  - Floor: `0.78`
  - Rim: `0.58`
  - Backboard: `0.65`
- **Aerodynamics:** Linear air drag + Magnus spin force (`F_magnus` proportional to `angular_velocity.cross(linear_velocity)`).
- **Canonical Ball States (`BallState`):**
  1. `FREE` — Loose ball governed by physics & bounce.
  2. `HELD` — Securely held in carrier's hands (triple threat / post / gather).
  3. `DRIBBLING` — Controlled dribble synchronized with carrier movement & hand bounce.
  4. `PASS_FLIGHT` — In flight toward a target teammate / lead position.
  5. `SHOT_FLIGHT` — Arced shot flight subject to gravity, air drag, Magnus spin, and rim/backboard collision.
  6. `DUNK_LOCKED` — Locked to a dunking player during dunk animation until slam release at the rim.

---

## 5. InputMap & Canonical `PlayerInputFrame`

### 5.1 Godot `InputMap` Actions
Defined in `client/project.godot`:

| Action | Default Bindings | Button Bitmask |
| :--- | :--- | :--- |
| `move_forward` | `W` | (axis) |
| `move_back` | `S` | (axis) |
| `move_left` | `A` | (axis) |
| `move_right` | `D` | (axis) |
| `sprint` | `Shift` | `1` (`1 << 0`) |
| `jump` | `Space` | `2` (`1 << 1`) |
| `shoot` | `Left Mouse Button`, `J` | `4` (`1 << 2`) |
| `pass_ball` | `Right Mouse Button`, `K` | `8` (`1 << 3`) |
| `skill_q` | `Q` | `16` (`1 << 4`) |
| `skill_e` | `E` | `32` (`1 << 5`) |
| `skill_r` | `R` | `64` (`1 << 6`) |
| `steal` | `F` | `128` (`1 << 7`) |
| `defensive_stance` | `C` | `512` (`1 << 9`) |
| `zone_activate` | `V` | `256` (`1 << 8`) |
| `pause` | `Escape` | (UI/pause) |

### 5.2 Canonical `PlayerInputFrame` Dictionary
Used identically by local input capture, AI input providers, replay/combo systems, and UDP input packets:

```gdscript
{
    "seq": int,              # Monotonic input sequence number
    "tick": int,             # Simulation tick index
    "move_world_xz": Vector2,# Normalized world XZ movement vector (or Vector2.ZERO)
    "local_dir": Vector2,    # Camera/facing-relative input vector (x=right, y=forward)
    "buttons": int,          # Bitmask below
    "aim_yaw": float,        # Radians, character/camera aim yaw
}
```

**Button Bitmask Constants:**
```gdscript
const BTN_SPRINT: int  = 1    # 1 << 0
const BTN_JUMP: int    = 2    # 1 << 1
const BTN_SHOOT: int   = 4    # 1 << 2
const BTN_PASS: int    = 8    # 1 << 3
const BTN_SKILL_Q: int = 16   # 1 << 4
const BTN_SKILL_E: int = 32   # 1 << 5
const BTN_SKILL_R: int = 64   # 1 << 6
const BTN_STEAL: int   = 128  # 1 << 7
const BTN_ZONE: int    = 256  # 1 << 8
const BTN_STANCE: int  = 512  # 1 << 9
```

---

## 6. Autoload Contracts (`EventBus`, `GameState`, `ConfigManager`, `NetClient`, `LocalCareer`)

Registered in `client/project.godot` in order:
1. `EventBus` -> `res://scripts/autoload/event_bus.gd`
2. `GameState` -> `res://scripts/autoload/game_state.gd`
3. `ConfigManager` -> `res://scripts/autoload/config_manager.gd`
4. `NetClient` -> `res://scripts/net/net_client.gd` (`class_name NetClientNode` for multi-instance tests)
5. `LocalCareer` -> `res://scripts/autoload/local_career_store.gd` (`class_name LocalCareerStore`, local offline Glicko-2 career & rival AI ladder persisted in `user://local_career.json`)

### 6.1 `EventBus` Canonical Signals (27 Signals)
All cross-system communication uses `EventBus`:

- **Match & Score:**
  - `match_started(match_config: Dictionary)`
  - `score_changed(team_id: int, new_score: int, delta: int, is_three: bool, scorer_id: int)`
  - `timer_updated(match_seconds_left: float, shot_clock_left: float)`
  - `possession_changed(team_id: int, carrier_id: int)`
  - `match_ended(winner_team: int, final_scores: Array, stats: Dictionary)`
  - `match_restarted()`
- **Ball & Player Motion:**
  - `ball_bounced(world_pos: Vector3, impact_speed: float, surface_type: String)`
  - `player_footstep(player_id: int, world_pos: Vector3, is_sprint: bool)`
  - `dribble_move_performed(player_id: int, move_name: String, world_pos: Vector3)`
  - `combo_triggered(player_id: int, combo_id: String, combo_tier: int, is_perfect: bool)`
- **Offense, Defense & Zone:**
  - `shot_released(player_id: int, release_pos: Vector3, target_rim: Vector3, is_three: bool, timing_quality: float)`
  - `shot_timing_feedback(player_id: int, label: String, timing_error: float)`
  - `dunk_impact(player_id: int, rim_pos: Vector3, power: float)`
  - `ankle_broken(victim_id: int, attacker_id: int, world_pos: Vector3)`
  - `block_performed(blocker_id: int, shooter_id: int, world_pos: Vector3)`
  - `steal_performed(stealer_id: int, victim_id: int, world_pos: Vector3)`
  - `zone_activated(player_id: int, duration: float)`
  - `zone_ended(player_id: int)`
- **Meters & Input Telemetry:**
  - `stamina_updated(player_id: int, current: float, maximum: float)`
  - `zone_meter_updated(player_id: int, current: float, maximum: float)`
  - `input_recorded(player_id: int, frame: Dictionary)`
- **Networking & Persistence:**
  - `net_connected(session_info: Dictionary)`
  - `net_disconnected(reason: String)`
  - `lobby_state_updated(lobby_state: Dictionary)`
  - `net_metrics_updated(metrics: Dictionary)`
  - `profile_loaded(profile: Dictionary)`
  - `leaderboard_loaded(entries: Array)`

---

## 7. `player_controller.gd` Integration API

`client/scripts/player/player_controller.gd` MUST expose the following public methods so AI bots, combo executors, and network prediction/reconciliation interoperate cleanly:

```gdscript
func set_external_input_provider(provider) -> void
func apply_archetype(archetype_dict: Dictionary) -> void
func execute_combo_move(move_def: Dictionary, is_perfect: bool) -> bool
func export_sim_state() -> Dictionary
func import_sim_state(state: Dictionary) -> void
```

- `set_external_input_provider(provider)`: Attaches an object/callable implementing `sample_input(tick: int, dt: float) -> Dictionary` returning a canonical `PlayerInputFrame`. Pass `null` to restore local human input.
- `apply_archetype(archetype_dict)`: Applies character attributes (speed, acceleration, jump impulse, shot arc/window, steal/block radii, stamina/zone rates, skill IDs).
- `execute_combo_move(move_def, is_perfect) -> bool`: Executes a dribble/combo burst or special ability (`ankle_breaker` radius, velocity impulse, animation state), returning `true` if triggered.
- `export_sim_state() -> Dictionary` / `import_sim_state(state: Dictionary)`: Lossless snapshot export/restore for client rollback & reconciliation.

---

## 8. Database & Local Dev Ports

- **PostgreSQL 16.4 (Local Portable):**
  - Host: `127.0.0.1`
  - Port: `15432`
  - Database: `phantom_court`
  - User: `postgres` (local trust auth in dev)
  - Connection URL: `postgres://postgres@127.0.0.1:15432/phantom_court`
- **Game Server Defaults:**
  - UDP Realtime Sim Port: `7777`
  - HTTP REST / Lobby / Health Port: `8080` (`GET /health`)

---

## 9. Mandatory Technical Rules (All Workers)

1. **NEVER invent `uid="uid://..."` in hand-authored `.tscn` or `.tres` files.** Omit `uid` attributes on `[gd_scene]` and `[ext_resource]` when creating scene/resource files manually so Godot 4.7.2 never errors on mismatched UIDs.
2. **Guard `looking_at(...)` and `.normalized()` against zero/degenerate vectors:**
   - Before `.normalized()`, check `v.length_squared() > 1e-8` (or `!v.is_zero_approx()`).
   - Before `look_at(target, up)` / `Basis.looking_at(dir, up)`, verify `(target - origin).length_squared() > 1e-6` and that `dir.normalized()` is not collinear with `up` (`abs(dir.normalized().dot(up.normalized())) < 0.999`).
3. **Headless Test Exit Codes:** Every Godot headless test script launched via `--headless --script ...` MUST explicitly call `quit(0)` on success or `quit(1)` on assertion failure/timeout.
4. **60 Hz Determinism:** All simulation state transitions must run inside `_physics_process(delta)` (or explicit fixed `dt = 1.0 / 60.0` steps), never scaled unreliably by variable render FPS.
