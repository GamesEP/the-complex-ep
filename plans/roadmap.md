# The Complex — Production Roadmap

Status: drafted

This roadmap breaks down the full Game Design Document ([`plans/gdd/`](gdd/overview.md)) into three
sequential milestones, divided into small, independently verifiable tasks for the team:

1. **Phase 1 — Polished Vertical Slice (`VS-01`–`VS-25`):** Polish and verify the existing combat
   slice on PC, mobile, and gamepad, then complete the **1-floor run loop** (5 authored rooms,
   zero-pause 1-of-3 run upgrades with queue, Boss **Oh** in Room 5, `RunResult`, instant Retry).
2. **Phase 2 — Polished Horizontal Slice (`HS-01`–`HS-32`):** Build the full gameplay breadth — the
   remaining **2 enemy types** (completing all 6), **5 floors × 5 randomized rooms**, Bosses **My**,
   **Gon**, and 2-phase **OhMyGon**, plus **1–4 player Co-op** (isolated Hub, Open/Private Parties,
   reserved private Run servers, and Downed / 5 s Ally Revive).
3. **Phase 3 — Almost Ready-to-Publish (`RP-01`–`RP-21`):** Add **permanent meta-progression &
   DataStore persistence** (permanent currency, Skill Tree, unlockable abilities, run perks), full
   asset upload & audio/UX polish, settings, exploit/memory/FPS hardening, and staging deployment
   readiness — **explicitly excluding monetization, Robux dev products/passes, and cosmetics** for
   now, while leaving clean hook points for them.

---

## Baseline: What Exists Today

Before assigning tasks, the team is starting from commit `6042371` (`develop`), which already ships
an expanded single-room **Combat Slice** passing `make check`:

- **Implemented:** Isometric camera; 3-hit combo with soft lock-on, wall-safe tracked lunges,
  recovery-cancel animations, and progressive enemy hitstun/daze; 2 s role-specific heavy attacks;
  dash with i-frames (double dash on speed buff); hold-to-block & parry (melee stun + projectile
  reflection); 3 test classes (`Tanque`, `Daño`, `Apoyo`) with 9 abilities & weapons; 4 difficulty
  tiers (`Fácil`, `Normal`, `Difícil`, `Zona Muerta`); 4 of 6 enemy archetypes (`Centinela` ×4
  weapons, `Cazador` ×4 weapons, `Detonante`, `Coloso`) + Boss **Oh** (Wave 6); squad AI (`Brain`,
  `Tactics`, `SpatialGrid`, `Hitbox`); `ComplexArena.rbxmx` with pillars, tactical bunkers, and wave
  lighting themes; 4 temporary combat drops; procedural player/enemy animations; `CombatHud` &
  `ClassSelect` (Hazard Arc); `Contract.luau` networking, `Environment`, `Flags`, and `LogSink`.
- **Not yet done:** Only `bgm-complex.ogg` is uploaded in `AssetIds.json` (all 19 SFX `.ogg` files
  still use Studio fallbacks); Studio verification across PC/mobile/gamepad is incomplete; 6 class
  abilities still use placeholder VFX/anims; no multi-room floor/run loop, no 1-of-3 upgrades, no
  `RunResult`; missing 2 enemy types (**En área**, **Por contacto**); missing Bosses **My**, **Gon**,
  **OhMyGon**; no Hub/Party/Teleport/Revive; no permanent currency, Skill Tree, or DataStore
  persistence; `Config.ENV_UNIVERSES` and `Config.FLAGS` are still empty.

---

## Team Conventions for Every Task

Every task below follows [`CLAUDE.md`](../CLAUDE.md):
- **Branch:** Work on `develop` (or short-lived feature branches merged into `develop`). Never touch `main`.
- **Tunables:** Every number goes into `src/shared/core/Config/` and is named in `plans/gdd/`.
- **Architecture:** Realm first (`shared/`, `server/`, `client/`), then feature. Bootstraps are
  wiring only; features never require sibling features by path.
- **Networking:** Every client→server remote gets a `src/shared/core/Net/Contract.luau` entry.
- **3D Models:** Author as `.rbxmx` under `assets/models/` (via Lune `@lune/roblox` or `make syncback`)
  with explicit `PrimaryPart` and pivot — never build runtime parts with `Instance.new`.
- **Verification:** Run `make check` (`test` + `globals` + Rojo build) on every code task. When
  Studio verification is listed, confirm synced `.Source` in Edit before pressing Play and record
  measured numbers (not eyeballed screenshots).
- **Docs:** Update `plans/gdd/` (what/why) and `docs/` (how) in the same PR as the code change.

---

## Phase 1 — Polished Vertical Slice

**Goal:** One complete, ship-quality slice of *The Complex* from entry to victory/defeat: pick
difficulty/starter kit, fight through **5 fixed rooms on 1 floor**, draft **1-of-3 upgrades without
pausing**, defeat **Boss Oh** in Room 5, view `RunResult`, and retry seamlessly — polished and
verified on **PC, mobile, and gamepad** with real uploaded audio and stable FPS.

### 1A. Design Lock & Doc Alignment

- [ ] **VS-01 · Resolve Classes vs. 1-of-3 Run Upgrades (Pillar 1 decision)**
  - **Area:** Design / GDD · **Depends on:** None
  - **Work:** Decide whether the 3 classes (`Tanque`, `Daño`, `Apoyo`) coexist with 1-of-3 upgrades
    (class sets base weapon/stats/passive while 1-of-3 builds active abilities & passives) or are
    replaced by Pillar 1's "everyone starts equal + pick 1 of 3 starter abilities." Update
    `plans/gdd/pillars.md`, `plans/gdd/systems.md`, `plans/gdd/loop.md`, and `plans/gdd/overview.md`
    accordingly.
  - **Verify:** Open question removed from `plans/gdd/overview.md` and `pillars.md`; team agrees on
    the exact flow before `VS-15` starts.

- [ ] **VS-02 · Decide Coloso rush→grab grace window & Boss Oh hitstun rule**
  - **Area:** Design / GDD · **Depends on:** None
  - **Work:** Close two open gameplay calls: (1) whether Coloso's bull rush adds a grab cooldown so
    rush→instant grab cannot chain-lock players (`plans/gdd/content.md`), and (2) confirm Boss Oh's
    full hitstun immunity vs. reduced hitstun (`docs/combat.md`). Update `Config/Enemies.luau` and
    `Brain.luau` if changed.
  - **Verify:** Decisions recorded in `plans/gdd/content.md` and `docs/combat.md`; `make check` passes
    if code/config changed.

- [ ] **VS-03 · Fix existing documentation drift before expanding**
  - **Area:** Docs · **Depends on:** None
  - **Work:** Audit and fix stale references currently in docs: `README.md` (lists old 5 waves, old
    ability names `Provocación`/`Muralla`/`Ejecución`/`Pulso curativo`/`Campo protector`/`Onda de
    choque`, and says "no bosses"), `docs/ui-design-system.md` (still mentions "3-second Heavy
    Attack" and "future Boss HP bar"), and `docs/classes.md` (mentions `Muralla` in Not Verified).
  - **Verify:** All docs match `Config/Combat.luau`, `Config/Classes.luau`, `Config/Enemies.luau`,
    and `plans/gdd/systems.md`.

### 1B. Combat Slice Studio Verification & Polish

- [ ] **VS-04 · Studio verify merged combat mechanics (hitstun, wall-safe lunges, Boss Oh, axe retrieve)**
  - **Area:** QA / Combat · **Depends on:** None
  - **Work:** Test and fix any issues from commit `6042371` in Studio: (1) melee lunges & dashes
    into pillars/bunkers/walls never clip or drop swings; (2) Support ranged combo never lunges into
    melee; (3) Boss Oh under full combo stays immune to hitstun and executes all 3 attacks cleanly;
    (4) hitting an axe Centinela during `axeRetrieve` does not leave it permanently unarmed; (5)
    hard stun (`Rugido`, `Repulsión`, `Parry`) cleanly exits telegraphs without hitstun overwriting
    `Phase`.
  - **Verify:** All 5 scenarios verified in Studio Play with measured observations logged; any fixes
    covered by `Brain.selfTest` / `Melee.selfTest` and `make check`.

- [ ] **VS-05 · Reconcile Roblox default health regeneration & verify class abilities in Studio**
  - **Area:** Combat / Server · **Depends on:** None
  - **Work:** Disable or override Roblox's default `Health` character script (1% max HP/s passive
    regen) so damage, heal drops, and Support's healing/passive actually matter and can be measured.
    Verify in Studio: `Rugido` forces target switch onto Tank, `Coraza` (-75%) and `Barrera` (-45%)
    apply exact damage multipliers, `Santuario` ticks exact HP/s, and Support passive regenerates
    nearby allies.
  - **Verify:** Measured HP deltas in Studio match `Config/Classes.luau` formulas within 1 HP; no
    silent default regen; `make check` passes.

