# Roblox game template

A starting point for a Roblox game: the toolchain, the project structure, the conventions and
the CI, with one worked example feature and nothing else. It builds, it runs, it publishes, and
`make check` is green — from the first clone.

It is deliberately not a framework. There is no base class to inherit from and no lifecycle to
register with; what it gives you is a **shape** — where things go, how a client talks to a
server, how a screen gets on screen, and what can be tested without opening Studio.

## What is in it

| | |
|---|---|
| **Rojo 7** | The repo is the source of truth. A `.rbxl` is a build output, never a workspace. |
| **Wally** | Dependencies pinned in `wally.toml` / `wally.lock`; `Packages/` is generated. |
| **Rokit** | The whole toolchain pinned in `rokit.toml`, so CI and every machine agree. |
| **Lune** | Runs the offline test suites, and any repo script that needs Roblox datatypes. |
| **luau-lsp** | Autocomplete, type-checking, and the `make globals` gate. |
| **StyLua** | One house format, configured in `stylua.toml`. |
| **React** (react-roblox) | Every screen. Plus a UI kit: scaling, hooks, theme, mount. |
| **Charm** | Atoms behind the stores React reads — testable offline, with no DataModel. |
| **SignalPlus** | Signals, for the events that have no current value to store. |
| **GitHub Actions** | Build + test on every PR; publish to a place on push to `staging`/`main`. |
| **Studio MCP** | An agent can drive Studio: read the tree, run Luau, take screenshots. |

Plus two things a Roblox project usually lacks and misses badly:

- **Offline tests.** `make test` runs every pure rule in the game in milliseconds, without
  Studio. `make globals` catches the class of error that builds clean and dies on the first
  frame of a real server.
- **A readable published server.** Roblox gives you no server log file. `features/telemetry/LogSink`
  keeps a ring buffer in a DataStore and `make logs` prints it in a terminal.

## Getting started

**Step one is not code.** Write the design document in [`plans/gdd/`](plans/gdd/) — start with
`overview.md` and fill in enough of the sections it links to that somebody could build the first
playable slice from them alone. [`plans/gdd/README.md`](plans/gdd/README.md) is how to write one
that actually drives development, and the `design-doc` skill will interview you and write it.

A repo with no design document does not have a neutral absence of one. It has a design that
exists only in whoever last touched the code — and every agent working in it is guessing.

Then:

```bash
make setup      # install the pinned toolchain and the Wally packages
make plugin     # install the Rojo Studio plugin (or: make plugin-win)
make dev        # build the scratch place and start live sync
```

Then open `local.rbxlx` in Studio and connect the Rojo plugin to `localhost:34872`. Edits on
disk sync into Studio live.

`make` on its own lists every target. On Windows, `.\make.ps1 <target>` is the same set —
see [CONTRIBUTING.md](CONTRIBUTING.md#windows).

## The tree

```
src/shared/     replicated to both realms: Config, the net contract, shared rules
src/server/     Bootstrap + core/ + one folder per feature
src/client/     Bootstrap + core/ + ui/ (the UI kit) + one folder per feature
assets/         media and tracked models; uploaded and mounted, never hardcoded ids
scripts/        the test runner, the sandbox it loads modules under, the CLI helpers
```

Realm first, then feature. A file's path answers which side of the network it runs on and which
feature it belongs to before you open it. The rules that keep it that way are in
[CLAUDE.md](CLAUDE.md#the-shape-of-the-tree).

## Making it yours

1. Write [`plans/gdd/`](plans/gdd/). See above — it is step one, not step five.
2. Rename the project: `name` in `default.project.json`, `syncback.project.json` and
   `wally.toml`.
3. Point the publish workflow at your places — one GitHub environment per branch, with
   `ROBLOX_UNIVERSE_ID` / `ROBLOX_PLACE_ID` as vars and `ROBLOX_API_KEY` as a secret. The
   header of `.github/workflows/publish.yml` spells it out.
4. Build the first feature `scope.md` calls the smallest playable slice. In The Complex that is
   the combat slice (`features/combat/` and `features/enemies/`, see
   [docs/combat.md](docs/combat.md)); the template's example feature has been removed.
5. Replace `WorldBuilder` with your actual world, or delete it and mount a model under
   `assets/` instead. Today it builds the combat room from `Config.ROOM_*`.

`core/`, `ui/` and `features/telemetry/` are the template proper.

## Where to read next

- **[plans/gdd/](plans/gdd/)** — the design document. *What the game is.* Written first.
- **[CLAUDE.md](CLAUDE.md)** — how to build in this repo: the structure rules, the net contract,
  the React rules, how to verify a change. The always-loaded index, linking to the rest. Claude
  Code reads it automatically; `AGENTS.md` points opencode at the same file.
- **[docs/](docs/)** — *how it is built.* One file per involved subsystem:
  [net-contract](docs/net-contract.md), [ui-architecture](docs/ui-architecture.md),
  [telemetry](docs/telemetry.md), [testing](docs/testing.md), and
  [roblox-gotchas](docs/roblox-gotchas.md) — engine behaviour worth knowing before you hit it.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — setup, the daily loop, branches and places, editors,
  Windows.
