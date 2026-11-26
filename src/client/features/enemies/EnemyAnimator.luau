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

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

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
	beamGuide: Part?,
	beamOrb: Part?,
	parryGlint: Part?,
	lastAfterimageAt: number,
	afterimageIndex: number,
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
		if rig.beamGuide then
			rig.beamGuide:Destroy()
			rig.beamGuide = nil
		end
		if rig.beamOrb then
			rig.beamOrb:Destroy()
			rig.beamOrb = nil
		end
		if rig.parryGlint then
			rig.parryGlint:Destroy()
			rig.parryGlint = nil
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
			beamGuide = nil,
			beamOrb = nil,
			parryGlint = nil,
			lastAfterimageAt = 0,
			afterimageIndex = 0,
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

local SANDEVISTAN_COLORS = {
	Color3.fromRGB(55, 235, 255),
	Color3.fromRGB(85, 255, 145),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(255, 65, 190),
}

-- Spawns a Cyberpunk Sandevistan neon afterimage silhouette of the enemy's current pose in
-- `_EnemyCorpses` so target-locking never selects afterimages.
local function spawnSandevistanGhost(model: Model, tint: Color3)
	local ghost = Instance.new("Model")
	ghost.Name = "SandevistanGhost"
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Transparency < 0.95 then
			local copy = Instance.new("Part")
			if desc:IsA("Part") then
				copy.Shape = desc.Shape
			end
			copy.Anchored = true
			copy.CanCollide = false
			copy.CanQuery = false
			copy.CanTouch = false
			copy.CastShadow = false
			copy.Material = Enum.Material.Neon
			copy.Color = tint
			copy.Transparency = 0.36
			copy.Size = desc.Size
			copy.CFrame = desc.CFrame
			copy.Parent = ghost
			TweenService:Create(
				copy,
				TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Transparency = 1 }
			):Play()
		end
	end
	ghost.Parent = getCorpseFolder()
	Debris:AddItem(ghost, 0.36)
end

