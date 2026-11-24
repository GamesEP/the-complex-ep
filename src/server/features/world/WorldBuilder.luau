--[[
	The combat room, built from code on server start: a floor, four walls and the spawn.

	Built-from-code means the coordinates in Config are *world* coordinates (CLAUDE.md, "Two kinds
	of world"). `build` destroys and rebuilds, so a leftover from an older version of this code
	cannot survive into a new session — which is also why editing this room in Studio is wasted
	work: change Config.ROOM_* instead.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

local WorldBuilder = {}

local FLOOR_THICKNESS = 4
local WALL_THICKNESS = 2

local function block(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.Position = position
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

function WorldBuilder.build(): Folder
	local existing = workspace:FindFirstChild("World")
	if existing then
		existing:Destroy()
	end

	local world = Instance.new("Folder")
	world.Name = "World"

	local room = Config.ROOM_SIZE
	local height = Config.ROOM_WALL_HEIGHT

	-- Top face at y = 0, so every height in the game is measured from the floor.
	local floor = block(
		"Floor",
		Vector3.new(room.X, FLOOR_THICKNESS, room.Y),
		Vector3.new(0, -FLOOR_THICKNESS / 2, 0),
		Config.ROOM_FLOOR_COLOR,
		world
	)
	floor.Material = Config.ROOM_FLOOR_MATERIAL

	local walls = {
		North = { Vector3.new(room.X + 2 * WALL_THICKNESS, height, WALL_THICKNESS), Vector3.new(0, height / 2, -(room.Y + WALL_THICKNESS) / 2) },
		South = { Vector3.new(room.X + 2 * WALL_THICKNESS, height, WALL_THICKNESS), Vector3.new(0, height / 2, (room.Y + WALL_THICKNESS) / 2) },
		West = { Vector3.new(WALL_THICKNESS, height, room.Y), Vector3.new(-(room.X + WALL_THICKNESS) / 2, height / 2, 0) },
		East = { Vector3.new(WALL_THICKNESS, height, room.Y), Vector3.new((room.X + WALL_THICKNESS) / 2, height / 2, 0) },
	}
	for name, spec in pairs(walls) do
		block(`Wall{name}`, spec[1], spec[2], Config.ROOM_WALL_COLOR, world)
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = Config.SPAWN_CFRAME
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Enabled = true
	-- No spawn shield. Roblox's default is a 10 s ForceField, which made the first wave unable to
	-- hurt anybody; a death resets the room, so there is nothing left to be shielded from.
	spawn.Duration = 0
	spawn.Parent = world

	world.Parent = workspace
	return world
end

return WorldBuilder