- [ ] **VS-06 · Polish VFX and procedural animations for the 6 class abilities**
  - **Area:** Combat / Client · **Depends on:** `VS-05`
  - **Work:** Replace placeholder VFX/missing poses noted in `docs/classes.md` for `Rugido`,
    `Coraza`, `Vórtice` (boomerang blades), `Santuario` (persistent 10 s healing ring), `Barrera`
    (squad-wide shield pulse), and `Repulsión` (radial shockwave) in `CombatAnim.luau`,
    `PlayerAnimator.luau`, and `Effects.luau`. Check all weapon grip poses (`WeaponSpikedMace`,
    `WeaponShield`, `WeaponDagger`, `WeaponStaff`) across idle, run, combo, block, and heavy charge
    so no weapon clips the floor.
  - **Verify:** `CombatAnim.selfTest` passes; Studio check confirms clear silhouette, distinct audio
    & visual read, and zero floor clipping for all 3 classes.

- [ ] **VS-07 · Upload all combat audio assets & balance SFX/BGM mix**
  - **Area:** Audio · **Depends on:** None
  - **Work:** Run `make sync-assets` to upload all 19 `.ogg` combat sound files under `assets/` into
    `src/shared/core/Assets/AssetIds.json`. Add dedicated SFX cues for Boss Oh (cone smash, leap
    impact, plasma nova) and class abilities if missing. Tune `Volume`, pitch jitter, and 3D rolloff
    in `Config/Audio.luau` during a live Studio fight.
  - **Verify:** `AssetIds.json` contains real asset IDs for every `.ogg` in `assets/`; Studio test
    confirms zero audio clipping, audible telegraphs over BGM, and proper 3D listener positioning.

- [ ] **VS-08 · Combat feel & difficulty tuning pass in Studio**
  - **Area:** Combat / Balance · **Depends on:** `VS-04`, `VS-05`
  - **Work:** Playtest Waves 1–6 across `easy`, `normal`, `hard`, and `deadzone` and tune feel
    numbers in `Config/Combat.luau`, `Config/Classes.luau`, `Config/Enemies.luau`, and
    `Config/Difficulty.luau` (hitstop/hitstun timings, dash/combo cadence, enemy TTK vs. the health
    ladder in `plans/gdd/content.md`, Boss Oh telegraph readability). Mirror any changed numbers in
    `plans/gdd/systems.md` and `content.md`.
  - **Verify:** A solo player on `Normal` clears Waves 1–6 smoothly with rewarding parry/dash timing;
    `Hard` and `Zona Muerta` feel distinctly deadlier; `make check` passes.

- [ ] **VS-09 · Cross-platform input & HUD audit (PC, Gamepad, Mobile emulation)**
  - **Area:** UI / Input · **Depends on:** `VS-06`
  - **Work:** Test `CombatInput`, `CombatHud`, and `ClassSelect` in Studio across: (1) Keyboard +
    Mouse, (2) Gamepad (D-pad ability switching, Y/R1 cast, L1 block, X/R2 attack, B/L2 dash,
    selecting cards on `ClassSelect`), and (3) Mobile device emulation (small phone ~667×375 and
    tablet). Fix any overlapping touch buttons around Roblox's jump button, `Layout.inset()` top-bar
    collisions, or cramped `ClassSelect` cards on phone.
  - **Verify:** Full fight + Boss Oh playable end-to-end on all three input methods; zero clipped or
    unclickable buttons on phone emulation; `make test ONLY=layout` and `make test ONLY=ui` pass.

### 1C. Single-Floor Run Loop (5 Fixed Rooms + Boss Oh + RunResult)

- [ ] **VS-10 · Design & test pure Run/Floor state machine (`shared/features/run/RunFlow.luau`)**
  - **Area:** Run / Shared · **Depends on:** `VS-01`
  - **Work:** Create `Config/Run.luau` (`ROOMS_PER_FLOOR = 5`, `FLOORS_PER_RUN = 1` for VS / `5` for
    HS, room transition delay, fixed 5-room wave definitions for the Vertical Slice floor ending
    with Boss Oh in Room 5) and register it in `Config/init.luau`. Create pure `RunFlow.luau` with
    `selfTest` handling room progression (`1 -> 2 -> 3 -> 4 -> 5 -> victory`), wipe detection, and
    run summary stats (rooms cleared, elapsed time, kills).
  - **Verify:** `make test` automatically discovers and passes `RunFlow.selfTest` (including victory,
    defeat on any room, and retry reset cases).

- [ ] **VS-11 · Build `server/features/run/RunService.luau` & integrate `WaveDirector`**
  - **Area:** Run / Server · **Depends on:** `VS-10`
  - **Work:** Create `RunService.luau` injected into `Bootstrap.server.luau` (wiring only). Refactor
    `WaveDirector` so it executes waves for the *current room* provided by `RunService` instead of
    endlessly looping one room. Publish replicated attributes on `workspace.World`: `Floor`, `Room`,
    `RoomCount`, `RunState` (`preparing` | `fighting` | `transition` | `victory` | `defeat`),
    `RunStartedAt`, `RunKills`. Add contracted `RetryRun` remote in `Remotes.luau` and `Contract.luau`.
  - **Verify:** Clearing Room 1 advances cleanly to Room 2…5; defeating Boss Oh in Room 5 sets
    `RunState = "victory"`; dying sets `RunState = "defeat"`; `RetryRun` resets all services cleanly
    (using generation tokens so stale loops cannot spawn); `make check` passes.

- [ ] **VS-12 · Room transition choreography (Blast Door, arena reset, pacing)**
  - **Area:** World / Run · **Depends on:** `VS-11`
  - **Work:** When a room is cleared, unlock/animate the North Blast Door (or central elevator pad)
    in `ComplexArena.rbxmx` with clear visual/audio signposting so the player steps through (or
    auto-advances after a short countdown) into the next room. On transition: clear leftover
    projectiles/drops/corpses, reposition player to `pivot * Config.SPAWN_OFFSET`, transition
    `ArenaTheme` cleanly per room, and open the next room's waves without jarring freezes.
  - **Verify:** Studio test through Rooms 1→5 confirms zero stuck enemies/drops/projectiles between
    rooms, smooth theme transitions, and player never falls out of bounds.

- [ ] **VS-13 · Update `CombatHud` SectorBar for Floor & Room telemetry**
  - **Area:** UI · **Depends on:** `VS-11`
  - **Work:** Update `CombatHud` top-center `SectorBar` to read `Floor`, `Room`, `RoomCount`,
    `Wave`, `EnemiesLeft`, and `Difficulty` attributes from `workspace.World` (compact format on
    mobile respecting `Layout.inset()`).
  - **Verify:** `make check` passes; Studio desktop and phone emulation show legible Floor/Room/Wave
    readout with zero collision against `BossBar` or top inset.

- [ ] **VS-14 · Build `RunResult` screen (`client/features/run/ui/RunResult.luau`)**
  - **Area:** UI · **Depends on:** `VS-11`
  - **Work:** Implement `RunResult` per `plans/gdd/ui.md` and `docs/ui-design-system.md` (Hazard Arc
    centered architectural plate): clear **Planta completada** (Victory) or **Derrota** (Defeat)
    header, 3 key summary metrics (rooms cleared, run time, enemies defeated), and large primary
    **Reintentar** button firing `RetryRun` (accessible by click, touch, and gamepad A/Cross).
    Mount via `UI.mount` (`ResetOnSpawn = false`).
  - **Verify:** Victory and Defeat states both display accurate stats and restart cleanly on click,
    touch, and gamepad; survives respawn without losing UI; `make check` passes.

### 1D. Zero-Pause 1-of-3 Run Upgrades

- [ ] **VS-15 · Define Vertical Slice upgrade catalog (`Config/Upgrades.luau`)**
  - **Area:** Upgrades / Config · **Depends on:** `VS-01`
  - **Work:** Create `Config/Upgrades.luau` (registered in `Config/init.luau`) with `UPGRADE_CHOICES
    = 3`, `START_ABILITY_CHOICES = 3`, and the initial upgrade pool: (1) active abilities & level-up
    tiers (+damage / -cooldown / +area), (2) stat upgrades (+max HP + heal, +damage %, +move speed %,
    +cooldown haste), and (3) movement passives (**Doble Salto** and **Doble Dash**). Keep card copy
    short for mobile readability (`plans/gdd/ui.md`).
  - **Verify:** Every number referenced in `plans/gdd/systems.md` has a matching `Config` key;
    `make check` passes.

