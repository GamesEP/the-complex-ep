# Contributing

## The one thing to understand first

**The repository is the game. A `.rbxl` file is a build output.**

Studio is not where the project lives — it is a viewer and a physics sandbox attached to it.
Rojo syncs files from disk *into* Studio, one direction, continuously. Nothing you type into
Studio's script editor reaches the repo, and anything you build in the Workspace survives only
if it is either a tracked model under `assets/` or something server code rebuilds on boot.

Two consequences worth having in muscle memory:

- `local.rbxlx` is disposable. Delete it and run `make place` any time it looks wrong.
- If a change did not come from a file, it is not a change.

## Before the first line of code

Write the design document. [`plans/gdd/`](plans/gdd/) is the first thing a team using this
template does, and [`plans/gdd/README.md`](plans/gdd/README.md) is how to write one that drives
development rather than one nobody re-reads. The short version: decisions rather than
aspirations, every number naming its `Config` key, every system naming its feature folder, and
open questions marked rather than guessed.

It is a good thing to draft with an agent and a bad thing to let one invent — the `design-doc`
skill interviews you and writes down your answers, flagging anything it filled in itself.

## First-time setup

```bash
make setup      # installs the toolchain pinned in rokit.toml, then the Wally packages
make plugin     # Linux/Vinegar. On Windows or macOS: make plugin-win
make lsp-defs   # once per machine — the Roblox type definitions luau-lsp needs
```

