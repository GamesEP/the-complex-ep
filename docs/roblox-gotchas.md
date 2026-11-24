# Engine gotchas already paid for

Roblox behaviours that cost real debugging time on the project this template came from. None of
them are documented anywhere you would look before hitting them, and several are *silent* — the
game keeps running and quietly does the wrong thing, which is the expensive kind.

Kept in the template because they are properties of the engine, not of that game. Delete an
entry only when you have verified Roblox changed it.

---

## Lifetime and replication

**`Destroying` never fires on the client** for something the server destroyed. Replication only
unparents the model, and its parts keep pointing at it — so `part.Parent` stays non-nil too. Use
`AncestryChanged` (checking for a nil parent) or `IsDescendantOf(workspace)` for end-of-life,
and call `:Destroy()` on the client copy to actually free the memory.

Getting this wrong is silent and cumulative: one HUD and one input handler stack up per respawn,
all of them fighting over the same module-level flags. It reads as "the controls got sluggish
after a while".

**A Model replicates before the parts inside it.** Attaching to a character or a spawned model
means yielding on `WaitForChild`, and how long that takes differs per client. Every message that
arrives during that wait is a message about something the client cannot act on yet.

**So anything a client *rebuilds* per object needs a stamp.** Most of what a client shows about
another player is replicated state it reads back every frame — an attribute, a CFrame — and that
kind cannot desync, because there is only one copy of it. State the client *reconstructs* from
messages is the opposite: the inputs arrive on two unordered channels. Stamp a monotonic id on
the object before parenting it, put that id in every message about it, and write down the policy
— claim before the first yield, hold what arrives early, drop what arrives about something
already replaced, never let a slow attach overwrite the one that overtook it.

That policy belongs in a pure module with a `selfTest`. The failing orderings need two clients
and a stopwatch to reproduce by hand, and they are three lines of assertion offline.

**State the server clears must be sent, not implied.** "Empty" is a state like any other. A
broadcast that only fires when there is something to say leaves a client that missed the
clearing moment showing the previous round's data forever, with nothing that can contradict it.

---

## Memory and editable assets

**Editable assets share a small memory budget** (~38 MB was the measured ceiling), and
`CreateEditableImage` **fails by returning a plain `nil`** — no error, no warning. Above the
ceiling a client meeting a new player builds a partial set and the rest is silently unusable,
on that one client, while every other client is fine.

- Do not allocate per respawn. Allocate per player and release on `PlayerRemoving`.
- **Never cache a failure as "impossible"** — a refused allocation that gets remembered as
  permanent leaves that object broken for the whole session.
- Count every failure and warn on a curve. One warning per session is what hid this for months.

**A destroyed `EditableImage` renders its part solid black, then collapses to 1x1.** It goes on
reporting itself as an EditableImage — there is no `IsDestroyed` — so nothing in the instance
tree looks wrong. The next reuse blanks that single pixel, the part turns flat white, and every
draw aimed at it *succeeds* and does nothing, because drawing outside a 1x1 image is not an
error. Size is the only tell there is: check a cached image against the layout it should have
before reusing it, and make everything wearing it let go before you destroy it.

**Never destroy an `EditableMesh` after `CreateMeshPartAsync`.** The MeshPart keeps a live link
to it, so destroying it breaks the UVs — which shows up as a part that renders its texture and
then ignores every edit. Keep one per size; it is a fixed cost, not a leak.

**`Content` object references are strong.** Per Roblox's own documentation: any `Content.Object`
reference extends the lifetime of that object and prevents garbage collection. Two consequences
that each cost a day: an `EditableMesh` handed to `CreateMeshPartAsync` is kept alive by the
resulting MeshPart rather than by any Lua variable, and destroying an `EditableImage` does *not*
clear the `TextureContent` of a MeshPart wearing it.

**An undressed MeshPart is not black.** With no `MeshContent` it renders as a **checkerboard**
placeholder; with a mesh but no texture it renders **plain white**. If you are chasing a black
part, it is a destroyed editable image, not a missing one. `MeshContent` is also not
script-writable, so the checkerboard state can only be reached by never assigning, never by
clearing.

---

## Physics and characters

**Physics controllers fight the Humanoid state machine.** A rig driven by a `ControllerManager`
wants `Humanoid.EvaluateStateMachine = false`. Impulses get swallowed by a rigid
`GroundController`, so a jump sets velocity outright and forces the `AirController` for a fixed
window rather than applying a force.

**`GroundController.GroundOffset` and `ControllerPartSensor.SearchDistance` are measured from
the root's bottom face, not its centre.** `Humanoid.HipHeight` drops straight into the same slot
for a standard avatar.

**`GroundController` is a velocity clamp, not a push** — with zero acceleration and deceleration
times it forces horizontal velocity every frame. That is why "am I grounded" has to be a
*distance* test rather than `SensedPart ~= nil`: the sensor deliberately reaches past the hover
height to see a step coming, and reading it as "standing" leaves the controller clamping a body
metres in the air — no run-up through a jump, a fall snapped short instead of landed, and jump
firing again from several studs up.

**The floor sensor only sees parts that collide.** A `CanQuery` part under the body is not a
floor.

**The friction a body walks with is blended with the material underfoot**, both weighted at 1 by
default — so a stud of walking means something different on ice than on concrete until the
controller's friction weight outvotes the ground.

**Only make one part collide and carry mass.** One set of jump and speed numbers then means the
same thing on every body shape you build.

**The engine re-enables collision on `UpperTorso` and `LowerTorso`.** Clearing `CanCollide` on a
Humanoid rig's template holds until the clone is parented into Workspace; assembling the rig
turns those two back on. Re-apply *after* parenting, or the character carries animated colliders
that the solver meets inside scenery with no velocity to work from.