- [ ] **VS-16 · Build pure upgrade roll, slot-full conversion & queue logic (`shared/features/upgrades/UpgradePool.luau`)**
  - **Area:** Upgrades / Shared · **Depends on:** `VS-15`
  - **Work:** Implement pure rules with `selfTest`: rolling 3 distinct choices from the player's
    eligible pool; when all `Config.ABILITY_SLOTS` (3) active slots are filled, converting a rolled
    new active ability randomly into (a) an upgrade to an owned active, (b) a replacement offer, or
    (c) a stat upgrade; unbounded per-player pending choice queue within a floor; and random
    auto-resolution of all queued choices on floor exit.
  - **Verify:** `UpgradePool.selfTest` covers empty slots, full slots, duplicate prevention,
    multi-room queue ordering, replacement validation, and floor-exit auto-resolve; `make test` green.

- [ ] **VS-17 · Build `server/features/upgrades/UpgradeService.luau` & contracted remotes**
  - **Area:** Upgrades / Server · **Depends on:** `VS-11`, `VS-16`
  - **Work:** Manage per-player run upgrades, pending queues, starter 1-of-3 offer on run start, and
    1-of-3 offer on every room clear (without pausing enemies). Add `PickUpgrade` and
    `ReplaceAbility` to `Remotes.luau` and `Contract.luau` (validating offer ID, card index `1..3`,
    and slot index `1..3`). Broadcast current offer + queue depth (`+N`) to the owning player via
    replicated state/event; clear all run upgrades on run reset and `onPlayerRemoving`.
  - **Verify:** Server rejects out-of-range, stale, or forged upgrade picks (logged by Telemetry);
    clearing 2 rooms without picking stacks queue to `+1` behind active offer; `make check` passes.

- [ ] **VS-18 · Wire stat upgrades & active ability level-ups into `CombatService`**
  - **Area:** Combat / Upgrades · **Depends on:** `VS-17`
  - **Work:** Feed run upgrade modifiers (damage %, max HP, move speed %, cooldown reduction, active
    ability levels, and swapped active slots) into `CombatService`, `Defense.walkSpeed`, and
    `CombatHud` ability slots so picking an upgrade immediately changes combat output and cooldowns
    with zero lag or respawn loss.
  - **Verify:** Pure modifier math asserted in `selfTest`; Studio verification confirms picking a
    damage/HP/cooldown/ability-level card measurably changes damage, max HP, and cooldown timer.

- [ ] **VS-19 · Wire permanent-for-run Movement Passives (Double Jump & Double Dash)**
  - **Area:** Combat / Movement · **Depends on:** `VS-17`
  - **Work:** Replicate active movement passives (`HasDoubleJump`, `HasDoubleDash`) as player
    attributes. Implement client Double Jump (mid-air jump impulse + air-ring VFX/SFX, 1 extra jump
    per ground touch, compatible with keyboard, gamepad, and mobile jump button) and Double Dash (2
    dash charges independent of speed drop buff, stacking cleanly with existing dash logic). Display
    discreet passive badges on `CombatHud` (`plans/gdd/ui.md`).
  - **Verify:** Both passives work independently AND combined together on PC, mobile, and gamepad in
    Studio; `Defense.selfTest` / `Melee.selfTest` pass; `make check` passes.

- [ ] **VS-20 · Build `UpgradeChoice` zero-pause top banner (`client/features/upgrades/ui/UpgradeChoice.luau`)**
  - **Area:** UI / Upgrades · **Depends on:** `VS-17`
  - **Work:** Build Charm store (`client/features/upgrades/stores/UpgradeStore.luau` with offline
    `ui` test) and React screen `UpgradeChoice.luau` per `plans/gdd/ui.md` and
    `docs/ui-design-system.md`: compact top-center horizontal strip of 3 Hazard Arc tickets (category
    top accent bar, icon, short title, compact numeric effect, keycap badge), `+N` queue badge, and
    seamless 3-slot replacement view when replacing an active ability. Never blocks camera, movement,
    or attack input; stays in upper ~20% on mobile under `Layout.inset()`.
  - **Verify:** `make test ONLY=ui` tests `UpgradeStore` state transitions (offer, queue, replace
    mode, clear); Studio desktop & mobile emulation confirm zero overlap with `SectorBar`, `BossBar`,
    joystick, or touch arc.

- [ ] **VS-21 · Resolve input ergonomics between `UpgradeChoice` and active ability keys**
  - **Area:** Input / UI · **Depends on:** `VS-20`
  - **Work:** Note that `CombatInput` currently uses `1`/`2`/`3` (and D-pad) to switch active ability
    slots, while `plans/gdd/ui.md` also maps `1`/`2`/`3` (and D-pad) to pick upgrade cards. Resolve
    this cleanly (e.g., while an upgrade banner is open, bind dedicated non-conflicting shortcuts
    like `Z`/`X`/`C` or `F1`/`F2`/`F3` OR contextual `1`/`2`/`3` with clear HUD keycap swap and
    click/tap support — document the exact choice in `plans/gdd/ui.md` and `docs/combat.md`).
  - **Verify:** Player can select upgrades mid-combat on PC, gamepad, and touch without accidentally
    triggering wrong ability switches or losing movement control.

### 1E. Vertical Slice Polish & Sign-Off Gate

- [ ] **VS-22 · Boss Oh Room 5 presentation & pacing polish**
  - **Area:** Boss / Polish · **Depends on:** `VS-12`, `VS-18`
  - **Work:** Add brief non-blocking Room 5 Boss entry beat (lighting shift to reactor crimson, boss
    spawn VFX/SFX, `BossBar` entrance) and satisfying defeat explosion/slow-dissolve + victory chime
    leading smoothly into `RunResult`. Ensure Boss Oh HP/damage feel balanced after 4 rooms of
    1-of-3 upgrades.
  - **Verify:** Studio playthrough from Room 1→5 confirms Boss Oh feels tense, fair, and readable on
    `Normal` and `Hard`.

- [ ] **VS-23 · Performance & stability measurement pass (Vertical Slice)**
  - **Area:** Performance / QA · **Depends on:** `VS-22`
  - **Work:** Measure FPS, frame times, and script activity in Studio (desktop + phone emulation)
    during peak Room 4/5 combat (up to 25 enemies + VFX + drops + active `UpgradeChoice` banner).
    Verify no `PlayerGui` wipe on respawn (`ResetOnSpawn = false`), no stacked `AncestryChanged`
    listeners across 3 consecutive retries, and zero `Diagnostics.fault` warnings.
  - **Verify:** Recorded metrics meet `plans/gdd/technical.md` budget (≥60 FPS PC, ≥30 FPS mobile
    profile) with zero memory/listener growth across 3 back-to-back runs.

- [ ] **VS-24 · End-to-end Vertical Slice playtest checklist (PC, Mobile, Gamepad)**
  - **Area:** QA · **Depends on:** `VS-21`, `VS-23`
  - **Work:** Run full end-to-end playtests on all 3 input schemes: start → difficulty/kit choice →
    starter 1-of-3 → Rooms 1–4 with queued and immediate upgrades → Room 5 Boss Oh victory →
    `RunResult` → Retry → intentional defeat → `RunResult` → Retry. Fix all P0/P1 defects found.
  - **Verify:** Every path passes cleanly on PC, mobile emulation, and gamepad with zero script
    errors in Output.

- [ ] **VS-25 · Vertical Slice documentation & GDD status update**
  - **Area:** Docs · **Depends on:** `VS-24`
  - **Work:** Add `docs/run.md` and `docs/upgrades.md`, register them in `docs/README.md`, and update
    `plans/gdd/overview.md` and `plans/gdd/scope.md` marking Hito 2 (*Una planta*) complete.
  - **Verify:** `make check` passes; docs accurately describe every new module, remote, and `Config`
    key.

---

## Phase 2 — Polished Horizontal Slice

**Goal:** Deliver the complete breadth of gameplay in the GDD: **all 6 enemy types**, **5 floors ×
5 randomized rooms** (~15–20 min run), **all 4 boss encounters** (**Oh**, **My**, **Gon**, and
2-phase **OhMyGon**), and full **1–4 player Cooperative Multiplayer** (isolated Hub, Open/Private
Parties, private reserved Run servers, Downed state & 5 s Ally Revive — without Robux purchase yet).

### 2A. Breadth Design Lock (Unblocking Phase 2)

