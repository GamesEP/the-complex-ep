# .claude/skills/

Project skills, one folder per skill with a `SKILL.md` inside. Claude Code discovers them
automatically; nothing has to be registered.

**This is the canonical location, and opencode reads it too** — `opencode.json` lists both this
folder and `.opencode/skills/` under `skills.paths`, so a skill written once is available in
both. Two hand-maintained copies of the same instructions drift the first time one is edited,
which is the same reason `AGENTS.md` points at `CLAUDE.md` instead of repeating it.

| | |
|---|---|
| `design-doc` | Interview the user and write `plans/gdd/` — the first thing a new game does |
| `doc-drift` | Check `docs/` and `plans/gdd/` against the code, and report what disagrees |

Good candidates for a new one are the repeatable, get-it-wrong-once procedures a project
accumulates: importing a map export, re-sampling spawns, cutting a release. Anything that is a
*rule* rather than a *procedure* belongs in `CLAUDE.md`, which is always loaded.