`make setup` will tell you how to install [rokit](https://github.com/rojo-rbx/rokit) if you do
not have it. Everything else — rojo, lune, luau-lsp, stylua, wally — is pinned in `rokit.toml`
and installed by that one command, so your versions match CI's exactly.

### Why there are two plugin targets

`rojo plugin install` writes into Studio's plugin folder, which it finds through the platform's
standard location. Under Linux that folder is inside a Wine prefix, and rojo does not know to
look there, so `scripts/install-plugin.sh` puts the same `.rbxm` in the right place for a
Vinegar install. Both install the same plugin from the same pinned rojo version.

## Daily loop

```bash
make dev        # build the scratch place, then serve it
```

Open `local.rbxlx` in Studio, connect the plugin to `localhost:34872`, and leave `make dev`
running. Edit files; they appear in Studio within a frame.

Before you push:

```bash
make check      # the offline suites, the undefined-globals gate, and a real build
```

That is exactly what CI runs. `make style` formats; `make style-check` reports without writing.

### Testing while you iterate

```bash
make test-list          # what suites exist
make test ONLY=ui       # just one
```

`make test` never needs Studio and takes under a second. It is the right thing to run on every
save. It cannot tell you whether the game *feels* right, and it cannot touch an instance — see
[CLAUDE.md](CLAUDE.md#verifying-a-change) for what does and does not belong in it, and for the
Studio verification steps that catch the rest.

## Branches and places

| Branch | Publishes to | Meaning |
|---|---|---|
| feature branches | nothing | CI builds and tests only |
| `staging` | the develop place | what is being tested |
| `main` | the production place | what players are in |

Two experiences, because a universe is the only thing Roblox isolates DataStores, passes and
badges by — there is no staging slot. **[docs/environments.md](docs/environments.md)** is why
that is the shape, how a universe is registered, how to tell which build is live, and how the
feature flags work.

Publishing is automatic on push, through `.github/workflows/publish.yml`. Its header lists the
per-environment secrets and vars to set. A publish from `main` also tags the commit
`release/<date>-<sha>`, which is the only durable record of what is live: rolling back means
publishing an older commit, and Roblox's own version history names no source. Assets are uploaded on the way to `staging` and the
resulting ids are committed back, so adding a sound is: drop the file in `assets/`, commit,
push. `main` only checks that no id is missing — merge up rather than publishing across.

Publishing by hand (`make upload`) exists for emergencies and prompts before it fires.

## Working on the world, not just code

Anything in the Workspace is one of two things, and they have opposite rules:

**A tracked model** under `assets/`, mounted by `default.project.json`. Edit it in Studio, save
the place, then pull it back:

```bash
# in Studio: stop Play, make your change, then File → Save (writes local.rbxlx)
make syncback-dry     # see what it would change
make syncback         # write it, then review: git diff assets/
```

`syncback.project.json` lists only what Studio is allowed to write back, and deliberately omits
`src/` — a syncback run can never rewrite a script.

**Built from code**, like `features/world/WorldBuilder`. Do not edit these in Studio: the
builder destroys and rebuilds on every server start, so a wall you moved is gone the moment you
press Play. Change the builder.

### Media

Drop the file in `assets/` and reference it by name:

```lua
local Assets = require(Shared.core.Assets)
sound.SoundId = `rbxassetid://{Assets.id("click.ogg")}`
```

`make sync-assets` uploads anything Roblox does not have and records the id (needs
`ROBLOX_API_KEY` with the `assets:write` scope); `make check-assets` reports without uploading.
A file nobody has uploaded yet answers `0`, which every caller should treat as "no media" — a
fresh clone is silent rather than broken.

### Do not use Team Create

Team Create edits a place, and the place is a build output. Anything two people do in one at the
same time is lost on the next `make place`. Collaborate through branches.

## Editor setup

The language server needs two things: the Roblox type definitions (`make lsp-defs`, once) and a
current `sourcemap.json`, which is how it resolves a `require` to a file. Regenerate it whenever
you add or rename a module:

```bash
make sourcemap          # once
make watch-sourcemap    # or keep it current
```

**Neovim** — `.nvim.lua` in the repo root wires up luau-lsp, stylua and the sourcemap refresh,
scoped to this project. Neovim reads it only with `vim.o.exrc = true`, and only after you trust
the file once.

**VS Code** — install the `luau-lsp` extension. `.luarc.json` already points it at the project
and turns on sourcemap autogeneration.

Formatting is StyLua, configured by `stylua.toml` at the repo root. StyLua searches upward from
the file it is formatting, so the repo's settings win over whatever is in your home directory —
which matters, because the common personal setup would rewrite every line on first save.

## Documentation

Three places, and a fact belongs in exactly one:

| | |
|---|---|
| [`plans/gdd/`](plans/gdd/) | **What the game is.** Changed when the design changes. |
| [`docs/`](docs/) | **How a subsystem works.** Changed when the implementation changes. |
| A code comment | **Why this line is the way it is**, and what breaks if it changes. |

**A doc changes in the same commit as the feature it describes.** These are load-bearing —
agents read `docs/<subsystem>.md` before touching a subsystem, and so does anybody coming back
to one after a month. One stale file is enough for people to stop trusting all of them.

**Comments link to the docs rather than repeating them.** A thirty-line block above a module goes
unread at the moment it matters, drifts from the code beneath it, and cannot be linked to — so
the same paragraph gets written again in the next module that needs it. Keep the reason at the
line; put the argument in `docs/` and point at it.

The `doc-drift` skill audits all of this against the code: GDD numbers against `Config`, doc
paths against the tree, subsystems with no doc. Worth running before a release.

## Windows

Everything works, with two accommodations:

- **`.\make.ps1 <target>`** is a port of the Makefile with the same targets and the same
  `KEY=VALUE` overrides: `.\make.ps1 test ONLY=ui`, `.\make.ps1 serve PORT=34873`. The targets
  backed by shell scripts (`lsp-defs`, `sync-assets`, `logs`) run those same scripts through Git
  Bash, so there is one implementation and CI calls it directly.

  **A target added, renamed or changed in one belongs in the other in the same commit** — and so
  does a changed flag or default. They are two ports of one thing, and the drift is quiet: a
  Windows contributor runs `.\make.ps1 check`, gets a green run, and it means something weaker
  than CI's. `make.ps1` keeps its help table and its switch in step by construction, so adding a
  target there means adding both halves.
- **Line endings are LF everywhere**, enforced by `.gitattributes`. Without it StyLua rewrites
  the tree on your first save and the shell scripts fail in Git Bash with `bad interpreter:
  /bin/bash^M`. `.ps1` files are the one exception and check out CRLF.

`sync-assets` needs a working `python3` inside Git Bash — the Microsoft Store alias stub does
not count.

## Agents

Both Claude Code and opencode are configured in the repo:

- `CLAUDE.md` is the guide, loaded by Claude Code automatically. `AGENTS.md` points opencode at
  the same file, and `opencode.json` lists it under `instructions` so it is loaded either way.
  **One file, so the two cannot drift.**
- `.mcp.json` and `opencode.json` both start the Studio MCP server through
  `scripts/studio-mcp.mjs`, which finds Studio on Windows and on Linux/Vinegar.
- `.claude/settings.json` and `opencode.json` carry a permission split: read-only Studio and
  build commands are pre-allowed, anything that publishes, uploads, writes back, or presses
  Play asks first.
- Skills live in `.claude/skills/`, which `opencode.json` also lists under `skills.paths` — one
  copy, both tools. Two ship with the template:

  | | |
  |---|---|
  | `design-doc` | Interviews you and writes `plans/gdd/` |
  | `doc-drift` | Checks `docs/` and `plans/gdd/` against the code |

If you change the structure rules, change `CLAUDE.md` in the same commit. It is the file
everything else — human and agent — is working from.

## Commands

`make` with no target lists everything. The ones worth knowing by heart:

| | |
|---|---|
| `make dev` | build the scratch place and start live sync |
| `make check` | what CI runs: suites, the globals gate, a real build |
| `make test ONLY=x` | one suite, in milliseconds |
| `make style` | format |
| `make logs` | read a published server's diagnostics buffer |
| `make stamp` | write the current commit into the place, so a session says which build it is |
| `make clean` | delete build outputs and scratch places |
