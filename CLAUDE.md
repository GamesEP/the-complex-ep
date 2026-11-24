# Working in this repo

This is a **template**: the smallest thing that is still a real Roblox game, with the tools,
the structure and the conventions already wired up. This file is how to build in it — the rules
that are easy to get wrong and expensive to rediscover.

**Before anything else: is there a design document?** [`plans/gdd/`](plans/gdd/) is the first
thing a team using this template writes, and it is what features are built from. If
`plans/gdd/overview.md` is still placeholders, say so and offer to write it — the `design-doc`
skill interviews the user and fills it in. Building a feature that no GDD section describes
means guessing at the design, and a plausible guess is worse than a question.

| | |
|---|---|
| [plans/gdd/](plans/gdd/) | **What the game is.** The design. Written first, changed with the design. |
| [docs/](docs/) | **How it is built.** One file per involved subsystem. |
| [README.md](README.md) | Orientation and quickstart |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Workflow: setup, branches, places, Windows |

The game is **The Complex** (see `plans/gdd/`). The template's `example` feature has been
removed; the combat slice — `features/combat/` and `features/enemies/` in each realm, described
in [docs/combat.md](docs/combat.md) — is now the worked reference for every convention below.

Tunables live in `src/shared/core/Config/`. Check there before writing a number into logic.

---

## The shape of the tree

**Realm first, then feature.** A file's path answers two questions before you open it: which
side of the network it runs on, and which feature it belongs to.

```
src/
  shared/          replicated to both; anything the server and client must agree on
    core/          what every feature uses: Config, Net, Assets
    features/      pure rules both realms call — the maths, the policies
  server/
    Bootstrap.server.luau     wiring only
    core/          Net/Dispatcher, Net/RateLimiter, Net/Telemetry
    features/      one folder per feature; behaviour lives here
  client/
    Bootstrap.client.luau     wiring only
    core/          what every client feature uses
    ui/            the UI kit: Mount, DesignScale, ScreenMetrics, hooks, theme/
    features/      one folder per feature
      <feature>/
        stores/    the Charm seams React reads from (discovered by the `ui` test suite)
        ui/        this feature's screens
```

Four rules hold this together:

- **A bootstrap is wiring only.** If a line in `Bootstrap.*.luau` does something other than
  name a module, call its `start`, or connect a lifecycle event, it belongs in a feature. That
  file is the one place a reader sees the whole game's shape at once, and that is only true
  while nothing hides in it.
- **A feature never requires another feature by path.** Take the dependency as an argument to
  `start` instead. Two features that require each other are a cycle, and the fix after the fact
  is always this refactor anyway — do it first and it costs nothing.
- **`core/` is what more than one feature uses.** Moving something into `core/` is a decision
  that it is now shared vocabulary. A module used by exactly one feature lives in that feature,
  where it can change without anybody auditing the rest of the game.
- **Config is a folder merged flat by its `init.luau`.** `Config.MOVE_SPEED` reads the same
  however many files the tunables are spread across, and a key defined by two parts is an error
  at require time rather than a silent last-writer-wins.

### Adding a feature

The combat feature is the same five files a real one is (`Config/Combat`, `shared/features/
combat/Melee`, `CombatService`, the `Attack`/`Dash`/`Spin` remotes, `CombatInput` + `ui/
CombatHud`). To add `powerups`:

1. **Tunables** — `src/shared/core/Config/Powerups.luau`, plus its name in `init.luau`'s
   `PARTS`.
2. **The rule both realms share** — `src/shared/features/powerups/Cooldown.luau`, pure, with a
   `selfTest`. `make test` discovers it by walking the folder; nothing has to be registered.
3. **The server feature** — `src/server/features/powerups/PowerupService.luau`, exposing
   `start(dependencies)` and the remote handlers.
4. **The remote** — one line in `shared/core/Net/Remotes.luau`, one in `Net/Contract.luau`, one
   `Dispatcher.connect` in the server bootstrap. The Dispatcher *refuses* a remote with no
   contract entry, so this cannot be half done.
5. **The client** — `src/client/features/powerups/stores/Kit.luau` for state React reads, and
   `ui/PowerupRing.luau` for the screen, started from the client bootstrap.

Not every feature needs all five. Something with no UI has no `stores/` or `ui/`; something the
client never asks for has no remote.

---

## Every client→server remote is declared in the contract

`shared/core/Net/Contract.luau` declares the rate, the role, the phase and the argument shapes
of every remote a client may fire. `server/core/Net/Dispatcher` is the only thing that connects
one, and it **errors on a remote with no contract entry** — so adding a remote means adding its
contract line, or the server will not wire it.

