# docs/

How the involved parts of this codebase work. One file per subsystem, each explaining the
decisions and the failures behind them — the long-form half of what would otherwise be a
thirty-line comment block at the top of a module.

| | |
|---|---|
| [combat.md](combat.md) | The player's kit, the enemies and the waves — and who decides what |
| [net-contract.md](net-contract.md) | How a client talks to the server, and why every remote is declared |
| [ui-architecture.md](ui-architecture.md) | Screens, scaling, stores, hooks — and the rules that are not style choices |
| [telemetry.md](telemetry.md) | Reading a published server, and why silent failures must report |
| [environments.md](environments.md) | Two experiences, what is live in each, and feature flags |
| [testing.md](testing.md) | What can be checked without Studio, and what cannot |
| [roblox-gotchas.md](roblox-gotchas.md) | Engine behaviour that has already cost somebody a day |

Design lives elsewhere: [`plans/gdd/`](../plans/gdd/) is *what the game is*, this folder is
*how it is built*. A change to what a player experiences touches the GDD; a change to how it is
implemented touches these.

## Two rules

**A doc and its feature change in the same commit.** These are load-bearing — agents read them
before working on a subsystem, and so does anybody returning to one after a month. One stale
file is enough for people to stop trusting all of them. If a PR changes how a subsystem works,
it changes that subsystem's doc; if the subsystem is new and involved enough to need one, the
PR adds it.

**Code comments reference these, they do not duplicate them.** A comment in a module says the
one thing you need to know *at that line* — usually what breaks if it changes — and links here
for the rest:

```lua
-- The root's container is the ScreenGui itself, never a Folder: a Folder has no ResetOnSpawn,
-- so the respawn reset takes the ScreenGui inside it with it. See docs/ui-architecture.md.
```

Not a thirty-line essay above every module. A long block goes unread at exactly the moment it
matters, drifts from the code beneath it, and cannot be linked to from anywhere else — the same
paragraph then gets written again in the next module that needs it.

Keep the reason in the code. Move the argument here.
