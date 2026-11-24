# Environments: two experiences, one repo

**Roblox has no staging slot.** There is no "publish to test" button, no deployment page, and
nothing that isolates a test run from live player data. The only isolation boundary the platform
offers is the *universe*, so an environment here is a universe, and "development" and
"production" are two experiences publishing the same source.

This file is why that is the shape, what it costs, and what closes the gaps it leaves.

## Experience, universe, place

Three words, and getting them the wrong way round leads to a design that cannot work:

| | |
|---|---|
| **Experience** / **universe** | The isolation boundary. DataStores, MemoryStore, badges, passes, developer products, analytics and the server list are all scoped to one. |
| **Place** | A level inside a universe. Places in one universe **share all of the above**. |

So "one experience with a dev place and a live place" is not an option. The moment the dev place
writes a player profile it writes to the *live* profile, because the DataStore belongs to the
universe, not the place. Places are for teleport destinations — a lobby, an arena — not for
environments.

Two universes is the community's answer to a platform gap, not an accident of this template.

## The promotion path

| Branch | Publishes to | Meaning |
|---|---|---|
| feature branches | nothing | CI builds and tests only |
| `staging` | the develop universe | what is being tested |
| `main` | the production universe | what players are in |

`.github/workflows/publish.yml` does it on push, one GitHub environment per branch. Merge up
rather than publishing across: only `staging` uploads assets, and `main` checks that no asset id
is missing, so a change that skipped `staging` fails rather than shipping with silent media.

**Tier zero is `make dev`.** Rojo into Studio absorbs most iterations and costs nothing. The dev
universe is for what Studio genuinely cannot show you: replication timing across real clients,
mobile, several players at once, real DataStore behaviour. Publishing to check something Play
Solo would have answered in three seconds is the default drift, and it is worth resisting.

## Registering a universe

`src/shared/core/Config/Environments.luau` maps `game.GameId` to an environment name:

```lua
Config.ENV_UNIVERSES = {
	[1234567890] = Config.ENV_PRODUCTION,
	[9876543210] = Config.ENV_DEVELOPMENT,
}
```

The **universe** id, not the place id — the universe is what owns the data. Find it on the
experience's Creator Hub page, or print `game.GameId` from a published server.

`shared/core/Environment.luau` resolves it. Three rules are load-bearing:

- **Resolved from `game.GameId` at runtime, never baked in by the build.** The same commit
  publishes to both places by merging up, so a constant written at build time would be right in
  one universe and quietly wrong in the other — and `git diff main..staging` would show config
  drift on top of the work that has not shipped. One artifact, one lookup.
- **Studio wins over the table.** Studio is not a universe; it runs against whatever place file
  is open, which may be a scratch build of production. There is no boundary to hold there anyway
  — somebody with the place open already has everything.
- **An unregistered universe is treated as production**, and `Environment.selfTest` fails if
  that default is changed. The two directions are not symmetric. Guessing "development" hands
  admin and every dev-only guard to a universe nobody registered — which, for a freshly cloned
  template with an empty table, is the real production universe. Guessing "production" costs a
  wrong monetization id, which fails loudly and harms nobody. It is still a misconfiguration, so
  `LogSink` records one `environment/unregistered-universe` fault where `make logs` will find it.

### What must be environment-scoped

**Every monetization and badge id.** Roblox scopes passes, developer products and badges to a
universe, so the same source has two sets of them. A number written next to the code that spends
it is correct in one universe and wrong in the other, and nothing offline can tell.

```lua
local Environment = require(Shared.core.Environment)

local pass = Environment.id("GAMEPASS_VIP")   -- 0 when this environment has no such id
```

Filed under `Config.ENV_IDS`, one row per environment. `Environment.id` answers `0` for anything
absent — the same "not set up yet" convention `Assets.id` uses, so a fresh clone is inert rather
than broken, and a caller that spends an id checks for `0` the way it checks an asset id. Studio
borrows development's row, because purchases in Studio are simulated and free.

