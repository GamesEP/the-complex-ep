# How to write the design document

**This is the first thing to do with this template.** Before the first feature folder, before
the first remote, before anything is renamed: write `overview.md` and enough of the sections it
links to that somebody could build the first playable slice from them alone.

Not because process is good, but because of what this repo does with the document. The GDD is
the input to everything downstream — an agent asked to build a system reads its section and
builds *that*; a reviewer asks whether the code matches it; `Config` is where its numbers live.
A repo with no design document does not have a neutral absence of one. It has a design that
exists only in whoever last touched the code, and every agent working in it is guessing.

---

## The shape

```
plans/gdd/
  overview.md      the hub — what the game is, and a link to every section
  pillars.md       the three or four things the game is about
  loop.md          what a player does, minute to minute and session to session
  systems.md       one entry per system: its rules, its numbers, its feature folder
  progression.md   economy, unlocks, what brings somebody back
  content.md       the data: maps, items, characters, enemies
  ui.md            every screen, and what each one shows
  technical.md     the constraints: players per server, platforms, persistence
  scope.md         milestones — what is in v1, and what is explicitly not
```

**Nothing lives only in `overview.md`.** It is a hub: a paragraph on what the game is, and a
link to each section with one line on what is in it. If a section grows a subject of its own,
split it into its own file and link it — a 900-line `systems.md` is a file nobody re-reads.

Delete a section you genuinely do not need. A puzzle game with no economy should not carry an
empty `progression.md`; an empty section reads as "not decided yet" forever.

---

## The rules that make it drive development

**1. Write decisions, not aspirations.**
"Rounds should feel tense" is not a decision — nobody can build it and nobody can tell whether
it was built. "A round is 180 seconds, and the last 30 are announced" is. Keep the feeling as
the *reason* next to the decision, because the reason is what tells the next person whether a
change breaks the design or serves it:

> Rounds are 180 seconds. Long enough to find a hiding place and get bored of it, short enough
> that a bad round costs nothing. The last 30 are announced, so the ending is a scramble
> rather than a countdown nobody noticed.

**2. Every number names its Config key.**
This is the single link between the design document and the running game. A number in the GDD
that does not name where it lives is a number that will be typed into a module and diverge:

> Rounds are 180 seconds (`Config.ROUND_SECONDS`).

Then a tuning change is one edit in `src/shared/core/Config/` and one edit here, and anybody
can check the two agree. A number with no key is a number nobody can find.

**3. Every system names the feature folder that will own it.**
`systems.md` entries head with the path: `server/features/round/`. That is what makes the
document navigable *from* the code and the code navigable *from* the document, and it forces
the question "is this one system or two?" at the point where the answer is cheap.

**4. Say what a player sees, not how it is implemented.**
The GDD is *what* and *why*. `docs/` is *how*. "A caught player becomes a spectator and can
follow anybody still alive" belongs here; "the spectator camera is set through `OrbitCamera`
with the subject swapped on a store write" belongs in `docs/`. Mixing them means the GDD goes
stale every time the implementation moves, and then nobody trusts it.

**5. Open questions are marked, never guessed.**
An unresolved decision written as though it were resolved is worse than a gap, because it gets
built. Mark it and move on:

> **Open:** does a caught player drop what they were carrying? Blocks the loot system; does
> not block the round loop.

Say what it blocks. That is what turns a list of open questions into an order of work.

**6. Every section carries its status.**
One line under the heading: `Status: drafted | agreed | built | diverged`. `diverged` is the
valuable one — it means the code no longer matches this section and somebody has to decide
which is right. A section with no status is one nobody knows whether to trust.

**7. It changes in the same commit as the code.**
A design change that ships without the document is how the document dies — one stale section
is enough for people to stop reading all of them. If a PR changes what the game *is*, it
touches `plans/gdd/`. If it only changes how something is done, it touches `docs/` instead.

**8. Keep it short enough to re-read.**
A section somebody reads before starting work is worth ten times one that is comprehensive and
skimmed. If a section is over a page, it is probably two sections. Cut anything that is true of
every game — nobody needs a paragraph explaining what a leaderboard is.

---

## Writing it with an agent

The GDD is a good thing to draft with an agent and a bad thing to let one invent.

- **Answer the questions yourself.** An agent asked to "write a GDD for a hide and seek game"
  will produce something complete, plausible, and not the game you wanted — and its confident
  specificity is what makes that hard to notice. Have it ask you the questions instead, then
  write down your answers.
- **Make it flag its own guesses.** Anything it filled in rather than heard from you goes in as
  an `**Open:**` line, not as a decision.
- **Have it check the code against the document**, in both directions: a `Config` key no section
  names, and a number in a section that no key backs. Both are drift, and both are cheap to find
  and expensive to discover later.
- **A section is a good unit of work.** "Read `plans/gdd/systems.md` and build the round loop"
  is a task an agent can do well. "Build the game" is not.

---

## When it is written

Then start building — see [CLAUDE.md](../../CLAUDE.md) for how this repo is structured, and copy
the example feature. The first feature you build should be the one `scope.md` says is the
smallest playable slice, not the one that is most fun to write.
