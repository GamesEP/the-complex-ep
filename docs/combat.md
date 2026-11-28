# Combat

How the combat slice works: the player's kit, the enemies, the waves, and who decides what. The
design (what the player experiences and why) is [plans/gdd/systems.md](../plans/gdd/systems.md)
and [plans/gdd/scope.md](../plans/gdd/scope.md); this is how it is built.

| | |
|---|---|
| `shared/features/combat/CombatAnim` | Pure: procedural player poses (combo, block/parry, jump/land, dash, spin) and interrupt priorities. |
| `shared/features/combat/CombatAudio` | Pure: combo cue selection, uploaded-vs-fallback id resolution, pitch variation. |
| `shared/features/combat/CombatState` | Pure: player combat state machine & movement policy (`WalkSpeed=0`/`AutoRotate=false` during Startup/Active/Lunge/Hitstop/Ability, opposite-direction lunge abort, Startup ±35° micro-pivot, hitstop/whiff cancel timing, Recovery move-cancel, heavy-only HeavyCharge interruption). |
| `shared/features/combat/Defense` | Pure: hit resolution priority (`invulnerable > parry > block > hit`), 50% defense buff stacking, and WalkSpeed calculation (including `attackLocked`). |
| `shared/features/combat/Melee` | Pure: the combo, the swing arc, the spin radius, forward target selection and attack lunge math. Both realms call it. |
| `shared/features/drops/Drops` | Pure: 30% drop roll, weighted kind selection, heal clamp, and damage/speed buff math. |
| `shared/features/enemies/Brain` | Pure: what an enemy (including Boss Oh) does each frame, as a state machine. |
| `shared/features/enemies/Difficulty` | Pure: 4-tier difficulty scaling (`easy`, `normal`, `hard`, `deadzone`) for wave counts (bosses stay at 1), health, damage, and speed. |
| `shared/features/enemies/EnemyAnim` | Pure: procedural enemy limb poses for walking, weapon-specific melee windup/strike (`sword`, `dual`, `axe`, `mace`), Boss Oh attacks, and death collapse. |
| `shared/features/enemies/Hitbox` | Pure: 3D ellipsoid hit checks for projectiles, melee strikes and oval explosions. |
| `shared/features/enemies/SpatialGrid` | Pure: uniform 2D spatial hash grid for local enemy lookups without full-list scans. |
| `shared/features/enemies/Tactics` | Pure: squad AI coordination (melee attack tokens, flanking orbit, ranged stagger/strafe, exploder intercept lead, grabber flank bias, co-op spread). |
| `shared/features/enemies/Waves` | Pure: what a wave contains, where it spawns, keeping things inside the room and clear of `Config.ARENA_PILLARS`. |
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
| `client/features/enemies/EnemyAnimator` | Client-side 60 FPS `Motor6D.C0` animator for rigged `.rbxmx` enemies (walking, weapon attacks, axe throw/retrieve, ranged recoil, and client-side death collapses). |
| `client/features/world/ArenaTheme` | Smoothly tweens `ComplexArena` neon accents, PointLights, and `Lighting` ambient across `Config.WAVE_THEMES` as `World.Wave` advances. |

Every number is in `Config/Combat.luau`, `Config/Drops.luau`, `Config/Enemies.luau`, `Config/Difficulty.luau`, `Config/World.luau`, `Config/Audio.luau` and `Config/Animations.luau`.

## Who decides what

**The client moves; the server judges.** Roblox gives each client network ownership of its own
character, so movement — including the dash — is the client's. Everything that decides an
outcome is the server's: what a swing hit, whether a cooldown allowed it, and the dash's
invulnerability window.

Each action is predicted on the client and confirmed by the server:

