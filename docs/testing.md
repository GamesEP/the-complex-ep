# Verifying a change

Two halves, and knowing which half a thing belongs in is most of the skill.

`make test` runs everything that can be checked without Studio, in under a second. It cannot
touch an instance, step physics, or render a frame — so the other half is running the game, and
that half has its own traps.

---

## The offline suites

```
make test              # everything
make test ONLY=ui      # one suite
make test-list         # what suites exist — asked of the runner, so it cannot go stale
make check             # the suites, the globals gate, and a real build. What CI runs.
```

`scripts/run-tests.luau` is one entry point rather than one script per check, so CI, the publish
workflow and `make test` all call the same command and a new suite reaches all three by being
added to `SUITES`.

| Suite | What it does |
|---|---|
| `syntax` | Compiles every `.luau` under `src/` and `scripts/` |
| `shared` | Runs `selfTest` on every pure module under `shared/features/` |
| `core` | Runs `selfTest` on every pure module at the top of `shared/core/` |
| `layout` | `ScreenMetrics.selfTest` — the scale thresholds |
| `ui` | Runs `selfTest` on every store under `client/features/*/stores/` |

Three of those discover their subjects by walking the tree. A new shared rule, a new piece of
core vocabulary or a new store is tested by existing, with nothing to register.

`core` walks **top-level files only**, and that boundary is the point rather than an accident:
everything else in `core/` is a folder, and the folders are the parts that reach for a service.
`Net/Remotes` creates a RemoteEvent at require time and cannot load offline at all. A module that
belongs in this suite is one with nothing to stub.

### The sandbox

`scripts/lib/sandbox.luau` hands a Lune chunk everything a Roblox module takes for granted:
`luau.load` starts from an empty environment, so the standard library, the Roblox datatypes and
stubs for `game`/`workspace`/`require` are all supplied explicitly.

The datatypes are the real ones from `@lune/roblox`, so a CFrame computed offline is the CFrame a
server would compute. What is *not* real is anything with runtime behaviour: no signals fire, no
instance replicates, no service answers.

**`Sandbox.service` is an object that errors on any access, naming the member that reached for
it.** That is the enforcement behind the rule below — a module that grows a service dependency
fails here with the line that did it, rather than quietly testing something else.

Charm is loaded with `strict` and `frozen` turned on deliberately (they default to `isStudio()`,
and there is no `game` offline). They catch a yielding effect and an in-place mutation of a table
inside an atom — the two failures hardest to reproduce by pressing Play, and microseconds to
catch here.

### The rule for adding a suite

**If it needs a service, it does not belong here.** That is the same rule as writing a `selfTest`
at all, and it is worth taking seriously rather than working around: a test that stubs enough to
run is a test of the stubs.

What that means in practice is *extract the decision*. A rule that is `(inputs) -> outcome` with
no service in the middle can be a shared module with a `selfTest`. The candidates worth the
effort:

- **Orderings.** "A message arrived about an object that has already been replaced." "An effect
  fired before its screen mounted." These need two clients and a stopwatch to reproduce by hand
  and are three lines of assertion offline.
- **Thresholds.** A layout breakpoint is cheap to assert and expensive to see on a device.
- **Branch order.** Which of two "this is over" conditions wins when both apply — nothing else
  pins that, and getting it wrong is a rare, confusing, correct-looking bug.
- **Nonsense inputs.** The two values a remote can produce that should never reach a function.
  Neither should happen, both are one typo away.

Pure modules also run their own `selfTest` on start in Studio, which is the moment somebody is
about to find out they broke it.

---

## `make globals`

**The one gate that reads names rather than shapes**, and the one class of error nothing else
catches.

The syntax pass compiles, so it does not resolve `require`s and knows none of Roblox's globals.
`rojo build` packs source without reading it at all. So a require through a name nobody bound —
`require(Shared.features.…)` in a module that never declared `Shared` — builds clean, passes
every suite, and then throws on the first frame of a real server, taking that whole realm's
bootstrap with it.

`make globals` runs `luau-lsp analyze` and fails on `Unknown global` alone. It is deliberately
narrower than `make analyze`, which cannot gate: a growing codebase accumulates type findings
nobody intends to fix, and the moment a gate fails for something nobody will fix, it stops being
run. An undefined global is never one of those.

It also catches the subtler half of the same class: **a `local` read a few lines above its own
declaration is the global of that name**, so it is silently `nil` rather than an error. That is
how a feature ends up sitting behind a condition that can never be true.

Needs `make lsp-defs` once per machine.

---

## In Studio

Everything above is a small fraction of what can break. Anything touching an instance, physics,
replication, or a frame is verified by running the game.

### The sync trap, in this exact order

1. Edit files.
2. `start_stop_play(false)` — stop any running session.
3. **Confirm the Edit datamodel actually has the change**: `script_grep`, or read `.Source` on
   the synced script with `datamodel_type: "Edit"`.
4. `start_stop_play(true)`.

Rojo syncs into the Edit datamodel, and pressing Play clones it at that instant. Starting Play
right after an edit routinely runs the *previous* version, and the resulting "the fix did
nothing" wastes a whole debugging cycle. Skipping step 3 is the most reliable way to lose an hour
in this repo.

### The MCP Luau VM is separate from the game's

`require` there returns a fresh copy of a module, so reading module state — a cached table, an
`isBlocked()` — tells you nothing about the running game.

**It also caches across calls.** Require a module, edit it, let Rojo sync, require it again in a
later call, and you still get the *first* table, with none of your new fields — so anything
reading them fails on nil. `.Source` on the synced ModuleScript is current even when the required
table is not, which is how you tell a sync problem from a cache one.

Verify through instances and physics instead: part positions, velocities, attributes, pixel
buffers. To check a computed value, do the arithmetic inline from live instances rather than
requiring the module that holds it.

### Synthetic input does not reach `UserInputService`

Keyboard events and 3D-view mouse clicks driven over the MCP produce zero
`InputBegan`/`JumpRequest`, so keybinds and drags cannot be tested end to end. GUI button clicks
by `instance_path` *do* work, because they run in the game's VM. For everything else, call the
same code path directly — build the ray, fire the remote — and check the effect.

### Measure, don't eyeball

A screenshot proves very little on its own. Read the numbers — part positions, attribute values,
`AbsoluteSize`, pixel buffers — and report counts and coordinates. And watch which channel you
sample: a red mark leaves the red channel at 255, so checking red finds nothing.

### Pin anything that respawns

A round loop that respawns on a timer blanks state mid-test. Pin it from the **Server**
datamodel — a client-side attribute write does not replicate.

---

## `[ERROR rojo] description() is deprecated; use Display`

Means inotify is exhausted, not that anything is wrong with the project. Rojo builds a
watcher-backed VFS before it reads a single file, and when the kernel refuses another inotify
instance the real error is swallowed by that deprecation message. `make check` fails, `-vvv` adds
nothing, and the last line is `Constructing in-memory filesystem`.

```bash
find /proc/*/fd -lname anon_inode:inotify 2>/dev/null | wc -l
```

against `/proc/sys/fs/inotify/max_user_instances`. One orphaned language server can hold half of
them — kill the stale ones instead of debugging the build.
