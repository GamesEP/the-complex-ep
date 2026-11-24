# The net contract

Every client→server remote in this game is declared in `src/shared/core/Net/Contract.luau`, and
`src/server/core/Net/Dispatcher.luau` is the only thing that connects one. **The Dispatcher
errors on a remote with no contract entry**, so adding a remote means adding its contract line
or the server does not wire it.

## Why it is built this way

The failure being prevented is invisible. A remote without a rate limit works perfectly in
Studio, works perfectly in a playtest, and is the lever an exploiter pulls — a client looping it
at frame rate, and every one of those calls doing whatever the handler does, including writing
to a DataStore. Nothing about the game looks wrong until it is.

Every mitigation that relies on remembering fails eventually. Making the limit a *precondition
of connecting at all* turns "we forgot" into "it does not start", which is the only version of
this that survives a year of new features.

## The declaration

```lua
Score = { rate = Config.ACTION_RATE, args = { Validate.number } },
```

| Field | Meaning |
|---|---|
| `rate` | Calls per second through the shared meter, or `"custom"` when the handler meters itself |
| `role` | The only role the remote means anything from |
| `phase` | `"playing"` or `"inRound"`, checked against whatever `Dispatcher.init` was handed |
| `admin` | Studio, or a user id in `Config.ADMIN_USER_IDS` |
| `args` | Positional guards from `Validate` — extra arguments ignored, bad ones drop the call |

`rate = "custom"` is not an escape hatch, it is the honest answer for anything fired from a drag
or a held trigger: a flat per-second number cannot describe a burst, and pretending it can
produces a limit that is either useless or in the way. The handler then owns a real budget — a
token bucket, a cooldown clock — and the contract records that it does.

## What the contract checks, and what it does not

`args` is a **shape** check. Types, and the family of nonsense a client can put on the wire:
wrong types, NaN, infinities. `Validate.number` rejects NaN and both infinities, because NaN
survives most arithmetic and an infinity survives `.Unit` as a NaN and gets broadcast to every
client.

What it deliberately does not check is what a value *means*. Whether a string names a real
catalogue item, whether a number is in range for this player right now, whether they can afford
it — that is the handler's, because the handler is the only thing that knows. Range checks in
the contract mean editing the contract every time a feature's rules change, and a contract that
is edited constantly is one nobody reads.

So: the contract guarantees the handler is called with the right *kinds* of thing, or not called
at all. Everything past that is the feature's own judgment.

## Refusals

Silent to the sender, counted by `core/Net/Telemetry`. A cheat learns nothing from being told
which check said no, and a legitimate client that trips a limit is a client one frame out of
date — neither wants an error dialog. The first refusal of each kind gets a warning line; the
ten-thousandth gets its count, printed when the player leaves.

## Remotes versus replicated state

**A remote is for events. An attribute is for state.**

A remote says *something happened* — a button was pressed, a shot was fired. It has no current
value, so there is nothing to read back and nothing to get out of sync.

State the client displays should be an attribute on the player or on an instance. It replicates
on its own, needs no "send me the current value" remote, survives a client joining late, and
reaches *every* client rather than the one that asked. `hooks.useAttribute` turns one into React
state in a line. The `Dash` and `Spin` remotes answer by writing `DashReadyAt` / `SpinReadyAt`
attributes rather than replying to the client who fired them — that is the pattern to copy (see
[combat.md](combat.md)).

Getting this backwards produces the bug that is hardest to find: two sources of truth for one
value, agreeing in every test and disagreeing on a slow connection.

A server→client broadcast needs no contract entry. The contract is about what a *client* is
allowed to send.

## Adding a remote

1. A line in `shared/core/Net/Remotes.luau` — the name, created by the server, waited for by the
   client.
2. A line in `shared/core/Net/Contract.luau` — rate, and whatever else applies.
3. A `Dispatcher.connect("Name", Handler.fn)` in the server bootstrap.

Miss the second and the third throws at boot, by design.

## The client report channel

`Diagnostic` is the one remote whose payload outlives the session — it ends in a DataStore. So
it is validated twice: once here as a table, and once field by field in `LogSink.onClientReport`.
A channel a client can write to persistent storage through is one an exploiter will try to fill,
and the identity on a report is stamped server-side rather than taken from the payload. See
[telemetry.md](telemetry.md).
