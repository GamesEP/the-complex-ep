--[[
	Mounts the combat arena on server start by cloning the tracked `.rbxmx` model
	`ReplicatedStorage.Models.ComplexArena` (`assets/models/ComplexArena.rbxmx`) and placing the
	SpawnLocation as an offset from the arena's pivot (CLAUDE.md, "Two kinds of world").

	Falls back to a minimal code-built room only if the model template is absent so a broken
	mount never leaves players falling into the void.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

local WorldBuilder = {}

local FLOOR_THICKNESS = 4
local WALL_THICKNESS = 3

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

local function buildFallback(world: Folder): CFrame
	local room = Config.ROOM_SIZE
	local height = Config.ROOM_WALL_HEIGHT
	local floor = block(
		"Floor",
		Vector3.new(room.X, FLOOR_THICKNESS, room.Y),
		Vector3.new(0, -FLOOR_THICKNESS / 2, 0),
		Config.ROOM_FLOOR_COLOR,
		world
	)
	floor.Material = Config.ROOM_FLOOR_MATERIAL

	local walls = {
		North = {
			Vector3.new(room.X + 2 * WALL_THICKNESS, height, WALL_THICKNESS),
			Vector3.new(0, height / 2, -(room.Y + WALL_THICKNESS) / 2),
		},
		South = {
			Vector3.new(room.X + 2 * WALL_THICKNESS, height, WALL_THICKNESS),
			Vector3.new(0, height / 2, (room.Y + WALL_THICKNESS) / 2),
		},
		West = {
			Vector3.new(WALL_THICKNESS, height, room.Y),
			Vector3.new(-(room.X + WALL_THICKNESS) / 2, height / 2, 0),
		},
		East = {
			Vector3.new(WALL_THICKNESS, height, room.Y),
			Vector3.new((room.X + WALL_THICKNESS) / 2, height / 2, 0),
		},
	}
	for name, spec in pairs(walls) do
		block(`Wall{name}`, spec[1], spec[2], Config.ROOM_WALL_COLOR, world)
	end
	return CFrame.new(0, 0, 0)
end

function WorldBuilder.build(): Folder
	local existing = workspace:FindFirstChild("World")
	if existing then
		existing:Destroy()
	end

	local world = Instance.new("Folder")
	world.Name = "World"

	local pivot = CFrame.new(0, 0, 0)
	local models = ReplicatedStorage:FindFirstChild("Models")
	local template = models and models:FindFirstChild(Config.ARENA_MODEL)
	if template and template:IsA("Model") then
		local arena = template:Clone()
		-- Re-stamp PrimaryPart and top-face PivotOffset because Rojo 7 live-sync can drop
		-- Model.PrimaryPart on `.rbxmx` imports, and Roblox resolves Model:GetPivot() through
		-- PrimaryPart.CFrame * PrimaryPart.PivotOffset.
		local floor = arena.PrimaryPart or arena:FindFirstChild("Floor")
		if floor and floor:IsA("BasePart") then
			floor.PivotOffset = CFrame.new(0, floor.Size.Y / 2, 0)
			arena.PrimaryPart = floor
		end
		arena:PivotTo(CFrame.new(0, 0, 0))
		arena.Parent = world
		pivot = arena:GetPivot()
	else
		warn(`missing arena model "{Config.ARENA_MODEL}" under ReplicatedStorage.Models — using fallback room`)
		pivot = buildFallback(world)
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	-- Resolved from the arena's pivot so moving or rotating the room takes its spawn with it.
	spawn.CFrame = pivot * Config.SPAWN_OFFSET
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
