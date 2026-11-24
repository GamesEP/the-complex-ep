# Telemetry: reading a published server

**Roblox gives you no server log file.**

In Studio the client and the server share a process, so the output window has everything and the
client's on-disk log catches it. A published game does not work that way: the server runs on
Roblox's machines, its `print` and `warn` reach no player's log, and the only live view is F9 for
whoever happens to be standing in the game. Creator Hub keeps script *errors* — the half of the
story that raises itself. The half that costs you weeks is the faults that do not throw.

## The ring buffer

`server/features/telemetry/LogSink.luau` keeps its own buffer and writes it where an Open Cloud
key can read it. `make logs` pulls it into a terminal:

```
make logs                  # newest server
make logs ARGS="--list"    # every server key
make logs ARGS="--all"     # every server's buffer
make logs ARGS="--raw"     # JSON, for jq
```

Needs `ROBLOX_API_KEY` with `universe-datastores:read` and `ROBLOX_UNIVERSE_ID`, in the
environment or in `.env`. The publish key is `places:write` only, so it will 403 until the scope
is added.

**One DataStore key per server.** A live server owns its key outright, so a flush is a plain
`SetAsync` with no contention and no read-modify-write to lose a race in — and listing the keys
is listing the servers that faulted. Flushed on a timer, at `DIAG_FLUSH_AT` unflushed entries,
and on `BindToClose`, because a shutting-down server's final minute is the one nobody else saw.

**`GetDataStore` throws in an unpublished place**, so the sink is inert in a local Studio session
and says so once at boot. Everything still reaches the console.

**Every flush carries which build wrote it** — `environment`, `branch` and `commit`, alongside
Roblox's `PlaceVersion`. `PlaceVersion` counts publishes and maps to no source you can check out,
so on its own it cannot answer "is the fix in?"; the stamp is what ties a fault to a diff. It
comes from `shared/core/Build`, written by CI before every publish. See
[environments.md](environments.md#what-is-live).

Two things feed it:

- **`LogService.MessageOut`** — every server warning and error, whoever printed it. Nothing has
  to be ported to be captured.
- **`LogSink.record`** — a fault that wants structure: an area, a code, a count, and the fields
  that say which thing in whose session, rather than a sentence to grep later.

The buffer is bounded twice: distinct causes are counted rather than repeated, and the tail is
capped. What survives a storm is the first of each kind and the most recent lines — which is what
a post-mortem actually reads.

## Client faults

They ride the `Diagnostic` remote and land in the same buffer. It is the one remote whose payload
outlives the session, so it is validated field by field in `LogSink.onClientReport` as well as by
the contract, and **the identity is stamped server-side** — a client does not get to say who it
is. See [net-contract.md](net-contract.md).

## A silent failure path should report, not `return`

This is the rule the whole subsystem exists for.

Most of what breaks on a client does not throw. A resource the memory budget refused comes back
as a plain `nil`. A model that never finished replicating renders as whatever was underneath. A
request that could not be served draws nothing. Each of those is naturally written as an early
`return` — correct behaviour, and completely invisible. The feature is broken for the session, on
that one client, while every other client is fine, and nothing anywhere says so.

`client/core/Diagnostics.luau` is where those go:

```lua
Diagnostics.fault("world", "chunk-missing", "the model never finished assembling", {
    model = model.Name, waited = elapsed,
})
```

| | |
|---|---|
| `area` | Which pipeline — `"world"`, `"ui"`, `"net"` |
| `code` | How it went wrong. Kebab-case and **stable**, because it is what you grep for |
| `detail` | A sentence saying what was true, in the terms of the thing that broke |
| `fields` | The identifying values: instance, index, size, player, request |

**The warning curve is the point.** One warning per session is what hid a memory ceiling for
months; sixty a second is what makes a console useless. So the console line comes on the
occurrence counts in `Config.DIAG_REPEAT_STEPS` and periodically after them, always carrying the
running total — and counts batch to the server every few seconds as *distinct causes*, not
occurrences. A storm is one message with a big number in it.

Cheap enough to call from a per-frame path: the work is a table lookup and an increment, and
everything expensive is on the curve or on the flush.

**Never report a reporting failure through the reporting channel.** That is a loop, not a
diagnostic — the flush failure warns directly.

## Where the counters and the reports must agree

If a module keeps its own `stats()` of what went wrong, a path that counts without reporting is a
fault that is either uncounted or unsaid. Worth an assertion in the offline suite that the two
views cannot drift.
