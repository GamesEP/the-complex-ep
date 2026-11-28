# Hub, Parties & Private Run Servers

How the isolated staging Hub, open/private co-op parties, and reserved Run server teleportation work (`plans/gdd/systems.md`, `plans/roadmap.md HS-22..HS-27`).

## Geometry & Tunables

- **Model:** [`assets/models/ComplexHub.rbxmx`](../assets/models/ComplexHub.rbxmx), generated via [`scripts/generate-hub.luau`](../scripts/generate-hub.luau) with explicit `PrimaryPart = Floor`, `WorldPivot = CFrame.new(0, 0, 0)`, North elevator bay, cutaway South/East curbs, and full-height invisible containment barriers.
- **Config:** [`src/shared/core/Config/Hub.luau`](../src/shared/core/Config/Hub.luau) (`HUB_MAX_PLAYERS = 24`, `PARTY_MAX_PLAYERS = 4`, `PARTY_INVITE_SECONDS = 20`, `HUB_MODEL`, `HUB_SPAWN_OFFSET`, `STUDIO_START_IN_HUB`).
- **Place IDs:** `HUB_PLACE_ID` and `RUN_PLACE_ID` live per universe under `Config.ENV_IDS` in [`src/shared/core/Config/Environments.luau`](../src/shared/core/Config/Environments.luau) and resolve via `Environment.id(...)`.

## Visual Hub Isolation

- **Server (`HubService.luau`):** Detects server mode via `RunTeleport.currentServerMode()` (`"hub"` or `"run"`), publishes `World.ServerMode`, mounts `ComplexHub.rbxmx` through `WorldBuilder.swapHub`, and places spawning avatars on `HUB_SPAWN_OFFSET`. While `ServerMode == "hub"`, `RunService.isPaused()` returns `true` so combat actions and wave loops stay completely inactive.
- **Client (`HubIsolation.luau`):** Watches `World.ServerMode`. While in `"hub"` mode, hides every other player's character locally (`LocalTransparencyModifier = 1`, disabled decals/billboards/lights/emitters, hidden overhead nameplates) so each player sees an empty staging bay while still receiving replicated `Player` attributes for the server player list. When `ServerMode` switches to `"run"`, all teammates are restored immediately.

## Party State Machine & Remotes

- **Pure rules:** [`src/shared/features/party/PartyRules.luau`](../src/shared/features/party/PartyRules.luau) (`selfTest` verified by `make test`). Handles open/private creation, open join (capped at 4), private invitations with `20 s` TTL, accept/decline, leader-only kick & difficulty/privacy changes, automatic leader transfer to the longest-standing remaining member on leave/disconnect, and run-launch locking.
- **Server (`PartyService.luau`):** Replicates `PartyId`, `PartyRole`, `PartyPrivacy`, `PartyDifficulty`, `PartyLocked`, and `PartyOrder` onto each `Player`, sweeps expired invites, pushes private invite toasts and error notices over `Remotes.PartyEvent`, and cleans up in `onPlayerRemoving`.
- **Contracted remotes (`Contract.luau`):** `CreateParty`, `SetPartyPrivacy`, `JoinParty`, `InvitePlayer`, `RespondInvite`, `LeaveParty`, `KickMember`, `ChooseDifficulty`, `StartRun`, and `ReturnToHub`.
- **Client UI:** [`PartyStore.luau`](../src/client/features/party/stores/PartyStore.luau) (tested offline under `make test ONLY=ui`) and [`HubPartyUi.luau`](../src/client/features/party/ui/HubPartyUi.luau) (Hazard Arc squad roster, difficulty selector, scrollable `Active = true` Hub player list, and countdown invite toast).

## Multi-Place Teleport & Studio Local Fallback

- [`RunTeleport.luau`](../src/server/features/hub/RunTeleport.luau) reserves an isolated Run server via `TeleportService:ReserveServer(runPlaceId)` and calls `TeleportAsync` with `{ partyId, leaderId, difficulty, memberIds }` when published with distinct `HUB_PLACE_ID` / `RUN_PLACE_ID`.
- On `TeleportInitFailed`, logs to `LogSink`, unlocks the party, and notifies the leader via `PartyEvent`.
- In Studio (or whenever `RUN_PLACE_ID == 0`), transitions seamlessly in-place: **Iniciar Run** swaps `ComplexHub` out for Floor 1 Room 1 (`HubService.enterLocalRun()` + `RunService.launchFromHub`), and **Volver al hub** on `RunResult` resets the run and returns cleanly to `ComplexHub`.

## Not Yet Verified in Studio

- Multi-client Studio Play (2–4 clients) confirming visual avatar isolation in Hub, private invite acceptance, kick, and leader disconnect transfer.
- Published multi-place staging test confirming real `ReserveServer` isolation across concurrent squads.
