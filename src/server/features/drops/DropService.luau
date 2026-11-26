--[[
	Enemy combat drops: rolls the configured drop chance when an enemy is defeated, clones the
	matching `.rbxmx` pickup model from `ReplicatedStorage.Models`, and hands pickups to players
	within `Config.DROP_PICKUP_RADIUS`.

	Pickup effects are never applied directly here: `onPickup` is passed in through `start`
	(CombatService.applyDrop), keeping features decoupled (CLAUDE.md). See docs/combat.md.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local Drops = require(Shared.features.drops.Drops)
local Waves = require(Shared.features.enemies.Waves)

local DropService = {}

type ActiveDrop = {
	kind: Drops.DropKind,
	model: Model,
	position: Vector3,
	expiresAt: number,
}

local WALL_MARGIN = 4

local worldRef: Instance = nil :: any
local folder: Folder = nil :: any
local onPickup: (Player, Drops.DropKind) -> boolean = nil :: any
local isPaused: (() -> boolean)? = nil
local active: { ActiveDrop } = {}
local nextDefenseSpawnAt = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function templateFor(kind: Drops.DropKind): Model?
	local models = ReplicatedStorage:FindFirstChild("Models")
	if not models then
		return nil
	end
	local name = Config.DROP_MODELS[kind]
	local found = name and models:FindFirstChild(name)
	if found and found:IsA("Model") then
		return found
	end
	return nil
end

local function hasActiveKind(kind: Drops.DropKind): boolean
	for _, drop in ipairs(active) do
		if drop.kind == kind then
			return true
		end
	end
	return false
end

local function randomRoomPosition(inset: number): Vector3
	local halfX = math.max(Config.ROOM_SIZE.X / 2 - inset, 4)
	local halfZ = math.max(Config.ROOM_SIZE.Y / 2 - inset, 4)
	local x = (math.random() * 2 - 1) * halfX
	local z = (math.random() * 2 - 1) * halfZ
	return Vector3.new(x, Config.DROP_HEIGHT, z)
end

local function step()
	if isPaused and isPaused() then
		return
	end
	local t = now()
	-- Spawn the 50% defense buff periodically across the map while a fight is active (at most one
	-- on the floor at a time so pickups never pile up).
	if worldRef and worldRef:GetAttribute("RoomState") == "fighting" then
		if nextDefenseSpawnAt == 0 then
			nextDefenseSpawnAt = t + Config.DEFENSE_SPAWN_INTERVAL
		elseif t >= nextDefenseSpawnAt then
			nextDefenseSpawnAt = t + Config.DEFENSE_SPAWN_INTERVAL
			if not hasActiveKind("defense") then
				DropService.spawn("defense", randomRoomPosition(Config.DEFENSE_SPAWN_INSET))
			end
		end
	else
		nextDefenseSpawnAt = 0
	end

	if #active == 0 then
		return
	end
	local players = Players:GetPlayers()

	for i = #active, 1, -1 do
		local drop = active[i]
		if t >= drop.expiresAt or not drop.model.Parent then
			if drop.model.Parent then
				drop.model:Destroy()
			end
			table.remove(active, i)
			continue
		end

		local collected = false
		for _, player in ipairs(players) do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
				local dx = root.Position.X - drop.position.X
				local dz = root.Position.Z - drop.position.Z
				if dx * dx + dz * dz <= Config.DROP_PICKUP_RADIUS * Config.DROP_PICKUP_RADIUS then
					if onPickup(player, drop.kind) then
						local cue = if drop.kind == "heal" then "dropHeal" else "dropBuff"
						Remotes.CombatSfx:FireAllClients(cue, drop.position)
						drop.model:Destroy()
						table.remove(active, i)
						collected = true
						break
					end
				end
			end
		end
		if collected then
			continue
		end
	end
end

function DropService.spawn(kind: Drops.DropKind, position: Vector3): Model?
	local template = templateFor(kind)
	if not template then
		warn(`missing drop model for kind "{kind}" under ReplicatedStorage.Models`)
		return nil
	end

	local clamped = Waves.clamp(position, Config.ROOM_SIZE, WALL_MARGIN)
	local clearPos = Waves.avoidObstacles(clamped, 2.2, Config.ARENA_PILLARS)
	local dropPos = Vector3.new(clearPos.X, Config.DROP_HEIGHT, clearPos.Z)

	local model = template:Clone()
	local core = model.PrimaryPart or model:FindFirstChild("Core")
	if core and core:IsA("BasePart") then
		model.PrimaryPart = core
		model.WorldPivot = core.CFrame
	end
	model:SetAttribute("DropKind", kind)
	model:SetAttribute("BaseY", dropPos.Y)
	model:PivotTo(CFrame.new(dropPos))
	model.Parent = folder

	table.insert(active, {
		kind = kind,
		model = model,
		position = dropPos,
		expiresAt = now() + Config.DROP_LIFETIME_SECONDS,
	})
	return model
end

function DropService.maybeSpawn(position: Vector3)
	local kind = Drops.roll(math.random(), math.random(), Config.DROP_CHANCE, Config.DROP_WEIGHTS)
	if kind then
		DropService.spawn(kind, position)
	end
end

function DropService.clear()
	for _, drop in ipairs(active) do
		if drop.model.Parent then
			drop.model:Destroy()
		end
	end
	table.clear(active)
	nextDefenseSpawnAt = 0
end

function DropService.start(dependencies: { world: Instance, onPickup: (Player, Drops.DropKind) -> boolean, isPaused: (() -> boolean)? })
	worldRef = dependencies.world
	onPickup = dependencies.onPickup
	isPaused = dependencies.isPaused
	folder = Instance.new("Folder")
	folder.Name = "Drops"
	folder.Parent = dependencies.world
	RunService.Heartbeat:Connect(step)
end

return DropService
