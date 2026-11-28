# Co-op Downed, Ally Revive & Squad Scaling

How 1–4 player downed state, 5-second proximity ally revives, squad HUD telemetry, and co-op wave/boss scaling work (`plans/gdd/systems.md`, `plans/roadmap.md HS-04 / HS-28..HS-31`).

## Tunables & Pure Rules

- **Config:** [`src/shared/core/Config/Revive.luau`](../src/shared/core/Config/Revive.luau) (`ALLY_REVIVE_SECONDS = 5`, `ALLY_REVIVE_RADIUS = 8`, `ALLY_REVIVE_HEALTH_FRACTION = 0.5`, `ALLY_REVIVE_IMMUNITY_SECONDS = 2.0`, `ALLY_REVIVE_EXTRA_HELPER_BONUS = 0.35`) and [`src/shared/core/Config/Difficulty.luau`](../src/shared/core/Config/Difficulty.luau) (`COOP_WAVE_COUNT_SCALE`, `COOP_BOSS_HEALTH_SCALE`).
- **Pure rules:** [`src/shared/features/revive/ReviveRules.luau`](../src/shared/features/revive/ReviveRules.luau) (`selfTest` verified by `make test`):
  - **Solo / last standing:** `canEnterDowned(0) == false` → triggers wipe immediately.
  - **Co-op downed:** While ≥1 teammate stands, lethal damage drops the player to `Downed = true` at `1 HP` instead of killing/respawning the character.
  - **5 s channel:** Standing teammates inside `8 studs` advance `ReviveProgress` (`0..1`) over `5 s` (additional helpers inside the ring accelerate slightly). Taking normal damage does **not** reset the channel; leaving the radius, getting downed, hard-stunned (`StunnedUntil`), or grabbed (`Grabbed`) interrupts and resets progress to `0`.
  - **Wipe extension hook:** `ReviveRules.resolveWipe(onWipeOffer)` resolves straight to `"defeat"` in Phase 2 while preserving a clean hook for future wipe-revive offers without refactoring.

## Server & Client Integration

- **Server (`ReviveService.luau`):** Wired into `CombatService.hurt` via `onLethalDamage`. When a player enters `Downed`, `CombatService.onPlayerDowned` freezes movement and cancels active attacks/blocks/charges; `EnemyService` excludes downed players from `targets()` and `canGrab` so enemies immediately pivot to standing teammates. On revive completion, restores `50%` MaxHealth, grants `2.0 s` invulnerability (`InvulnerableUntil`), and plays `playerRevived` SFX. On disconnect (`ReviveService.forget`), immediately checks `isSquadWiped` so if the last standing teammate leaves, the run ends cleanly.
- **Client visuals (`ReviveVisuals.luau`):** Renders an 8-stud diegetic ground ring, expanding radial progress disc, and overhead `BillboardGui` (`CAÍDO` / `REANIMANDO X.Xs`) over every downed player.
- **HUD (`CombatHud.luau`):** Displays compact **Co-op Squad Vitals** strips beneath top-left `Vitals` whenever teammates are present (showing HP bars and `CAÍDO` / `REAN. XX%` / `ATRAPADO` badges) plus a bottom-center `DownedBanner` when the local player is downed.

## Co-op Scaling & Abandonment Rescaling

- [`Difficulty.luau`](../src/shared/features/enemies/Difficulty.luau) scales wave enemy counts (`COOP_WAVE_COUNT_SCALE`, strictly clamped to `Config.MAX_ACTIVE_ENEMIES = 25` by `FloorGenerator.capWave`) and boss health (`COOP_BOSS_HEALTH_SCALE`, never duplicating bosses) for `1..4` players.
- [`WaveDirector.luau`](../src/server/features/enemies/WaveDirector.luau) reads the live `#Players:GetPlayers()` count right as each wave spawns, so mid-run abandonment (`HS-03`) automatically rescales subsequent waves and bosses to the remaining squad size.

## Not Yet Verified in Studio

- Multi-client Studio Play (2–4 clients) confirming enemy pivot away from downed players, 5 s channel completion/interruption under live hits/stuns, and co-op boss HP feel.
