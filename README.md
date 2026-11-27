# The Complex

A high-speed cooperative semi-roguelite hack & slash for Roblox (1–4 players, isometric camera,
PC / mobile / console). Players fight through the floors of The Complex, clearing waves of enemies
and earning permanent progression between runs.

The game design lives in [`plans/gdd/`](plans/gdd/).

## Current state

**Phase 1 — Vertical Slice (1 Floor, 5 Rooms, Zero-Pause 1-of-3 Upgrades & Boss Oh)** is
implemented on `develop` and passes the offline checks (`make check`). See
[`plans/gdd/scope.md`](plans/gdd/scope.md), [`plans/roadmap.md`](plans/roadmap.md), and
[`docs/combat.md`](docs/combat.md).

- **Player kit (Pillar 1 — equal start, build during the run)**: everyone starts identical with the
  base sword, isometric camera, movement/jump, 3-hit combo with soft lock-on, tracked wall-safe
  lunges, progressive enemy hitstun, a 1.4 s charged heavy attack, dash with i-frames, and
  hold-to-block with parry (melee stun + projectile reflection).
- **1-of-3 Zero-Pause Upgrades (`UpgradePool` / `UpgradeService` / `UpgradeChoice`)**: players
  choose 1 of 3 cards on run start and on every room clear without pausing (using **`Q` / `E` /
  `F`** on PC, click/tap, or gamepad) — building up to 3 active abilities (leveling up Lv.1–Lv.3 or
  replacing full slots) from the 9-ability pool (**Torbellino**, **Rugido**, **Coraza**,
  **Estocada**, **Vórtice**, **Corte Final**, **Santuario**, **Barrera**, **Repulsión**), stat
  upgrades (`+HP`, `+Daño`, `+Velocidad`, `-Recarga`), and movement passives (**Doble Salto** and
  **Doble Dash**).
- **1-Floor Run Loop & Boss Oh (`RunFlow` / `RunService` / `RunResult`)**: 4 difficulty tiers
  (**Fácil**, **Normal**, **Difícil**, **Zona Muerta**), 5 authored rooms ending with **Boss Oh**
  in Room 5, manual North Blast Door room transitions, per-room/wave arena color themes, and
  `RunResult` (Victory / Defeat) with instant Retry.
- **Enemies**: four rigged `.rbxmx` archetypes (`Brain`, `Tactics`, `SpatialGrid`) — **Centinela**
  (sword *Paso Fantasma*, dual-blade spin, throwing axe + floor pickup, mace stun slam), **Cazador**
  (rifle/plasma charged rail-beam, 4-line diverging shotgun fan, non-parriable minigun tracers,
  backstep evade leap, recoil animations), **Detonante** (oval friendly-fire blast), **Coloso**
  (grab + bull rush), and **Boss Oh** (cone smash, seismic leap, 360° plasma nova, hitstun-immune).
- **World, feedback & infrastructure**: `ComplexArena.rbxmx` with solid cover pillars/bunkers and
  anti-climb hulls, 30% enemy drops, Hazard Arc React/Charm HUD, procedural player & enemy
  animations, contract-enforced remotes (`Contract.luau`), `Environment`, `Flags`, `LogSink`, and
  offline Lune test suites.

**Not done yet:** only `bgm-complex.ogg` is uploaded to Roblox (`AssetIds.json`); SFX cues use
Studio fallbacks until `make sync-assets` is run with Open Cloud credentials. Phase 2 (remaining 2
enemy types, 5 floors, My/Gon/OhMyGon, Hub/Parties/Co-op Revive) and Phase 3 (permanent
progression/DataStore) follow in [`plans/roadmap.md`](plans/roadmap.md).

## Stack & toolchain

| | |
|---|---|
| **Rojo 7** | The repo is the source of truth. A `.rbxl` is a build output, never a workspace. |
| **Wally** | Dependencies pinned in `wally.toml` / `wally.lock`; `Packages/` is generated. |
| **Rokit** | The whole toolchain pinned in `rokit.toml`, so CI and every machine agree. |
| **Lune** | Runs the offline test suites and generates `.rbxmx` 3D model assets (`@lune/roblox`). |
| **luau-lsp** | Autocomplete, type-checking, and the `make globals` gate. |
| **StyLua** | One house format, configured in `stylua.toml`. |
| **React** (`react-roblox`) | Every screen, backed by the UI kit (`Mount`, `DesignScale`, `ScreenMetrics`, hooks, theme). |
| **Charm** | Atoms behind the client stores React reads — testable offline with no DataModel. |
| **SignalPlus** | Signals, for events that have no current value to store. |
| **GitHub Actions** | Build + test on every PR; publish to Roblox on push to `staging`/`main`. |
| **Studio MCP** | Lets agents inspect Studio, run Luau, and capture screenshots. |

Plus two operational safeguards built in from day one:

- **Offline verification.** `make test` runs every pure rule in milliseconds without Studio;
  `make globals` catches undefined globals that build cleanly and crash on the first server frame.
- **Readable published servers.** Roblox provides no server log file. `features/telemetry/LogSink`
  keeps a ring buffer in a DataStore and `make logs` reads it from the terminal.

## Getting started

Work happens on the **`develop`** branch.

```bash
make setup      # install the pinned toolchain and the Wally packages
make plugin     # install the Rojo Studio plugin on Linux/Vinegar (Windows/macOS: make plugin-win)
make lsp-defs   # download Roblox type definitions for luau-lsp (once per machine)
make dev        # build the local scratch place and start live sync
```

Open `local.rbxlx` in Roblox Studio and connect the Rojo plugin to `localhost:34872`. Edits on
disk sync into Studio live.

Before pushing, run:

```bash
make check      # offline tests, undefined-globals gate, and a full Rojo build
```

Run `make` on its own to list every target. On Windows, `.\make.ps1 <target>` exposes the same
targets — see [`CONTRIBUTING.md`](CONTRIBUTING.md#windows).

## Project structure

```
src/shared/     replicated to both realms: Config, Net contract, Assets, pure game rules
src/server/     Bootstrap + core/ + one folder per feature
src/client/     Bootstrap + core/ + ui/ (React UI kit) + one folder per feature
assets/         audio (.ogg), images, and .rbxmx 3D models mounted via default.project.json
plans/gdd/      game design document (what The Complex is)
docs/           subsystem architecture docs (how it is built)
scripts/        offline test runner, sandbox, asset sync, logs, and Studio MCP helpers
```

Code is organized **realm first, then feature**: a file's path tells you which side of the network
it runs on and which feature owns it before you open it.

## Where to read next

- **[`plans/gdd/`](plans/gdd/overview.md)** — Game design document (*what the game is*).
- **[`CLAUDE.md`](CLAUDE.md)** — Architecture rules, conventions, net contract, React UI rules,
  3D model policy (`.rbxmx`), and verification steps. [`GEMINI.md`](GEMINI.md) and
  [`AGENTS.md`](AGENTS.md) point Gemini and other agents at this same file.
- **[`docs/`](docs/README.md)** — Subsystem deep-dives: [combat](docs/combat.md),
  [net-contract](docs/net-contract.md), [ui-architecture](docs/ui-architecture.md),
  [environments](docs/environments.md), [telemetry](docs/telemetry.md), [testing](docs/testing.md),
  and [roblox-gotchas](docs/roblox-gotchas.md).
- **[`CONTRIBUTING.md`](CONTRIBUTING.md)** — Setup, daily workflow, branches and places, editors,
  and Windows notes.