-- Renders the devastating rail-beam discharge (bright core + wide outer plasma sheath + muzzle flash).
local function spawnBeamBlast(origin: Vector3, direction: Vector3, length: number)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 or length <= 0 then
		return
	end
	local unit = flat.Unit
	local mid = origin + unit * (length * 0.5)
	local orient = CFrame.lookAt(mid, mid + unit)
	local parent = getCorpseFolder()

	local core = Instance.new("Part")
	core.Name = "RailBeamCore"
	core.Shape = Enum.PartType.Block
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.CastShadow = false
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(235, 252, 255)
	core.Transparency = 0
	core.Size = Vector3.new(2.0, 2.0, length)
	core.CFrame = orient
	core.Parent = parent
	TweenService:Create(
		core,
		TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.15, 0.15, length), Transparency = 1 }
	):Play()
	Debris:AddItem(core, 0.46)

	local outer = Instance.new("Part")
	outer.Name = "RailBeamHalo"
	outer.Shape = Enum.PartType.Block
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.CastShadow = false
	outer.Material = Enum.Material.Neon
	outer.Color = Color3.fromRGB(55, 215, 255)
	outer.Transparency = 0.28
	outer.Size = Vector3.new(4.6, 3.8, length)
	outer.CFrame = orient
	outer.Parent = parent
	TweenService:Create(
		outer,
		TweenInfo.new(0.44, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(6.4, 5.2, length), Transparency = 1 }
	):Play()
	Debris:AddItem(outer, 0.48)

	local flash = Instance.new("Part")
	flash.Name = "RailBeamMuzzle"
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(160, 240, 255)
	flash.Transparency = 0.1
	flash.Size = Vector3.one * 3.5
	flash.Position = origin + unit * 2
	flash.Parent = parent
	TweenService:Create(
		flash,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * 7.5, Transparency = 1 }
	):Play()
	Debris:AddItem(flash, 0.32)
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
		elseif phase == "sandevistan" then
			targetPose = EnemyAnim.sandevistanPose()
		elseif phase == "evade" then
			targetPose = EnemyAnim.evadeJumpPose(phaseProgress)
		elseif phase == "beamCharge" then
			targetPose = EnemyAnim.beamChargePose(clock, phaseProgress)
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

		-- Client-only targeting laser line + growing muzzle charge orb while overcharging rail-beam.
		if phase == "beamCharge" then
			local dirAttr = model:GetAttribute("BeamDir")
			if typeof(dirAttr) == "Vector3" and dirAttr.Magnitude > 1e-3 then
				local guide = rig.beamGuide
				if not guide or not guide.Parent then
					local line = Instance.new("Part")
					line.Name = "EnemyBeamGuide"
					line.Shape = Enum.PartType.Block
					line.Anchored = true
					line.CanCollide = false
					line.CanQuery = false
					line.CanTouch = false
					line.CastShadow = false
					line.Material = Enum.Material.Neon
					line.Parent = getCorpseFolder()
					rig.beamGuide = line
					guide = line
				end
				local orb = rig.beamOrb
				if not orb or not orb.Parent then
					local ball = Instance.new("Part")
					ball.Name = "EnemyBeamChargeOrb"
					ball.Shape = Enum.PartType.Ball
					ball.Anchored = true
					ball.CanCollide = false
					ball.CanQuery = false
					ball.CanTouch = false
					ball.CastShadow = false
					ball.Material = Enum.Material.Neon
					ball.Parent = getCorpseFolder()
					rig.beamOrb = ball
					orb = ball
				end
				local unit = Vector3.new(dirAttr.X, 0, dirAttr.Z).Unit
				local rangeAttr = model:GetAttribute("BeamRange")
				local range = if type(rangeAttr) == "number" and rangeAttr > 0 then rangeAttr else 65
				local origin = Vector3.new(pos.X, 2.4, pos.Z)
				local locked = model:GetAttribute("BeamLocked") == true
				if guide then
					local mid = origin + unit * (range * 0.5)
					local thickness = if locked then 0.46 + 0.18 * math.abs(math.sin(clock * 36)) else 0.24 + phaseProgress * 0.22
					guide.Size = Vector3.new(thickness, thickness, range)
					guide.CFrame = CFrame.lookAt(mid, mid + unit)
					guide.Color = if locked then Color3.fromRGB(255, 70, 70) else Color3.fromRGB(90, 235, 255)
					guide.Transparency = if locked then 0.08 else 0.35 - phaseProgress * 0.22
				end
				if orb then
					local sz = 0.7 + phaseProgress * 1.9 + 0.25 * math.sin(clock * 28)
					orb.Size = Vector3.one * sz
					orb.Position = origin + unit * 3.8
					orb.Color = if locked then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(160, 245, 255)
					orb.Transparency = 0.12
				end
			end
		else
			if rig.beamGuide then
				rig.beamGuide:Destroy()
				rig.beamGuide = nil
			end
			if rig.beamOrb then
				rig.beamOrb:Destroy()
				rig.beamOrb = nil
			end
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

		-- Instant snap during high-speed spin or Sandevistan dash so pose never lags behind.
		if phase == "spin" or phase == "sandevistan" then
			rig.currentPose = targetPose
		else
			rig.currentPose = EnemyAnim.blend(rig.currentPose, targetPose, blendRate)
		end
		applyPose(rig.joints, rig.currentPose)

		-- Cyberpunk Sandevistan neon afterimage trail sampled rapidly after posing limbs.
		if phase == "sandevistan" and clock - rig.lastAfterimageAt >= 0.042 then
			rig.lastAfterimageAt = clock
			rig.afterimageIndex = (rig.afterimageIndex % #SANDEVISTAN_COLORS) + 1
			spawnSandevistanGhost(model, SANDEVISTAN_COLORS[rig.afterimageIndex])
		end

		-- Vivid pulsing parry-only glint while the Sandevistan finisher is winding up.
		if model:GetAttribute("ParryTelegraph") == true then
			local glint = rig.parryGlint
			if not glint or not glint.Parent then
				local flare = Instance.new("Part")
				flare.Name = "SandevistanParryGlint"
				flare.Shape = Enum.PartType.Ball
				flare.Anchored = true
				flare.CanCollide = false
				flare.CanQuery = false
				flare.CanTouch = false
				flare.CastShadow = false
				flare.Material = Enum.Material.Neon
				flare.Parent = getCorpseFolder()
				rig.parryGlint = flare
				glint = flare
			end
			if glint then
				local pulse = 1.6 + 1.2 * math.abs(math.sin(clock * 32))
				glint.Size = Vector3.one * pulse
				glint.Color = if math.sin(clock * 36) > 0
					then Color3.fromRGB(70, 245, 255)
					else Color3.fromRGB(255, 230, 85)
				glint.Transparency = 0.12
				glint.Position = pos + Vector3.new(0, 2.2, 0) + rig.body.CFrame.LookVector * 1.4
			end
		elseif rig.parryGlint then
			rig.parryGlint:Destroy()
			rig.parryGlint = nil
		end
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

	Remotes.EnemyAnim.OnClientEvent:Connect(function(eventKind: string, arg1: any, arg2: any, arg3: any, arg4: any)
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
		elseif eventKind == "beamFire" then
			if typeof(arg1) == "Instance" and arg1:IsA("Model") then
				local rig = rigs[arg1]
				if rig then
					rig.fireStartedAt = os.clock()
				end
			end
			if typeof(arg2) == "Vector3" and typeof(arg3) == "Vector3" and type(arg4) == "number" then
				spawnBeamBlast(arg2, arg3, arg4)
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