- [ ] **HS-01 · Design the 2 missing enemy archetypes (`En área` & `Por contacto`)**
  - **Area:** Design / GDD · **Depends on:** `VS-25`
  - **Work:** Specify player-facing Spanish names, roles, silhouettes, attacks, counterplay, HP
    ladder entries, and `Config.ENEMY_KINDS` keys for the 2 remaining enemy types in
    `plans/gdd/content.md`: **En área** (e.g., mortar/hazard-zone unit that denies ground space with
    telegraphed zones) and **Por contacto** (e.g., electrified/sawblade charger or orbiter that
    punishes body contact and rewards ranged/spacing/parry).
  - **Verify:** `plans/gdd/content.md` has complete rules and starting HP/damage numbers for all 6
    enemy archetypes.

- [ ] **HS-02 · Design Bosses `My`, `Gon`, and 2-phase `OhMyGon`**
  - **Area:** Design / GDD · **Depends on:** `VS-25`
  - **Work:** Define concrete, telegraphed attacks and counterplay in `plans/gdd/content.md` for:
    - **My** (Floor 3 Room 5) — distinct identity complementing Oh's heavy melee (e.g., high-speed
      mobility / laser sweeps / dashes).
    - **Gon** (Floor 4 Room 5) — distinct identity (e.g., area-denial hazards / shockwaves /
      summons or gravity wells).
    - **OhMyGon** (Floor 5 Room 5) — **Phase 1** recombining attacks players learned from Oh, My,
      and Gon (Pillar 3: *Aprender peleando*), and **Phase 2** (e.g., at 50% HP) escalating combo
      patterns without introducing untaught mechanics.
  - **Verify:** Open boss questions removed from `plans/gdd/overview.md` and `content.md`.

- [ ] **HS-03 · Lock Hub, Party & Co-op Disconnect rules**
  - **Area:** Design / GDD · **Depends on:** `VS-25`
  - **Work:** Close the open Hub/Party questions in `plans/gdd/systems.md`, `loop.md`, and
    `technical.md`: `Config.HUB_MAX_PLAYERS` (e.g., 20–30 for readable mobile list),
    `Config.PARTY_INVITE_SECONDS` (e.g., 20 s), whether private parties allow join requests or
    invite-only, leader kick & leader transfer on disconnect (longest-standing member), mid-run
    reconnect policy, and whether enemy scaling adjusts on player abandonment.
  - **Verify:** All Hub/Party `Open:` markers resolved in `plans/gdd/`.

