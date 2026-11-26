# Combat

How the combat slice works: the player's kit, the enemies, the waves, and who decides what. The
design (what the player experiences and why) is [plans/gdd/systems.md](../plans/gdd/systems.md)
and [plans/gdd/scope.md](../plans/gdd/scope.md); this is how it is built.

| | |
|---|---|
| `shared/features/combat/CombatAnim` | Pure: procedural player poses (combo, block/parry, jump/land, dash, spin) and interrupt priorities. |
| `shared/features/combat/CombatAudio` | Pure: combo cue selection, uploaded-vs-fallback id resolution, pitch variation. |
| `shared/features/combat/Defense` | Pure: hit resolution priority (`invulnerable > parry > block > hit`), 50% defense buff stacking, and WalkSpeed calculation. |
| `shared/features/combat/Melee` | Pure: the combo, the swing arc, the spin radius, forward target selection and attack lunge math. Both realms call it. |
| `shared/features/drops/Drops` | Pure: 30% drop roll, weighted kind selection, heal clamp, and damage/speed buff math. |
| `shared/features/enemies/Brain` | Pure: what an enemy does each frame, as a state machine. |
| `shared/features/enemies/EnemyAnim` | Pure: procedural enemy limb poses for walking, weapon-specific melee windup/strike (`sword`, `dual`, `axe`, `mace`), and death collapse. |
| `shared/features/enemies/Hitbox` | Pure: 3D ellipsoid hit checks for projectiles, melee strikes and oval explosions. |
| `shared/features/enemies/SpatialGrid` | Pure: uniform 2D spatial hash grid for local enemy lookups without full-list scans. |
| `shared/features/enemies/Tactics` | Pure: squad AI coordination (melee attack tokens, flanking orbit, ranged stagger/strafe, exploder intercept lead, grabber flank bias, co-op spread). |
| `shared/features/enemies/Waves` | Pure: what a wave contains, where it spawns, keeping things inside the room. |
| `server/features/combat/CombatService` | The player's stats, test sword equipping, drop buff application, the three remotes, and `hurt`. |
| `server/features/drops/DropService` | Spawns `.rbxmx` combat drops on enemy kills, handles pickup radius, expiration and room reset. |
| `server/features/enemies/EnemyService` | Spawns, moves and damages enemies; carries out what `Brain` decides. |
| `server/features/enemies/WaveDirector` | Runs the waves; resets the room when everybody is dead. |
| `client/features/camera/IsoCamera` | The isometric camera. |
| `client/features/combat/CombatInput` | Attack, dash and spin on every input device. |
| `client/features/combat/Effects` | The local player's own swing, dash and spin visuals, local SFX and local animation triggers. |
| `client/features/combat/PlayerAnimator` | Procedural `Stepped` joint animator for every player's character (`AnimationConstraint` and `Motor6D`). |
| `client/features/combat/SoundPlayer` | 3D spatial combat audio player, preloading, and `CombatSfx` listener. |
| `client/features/combat/ui/CombatHud` | Health, cooldowns, active buff timers, wave. |
| `client/features/drops/DropVisuals` | Client-only bobbing and rotation for drops in `workspace.World.Drops`. |
| `client/features/enemies/EnemyAnimator` | Client-side 60 FPS `Motor6D.C0` animator for rigged `.rbxmx` enemies (walking, weapon attacks, and client-side death collapses). |

Every number is in `Config/Combat.luau`, `Config/Drops.luau`, `Config/Enemies.luau`, `Config/Audio.luau` and `Config/Animations.luau`.

## Who decides what

**The client moves; the server judges.** Roblox gives each client network ownership of its own
character, so movement — including the dash — is the client's. Everything that decides an
outcome is the server's: what a swing hit, whether a cooldown allowed it, and the dash's
invulnerability window.

Each action is predicted on the client and confirmed by the server:

