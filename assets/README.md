# assets/

Game media and 3D models: audio (`.ogg` / `.mp3`), images (`.png` / `.jpg`), `.rbxmx` models
mounted by `default.project.json`, and (only when explicitly requested for highly complex meshes)
`.fbx` models.

## Media (audio, images, `.fbx`)

Nothing in here is referenced by a hardcoded Roblox id. `make sync-assets` uploads any file
Roblox does not already have and records the id it got back in
`src/shared/core/Assets/AssetIds.json`, keyed by filename and hashed so an edited file is
re-uploaded. Code asks `Assets.id("player-attack.ogg")`, and gets `0` for a file nobody has
uploaded yet — callers either stay silent or use a documented Studio fallback (like
`CombatAudio.resolveId`), so a fresh clone never breaks.

The publish workflow runs the same upload on `staging` and commits the ids back, so adding media
takes no manual step: drop the file here, commit, push, and the id arrives back on the branch.

## 3D models (`.rbxmx`)

New 3D models belong here as `.rbxmx` files mounted by `default.project.json` and cloned with
`:Clone()` in code — never constructed part-by-part at runtime.

- Generate `.rbxmx` models programmatically with Lune (`@lune/roblox`, `roblox.serializeModel`) or
  edit them in Studio and pull them back with `make syncback` — **never hand-edit raw XML**.
- Always set an explicit `PrimaryPart` and pivot so spawns and placement stay stable across loads
  (see `CLAUDE.md`).
- Only use `.fbx` for highly complex objects when the developer explicitly requests `.fbx`.
- Do not hand-edit anything in Studio that server code currently rebuilds on boot (such as the
  combat slice's temporary room in `features/world/WorldBuilder`) — Studio edits to code-built
  geometry are wiped on the next Play.
