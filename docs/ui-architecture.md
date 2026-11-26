# UI architecture

Every screen is React (`react` + `react-roblox`, pinned to the same version), mounted through
`client/ui/Mount.luau`, laid out in design units under one `UIScale`, and fed from stores and
attributes rather than from whatever module happened to build it.

Several of the rules below are not style choices. They are each a bug that shipped.

---

## Mounting

**One React root per ScreenGui, and the root's container is the ScreenGui itself — never a
Folder holding one.**

`ResetOnSpawn` is a property of ScreenGui. A Folder has no such property, so Roblox's respawn
reset wipes the Folder and takes the ScreenGui inside it with it, however carefully that
ScreenGui was marked to persist. This cost every screen in the game this template came from, on
the first respawn, and said nothing about it: no error, no warning, just an empty `PlayerGui` and
a player with no UI for the rest of the round. **A test that never respawns will not find it.**

The price is that the few ScreenGui properties are set in `UI.mount` rather than declared in the
component. That is a fair trade for a UI that still exists after somebody dies.

One root per screen also means screens are independent: one can be unmounted, restarted, or
rewritten — or built imperatively with `Instance.new`, which is still the right answer for
anything that redraws every frame — without any of the others knowing.

**The layout provider sits above the ScreenGui, not inside the scaled frame.** `UI.mount` wraps
each screen in `Scaled.Provider`; the component consumes it with `Scaled.Frame`. Put the provider
inside the frame and the screen's own root component cannot read it, which is four screens
rendering nothing.

**`IgnoreGuiInset` is on for every screen.** It puts the whole UI in one coordinate space with
`GetMouseLocation` and any screen-to-world ray, which is what lets a click become a world
position without a per-screen correction. The price: anything pinned to the top of the screen
adds `Layout.inset()` back by hand, or it sits under Roblox's own bar on a phone.

**`UI.cursorLayer()`** is a ScreenGui at DisplayOrder 100 for things that *are* the pointer — a
crosshair, a drag ghost. `DisplayOrder` is the only thing that decides between two ScreenGuis, so
something that must never be covered needs its own. Nothing clickable goes in it: it is above
every button in the game and would swallow the press.

---

## Scaling

Panels are written in pixels against one reference viewport (`Config.UI_REFERENCE`, 1280x720),
and a single `UIScale` shrinks them together. `client/ui/ScreenMetrics.luau` owns every number
about the screen and builds no instances; `DesignScale.luau` is the frame and the context.

**A `UIScale` scales the object it is parented to, not only its descendants.** A full-screen frame
at `fromScale(1, 1)` with a 0.55 scale on it is 55% of the screen pinned to the top left, and
every edge-anchored panel lands in the middle of the window. `Scaled.Frame` sizes the container
in *design units* — `room`, the viewport divided by the scale — and lets the scale multiply it
back. That is what keeps an edge an edge.

**Offsets inside an attached GUI are design units, not pixels.** They are already scaled;
multiplying by `Layout.scale()` again shrinks twice. What a panel measuring itself wants is
`useLayout().room` (or `.safe`, which takes the top bar and the control band out) — the screen
expressed in the units the panel is already written in. On a phone `room` is *larger* than the
viewport: 667 real pixels at 0.55 is 1212 units of room.

The scale is floored at `UI_MIN_SCALE` rather than shrinking forever — past that a button is
smaller than a fingertip — and quantised to `UI_SCALE_STEP` so dragging a window edge does not
re-lay-out on every frame it passes through. Below `UI_COMPACT_WIDTH`/`HEIGHT` the metrics report
`compact`, and the UI is expected to *restructure* rather than only shrink.

Both the viewport and the input mode are live: Studio's device emulator flips `TouchEnabled`
under a running session and a window drag changes the viewport. Consumers read the
`Layout.state` atom instead of branching once at build time.

---

## State

Three sources, three hooks, in `client/ui/hooks.luau`.

| Source | Hook | Use for |
|---|---|---|
| A replicated attribute | `useAttribute` / `useAttributes` | Anything the server owns |
| A Charm atom (a store) | `useAtom` / `useAtomBinding` | Anything the client computes |
| An `RBXScriptSignal` | `useSignal` | Events, including server broadcasts |