| Action | Client, at once | Server, on the remote |
|---|---|---|
| Attack | Picks the best enemy in the forward cone, turns and lunges in if needed, plays swing anim/SFX, fires `Attack(aim)` | Checks the swing interval, advances the combo, damages every enemy in the arc |
| Heavy Attack (hold Attack 2 s) | Tap still swings immediately; holding past `HEAVY_CHARGE_DELAY` starts charge ring/SFX and fires `HeavyCharge(true)`. At `HEAVY_CHARGE_SECONDS` (2 s) lunges, draws shockwave, plays `heavyAttack` anim/SFX, fires `HeavyAttack(aim)` | Tracks server-side charge clock (`ChargingHeavy`, `HeavyChargeStart`), slows `WalkSpeed`, verifies full charge (`Melee.isChargeReady`), damages every enemy in the wide `HEAVY_ATTACK_ARC` |
| Dash | Applies the dash velocity, fires `Dash()` | Checks the cooldown, sets `DashReadyAt`, grants `InvulnerableUntil` |
| Spin (`1` + `E`) | Draws the ring, fires `Spin()` | Checks `SpinReadyAt`, damages everything in `SPIN_RADIUS` |
| Stinger (`2` + `E`) | Applies high-speed forward thrust `LinearVelocity`, draws lance streak & anim, fires `Stinger(aim)` | Checks `StingerReadyAt`, pierces every enemy along `Melee.inCorridor` (`STINGER_DISTANCE` × `STINGER_WIDTH`) |
| Over Drive (`3` + `E`, Ult) | Faces target, fires `OverDrive(aim)` | Checks `OverDriveReadyAt` (`14 s`), enters `OverDriveCharging` (`0.75 s`), then fires 3 sequential piercing ranged waves (`Melee.inCorridor`, `56` studs) synced via `CombatVfx`/`CombatAnim`/`CombatSfx` |

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

Each kind has a player-facing name in `Config.ENEMY_KINDS[kind].displayName`; the table key is the
internal id used by `Brain`, `Tactics`, `Config.WAVES` and the asset names, and is deliberately not
renamed. Read the name from Config anywhere it reaches a screen — never write it into UI code.

| Internal id | Name | Role |
|---|---|---|
| `melee` | Centinela | Melee line, four weapon variants |
| `ranged` | Cazador | Ranged, four weapon variants |
| `exploder` | Detonante | Fast suicide runner |
| `grabber` | Coloso | Juggernaut that grabs and rushes |

**Anchored parts, not rigs.** An enemy is a Model with one anchored part (`Body`), moved by the
server every Heartbeat. A Humanoid rig per enemy brings physics, pathfinding and a network owner
that a flat room does not need, at a cost paid per enemy — the number a horde game wants large.
Players pass through enemies (`CanCollide = false`); hits are judged by distance, not contact.

**`Brain` + `Tactics` decide, `EnemyService` carries it out.** Each frame `EnemyService` assigns
targets across living players via `Tactics.chooseTarget` (applying `Config.AI_COOP_CROWD_PENALTY`
in co-op), distributes 360-degree angular sectors via `Tactics.assignSectors` (separately for
close-quarters units and `ranged` crossfire units, with per-enemy unpredictable jitter and periodic
flank/radius shifts), and budgets up to `Config.AI_MAX_MELEE_ATTACKERS` simultaneous melee
attackers per player via `Tactics.assignMeleeTokens`. Attackers curve in from opposing sectors
(`Tactics.pincerApproach`), flankers peel away to their assigned sectors (`Tactics.steerToSector`),
and quadratic repulsion (`Tactics.antiClumpPush` over `SpatialGrid`, with `ENEMY_SPACING = 9.5` and
`AI_RANGED_SPACING = 16`) actively breaks up clumping so waves cannot easily be herded into one
ball. Ranged enemies spread into crossfire corners and stagger volleys (`Tactics.canFireStaggered`),
exploders curve-intercept moving players (`Tactics.interceptPoint`), and grabbers circle toward a
player's blindspot (`Tactics.grabberApproach`) before launching their lunge. Keeping all of that
pure lets `make test` assert timings, sector dispersion, and anti-clump repulsion offline.

**The telegraph is a crisp Highlight outline.** During a windup, ability charge, or fuse the enemy
gains a color-coded `Highlight` (`FillTransparency = 0.72`, `OutlineTransparency = 0.08`) instead of
turning its body Neon, keeping armor silhouettes sharp with controlled glow. A strike checks
reach again at the moment it lands, so dashing out during the windup always works (except the
single-sword Paso Fantasma parry-only finisher).

**Vertical hitboxes (`Hitbox.inEllipsoid`)** check height (`Y`) as well as horizontal distance so
jumping has a defensive role: ranged shots travel at `Config.PROJECTILE_HEIGHT` (`Y = 2`) and pass
under a jumping player; melee strikes check `strikeHeight`; and exploder detonations use a
flattened oval (`blastHeight < blastRadius`, rendered with a `SpecialMesh` sphere to match) so
jumping near the outer rim clears the dome more easily than at dead centre.

