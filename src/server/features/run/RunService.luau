--[[
	Single-floor 5-room Run controller (plans/gdd/loop.md, plans/roadmap.md VS-11..VS-12, VS-22).

	Owns Difficulty, `RunFlow` state (`preparing` -> `fighting` -> `transition` -> `victory` /
	`defeat`), manual North Blast Door room transitions, kill counting, wipe detection, and
	clean retry resets. Publishes `Floor`, `Room`, `RoomCount`, `RoomName`, `RunState`, `DoorOpen`,
	`RunStartedAt`, `RunElapsed`, `RunKills`, `RoomsCleared`, and `Difficulty` on `workspace.World`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunServiceEngine = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Difficulty = require(Shared.features.enemies.Difficulty)
local Remotes = require(Shared.core.Net.Remotes)
local RunFlow = require(Shared.features.run.RunFlow)

local RunService = {}

local world: Instance = nil :: any
local waveDirector: any = nil
local combatService: any = nil
local dropService: any = nil
local enemyService: any = nil
local upgradeService: any = nil

local flow: RunFlow.State = RunFlow.initial(Config.ROOMS_PER_FLOOR)
local currentDifficulty: string = Config.DEFAULT_DIFFICULTY
local runGeneration = 0

-- Cached closed CFrames for `ComplexArena.BlastDoor` leaves so open/close tweens stay exact.
local doorLeftClosed: CFrame? = nil
local doorRightClosed: CFrame? = nil
local doorStatusBaseColor: Color3? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

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

local function getArenaPivot(): CFrame
	local arena = world and world:FindFirstChild(Config.ARENA_MODEL)
	if arena and arena:IsA("Model") then
		return arena:GetPivot()
	end
	return CFrame.identity
end

local function setBlastDoorOpen(open: boolean, instant: boolean?)
	if world then
		world:SetAttribute("DoorOpen", open)
	end
	local arena = world and world:FindFirstChild(Config.ARENA_MODEL)
	local blastDoor = arena and arena:FindFirstChild("BlastDoor")
	if not blastDoor then
		return
	end
	local left = blastDoor:FindFirstChild("DoorLeft")
	local right = blastDoor:FindFirstChild("DoorRight")
	local statusBar = blastDoor:FindFirstChild("DoorStatusBar")

	if left and left:IsA("BasePart") and not doorLeftClosed then
		doorLeftClosed = left.CFrame
	end
	if right and right:IsA("BasePart") and not doorRightClosed then
		doorRightClosed = right.CFrame
	end
	if statusBar and statusBar:IsA("BasePart") and not doorStatusBaseColor then
		doorStatusBaseColor = statusBar.Color
	end

	local slide = Config.BLAST_DOOR_SLIDE_DISTANCE or 8.4
	local dur = if instant then 0 else (Config.BLAST_DOOR_ANIM_SECONDS or 0.7)
	local info = TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	if left and left:IsA("BasePart") and doorLeftClosed then
		local target = if open then doorLeftClosed * CFrame.new(-slide, 0, 0) else doorLeftClosed
		if dur <= 0 then
			left.CFrame = target
		else
			TweenService:Create(left, info, { CFrame = target }):Play()
		end
	end
	if right and right:IsA("BasePart") and doorRightClosed then
		local target = if open then doorRightClosed * CFrame.new(slide, 0, 0) else doorRightClosed
		if dur <= 0 then
			right.CFrame = target
		else
			TweenService:Create(right, info, { CFrame = target }):Play()
		end
	end
	if statusBar and statusBar:IsA("BasePart") then
		local targetColor = if open then Color3.fromRGB(68, 240, 152) else (doorStatusBaseColor or Color3.fromRGB(80, 215, 255))
		statusBar.Color = targetColor
		local light = statusBar:FindFirstChildOfClass("PointLight")
		if light then
			light.Color = targetColor
		end
	end
end

local function syncWorldAttributes()
	if not world then
		return
	end
	local roomDef = Config.FLOOR_ROOMS[flow.room]
	local summary = RunFlow.summary(flow, now())
	world:SetAttribute("Floor", flow.floor)
	world:SetAttribute("Room", flow.room)
	world:SetAttribute("RoomCount", flow.roomCount)
	world:SetAttribute("RoomName", if roomDef then roomDef.name else `SALA {flow.room}`)
	world:SetAttribute("RunState", flow.status)
	world:SetAttribute("RunStartedAt", flow.startedAt)
	world:SetAttribute("RunElapsed", math.floor(summary.elapsedSeconds))
	world:SetAttribute("RunKills", flow.kills)
	world:SetAttribute("RoomsCleared", flow.roomsCleared)
	world:SetAttribute("Difficulty", currentDifficulty)
end

local function repositionPlayersToSpawn(fullHeal: boolean)
	local spawnCF = getArenaPivot() * Config.SPAWN_OFFSET
	local players = Players:GetPlayers()
	for idx, player in ipairs(players) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
			if fullHeal then
				task.spawn(function()
					player:LoadCharacter()
				end)
			end
		else
			local offset = Vector3.new(((idx - 1) % 2 - 0.5) * 4, 0, math.floor((idx - 1) / 2) * 4)
			if #players == 1 then
				offset = Vector3.zero
			end
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = spawnCF * CFrame.new(offset)
			if fullHeal and combatService and combatService.resetPlayerForRun then
				combatService.resetPlayerForRun(player)
			end
		end
	end
end

local function beginCurrentRoom(myGen: number)
	if runGeneration ~= myGen or flow.status ~= "fighting" then
		return
	end
	local roomDef = Config.FLOOR_ROOMS[flow.room]
	if not roomDef then
		return
	end
	setBlastDoorOpen(false, false)
	syncWorldAttributes()

	if roomDef.isBossRoom then
		Remotes.CombatSfx:FireAllClients("bossOhEntry", Vector3.new(0, 4, -40))
	end

	waveDirector.runRoom(roomDef.waves, function()
		if runGeneration ~= myGen or flow.status ~= "fighting" then
			return
		end
		flow = RunFlow.onRoomCleared(flow, now())
		syncWorldAttributes()

		if flow.status == "victory" then
			if upgradeService then
				upgradeService.autoResolveAll()
			end
			Remotes.CombatSfx:FireAllClients("bossOhVictory", Vector3.new(0, 4, 0))
		elseif flow.status == "transition" then
			-- Zero-pause 1-of-3 upgrade offer on every room clear + unlock North Blast Door!
			if upgradeService then
				upgradeService.offerRoomClearAll()
			end
			setBlastDoorOpen(true, false)
			Remotes.CombatSfx:FireAllClients("doorOpen", Vector3.new(0, 6, -65))
		end
	end)
end

local function stepDoorTrigger()
	if flow.status ~= "transition" then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			if RunFlow.inDoorZone(root.Position) then
				-- Player stepped through the opened North Blast Door: advance cleanly to next room!
				if dropService then
					dropService.clear()
				end
				if combatService then
					combatService.clear()
				end
				flow = RunFlow.advanceRoom(flow)
				repositionPlayersToSpawn(false)
				beginCurrentRoom(runGeneration)
				return
			end
		end
	end
end

function RunService.isPaused(): boolean
	return flow.status == "preparing" or flow.status == "victory" or flow.status == "defeat"
end

function RunService.getDifficulty(): string
	return currentDifficulty
end

function RunService.onEnemyKilled()
	if flow.status == "fighting" then
		flow = RunFlow.recordKill(flow)
		if world then
			world:SetAttribute("RunKills", flow.kills)
		end
	end
end

-- Remote "ChooseDifficulty(diffId)". Allowed only on the start screen (`preparing`).
function RunService.chooseDifficulty(_player: Player, diffId: string)
	if not Difficulty.isValid(diffId) or flow.status ~= "preparing" then
		return
	end
	currentDifficulty = diffId
	if world then
		world:SetAttribute("Difficulty", currentDifficulty)
	end
end

-- Starts or restarts a full 5-room run from Room 1 with fresh starter 1-of-3 offers.
local function launchFreshRun()
	runGeneration += 1
	local myGen = runGeneration
	waveDirector.stop()
	if enemyService then
		enemyService.clear()
	end
	if dropService then
		dropService.clear()
	end
	if combatService then
		combatService.clear()
	end
	if upgradeService then
		upgradeService.resetAll()
	end
	setBlastDoorOpen(false, true)
	repositionPlayersToSpawn(true)

	flow = RunFlow.start(RunFlow.initial(Config.ROOMS_PER_FLOOR), now())
	syncWorldAttributes()

	-- Zero-pause starter 1-of-3 ability offer right as Room 1 opens.
	if upgradeService then
		upgradeService.offerStarterAll()
	end
	beginCurrentRoom(myGen)
end

-- Remote "StartRun()". Starts the run from the initial Difficulty screen.
function RunService.startRun(_player: Player)
	if flow.status ~= "preparing" then
		return
	end
	launchFreshRun()
end

-- Remote "RetryRun()". Restarts from Room 1 after Victory or Defeat.
function RunService.retryRun(_player: Player)
	if flow.status ~= "victory" and flow.status ~= "defeat" then
		return
	end
	launchFreshRun()
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		if (flow.status == "fighting" or flow.status == "transition") and not anyoneAlive() then
			runGeneration += 1
			waveDirector.stop()
			if enemyService then
				enemyService.clear()
			end
			if dropService then
				dropService.clear()
			end
			if combatService then
				combatService.clear()
			end
			setBlastDoorOpen(false, false)
			flow = RunFlow.onWipe(flow, now())
			syncWorldAttributes()
		end
	end)
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
end

function RunService.start(dependencies: {
	world: Instance,
	waveDirector: any,
	combatService: any,
	dropService: any,
	enemyService: any,
	upgradeService: any,
})
	world = dependencies.world
	waveDirector = dependencies.waveDirector
	combatService = dependencies.combatService
	dropService = dependencies.dropService
	enemyService = dependencies.enemyService
	upgradeService = dependencies.upgradeService

	flow = RunFlow.initial(Config.ROOMS_PER_FLOOR)
	currentDifficulty = Config.DEFAULT_DIFFICULTY
	setBlastDoorOpen(false, true)
	syncWorldAttributes()

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end

	RunServiceEngine.Heartbeat:Connect(stepDoorTrigger)
end

return RunService