| Action | Client, at once | Server, on the remote |
|---|---|---|
| Attack | Resolves lock/forward target (extended to `STAFF_AIM_ASSIST_RANGE` with no lunge for ranged Support); for melee, tracks a zero-overshoot lunge stopping at sweet-spot range (`radius + ATTACK_LUNGE_STOP_DISTANCE`), plays 3-phase swing+recovery anim/SFX (cancelable from `cancelAt`), fires `Attack(aim)` | Checks light/finisher swing interval (`Melee.attackInterval`), advances the combo; damages & applies hitstun/daze (`light` / `medium`) to every enemy in the melee arc for Tank/Damage, or launches a traveling `staffBolt` (with finisher splash on step 3) for Support |
| Heavy Attack (hold Attack 2 s) | Tap still attacks immediately; holding past `HEAVY_CHARGE_DELAY` starts role-tinted charge ring/SFX and fires `HeavyCharge(true)`. At `HEAVY_CHARGE_SECONDS` (2 s) triggers role-specific heavy VFX/SFX and fires `HeavyAttack(aim)` | Tracks server-side charge clock (`ChargingHeavy`, `HeavyChargeStart`), slows `WalkSpeed`, verifies full charge (`Melee.isChargeReady`), then executes Tank seismic slam (+stun), Damage twin X-slash, or Support explosive arcane orb (+AoE stun); enemies hit take heavy hitstun |
| Dash | Immediately cancels active/recovery combat animations & lunges, applies dash velocity, fires `Dash()` | Checks the cooldown, sets `DashReadyAt`, grants `InvulnerableUntil` |
| Spin (`1` + `E`) | Lunges up to `SPIN_LUNGE_MAX_DISTANCE` stopping at sweet-spot range, draws the ring, plays 3-phase spin+recovery anim (cancelable at `cancelAt`), fires `Spin()` | Checks `SpinReadyAt`, damages & medium-hitstuns everything in `SPIN_RADIUS` |
| Stinger (`2` + `E`) | Applies high-speed forward thrust `LinearVelocity` stopping right at sweet-spot range (`radius + STINGER_STOP_DISTANCE`) before a locked target (or full `STINGER_DISTANCE` with no target), draws lance streak & recovery anim, fires `Stinger(aim)` | Checks `StingerReadyAt`, pierces & heavy-hitstuns every enemy along `Melee.inCorridor` (`STINGER_DISTANCE` × `STINGER_WIDTH`) |
| Over Drive (`3` + `E`, Ult) | Faces target, fires `OverDrive(aim)` | Checks `OverDriveReadyAt` (`14 s`), enters `OverDriveCharging` (`0.75 s`), then fires 3 sequential piercing ranged waves (`Melee.inCorridor`, `56` studs, `OVERDRIVE_WAVE_INTERVAL = 0.34 s`) with heavy hitstun, synced via `CombatVfx`/`CombatAnim`/`CombatSfx` |

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
`Melee.attackInterval` selects `ATTACK_INTERVAL` (0.36 s) for light combo steps and
`ATTACK_FINISHER_INTERVAL` (0.50 s) after the heavy 3rd hit, while `ATTACK_TOLERANCE` lets
recovery-cancels arrive a little closer than the exact interval so network jitter never drops a
chain.

**Enemy hitstun and progressive suppression (`Brain.applyHitstun` + `Brain.dazeSpeedFactor`).**
Every player attack and skill goes through `CombatService`'s `hitEnemy` (so the class multiplier and
the Damage passive always apply) and passes a hit tier (`light`, `medium`, `heavy`) and attacker
origin into `EnemyService.damage`; class abilities default to `light`, staff bolts are `light` /
`medium` (finisher) / `heavy` (charged orb). Hits interrupt normal enemy windups, ranged bursts, rail-beam charges,
mace slam windups, and dual spins, putting the target into the `hitstun` phase (flinching via
`EnemyAnim.hitstunPose` driven by `HitCount`), pushing back its next attack/evade cooldowns by
`ENEMY_HIT_ACTION_DELAY`, applying a short damped recoil away from the attacker (clamped inside
room walls with dampened crowd separation so nearby enemies do not shove the target out of combo
range), and stacking a lingering daze slowdown (`ENEMY_DAZE_SPEED_FACTORS` for
`ENEMY_DAZE_SECONDS`) so each consecutive hit leaves the enemy less able to act or move. Grabbers
currently `holding` a player, spent exploders, active Paso Fantasma dashes, and anything mid-flight
(a grabber `rush`, a boss `bossLeap`, an axe enemy in `axeRetrieve`) are excluded. Hitstun is
skipped entirely while a hard stun (`EnemyService.stun`, `stunUntil`) holds the enemy — writing
`hitstun` over the `stunned` Phase would stop the stun's exit from clearing its telegraph and
resuming an axe retrieve — and bosses (`spec.isBoss`) have super armour against it, or any
combo would chain-lock the only boss in the room.

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
| `bossOh` | Oh | Wave 6 heavy mechanical titan boss (cone smash, seismic leap, 360° plasma nova) |

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

