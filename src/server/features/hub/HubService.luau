--!strict
--[[
	Isolated Hub server service (`plans/gdd/systems.md`, `plans/roadmap.md HS-23`).

	Manages `World.ServerMode` (`"hub"` | `"run"`), mounts `ComplexHub.rbxmx` while in Hub mode,
	and places spawning players cleanly on the Hub staging bay. Visual isolation (hiding other
	players' avatars while keeping `Player` attributes replicated for the live server player list)
	is enforced locally by `client/features/hub/HubIsolation.luau`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local HubService = {}

local world: Instance = nil :: any
local worldBuilder: any = nil
local mode: "hub" | "run" = "hub"

local function placeAtHubSpawn(player: Player, pivot: CFrame)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = pivot * Config.HUB_SPAWN_OFFSET
	end
end

function HubService.isHub(): boolean
	return mode == "hub"
end

function HubService.getMode(): "hub" | "run"
	return mode
end

function HubService.enterHub()
	mode = "hub"
	if world then
		world:SetAttribute("ServerMode", "hub")
		world:SetAttribute("HubMaxPlayers", Config.HUB_MAX_PLAYERS)
	end
	local pivot = CFrame.new(0, 0, 0)
	if worldBuilder and worldBuilder.swapHub then
		pivot = worldBuilder.swapHub(world, Config.HUB_MODEL)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		placeAtHubSpawn(player, pivot)
	end
end

function HubService.enterLocalRun()
	mode = "run"
	if world then
		world:SetAttribute("ServerMode", "run")
	end
end

function HubService.start(deps: {
	world: Instance,
	worldBuilder: any,
	initialMode: "hub" | "run",
})
	world = deps.world
	worldBuilder = deps.worldBuilder
	mode = deps.initialMode

	world:SetAttribute("ServerMode", mode)
	world:SetAttribute("HubMaxPlayers", Config.HUB_MAX_PLAYERS)

	if mode == "hub" then
		HubService.enterHub()
	end

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			if mode ~= "hub" then
				return
			end
			task.defer(function()
				if mode ~= "hub" then
					return
				end
				local hub = world and world:FindFirstChild(Config.HUB_MODEL)
				local pivot = if hub and hub:IsA("Model") then hub:GetPivot() else CFrame.new(0, 0, 0)
				placeAtHubSpawn(player, pivot)
			end)
		end)
	end)
end

return HubService
