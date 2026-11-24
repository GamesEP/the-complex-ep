# Combat

How the combat slice works: the player's kit, the enemies, the waves, and who decides what. The
design (what the player experiences and why) is [plans/gdd/systems.md](../plans/gdd/systems.md)
and [plans/gdd/scope.md](../plans/gdd/scope.md); this is how it is built.

| | |
|---|---|
| `shared/features/combat/Melee` | Pure: the combo, the swing arc, the spin radius. Both realms call it. |
| `shared/features/enemies/Brain` | Pure: what an enemy does each frame, as a state machine. |
| `shared/features/enemies/Waves` | Pure: what a wave contains, where it spawns, keeping things inside the room. |
| `server/features/combat/CombatService` | The player's stats, the three remotes, and `hurt`. |
| `server/features/enemies/EnemyService` | Spawns, moves and damages enemies; carries out what `Brain` decides. |
| `server/features/enemies/WaveDirector` | Runs the waves; resets the room when everybody is dead. |
| `client/features/camera/IsoCamera` | The isometric camera. |
| `client/features/combat/CombatInput` | Attack, dash and spin on every input device. |
| `client/features/combat/Effects` | The local player's own swing, dash and spin visuals. |
| `client/features/combat/ui/CombatHud` | Health, cooldowns, wave. |

Every number is in `Config/Combat.luau` and `Config/Enemies.luau`.

## Who decides what

**The client moves; the server judges.** Roblox gives each client network ownership of its own
character, so movement — including the dash — is the client's. Everything that decides an
outcome is the server's: what a swing hit, whether a cooldown allowed it, and the dash's
invulnerability window.

Each action is predicted on the client and confirmed by the server:

| Action | Client, at once | Server, on the remote |
|---|---|---|
| Attack | Turns the character, draws the slash, fires `Attack(aim)` | Checks the swing interval, advances the combo, damages every enemy in the arc |
| Dash | Applies the dash velocity, fires `Dash()` | Checks the cooldown, sets `DashReadyAt`, grants `InvulnerableUntil` |
| Spin | Draws the ring, fires `Spin()` | Checks the cooldown, sets `SpinReadyAt`, damages everything in the radius |

**The attack sends its aim.** The server could read the character's facing instead, but that
facing arrives by physics replication, which is not ordered with remotes — the remote announcing
a swing can arrive before the turn that aimed it. Sending the direction makes the swing go where
the player saw it go. The contract shape-checks it as a finite `Vector3`; `CombatService` flattens
it and falls back to the character's facing if it is degenerate.

**Cooldowns are attributes in server time.** `DashReadyAt` and `SpinReadyAt` are
`workspace:GetServerTimeNow()` values on the player, which both realms read on the same clock.
The HUD turns them into bars with a binding (they move every frame). The client also keeps its own
predicted ready time, so a double press cannot fire twice before the attribute replicates.
The server accepts a press up to 0.1 s early, so a dash pressed the instant the bar fills is
never silently refused.

**The combo is judged on the server's own clock** (`os.clock`), which a client cannot move.
`ATTACK_TOLERANCE` lets two presses arrive a little closer than `ATTACK_INTERVAL`, because network
jitter can bunch them up.

**All damage to a player goes through `CombatService.hurt`.** `EnemyService` receives it as a
dependency and never touches a Humanoid. That is what makes the dash's invulnerability apply to
every source — a melee strike, an explosion, a projectile — without any of them knowing about it.
`hurt` returns whether the hit landed, so a projectile passes through a dashing player instead of
disappearing on them.

## Enemies

**Anchored parts, not rigs.** An enemy is a Model with one anchored part (`Body`), moved by the
server every Heartbeat. A Humanoid rig per enemy brings physics, pathfinding and a network owner
that a flat room does not need, at a cost paid per enemy — the number a horde game wants large.
Players pass through enemies (`CanCollide = false`); hits are judged by distance, not contact.

**`Brain` decides, `EnemyService` carries it out.** Each frame an enemy finds the nearest living
player, and `Brain.step(kind, spec, state, distance, now)` returns its new state and an intent:
move toward / away / hold, and optionally strike / fire / explode. Keeping that pure is what lets
`make test` assert "the melee enemy always telegraphs before it strikes" — the rule that makes the
dash a skill rather than luck.

**The telegraph is the material.** During a windup or a fuse the body turns Neon. A strike checks
reach again at the moment it lands, so dashing out during the windup always works.

**Separation** pushes enemies apart inside `ENEMY_SPACING`, so a wave reads as a crowd.

## Waves

`WaveDirector` spawns `Config.WAVES` in order, each round a ring inside the walls, and waits until
the board is empty. After the last wave the room is clean, and after `ROOM_RESTART_SECONDS` it
starts again from wave 1 — the slice is for fighting the room over and over.

The spawn has no ForceField (`SpawnLocation.Duration = 0` in `WorldBuilder`). Roblox's default
10-second shield made the whole first wave harmless; with the room resetting on death there is
nothing left for it to protect.

When the last living player dies the room resets: the board is cleared and the waves start again
once somebody has respawned. A `generation` counter makes the reset safe: the old loop sees that
its generation is no longer current at its next check and stops, so it can never spawn into the
new room.

The HUD reads the room from attributes on `workspace.World`: `Wave`, `WaveCount`, `EnemiesLeft`,
`RoomState` (`waiting` | `fighting` | `cleared`).

## Input

`ContextActionService` binds each action once for every device, and `createTouchButton` draws the
on-screen button on a phone. Moving and jumping stay Roblox's own controls, which move relative to
the camera — so WASD, the thumbstick and the gamepad stick all mean "up the screen" with no code.

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Attack | Left click | X, R2 | "Atacar" button |
| Dash | Left Shift, Q | B, L2 | "Dash" button |
| Spin | E | Y, R1 | "Giro" button |

With a mouse the swing goes where the cursor points (a ray onto the horizontal plane through the
player). Without one there is nothing to point with, so the swing turns to the nearest enemy
within `AIM_ASSIST_RANGE`, then falls back to the movement direction, then the facing.

Shift lock is turned off per player (`DevEnableMouseLock = false`): it toggles on Left Shift,
which is the dash.

## What is not verified offline

`make test` covers `Melee`, `Brain` and `Waves`. Everything that needs a DataModel — the camera,
the dash's feel, the touch buttons' placement, enemies moving, the HUD — only shows up in Studio.
The touch buttons in particular sit where `ContextActionService` puts them by default; check them
with phone emulation before relying on them.
