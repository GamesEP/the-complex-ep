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
local FloorGenerator = require(Shared.features.run.FloorGenerator)
local Remotes = require(Shared.core.Net.Remotes)
local RunFlow = require(Shared.features.run.RunFlow)

local RunService = {}

local world: Instance = nil :: any
local worldBuilder: any = nil
local waveDirector: any = nil
local combatService: any = nil
local dropService: any = nil
local enemyService: any = nil
local upgradeService: any = nil
local isHubMode: (() -> boolean)? = nil
local onHubDifficulty: ((Player, string) -> ())? = nil
local onHubStartRequest: ((Player) -> ())? = nil
local onReturnHubRequest: ((Player) -> ())? = nil
local getTeleportDifficulty: ((Player) -> string?)? = nil
local isAnyoneStandingFn: (() -> boolean)? = nil
local resetReviveAll: (() -> ())? = nil
local reviveDownedAll: (() -> ())? = nil

local flow: RunFlow.State = RunFlow.initial(Config.ROOMS_PER_FLOOR, Config.FLOORS_PER_RUN)
local runPlan: FloorGenerator.RunPlan = FloorGenerator.generateRun()
local currentDifficulty: string = Config.DEFAULT_DIFFICULTY
local runGeneration = 0

-- Cached closed CFrames for the active arena's `BlastDoor` leaves (cleared whenever arenas swap).
local doorArenaRef: Instance? = nil
local doorLeftClosed: CFrame? = nil
local doorRightClosed: CFrame? = nil
local doorStatusBaseColor: Color3? = nil
local doorOpenedAt = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function anyoneAlive(): boolean
	if isAnyoneStandingFn then
		return isAnyoneStandingFn()
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and player:GetAttribute("Downed") ~= true then
			return true
		end
	end
	return false
end

local function getActiveArena(): Model?
	if not world then
		return nil
	end
	local activeName = world:GetAttribute("ArenaModel")
	if type(activeName) == "string" and activeName ~= "" then
		local named = world:FindFirstChild(activeName)
		if named and named:IsA("Model") then
			return named
		end
	end
	local fallback = world:FindFirstChild(Config.ARENA_MODEL)
	return if fallback and fallback:IsA("Model") then fallback else nil
end

local function getArenaPivot(): CFrame
	local arena = getActiveArena()
	if arena then
		return arena:GetPivot()
	end
	return CFrame.identity
end

local function currentRoomPlan(): FloorGenerator.RoomPlan?
	local floorRooms = runPlan[flow.floor]
	return if floorRooms then floorRooms[flow.room] else nil
end

