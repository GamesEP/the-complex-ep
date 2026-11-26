# UI Design System — Hazard Arc

The shared visual and layout grammar for **The Complex**. It combines two complementary layers into
one industrial control-panel language:

- **Top & informational surfaces ("Sector Hazard"):** sharp architectural plates (`CORNER = 2`),
  dark concrete/charcoal fills, hairline steel borders, `3px` left/top semantic accent bars, and
  monospace telemetry readouts.
- **Bottom-right tactile controls & upgrade nodes ("Machined Brawl Arc"):** pure circular
  machined-steel actuators (`CORNER_ROUND = 999`) with dark radial cores and `2.5px` luminous
  semantic outer rings arranged in a right-thumb arc.

Why the two shapes cohere: real industrial hardware (sector blast doors, elevators, mech consoles)
pairs rectangular steel status plates with circular push-buttons. Making **shape equal function**
— angular for read-only telemetry and upgrade tickets, circular for actions you press — keeps every
screen consistent from `CombatHud` to the future skill tree without candy-colored mobile clutter.

The values live in `src/client/ui/theme/Palette.luau` and the shared primitives live in
`src/client/ui/theme/Widgets.luau`. Never hardcode colours or corner radii inside feature screens.

---

## Colour Tokens (`Palette.luau`)

| Token | Hex | RGB | Role |
|---|---|---|---|
| `INK` | `#141618` | `20, 22, 24` | Deep backing, bar tracks, outer halos, text on yellow badges |
| `PANEL` | `#181B1F` | `24, 27, 31` | Default architectural plate fill |
| `STEEL` (`PANEL_LIGHT`) | `#22262B` | `34, 38, 43` | Secondary plate surface, actuator core base |
| `STEEL_TOP` | `#2E343C` | `46, 52, 60` | Top highlight stop of machined actuator `UIGradient` |
| `BORDER` | `#3A4048` | `58, 64, 72` | Hairline `1.5px` plate outline |
| `HAZARD` (`HIGHLIGHT`) | `#F5C400` | `245, 196, 0` | Sector tags, stat upgrades, active Slot 1, block/parry flash, warnings |
| `STRIKE` | `#FF3B30` | `255, 59, 48` | Attack anchor ring, Boss HP bar, low-health danger, grab alert border |
| `KINETIC` | `#38D4FF` | `56, 212, 255` | Dash actuator, movement passives (`2x Dash`, `2x Jump`), speed buff |
| `VITAL` | `#44E37B` | `68, 227, 123` | Player HP bar, room-cleared confirmation |
| `ABILITY_1` | `#F5C400` | `245, 196, 0` | Active ability slot 1 (`Spin` in the playable slice) |
| `ABILITY_2` | `#2CE5B8` | `44, 229, 184` | Active ability slot 2 |
| `ABILITY_3` | `#B97CFF` | `185, 124, 255` | Active ability slot 3 |
| `GUARD` | `#CFD8E3` | `207, 216, 227` | Block / Parry idle ring (flashes `HAZARD` while blocking) |
| `HEAVY` | `#FF9F2E` | `255, 159, 46` | 3-second Heavy Attack charge ring and bar |
| `GRAB` | `#FF2E93` | `255, 46, 147` | Grabber escape mash bar & trapped Attack pulse |
| `BUFF_DAMAGE` | `#FF693C` | `255, 105, 60` | Temporary damage drop buff |
| `BUFF_SPEED` | `#38D4FF` | `56, 212, 255` | Temporary speed drop buff |
| `BUFF_DEFENSE` | `#58A0FF` | `88, 160, 255` | Temporary map defense buff |
| `TEXT` | `#F4F5F0` | `244, 245, 240` | Primary high-contrast off-white copy |
| `MUTED` | `#949EAB` | `148, 158, 171` | Secondary labels, unit tags, commit stamps |

---

## Typography & Geometry