- [ ] **HS-04 · Lock Downed & Ally Revive rules (non-Robux)**
  - **Area:** Design / GDD · **Depends on:** `VS-25`
  - **Work:** Close the open Revive questions in `plans/gdd/systems.md`: `Config.ALLY_REVIVE_RADIUS`
    (e.g., 8 studs), whether taking damage interrupts/resets the 5 s revive channel, HP percentage
    restored on ally revive (e.g., 50%), and non-monetized wipe flow (short surrender/defeat beat
    straight to `RunResult` with a documented hook for Phase 4's 10-Robux wipe revive).
  - **Verify:** Revive rules documented cleanly in `plans/gdd/systems.md`.

### 2B. Completing the 6-Enemy Roster

- [ ] **HS-05 · Author `.rbxmx` rigged model & animations for `En área` enemy**
  - **Area:** 3D / Assets · **Depends on:** `HS-01`
  - **Work:** Generate `assets/models/EnemyArea.rbxmx` via `scripts/generate-models.luau` (`@lune/roblox`)
    with anchored invisible `Body`, explicit `PrimaryPart`/pivot, and `Group`-tagged `Motor6D` rig.
    Mount in `default.project.json`. Add procedural walk/cast/hitstun/death poses in `EnemyAnim.luau`
    + `EnemyAnimator.luau`.
  - **Verify:** `EnemyAnim.selfTest` and `make check` pass; Studio visual check confirms distinct
    silhouette readable from isometric camera.

- [ ] **HS-06 · Implement `En área` pure AI, hitboxes & server/client ground-zone behavior**
  - **Area:** Enemies / Combat · **Depends on:** `HS-05`
  - **Work:** Add `En área` config in `Config/Enemies.luau`, state transitions in `Brain.luau` +
    `Tactics.luau` + `Hitbox.luau` (with `selfTest`), server hazard-zone lifecycle in `EnemyService`
    (telegraphed ground warning → active damage/DoT zone → cleanup on room clear), and client VFX +
    SFX cues. Ensure jumping / dashing out of the zone behaves fairly.
  - **Verify:** `make check` passes; Studio test confirms telegraph timing, clean zone damage,
    pillar avoidance, and zero lingering zones after kill or room transition.

- [ ] **HS-07 · Author `.rbxmx` rigged model & animations for `Por contacto` enemy**
  - **Area:** 3D / Assets · **Depends on:** `HS-01`
  - **Work:** Generate `assets/models/EnemyContact.rbxmx` via Lune with anchored `Body`, explicit
    `PrimaryPart`/pivot, and `Group`-tagged `Motor6D` rig. Mount in `default.project.json`. Add
    procedural locomotion/active-aura/hitstun/death poses in `EnemyAnim.luau` + `EnemyAnimator.luau`.
  - **Verify:** `EnemyAnim.selfTest` and `make check` pass; distinct silhouette verified in Studio.

- [ ] **HS-08 · Implement `Por contacto` pure AI, contact hitbox & server/client behavior**
  - **Area:** Enemies / Combat · **Depends on:** `HS-07`
  - **Work:** Add `Por contacto` config in `Config/Enemies.luau`, state/movement rules in `Brain.luau`
    + `Tactics.luau` + `Hitbox.luau` (`selfTest`), contact-damage tick with brief invulnerability
    debounce in `EnemyService` (routed through `CombatService.hurt` so Dash i-frames and Block
    work), and unmistakable active-hazard VFX/SFX around its body.
  - **Verify:** `make check` passes; Studio test confirms players take damage on contact, can dash
    through with i-frames, and kill it cleanly at melee sweet-spot or range.

- [ ] **HS-09 · Integrate all 6 enemy types into wave compositions & squad AI balance**
  - **Area:** Enemies / Balance · **Depends on:** `HS-06`, `HS-08`
  - **Work:** Update `Tactics.luau` and `SpatialGrid` interactions so all 6 archetypes combine
    cleanly without clumping or unfair unavoidable overlaps (e.g., Grabber holding while `En área`
    drops a zone on the trapped player — apply the same grab-exclusion safety rule).
  - **Verify:** `Tactics.selfTest` and `Brain.selfTest` pass; Studio mixed-wave test with all 6
    types active simultaneously stays legible and fair.

### 2C. 5-Floor World, Randomized Room Pools & Content Breadth

- [ ] **HS-10 · Author 3–4 additional combat arena layout `.rbxmx` models**
  - **Area:** 3D / Level Design · **Depends on:** `VS-25`
  - **Work:** Generate 3–4 distinct `140×140` arena `.rbxmx` variants under `assets/models/` (e.g.,
    `ComplexArenaCross`, `ComplexArenaReactor`, `ComplexArenaCorridor`, `ComplexArenaVault`) with
    different cover/pillar configurations, explicit `PrimaryPart` + `WorldPivot`, full-height
    anti-climb hulls on tall props, cutaway South/East walls for `IsoCamera`, and matching obstacle
    tables in `Config/World.luau`. Keep `StreamingEnabled = false` memory footprint lean.
  - **Verify:** Every arena mounts cleanly via `default.project.json`; `Waves.selfTest` verifies
    spawns/drops stay clear of obstacles on every layout; Studio check verifies zero camera
    obstruction and zero climb exploits.

- [ ] **HS-11 · Per-floor visual & lighting themes (Floors 1–5)**
  - **Area:** World / Art · **Depends on:** `HS-10`
  - **Work:** Define distinct color/lighting palettes per floor in `Config/World.luau` (e.g., Floor 1
    Intake Cyan, Floor 2 Foundry Amber for Oh, Floor 3 Cryo/Volt Violet for My, Floor 4 Bio-Hazard
    Emerald for Gon, Floor 5 Core Crimson for OhMyGon) and update `ArenaTheme.luau` to shift smoothly
    by `(Floor, Room, Boss)`.
  - **Verify:** Studio check across Floors 1–5 confirms clear visual progression and high enemy
    telegraph contrast against every floor palette.

- [ ] **HS-12 · Build pure 5-Floor randomized room generator (`shared/features/run/FloorGenerator.luau`)**
  - **Area:** Run / Shared · **Depends on:** `HS-09`, `HS-10`
  - **Work:** Implement `FloorGenerator.luau` (`selfTest`) and `Config/Floors.luau` defining a pool
    of authored room encounters + arena layouts per floor: **Floor 1** has 5 normal rooms (no boss,
    warm-up), **Floors 2–5** draw Rooms 1–4 randomly from each floor's pool (no back-to-back repeats)
    and lock Room 5 to the floor's boss (**Oh**, **My**, **Gon**, **OhMyGon**). Enforce
    `Config.MAX_ACTIVE_ENEMIES = 25` cap across all waves and difficulties.
  - **Verify:** `FloorGenerator.selfTest` proves 5×5 structure, boss placement, zero back-to-back
    duplicate rooms, and active enemy cap compliance; `make check` passes.

- [ ] **HS-13 · Upgrade `RunService` & `WorldBuilder` for 5-floor swaps & floor-exit auto-resolve**
  - **Area:** Run / Server · **Depends on:** `HS-11`, `HS-12`
  - **Work:** Support swapping between `.rbxmx` arena models cleanly on room/floor transitions
    without leaking instances or falling through floors. On Floor `N -> N+1`, invoke
    `UpgradeService.autoResolvePending()` so queued unpicked choices resolve randomly per
    `plans/gdd/systems.md`.
  - **Verify:** Stepping through Floors 1→5 in Studio swaps arenas smoothly, auto-resolves pending
    upgrade queues at floor boundaries, and ends in Victory only after Floor 5 Room 5.

- [ ] **HS-14 · Expand the Run Upgrade catalog for 5-floor build variety**
  - **Area:** Upgrades / Combat · **Depends on:** `VS-18`, `VS-19`
  - **Work:** Expand `Config/Upgrades.luau` and `CombatService` so a 5-floor run (~20–25 upgrade
    picks) produces genuinely distinct builds: expand active abilities pool, add ability evolution
    ranks (Lv. 1–4), add movement passives (Double Jump, Double Dash, Dash Speed/Distance, Air
    Control / Swift Recovery), and add build-defining stat/synergy cards (Parry Bonus, Heavy Charge
    Haste, Crit/Backstab, Life-on-Kill).
  - **Verify:** Every new upgrade has pure math covered by `selfTest`; Studio test verifies 3
    different builds feel meaningfully distinct by Floor 3.

### 2D. Boss Roster: My, Gon & OhMyGon (2 Phases)

- [ ] **HS-15 · Author `.rbxmx` model & procedural animations for Boss `My` (Floor 3)**
  - **Area:** 3D / Boss · **Depends on:** `HS-02`
  - **Work:** Generate `assets/models/BossMy.rbxmx` via Lune (`@lune/roblox`) with explicit pivot,
    `PrimaryPart`, and `Motor6D` rig matching its agile/distinct silhouette. Add all attack windup,
    strike, transition, and death poses in `EnemyAnim.luau` + `EnemyAnimator.luau`.
  - **Verify:** `EnemyAnim.selfTest` and `make check` pass; Studio visual check confirms clear
    readability and zero part detachment.

- [ ] **HS-16 · Implement Boss `My` pure AI, attacks, VFX & SFX**
  - **Area:** Boss / Combat · **Depends on:** `HS-15`
  - **Work:** Add `bossMy` in `Config/Enemies.luau`, pure state machine + `selfTest` in `Brain.luau`,
    server execution & `BossBar` attributes in `EnemyService.luau`, and telegraphed VFX/SFX on the
    client. Verify difficulty scaling (`isBoss = true` always spawns 1 boss) and pillar collision.
  - **Verify:** `Brain.selfTest` passes; Studio fight verifies all telegraphs, dodge/parry windows,
    and defeat flow on Floor 3 Room 5.

- [ ] **HS-17 · Author `.rbxmx` model & procedural animations for Boss `Gon` (Floor 4)**
  - **Area:** 3D / Boss · **Depends on:** `HS-02`
  - **Work:** Generate `assets/models/BossGon.rbxmx` via Lune with explicit pivot, `PrimaryPart`,
    and `Motor6D` rig. Add procedural poses in `EnemyAnim.luau` + `EnemyAnimator.luau`.
  - **Verify:** `EnemyAnim.selfTest` and `make check` pass; Studio silhouette check passes.

- [ ] **HS-18 · Implement Boss `Gon` pure AI, attacks, VFX & SFX**
  - **Area:** Boss / Combat · **Depends on:** `HS-17`
  - **Work:** Add `bossGon` in `Config/Enemies.luau`, pure state machine + `selfTest` in
    `Brain.luau`, server execution in `EnemyService.luau`, and client VFX/SFX. Ensure any ground
    hazards or spawned objects clean up immediately on Gon's death or room reset.
  - **Verify:** `Brain.selfTest` passes; Studio fight confirms readable telegraphs and clean reset.

- [ ] **HS-19 · Author `.rbxmx` model & procedural animations for fused Boss `OhMyGon` (Floor 5)**
  - **Area:** 3D / Boss · **Depends on:** `HS-15`, `HS-17`
  - **Work:** Generate `assets/models/BossOhMyGon.rbxmx` via Lune visibly fusing motifs of Oh, My,
    and Gon with explicit pivot, `PrimaryPart`, and `Motor6D` rig. Add Phase 1, Phase-Transition
    transformation, Phase 2, and defeat poses in `EnemyAnim.luau` + `EnemyAnimator.luau`.
  - **Verify:** `EnemyAnim.selfTest` and `make check` pass; Studio visual check confirms boss fits
    arena scale and camera framing cleanly.

- [ ] **HS-20 · Implement Boss `OhMyGon` Phase 1 & Phase 2 AI, VFX & `BossBar` phase indicator**
  - **Area:** Boss / Combat · **Depends on:** `HS-16`, `HS-18`, `HS-19`
  - **Work:** Add `bossOhMyGon` in `Config/Enemies.luau` and pure 2-phase state machine + `selfTest`
    in `Brain.luau`: Phase 1 chains learned Oh/My/Gon attacks; crossing the Phase 2 HP threshold
    triggers a brief telegraphed phase-shift (invulnerability beat + arena lighting intensification +
    phase indicator on `BossBar`) into escalated combined attacks. Clean up all hazards on victory.
  - **Verify:** `Brain.selfTest` asserts Phase 1→Phase 2 threshold trigger and single-fire
    transition; Studio test plays through both phases to Victory `RunResult`.

- [ ] **HS-21 · Solo 5-Floor full run pacing & balance pass (15–20 min target)**
  - **Area:** Balance / QA · **Depends on:** `HS-13`, `HS-14`, `HS-20`
  - **Work:** Playtest complete 5-floor solo runs on `Normal` and measure time per floor (target:
    **3–4 min/floor**, **15–20 min total** per `plans/gdd/loop.md`). Tune wave counts, enemy HP,
    boss HP, and upgrade power scaling in `Config/` so Floor 1 warms up smoothly and Floor 5 OhMyGon
    feels climactic.
  - **Verify:** Recorded run timestamps for Floors 1–5 fall within 15–20 min on `Normal`; `make check`
    passes.

### 2E. Hub, Parties & Private Run Servers

- [ ] **HS-22 · Author Hub `.rbxmx` map (`assets/models/ComplexHub.rbxmx`)**
  - **Area:** 3D / World · **Depends on:** `HS-03`
  - **Work:** Generate `assets/models/ComplexHub.rbxmx` via Lune (industrial staging bay / elevator
    console with explicit `PrimaryPart`, `WorldPivot`, `SPAWN_OFFSET`, and anti-climb boundaries)
    and mount via `default.project.json`.
  - **Verify:** Loads cleanly in Studio with `IsoCamera` framing and zero falling/clipping bugs.

- [ ] **HS-23 · Build isolated Hub service (`server/features/hub/HubService.luau` + client isolation)**
  - **Area:** Hub · **Depends on:** `HS-22`
  - **Work:** Implement `HubService.luau` (`Config/Hub.luau` with `HUB_MAX_PLAYERS`) and client-side
    character visibility isolation so every player in the Hub server sees **only their own avatar**
    in the space while still receiving replicated `Player` attributes for the server player list
    (`plans/gdd/systems.md`). Disable combat inputs/waves while in Hub mode.
  - **Verify:** Multi-client Studio test (2+ players in Hub) confirms Player A cannot see Player B's
    avatar in 3D space, yet both see each other live in the player list.

- [ ] **HS-24 · Build pure Party rules module (`shared/features/party/PartyRules.luau`)**
  - **Area:** Party / Shared · **Depends on:** `HS-03`
  - **Work:** Implement pure state machine with `selfTest`: create party (open/private), join open
    party (up to `PARTY_MAX_PLAYERS = 4`), invite to private party + expiration
    (`PARTY_INVITE_SECONDS`), accept/reject invite, leave party, kick member (leader only), automatic
    leader transfer when leader leaves, and locking party once run launches.
  - **Verify:** `PartyRules.selfTest` covers every transition, full-party rejection, expired invite,
    and leader disconnect edge case; `make test` green.

- [ ] **HS-25 · Build `server/features/party/PartyService.luau` & contracted remotes**
  - **Area:** Party / Server · **Depends on:** `HS-23`, `HS-24`
  - **Work:** Wire `PartyService.luau` using `PartyRules`, publishing each player's `PartyId`,
    `PartyRole` (`leader` | `member`), `PartyPrivacy` (`open` | `private`), `PartyDifficulty`, and
    `PartyLocked` as replicated `Player` attributes. Declare `CreateParty`, `SetPartyPrivacy`,
    `JoinParty`, `InvitePlayer`, `RespondInvite`, `LeaveParty`, `KickMember`, and `StartRun` in
    `Remotes.luau` and `Contract.luau`. Clean up party state in `onPlayerRemoving`.
  - **Verify:** Multi-client Studio test confirms open join, private invite/accept/reject, kick,
    leader transfer on disconnect, and non-leader refusal on `StartRun`; `make check` passes.

- [ ] **HS-26 · Build `HubPartyUi` React screen (`client/features/party/ui/HubPartyUi.luau`)**
  - **Area:** UI / Party · **Depends on:** `HS-25`
  - **Work:** Build Charm store (`PartyStore.luau` with offline `ui` test) + Hazard Arc React UI for
    the Hub: scrollable server player list (`Active = true` for input sinking), open/private toggle,
    invite toast with accept/decline countdown, 1–4 slot party roster, difficulty selector (and
    class selector if retained by `VS-01`), and solo/party **Iniciar Run** button. Ensure phone
    layout is crisp and uncluttered.
  - **Verify:** `make test ONLY=ui` passes; Studio multi-client desktop & phone emulation confirm
    forming a 2-player party and launching works smoothly on mouse, touch, and gamepad.

- [ ] **HS-27 · Multi-place / Private Run Server teleportation (`server/features/hub/RunTeleport.luau`)**
  - **Area:** Networking / Server · **Depends on:** `HS-13`, `HS-25`
  - **Work:** Set up the two-place architecture (Hub place + Run place in the same universe, or
    place-role detection via `Config/Environments.luau`) so `StartRun` locks the party, calls
    `TeleportService:ReserveServer(runPlaceId)`, and teleports the 1–4 player party together with
    party roster + difficulty metadata. Handle `TeleportInitFailed` cleanly (unlock party, notify
    leader, report to `LogSink`). Add **Volver al hub** on `RunResult` to teleport back to Hub.
    Include a Studio single-place fallback mode so developers can still test Hub→Run locally without
    live teleport failures.
  - **Verify:** Studio local fallback transitions Hub→Run→Hub cleanly; Staging published universe
    test confirms real `ReserveServer` teleport for 1 and 2+ players isolates each run to its own
    server.

### 2F. Co-op Combat, Downed & Ally Revive (No Robux)

- [ ] **HS-28 · Build pure Downed & Revive rules (`shared/features/revive/ReviveRules.luau`)**
  - **Area:** Revive / Shared · **Depends on:** `HS-04`
  - **Work:** Implement pure rules with `selfTest`: player drops to `downed` state instead of dead
    while ≥1 teammate stands; proximity channel progress (`ALLY_REVIVE_SECONDS = 5`,
    `ALLY_REVIVE_RADIUS`), damage interruption rule per `HS-04`, multiple allies assisting, full-party
    wipe detection (`allDowned`), and an explicit extension hook (`onWipeOffer`) that currently goes
    straight to defeat/surrender (ready for future 10-Robux revive without refactoring).
  - **Verify:** `ReviveRules.selfTest` asserts solo instant wipe, 2–4 player downed state, 5 s
    channel completion, interruption/reset, and simultaneous all-downed wipe; `make test` green.

- [ ] **HS-29 · Build `server/features/revive/ReviveService.luau` & integrate with Combat/Enemies**
  - **Area:** Revive / Server · **Depends on:** `HS-28`
  - **Work:** Intercept lethal player damage in `CombatService.hurt` to enter `Downed = true` when
    teammates remain standing (freezing combat actions, disabling movement or crawl, excluding
    downed players from `EnemyService` targeting and Grabber grabs). Run server proximity channel
    check, replicate `Downed` and `ReviveProgress` (`0..1`) attributes on the player, and trigger
    `RunService.onWipe()` only when all party members are down (or the last standing player leaves).
    Add clean `onPlayerRemoving` handling.
  - **Verify:** Multi-client Studio test (2 players): Player 1 goes down, enemies pivot to Player 2,
    Player 2 holds position for 5 s to revive Player 1, and wipe triggers only when both are down.

- [ ] **HS-30 · Downed world indicator, revive ring VFX & Co-op Squad Vitals HUD**
  - **Area:** UI / VFX · **Depends on:** `HS-29`
  - **Work:** Render a high-visibility diegetic ground revive ring + overhead downed beacon on
    downed teammates (filling cleanly from `ReviveProgress` over 5 s, plus SFX on down and revive).
    Add compact Co-op Squad Vitals strips under top-left `Vitals` in `CombatHud` showing teammates'
    names, HP bars, downed/grabbed alert badges, and off-screen edge arrows if a downed ally is out
    of view.
  - **Verify:** Multi-client Studio test confirms downed marker, 5 s progress fill, and squad strips
    stay clear of `UpgradeChoice` and mobile thumbstick.

- [ ] **HS-31 · Co-op enemy/boss scaling & mid-run abandonment handling**
  - **Area:** Balance / Co-op · **Depends on:** `HS-03`, `HS-29`
  - **Work:** Scale enemy wave counts (strictly capped at `Config.MAX_ACTIVE_ENEMIES = 25`) and boss
    HP by active party size (1–4 players) in `Difficulty.luau` / `FloorGenerator.luau`, plus apply
    the abandonment scaling rule decided in `HS-03` if a teammate disconnects mid-run. Verify
    `Tactics.chooseTarget` (`AI_COOP_CROWD_PENALTY`) distributes pressure across all 4 players.
  - **Verify:** `Difficulty.selfTest` and `Tactics.selfTest` assert 1–4 player scaling; 2–4 player
    Studio test confirms enemies split across teammates and boss HP feels tuned for groups.

- [ ] **HS-32 · Horizontal Slice multi-client QA & doc sync gate**
  - **Area:** QA / Docs · **Depends on:** `HS-21`, `HS-27`, `HS-30`, `HS-31`
  - **Work:** Execute a full 2-player (and ideally 4-player) co-op playthrough from Hub → Party →
    5 Floors (all 6 enemies + Oh, My, Gon, OhMyGon) → ally revive test → Victory/Defeat → Return to
    Hub. Write `docs/hub-and-party.md`, `docs/revive.md`, and update `docs/combat.md`,
    `plans/gdd/overview.md`, and `plans/gdd/scope.md` (marking *Run en solitario* and *Grupos* done).
  - **Verify:** `make check` passes; full co-op run completes with zero soft-locks, zero orphaned
    instances, and docs matching code.

---

## Phase 3 — Almost Ready-to-Publish (No Monetization / No Dev Items)

**Goal:** Bring *The Complex* to a true release-candidate standard ready for public playtesting and
launch — adding **permanent meta-progression & DataStore persistence**, full audio/UI/onboarding
polish, settings, security/stability/FPS hardening, and staging ops — while **deliberately leaving
out Robux dev products, GamePasses, currency packs, Robux wipe-revive, and cosmetics** until a final
monetization pass.

### 3A. Permanent Progression Design Lock (Non-Monetized)

- [ ] **RP-01 · Lock Permanent Currency name, reward table & co-op payout rule**
  - **Area:** Design / GDD · **Depends on:** `HS-32`
  - **Work:** Finalize in `plans/gdd/progression.md`: player-facing currency name, exact reward
    values (`CURRENCY_PER_ENEMY < CURRENCY_PER_ROOM < CURRENCY_PER_FLOOR < CURRENCY_PER_BOSS`),
    difficulty reward multipliers (optional), and confirm full payout per player in co-op so playing
    with friends is never worse than solo.
  - **Verify:** Currency table in `plans/gdd/progression.md` has concrete numbers and zero `Open:`
    placeholders for non-Robux progression.

- [ ] **RP-02 · Lock Skill Tree branches, Unlockable Abilities & Run Perks**
  - **Area:** Design / GDD · **Depends on:** `RP-01`
  - **Work:** Define in `plans/gdd/progression.md` the exact v1 meta-progression catalog:
    - **Skill Tree branches & nodes:** e.g., Vitality (+HP), Offense (+Damage), Mobility (+Speed /
      Dash CD), Mastery (+Ability Haste) with costs & prerequisites.
    - **Unlockable Abilities:** abilities unlocked via permanent currency that enter the player's
      1-of-3 run offer pool.
    - **Run Perks:** e.g., Extra Upgrade Choice (1-of-4), Run Reroll Charges (reroll a 1-of-3
      offer), Faster Ally Revive (5 s → 3.5 s).
    - Verify **100% of functional nodes/abilities/perks are earnable with permanent currency alone**
      (GDD rule: nothing functional is paywalled).
  - **Verify:** Complete node graph, costs, and perk rules agreed in `plans/gdd/progression.md`.

### 3B. DataStore Persistence & Permanent Meta-Progression

- [ ] **RP-03 · Define `Config/Progression.luau` & pure `Progression.luau` rules**
  - **Area:** Progression / Shared · **Depends on:** `RP-02`
  - **Work:** Create `Config/Progression.luau` (registered in `Config/init.luau`) containing currency
    rates, the Skill Tree node DAG (id, branch, cost, prerequisite ids, bonus), unlockable ability
    ids, and run perks. Create pure `shared/features/progression/Progression.luau` with `selfTest`:
    run payout calculation, cycle-free DAG check, prerequisite/affordability validation, and
    computing aggregate player meta-bonuses from a saved profile.
  - **Verify:** `Progression.selfTest` asserts DAG integrity, cost math, prerequisite gating, and
    payout monotonicity (`enemy < room < floor < boss`); `make test` green.

- [ ] **RP-04 · Build resilient DataStore profile service (`server/features/persistence/ProfileStore.luau`)**
  - **Area:** Persistence / Server · **Depends on:** `RP-03`
  - **Work:** Implement server-only DataStore persistence (scoped cleanly by universe via
    `Environment`, schema version field, session lock / `UpdateAsync`, exponential retry with jitter,
    auto-save interval, and `game:BindToClose` flush). Only persist permanent state (currency,
    purchased nodes, unlocked abilities, purchased perks, settings) — **never** mid-run upgrades. If
    DataStore is unavailable on load, enter safe read-only degraded mode (notify player, log via
    `LogSink`, never overwrite real data on leave).
  - **Verify:** Pure migration/schema logic verified in `selfTest`; Studio API-services-enabled test
    confirms save/rejoin persistence, `BindToClose` flush, and degraded-mode protection when
    simulated DataStore fails.

- [ ] **RP-05 · Build `server/features/progression/ProgressionService.luau` & contracted remotes**
  - **Area:** Progression / Server · **Depends on:** `RP-04`
  - **Work:** Wire `ProgressionService.luau` on top of `ProfileStore`: expose server-authoritative
    `grantRunReward(player, summary)` on run end (Victory or Defeat), replicate currency balance and
    unlock summary to the client, and connect contracted Hub-only remotes `BuyTreeNode`,
    `BuyUnlockable`, and `BuyPerk` in `Remotes.luau` + `Contract.luau` (refusing purchases during an
    active run or without prerequisites/funds). Clean up in `onPlayerRemoving`.
  - **Verify:** Invalid node IDs, missing prerequisites, insufficient currency, and mid-run purchase
    attempts are all silently refused and counted by `Net/Telemetry`; `make check` passes.

- [ ] **RP-06 · Wire permanent meta-bonuses & Run Perks into Run Start, Upgrades & Revive**
  - **Area:** Progression / Combat · **Depends on:** `RP-05`
  - **Work:** On Run server join, load the player's profile directly from `ProfileStore` (never trust
    `TeleportData` for currency/stats!) and apply: (1) Skill Tree stat bonuses into `CombatService`
    / `Defense`, (2) unlocked abilities into `UpgradeService`'s eligible 1-of-3 pool, and (3) Run
    Perks into `UpgradeService` (e.g., extra card option, contracted `RerollUpgrade` remote) and
    `ReviveService` (faster ally revive timer).
  - **Verify:** Studio test confirms buying a +HP node, an unlockable ability, and a Reroll perk in
    Hub visibly and measurably takes effect in the next run, while mid-run upgrades still reset on
    run end.