**A modern avatar's `Animate` is a ModuleScript with `RunAnimate` runner scripts beside it.**
Disabling "the Animate LocalScript" silences nothing — every `BaseScript` under it has to stop,
or it plays idle over whatever you play. The module itself is worth keeping as data: its
children hold that player's animation ids, which is how a bought animation package is honoured.

---

## Input and UI

**Synthetic input does not reach `UserInputService`.** Keyboard and 3D-view mouse events driven
over the Studio MCP produce zero `InputBegan`/`JumpRequest` events, so keybinds and drags cannot
be tested end to end. GUI button clicks by `instance_path` *do* work; for everything else, call
the same code path directly and check the effect.

**`UserInputService.JumpRequest` depends on core scripts** you do not always get. Bind the key
directly as well, and land both on the same guarded function.

**`GetMouseLocation` is viewport space.** Pair it with `ViewportPointToRay`, never
`ScreenPointToRay`, and keep `IgnoreGuiInset = true` on the GUI.

**A `UIScale` scales the object it is parented to, not only its descendants.** A full-screen
frame at `fromScale(1, 1)` with a 0.55 scale on it is 55% of the screen pinned to the top left,
and everything anchored to its right or bottom edge lands in the middle of the window. Size the
container in design units and let the scale bring it back.

**A `Frame` does not sink input; a `GuiButton` does.** A slider track built from a Frame hands
the same drag to the camera as well.

**The default control scripts drive the Humanoid** and will fight a `ControllerManager`.
`DevTouchMovementMode = "Scriptable"` is what stops Roblox drawing its own thumbstick over yours.

---

## Streaming

**`StreamingMinRadius`, `StreamingTargetRadius` and `StreamOutBehavior` are `NotScriptable`.**
They live in the project file and only apply when a place is *built and opened* — the Rojo
plugin cannot patch them live, and neither can the MCP. `StreamingEnabled` itself is scriptable
in Edit. Since they cannot be read back, verify by behaviour rather than by inspection.

**`ModelStreamingMode = "Persistent"` is radius-independent** — delivered as a complete unit,
never streamed out. That is the only thing that actually guarantees a whole map on every client;
a radius large enough today is a radius somebody shrinks tomorrow. It is not free: a few
thousand parts on every client is the cost.

**A streamed-out model comes back as a fresh replica** with nothing refiring `CharacterAdded`.
Re-attach off `workspace.ChildAdded`, and make the re-attach idempotent — it will over-fire.

**Do not treat one child's arrival as proof the whole model is there.** A model that replicates
all at once arrives in build order, so the last-added child is a fair thing to wait on; a model
streaming *back* in is reassembled in an order the engine does not promise. Check for what you
actually need, and keep the listener connected until that answers true.

---

## Lighting

**`GlobalShadows = false` only does anything under `Technology = "Voxel"`.** ShadowMap and
Future ignore the flag and shade from per-part `CastShadow` and per-light `Shadows` instead — so
changing the technology brings every shadow back whatever else you set.

**Rojo patches Lighting when the plugin connects.** A Play pressed before that patch lands clones
the *old* values, so a Lighting setting that exists only in the project file can be silently
wrong for a whole Studio session. Setting it on the server at boot replicates to every client and
makes it self-healing.

---

## Models, pivots and imported maps

**A Model with no `WorldPivotData` and no `PrimaryPart` has no dependable pivot.** Roblox derives
one, and the derived value moves between loads — observed swinging 50+ studs inside a single
session. Every spawn expressed as an offset from that pivot then lands underground. Stamp an
explicit pivot in and commit it.

**A Model stores its pivot in two properties and they can disagree.** `WorldPivot` and
`WorldPivotData` both survive serialisation, and different tools read different ones. Decide
which your offsets are measured against; make anything that writes a pivot write both; fail the
build when they differ rather than guessing.

**Serialise models as XML, not binary, if anything reads `WorldPivot`.** The binary writer drops
`WorldPivot` and keeps only `WorldPivotData`, so a model written as binary comes back with a
*derived* pivot. Verify by re-reading the file you wrote — both forms are correct in memory, and
the difference exists only on disk.

**An imported map brings somebody else's material library.** A map exported from another place
usually ships its author's whole material pack in a folder called something like
`-- Ungroup in Material Service --`. The name is the instruction: a `MaterialVariant` only
applies from `MaterialService`, and one sitting in a Workspace model is inert. It is not free —
the engine still fetches every texture it points at, those belong to whoever built the pack, and
each one fails with `Failed to fetch TexturePack`. One observed import shipped 1313 of them: 502
warnings a session, against a `GetLogHistory` buffer that holds 512, so the server's own boot
lines were evicted by the spam. Strip them on import.

---

## Spawning

**Flat ground does not prove there is room to stand.** Vertical tests — a flat face, nothing
overhead — all pass for the gap between two crates, and the body arrives wedged in the scenery.
Test clearance with a probe part and `GetPartsInPart`, never `GetPartBoundsInBox`: the bounds
version answers with anything whose *bounding box* overlaps, and one CSG union spanning a whole
floor reports every spawn on it as blocked.

**Clearance is sideways and overhead only — the box stops at the soles.** Reach below them and
the floor fails its own test, and so does every kerb, step and tuft the body is merely standing
over.

**A spawn CFrame is the body's root, so its height depends on the body.** Two characters of
different sizes standing on the same floor do not share a spawn Y.

**A spawn can be a whole map away from where the player stood.** Fire a best-effort
`RequestStreamAroundAsync` at the destination; the engine's physics pause holds the body over
unloaded ground, and a void-catcher is the backstop.
