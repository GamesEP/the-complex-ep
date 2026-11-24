---
name: doc-drift
description: Check the documentation against the code for drift — docs/ describing behaviour that changed, plans/gdd/ numbers that no longer match Config, stale file paths, undocumented subsystems. Use when the user asks to check, audit, or update the docs, before a release, or after a large refactor.
---

# Finding drift between the docs and the code

Documentation in this repo is load-bearing: agents read `docs/` before working on a subsystem,
and `plans/gdd/` is what features are built from. **One stale file is enough for people to stop
trusting all of them**, so drift is a defect, not untidiness.

Report what you find. Do not fix silently — some drift means the *code* is wrong, and that is the
user's call.

## What to check

Work through these in order. Each is a different kind of drift and they are found different ways.

### 1. GDD numbers against Config

`plans/gdd/` states numbers with their key: `180 seconds (`Config.ROUND_SECONDS`)`. Two failures:

- **A stated number that no longer matches the key's value in `src/shared/core/Config/`.** Report
  both values. This is the most common drift and the most quietly damaging — somebody tunes a
  number in code and the design document keeps claiming the old one.
- **A named key that does not exist.** Either it was renamed, or it was never written.

Also the reverse sweep: **a `Config` key that no GDD section names.** Not always drift — plenty
of keys are implementation detail — but a *gameplay* tunable nobody documented is a design
decision that was made in code without anybody deciding it.

### 2. GDD systems against feature folders

Each `systems.md` entry heads with a path like `server/features/round/`. Check that the folder
exists. Then the reverse: **a feature folder under `src/server/features/` or
`src/client/features/` that no GDD section describes.** That is a system somebody built without
writing down what it is supposed to do.

Ignore `features/example/` (template demo) and `features/telemetry/` (infrastructure, documented
in `docs/`, not design).

### 3. docs/ against the code it describes

For each file in `docs/`, check its concrete claims:

- **File and module paths.** `docs/` names modules by path constantly. A moved or renamed module
  leaves every mention wrong.
- **Function and field names.** Hook names, `Config` keys, contract fields, exported functions.
- **Behavioural claims that a quick read can settle.** "The Dispatcher errors on a remote with no
  contract entry" — is that still what it does? These are the ones worth the most and take the
  longest; prioritise the docs whose subsystem has changed recently (`git log` on the relevant
  `src/` paths since the doc was last touched is a good filter).
- **Code examples.** Do they still compile in spirit — right arguments, right module names?

### 4. Subsystems with no doc

A subsystem involved enough to need one is roughly: more than two or three modules, or one
carrying a non-obvious invariant, or one where the way it works has bitten somebody. If such a
thing exists with no `docs/` file and no mention in an existing one, say so — that is a doc that
should be written, not a mistake to fix in passing.

### 5. CLAUDE.md and the doc index

- `CLAUDE.md` summarises and links; check its links resolve and its summaries still match the
  docs they point at.
- `docs/README.md` should list every file in `docs/`.
- `plans/gdd/overview.md`'s section table should list every file in `plans/gdd/`, and its status
  table should have a row per section.

### 6. Comment blocks that outgrew their file

House style is that a comment says the one thing you need to know *at that line* and links to
`docs/` for the argument. Flag comment blocks that have grown into essays — a twenty-line header
is content that belongs in `docs/`, where it can be linked to and where the next module that
needs the same explanation can point at it instead of repeating it.

## How to search

This repo has tokensave; use `tokensave_context` and `tokensave_search` for the code side rather
than exploration agents. `grep` is the right tool for the doc side — the claims are literal
strings.

For the Config sweep specifically: read every file in `src/shared/core/Config/`, then grep
`plans/gdd/` for each key name. It is a small, finite list and worth doing exhaustively rather
than sampling.

## Reporting

Group by severity, not by file:

**Wrong** — a doc states something the code contradicts. Someone acting on it will be misled.
Give the doc's claim, the code's actual behaviour, and the file:line of each.

**Missing** — a subsystem, system, or key with no documentation.

**Stale** — a path, name, or link that no longer resolves. Usually mechanical to fix.

For each item in the first group, say **which side you think is wrong**, and why. Often the code
is right and the doc lagged; sometimes the doc records a deliberate decision that the code
quietly broke, and that one is a bug. You are frequently the only reader who will have both in
view at once — an opinion is more useful than a neutral list.

Then ask before fixing. Stale paths and dead links are safe to fix on the spot; a behavioural
claim that disagrees with the code is a decision.
