---
name: design-doc
description: Draft or extend the game design document in plans/gdd/ by interviewing the user, one section at a time. Use when starting a new game from this template, when the user asks to write or update the GDD, design doc, or game design, or when a feature is being built that no GDD section describes.
---

# Writing the design document

Your job is to **interview, then write**. The user knows the game; you know the format and the
questions. What you must not do is invent the game — an agent asked to "write a GDD for a hide
and seek game" produces something complete, plausible, and not the game they wanted, and its
confident specificity is exactly what makes that hard to notice.

Read [`plans/gdd/README.md`](../../../plans/gdd/README.md) first. It is the house style for this
document and the rules below assume it.

## Before you ask anything

1. Read `plans/gdd/overview.md` and the status table. Work out what already exists.
2. If sections are filled in, **read them** — do not re-interview settled ground. Ask about gaps
   and about `**Open:**` lines.
3. If everything is still placeholders, this is a new game: start at the top.

## The interview

**Ask in small batches — three or four questions at a time, not twenty.** Use the
`AskUserQuestion` tool where the answer is a choice between a few options, and plain prose where
it is open-ended. After each batch, write what you heard into the relevant file, then move on.
Writing as you go is what keeps a long interview from ending in a wall of text nobody checks.

Order matters. Later answers depend on earlier ones, and asking out of order produces
contradictions you then have to go back and resolve:

**Round 1 — what it is.** The pitch in one line. What the player does. Player count. Platform
(is this a phone game?). The obvious comparison, and what is different about this one.
→ writes `overview.md`, starts `technical.md`

**Round 2 — pillars.** Three or four things the game is about. For each, push for **what it
rules out** — a pillar that rules nothing out is a slogan and will not settle an argument later.
If they cannot name what a pillar excludes, it probably is not one.
→ writes `pillars.md`

**Round 3 — the loop.** The moment (the thing done over and over, in seconds). The round
(start to end, as a sequence, with durations). The session (why a second round). Push on the
edges here, because they are what implementations get stuck on: what does a player who joins
mid-round see? What happens when too few players remain?
→ writes `loop.md`

**Round 4 — systems.** One at a time. For each: what it does in a sentence, the rules that
decide behaviour, the numbers that tune it, and how the client learns about it. Do not move on
to the next system until the current one has numbers.
→ writes `systems.md`

**Round 5 — progression, content, screens.** Currency and what it buys. What survives a session.
The maps and items that exist. Every screen, what it shows, and what it looks like on a phone.
→ writes `progression.md`, `content.md`, `ui.md`

**Round 6 — scope.** The smallest playable slice. What is in v1. What is explicitly *not*, each
with one line on why not. This is the section people skip and the one that gets pointed at most.
→ writes `scope.md`

Skip rounds that do not apply. A puzzle game with no economy should have `progression.md`
deleted, not filled with placeholders.

## Writing it

Follow the eight rules in `plans/gdd/README.md`. The three that are easiest to get wrong:

- **Decisions, not aspirations.** "Rounds are 180 seconds" — with the *reason* next to it, since
  the reason is what tells the next person whether a change breaks the design or serves it.
- **Every number names its Config key**: `180 seconds (`Config.ROUND_SECONDS`)`. This is the only
  link between the document and the running game. Propose the key name if it does not exist yet.
- **Every system names its feature folder**: `server/features/round/`. It forces the "is this one
  system or two?" question at the point where the answer is cheap.

And what belongs elsewhere: the GDD is *what* and *why*. How something is implemented goes in
`docs/`. Mixing them means the GDD goes stale every time the code moves, and then nobody trusts
it.

## Your own guesses

Anything you filled in that the user did not say goes in as an `**Open:**` line, not as a
decision — with what it blocks:

> **Open:** does a caught player drop what they were carrying? Blocks the loot system; does not
> block the round loop.

Say so plainly when you hand back: "I marked four things as open because I was guessing." A
document where the guesses are marked is usable. One where they are not is a trap.

## Finishing

- Update the status table in `overview.md` — one row per section, and set each section's own
  `Status:` line.
- List the open questions in `overview.md` that cross sections or block work.
- Tell the user what you wrote, what is still open, and what `scope.md` says to build first.
- **Do not start building.** Writing the document and implementing it are two tasks, and the
  point of the document is that somebody gets to read it before the second one starts.
