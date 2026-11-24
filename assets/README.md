# assets/

Media the game uses: sounds, images, meshes, and the `.rbxmx` models that
`default.project.json` mounts into the Workspace.

Nothing in here is referenced by a hardcoded Roblox id. `make sync-assets` uploads any file
Roblox does not already have and records the id it got back in
`src/shared/core/Assets/AssetIds.json`, keyed by filename and hashed so an edited file is
re-uploaded. Code asks `Assets.id("whistle.mp3")`, and gets `0` for a file nobody has uploaded
yet — every caller treats that as "no media", so a fresh clone is silent rather than broken.

The publish workflow does the same upload on the way to staging and commits the ids, which is
why a file added here needs no manual step: commit the file, push, and the id arrives back on
the branch.

Models are different from media in one way worth knowing: a `.rbxmx` mounted by the project
file is *content*, so it is edited in Studio and pulled back with `make syncback` — never
hand-edited as XML. A model built by server code (see `features/world/WorldBuilder`) is the
opposite: it is a build output, and editing it in Studio is wasted work because the code
destroys and rebuilds it on the next boot.