**Anything gated on being a developer.** Write the guard against the environment, not against
`RunService:IsStudio()`. They are the same test today and stop being the same the moment somebody
wants a universe where the team has admin; written this way, that change is one row in `Config`
rather than a grep. The server bootstrap has the only copy:

```lua
local function isAdmin(player: Player): boolean
	return Environment.isStudio() or table.find(Config.ADMIN_USER_IDS, player.UserId) ~= nil
end
```

`Environment.isProduction()` is the guard for anything dangerous, written that way round on
purpose: a fourth environment nobody thought about is locked down by default.

## What is live

Roblox will not tell you. A place carries a `PlaceVersion`, which counts publishes and maps to no
commit you can check out. There is no deployment page. So three things close the loop, and they
only work together:

**1. The build stamp.** `scripts/stamp-build.sh` writes the commit, branch and build time into
`src/shared/core/Build/BuildInfo.json`, and CI runs it immediately before `rojo upload` — after
the asset-id commit, because a stamp is a property of a build and must never land in a commit.
`Build.label()` reads back as `main 290a9c8`.

It is committed as an `unknown` placeholder so a fresh clone builds. `make stamp` fills it in
locally, for reproducing something a published server reported; put it back with
`git checkout src/shared/core/Build/BuildInfo.json` before committing.

**2. The stamp in the logs.** Every `LogSink` flush carries `environment`, `branch` and `commit`
alongside the `PlaceVersion`, and `make logs` prints them. That is what ties a fault to a diff.

**3. The stamp on screen.** `client/features/environment/ui/BuildStamp` puts the environment and
the commit in the corner of every **non-production** client. The two experiences look identical
from the inside; without it, "the fix did nothing" and "you were in the other universe" are the
same screenshot, and a bug report from the dev experience gets triaged as a production incident.
The client bootstrap is what decides it is not mounted in production — a watermark that can
decide that for itself is one bad boolean away from being visible to players.

### Release tags

A successful publish from `main` tags the commit `release/<date>-<short sha>`, annotated with the
place and universe it went to. Rolling back on Roblox means publishing an older commit, which you
cannot do without knowing which one was good, and `git tag` is the only durable record of that —
Roblox's version history offers a number that names no source.

Re-publishing the same commit is the same release, so an existing tag is a notice rather than a
failure. `staging` is not tagged: it republishes constantly and a tag per push would bury the
releases. The build stamp is how a dev server says which commit it is.

## Feature flags

A second universe proves a feature is *correct*. It can never prove it holds at forty players, on
the real device mix, against real DataStore throughput, or against real exploiters — a private QA
experience with four people in it structurally cannot. Flags are what make that acceptable: the
untested half ships anyway, dark, and goes off again in under a minute when it does not hold.

This is the part that scales better than adding a third environment.

Two files, split along the line the rest of the repo is split on:

| | |
|---|---|
| `shared/core/Flags.luau` | The rule. Pure, no service, asserted by `make test ONLY=core`. |
| `server/features/flags/FlagService.luau` | The live half: reads the overrides, publishes the answers. |

### Declaring one

```lua
-- src/shared/core/Config/Flags.luau
Config.FLAGS = {
	NEW_SHOP = {
		default = {
			[Environments.ENV_PRODUCTION] = false,
			[Environments.ENV_DEVELOPMENT] = true,
		},
		staff = true,   -- on for Config.ADMIN_USER_IDS regardless of the default
		rollout = 0,    -- percent of everybody else, 0..100
	},
}
```

A flag name becomes an attribute name, so it is `[A-Z][A-Z0-9_]*`; the self test says so rather
than letting `SetAttribute` throw at the first player to join.

### Reading one

On the server, where the decision is made:

```lua
if FlagService.enabled("NEW_SHOP", player) then
```

Resolved from the catalogue and the overrides rather than read back off the attribute, so server
code never depends on whether the write has landed. In a component:

```lua
local Flags = require(Shared.core.Flags)

local newShop = hooks.useAttribute(player, Flags.attribute("NEW_SHOP")) == true
```

