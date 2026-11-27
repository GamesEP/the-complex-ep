# Zero-pause 1-of-3 run upgrades

How Pillar 1 builds work during a run: everyone starts identical with `TestSword`, `100` HP, `26` walk speed, and 0 active abilities, then drafts their build without ever pausing combat. Design rules live in [`plans/gdd/systems.md`](../plans/gdd/systems.md) and [`plans/gdd/ui.md`](../plans/gdd/ui.md).

## Modules

| Module | Realm | Responsibility |
|---|---|---|
| [`Config/Upgrades.luau`](../src/shared/core/Config/Upgrades.luau) | Shared | Catalog of all 9 active abilities (`UPGRADE_ABILITY_ORDER`), level scaling (`+25%` dmg / `-10%` cd per level up to Lv. 3), 4 repeatable `STAT_UPGRADES`, and 2 unique `PASSIVE_UPGRADES` (**Doble Salto**, **Doble Dash**). |
| [`UpgradePool.luau`](../src/shared/features/upgrades/UpgradePool.luau) | Shared (pure) | 1-of-3 starter & room-clear rolling, 3/3 slot-full conversion (level-up, replacement offer, or stat card), unbounded per-player offer queue, pick/replace validation, and floor-exit random auto-resolve. Tested offline by `make test`. |
| [`UpgradeService.luau`](../src/server/features/upgrades/UpgradeService.luau) | Server | Owns per-player `PlayerBuild`, replicates build attributes, pushes `{ offer, pending }` via `Remotes.UpgradeOffer`, and validates `PickUpgrade` / `ReplaceAbility`. |
| [`UpgradeStore.luau`](../src/client/features/upgrades/stores/UpgradeStore.luau) | Client store | Pure Charm atoms (`offer`, `pending`, `replacingCardIndex`) tested offline by `make test ONLY=ui`. |
| [`UpgradeChoice.luau`](../src/client/features/upgrades/ui/UpgradeChoice.luau) | Client UI | Zero-pause top-center 3-ticket Hazard Arc banner below `SectorBar`, `+N` queue chip, 3-slot replace view, and `Q` / `E` / `F` PC hotkeys bound above `CombatInput` only while an offer is open. |

## Replicated Player attributes

Written by `UpgradeService` and read directly by `CombatService`, `CombatInput`, and `CombatHud`:

- `AbilitySlot1..3` (`string`): ability id in each active slot (empty string when empty)
- `AbilityLevel1..3` (`number`): `1..3` (0 when empty)
- `UpgradeMaxHealthBonus` (`number`): additive Max HP bonus
- `UpgradeDamageMult` (`number`): outgoing damage multiplier applied inside `CombatService` `hitEnemy`
- `UpgradeSpeedMult` (`number`): walk speed multiplier applied inside `CombatService` `refreshWalkSpeed`
- `UpgradeCooldownMult` (`number`): multiplicative cooldown haste floored at `Config.MIN_COOLDOWN_MULTIPLIER` (`0.45`)
- `HasDoubleJump` (`boolean`): unlocks 1 mid-air jump (`UserInputService.JumpRequest`, `Config.DOUBLE_JUMP_POWER`) with air-ring VFX and `doubleJump` SFX
- `HasDoubleDash` (`boolean`): grants +1 permanent base dash charge (`Drops.maxDashCharges`), stacking cleanly with Speed Buff drops

## Input ergonomics (`Q` / `E` / `F` & Gamepad D-Pad)

While `UpgradeChoice` has an active offer during `"fighting"` or `"transition"`:

- `Q`, `E`, `F` (PC) and `DPadLeft`, `DPadUp`, `DPadRight` (Gamepad) are bound via `ContextActionService:BindActionAtPriority` at `High.Value + 50` (higher than `CombatInput`'s `High.Value`), picking cards 1 / 2 / 3 (or slots 1 / 2 / 3 in replace mode) and sinking those keys so they do not trigger Dash/Ability/Block.
- For the first `0.35 s` after a new offer opens, keyboard/gamepad shortcuts pass through so a mid-combat reflex press of `E` or `F` never picks a card accidentally (clicking or tapping a ticket works immediately).
- `LeftShift` (Dash), `LMB` (Attack), `RMB` (Block), `WASD`, `Space`, and `1`/`2`/`3` remain completely unobstructed mid-fight.
- `Escape` / `ButtonB` / `DPadDown` cancels 3-slot replacement mode back to the 3 cards.
- Clicking or tapping any ticket works on desktop and touch; when no offer is open or the run is not active (`preparing` / `victory` / `defeat`), `UpgradeChoice` hides and returns `Pass` so combat controls work normally.
- When advancing through a multi-offer queue, `UpgradePool` refreshes any newly redundant card in the next offer (e.g. an already-acquired passive or maxed/replaced ability) into a fresh stat card so no queued pick is wasted.

## Remotes

- Server -> Client: `UpgradeOffer({ offer, pending })`
- Client -> Server (contracted in [`Contract.luau`](../src/shared/core/Net/Contract.luau)):
  - `PickUpgrade(offerId: number, cardIndex: number)`
  - `ReplaceAbility(offerId: number, cardIndex: number, slotIndex: number)`
