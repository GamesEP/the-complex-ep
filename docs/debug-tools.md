# In-Game Admin Dev & Debug Toolset

How the admin playtesting and debugging panel works across all three realms, how production stays zero-footprint, and which module owns each piece of state.

## Modules

| Module | Realm | Responsibility |
|---|---|---|
| [`Config/Debug.luau`](../src/shared/core/Config/Debug.luau) | Shared | `DEBUG_ALLOW_IN_PRODUCTION = false`, `DEBUG_ADMIN_RATE = 15`, `DEBUG_TOGGLE_KEY = F4`, damage multiplier & spawn batch lists, `DEBUG_DUMMY_HEALTH = 9999`, log caps, and hitbox wireframe colors. |
| [`DebugCommands.luau`](../src/shared/features/debug/DebugCommands.luau) | Shared (pure) | Permission rule `canUse()`, dynamic `enemyCatalog()` derived from `Config.ENEMY_KINDS`, payload validator for every admin action, all 5 declarative presets, and immutable `appendLog`. Tested offline by `make test`. |
| [`DebugService.luau`](../src/server/features/debug/DebugService.luau) | Server | Admin command dispatcher (`onCommand`), `IsAdmin` player attribute replication, `LogSink` audit recording, `emitCombatLog`, and `runPreset` orchestrator. Receives gameplay services via `start(deps)` so no gameplay feature requires `debug`. |
| [`DebugStore.luau`](../src/client/features/debug/stores/DebugStore.luau) | Client store | Pure Charm atoms (`isOpen`, `activeTab`, `quickBarVisible`, `overlays`, `hitboxLayers`, `themeOverride`, `tonemapperOverride`, `combatLog`, `lastCommandStatus`) tested offline by `make test ONLY=ui`. |
| [`DevPanel.luau`](../src/client/features/debug/ui/DevPanel.luau) + [`tabs/`](../src/client/features/debug/ui/tabs/) | Client UI | Hazard Arc collapsible 6-tab drawer (`Run`, `Enemigos`, `Build`, `Cheats`, `Presets`, `Overlays`), quick-action strip, bottom-left `DEV [F4]` / `QUICK` pills, and `F4` toggle hotkey. Mounted via `UI.mount` (`ResetOnSpawn = false`, `displayOrder = 90`). |
| [`DebugMetrics.luau`](../src/client/features/debug/ui/DebugMetrics.luau) | Client UI | Top-right FPS / frame ms / entity count / player stat & window indicator strip driven by `React.useBinding` at ~10 Hz (zero 60 FPS reconciler wakeups). |
| [`CombatLogPanel.luau`](../src/client/features/debug/ui/CombatLogPanel.luau) | Client UI | Top-right rolling combat math log (below Metrics) populated by `Remotes.DebugEvent`. |
| [`EnemyInspector.luau`](../src/client/features/debug/EnemyInspector.luau) | Client | Plain Luau overhead `BillboardGui` inspector showing `kind:weapon`, `HP/MaxHP`, `Phase`, and `Daze` stacks; tears down via `AncestryChanged` (see [roblox-gotchas.md](roblox-gotchas.md)). |
| [`HitboxVisualizer.luau`](../src/client/features/debug/HitboxVisualizer.luau) | Client | Plain Luau pooled wireframe overlay under `workspace.CurrentCamera` with per-layer toggles (`playerAim`, `enemyReach`, `pillars`, `doorZone`) for the player `120°` aim-assist cone & soft-lock line, live enemy/boss radii, `Config.ARENA_PILLARS`, and the North Blast Door zone. |

## Security boundary

1. **Contract enforcement:** `AdminCommand` is declared with `admin = true` in [`Contract.luau`](../src/shared/core/Net/Contract.luau). [`Dispatcher.luau`](../src/server/core/Net/Dispatcher.luau) rejects non-admins silently before `DebugService` runs and counts rejections in `Telemetry`.
2. **Production kill switch:** `DebugCommands.canUse(Environment.name(), isAdmin(player), Config.DEBUG_ALLOW_IN_PRODUCTION)` blocks every command in production while `DEBUG_ALLOW_IN_PRODUCTION` is `false` (asserted in `DebugCommands.selfTest()`).
3. **Client mount gate:** [`Bootstrap.client.luau`](../src/client/Bootstrap.client.luau) mounts `DevPanel` only when `not Environment.isProduction()` (matching `BuildStamp`), and `DevPanelApp` additionally checks `LocalPlayer:GetAttribute("IsAdmin")` (or `Environment.isStudio()`).

## Replicated attributes

- **Player:** `IsAdmin` (`boolean`), `DebugGodMode` (`boolean`), `DebugNoCooldowns` (`boolean`), `DebugDamageMult` (`number`)
- **World:** `DebugSandbox` (`boolean`), `DebugAiMode` (`"normal" | "noAttack" | "frozen"`)
- **Enemy Model:** `Health`, `MaxHealth`, `Phase`, `DazeStacks`, `Weapon`, `DebugDummy`

## Remotes

- **Client → Server (contracted):** `AdminCommand(action: string, payload: table)`
- **Server → Admin Client:** `DebugEvent(kind: "commandResult" | "combatLog" | "openOverlay", data: table)`

## One-click playtest presets

- **`boss_oh_practice`** — Jump to Room 5 (`BossOh`), equip Lv.2 `spin` / `stinger` / `overdrive`, enable `HasDoubleDash`, full heal.
- **`parry_gym`** — Sandbox ON, God Mode ON, clear enemies, spawn 1 Sword Centinela (`Paso Fantasma`) and 1 Rifle Cazador in front of the player.
- **`perf_25_enemies`** — Sandbox ON, spawn 25 mixed enemies (all 4 archetypes) for `VS-23` FPS stress testing, auto-open Metrics Bar.
- **`upgrade_queue_test`** — Fill all 3 active ability slots and push 3 queued 1-of-3 offers (`+2` queue depth) to exercise replacement & queue UX.
- **`clean_reset`** — Disable all cheats/sandbox/AI overrides, reset build to Pillar 1 baseline, jump to Room 1 at full HP.