**Spatial grid (`SpatialGrid`) and exploder splash damage.** Living enemies are indexed into
`Config.ENEMY_GRID_CELL_SIZE` cells on `(X, Z)`. When an exploder detonates, `EnemyService` queries
only the local cells overlapping its blast radius instead of scanning every enemy in the room,
applying `Config.ENEMY_KINDS.exploder.enemyDamage` to any other living enemy inside the oval
(`Hitbox.inEllipsoid`), turning kiting an exploder into a crowd into a tactical advantage. Enemies
killed by the blast still go through `EnemyService.damage` -> `kill` and roll drops; the
self-destructing exploder itself does not. Crowd separation (`ENEMY_SPACING`) uses the same spatial
grid to push nearby enemies apart in `O(local)` rather than `O(N^2)`.

**Grabbers telegraph, immobilise, and drain 8 HP/s.** Modeled as `assets/models/EnemyGrabber.rbxmx`
(mounted at `ReplicatedStorage.Models.EnemyGrabber`, moved via `Model:PivotTo`), a grabber enters
`windup` (`0.55 s`) showing its `TelegraphHighlight`, playing `enemyGrabberWindup`, and displaying
the overhead yellow `!` triangle (`AlertIcon`). If the player does not
escape reach or Dash i-frames (`CombatService.canGrab`), the grabber enters `holding`, locks
movement (`Grabbed = true`), and ticks 8 HP/s (`Config.GRAB_DAMAGE_TICK_SECONDS`). While trapped,
pressing Attack (mouse/gamepad/touch) fires the contracted `GrabEscape` remote (10 presses,
`Config.GRAB_ESCAPE_PRESSES`); teammates attacking the grabber also contribute
`Config.GRAB_ALLY_HIT_PROGRESS` per hit and killing it frees the player immediately. While a player
is `Grabbed`, `EnemyService`'s `targets()` skips them so every other enemy (and in-flight
projectiles/explosions) ignores the trapped player: in co-op they keep chasing free teammates, and
when no free target exists (solo or full-party grab) they keep prowling the room via
`Brain.wanderDirection` while steering outside `Config.ENEMY_GRAB_AVOID_RADIUS` instead of
freezing, and any active enemy windup resets cleanly. Grabbers enter `Config.WAVES` starting on
wave 4 of 5.

**Grabber rush (embestida).** When the target is beyond grab reach but inside
`rushMinRange..rushMaxRange` and `nextRushAt` has passed, `Brain` puts the grabber into
`rushWindup` (red telegraph, `AlertIcon`, `EnemyAnim.rushWindupPose`), then `rush`: `EnemyService`
locks the heading at `rushLaunch` and drives the body at `rushSpeed` for `rushDuration`,
checking `Hitbox.inEllipsoid` after each frame's step so the charge cannot tunnel past anyone.
Each player is hit at most once per rush (`enemy.rushHit`); a wall ends the rush early through
`Brain.endRush`. A hit goes through `CombatService.hurt` (`canBlock = true, canParry = false`, so
Dash i-frames dodge it), then `CombatService.stun` and a **`Remotes.Knockback`** to that one
client. The knockback is applied by `client/features/combat/Knockback`, not the server: the client
owns its character's physics, so a velocity set on the server would be overwritten by the next
client physics update. It holds a horizontal `LinearVelocity` for `rushKnockbackSeconds` and kicks
`rushKnockbackUp` upward; a block halves the fling and scales the stun to 45%. The cooldown is
counted from the start of the windup. Measured in Studio from 25 studs: 0.72 s windup, contact
0.33 s into the charge, 1.27 s stun, player flung 19.5 studs.

**Health per variant.** A variant entry may set `health`; `EnemyService.spawn` already merges every
variant field except `model`, `weapon` and `weight` over its kind, so it overrides the kind's
value. The ladder and the reasoning are in `plans/gdd/content.md`.

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