This is the single most load-bearing convention in the repo, because the failure it prevents is
invisible: a remote without a rate limit works perfectly in Studio, works perfectly in
playtesting, and is the lever an exploiter pulls. Making the limit a precondition of connecting
at all is what turns "we forgot" into "it does not start".

- **`args` is a shape check and nothing more.** Whether a string names a real item, whether a
  number is in range, whether this player may do this right now — that is the handler's, because
  the handler is the only thing that knows what the value means.
- **Prefer replicated state to a reply.** A remote is for *events*. State the client displays
  belongs on an attribute, which replicates on its own, needs no "send me the current value"
  remote, reaches every client rather than the one that asked, and cannot get out of sync.
- **A server→client broadcast needs no contract entry.** The contract is about what a *client*
  is allowed to send.
- **Refusals are silent to the sender** and counted by `core/Net/Telemetry`.

Full detail, including why `rate = "custom"` exists and how the client report channel is
double-validated: **[docs/net-contract.md](docs/net-contract.md)**.

---

## The screens are React; deliberately not everything else is

Every ScreenGui lives in its feature's `ui/` folder and is built with react-roblox (`react` and
`react-roblox`, pinned to the same version in `wally.toml`).

What should *not* be a component: per-frame and per-input logic. A draw loop, an input arbiter,
a camera rig, a character controller — a reconciler has nothing to offer something that runs
sixty times a second, and would only slow it down. Those are plain modules that write into a
store; the store is what React reads.

**Mount through `UI.mount`, and never into a Folder.** The React root's container is the
ScreenGui itself. `ResetOnSpawn` is a property of ScreenGui — a Folder has no such property, so
Roblox's respawn reset wipes the Folder and takes the ScreenGui inside it with it, however
carefully that ScreenGui was marked to persist. This costs every screen in the game on the first
respawn and says nothing about it: no error, no warning, just an empty `PlayerGui` and a player
with no UI for the rest of the round. **A test that never respawns will not find it.**

**The layout provider sits above the ScreenGui, not inside the scaled frame.** `UI.mount` wraps
each screen in `Scaled.Provider`; `Scaled.Frame` consumes it. Put the provider inside the frame
and the screen's own root component cannot read it.

**Anything that changes every frame is a binding, never state.** A clock, a reticle, a
thumbstick knob. `setState` at 60 fps re-renders a whole screen per frame to change one
character; `useBinding` (via `hooks.useAtomBinding`) writes the property and React never wakes up.

**Reading outside state means re-reading inside the effect.** `useAttribute`, `useAttributes`
and `useAtom` all seed during render and subscribe later, and anything that moves in between
happens with nobody listening. React Lua is React 17 — there is no `useSyncExternalStore`.

**A hook call inside a loop is a hook call waiting to be skipped.** `useAttributes(instance,
names)` exists for the panels that need one value per item in a list.

**A store is the seam, and it is plain Luau** — no instance, no signal object, no service beyond
the one lookup that finds Charm. That is what lets `make test ONLY=ui` load every store in the
game offline and assert its rules.

**Do not put replicated state in a store.** That is a second source of truth that will
eventually disagree with the first. Attributes for what the server owns, stores for what the
client computes.

Full detail — mounting, scaling, the three hooks, what is deliberately not React, and how to
verify a screen from the MCP: **[docs/ui-architecture.md](docs/ui-architecture.md)**.

---

## Screen size

`src/client/ui/ScreenMetrics.luau` owns every number about the screen. Panels are written in
pixels against one reference viewport and a single `UIScale` shrinks them together.

- **A `UIScale` scales the object it is parented to, not only its descendants.** A full-screen
  frame with `fromScale(1, 1)` and a 0.55 scale on it is 55% of the screen pinned to the top
  left, and everything anchored to its right or bottom edge lands in the middle of the window.
  `DesignScale.Frame` sizes the container in *design units* (`room` — the viewport divided by
  the scale) and lets the scale bring it back, which is what keeps an edge an edge.
- **Offsets inside an attached GUI are design units, not pixels.** They are already scaled;
  multiplying by `Layout.scale()` again shrinks twice. What a panel wants is `room` / `safe` —
  how much room it has, in the units it is written in.
- **Every ScreenGui here runs `IgnoreGuiInset = true`**, so the whole UI shares one coordinate
  space with `GetMouseLocation` and any screen-to-world ray. Add `Layout.inset()` by hand to
  anything pinned to the top, or it sits under Roblox's own bar on a phone.