- [ ] **RP-07 · Update `RunResult` with permanent currency breakdown**
  - **Area:** UI / Progression · **Depends on:** `RP-05`
  - **Work:** Add a clean Hazard Arc currency breakdown section to `RunResult` (Enemies + Rooms +
    Floors + Bosses = Total Earned, plus updated permanent wallet balance) for both Victory and
    Defeat runs so players always feel progress (`plans/gdd/loop.md`).
  - **Verify:** Victory and Defeat screens display exact server-granted totals matching the saved
    profile balance in Hub.

- [ ] **RP-08 · Build Hub `SkillTree` & Unlocks screen (`client/features/progression/ui/SkillTree.luau`)**
  - **Area:** UI / Progression · **Depends on:** `RP-05`
  - **Work:** Build Charm store (`ProgressionStore.luau` + offline `ui` test) and React screen
    accessible from the Hub following `docs/ui-design-system.md`: orthogonal blueprint connector
    traces linking circular `ui.Actuator` nodes (`BORDER` locked → pulsing `HAZARD` affordable → lit
    `KINETIC` unlocked), clear node detail/buy drawer, tabs for **Árbol**, **Habilidades**, and
    **Ventajas**, and full desktop/mobile/gamepad navigation (`Active = true` on scroll panels).
  - **Verify:** `make test ONLY=ui` passes; Studio test on desktop, phone emulation, and gamepad
    buys nodes across branches, updates wallet live, and persists across rejoin.