**Difficulty scaling (`Config/Difficulty.luau` + `shared/features/enemies/Difficulty`).** Players
select one of 4 tiers (`easy`, `normal`, `hard`, `deadzone` — *Fácil*, *Normal*, *Difícil*, *Zona
Muerta*) via the contracted `ChooseDifficulty` remote in `ClassSelect`, stored on
`workspace.World:GetAttribute("Difficulty")`. `WaveDirector` scales non-boss wave counts with
`Difficulty.scaleWave` (reserving bosses at `1`), and `EnemyService.spawn` runs
`Difficulty.scaleSpec` on every enemy's merged spec to scale `health`, movement/charge/projectile
speeds, and all damage fields cleanly. Changing difficulty while the room is paused resets the
queued wave cleanly.

**Boss "Oh" (Wave 6, `assets/models/BossOh.rbxmx`).** An 11-stud rigged mechanical titan spawning
near the North Blast Door with `650` base HP (scaled by difficulty) and 50% stun duration
resistance. `Brain` cycles three telegraphed attacks:
- **Frontal Cone Smash (`bossConeWindup` -> `bossConeSmash`):** 0.85 s ground fan warning (`115°`,
  `24` studs), followed by an overhead maul sweep dealing `coneDamage` and `coneStunDuration`.
- **Seismic Meteor Leap (`bossLeapWindup` -> `bossLeap`):** triggered at `16–55` studs on cooldown;
  locks a red ground impact ring (`18` studs), arcs `16` studs high over `0.72 s`, and slams the
  landing zone for `leapDamage` + `leapStunDuration`.
- **360° Plasma Nova (`bossNovaWindup` -> `bossNovaFire`):** 1.0 s reactor overcharge ring, then
  fires 2 staggered rings of 10 plasma orbs (blocked by the 4 reactor pillars or reflectable via
  Parry).
`EnemyService` mirrors the active boss onto `workspace.World` attributes (`BossName`, `BossHealth`,
`BossMaxHealth`), which `CombatHud` renders as the bottom-center `BossBar`.

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

Every input device — mouse, gamepad and touch — uses the same DMC-style soft target lock,
tracked sweet-spot lunge, and recovery-cancel system (`Melee.pickTarget`, `Melee.shouldKeepLock`,
`Melee.lungeDistance`, and `CombatAnim.canInterrupt`), ignoring the mouse cursor. Pressing any
basic attack or melee skill (Spin, Stinger, Heavy Attack) locks onto the best enemy within
`AIM_ASSIST_RANGE` inside the forward `AIM_ASSIST_CONE` weighted toward angular alignment
(`AIM_ASSIST_ANGLE_WEIGHT`), renders a ground lock ring via `Effects.updateLockIndicator`, and
tracks a horizontal `LinearVelocity` impulse toward the live target on `RenderStepped`. The lunge
brakes and zeros horizontal `AssemblyLinearVelocity` the instant the player reaches sweet-spot
range (`radius + ATTACK_LUNGE_STOP_DISTANCE`, or `radius + STINGER_STOP_DISTANCE` for Stinger),
eliminating physics overshoot so every swing lands cleanly in the middle of melee reach.

