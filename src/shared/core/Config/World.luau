-- The combat room, built from code by WorldBuilder on boot. Built-from-code means these are
-- *world* coordinates; a room exported from Studio would use offsets from its pivot instead
-- (CLAUDE.md, "Two kinds of world").
local Config = {}

-- The floor's footprint, in studs. Walls stand on its edges and enemies spawn just inside them.
Config.ROOM_SIZE = Vector2.new(140, 140)
Config.ROOM_WALL_HEIGHT = 12
Config.ROOM_FLOOR_COLOR = Color3.fromRGB(70, 74, 82)
Config.ROOM_WALL_COLOR = Color3.fromRGB(40, 42, 50)
Config.ROOM_FLOOR_MATERIAL = Enum.Material.Concrete

-- Where players arrive: the middle of the room, with the enemies spawning around them.
Config.SPAWN_CFRAME = CFrame.new(0, 4, 0)

return Config