### 3C. Audio, Visual Polish, Settings & Onboarding UX

- [ ] **RP-09 · Complete asset sync (`make sync-assets`) & music/audio polish**
  - **Area:** Audio / Assets · **Depends on:** `HS-32`, `RP-08`
  - **Work:** Author/gather and upload all remaining `.ogg` SFX via `make sync-assets`: new enemy
    archetypes (`En área`, `Por contacto`), Bosses (`Oh`, `My`, `Gon`, `OhMyGon` phase shift), UI
    interactions (upgrade pick, skill tree purchase, party invite, countdown tick), and revive
    channel/complete. Add smooth BGM intensity shift or boss track crossfade for Room 5 boss fights
    and Hub calm ambience.
  - **Verify:** Zero cues fall back to placeholder Studio IDs in `AssetIds.json`; audio mix tested
    across Hub, combat, boss fights, and menus.

- [ ] **RP-10 · Build Settings panel (`client/features/settings/ui/Settings.luau`)**
  - **Area:** UI / Settings · **Depends on:** `RP-04`
  - **Work:** Create a compact Hazard Arc Settings screen (accessible in Hub and via unobtrusive HUD
    button without pausing co-op runs): BGM volume slider, SFX volume slider (built with `GuiButton`
    tracks so drags sink input and never spin the camera per `CLAUDE.md`), screen shake intensity /
    toggle, and reduced VFX mode for low-end mobile. Persist settings via `ProfileStore` (contracted
    `UpdateSettings` remote).
  - **Verify:** Sliders sink input on mouse & touch, audio volumes update live, and preferences
    persist across sessions; `make check` passes.

- [ ] **RP-11 · Dynamic input glyph prompts (PC / Xbox / PlayStation / Touch)**
  - **Area:** UI / Input · **Depends on:** `RP-08`
  - **Work:** Add a small shared client helper listening to `UserInputService.LastInputTypeChanged`
    so every keycap badge in `CombatHud`, `UpgradeChoice`, `RunResult`, `HubPartyUi`, and
    `SkillTree` automatically displays the player's active device prompts (Keyboard keys, Gamepad
    buttons, or clean touch tap targets with no desktop keycaps cluttering phone screens).
  - **Verify:** Switching between keyboard, gamepad, and touch emulation in Studio updates all visible
    prompts cleanly with zero layout overflow.

- [ ] **RP-12 · Zero-text "Learn by Fighting" onboarding & combat feedback polish**
  - **Area:** UX / Polish · **Depends on:** `HS-32`
  - **Work:** Audit Pillar 3 (*Aprender peleando*) across Floor 1 and all bosses: ensure clear damage
    numbers / parry spark / stun icon / off-screen danger indicators, unmistakable room-clear
    doorway guidance, and Floor 1 Room 1 starting with manageable enemy pacing so a brand-new player
    grasps Attack, Dash, Block/Parry, and 1-of-3 upgrades within 30 seconds with zero tutorial walls.
  - **Verify:** Blind playtest with a teammate/tester who reads no instructions clears Floor 1 and
    uses dash, parry, and 1-of-3 upgrades naturally.