Once locked onto an enemy, the lock persists (`TARGET_LOCK_DURATION`) as long as the target stays
alive inside `TARGET_LOCK_BREAK_RANGE` and the player either presses **no movement direction** or
steers in the **general direction of the target** (`TARGET_LOCK_CONE = 120°`, ±60°). While locked
during active swings or recovery, a gentle wall-safe magnetic follow (`TARGET_LOCK_MAGNET_RANGE`)
tracks the target's slight hitstun recoil to keep the player glued in range. The moment the player
inputs **any other direction** outside `TARGET_LOCK_CONE`, the lock breaks immediately — letting
them walk away freely or attack/skill directly onto a different target in the new direction.

Every attack and ability carries a longer, deliberate animation (`Config.ANIMATIONS` durations
scaled ~1.5x–2.4x) driven by the shared state machine in `shared/features/combat/CombatState.luau`:

- **Committed attack movement (zero sideways/backward skating or jitter between hits):** During
  `ApproachLunge` (stopping close at `targetRadius + ATTACK_LUNGE_STOP_DISTANCE` = `1.1` studs with
  a `0.035 s` `ATTACK_POST_LUNGE_SETTLE_SECONDS` arrival-replication beat so the first hit always
  connects on the server), `Startup`, `Active`, `Hitstop`, `AbilityCommit`, `Dash`, `ParryCounter`,
  and `Recovery`, `CombatInput` keeps `Humanoid.WalkSpeed = 0` and `Humanoid.AutoRotate = false` so
  **only the attack or ability's own motion** moves the player. While locked onto a target (neutral
  or general-direction input inside `TARGET_LOCK_CONE`), the player continuously rotates to face the
  target across `Startup`, `Active`, `Hitstop`, and `Recovery`, and never obeys `WalkSpeed` between
  buffered/chained combo hits.
- **Opposite-direction lunge abort (`LUNGE_ABORT_ANGLE = 120°`):** Steering more than 120° away
  from an active melee `ApproachLunge` aborts the lunge immediately, drops the old lock, searches
  `MoveDir` for a new target, and fires the swing/step along the new direction.
- **Lingering multi-frame active hitboxes (`CombatService` + `Melee.inHitbox`):** Basic combo
  swings (`ATTACK_ACTIVE_SECONDS = 0.16 s` light / `ATTACK_FINISHER_ACTIVE_SECONDS = 0.22 s`
  finisher), Heavy Attack (`HEAVY_ATTACK_ACTIVE_SECONDS = 0.24 s`), Spin (`SPIN_ACTIVE_SECONDS =
  0.30 s`), and Stinger (`STINGER_ACTIVE_SECONDS = 0.26 s`) spawn a server-authoritative
  `ActiveHitbox` stepped on every `Heartbeat` rather than a 1-frame snapshot. Soft-lock still
  picks a single active target for lunge/rotation, while the lingering hitbox follows the player's
  live root and cleaves any and multiple enemies entering the active sector/radius/corridor (each
  enemy hit at most once per swing via `hitSet`). Dash, Block, Stun, Grab, or starting a new swing
  cancels any lingering hitbox immediately. The server broadcasts `CombatVfx("hitboxActive", ...)`
  and `"hitboxEnd"` so the Debug `HitboxVisualizer` (`Ataque Activo` layer) renders the exact live
  hitbox even when swinging into empty air (flashing green on `"hitConfirm"`).
- **Hitstop & hit-confirm vs. whiff:** When `CombatService` confirms ≥ 1 enemy hit, it fires
  `CombatVfx("hitConfirm", tier, hitPos, anyKilled, allArmored)` back to the attacker, triggering a
  tactile `PlayerAnimator.hitstop` pose freeze (`35–75 ms`), impact sparks, subtle `IsoCamera.shake`,
  immediate dead-target lock clear, and faster `cancelAt` than a whiff (`ATTACK_WHIFF_CANCEL_PENALTY = 0.04 s`).