| Token | Value | Use |
|---|---|---|
| `DISPLAY_FONT` | `Enum.Font.GothamBlack` | High-impact badges, actuator primary labels, modal headers |
| `TITLE_FONT` | `Enum.Font.GothamBold` | Panel titles, upgrade names, button text |
| `BODY_FONT` | `Enum.Font.Gotham` | Short secondary copy (rare during combat) |
| `MONO_FONT` | `Enum.Font.RobotoMono` | HP ratios, cooldown timers, wave/sector stamps, keycaps (`LMB`, `SH`, `E`) |
| `CORNER` | `2` | Sharp industrial plates, bars, keycaps, upgrade tickets |
| `CORNER_ROUND` | `999` | Pure circular actuators and skill tree nodes |
| `ACCENT_WIDTH` | `3` | Semantic left or top accent bar on architectural plates |
| `STROKE` | `1.5` | Hairline border on plates |
| `ACTUATOR_STROKE` | `2.5` | Luminous semantic ring around circular actuators |

### Circular Cooldown Clipping (No `CanvasGroup`)

`Frame.ClipsDescendants` clips to a rectangular bounding box, not to `UICorner`. To fill a circular
actuator from bottom to top at 60 FPS without `CanvasGroup` VRAM overhead, `ui.Actuator` places a
circular child fill layer (`CornerRadius = 999`) with a `-90°` `UIGradient` whose `Transparency`
`NumberSequence` steps cleanly at the current charge binding (`0..1`). React never re-renders while
cooldowns or heavy-charge rings animate.

---

## Screen Zones & Platform Adaptation

Every screen mounts inside `Scaled.Frame` with `IgnoreGuiInset = true` (see
[ui-architecture.md](ui-architecture.md)), adding `Layout.inset()` to every top-anchored element.

| Zone | Desktop & Console | Mobile (`metrics.touch`) |
|---|---|---|
| **Top-left** | `Vitals` plate (`UNIT 01` + HP bar with quarter ticks), timed drop buff chips stacked directly below (semantic stripe + draining bar + right-aligned `MONO_FONT` countdown in seconds), future co-op squad strips | Compact `Vitals` plate (`176` units wide) + compact timed buff chips with live countdown below (keeps bottom-left free for thumbstick) |
| **Top-center** | `SectorBar` pill (`SEC-01 // OLEADA W/N \| X HOSTILES`) + future zero-pause 3-ticket `UpgradeChoice` strip + `+N` queue badge (enemy Grabber / Paso Fantasma telegraphs are diegetic overhead `!` triangles) | Compact `SectorBar` (`O2/5 \| 8`) + single-row tap-sized `UpgradeChoice` tickets staying in upper ~20% of screen |
| **Bottom-center** | Future Boss HP bar (`UNIT // OH`, zero collision with top `UpgradeChoice`); active `HeavyCharge`, `StunBanner` (`¡ATURDIDO!`), and `GrabEscape` urgent plates | Same, raised cleanly above bottom margin between the left thumbstick and right touch arc |
| **Bottom-right** | Compact machined **Hazard Arc** (`ATK`, `DSH`, `BLK` + 3 switchable ability actuators with custom emblems: `1 Giro`, `2 Stinger`, `3 Over Drive`, highlighting active slot `E` via `AbilityStore`) | Full thumb-sized interactive `TextButton` radial arc wrapping cleanly around Roblox's built-in bottom-right Jump button (`Config.TOUCH_BUTTON + Config.TOUCH_MARGIN` clearance); tapping any of the 3 ability actuators casts directly |
| **Bottom-left** | Non-production `BuildStamp` only (`displayOrder = 50`) | Roblox virtual thumbstick (no gameplay HUD panels enter `Layout.band()`) |

---

## Extending to Future Screens

All upcoming screens in [plans/gdd/ui.md](../plans/gdd/ui.md) follow the same shape/colour rules:

- **`UpgradeChoice`:** 3 horizontal `ui.Panel` tickets (`accent = "top"`) coloured by category
  (`HAZARD` stats, `KINETIC` movement passives, `ABILITY_1/2/3` actives) with crisp `2px` square
  keycaps (`1` / `2` / `3`) and a `+N` queue chip. When replacing one of 3 full active slots, the
  3 tickets mirror the exact ring colours of the bottom-right active actuators.
- **`RunResult` & Wipe Revive (10 Robux):** Centered architectural dossier plate (`#181B1F`,
  `HAZARD` / `STRIKE` top bar, `MONO_FONT` summary metrics) paired with a high-contrast primary
  action trigger.
- **Permanent Skill Tree:** Orthogonal blueprint connector traces linking `ui.Actuator` circular
  nodes (dim `BORDER` locked → pulsing `HAZARD` affordable → lit `KINETIC`/`TEXT` unlocked).
