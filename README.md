# The Complex

A high-speed cooperative semi-roguelite hack & slash for Roblox (1–4 players, isometric camera,
PC / mobile / console). Players fight through the floors of The Complex, clearing waves of enemies
and earning permanent progression between runs.

The game design lives in [`plans/gdd/`](plans/gdd/).

## Current state

The first playable slice — **single-room combat** — is implemented, has grown well past its
original scope, and passes the offline checks (`make check`). It is ready for playtesting and
tuning in Roblox Studio; nothing that needs a DataModel is verified automatically. See
[`plans/gdd/scope.md`](plans/gdd/scope.md) and [`docs/combat.md`](docs/combat.md).

- **Player kit**: isometric camera, movement/jump, 3-hit combo with forward target sticking and a
  short lunge, a 2 s charged heavy attack, dash with an invulnerability window (double dash while
  the speed buff is active), and hold-to-block with a parry window that staggers melee attackers
  and reflects shots.
- **Classes**: three test classes picked on a selection screen before the fight (the enemies wait
  while anyone is choosing) — **Tanque** (greatsword and shield: Giro, Provocación, Muralla),
  **Daño** (two daggers: Stinger, Ejecución, Over Drive) and **Apoyo** (staff: Pulso curativo,
  Campo protector, Onda de choque) — each with its own stats and passive
  ([`docs/classes.md`](docs/classes.md)). Abilities are selected with `1`/`2`/`3` or the D-pad and
  fired with `E` / `Y` / `R1`.
- **Enemies & waves**: four kinds driven by pure state machines (`Brain`, `Tactics`) on a spatial
  grid, as rigged `.rbxmx` models with weapon variants — the **Centinela** (melee: sword with the
  parry-only *Paso Fantasma* ambush, dual blades spin, axe, mace stun slam), the **Cazador**
  (ranged: rifle and plasma charged rail-beam, shotgun, minigun tracers, backstep evade leap), the
  **Detonante** (exploder: oval blast that also hurts enemies) and the **Coloso** (grabber: mash or
  teammates to break free, plus a bull rush that flings and stuns). Health scales by kind and
  weapon. Five waves; the room restarts on clear and resets on a wipe.
- **World & rewards**: the industrial `ComplexArena.rbxmx` room, 30% enemy drops (heal, damage,
  speed) and a periodic defense pickup, all as `.rbxmx` models.
- **Feedback**: procedural player and enemy animations, 2D/3D combat sound effects, looped
  background music, combat VFX, the AgX Punchy tonemapper ([`docs/tonemapping.md`](docs/tonemapping.md))
  and a React combat HUD (health, buffs, wave and telegraph banners, ability bar).
- **Core infrastructure**: contract-enforced client→server networking, centralized `Config`,
  universe-based environments and feature flags, server log telemetry (`LogSink`), and offline
  Lune test suites.

**Not done yet:** only the background music is uploaded to Roblox (`AssetIds.json`); every sound
effect still plays through its Studio fallback and needs `make sync-assets` before a publish.
There are no floors, run upgrades, bosses, hub, parties or persistence yet — those are the later
milestones in `scope.md`.

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
