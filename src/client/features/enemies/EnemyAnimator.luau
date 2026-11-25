--[[
	Client-side procedural animator for rigged `.rbxmx` enemies (walking, weapon-specific attack
	windup/strike, and client-side death collapse clones).

	Drives `Motor6D.C0` on `RenderStepped` for every enemy model in `World.Enemies` whose `Body`
	carries `Group`-tagged Motor6Ds (`torso`, `head`, `leftLeg`, `rightLeg`, `leftArm`, `rightArm`).
	Because the server only updates `Body.CFrame` (and phase attributes), limb animation runs at
	60 FPS with zero Humanoid overhead and zero server-replication jitter.

	Death animations clone the `.rbxmx` template into a client-only folder outside `World.Enemies`
	so target-locking (`CombatInput`) never latches onto a collapsing enemy. See docs/combat.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local EnemyAnim = require(Shared.features.enemies.EnemyAnim)

local EnemyAnimator = {}

type JointEntry = {
	motor: Motor6D,
	restC0: CFrame,
	group: string,
}

type Rig = {
	model: Model,
	body: BasePart,
	kind: string,
	weapon: string,
	joints: { JointEntry },
	seenMotors: { [Motor6D]: boolean },
	connections: { RBXScriptConnection },
	lastPos: Vector3,
	walkPhase: number,
	speedFactor: number,
	currentPose: EnemyAnim.LimbPose,
	strikeStartedAt: number,
	fireStartedAt: number,
	spinRing: Part?,
}

type DeathAnim = {
	model: Model,
	body: BasePart,
	baseCFrame: CFrame,
	joints: { JointEntry },
	parts: { { part: BasePart, baseTransparency: number } },
	startedAt: number,
	duration: number,
}

local rigs: { [Model]: Rig } = {}
local deaths: { DeathAnim } = {}
local corpseFolder: Folder? = nil

local function getCorpseFolder(): Folder
	if corpseFolder and corpseFolder.Parent then
		return corpseFolder
	end
	local existing = workspace:FindFirstChild("_EnemyCorpses")
	if existing and existing:IsA("Folder") then
		corpseFolder = existing
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "_EnemyCorpses"
	f.Parent = workspace
	corpseFolder = f
	return f
end

local function collectJoints(model: Model, body: BasePart): { JointEntry }
	local entries: { JointEntry } = {}
	for _, child in ipairs(body:GetChildren()) do
		if child:IsA("Motor6D") then
			-- Self-heal Part0/Part1 if Rojo live-sync ever dropped Instance Refs on a clone.
			if not child.Part0 then
				child.Part0 = body
			end
			if not child.Part1 and child.Name:sub(1, 6) == "Joint_" then
				local target = model:FindFirstChild(child.Name:sub(7))
				if target and target:IsA("BasePart") then
					child.Part1 = target
				end
			end
			local group = child:GetAttribute("Group")
			if type(group) == "string" and child.Part1 then
				table.insert(entries, {
					motor = child,
					restC0 = child.C0,
					group = group,
				})
			end
		end
	end
	return entries
end

local function applyPose(joints: { JointEntry }, pose: EnemyAnim.LimbPose)
	for _, entry in ipairs(joints) do
		local delta = (pose :: any)[entry.group]
		if delta and entry.motor.Parent then
			entry.motor.C0 = entry.restC0 * delta
		end
	end
end

local function registerMotor(model: Model, body: BasePart, rig: Rig, child: Instance)
	if not child:IsA("Motor6D") or rig.seenMotors[child] then
		return
	end
	if not child.Part0 then
		child.Part0 = body
	end
	if not child.Part1 and child.Name:sub(1, 6) == "Joint_" then
		local target = model:FindFirstChild(child.Name:sub(7))
		if target and target:IsA("BasePart") then
			child.Part1 = target
		end
	end
	local group = child:GetAttribute("Group")
	if type(group) == "string" and child.Part1 then
		rig.seenMotors[child] = true
		table.insert(rig.joints, {
			motor = child,
			restC0 = child.C0,
			group = group,
		})
	end
end

local function detachEnemy(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local rig = rigs[inst]
	if rig then
		if rig.spinRing then
			rig.spinRing:Destroy()
			rig.spinRing = nil
		end
		for _, conn in ipairs(rig.connections) do
			conn:Disconnect()
		end
		rigs[inst] = nil
	end
end

local function attachEnemy(inst: Instance)
	if not inst:IsA("Model") or rigs[inst] then
		return
	end
	-- Descendants (`Body` and its Motor6D joints) can finish replicating after `ChildAdded` fires
	-- on the client (CLAUDE.md), so wait briefly for `Body` and subscribe to late-arriving joints.
	task.spawn(function()
		local body = inst:WaitForChild("Body", 5)
		if not body or not body:IsA("BasePart") or not inst.Parent or rigs[inst] then
			return
		end
		local kindAttr = inst:GetAttribute("Kind")
		local weaponAttr = inst:GetAttribute("Weapon")
		local rig: Rig = {
			model = inst,
			body = body,
			kind = if type(kindAttr) == "string" then kindAttr else inst.Name,
			weapon = if type(weaponAttr) == "string" then weaponAttr else "sword",
			joints = {},
			seenMotors = {},
			connections = {},
			lastPos = body.Position,
			walkPhase = math.random() * math.pi * 2,
			speedFactor = 0,
			currentPose = EnemyAnim.neutral(),
			strikeStartedAt = -math.huge,
			fireStartedAt = -math.huge,
			spinRing = nil,
		}
		for _, child in ipairs(body:GetChildren()) do
			registerMotor(inst, body, rig, child)
		end
		table.insert(
			rig.connections,
			body.ChildAdded:Connect(function(child)
				registerMotor(inst, body, rig, child)
			end)
		)
		table.insert(
			rig.connections,
			inst:GetAttributeChangedSignal("Weapon"):Connect(function()
				local nextWeapon = inst:GetAttribute("Weapon")
				if type(nextWeapon) == "string" then
					rig.weapon = nextWeapon
				end
			end)
		)
		rigs[inst] = rig
	end)
end

local function spawnDeathCollapse(modelName: string, cframe: CFrame)
	local models = ReplicatedStorage:FindFirstChild("Models")
	local template = models and models:FindFirstChild(modelName)
	if not template or not template:IsA("Model") then
		return
	end
	local clone = template:Clone()
	local body = clone.PrimaryPart or clone:FindFirstChild("Body")
	if not body or not body:IsA("BasePart") then
		clone:Destroy()
		return
	end
	clone.PrimaryPart = body
	body.CFrame = cframe
	clone.Parent = getCorpseFolder()

	local joints = collectJoints(clone, body)
	local parts: { { part: BasePart, baseTransparency: number } } = {}
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			-- Extinguish glowing visors/blades on death so fallen units read immediately as defeated.
			if desc.Material == Enum.Material.Neon then
				desc.Material = Enum.Material.SmoothPlastic
				desc.Color = Color3.fromRGB(70, 35, 35)
			end
			table.insert(parts, { part = desc, baseTransparency = desc.Transparency })
		end
	end

	table.insert(deaths, {
		model = clone,
		body = body,
		baseCFrame = cframe,
		joints = joints,
		parts = parts,
		startedAt = os.clock(),
		duration = Config.ENEMY_DEATH_ANIM_SECONDS,
	})
end

local function onRenderStepped(dt: number)
	local clock = os.clock()
	local serverNow = workspace:GetServerTimeNow()
	local blendRate = math.clamp(dt * 18, 0, 1)

	for model, rig in pairs(rigs) do
		if not model.Parent or not rig.body.Parent then
			detachEnemy(model)
			continue
		end
		if #rig.joints == 0 then
			continue
		end

		local pos = rig.body.Position
		local deltaXZ = Vector3.new(pos.X - rig.lastPos.X, 0, pos.Z - rig.lastPos.Z)
		rig.lastPos = pos
		local instSpeed = if dt > 1e-4 then deltaXZ.Magnitude / dt else 0
		local targetFactor = math.clamp(instSpeed / 12, 0, 1)
		rig.speedFactor += (targetFactor - rig.speedFactor) * math.clamp(dt * 10, 0, 1)
		rig.walkPhase += dt * Config.ENEMY_WALK_CYCLE_HZ * math.pi * 2 * math.max(rig.speedFactor, 0.35)

		local phase = model:GetAttribute("Phase")
		local startedAt = model:GetAttribute("PhaseStartedAt")
		local duration = model:GetAttribute("PhaseDuration")
		local phaseProgress = if type(startedAt) == "number" and type(duration) == "number" and duration > 0
			then math.clamp((serverNow - startedAt) / duration, 0, 1)
			else 1

		local targetPose: EnemyAnim.LimbPose
		local strikeElapsed = clock - rig.strikeStartedAt
		local fireElapsed = clock - rig.fireStartedAt
		if phase == "holding" then
			targetPose = EnemyAnim.grabHoldPose(clock)
		elseif phase == "spin" then
			targetPose = EnemyAnim.spinPose(clock)
		elseif phase == "lunge" then
			targetPose = EnemyAnim.grabLungePose()
		elseif phase == "fuse" then
			targetPose = EnemyAnim.fusePose(clock, phaseProgress)
		elseif strikeElapsed >= 0 and strikeElapsed < Config.ENEMY_STRIKE_ANIM_SECONDS then
			targetPose = EnemyAnim.strikePose(strikeElapsed / Config.ENEMY_STRIKE_ANIM_SECONDS, rig.weapon)
		elseif fireElapsed >= 0 and fireElapsed < Config.ENEMY_FIRE_ANIM_SECONDS then
			targetPose = EnemyAnim.firePose(fireElapsed / Config.ENEMY_FIRE_ANIM_SECONDS, rig.weapon)
		elseif phase == "windup" then
			if rig.kind == "grabber" then
				targetPose = EnemyAnim.grabWindupPose(phaseProgress)
			else
				targetPose = EnemyAnim.windupPose(phaseProgress, rig.weapon)
			end
		else
			targetPose = EnemyAnim.walkPose(rig.walkPhase, rig.speedFactor, rig.weapon, rig.kind)
		end

		-- Client-only crimson-magenta danger disc while a dual-blade enemy executes its DPS spin.
		if phase == "spin" then
			local ring = rig.spinRing
			if not ring or not ring.Parent then
				local disc = Instance.new("Part")
				disc.Name = "EnemySpinRing"
				disc.Shape = Enum.PartType.Cylinder
				disc.Anchored = true
				disc.CanCollide = false
				disc.CanQuery = false
				disc.CanTouch = false
				disc.CastShadow = false
				disc.Material = Enum.Material.Neon
				disc.Color = Color3.fromRGB(255, 65, 110)
				disc.Transparency = 0.62
				disc.Size = Vector3.new(0.35, 15.5, 15.5)
				disc.Parent = getCorpseFolder()
				rig.spinRing = disc
				ring = disc
			end
			if ring then
				local pulse = 15.0 + math.sin(clock * 24) * 1.2
				ring.Size = Vector3.new(0.35, pulse, pulse)
				ring.CFrame = CFrame.new(pos.X, 0.35, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
			end
		elseif rig.spinRing then
			rig.spinRing:Destroy()
			rig.spinRing = nil
		end

		-- Instant snap during high-speed spin so CFrame:Lerp never fights a 360-degree rotation.
		if phase == "spin" then
			rig.currentPose = targetPose
		else
			rig.currentPose = EnemyAnim.blend(rig.currentPose, targetPose, blendRate)
		end
		applyPose(rig.joints, rig.currentPose)
	end

	-- Advance client-side death collapses and clean them up once faded out.
	for i = #deaths, 1, -1 do
		local d = deaths[i]
		local u = (clock - d.startedAt) / math.max(d.duration, 0.05)
		if u >= 1 or not d.model.Parent then
			d.model:Destroy()
			table.remove(deaths, i)
		else
			local rootDelta, limbs, fadeAlpha = EnemyAnim.deathPose(u)
			d.body.CFrame = d.baseCFrame * rootDelta
			applyPose(d.joints, limbs)
			if fadeAlpha > 0 then
				for _, entry in ipairs(d.parts) do
					entry.part.Transparency = entry.baseTransparency + (1 - entry.baseTransparency) * fadeAlpha
				end
			end
		end
	end
end

local function watchEnemiesFolder(enemiesFolder: Instance)
	for _, child in ipairs(enemiesFolder:GetChildren()) do
		attachEnemy(child)
	end
	enemiesFolder.ChildAdded:Connect(attachEnemy)
	enemiesFolder.ChildRemoved:Connect(detachEnemy)
end

function EnemyAnimator.start()
	task.spawn(function()
		local world = workspace:WaitForChild("World")
		local enemiesFolder = world:WaitForChild("Enemies")
		watchEnemiesFolder(enemiesFolder)
		-- Re-hook if World is ever rebuilt.
		workspace.ChildAdded:Connect(function(child)
			if child.Name == "World" then
				local nextEnemies = child:WaitForChild("Enemies", 5)
				if nextEnemies then
					watchEnemiesFolder(nextEnemies)
				end
			end
		end)
	end)

	Remotes.EnemyAnim.OnClientEvent:Connect(function(eventKind: string, arg1: any, _arg2: any, arg3: any)
		if eventKind == "strike" then
			if typeof(arg1) == "Instance" and arg1:IsA("Model") then
				local rig = rigs[arg1]
				if rig then
					rig.strikeStartedAt = os.clock()
				end
			end
		elseif eventKind == "fire" then
			if typeof(arg1) == "Instance" and arg1:IsA("Model") then
				local rig = rigs[arg1]
				if rig then
					rig.fireStartedAt = os.clock()
				end
			end
		elseif eventKind == "death" then
			if type(arg1) == "string" and typeof(arg3) == "CFrame" then
				spawnDeathCollapse(arg1, arg3)
			end
		end
	end)

	RunService.RenderStepped:Connect(onRenderStepped)
end

return EnemyAnimator