- **Recovery cancels & opposite-direction move-cancel:** Pressing **any attack or any of the 9
  drafted abilities** once `elapsed >= cancelAt` (or within `COMBO_INPUT_BUFFER = 0.18 s`) fires
  before `Recovery` can unlock locomotion, preventing any single-frame movement leak between attacks.
  `Recovery` only restores `WalkSpeed` & `AutoRotate = true` early when the player steers in an
  **opposite/break direction** (`CombatState.isSteeringAway`, outside `TARGET_LOCK_CONE`) past
  `moveCancelAt` with no buffered move, or once `Recovery` finishes completely (`endsAt`) without a
  buffered/canceling move. `Dash` and `Block` cancel immediately at any point.
- **Heavy-only charge interruption & single velocity owner:** Normal/light enemy hits deal damage
  without interrupting an active `HeavyCharge`; only `heavy = true` enemy attacks (Exploder blast,
  Mace slam, Rifle/Plasma rail-beam, Paso Fantasma ambush, Boss Oh cone/leap, Coloso rush) and CC
  (Stun, Knockback, Grab, Death) cancel it (`CombatState.shouldCancelHeavyCharge`). `Knockback`
  notifies `CombatInput.beginKnockback` so at most one `LinearVelocity` owns `HumanoidRootPart` at
  any time, and `StunnedUntil`/`Grabbed` tear down Dash, Lunge, Step, and Startup together.

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
`default.project.json` (never built part-by-part at runtime, per `CLAUDE.md`). Every combat enemy model anchors only an invisible `Body` root and rigs every visible part
(including `TorsoCore`) via `Group`-tagged `Motor6D` pivots so `EnemyService` updates `Body.CFrame`
while `EnemyAnimator` drives hierarchical 60 FPS limb poses (head and arms inherit `torso`
crouches/twists/recoil, and dual-blade `spinPose` rotates the whole connected body around `Body`'s
center via `pose.root` rather than spinning individual limbs in place): walk/strafe/sprint,
weapon-specific melee strikes, single-sword Paso Fantasma (`phantomStep`) multi-directional ambush
dashes
(`phantomStepPose` + neon afterimage silhouettes in `_EnemyCorpses`, 3+ hops via
`Tactics.phantomStepWaypoint` into an unavoidable parry-only finisher slash that shadows the player
and passes `canDodge = false, canBlock = false, canParry = true` to `CombatService.hurt`,
telegraphed by an overhead yellow warning triangle `!` + pulsing `PhantomStepParryGlint`),
dual-blade DPS tornado spin (`spinPose` + danger disc), heavy axe throw (`axeThrowWindupPose` ->
spinning `ThrownAxe` projectile; on miss embeds `DroppedEnemyAxe` on the floor and transitions
into `axeRetrieve` / `axeRetrievePose` until picked back up, hiding in-hand axe parts via
`AxeThrown`), heavy mace seismic ground slam (`slamWindupPose` + filling floor warning ring +
`slamImpact` shockwave & debris checked via `Hitbox.inEllipsoid`, staggering and stunning grounded
players via `CombatService.stun` / `StunnedUntil` + `CombatAnim.staggerPose`), pronounced ranged
gun recoil (`firePose` across rifle, plasma, 4-way diverging shotgun tracer fan, and 6-round
minigun tracer bursts), rifle/plasma charged cylindrical rail-beam (`beamChargePose` +
cylindrical laser guide that locks `0.4 s` before `beamFire`, checked via `Hitbox.inBeam`),
ranged parabolic backstep evade leaps (`evadeJumpPose`, >=5 s cooldown), exploder fuse shake,
muscular grabber windup/lunge/hold (overhead yellow `!` triangle), and client death collapses at 60
FPS without Humanoids.