**A feature flag is an attribute too.** The server resolves it per player and writes it, so a
screen reads it with the same hook as everything else and no remote is involved:
`hooks.useAttribute(player, Flags.attribute("NEW_SHOP")) == true`. Compared against `true`
rather than coerced — it is nil until the server has answered, and "not yet known" must read as
off. See [environments.md](environments.md#feature-flags).

**Seeding and subscribing are two different moments.** The value is read during render and the
subscription is made later, when the effect runs. Anything that changes in between happens with
nobody listening and is never reported, because a signal only tells you what happens *after* you
connect. Every hook therefore re-reads inside its effect before trusting the subscription. Miss
that and a panel shows a value that was true a few milliseconds before it mounted — roughly never
in Studio, where nothing else is happening, and occasionally in a real session.

React Lua is React 17, so there is no `useSyncExternalStore` to do this for us. The exports are
`useBinding, useCallback, useContext, useDebugValue, useDeferredValue, useEffect,
useImperativeHandle, useLayoutEffect, useMemo, useMutableSource, useOpaqueIdentifier, useReducer,
useRef, useState, useTransition` — and nothing else.

**Anything that changes every frame is a binding, never state.** `useAtom` on a countdown clock
or a thumbstick knob reconciles a whole screen sixty times a second to move one number.
`useAtomBinding` writes the property and React never wakes up. The same applies to `useSignal` on
a frame signal: pair it with a binding, never with a state setter.

**A hook call inside a loop is a hook call waiting to be skipped.** `useAttributes(instance,
names)` exists for the panels that need one value per item in a list — one subscription call
however long the list is.

---

## Stores

A store is the seam between the plain modules and React. It lives in
`client/features/<feature>/stores/`, and it is **plain Luau** — no instance, no signal object, no
service beyond the one lookup that finds Charm.

That constraint is what earns its keep: `make test ONLY=ui` loads every store in the game
offline, with no DataModel, and runs its `selfTest`. The runner discovers them by walking
`features/*/stores/`, so a new store is tested by existing. The moment a store reaches for a
service, it stops being checkable — and the suite fails with the member name that did it, rather
than quietly testing something else.

A Charm atom notifies only when the value **actually changes**, which is load-bearing the moment
anything writes one per frame.

**Do not put replicated state in a store.** That is a second source of truth that will eventually
disagree with the first. Attributes for what the server owns, stores for what the client
computes.

The rules a store encodes are usually *orderings* — "a later message overtook an earlier one",
"this timer must not clear a label that has since been replaced". Those need two clients and a
stopwatch to reproduce by hand and are three lines of assertion offline, which is the whole
argument for keeping the decision pure and the clock in the component.

---

## What is deliberately not React

Per-frame and per-input logic: a draw loop, an input arbiter, a camera rig, a character
controller. A reconciler has nothing to offer something that runs sixty times a second and would
only slow it down. Those are plain modules that write into a store; the store is what React
reads.

`ui/theme/Palette.luau` keeps the values and two imperative helpers for exactly those draw loops.
`ui/theme/Widgets.luau` is the component half, re-exporting the palette so a colour is defined
once however a thing is built. The visual tokens, shape grammar and HUD layout rules live in
[ui-design-system.md](ui-design-system.md).

Keep `Widgets.luau` small. It is for the three or four shapes every screen repeats. A widget only
one screen uses belongs in that screen's folder, where it can change without anybody auditing the
rest of the game.

---

## Verifying a screen

See [testing.md](testing.md) for the Studio MCP traps in general. Two are specific to UI:

**`require` in the MCP VM hands back a fresh copy of a store**, so writing one from there moves
nothing the running screen is subscribed to. Drive state from the **Server** datamodel
(attributes replicate) or click a real button by `instance_path`, which runs in the game's VM.

**Pretend the screen is a phone without owning one.** `ScreenMetrics` reads two attributes in
Studio, because `_force` over the MCP would land on that same fresh copy:

```lua
game.Players.LocalPlayer:SetAttribute("LayoutViewport", Vector2.new(667, 375))
game.Players.LocalPlayer:SetAttribute("LayoutTouch", true)
```

The UI re-lays-out inside a box that really is 667x375, so "does this column reach the jump
button" has a true answer. Clear both to go back. Measure overlap by walking `PlayerGui` and
comparing `AbsolutePosition`/`AbsoluteSize` — `AbsolutePosition` is inset-relative, so calibrate
with a probe frame rather than reasoning about the inset.