**Flags reach the client as attributes on the player** — no remote, nothing in the contract, and
so nothing to get out of sync. Compared against `true` rather than coerced: the attribute is nil
in the window between joining and the server resolving, and "not yet known" and "off" are the
same answer on purpose. A feature that is not known to be on is off.

### The switch

Overrides live in the `Flags` DataStore under one key, `overrides`, as a flat
`{ [name] = boolean }`. Write it with Open Cloud or from a Studio command bar against the
published universe; every live server picks it up within `FLAG_REFRESH_SECONDS` (60) and
re-publishes every player's flags without a republish and without kicking anybody.

**Resolution order is override, staff, rollout, default — and the override beats staff.** A kill
switch that leaves the feature running for the people handling the incident is not a kill switch,
and 3am is not when anybody should be deriving the precedence from the code. `Flags.selfTest`
asserts it.

A failed DataStore read keeps the last good table rather than falling back to the defaults: a
blip must not quietly re-enable the thing somebody just turned off.

### Rollout buckets

`Flags.bucket(name, userId)` is a stable hash, 0..99. Stable matters: a random draw per server
would put the same player on both sides of a feature depending on which server they joined, which
is how you get a bug report nobody can reproduce. Raising a rollout only ever adds people.

The flag name is in the hash, so two flags at 10% do not pick the *same* 10% — one unlucky cohort
getting every experiment at once is bad for them and useless as a signal.

**Delete a flag once the feature is on everywhere.** A flag that has been true in production for a
month is a branch nothing exercises the other side of.

## What the repo does not own

Place-level properties are in `default.project.json` and are identical in both universes by
construction. **Universe and place *settings* are not.** They live only in the Creator Hub
dashboard, per universe, and nothing here can see them — so they drift, and a test passes in a
configuration production does not have.

Check these against each other when something behaves differently in one universe:

- **Privacy.** The dev experience is **Private**. A public second experience splits your player
  count, can put a broken build in front of real players, and fills your analytics with numbers
  that mean nothing.
- **Server size**, and whether the dev universe can even reach the player count being tested.
- **Avatar settings** — the rig type, scaling and collision your character controller assumes.
- **Monetization**: the passes and products themselves, which are per universe and are the
  reason `ENV_IDS` exists.
- **Moderation and chat settings**, and the age rating, which changes what the chat filter does.
- **API access to DataStores** (Studio only) — off means `LogSink` and `FlagService` are inert
  and say so once at boot.

## What a dev universe cannot buy you

Worth being blunt about, because the temptation is to keep making the dev universe more realistic
instead of investing where the risk actually is:

- **Scale.** Real concurrency, real DataStore throughput (quota scales with player count), real
  network conditions, the real device mix, real exploiters. None of it reproduces with four
  people in a private server.
- **A data migration against real data.** The universes have separate DataStores, which is the
  point and also the limit. Copying a handful of real profiles into the dev universe through the
  Open Cloud DataStore API is the way to test one — the same key family `make logs` already uses.

The ceiling on "manage this better" is not a third environment. It is fast rollback plus enough
telemetry to know you need it — the release tag, the build stamp, `make logs`, and a flag you can
flip in under a minute.

## Adding an environment

A fourth (a soak universe, a per-team sandbox) is a name and a row:

1. A name constant in `Config/Environments.luau`, its `game.GameId` in `ENV_UNIVERSES`, and a row
   in `ENV_IDS`. `Environment.selfTest` fails if the last of those is missing.
2. A `default` entry per flag that should be on there. A flag says nothing about an environment
   it does not name, and that reads as off — a new environment must not inherit a feature by
   accident.
3. A GitHub environment named after the branch that publishes to it, with its own
   `ROBLOX_UNIVERSE_ID` and `ROBLOX_PLACE_ID`, and the branch added to `publish.yml`'s trigger.

Worth waiting for. Two environments is right until `staging` is permanently occupied by somebody
else's half-finished work.