- [ ] **RP-13 · Full responsive Hazard Arc UI audit across all viewports**
  - **Area:** UI / QA · **Depends on:** `RP-08`, `RP-10`, `RP-11`
  - **Work:** Audit every ScreenGui (`CombatHud`, `UpgradeChoice`, `RunResult`, `ClassSelect`,
    `HubPartyUi`, `SkillTree`, `Settings`, `BuildStamp`) across: 1920×1080, 2560×1080 ultrawide,
    1024×768 tablet, and 667×375 small phone. Verify `IgnoreGuiInset = true` + `Layout.inset()`,
    `ResetOnSpawn = false`, no `UIScale` double-shrinking, and zero overlaps when multiple panels
    coexist (e.g., BossBar + UpgradeChoice + Squad Vitals + GrabEscape).
  - **Verify:** Every screen passes `make test ONLY=layout` and Studio multi-resolution verification
    checklist with zero clipping or off-screen buttons.

### 3D. Security, Stability & Performance Hardening

- [ ] **RP-14 · Security & Net Contract exploit audit**
  - **Area:** Security / Net · **Depends on:** `RP-06`, `RP-10`
  - **Work:** Audit every remote in `src/shared/core/Net/Contract.luau` and every server handler:
    confirm strict rate limits, NaN/Inf/magnitude checks on `Vector3`/numbers, server-side ownership
    & phase checks (`Hub` vs `Run`, `alive` vs `downed`, `paused`), zero trust of `TeleportData` for
    meta-progression, and `Net/Telemetry` logging of refusals. Test malformed remote invocations in
    Studio.
  - **Verify:** Fuzzing invalid arguments, rapid spam, and out-of-phase remote calls produces zero
    server errors and zero exploit gains; `make check` passes.

- [ ] **RP-15 · Engine gotchas, teardown & memory-leak soak test**
  - **Area:** Stability / QA · **Depends on:** `RP-13`
  - **Work:** Audit every new client and server feature against [`docs/roblox-gotchas.md`](../docs/roblox-gotchas.md):
    (1) client end-of-life uses `AncestryChanged` / `IsDescendantOf(workspace)`, never `Destroying`;
    (2) respawn teardown uses generation tokens; (3) every server service holding per-player tables
    is called in `Bootstrap.server.luau`'s `onPlayerRemoving`; (4) no per-frame `setState` in React
    (use bindings). Run a 30-minute soak test across repeated runs, deaths, respawns, and joins/leaves.
  - **Verify:** Lua heap, instance count, and active connections stay flat across repeated runs and
    respawns; zero errors in `LogSink`.

- [ ] **RP-16 · Worst-case performance profiling (4 players + 25 enemies + OhMyGon Phase 2)**
  - **Area:** Performance · **Depends on:** `RP-15`
  - **Work:** Profile client & server frame times under worst-case load (4 players casting abilities,
    25 active enemies or OhMyGon Phase 2 with full VFX/projectiles, drops, and active HUD). Optimize
    any hotspots (particle counts, `SpatialGrid` cell lookups, `Motor6D` updates, `Stepped` /
    `RenderStepped` allocations, reduced-VFX mobile profile).
  - **Verify:** Measured frame times hit `plans/gdd/technical.md` targets: **≥30 FPS** on low-end
    mobile target and **≥60 FPS** on PC, with server Heartbeat comfortably under 16 ms.

- [ ] **RP-17 · Full `doc-drift`, `Makefile`/`make.ps1`, and test coverage audit**
  - **Area:** Quality / Docs · **Depends on:** `RP-16`
  - **Work:** Run a complete audit matching the `doc-drift` skill: every `Config` key referenced in
    `plans/gdd/` exists, every `plans/gdd/` number matches `Config`, every subsystem has an up-to-date
    `docs/<subsystem>.md` row in `docs/README.md`, `Makefile` and `make.ps1` stay 100% in step, and
    every pure `shared/features/` module + client Charm store has passing offline tests.
  - **Verify:** `make check` (`test` + `globals` + `build`) passes cleanly on Linux/macOS and
    `.\make.ps1 check` passes on Windows; zero GDD/doc discrepancies remain.

### 3E. Staging Ops, Release Readiness & Monetization Extension Boundary

- [ ] **RP-18 · Register Staging & Production Universe/Place IDs (`Config/Environments.luau`)**
  - **Area:** Ops / Config · **Depends on:** `HS-27`
  - **Work:** Populate `Config.ENV_UNIVERSES` and universe-scoped Hub/Run place IDs in
    `Config.ENV_IDS` for both `development` (staging) and `production` universes. Verify
    unregistered universes still default safely to `production` (`Environment.selfTest`).
  - **Verify:** `Environment.selfTest` passes; `BuildStamp` displays commit SHA + `development` in
    staging and is completely absent in production.

- [ ] **RP-19 · Configure operational Feature Flags (`Config/Flags.luau`)**
  - **Area:** Ops / Flags · **Depends on:** `RP-05`, `RP-18`
  - **Work:** Define kill-switch flags in `Config/Flags.luau` for high-risk release subsystems (e.g.,
    `PERSISTENCE_WRITES`, `PARTY_TELEPORT`, `PROGRESSION_PURCHASES`) with safe defaults and staff
    overrides, verifying override beats staff (`Flags.selfTest`).
  - **Verify:** `Flags.selfTest` passes; toggling a flag override in Staging DataStore disables the
    gated behavior within `FLAG_REFRESH_SECONDS` (60 s) without republishing.

- [ ] **RP-20 · Live Staging publish & end-to-end multi-device smoke test**
  - **Area:** Ops / QA · **Depends on:** `RP-17`, `RP-18`, `RP-19`
  - **Work:** Publish the release candidate to the `staging` universe and run a real multi-device
    playtest (PC + real mobile phone + console/gamepad): Hub isolation → Party invite → real
    `ReserveServer` teleport → full 5-floor co-op run → Downed & Ally Revive → OhMyGon victory →
    Return to Hub → buy Skill Tree nodes & Perks → rejoin server to verify DataStore persistence.
    Inspect server telemetry via `make logs`.
  - **Verify:** Complete live Staging run succeeds across real devices with zero server errors and
    clean `make logs` output.

- [ ] **RP-21 · Document the Monetization & Dev Items integration boundary (Phase 4 prep)**
  - **Area:** Architecture / Docs · **Depends on:** `RP-20`
  - **Work:** Write a short architecture note (`docs/monetization-hooks.md`) documenting the exact
    clean seams left ready for Phase 4 (when Robux & dev items are added):
    - `ReviveService.onWipeOffer` → 20 s `WIPE_REVIVE_SECONDS` 10-Robux group revive prompt (`MarketplaceService.ProcessReceipt` + `Config.ENV_IDS.PRODUCT_WIPE_REVIVE`).
    - `ProgressionService` → currency packs & permanent/timed currency multiplier (`Config.ENV_IDS`).
    - Cosmetics hook in Hub / `ProfileStore` schema (empty `cosmetics = {}` reserved field).
    - Confirm zero Robux prompts, zero unconfigured product IDs, and zero dead shop buttons exist in
      the Phase 3 build.
  - **Verify:** Reviewed by team; Phase 3 build is 100% shippable as a non-monetized public beta /
    release candidate, and Phase 4 can plug in without refactoring core systems.

---

## Summary of Milestone Exit Gates

| Phase | Total Tasks | Exit Gate ("Done" means…) |
|---|---|---|
| **1. Polished Vertical Slice** | 25 (`VS-01`–`VS-25`) | 1 complete floor (5 fixed rooms + zero-pause 1-of-3 upgrades + Boss Oh + `RunResult` + Retry) verified on PC, mobile, and gamepad with uploaded `.ogg` audio, polished class VFX, and ≥30 FPS mobile / ≥60 FPS PC. |
| **2. Polished Horizontal Slice** | 32 (`HS-01`–`HS-32`) | Full 5 floors × 5 randomized rooms (~15–20 min), all 6 enemy types, all 4 bosses (Oh, My, Gon, 2-phase OhMyGon), and 1–4 player Co-op (isolated Hub, Open/Private Parties, reserved private Run servers, 5 s Ally Revive). |
| **3. Almost Ready-to-Publish** | 21 (`RP-01`–`RP-21`) | Permanent currency, Skill Tree, unlockable abilities, Run Perks, resilient DataStore persistence, Settings, dynamic PC/Gamepad/Touch prompts, exploit/leak/FPS sign-off, live Staging smoke test, and zero monetization/dev items (with clean Phase 4 hook points). |
