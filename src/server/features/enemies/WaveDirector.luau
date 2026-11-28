--[[
	Executes the waves of the current room handed to it by `RunService`: spawns each wave in
	order, waits until `EnemyService.count() == 0`, then invokes `onRoomCleared`.

	Publishes `Wave`, `WaveCount`, `EnemiesLeft`, and `RoomState` ("waiting" | "fighting" |
	"cleared") as attributes on `workspace.World` for `CombatHud` and `ArenaTheme`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Difficulty = require(Shared.features.enemies.Difficulty)
local FloorGenerator = require(Shared.features.run.FloorGenerator)
local Waves = require(Shared.features.enemies.Waves)

local EnemyService = require(script.Parent.EnemyService)

local WaveDirector = {}

local POLL_SECONDS = 0.2
-- Spawns sit this far inside the walls (clear of perimeter crates, cryo tanks, and consoles).
local SPAWN_INSET = 13

local world: Instance = nil :: any
local getDifficulty: (() -> string)? = nil

-- Bumped by every `stop()` / `runRoom()`: any older loop sees a stale generation and exits cleanly.
local generation = 0
local sandboxMode = false

local function spawnWave(waveSpec: { [string]: number })
	local diffId = if getDifficulty then getDifficulty() else Config.DEFAULT_DIFFICULTY
	-- Read current live player count right as each wave spawns so mid-run abandonment (`HS-03`)
	-- automatically rescales subsequent waves and bosses while staying capped at MAX_ACTIVE_ENEMIES.
	local partySize = math.clamp(#Players:GetPlayers(), 1, Config.PARTY_MAX_PLAYERS)
	local scaled = FloorGenerator.capWave(Difficulty.scaleWave(waveSpec, diffId, partySize), Config.MAX_ACTIVE_ENEMIES)
	local kinds = Waves.expand(scaled)
	local obstacles = Config.getArenaObstacles(world and world:GetAttribute("ArenaModel"))
	for i, kind in ipairs(kinds) do
		local spec = Config.ENEMY_KINDS[kind]
		local rawPos: Vector3
		if spec and spec.isBoss == true then
			-- Floor bosses enter dramatically from the North Blast Door bay!
			rawPos = Vector3.new(0, 0, -(Config.ROOM_SIZE.Y / 2 - 18))
		else
			rawPos = Waves.spawnPoint(i, #kinds, Config.ROOM_SIZE, SPAWN_INSET, 0)
		end
		local safePos = Waves.avoidObstacles(rawPos, 3.5, obstacles)
		EnemyService.spawn(kind, safePos, diffId, partySize)
	end
end

function WaveDirector.stop()
	generation += 1
	if world then
		world:SetAttribute("RoomState", "waiting")
		world:SetAttribute("EnemiesLeft", 0)
	end
end

function WaveDirector.isSandbox(): boolean
	return sandboxMode
end

function WaveDirector.setSandbox(enabled: boolean)
	sandboxMode = enabled == true
	if world then
		world:SetAttribute("DebugSandbox", sandboxMode)
	end
	if sandboxMode then
		generation += 1
		if world then
			world:SetAttribute("RoomState", "fighting")
			world:SetAttribute("EnemiesLeft", EnemyService.count())
		end
	end
end

function WaveDirector.runRoom(waves: { { [string]: number } }, onRoomCleared: () -> ())
	generation += 1
	local mine = generation

	if sandboxMode then
		world:SetAttribute("WaveCount", #waves)
		world:SetAttribute("Wave", 1)
		world:SetAttribute("RoomState", "fighting")
		world:SetAttribute("EnemiesLeft", EnemyService.count())
		return
	end

	task.spawn(function()
		local function current(): boolean
			return generation == mine
		end

		world:SetAttribute("WaveCount", #waves)
		for index, waveSpec in ipairs(waves) do
			if not current() then
				return
			end
			world:SetAttribute("RoomState", "fighting")
			world:SetAttribute("Wave", index)
			spawnWave(waveSpec)
			world:SetAttribute("EnemiesLeft", EnemyService.count())
			repeat
				task.wait(POLL_SECONDS)
				if current() then
					world:SetAttribute("EnemiesLeft", EnemyService.count())
				end
			until not current() or EnemyService.count() == 0
			if index < #waves and current() then
				task.wait(Config.WAVE_GAP_SECONDS)
			end
		end

		if not current() then
			return
		end
		world:SetAttribute("RoomState", "cleared")
		world:SetAttribute("EnemiesLeft", 0)
		onRoomCleared()
	end)
end

function WaveDirector.start(dependencies: {
	world: Instance,
	getDifficulty: (() -> string)?,
})
	world = dependencies.world
	getDifficulty = dependencies.getDifficulty
	world:SetAttribute("Wave", 1)
	world:SetAttribute("WaveCount", 1)
	world:SetAttribute("EnemiesLeft", 0)
	world:SetAttribute("RoomState", "waiting")
	world:SetAttribute("DebugSandbox", false)
end

return WaveDirector
