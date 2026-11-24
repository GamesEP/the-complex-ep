# Agent instructions

**The guide is [CLAUDE.md](CLAUDE.md). Read it before changing anything in `src/`.**

It is one file rather than two on purpose. This repo used to carry `AGENTS.md` and `CLAUDE.md`
as near-identical copies, and they had already drifted apart by the time anybody noticed — so
the content lives in one place and every tool is pointed at it:

- **Claude Code** reads `CLAUDE.md` directly.
- **opencode** reads this file, and `opencode.json` additionally lists `CLAUDE.md` under
  `instructions`, so it is loaded either way.
- Anything else: read `CLAUDE.md`.

A symlink would have been tidier and is deliberately not used — git checks symlinks out as
plain text files containing the target's path on Windows without `core.symlinks`, which would
hand a Windows contributor's agent the string "CLAUDE.md" as its entire instruction set.

## The short version

- **Check `plans/gdd/` first.** It is the design document, and it is what features are built
  from. If it does not describe what you have been asked to build, ask rather than guess — the
  `design-doc` skill interviews the user and writes it.
- Structure is realm first, then feature: `src/<realm>/features/<feature>/`. Bootstraps are
  wiring only; a feature never requires another feature by path.
- Every client→server remote needs a line in `shared/core/Net/Contract.luau` or the server
  refuses to connect it.
- Tunables live in `src/shared/core/Config/`, never inline in logic.
- `make check` before claiming something works. If only Studio can confirm it, say so.
- **Three homes for a fact**: `plans/gdd/` for what the game is, `docs/` for how a subsystem
  works, a comment for why *this line* is the way it is. Docs change in the same commit as the
  feature; comments link to the docs rather than repeating them, so no thirty-line blocks.
- **`Makefile` and `make.ps1` stay in step.** A target changed in one is changed in the other,
  in the same commit — a Windows contributor's green run has to mean what CI's means.

## Skills

| | |
|---|---|
| `design-doc` | Interview the user and write `plans/gdd/`. The first thing a new game does. |
| `doc-drift` | Check `docs/` and `plans/gdd/` against the code, and report what disagrees. |
