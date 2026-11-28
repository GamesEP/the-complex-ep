-- Hub, Party & Private Run Server tunables (`plans/gdd/systems.md`, `plans/roadmap.md HS-03 / HS-22..HS-27`).
local Config = {}

-- Maximum concurrent players in a single public Hub server (each sees an isolated empty Hub).
Config.HUB_MAX_PLAYERS = 24

-- Co-op party capacity (1-4 players) and private-party invitation timeout.
Config.PARTY_MAX_PLAYERS = 4
Config.PARTY_INVITE_SECONDS = 20

-- Hub model & spawn geometry (`assets/models/ComplexHub.rbxmx`).
Config.HUB_MODEL = "ComplexHub"
Config.HUB_ROOM_SIZE = Vector2.new(80, 80)
Config.HUB_SPAWN_OFFSET = CFrame.new(0, 3, 18)

-- Minimum wait between retry attempts after a failed live TeleportService call.
Config.TELEPORT_RETRY_COOLDOWN = 2

-- When true in Studio (and HUB_PLACE_ID / RUN_PLACE_ID are 0), the server starts in Hub mode and
-- lets developers test Hub -> Party -> 5-Floor Run -> RunResult -> Hub inside one local session.
Config.STUDIO_START_IN_HUB = true

return Config