local function setBlastDoorOpen(open: boolean, instant: boolean?)
	doorOpenedAt = if open then now() else 0
	if world then
		world:SetAttribute("DoorOpen", open)
	end
	local arena = getActiveArena()
	if arena ~= doorArenaRef then
		doorArenaRef = arena
		doorLeftClosed = nil
		doorRightClosed = nil
		doorStatusBaseColor = nil
	end
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
	local roomDef = currentRoomPlan()
	local floorDef = Config.FLOORS[flow.floor]
	local summary = RunFlow.summary(flow, now())
	world:SetAttribute("Floor", flow.floor)
	world:SetAttribute("FloorCount", flow.floorCount)
	world:SetAttribute("FloorName", if floorDef then floorDef.name else `PISO {flow.floor}`)
	world:SetAttribute("Room", flow.room)
	world:SetAttribute("RoomCount", flow.roomCount)
	world:SetAttribute("TotalRoomCount", summary.totalRoomCount)
	world:SetAttribute("RoomName", if roomDef then roomDef.name else `SALA {flow.room}`)
	world:SetAttribute("IsBossRoom", if roomDef then roomDef.isBossRoom else false)
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
	local roomDef = currentRoomPlan()
	if not roomDef then
		return
	end
	if worldBuilder and worldBuilder.swapArena then
		worldBuilder.swapArena(world, roomDef.arena)
	end
	setBlastDoorOpen(false, true)
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
	-- Wait for the Blast Door slide animation so clearing the final enemy near the North wall
	-- never teleports the player out on frame 1 before they can see the door open or grab drops.
	if now() - doorOpenedAt < (Config.BLAST_DOOR_ANIM_SECONDS or 0.7) then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and player:GetAttribute("Downed") ~= true and root and root:IsA("BasePart") then
			if RunFlow.inDoorZone(root.Position) then
				-- Player stepped through the opened North Blast Door: advance cleanly!
				local crossingFloor = RunFlow.isFloorBoundary(flow)
				if reviveDownedAll then
					reviveDownedAll()
				end
				if dropService then
					dropService.clear()
				end
				if combatService then
					combatService.clear()
				end
				-- Floor exit (Floor N Room 5 -> Floor N+1 Room 1): randomly resolve any queued
				-- unpicked upgrades per plans/gdd/systems.md so nobody carries queues across floors.
				if crossingFloor and upgradeService then
					upgradeService.autoResolveAll()
				end
				flow = RunFlow.advanceRoom(flow)
				local nextDef = currentRoomPlan()
				if nextDef and worldBuilder and worldBuilder.swapArena then
					worldBuilder.swapArena(world, nextDef.arena)
				end
				repositionPlayersToSpawn(false)
				beginCurrentRoom(runGeneration)
				return
			end
		end
	end
end

function RunService.isPaused(): boolean
	if isHubMode and isHubMode() then
		return true
	end
	return flow.status == "preparing" or flow.status == "victory" or flow.status == "defeat"
end

function RunService.isInRun(): boolean
	return flow.status == "fighting" or flow.status == "transition"
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

-- Remote "ChooseDifficulty(diffId)". In Hub mode delegates to PartyService; on the Run start
-- screen (`preparing`) sets the run's difficulty directly.
function RunService.chooseDifficulty(player: Player, diffId: string)
	if not Difficulty.isValid(diffId) then
		return
	end
	if isHubMode and isHubMode() then
		if onHubDifficulty then
			onHubDifficulty(player, diffId)
		end
		return
	end
	if flow.status ~= "preparing" then
		return
	end
	currentDifficulty = diffId
	if world then
		world:SetAttribute("Difficulty", currentDifficulty)
	end
end

-- Starts or restarts a full 5-floor randomized run from Floor 1 Room 1 with fresh starter offers.
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
	if resetReviveAll then
		resetReviveAll()
	end
	runPlan = FloorGenerator.generateRun()
	flow = RunFlow.start(RunFlow.initial(Config.ROOMS_PER_FLOOR, Config.FLOORS_PER_RUN), now())
	local firstDef = currentRoomPlan()
	if firstDef and worldBuilder and worldBuilder.swapArena then
		worldBuilder.swapArena(world, firstDef.arena)
	end
	setBlastDoorOpen(false, true)
	repositionPlayersToSpawn(true)
	syncWorldAttributes()

	-- Zero-pause starter 1-of-3 ability offer right as Floor 1 Room 1 opens.
	if upgradeService then
		upgradeService.offerStarterAll()
	end
	beginCurrentRoom(myGen)
end

-- Called by Hub/Teleport local fallback (or reserved Run server auto-launch) to begin a run.
function RunService.launchFromHub(diffId: string?)
	if Difficulty.isValid(diffId) then
		currentDifficulty = diffId :: string
	end
	launchFreshRun()
end

-- Stops any active run cleanly and transitions back to `preparing` (used when returning to Hub
-- locally in Studio or cleaning up).
function RunService.resetToPreparing()
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
	if upgradeService then
		upgradeService.resetAll()
	end
	if resetReviveAll then
		resetReviveAll()
	end
	flow = RunFlow.initial(Config.ROOMS_PER_FLOOR, Config.FLOORS_PER_RUN)
	setBlastDoorOpen(false, true)
	syncWorldAttributes()