- **A `Frame` does not sink input; a `GuiButton` does.** A slider track built from a frame hands
  the same drag to the camera as well. Make sliders buttons, and set `Active = true` on
  scrolling panels.

See [docs/ui-architecture.md#scaling](docs/ui-architecture.md#scaling).

---

## Verifying a change

`make test` (`scripts/run-tests.luau`) runs every suite that does not need Studio, each loading
the real module under the sandbox in `scripts/lib/sandbox.luau`. Narrow it while iterating with
`make test ONLY=ui`; **`make test-list` names the suites** — it asks the runner, so it cannot go
stale the way a list written down here does. `make check` is that, plus `make globals`, plus the
build.

**`make globals` is the one gate that reads names rather than shapes.** The syntax pass
compiles, so it does not resolve `require`s and knows none of Roblox's globals, and `rojo build`
packs source without reading it at all — so a require through a name nobody bound
(`require(Shared.features.…)` in a module that never declared `Shared`) builds clean, passes
every suite, and then throws on the first frame of a real server, taking that whole realm's
bootstrap with it. `make globals` runs `luau-lsp analyze` and fails on `Unknown global` alone;
it is deliberately narrower than `make analyze`, which cannot gate once a codebase has
pre-existing type findings. It needs `make lsp-defs` once per machine.

It also catches the subtler half of the same class: **a `local` read a few lines above its own
declaration is the global of that name**, so it is silently `nil` rather than an error.

That is still a small fraction of what can break. The self tests only cover what is pure, and a
suite that needs a service does not belong in them. Real verification means running it in Studio.

### What belongs in a test, and what cannot

Extract the decision. A rule that is `(inputs) -> outcome` with no service in the middle can be a
shared module with a `selfTest`, and then it is asserted in milliseconds instead of costing a
sync, a Play and a look. Anything that needs a DataModel, a physics step or a frame cannot be,
and pretending otherwise produces a test that stubs so much it is testing the stubs.

The orderings are the case worth the effort: "a message arrived about something already
replaced", "an effect fired before its screen mounted". Those need two clients and a stopwatch to
reproduce by hand, and are three lines of assertion as a pure policy module.

### The sync trap, in this exact order

1. Edit files.
2. `start_stop_play(false)` — stop any running session.
3. Confirm the Edit datamodel actually has the change: `script_grep`, or read `.Source` on the
   synced script with `datamodel_type: "Edit"`.
4. `start_stop_play(true)`.

Rojo syncs into the Edit datamodel, and pressing Play clones it at that instant. Starting Play
right after an edit routinely runs the *previous* version, and the resulting "the fix did
nothing" wastes a whole debugging cycle. Skipping step 3 is the most reliable way to lose an hour
in this repo.

### The MCP Luau VM is separate from the game's

`require` there returns a fresh copy of a module — so reading module state tells you nothing
about the running game — **and it caches across calls**, so a module edited and re-required in a
later call is still the first table, with none of your new fields. Verify through instances and
physics instead: positions, velocities, attributes, pixel buffers.

### Measure, don't eyeball

A screenshot proves very little on its own. Read the numbers and report them.

The rest — the sandbox, the rule for adding a suite, synthetic input, emulating a phone, and the
inotify failure that looks like a Rojo bug: **[docs/testing.md](docs/testing.md)**.

---

## Two kinds of world, and which rule applies

Getting these the wrong way round puts players in open air — and with a void-catcher returning
anyone below a floor to that same spawn, they fall forever.

**Built from code** (`server/features/world/WorldBuilder`) means the coordinates are world
coordinates in `Config`, and the table that places a wall and the table that places a spawn are
read from the same file. There is no model whose pivot they could hang off.

**A tracked model** under `assets/`, mounted by `default.project.json`, is something somebody
placed in Studio and exported. Every spawn on one of those is an **offset from the model's
pivot**, never a world position — a map that gets moved or yawed takes its spawns with it.
Resolve through the pivot with `pivot * offset`, never `pivot.Position + offset`: the multiply
carries rotation. And resolve **on use, not at require time** — a cached world position is a
hardcoded one with extra steps, and `Config` is required long before `Workspace` is worth
reading.

Two things that only bite once spawns are hand-authored rather than sampled at runtime:

- **A Model stores its pivot in two properties, and they can disagree.** `WorldPivot` and
  `WorldPivotData` both survive serialisation, and different tools read different ones. Decide
  which one your offsets are measured against, and make anything that writes a pivot write both.
- **A Model with neither an explicit pivot nor a `PrimaryPart` has no dependable pivot.** Roblox
  derives it, and the derived value moves between loads — observed swinging 50+ studs inside a
  single session, which puts every spawn on that map underground. Stamp an explicit pivot in and
  commit it.

**Never hand-edit a model that code rebuilds.** If `WorldBuilder.build()` destroys and recreates
it on server start, a wall you moved in Studio is gone the moment you press Play. Change the
builder, not the model. `syncback.project.json` deliberately omits anything in that category.

---

## Two experiences, and knowing which build is in front of you

**Roblox has no staging slot.** The only thing it isolates DataStores, passes, products and
badges by is the *universe*, so an environment here is a universe: `staging` publishes to the
develop experience, `main` to the production one, and places inside a universe share all of its
data rather than separating it.

- **The environment is resolved from `game.GameId` at runtime**, by `shared/core/Environment`,
  never baked in by the build. The same commit publishes to both places by merging up, so a
  build-time constant would be right in one and quietly wrong in the other.
- **An unregistered universe is treated as production**, and `Environment.selfTest` fails if
  that default is changed. Guessing "development" hands admin and every dev-only guard to a
  universe nobody registered — which, for a fresh clone with an empty table, is production.
- **Every id Roblox scopes per universe goes in `Config.ENV_IDS`** and is read through
  `Environment.id(key)`, which answers `0` for anything absent, like `Assets.id`. A pass id
  written next to the code that spends it is correct in one universe and wrong in the other,
  and nothing offline can tell.
- **Guard dangerous things with `Environment.isProduction()`/`isStudio()`, not
  `RunService:IsStudio()`.** Same test today; not the same the moment a universe wants the team
  to have admin, and written this way that is one row in `Config` rather than a grep.

**Nothing on the platform says what is live.** `PlaceVersion` counts publishes and names no
commit. So CI stamps the commit into the place (`scripts/stamp-build.sh` → `shared/core/Build`),
`LogSink` carries it into every flush, every non-production client wears it in the corner, and a
publish from `main` tags `release/<date>-<sha>`. Rolling back means publishing an older commit,
which needs a record of which one was good.

**Feature flags are what make one extra universe enough.** A private QA experience proves a
feature is correct; it cannot prove it holds at forty players against real DataStore throughput.
`shared/core/Flags` is the pure rule, `server/features/flags/FlagService` reads the overrides
from a DataStore and publishes each player's answers **as attributes on the player** — no remote,
nothing in the contract. Order is override, staff, rollout, default, and **the override beats
staff**, because a kill switch that leaves the feature on for whoever is handling the incident is
not a kill switch.

Full detail — registering a universe, the dashboard settings the repo cannot see, rollout
buckets, and what a dev universe structurally cannot buy you:
**[docs/environments.md](docs/environments.md)**.

---

## Reading a published server

**Roblox gives you no server log file.** In Studio the client and server share a process, so the
output window has everything. A published game does not work that way: the server runs on
Roblox's machines, its `print` and `warn` reach no player's log, and the only live view is F9 for
whoever is standing in the game. Creator Hub keeps script *errors* — the half that raises itself.
The half that hurts is the faults that do not throw.

So the server keeps its own ring buffer: `server/features/telemetry/LogSink`, one DataStore key
per server, read back with **`make logs`**.

**A silent failure path should report, not `return`.** `client/core/Diagnostics` exists for the
paths where being silent is the norm — a resource the budget refused comes back as a plain `nil`,
a request that could not be served just shows nothing. Each of those is correct behaviour and
completely invisible. Route them through `Diagnostics.fault(area, code, detail, fields)`, where
the console line comes on a curve rather than once or sixty times a second, and codes are stable
kebab-case because they are what you grep for.

Full detail: **[docs/telemetry.md](docs/telemetry.md)**.

---

## Engine gotchas already paid for

The full list, with the reproductions, is [docs/roblox-gotchas.md](docs/roblox-gotchas.md). The
ones that change how you write code here:

- **`Destroying` never fires on the client** for something the server destroyed — replication
  only unparents it, and its children keep pointing at it, so `.Parent` stays non-nil too. Use
  `AncestryChanged` (parent nil) or `IsDescendantOf(workspace)` for end-of-life. Getting this
  wrong silently stacks one handler per respawn, all fighting over the same module-level flags.
- **Module-level state outlives the thing it was about.** A teardown running for an old body
  must not tidy up after the new one that has already started. Gate teardown on a token, and
  have `start` reset the flags so nothing can inherit a state nobody turned on.
- **A Model replicates before the parts inside it.** Attaching to one means yielding on
  `WaitForChild`, and how long that takes differs per client. Anything a client *rebuilds* per
  object — as opposed to reads back every frame — needs a monotonic stamp on the object and a
  policy for messages that arrive early, late, or about something already replaced.
- **Editable assets share a small memory budget** and fail by returning a plain `nil`, no error.
  Do not allocate per respawn, and never cache a failure as "impossible".
- **`Content` object references are strong** and keep the referenced object alive regardless of
  any Lua variable.

---

## Documentation is part of the change

Three places, and knowing which one a fact belongs in is the whole discipline:

| | |
|---|---|
| `plans/gdd/` | **What the game is.** A change to what a player experiences goes here. |
| `docs/` | **How a subsystem works.** A change to how something is done goes here. |
| A code comment | **Why this line is the way it is**, and what breaks if it changes. |

**Docs change in the same commit as the feature.** These are load-bearing — agents read
`docs/<subsystem>.md` before working on a subsystem, and so does anybody returning to one after
a month. One stale file is enough for people to stop trusting all of them, so a doc that
contradicts the code is a defect, not untidiness. If a subsystem is new and involved enough to
need a doc — more than two or three modules, or one carrying a non-obvious invariant — the
change that adds it adds the doc, and a row in `docs/README.md`.

**Comments reference the docs, they do not duplicate them.** A comment says the one thing you
need to know *at that line*:

```lua
-- The root's container is the ScreenGui itself, never a Folder: a Folder has no ResetOnSpawn,
-- so the respawn reset takes the ScreenGui inside it with it. See docs/ui-architecture.md.
```

A thirty-line block above a module goes unread at exactly the moment it matters, drifts from the
code beneath it, and cannot be linked to — so the same paragraph gets written again in the next
module that needs it. That is why `docs/` exists. Keep the reason in the code; move the argument
out.

Same rule for `CLAUDE.md` itself: it is the always-loaded index. Rules and pointers here, the
long form in `docs/`.

The `doc-drift` skill checks all of this against the code — GDD numbers against `Config`, doc
paths against the tree, subsystems with no doc. Worth running before a release or after a large
refactor.

## The two build files stay in step

`Makefile` and `make.ps1` are two ports of one thing: the same targets, the same `KEY=VALUE`
overrides, the same behaviour. **A target added, renamed or changed in one belongs in the other
in the same commit**, and so does a changed flag or a changed default.

They drift the moment only one is edited, and the drift is quiet — a Windows contributor runs
`.\make.ps1 check`, gets a green run, and it means something weaker than CI's green run. That
is worse than not having the file. (The version this template was cut from had already drifted:
`make.ps1` still had a target for a script that had been renamed, and lacked `globals`,
`test-list` and `logs` entirely.)

`make.ps1` keeps its help table and its switch in step by construction — every target in the
table must have a case, and the unknown-target check reads the same table. If you add one, add
both halves.

Where a target is backed by a shell script, **both call the same script through Git Bash** rather
than reimplementing it in PowerShell. One implementation, and CI calls it directly too.

## Rules for agents specifically

- **Work only on the `develop` branch.** Never commit to, push to, or modify `main` (or any
  other branch) unless the user explicitly asks to switch. Check the active branch before
  committing.
- **Check the design document first.** If `plans/gdd/` does not describe the feature you have
  been asked to build, say so and ask, or offer the `design-doc` skill. Guessing at a design
  produces something plausible that is not what anybody wanted, and its confidence is what makes
  that hard to notice.
- **Follow the tokensave rule in the user's global instructions**: use the tokensave MCP tools
  for code exploration in a project that has `.tokensave/`, not exploration agents.
- **`make check` before you say it works.** "It should work" is not a result. If Studio is
  needed to be sure, say that it is and say what you did verify.
- **Update the docs and the GDD in the same change**, per the section above. And keep `Makefile`
  and `make.ps1` in step.
- **Comment the *why*, in the shape of the surrounding code.** This codebase's comments explain
  what went wrong last time and what would break if the line changed — not what the line does. A
  comment restating the code is noise; a comment naming the failure it prevents is the most
  valuable thing in the file. Keep it short and link the argument.
- **Do not add a remote without its contract entry.** The Dispatcher will refuse it, and the
  refusal will look like a bug in something else.
- **Do not write a universe-scoped id into a module.** Passes, products and badges differ per
  universe — they belong in `Config.ENV_IDS`, read through `Environment.id`.
- **Do not widen `core/` casually.** Something one feature uses stays in that feature.
- **When something is unverifiable offline, say so rather than asserting it works.** Half the
  invariants in this file exist because a plausible-looking change passed everything that could
  be run and broke on the first real client.
