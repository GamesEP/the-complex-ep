-- The combat room: a tracked `.rbxmx` industrial sci-fi arena (`assets/models/ComplexArena.rbxmx`,
-- mounted at `ReplicatedStorage.Models.ComplexArena`) cloned by WorldBuilder on boot.
--
-- Spawns are offsets from the arena's pivot, never hardcoded world coordinates (CLAUDE.md,
-- "Two kinds of world").
local Config = {}

Config.ARENA_MODEL = "ComplexArena"

-- The playable floor footprint in studs (must match ComplexArena.rbxmx's Floor slab).
Config.ROOM_SIZE = Vector2.new(140, 140)
Config.ROOM_WALL_HEIGHT = 18
Config.ROOM_FLOOR_COLOR = Color3.fromRGB(48, 52, 60)
Config.ROOM_WALL_COLOR = Color3.fromRGB(42, 46, 54)
Config.ROOM_FLOOR_MATERIAL = Enum.Material.Concrete

-- Offset from the arena's pivot where players arrive (centre entry elevator pad).
Config.SPAWN_OFFSET = CFrame.new(0, 4, 0)

-- Facility lighting applied on server start so Studio Play matches default.project.json even
-- if Rojo patched Lighting late (CLAUDE.md).
Config.LIGHTING_AMBIENT = Color3.fromRGB(70, 78, 92)
Config.LIGHTING_OUTDOOR_AMBIENT = Color3.fromRGB(85, 95, 115)
Config.LIGHTING_BRIGHTNESS = 1.8
Config.LIGHTING_CLOCK_TIME = 14.5

return Config