end

-- Triggers full-squad wipe (called by Humanoid.Died fallback or ReviveService when all teammates
-- are downed / last standing teammate disconnects).
function RunService.triggerWipe()
	if flow.status ~= "fighting" and flow.status ~= "transition" then
		return
	end
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
	if upgradeService then
		upgradeService.resetAll()
	end
	if resetReviveAll then
		resetReviveAll()
	end
	setBlastDoorOpen(false, false)
	flow = RunFlow.onWipe(flow, now())
	syncWorldAttributes()
end

-- Remote "StartRun()". In Hub mode forwards to PartyService.requestLaunch; in Run mode starts
-- from the preparing screen.
function RunService.startRun(player: Player)
	if isHubMode and isHubMode() then
		if onHubStartRequest then
			onHubStartRequest(player)
		end
		return
	end
	if flow.status ~= "preparing" then
		return
	end
	launchFreshRun()
end

-- Remote "RetryRun()". Restarts from Floor 1 Room 1 after Victory or Defeat.
function RunService.retryRun(_player: Player)
	if isHubMode and isHubMode() then
		return
	end
	if flow.status ~= "victory" and flow.status ~= "defeat" then
		return
	end
	launchFreshRun()
end

-- Remote "ReturnToHub()". Returns from RunResult (or active run) back to the Hub place/bay.
function RunService.returnToHub(player: Player)
	if isHubMode and isHubMode() then
		return
	end
	if onReturnHubRequest then
		onReturnHubRequest(player)
	end
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		if (flow.status == "fighting" or flow.status == "transition") and not anyoneAlive() then
			RunService.triggerWipe()
		end
	end)
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
	-- In a live reserved Run server (`ServerMode == "run"`), read the party's teleport difficulty
	-- from the first arriving player and auto-start once they load in.
	if (not isHubMode or not isHubMode()) and flow.status == "preparing" and getTeleportDifficulty then
		local tpDiff = getTeleportDifficulty(player)
		if Difficulty.isValid(tpDiff) then
			currentDifficulty = tpDiff :: string
			syncWorldAttributes()
			task.delay(1.0, function()
				if flow.status == "preparing" and (not isHubMode or not isHubMode()) then
					launchFreshRun()
				end
			end)
		end
	end
end

function RunService.start(dependencies: {
	world: Instance,
	worldBuilder: any?,
	waveDirector: any,
	combatService: any,
	dropService: any,
	enemyService: any,
	upgradeService: any,
	isHubMode: (() -> boolean)?,
	onHubDifficulty: ((Player, string) -> ())?,
	onHubStartRequest: ((Player) -> ())?,
	onReturnHubRequest: ((Player) -> ())?,
	getTeleportDifficulty: ((Player) -> string?)?,
	isAnyoneStanding: (() -> boolean)?,
	resetReviveAll: (() -> ())?,
	reviveDownedAll: (() -> ())?,
})
	world = dependencies.world
	worldBuilder = dependencies.worldBuilder
	waveDirector = dependencies.waveDirector
	combatService = dependencies.combatService
	dropService = dependencies.dropService
	enemyService = dependencies.enemyService
	upgradeService = dependencies.upgradeService
	isHubMode = dependencies.isHubMode
	onHubDifficulty = dependencies.onHubDifficulty
	onHubStartRequest = dependencies.onHubStartRequest
	onReturnHubRequest = dependencies.onReturnHubRequest
	getTeleportDifficulty = dependencies.getTeleportDifficulty
	isAnyoneStandingFn = dependencies.isAnyoneStanding
	resetReviveAll = dependencies.resetReviveAll
	reviveDownedAll = dependencies.reviveDownedAll

	runPlan = FloorGenerator.generateRun()
	flow = RunFlow.initial(Config.ROOMS_PER_FLOOR, Config.FLOORS_PER_RUN)
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