- **Arena (`ComplexArena.rbxmx`):** industrial sci-fi sector room (140×140 studs, floor top at
  `y = 0`) cloned by `WorldBuilder.build()`, with `SpawnLocation` placed from the arena's pivot
  (`pivot * Config.SPAWN_OFFSET`). North (`-Z`) and West (`-X`) are full-height hero walls (blast
  door with holo-status boards, observation bay, columns, conduits, overhead gantry cranes, server
  racks, cryo tank clusters, cyan/amber lights); South (`+Z`) and East (`+X`) use low cutaway curbs
  + low cargo pallets + invisible full-height containment bounds so `IsoCamera` (at `+X/+Z`) is
  never obstructed while keeping players inside. Inside the room sit **4 solid quadrant reactor
  pillars** at `(±38, ±38)` (SE kept shorter at `8.5` studs for camera sightline) plus **5 solid
  chest-high tactical cover bunkers** (`Config.ARENA_PILLARS`), recessed glowing floor turbine
  vents, overhead pillar conduit bridges, and perimeter industrial props. `Waves.avoidObstacles`
  and `Waves.hitsObstacle` keep enemy movement, spawns, drops, and projectiles (`EnemyService` +
  `CombatService` `staffBolt` + `DropService`) respecting every pillar and bunker as real tactical
  cover. Every standing structure and perimeter prop except the 5 cover bunkers (pillars, crates,
  barrels, cryo tanks, consoles, server racks, pallets, bollards) carries a full-height (`36` stud)
  invisible anti-climb collision hull (`CanCollide = true`, `CanQuery = true`) paired with a 4-wall
  + ceiling invisible containment shell so players cannot pass through props, climb onto
  tall/perimeter structures, or exit the room. The 5 low tactical cover bunkers (`CoverBunkers`)
  use matching-height solid colliders (`3.55–3.95` studs) so they are the only structures players
  can jump onto and stand on top of. All decorative floor plates and vents are `CanCollide = false` so dashes and
  lunges never snag. Client horizontal impulses (Dash, Estocada, Attack Lunge, and `Knockback`)
  use bounded finite `MaxForce` + per-frame `RespectCanCollide` spherecast wall-stops and an
  out-of-bounds clamp in `CombatInput` so dashing into walls or pillars stops flush without flinging.

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
    attackers (`Config.PARRY_STUN_SECONDS`), and **reflects parriable ranged projectiles** back at
    the shooter (or nearest living enemy) at `Config.PARRY_PROJECTILE_SPEED_MULTIPLIER` speed for
    `Config.PARRY_PROJECTILE_DAMAGE` damage. Minigun tracers (`EnemyRangedMinigun`, `canParry =
    false`) cannot be parried — holding Block reduces their damage by 70%, while Dash, Jump, and
    arena cover avoid them cleanly.
  - `block` reduces damage by `Config.BLOCK_DAMAGE_REDUCTION` (70%), stacks with the 50% defense
    buff, and plays `playerBlock`.
- **Visuals and HUD:** `DropVisuals` bobs/spins pickups on `RenderStepped`, `PlayerAnimator`
  renders the continuous `blockPose` whenever `Blocking == true` (plus the one-shot `parry` sweep),
  and `CombatHud` renders a top-left red health bar (+ active buff countdown bars only when active),
  top-center wave/telegraph banners, and a bottom-left 3-slot switchable ability bar (`1` Giro,
  `2` Stinger, `3` Over Drive, backed by `AbilityStore` and omitting Dash and Block/Parry bars) via
  `React.useBinding`.

## What is not verified offline

`make test` covers `CombatAnim`, `CombatAudio`, `Defense`, `Drops`, `Melee`, `Brain`, `Difficulty`, `EnemyAnim`, `Hitbox`, `SpatialGrid`, `Tactics` and `Waves`. Everything that needs a DataModel — the camera,
the dash's feel, the touch buttons' placement, enemies moving, 3D audio playback and volume balance, animation silhouettes and feel, sword grip alignment, drop pickup feel, the HUD — only shows up in Studio.
The touch buttons in particular sit where `ContextActionService` puts them by default; check them
with phone emulation before relying on them.
