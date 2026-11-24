--[[
	The room's waves: spawn one, wait until it is dead, spawn the next. When the last is cleared the
	room is clean, and a few seconds later it starts again — the combat slice is for fighting the
	same room over and over (plans/gdd/scope.md). If every player is dead, the room resets.

	What the HUD shows is written as attributes on the World folder: `Wave`, `WaveCount`,
	`EnemiesLeft`, `RoomState` ("waiting" | "fighting" | "cleared").
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Waves = require(Shared.features.enemies.Waves)

local EnemyService = require(script.Parent.EnemyService)

local WaveDirector = {}

-- How often the director looks at the board. Waves change on a scale of seconds; checking every
-- frame would only cost more.
local POLL_SECONDS = 0.2
-- Spawns sit this far inside the walls.
local SPAWN_INSET = 10

local world: Instance = nil :: any

-- Bumped by every reset. A loop holding an older generation stops at its next check, so a
-- reset can never leave the old loop spawning into the new room.
local generation = 0

local function anyoneAlive(): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			return true
		end
	end
	return false
end

local function spawnWave(index: number)
	local kinds = Waves.expand(Config.WAVES[index])
	for i, kind in ipairs(kinds) do
		EnemyService.spawn(kind, Waves.spawnPoint(i, #kinds, Config.ROOM_SIZE, SPAWN_INSET, 0))
	end
end

local function run(mine: number)
	local function current(): boolean
		return generation == mine
	end

	while current() do
		world:SetAttribute("RoomState", "waiting")
		world:SetAttribute("EnemiesLeft", 0)
		while current() and not anyoneAlive() do
			task.wait(POLL_SECONDS)
		end

		for index = 1, #Config.WAVES do
			if not current() then
				return
			end
			world:SetAttribute("RoomState", "fighting")
			world:SetAttribute("Wave", index)
			spawnWave(index)
			repeat
				task.wait(POLL_SECONDS)
				world:SetAttribute("EnemiesLeft", EnemyService.count())
			until not current() or EnemyService.count() == 0
			if index < #Config.WAVES and current() then
				task.wait(Config.WAVE_GAP_SECONDS)
			end
		end

		if not current() then
			return
		end
		world:SetAttribute("RoomState", "cleared")
		task.wait(Config.ROOM_RESTART_SECONDS)
	end
end

-- Everybody died: clear the board and start from wave 1 once somebody is back.
function WaveDirector.reset()
	generation += 1
	EnemyService.clear()
	world:SetAttribute("Wave", 1)
	task.spawn(run, generation)
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		if not anyoneAlive() then
			WaveDirector.reset()
		end
	end)
end

local function watch(player: Player)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
end

function WaveDirector.start(dependencies: { world: Instance })
	world = dependencies.world
	world:SetAttribute("WaveCount", #Config.WAVES)
	Players.PlayerAdded:Connect(watch)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	WaveDirector.reset()
end

return WaveDirector
