# Run loop (5-floor Horizontal Slice)

How a 5-floor × 5-room run moves from the start screen through randomized encounters, dynamic arena swaps, Bosses **Oh / My / Gon / OhMyGon**, Victory/Defeat, and Retry — and which module owns each piece of state. Design rules live in [`plans/gdd/loop.md`](../plans/gdd/loop.md) and [`plans/gdd/overview.md`](../plans/gdd/overview.md).

## Modules

| Module | Realm | Responsibility |
|---|---|---|
| [`Config/Run.luau`](../src/shared/core/Config/Run.luau) | Shared | `ROOMS_PER_FLOOR = 5`, `FLOORS_PER_RUN = 5`, `BLAST_DOOR_TRIGGER_Z = -60`, `BLAST_DOOR_TRIGGER_HALF_X = 12`. |
| [`Config/Floors.luau`](../src/shared/core/Config/Floors.luau) | Shared | `MAX_ACTIVE_ENEMIES = 25` and the 5-floor encounter pools (`Config.FLOORS[1..5]`): Floor 1 warm-up (no boss), Floors 2–5 randomized rooms + Room 5 Boss (**Oh**, **My**, **Gon**, **OhMyGon**). |
| [`FloorGenerator.luau`](../src/shared/features/run/FloorGenerator.luau) | Shared (pure) | Generates randomized 5×5 `RunPlan` with zero back-to-back duplicate rooms/arenas and enforces `MAX_ACTIVE_ENEMIES` cap (`capWave`). Tested offline by `make test`. |
| [`RunFlow.luau`](../src/shared/features/run/RunFlow.luau) | Shared (pure) | Multi-floor immutable state machine (`preparing` -> `fighting` -> `transition` -> `victory` / `defeat`), `isFloorBoundary`, kill counter, summary metrics, and `inDoorZone(pos)`. Tested offline by `make test`. |
| [`WorldBuilder.luau`](../src/server/features/world/WorldBuilder.luau) | Server | Mounts and swaps the 5 tracked `.rbxmx` arena layouts (`ComplexArena`, `ComplexArenaCross`, `ComplexArenaReactor`, `ComplexArenaCorridor`, `ComplexArenaVault`) safely via `swapArena` without dropping players. |
| [`RunService.luau`](../src/server/features/run/RunService.luau) | Server | Owns active `RunFlow` + `RunPlan`, Difficulty, `StartRun` / `RetryRun`, arena swapping, floor-exit upgrade auto-resolve, generation tokens, wipe detection, North Blast Door tweens, and `workspace.World` attributes. |
| [`WaveDirector.luau`](../src/server/features/enemies/WaveDirector.luau) | Server | Executes the waves for the current room (`runRoom(waves, onRoomCleared)`), enforces `MAX_ACTIVE_ENEMIES`, uses active arena obstacles, and aborts cleanly via generation tokens (`stop()`). |
| [`ClassSelect.luau`](../src/client/features/classes/ui/ClassSelect.luau) | Client UI | Pre-run Difficulty + Start Run screen (visible only when `World.RunState == "preparing"`). |
| [`RunResult.luau`](../src/client/features/run/ui/RunResult.luau) | Client UI | End-of-run Victory / Defeat summary plate displaying floor progress (`PISO 01..05`), total rooms (`0..25`), time, kills, and `REINTENTAR RUN`. |
| [`ArenaTheme.luau`](../src/client/features/world/ArenaTheme.luau) | Client | Rebinds automatically on arena swaps and tweens lighting/neons across `Config.FLOOR_THEMES[1..5]` (with boss-room intensification and emerald cleared state). |

## Replicated `workspace.World` attributes

- `Floor` (`1..5`), `FloorCount` (`5`), `FloorName` (`string`), `Room` (`1..5`), `RoomCount` (`5`), `TotalRoomCount` (`25`), `RoomName` (`string`), `IsBossRoom` (`boolean`), `ArenaModel` (`string`)
- `RunState` (`"preparing" | "fighting" | "transition" | "victory" | "defeat"`)
- `DoorOpen` (`boolean`): `true` when the North Blast Door has slid open after a room clear
- `Difficulty` (`"easy" | "normal" | "hard" | "deadzone"`)
- `RunStartedAt`, `RunElapsed`, `RunKills`, `RoomsCleared`

## Room transitions & retry invariants

1. Clearing all waves in Rooms 1–4 transitions `RunState` to `"transition"`, opens `ComplexArena.BlastDoor` (`DoorLeft` / `DoorRight` slide apart `8.4` studs, `DoorStatusBar` turns `#44F098`), plays `doorOpen`, and enqueues a zero-pause 1-of-3 upgrade offer for every player.
2. After the door slide finishes (`BLAST_DOOR_ANIM_SECONDS`, preventing accidental instant transitions when finishing the last enemy near the North wall), stepping into the open North Blast Door doorway (`Z <= -60`, `|X| <= 12`) clears leftover drops, projectiles, and active `Santuario` VFX zones, repositions all players to `SPAWN_OFFSET`, closes the door, and launches the next room.
3. Defeating Boss Oh in Room 5 auto-resolves any pending upgrades, plays `bossOhVictory`, and sets `RunState = "victory"`. If every player dies during combat/transition, `UpgradeService.resetAll()` clears open offers and `RunState` switches to `"defeat"`.
4. `RetryRun` increments `runGeneration`, stops active wave loops, clears enemies/drops/projectiles/zones, resets player upgrades, health, and client predicted cooldowns/selected slot (`UpgradeService.resetAll`, `CombatService.resetPlayerForRun`, `RunStartedAt` signal), closes the door, and starts a fresh Room 1 with a new starter 1-of-3 offer.

## Remotes

Declared in [`Remotes.luau`](../src/shared/core/Net/Remotes.luau) and validated in [`Contract.luau`](../src/shared/core/Net/Contract.luau):

- `ChooseDifficulty(diffId: string)` — allowed while `RunState == "preparing"`.
- `StartRun()` — transitions `preparing` -> Room 1 `fighting`.
- `RetryRun()` — restarts from `victory` or `defeat` back to Room 1 `fighting`.