`ContextActionService` binds each action once for keyboard/mouse and gamepad (`createTouchButton =
false`), while touch devices drive the exact same `CombatInput` entry points (`beginAttack`,
`endAttack`, `dash`, `spin`, `stinger`, `overDrive`, `beginBlock`, `endBlock`) from the machined
circular actuators in `CombatHud`'s lower-right radial arc (see
[ui-design-system.md](ui-design-system.md)). Moving and jumping stay Roblox's own controls, which
move relative to the camera — so WASD, the thumbstick and the gamepad stick all mean "up the
screen" with no code, and the touch arc wraps cleanly around Roblox's built-in bottom-right jump
button.

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Attack (tap) / Heavy Attack (hold 2 s) | Left click | X, R2 | Radial `ATK` actuator |
| Dash | Left Shift, Q | B, L2 | Radial `DSH` actuator |
| Active Ability (the class's slots `1` / `2` / `3`, see [classes.md](classes.md)) | `1`/`2`/`3` select, `E` cast | D-Pad select, Y / R1 cast | Direct radial ability actuators |
| Block / Parry (hold) | Right click, F | L1 | Radial `BLK` actuator |

Every input device — mouse, gamepad and touch — uses the same forward-cone target sticking
(`Melee.pickTarget` + `Melee.lungeDistance`), ignoring the mouse cursor. Pressing Attack reads
the character's movement direction (or current facing when standing still), searches enemies
within `AIM_ASSIST_RANGE` inside a forward `AIM_ASSIST_CONE` weighted toward angular alignment
(`AIM_ASSIST_ANGLE_WEIGHT`), and turns toward the winner. Once a basic attack or ability (such as
Spin) locks onto an enemy, continuing the combo within `COMBO_WINDOW` always keeps that same
target while it stays alive, in range, and within `TARGET_LOCK_CONE` of where the player is
heading (`lastEngageAt` is tracked separately from `lastSwingAt` so abilities can seed or refresh
the lock without altering the server-synced combo step). Steering away drops the lock immediately
and selects the new forward target. If the chosen enemy is farther than
`radius + ATTACK_LUNGE_STOP_DISTANCE`, the client applies a short horizontal `LinearVelocity`
step-in (up to `ATTACK_LUNGE_MAX_DISTANCE` at `ATTACK_LUNGE_SPEED`, respecting walls and gravity),
starts the attack windup immediately, and fires `Remotes.Attack` as the lunge closes the gap so
the server sees the updated position. `lastSwingAt` is anchored to lunge completion so the server's
interval gate never drops the following combo hit, and starting a dash or respawning cancels any
in-flight lunge cleanly via `lungeToken`.

Shift lock is turned off per player (`DevEnableMouseLock = false`): it toggles on Left Shift,
which is the dash.

## Audio

Combat sound effects live in `Config/Audio.luau` (`Config.SFX`) and are played by
`client/features/combat/SoundPlayer`:

- **Local player attack, dash and spin** play immediately in `Effects.slash` / `Effects.dash` /
  `Effects.spin` as non-spatial 2D cues with zero round-trip delay, while `CombatService`
  broadcasts them in 3D only to *other* players so co-op teammates hear them without
  double-playing for the attacker. Hit confirmation (`playerHit`) broadcasts once per swing that
  connected with at least one enemy.
- **Isometric audio listener:** because `IsoCamera` sits `Config.CAMERA_DISTANCE` (70) studs
  away, `SoundPlayer.start` attaches `SoundService:SetListener(Enum.ListenerType.ObjectPosition,
  root)` to the local character's `HumanoidRootPart`. Stereo panning still matches the camera,
  while 3D distance rolloff is measured from the player so nearby combat is never muffled by
  camera height.
- **Enemy cues** (`enemyMeleeWindup`, `enemyMeleeStrike`, `enemyRangedFire`, `enemyExploderFuse`,
  `enemyExploderBlast`) are broadcast from `EnemyService` over the server→client `CombatSfx`
  remote (no `Contract.luau` entry: the contract governs client→server remotes only).
- **3D spatial anchors live on `workspace.Terrain`**, not inside enemy models: an exploder
  destroys its `Model` on the frame it detonates, which would cut off the blast tail if the
  `Sound` were parented to its `Body`. Each temporary `Attachment` cleans up on `Sound.Ended`,
  after `maxDuration` (with a short fade), or at `Config.SFX_MAX_CLEANUP_SECONDS`.
- **Custom `.ogg` files vs Studio fallbacks:** every cue ships a custom Vorbis file under
  `assets/` (`player-attack.ogg`, `player-attack-heavy.ogg`, `player-dash.ogg`, `player-spin.ogg`,
  `player-hit.ogg`, `enemy-melee-windup.ogg`, `enemy-melee-strike.ogg`, `enemy-ranged-fire.ogg`,
  `enemy-exploder-fuse.ogg`, `enemy-exploder-blast.ogg`). `CombatAudio.resolveId` prefers
  `Assets.id(spec.file)` once uploaded via `make sync-assets`, and falls back to a verified
  public Creator Store `fallbackId` so unpublished local Studio sessions are audible immediately.
- **Looped playtest soundtrack (`Config.BGM`):** `SoundPlayer.start` loops a non-spatial 2D
  `Sound` (`ComplexBgm`) under `SoundService` backed by `assets/bgm-complex.ogg` once synced into
  `Assets/AssetIds.json`, falling back to `Config.BGM.fallbackId` until uploaded.

## Player animations

Player combat and jump animations live in `Config/Animations.luau` + `shared/features/combat/CombatAnim`
and are applied on the client by `client/features/combat/PlayerAnimator`:

- **Procedural `Transform` layering on `RunService.Stepped`:** Roblox's default `Animator` writes
  locomotion transforms before `Stepped`, and the renderer reads them after. Lerping joint
  `.Transform` inside `Stepped` lets upper-body combo attacks (hits 1 and 2) layer over running
  and jumping without replacing Roblox's `Animate` script, while heavy step 3, dash and 360-degree
  spin take over full-body pose smoothly and blend back out.
- **Supports both `AnimationConstraint` and `Motor6D`:** modern R15 rigs under Avatar Joint
  Upgrade spawn with `AnimationConstraint` joints rather than `Motor6D`. `PlayerAnimator` accepts
  both (plus R6 joint aliases) and watches `DescendantAdded` for late-replicating joints.
- **No external `AnimationId` ownership lock:** because poses are computed in Luau from
  `Config/Animations.luau`, they work identically in unpublished `local.rbxlx` sessions, `staging`
  and `main` without asset-ownership failures.
- **Local immediate + co-op broadcast:** `Effects` calls `PlayerAnimator.playLocal` on input for
  zero-latency attack, dash and spin feedback; `CombatService` broadcasts `Remotes.CombatAnim`
  (server→client, no `Contract.luau` entry) only to *other* players so teammates animate in co-op.
  Jump and landing squash are driven directly from each character's replicated `HumanoidStateType`
  and root vertical velocity, requiring no remote.

## Test sword, enemy drops, periodic defense buff, and Block / Parry

All combat 3D models (`ComplexArena`, `TestSword`, `DropHeal`, `DropDamage`, `DropSpeed`,
`DropDefense`, `EnemyMelee`, `EnemyMeleeDual`, `EnemyMeleeAxe`, `EnemyMeleeMace`, `EnemyRanged`,
`EnemyRangedShotgun`, `EnemyRangedCarbine`, `EnemyRangedMinigun`, `EnemyExploder`, `EnemyGrabber`)
are tracked `.rbxmx` assets under `assets/models/` generated by `lune run scripts/generate-arena.luau`
and `lune run scripts/generate-models.luau`, mounted at `ReplicatedStorage.Models` via
`default.project.json` (never built part-by-part at runtime, per `CLAUDE.md`). Every combat enemy
model anchors only `Body` and rigs limbs via `Group`-tagged `Motor6D` pivots so `EnemyService`
updates `Body.CFrame` while `EnemyAnimator` drives walk/strafe/sprint, weapon-specific melee
strikes, single-sword Paso Fantasma (`phantomStep`) multi-directional ambush dashes
(`phantomStepPose` + neon afterimage silhouettes in `_EnemyCorpses`, 3+ hops via
`Tactics.phantomStepWaypoint` into an unavoidable parry-only finisher slash that shadows the player
and passes `canDodge = false, canBlock = false, canParry = true` to `CombatService.hurt`,
telegraphed by an overhead yellow warning triangle `!` + pulsing `PhantomStepParryGlint`),
dual-blade DPS tornado spin (`spinPose` + danger disc), heavy mace seismic ground slam
(`slamWindupPose` + filling floor warning ring + `slamImpact` shockwave & debris checked via
`Hitbox.inEllipsoid`, staggering and stunning grounded players via `CombatService.stun` /
`StunnedUntil` + `CombatAnim.staggerPose`), ranged gun recoil (single orb, double-burst orb, or
6-round minigun tracer lines), rifle/plasma charged cylindrical rail-beam (`beamChargePose` +
cylindrical laser guide that locks `0.4 s` before `beamFire`, checked via `Hitbox.inBeam`),
ranged parabolic backstep evade leaps (`evadeJumpPose`, >=5 s cooldown), exploder fuse shake,
muscular grabber windup/lunge/hold (overhead yellow `!` triangle), and client death collapses at 60
FPS without Humanoids.

- **Arena (`ComplexArena.rbxmx`):** industrial sci-fi sector room (140×140 studs, floor top at
  `y = 0`) cloned by `WorldBuilder.build()`, with `SpawnLocation` placed from the arena's pivot
  (`pivot * Config.SPAWN_OFFSET`). North (`-Z`) and West (`-X`) are full-height hero walls (blast
  door, observation bay, columns, conduits, cyan/amber lights); South (`+Z`) and East (`+X`) use
  low cutaway curbs + invisible full-height containment bounds so `IsoCamera` (at `+X/+Z`) is never
  obstructed while keeping players inside. All decorative floor plates are `CanCollide = false` so
  dashes and lunges never snag.

- **Test sword:** `CombatService` clones `ReplicatedStorage.Models.TestSword` on `CharacterAdded`
  and `CharacterAppearanceLoaded`, welding its `PrimaryPart` (`Grip`) to `RightHand`
  (`RightGripAttachment`) with a `WeldConstraint`, pitched forward by `Config.SWORD_GRIP_PITCH`
  (70°). That attachment's `-Z` runs *down* the forearm, so the old 25° pitch with the full-size
  blade planted the tip ~2 studs under the floor whenever the arm relaxed. The model is generated
  at `SWORD_SCALE = 0.8` (`scripts/generate-models.luau`); measured in Studio, the tip now stays
  above the floor at rest, walking and through the combo. **`CombatAnim.blockPose` is solved
  against that pitch** — the guard holds the blade level across the chest only while the mount
  angle is unchanged, so re-solve the guard if the pitch moves.
- **Enemy drops (30% chance):** `EnemyService` invokes `DropService.maybeSpawn` on player kills
  (`heal`, `damage`, `speed` via `Config.DROP_WEIGHTS`).
- **Periodic defense buff (50% reduction):** while `RoomState == "fighting"`, `DropService` spawns
  a `DropDefense` shield at a random inset room position every `Config.DEFENSE_SPAWN_INTERVAL`
  seconds (at most one active on the floor). Picking it up sets `DefenseBuffUntil` for
  `Config.BUFF_DEFENSE_DURATION` seconds, halving incoming damage from every source (including
  grabber drain) and stacking with Block.
- **Block and Parry:** holding Block fires the contracted `Block(true)` / `Block(false)` remote.
  `CombatService.block` sets `Blocking = true` and opens `ParryUntil = now + Config.PARRY_WINDOW`,
  slowing `WalkSpeed` via `Defense.walkSpeed`; releasing starts `Config.BLOCK_COOLDOWN`.
  `CombatService.hurt` returns `(hitLanded, outcome)` via `Defense.resolveHit`:
  - `parry` deals 0 damage, triggers `playerParry` SFX + `parry` animation, staggers melee
    attackers (`Config.PARRY_STUN_SECONDS`), and **reflects ranged projectiles** back at the shooter
    (or nearest living enemy) at `Config.PARRY_PROJECTILE_SPEED_MULTIPLIER` speed for
    `Config.PARRY_PROJECTILE_DAMAGE` damage.
  - `block` reduces damage by `Config.BLOCK_DAMAGE_REDUCTION` (70%), stacks with the 50% defense
    buff, and plays `playerBlock`.
- **Visuals and HUD:** `DropVisuals` bobs/spins pickups on `RenderStepped`, `PlayerAnimator`
  renders the continuous `blockPose` whenever `Blocking == true` (plus the one-shot `parry` sweep),
  and `CombatHud` renders a top-left red health bar (+ active buff countdown bars only when active),
  top-center wave/telegraph banners, and a bottom-left 3-slot switchable ability bar (`1` Giro,
  `2` Stinger, `3` Over Drive, backed by `AbilityStore` and omitting Dash and Block/Parry bars) via
  `React.useBinding`.

## What is not verified offline

`make test` covers `CombatAnim`, `CombatAudio`, `Defense`, `Drops`, `Melee`, `Brain`, `EnemyAnim`, `Hitbox`, `SpatialGrid`, `Tactics` and `Waves`. Everything that needs a DataModel — the camera,
the dash's feel, the touch buttons' placement, enemies moving, 3D audio playback and volume balance, animation silhouettes and feel, sword grip alignment, drop pickup feel, the HUD — only shows up in Studio.
The touch buttons in particular sit where `ContextActionService` puts them by default; check them
with phone emulation before relying on them.
