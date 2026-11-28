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
	lastHitCount: number,
	hitstunStartedAt: number,
	spinRing: Part?,
	spinTrails: { Part }?,
	spinSparks: { Part }?,
	spinRimSegs: { Part }?,
	beamGuide: Part?,
	beamOrb: Part?,
	parryGlint: Part?,
	slamOuter: Part?,
	slamInner: Part?,
	bossConeArc: { Part }?,
	bossLeapOuter: Part?,
	bossLeapInner: Part?,
	bossNovaRing: Part?,
	alertGui: BillboardGui?,
	stunOrbs: { Part }?,
	contactAura: Part?,
	contactArcs: { Part }?,
	contactBolts: { Part }?,
	contactSparks: { Part }?,
	contactRingSegs: { Part }?,
	contactLight: PointLight?,
	nextBoltReseedAt: number,
	boltSeeds: { { angle: number, distFrac: number, jitter1: Vector3, jitter2: Vector3, colorIdx: number } },
	bossSweepBeam: Part?,
	bossDashLine: Part?,
	lastAfterimageAt: number,
	afterimageIndex: number,
}

type ToxicBubble = {
	part: Part,
	angle: number,
	distFrac: number,
	speed: number,
	phase: number,
	maxSize: number,
	maxRise: number,
}

type ToxicPoolRig = {
	source: BasePart,
	radius: number,
	anchor: Part,
	swirls: { Part },
	rimSegs: { Part },
	bubbles: { ToxicBubble },
	emitter: ParticleEmitter,
}

type BallisticChunk = {
	part: Part,
	velocity: Vector3,
	gravity: number,
	startedAt: number,
	duration: number,
	baseSize: Vector3,
	stretch: boolean,
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
local toxicPools: { [BasePart]: ToxicPoolRig } = {}
local ballistics: { BallisticChunk } = {}
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
	local rootDelta = pose.root or CFrame.identity
	-- Resolve the rig's torso pivot so head and shoulders follow `pose.torso` hierarchically
	-- (preventing floating detached arms/heads during crouches, twists, leaps, and recoil).
	local torsoPivot = CFrame.identity
	for _, entry in ipairs(joints) do
		if entry.group == "torso" then
			torsoPivot = entry.restC0
			break
		end
	end
	local torsoShift = torsoPivot * pose.torso * torsoPivot:Inverse()
	local hipDrop = CFrame.new(0, pose.torso.Position.Y * 0.45, 0)

	for _, entry in ipairs(joints) do
		local delta = (pose :: any)[entry.group]
		if delta and entry.motor.Parent then
			if entry.group == "torso" then
				entry.motor.C0 = rootDelta * entry.restC0 * delta
			elseif entry.group == "head" or entry.group == "leftArm" or entry.group == "rightArm" then
				entry.motor.C0 = rootDelta * torsoShift * entry.restC0 * delta
			else
				entry.motor.C0 = rootDelta * hipDrop * entry.restC0 * delta
			end
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

local function makeVfxPart(
	name: string,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?,
	transparency: number?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material or Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency or 0
	if shape then
		p.Shape = shape
	end
	p.Parent = getCorpseFolder()
	return p
end

local function positionSegment(part: Part, p0: Vector3, p1: Vector3, thickness: number)
	local delta = p1 - p0
	local len = delta.Magnitude
	if len < 1e-3 then
		part.Size = Vector3.new(thickness, thickness, 0.05)
		part.CFrame = CFrame.new(p0)
		return
	end
	local mid = (p0 + p1) * 0.5
	part.Size = Vector3.new(thickness, thickness, len)
	part.CFrame = CFrame.lookAt(mid, p1)
end

local function destroyPartList(list: { Part }?)
	if not list then
		return
	end
	for _, p in ipairs(list) do
		if p.Parent then
			p:Destroy()
		end
	end
end

local function detachToxicPool(source: BasePart)
	local pool = toxicPools[source]
	if not pool then
		return
	end
	toxicPools[source] = nil
	destroyPartList(pool.swirls)
	destroyPartList(pool.rimSegs)
	for _, b in ipairs(pool.bubbles) do
		if b.part.Parent then
			b.part:Destroy()
		end
	end
	if pool.anchor.Parent then
		pool.anchor:Destroy()
	end
end

local function attachToxicPool(source: BasePart)
	if toxicPools[source] then
		return
	end
	local radAttr = source:GetAttribute("HazardRadius")
	local radius = if type(radAttr) == "number" and radAttr > 0 then radAttr else (source.Size.Y * 0.5)
	local center = Vector3.new(source.Position.X, 0.25, source.Position.Z)

	local anchor = makeVfxPart("ToxicPoolVaporAnchor", Color3.fromRGB(115, 255, 65), Enum.Material.SmoothPlastic, nil, 1)
	anchor.Size = Vector3.new(radius * 1.45, 0.2, radius * 1.45)
	anchor.CFrame = CFrame.new(center)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(165, 255, 70)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(82, 225, 45)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(28, 90, 22)),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.65),
		NumberSequenceKeypoint.new(0.45, 1.55),
		NumberSequenceKeypoint.new(1, 2.2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.82),
		NumberSequenceKeypoint.new(0.35, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.9, 1.5)
	emitter.Rate = 16
	emitter.Speed = NumberRange.new(2.2, 4.8)
	emitter.SpreadAngle = Vector2.new(22, 22)
	emitter.RotSpeed = NumberRange.new(-45, 45)
	emitter.LightEmission = 0.55
	emitter.Enabled = source:GetAttribute("HazardActive") == true
	emitter.Parent = anchor

	-- Organic swirling acid currents rotating across the sludge surface.
	local swirls: { Part } = {}
	for i = 1, 6 do
		local c = if i % 2 == 0 then Color3.fromRGB(150, 255, 62) else Color3.fromRGB(72, 210, 38)
		local p = makeVfxPart(`ToxicSwirl_{i}`, c, Enum.Material.Neon, nil, 1)
		p.Size = Vector3.new(radius * 0.65, 0.12, 0.6)
		table.insert(swirls, p)
	end

	-- Bubbling outer edge slime ring segments undulating around the puddle perimeter.
	local rimSegs: { Part } = {}
	for i = 1, 10 do
		local p = makeVfxPart(`ToxicRim_{i}`, Color3.fromRGB(130, 255, 55), Enum.Material.Neon, nil, 1)
		table.insert(rimSegs, p)
	end

	-- Rising & popping translucent toxic acid bubbles across the puddle.
	local bubbles: { ToxicBubble } = {}
	for i = 1, 9 do
		local c = if i % 3 == 0 then Color3.fromRGB(210, 255, 115) else Color3.fromRGB(135, 255, 58)
		local bPart = makeVfxPart(`ToxicBubble_{i}`, c, Enum.Material.Neon, Enum.PartType.Ball, 1)
		table.insert(bubbles, {
			part = bPart,
			angle = (i / 9) * math.pi * 2 + math.random() * 0.5,
			distFrac = 0.14 + math.random() * 0.72,
			speed = 0.85 + math.random() * 0.75,
			phase = math.random(),
			maxSize = 0.75 + math.random() * 0.85,
			maxRise = 1.1 + math.random() * 1.4,
		})
	end

	toxicPools[source] = {
		source = source,
		radius = radius,
		anchor = anchor,
		swirls = swirls,
		rimSegs = rimSegs,
		bubbles = bubbles,
		emitter = emitter,
	}
end

local function spawnToxicSplash(origin: Vector3, radius: number)
	local base = Vector3.new(origin.X, 0.35, origin.Z)
	-- Expanding hollow toxic splash rim (10 arc segments).
	local segCount = 10
	local arcLen = (2 * math.pi * radius) / segCount * 0.82
	for i = 1, segCount do
		local angle = (i / segCount) * math.pi * 2
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local seg = makeVfxPart("ToxicSplashRim", Color3.fromRGB(165, 255, 65), Enum.Material.Neon, nil, 0.15)
		local startPos = base + dir * 1.5
		local endPos = base + dir * (radius * 1.02)
		seg.Size = Vector3.new(1.4, 0.35, 0.75)
		seg.CFrame = CFrame.lookAt(startPos, startPos + dir)
		TweenService:Create(seg, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(arcLen, 0.14, 0.45),
			CFrame = CFrame.lookAt(endPos, endPos + dir),
			Transparency = 1,
		}):Play()
		Debris:AddItem(seg, 0.38)
	end

	-- 10 flying neon-green acid droplets arcing upward and splashing back into the pool.
	local t = os.clock()
	for i = 1, 10 do
		local angle = (i / 10) * math.pi * 2 + (math.random() - 0.5) * 0.4
		local spd = (0.65 + math.random() * 0.75) * radius * 1.45
		local up = 13 + math.random() * 10
		local drop = makeVfxPart(
			"ToxicDroplet",
			if i % 2 == 0 then Color3.fromRGB(195, 255, 85) else Color3.fromRGB(110, 245, 48),
			Enum.Material.Neon,
			Enum.PartType.Ball,
			0.1
		)
		local sz = 0.55 + math.random() * 0.55
		drop.Size = Vector3.one * sz
		drop.Position = base + Vector3.new(0, 0.5, 0)
		table.insert(ballistics, {
			part = drop,
			velocity = Vector3.new(math.cos(angle) * spd, up, math.sin(angle) * spd),
			gravity = 42,
			startedAt = t,
			duration = 0.45 + math.random() * 0.25,
			baseSize = Vector3.one * sz,
			stretch = false,
		})
	end
end

-- Multi-layered cinematic explosion for Detonante (`exploder`): blinding core flash + dynamic
-- light + fireball puffs + billowing dark smoke clouds + hollow ground shockwave rim + flying
-- incandescent shrapnel arcs + rising ember ash burst.
local function spawnExplosion(origin: Vector3, blastRadius: number, accentColor: Color3?)
	local center = Vector3.new(origin.X, math.max(origin.Y, 1.4), origin.Z)
	local floorBase = Vector3.new(origin.X, 0.32, origin.Z)
	local hotColor = accentColor or Color3.fromRGB(255, 118, 36)
	local t = os.clock()

	-- 1. Blinding white-gold detonation core + brief arena PointLight flash.
	local core = makeVfxPart("ExploderCoreFlash", Color3.fromRGB(255, 250, 215), Enum.Material.Neon, Enum.PartType.Ball, 0.0)
	core.Size = Vector3.one * 2.2
	core.Position = center
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 168, 62)
	light.Range = math.max(blastRadius * 2.6, 36)
	light.Brightness = 5.5
	light.Shadows = false
	light.Parent = core
	TweenService:Create(core, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * (blastRadius * 1.15),
		Transparency = 1,
	}):Play()
	TweenService:Create(light, TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
	}):Play()
	Debris:AddItem(core, 0.3)

	-- 2. Staggered inner fiery fireball puffs expanding rapidly outward.
	for i = 1, 4 do
		local a = (i / 4) * math.pi * 2 + math.random() * 0.8
		local rOff = blastRadius * (0.18 + math.random() * 0.2)
		local startPos = center + Vector3.new(math.cos(a) * 1.2, (math.random() - 0.3) * 1.4, math.sin(a) * 1.2)
		local endPos = center + Vector3.new(math.cos(a) * rOff, 2.2 + math.random() * 2.8, math.sin(a) * rOff)
		local puff = makeVfxPart(
			"ExploderFireball",
			if i % 2 == 0 then Color3.fromRGB(255, 175, 45) else hotColor,
			Enum.Material.Neon,
			Enum.PartType.Ball,
			0.12
		)
		puff.Size = Vector3.one * (blastRadius * 0.26)
		puff.Position = startPos
		local targetDiam = blastRadius * (0.68 + math.random() * 0.32)
		local dur = 0.32 + math.random() * 0.16
		TweenService:Create(puff, TweenInfo.new(dur, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = Vector3.one * targetDiam,
			Position = endPos,
			Color = Color3.fromRGB(165, 42, 16),
			Transparency = 1,
		}):Play()
		Debris:AddItem(puff, dur + 0.06)
	end

	-- 3. Billowing dark smoke clouds rolling outward and rising from the blast.
	for i = 1, 7 do
		local a = (i / 7) * math.pi * 2 + (math.random() - 0.5) * 0.45
		local rEnd = blastRadius * (0.42 + math.random() * 0.36)
		local startPos = floorBase + Vector3.new(math.cos(a) * 1.5, 0.8, math.sin(a) * 1.5)
		local endPos = floorBase + Vector3.new(math.cos(a) * rEnd, 3.8 + math.random() * 4.5, math.sin(a) * rEnd)
		local smoke = makeVfxPart(
			"ExploderSmoke",
			if i % 3 == 0 then Color3.fromRGB(95, 52, 34) else Color3.fromRGB(48, 44, 48),
			Enum.Material.SmoothPlastic,
			Enum.PartType.Ball,
			0.22
		)
		smoke.Size = Vector3.one * (blastRadius * 0.22)
		smoke.Position = startPos
		local targetDiam = blastRadius * (0.55 + math.random() * 0.35)
		local dur = 0.52 + math.random() * 0.32
		TweenService:Create(smoke, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.one * targetDiam,
			Position = endPos,
			Color = Color3.fromRGB(26, 26, 30),
			Transparency = 1,
		}):Play()
		Debris:AddItem(smoke, dur + 0.08)
	end

	-- 4. Hollow segmented ground shockwave ring racing across the floor to blastRadius.
	local segCount = 12
	local segWidth = (2 * math.pi * blastRadius) / segCount * 0.86
	for i = 1, segCount do
		local angle = (i / segCount) * math.pi * 2
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local startPos = floorBase + dir * 1.4
		local endPos = floorBase + dir * blastRadius
		local rim = makeVfxPart("ExploderShockRim", Color3.fromRGB(255, 195, 72), Enum.Material.Neon, nil, 0.1)
		rim.Size = Vector3.new(1.5, 0.55, 0.9)
		rim.CFrame = CFrame.lookAt(startPos, startPos + dir)
		TweenService:Create(rim, TweenInfo.new(0.34, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = Vector3.new(segWidth, 0.14, 0.55),
			CFrame = CFrame.lookAt(endPos, endPos + dir),
			Color = Color3.fromRGB(255, 72, 28),
			Transparency = 1,
		}):Play()
		Debris:AddItem(rim, 0.4)
	end

	-- 5. 12 incandescent flying shrapnel / spark streaks launched in 3D ballistic arcs.
	for i = 1, 12 do
		local angle = (i / 12) * math.pi * 2 + (math.random() - 0.5) * 0.45
		local horizSpeed = (1.6 + math.random() * 1.8) * math.max(blastRadius, 10)
		local upSpeed = 16 + math.random() * 20
		local spark = makeVfxPart(
			"ExploderShrapnel",
			if i % 2 == 0 then Color3.fromRGB(255, 240, 140) else Color3.fromRGB(255, 115, 35),
			Enum.Material.Neon,
			nil,
			0.05
		)
		local baseSz = Vector3.new(0.28, 0.28, 1.55)
		spark.Size = baseSz
		spark.Position = center
		table.insert(ballistics, {
			part = spark,
			velocity = Vector3.new(math.cos(angle) * horizSpeed, upSpeed, math.sin(angle) * horizSpeed),
			gravity = 56,
			startedAt = t,
			duration = 0.42 + math.random() * 0.3,
			baseSize = baseSz,
			stretch = true,
		})
	end

	-- 6. One-shot rising glowing ember & ash burst.
	local emitterHost = makeVfxPart("ExploderEmberHost", hotColor, Enum.Material.SmoothPlastic, nil, 1)
	emitterHost.Size = Vector3.new(2, 1, 2)
	emitterHost.Position = center
	local embers = Instance.new("ParticleEmitter")
	embers.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 140)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 110, 32)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 36, 40)),
	})
	embers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	embers.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	embers.Lifetime = NumberRange.new(0.45, 0.9)
	embers.Speed = NumberRange.new(10, 26)
	embers.SpreadAngle = Vector2.new(85, 85)
	embers.Acceleration = Vector3.new(0, -18, 0)
	embers.LightEmission = 0.85
	embers.Enabled = false
	embers.Parent = emitterHost
	embers:Emit(22)
	Debris:AddItem(emitterHost, 1.1)
end

local function detachEnemy(inst: Instance)
	if inst:IsA("BasePart") then
		detachToxicPool(inst)
		return
	end
	if not inst:IsA("Model") then
		return
	end
	local rig = rigs[inst]
	if rig then
		if rig.spinRing then
			rig.spinRing:Destroy()
			rig.spinRing = nil
		end
		destroyPartList(rig.spinTrails)
		rig.spinTrails = nil
		destroyPartList(rig.spinSparks)
		rig.spinSparks = nil
		destroyPartList(rig.spinRimSegs)
		rig.spinRimSegs = nil
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
		if rig.slamOuter then
			rig.slamOuter:Destroy()
			rig.slamOuter = nil
		end
		if rig.slamInner then
			rig.slamInner:Destroy()
			rig.slamInner = nil
		end
		destroyPartList(rig.bossConeArc)
		rig.bossConeArc = nil
		if rig.bossLeapOuter then
			rig.bossLeapOuter:Destroy()
			rig.bossLeapOuter = nil
		end
		if rig.bossLeapInner then
			rig.bossLeapInner:Destroy()
			rig.bossLeapInner = nil
		end
		if rig.bossNovaRing then
			rig.bossNovaRing:Destroy()
			rig.bossNovaRing = nil
		end
		if rig.alertGui then
			rig.alertGui:Destroy()
			rig.alertGui = nil
		end
		destroyPartList(rig.stunOrbs)
		rig.stunOrbs = nil
		if rig.contactAura then
			rig.contactAura:Destroy()
			rig.contactAura = nil
		end
		destroyPartList(rig.contactArcs)
		rig.contactArcs = nil
		destroyPartList(rig.contactBolts)
		rig.contactBolts = nil
		destroyPartList(rig.contactSparks)
		rig.contactSparks = nil
		destroyPartList(rig.contactRingSegs)
		rig.contactRingSegs = nil
		if rig.contactLight and rig.contactLight.Parent then
			rig.contactLight:Destroy()
		end
		rig.contactLight = nil
		if rig.bossSweepBeam then
			rig.bossSweepBeam:Destroy()
			rig.bossSweepBeam = nil
		end
		if rig.bossDashLine then
			rig.bossDashLine:Destroy()
			rig.bossDashLine = nil
		end
		for _, conn in ipairs(rig.connections) do
			conn:Disconnect()
		end
		rigs[inst] = nil
	end
end

local function attachEnemy(inst: Instance)
	if inst:IsA("BasePart") and (inst.Name == "AreaHazardOuter" or inst:GetAttribute("HazardZone") == true) then
		attachToxicPool(inst)
		return
	end
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
			lastHitCount = 0,
			hitstunStartedAt = -math.huge,
			spinRing = nil,
			spinTrails = nil,
			spinSparks = nil,
			spinRimSegs = nil,
			beamGuide = nil,
			beamOrb = nil,
			parryGlint = nil,
			slamOuter = nil,
			slamInner = nil,
			bossConeArc = nil,
			bossLeapOuter = nil,
			bossLeapInner = nil,
			bossNovaRing = nil,
			alertGui = nil,
			stunOrbs = nil,
			contactAura = nil,
			contactArcs = nil,
			contactBolts = nil,
			contactSparks = nil,
			contactRingSegs = nil,
			contactLight = nil,
			nextBoltReseedAt = 0,
			boltSeeds = {},
			bossSweepBeam = nil,
			bossDashLine = nil,
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

-- Overhead yellow warning triangle with exclamation mark (`!`) shown above the head of grabbers
-- and single-sword Paso Fantasma units when activating their abilities.
local function createAlertGui(body: BasePart): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "EnemyAlertIcon"
	gui.Size = UDim2.fromOffset(56, 56)
	gui.StudsOffset = Vector3.new(0, body.Size.Y / 2 + 3.4, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = body
	gui.LightInfluence = 0

	local outline = Instance.new("TextLabel")
	outline.Name = "TriangleOutline"
	outline.AnchorPoint = Vector2.new(0.5, 0.5)
	outline.Position = UDim2.fromScale(0.5, 0.5)
	outline.Size = UDim2.fromScale(1, 1)
	outline.BackgroundTransparency = 1
	outline.Font = Enum.Font.GothamBold
	outline.Text = "▲"
	outline.TextSize = 54
	outline.TextColor3 = Color3.fromRGB(22, 24, 30)
	outline.ZIndex = 1
	outline.Parent = gui

	local fill = Instance.new("TextLabel")
	fill.Name = "TriangleFill"
	fill.AnchorPoint = Vector2.new(0.5, 0.5)
	fill.Position = UDim2.fromScale(0.5, 0.51)
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundTransparency = 1
	fill.Font = Enum.Font.GothamBold
	fill.Text = "▲"
	fill.TextSize = 44
	fill.TextColor3 = Color3.fromRGB(255, 212, 38)
	fill.ZIndex = 2
	fill.Parent = gui

	local mark = Instance.new("TextLabel")
	mark.Name = "Exclamation"
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Position = UDim2.fromScale(0.5, 0.57)
	mark.Size = UDim2.fromScale(0.6, 0.6)
	mark.BackgroundTransparency = 1
	mark.Font = Enum.Font.GothamBlack
	mark.Text = "!"
	mark.TextSize = 24
	mark.TextColor3 = Color3.fromRGB(20, 22, 28)
	mark.ZIndex = 3
	mark.Parent = gui

	gui.Parent = body
	return gui
end

local PHANTOM_STEP_COLORS = {
	Color3.fromRGB(55, 235, 255),
	Color3.fromRGB(85, 255, 145),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(255, 65, 190),
}

-- Spawns a Paso Fantasma (Phantom Step) neon afterimage silhouette of the enemy's current pose in
-- `_EnemyCorpses` so target-locking never selects afterimages.
local function spawnPhantomStepGhost(model: Model, tint: Color3)
	local ghost = Instance.new("Model")
	ghost.Name = "PhantomStepGhost"
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
			copy.Transparency = 0.42
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

-- Renders the heavy Mace seismic ground-slam shockwave: expanding shock rings + tumbling
-- dark-stone/amber floor debris in `_EnemyCorpses`.
local function spawnSlamShockwave(origin: Vector3, radius: number)
	local parent = getCorpseFolder()
	local floorY = 0.25
	local diameter = radius * 2

	local outer = Instance.new("Part")
	outer.Name = "MaceSlamShockwave"
	outer.Shape = Enum.PartType.Cylinder
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.CastShadow = false
	outer.Material = Enum.Material.Neon
	outer.Color = Color3.fromRGB(255, 145, 45)
	outer.Transparency = 0.16
	outer.Size = Vector3.new(0.45, 4, 4)
	outer.CFrame = CFrame.new(origin.X, floorY, origin.Z) * CFrame.Angles(0, 0, math.rad(90))
	outer.Parent = parent
	TweenService:Create(
		outer,
		TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.25, diameter, diameter), Transparency = 1 }
	):Play()
	Debris:AddItem(outer, 0.4)

	local core = Instance.new("Part")
	core.Name = "MaceSlamCore"
	core.Shape = Enum.PartType.Cylinder
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.CastShadow = false
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(255, 235, 160)
	core.Transparency = 0.08
	core.Size = Vector3.new(0.55, 3, 3)
	core.CFrame = CFrame.new(origin.X, floorY + 0.1, origin.Z) * CFrame.Angles(0, 0, math.rad(90))
	core.Parent = parent
	TweenService:Create(
		core,
		TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.18, radius * 1.15, radius * 1.15), Transparency = 1 }
	):Play()
	Debris:AddItem(core, 0.28)

	local chunkCount = 10
	for i = 1, chunkCount do
		local angle = (i / chunkCount) * math.pi * 2 + (math.random() - 0.5) * 0.35
		local dirX, dirZ = math.cos(angle), math.sin(angle)
		local rStart = 2.0 + math.random() * 1.5
		local rEnd = radius * (0.55 + math.random() * 0.42)
		local peakY = 2.4 + math.random() * 2.2
		local chunk = Instance.new("Part")
		chunk.Name = "MaceSlamDebris"
		chunk.Anchored = true
		chunk.CanCollide = false
		chunk.CanQuery = false
		chunk.CanTouch = false
		chunk.CastShadow = false
		chunk.Material = if i % 3 == 0 then Enum.Material.Neon else Enum.Material.Concrete
		chunk.Color = if i % 3 == 0 then Color3.fromRGB(255, 165, 55) else Color3.fromRGB(78, 82, 92)
		local s = 0.65 + math.random() * 0.65
		chunk.Size = Vector3.new(s, s * 0.75, s * 1.1)
		local startPos = Vector3.new(origin.X + dirX * rStart, 0.4, origin.Z + dirZ * rStart)
		local peakPos = Vector3.new(origin.X + dirX * (rEnd * 0.6), peakY, origin.Z + dirZ * (rEnd * 0.6))
		local endPos = Vector3.new(origin.X + dirX * rEnd, 0.25, origin.Z + dirZ * rEnd)
		chunk.CFrame = CFrame.new(startPos) * CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3)
		chunk.Parent = parent

		local spinCf = CFrame.Angles(math.random() * 4, math.random() * 4, math.random() * 4)
		TweenService:Create(
			chunk,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.new(peakPos) * spinCf }
		):Play()
		task.delay(0.22, function()
			if chunk.Parent then
				TweenService:Create(
					chunk,
					TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ CFrame = CFrame.new(endPos) * spinCf * spinCf, Transparency = 1 }
				):Play()
			end
		end)
		Debris:AddItem(chunk, 0.54)
	end
end

-- Renders the devastating rail-beam discharge using smooth cylindrical plasma beams + expanding
-- barrel shock rings (zero rectangular blocks).
local function spawnBeamBlast(origin: Vector3, direction: Vector3, length: number)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 or length <= 0 then
		return
	end
	local unit = flat.Unit
	local mid = origin + unit * (length * 0.5)
	-- Roblox Cylinders extend along local +X; rotating +90 deg around Y aligns +X with forward (-Z).
	local cylOrient = CFrame.lookAt(mid, mid + unit) * CFrame.Angles(0, math.rad(90), 0)
	local parent = getCorpseFolder()

	local core = Instance.new("Part")
	core.Name = "RailBeamCore"
	core.Shape = Enum.PartType.Cylinder
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.CastShadow = false
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(235, 252, 255)
	core.Transparency = 0
	core.Size = Vector3.new(length, 1.85, 1.85)
	core.CFrame = cylOrient
	core.Parent = parent
	TweenService:Create(
		core,
		TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(length, 0.12, 0.12), Transparency = 1 }
	):Play()
	Debris:AddItem(core, 0.46)

	local outer = Instance.new("Part")
	outer.Name = "RailBeamHalo"
	outer.Shape = Enum.PartType.Cylinder
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.CastShadow = false
	outer.Material = Enum.Material.Neon
	outer.Color = Color3.fromRGB(55, 215, 255)
	outer.Transparency = 0.28
	outer.Size = Vector3.new(length, 4.0, 4.0)
	outer.CFrame = cylOrient
	outer.Parent = parent
	TweenService:Create(
		outer,
		TweenInfo.new(0.44, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(length, 5.8, 5.8), Transparency = 1 }
	):Play()
	Debris:AddItem(outer, 0.48)

	-- Twin plasma shock-rings expanding perpendicular to the rail-beam muzzle.
	for i = 1, 2 do
		local ringPos = origin + unit * (2.5 + i * 3.5)
		local ring = Instance.new("Part")
		ring.Name = "RailBeamRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.CastShadow = false
		ring.Material = Enum.Material.Neon
		ring.Color = if i == 1 then Color3.fromRGB(200, 250, 255) else Color3.fromRGB(70, 225, 255)
		ring.Transparency = 0.2
		ring.Size = Vector3.new(0.35, 2.2, 2.2)
		ring.CFrame = CFrame.lookAt(ringPos, ringPos + unit) * CFrame.Angles(0, math.rad(90), 0)
		ring.Parent = parent
		local endPos = ringPos + unit * (6 + i * 4)
		TweenService:Create(
			ring,
			TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				Size = Vector3.new(0.18, 6.5 + i * 1.8, 6.5 + i * 1.8),
				CFrame = CFrame.lookAt(endPos, endPos + unit) * CFrame.Angles(0, math.rad(90), 0),
				Transparency = 1,
			}
		):Play()
		Debris:AddItem(ring, 0.36)
	end

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
	flash.Size = Vector3.one * 3.2
	flash.Position = origin + unit * 2
	flash.Parent = parent
	TweenService:Create(
		flash,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * 7.0, Transparency = 1 }
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

		local hitCountAttr = model:GetAttribute("HitCount")
		local hitCount = if type(hitCountAttr) == "number" then hitCountAttr else 0
		if hitCount ~= rig.lastHitCount then
			rig.lastHitCount = hitCount
			rig.hitstunStartedAt = clock
		end

		local targetPose: EnemyAnim.LimbPose
		local strikeElapsed = clock - rig.strikeStartedAt
		local fireElapsed = clock - rig.fireStartedAt
		local stunnedUntil = model:GetAttribute("StunnedUntil")
		local isStunned = phase == "stunned" or (type(stunnedUntil) == "number" and serverNow < stunnedUntil)
		if isStunned then
			targetPose = EnemyAnim.stunPose(clock)
		elseif phase == "bossConeWindup" then
			targetPose = EnemyAnim.bossConeWindupPose(phaseProgress, clock)
		elseif phase == "bossLeapWindup" then
			targetPose = EnemyAnim.bossLeapWindupPose(phaseProgress, clock)
		elseif phase == "bossLeap" then
			targetPose = EnemyAnim.bossLeapAirPose(phaseProgress)
		elseif phase == "bossNovaWindup" then
			targetPose = EnemyAnim.bossNovaWindupPose(phaseProgress, clock)
		elseif phase == "myDashWindup" or phase == "myBladesWindup" then
			targetPose = EnemyAnim.bossMyDashWindupPose(phaseProgress, clock)
		elseif phase == "myDash" then
			targetPose = EnemyAnim.bossMyDashPose()
		elseif phase == "mySweepWindup" or phase == "mySweep" then
			targetPose = EnemyAnim.bossMySweepPose(clock)
		elseif phase == "gonRainWindup" or phase == "gonGravityWindup" or phase == "gonGravity" or phase == "gonRingsWindup" then
			targetPose = EnemyAnim.bossGonChannelPose(phaseProgress, clock)
		elseif phase == "bossPhaseShift" then
			targetPose = EnemyAnim.bossPhaseShiftPose(phaseProgress, clock)
		elseif phase == "holding" then
			targetPose = EnemyAnim.grabHoldPose(clock)
		elseif phase == "hitstun" then
			local stunDur = if type(duration) == "number" and duration > 0 then duration else Config.ENEMY_HITSTUN_LIGHT
			local stunU = math.clamp((clock - rig.hitstunStartedAt) / math.max(stunDur, 0.1), 0, 1)
			targetPose = EnemyAnim.hitstunPose(stunU, hitCount)
		elseif phase == "spin" then
			targetPose = EnemyAnim.spinPose(clock)
		elseif phase == "phantomStep" then
			targetPose = EnemyAnim.phantomStepPose()
		elseif phase == "slamWindup" then
			targetPose = EnemyAnim.slamWindupPose(phaseProgress, clock)
		elseif phase == "axeThrowWindup" then
			targetPose = EnemyAnim.axeThrowWindupPose(phaseProgress, clock)
		elseif phase == "axeRetrieve" then
			targetPose = EnemyAnim.axeRetrievePose(rig.walkPhase)
		elseif phase == "evade" then
			targetPose = EnemyAnim.evadeJumpPose(phaseProgress)
		elseif phase == "beamCharge" then
			targetPose = EnemyAnim.beamChargePose(clock, phaseProgress)
		elseif phase == "lunge" then
			targetPose = EnemyAnim.grabLungePose()
		elseif phase == "rushWindup" then
			targetPose = EnemyAnim.rushWindupPose(phaseProgress, clock)
		elseif phase == "rush" then
			targetPose = EnemyAnim.rushPose(clock)
		elseif phase == "fuse" then
			targetPose = EnemyAnim.fusePose(clock, phaseProgress)
		elseif phase == "areaWindup" then
			targetPose = EnemyAnim.areaWindupPose(phaseProgress, clock)
		elseif phase == "contactWindup" then
			targetPose = EnemyAnim.contactWindupPose(phaseProgress, clock)
		elseif phase == "contactActive" then
			targetPose = EnemyAnim.contactActivePose(rig.walkPhase, clock)
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
					line.Shape = Enum.PartType.Cylinder
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
					local thickness = if locked then 0.42 + 0.16 * math.abs(math.sin(clock * 36)) else 0.22 + phaseProgress * 0.2
					guide.Size = Vector3.new(range, thickness, thickness)
					guide.CFrame = CFrame.lookAt(mid, mid + unit) * CFrame.Angles(0, math.rad(90), 0)
					guide.Color = if locked then Color3.fromRGB(255, 70, 70) else Color3.fromRGB(90, 235, 255)
					guide.Transparency = if locked then 0.08 else 0.34 - phaseProgress * 0.2
				end
				if orb then
					local sz = 0.68 + phaseProgress * 1.45 + 0.2 * math.sin(clock * 28)
					orb.Size = Vector3.one * sz
					orb.Position = origin + unit * 3.8
					orb.Color = if locked then Color3.fromRGB(255, 120, 120) else Color3.fromRGB(160, 245, 255)
					orb.Transparency = 0.2
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

		-- Client-only seismic ground danger zone while a heavy Mace enemy winds up its ground slam.
		if phase == "slamWindup" then
			local radiusAttr = model:GetAttribute("SlamRadius")
			local slamDiameter = (if type(radiusAttr) == "number" and radiusAttr > 0 then radiusAttr else 15.5) * 2
			local outer = rig.slamOuter
			if not outer or not outer.Parent then
				local disc = Instance.new("Part")
				disc.Name = "MaceSlamOuter"
				disc.Shape = Enum.PartType.Cylinder
				disc.Anchored = true
				disc.CanCollide = false
				disc.CanQuery = false
				disc.CanTouch = false
				disc.CastShadow = false
				disc.Material = Enum.Material.Neon
				disc.Color = Color3.fromRGB(255, 115, 45)
				disc.Transparency = 0.72
				disc.Parent = getCorpseFolder()
				rig.slamOuter = disc
				outer = disc
			end
			local inner = rig.slamInner
			if not inner or not inner.Parent then
				local fill = Instance.new("Part")
				fill.Name = "MaceSlamInner"
				fill.Shape = Enum.PartType.Cylinder
				fill.Anchored = true
				fill.CanCollide = false
				fill.CanQuery = false
				fill.CanTouch = false
				fill.CastShadow = false
				fill.Material = Enum.Material.Neon
				fill.Color = Color3.fromRGB(255, 200, 65)
				fill.Transparency = 0.55
				fill.Parent = getCorpseFolder()
				rig.slamInner = fill
				inner = fill
			end
			if outer then
				outer.Size = Vector3.new(0.16, slamDiameter, slamDiameter)
				outer.CFrame = CFrame.new(pos.X, 0.16, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
				outer.Transparency = 0.74 - 0.14 * math.abs(math.sin(clock * 18))
			end
			if inner then
				local fillDiam = math.max(slamDiameter * phaseProgress, 1.5)
				inner.Size = Vector3.new(0.22, fillDiam, fillDiam)
				inner.CFrame = CFrame.new(pos.X, 0.22, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
				inner.Transparency = 0.62 - 0.3 * phaseProgress
			end
		else
			if rig.slamOuter then
				rig.slamOuter:Destroy()
				rig.slamOuter = nil
			end
			if rig.slamInner then
				rig.slamInner:Destroy()
				rig.slamInner = nil
			end
		end

		-- Dual-blade whirling sword-slash trails (2 opposing curved tapered crimson/white blade
		-- ribbons + tangential metallic sparks + subtle slim perimeter edge dashes for hitbox read).
		if phase == "spin" then
			local trails = rig.spinTrails
			if not trails then
				trails = {}
				for i = 1, 12 do
					local segIdx = ((i - 1) % 6) + 1
					local color = if segIdx == 1
						then Color3.fromRGB(255, 235, 245)
						elseif segIdx <= 3 then Color3.fromRGB(255, 58, 118)
						else Color3.fromRGB(185, 22, 72)
					table.insert(trails, makeVfxPart(`DualSpinTrail_{i}`, color, Enum.Material.Neon, nil, 0.1))
				end
				rig.spinTrails = trails
			end
			local sparks = rig.spinSparks
			if not sparks then
				sparks = {}
				for i = 1, 4 do
					local col = if i % 2 == 0 then Color3.fromRGB(255, 230, 145) else Color3.fromRGB(255, 110, 155)
					table.insert(sparks, makeVfxPart(`DualSpinSpark_{i}`, col, Enum.Material.Neon, nil, 0.15))
				end
				rig.spinSparks = sparks
			end
			local rimSegs = rig.spinRimSegs
			if not rimSegs then
				rimSegs = {}
				for i = 1, 10 do
					table.insert(rimSegs, makeVfxPart(`DualSpinRim_{i}`, Color3.fromRGB(255, 65, 110), Enum.Material.Neon, nil, 0.68))
				end
				rig.spinRimSegs = rimSegs
			end

			local spinRadius = 7.4
			local baseAngle = clock * 19.5
			local segStep = math.rad(22)
			for bladeIdx = 0, 1 do
				local bladeBase = baseAngle + bladeIdx * math.pi
				local bladeY = pos.Y + (if bladeIdx == 0 then 0.25 else -0.25)
				local tiltDir = if bladeIdx == 0 then 1 else -1
				for seg = 1, 6 do
					local p = trails[bladeIdx * 6 + seg]
					if p and p.Parent then
						local a0 = bladeBase - (seg - 1) * segStep
						local a1 = bladeBase - seg * segStep
						local frac = (seg - 1) / 5
						local rOuter = spinRadius * (1.0 - frac * 0.16)
						local y0 = bladeY + math.sin(a0) * 0.45 * tiltDir
						local y1 = bladeY + math.sin(a1) * 0.45 * tiltDir
						local pt0 = Vector3.new(pos.X + math.cos(a0) * rOuter, y0, pos.Z + math.sin(a0) * rOuter)
						local pt1 = Vector3.new(pos.X + math.cos(a1) * rOuter, y1, pos.Z + math.sin(a1) * rOuter)
						local mid = (pt0 + pt1) * 0.5
						local chord = (pt1 - pt0).Magnitude
						local ribbonWidth = 1.65 * (1 - frac * 0.72)
						local ribbonHeight = 0.24 * (1 - frac * 0.55)
						p.Size = Vector3.new(ribbonWidth, ribbonHeight, math.max(chord * 1.12, 0.4))
						p.CFrame = CFrame.lookAt(mid, pt0) * CFrame.Angles(0, 0, math.rad(14 * tiltDir))
						p.Transparency = 0.08 + frac * 0.76
					end
				end
			end

			-- Tangential steel spark streaks spinning off the outer edge of the blades.
			for k, sp in ipairs(sparks) do
				if sp.Parent then
					local cycle = (clock * 3.8 + k * 0.25) % 1
					local a = baseAngle * 0.55 + k * (math.pi * 0.5) + cycle * 0.8
					local r = spinRadius * (0.88 + cycle * 0.32)
					local pt = Vector3.new(pos.X + math.cos(a) * r, pos.Y + (cycle - 0.5) * 1.2, pos.Z + math.sin(a) * r)
					local tangent = Vector3.new(-math.sin(a), 0.12, math.cos(a)).Unit
					sp.Size = Vector3.new(0.16, 0.16, 1.45 * (1 - cycle * 0.5))
					sp.CFrame = CFrame.lookAt(pt, pt + tangent)
					sp.Transparency = 0.15 + cycle * 0.82
				end
			end

			-- Subtle slim floor perimeter arcs (combined cleanly with blade trails so hitbox stays readable).
			local rimR = 7.75
			for k, seg in ipairs(rimSegs) do
				if seg.Parent then
					local a = -clock * 4.5 + (k / 10) * math.pi * 2
					local pt = Vector3.new(pos.X + math.cos(a) * rimR, 0.18, pos.Z + math.sin(a) * rimR)
					local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
					seg.Size = Vector3.new(0.28, 0.1, 2.3)
					seg.CFrame = CFrame.lookAt(pt, pt + tangent)
					seg.Transparency = 0.58 + 0.14 * math.sin(clock * 18 + k)
				end
			end
		else
			if rig.spinRing then
				rig.spinRing:Destroy()
				rig.spinRing = nil
			end
			if rig.spinTrails then
				destroyPartList(rig.spinTrails)
				rig.spinTrails = nil
			end
			if rig.spinSparks then
				destroyPartList(rig.spinSparks)
				rig.spinSparks = nil
			end
			if rig.spinRimSegs then
				destroyPartList(rig.spinRimSegs)
				rig.spinRimSegs = nil
			end
		end

		-- Boss Oh telegraphs: frontal cone smash fan, seismic leap red landing zone, and 360 nova charge ring.
		if phase == "bossConeWindup" then
			local dirAttr = model:GetAttribute("BossConeDir")
			local coneRange = model:GetAttribute("BossConeRange")
			local coneArc = model:GetAttribute("BossConeArc")
			if typeof(dirAttr) == "Vector3" and dirAttr.Magnitude > 1e-3 then
				local dir = Vector3.new(dirAttr.X, 0, dirAttr.Z).Unit
				local range = if type(coneRange) == "number" then coneRange else 24
				local halfArc = math.rad((if type(coneArc) == "number" then coneArc else 115) * 0.5)
				local fan = rig.bossConeArc
				if not fan then
					fan = {}
					for i = 1, 5 do
						local ray = Instance.new("Part")
						ray.Name = `BossConeGuide_{i}`
						ray.Anchored = true
						ray.CanCollide = false
						ray.CanQuery = false
						ray.CanTouch = false
						ray.CastShadow = false
						ray.Material = Enum.Material.Neon
						ray.Color = if i == 1 or i == 5 then Color3.fromRGB(255, 70, 50) else Color3.fromRGB(255, 155, 50)
						ray.Parent = getCorpseFolder()
						table.insert(fan, ray)
					end
					rig.bossConeArc = fan
				end
				for i, ray in ipairs(fan) do
					if ray.Parent then
						local frac = (i - 1) / 4
						local theta = -halfArc + frac * (halfArc * 2)
						local c, s = math.cos(theta), math.sin(theta)
						local rayDir = Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
						local len = range * (0.45 + 0.55 * phaseProgress)
						local mid = Vector3.new(pos.X, 0.18, pos.Z) + rayDir * (len * 0.5)
						ray.Size = Vector3.new(if i == 1 or i == 5 then 0.55 else 1.4, 0.14, len)
						ray.CFrame = CFrame.lookAt(mid, mid + rayDir)
						ray.Transparency = 0.68 - 0.38 * phaseProgress
					end
				end
			end
		elseif rig.bossConeArc then
			for _, p in ipairs(rig.bossConeArc) do
				if p.Parent then
					p:Destroy()
				end
			end
			rig.bossConeArc = nil
		end

		local leapTarget = model:GetAttribute("BossLeapTarget")
		if (phase == "bossLeapWindup" or phase == "bossLeap") and typeof(leapTarget) == "Vector3" then
			local radiusAttr = model:GetAttribute("BossLeapRadius")
			local leapDiam = (if type(radiusAttr) == "number" and radiusAttr > 0 then radiusAttr else 18) * 2
			local outer = rig.bossLeapOuter
			if not outer or not outer.Parent then
				local disc = Instance.new("Part")
				disc.Name = "BossLeapOuter"
				disc.Shape = Enum.PartType.Cylinder
				disc.Anchored = true
				disc.CanCollide = false
				disc.CanQuery = false
				disc.CanTouch = false
				disc.CastShadow = false
				disc.Material = Enum.Material.Neon
				disc.Color = Color3.fromRGB(255, 55, 65)
				disc.Transparency = 0.68
				disc.Parent = getCorpseFolder()
				rig.bossLeapOuter = disc
				outer = disc
			end
			local inner = rig.bossLeapInner
			if not inner or not inner.Parent then
				local fill = Instance.new("Part")
				fill.Name = "BossLeapInner"
				fill.Shape = Enum.PartType.Cylinder
				fill.Anchored = true
				fill.CanCollide = false
				fill.CanQuery = false
				fill.CanTouch = false
				fill.CastShadow = false
				fill.Material = Enum.Material.Neon
				fill.Color = Color3.fromRGB(255, 165, 65)
				fill.Transparency = 0.52
				fill.Parent = getCorpseFolder()
				rig.bossLeapInner = fill
				inner = fill
			end
			if outer then
				outer.Size = Vector3.new(0.18, leapDiam, leapDiam)
				outer.CFrame = CFrame.new(leapTarget.X, 0.16, leapTarget.Z) * CFrame.Angles(0, 0, math.rad(90))
				outer.Transparency = 0.72 - 0.16 * math.abs(math.sin(clock * 20))
			end
			if inner then
				local fillFrac = if phase == "bossLeapWindup" then phaseProgress * 0.45 else 0.45 + phaseProgress * 0.55
				local fillDiam = math.max(leapDiam * fillFrac, 2.5)
				inner.Size = Vector3.new(0.24, fillDiam, fillDiam)
				inner.CFrame = CFrame.new(leapTarget.X, 0.22, leapTarget.Z) * CFrame.Angles(0, 0, math.rad(90))
				inner.Transparency = 0.62 - 0.34 * fillFrac
			end
		else
			if rig.bossLeapOuter then
				rig.bossLeapOuter:Destroy()
				rig.bossLeapOuter = nil
			end
			if rig.bossLeapInner then
				rig.bossLeapInner:Destroy()
				rig.bossLeapInner = nil
			end
		end

		if phase == "bossNovaWindup" then
			local ring = rig.bossNovaRing
			if not ring or not ring.Parent then
				local disc = Instance.new("Part")
				disc.Name = "BossNovaCharge"
				disc.Shape = Enum.PartType.Cylinder
				disc.Anchored = true
				disc.CanCollide = false
				disc.CanQuery = false
				disc.CanTouch = false
				disc.CastShadow = false
				disc.Material = Enum.Material.Neon
				disc.Color = Color3.fromRGB(220, 85, 255)
				disc.Parent = getCorpseFolder()
				rig.bossNovaRing = disc
				ring = disc
			end
			if ring then
				local diam = 14 + 14 * (1 - phaseProgress) + math.sin(clock * 28) * 0.8
				ring.Size = Vector3.new(0.26, diam, diam)
				ring.CFrame = CFrame.new(pos.X, 0.24, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
				ring.Transparency = 0.65 - 0.35 * phaseProgress
			end
		elseif rig.bossNovaRing then
			rig.bossNovaRing:Destroy()
			rig.bossNovaRing = nil
		end

		-- Boss My / OhMyGon sweeping photonic laser beam & dash line telegraph.
		local sweepDir = model:GetAttribute("SweepDir")
		if (phase == "mySweepWindup" or phase == "mySweep") and typeof(sweepDir) == "Vector3" and sweepDir.Magnitude > 1e-3 then
			local beam = rig.bossSweepBeam
			if not beam or not beam.Parent then
				local p = Instance.new("Part")
				p.Name = "BossMySweepBeam"
				p.Shape = Enum.PartType.Cylinder
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.CastShadow = false
				p.Material = Enum.Material.Neon
				p.Parent = getCorpseFolder()
				rig.bossSweepBeam = p
				beam = p
			end
			if beam then
				local unit = Vector3.new(sweepDir.X, 0, sweepDir.Z).Unit
				local rangeAttr = model:GetAttribute("SweepRange")
				local range = if type(rangeAttr) == "number" and rangeAttr > 0 then rangeAttr else 42
				local active = phase == "mySweep" or model:GetAttribute("SweepActive") == true
				local thickness = if active then 2.2 + 0.35 * math.sin(clock * 32) else 0.32 + phaseProgress * 0.3
				local origin = Vector3.new(pos.X, 2.4, pos.Z)
				local mid = origin + unit * (range * 0.5)
				beam.Size = Vector3.new(range, thickness, thickness)
				beam.CFrame = CFrame.lookAt(mid, mid + unit) * CFrame.Angles(0, math.rad(90), 0)
				beam.Color = if active then Color3.fromRGB(85, 245, 255) else Color3.fromRGB(224, 78, 255)
				beam.Transparency = if active then 0.08 else 0.45 - 0.25 * phaseProgress
			end
		elseif rig.bossSweepBeam then
			rig.bossSweepBeam:Destroy()
			rig.bossSweepBeam = nil
		end

		local dashDir = model:GetAttribute("MyDashDir")
		if phase == "myDashWindup" and typeof(dashDir) == "Vector3" and dashDir.Magnitude > 1e-3 then
			local line = rig.bossDashLine
			if not line or not line.Parent then
				local p = Instance.new("Part")
				p.Name = "BossMyDashGuide"
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.CastShadow = false
				p.Material = Enum.Material.Neon
				p.Color = Color3.fromRGB(224, 78, 255)
				p.Parent = getCorpseFolder()
				rig.bossDashLine = p
				line = p
			end
			if line then
				local unit = Vector3.new(dashDir.X, 0, dashDir.Z).Unit
				local len = 26 * (0.4 + 0.6 * phaseProgress)
				local mid = Vector3.new(pos.X, 0.22, pos.Z) + unit * (len * 0.5)
				line.Size = Vector3.new(1.8, 0.14, len)
				line.CFrame = CFrame.lookAt(mid, mid + unit)
				line.Transparency = 0.68 - 0.38 * phaseProgress
			end
		elseif rig.bossDashLine then
			rig.bossDashLine:Destroy()
			rig.bossDashLine = nil
		end

		-- Voltaico (`contact`) jagged multi-segment lightning bolts + crackling ground spark nodes
		-- + slim dashed danger perimeter (real jagged electricity, never a flat solid neon circle).
		if phase == "contactWindup" or phase == "contactActive" then
			local radiusAttr = model:GetAttribute("ContactRadius")
			local contactRadius = if type(radiusAttr) == "number" and radiusAttr > 0 then radiusAttr else 5.5
			local isActive = phase == "contactActive"
			local boltCount = 5
			local segsPerBolt = 4

			local bolts = rig.contactBolts
			if not bolts then
				bolts = {}
				for i = 1, boltCount * segsPerBolt do
					table.insert(bolts, makeVfxPart(`VoltaicBolt_{i}`, Color3.fromRGB(90, 245, 255), Enum.Material.Neon, nil, 0.1))
				end
				rig.contactBolts = bolts
			end
			local sparks = rig.contactSparks
			if not sparks then
				sparks = {}
				for i = 1, boltCount do
					table.insert(sparks, makeVfxPart(`VoltaicSpark_{i}`, Color3.fromRGB(230, 252, 255), Enum.Material.Neon, Enum.PartType.Ball, 0.2))
				end
				rig.contactSparks = sparks
			end
			local ringSegs = rig.contactRingSegs
			if not ringSegs then
				ringSegs = {}
				for i = 1, 12 do
					table.insert(ringSegs, makeVfxPart(`VoltaicPerimeter_{i}`, Color3.fromRGB(70, 240, 255), Enum.Material.Neon, nil, 0.55))
				end
				rig.contactRingSegs = ringSegs
			end
			if not rig.contactLight or not rig.contactLight.Parent then
				local pl = Instance.new("PointLight")
				pl.Name = "VoltaicArcLight"
				pl.Color = Color3.fromRGB(85, 240, 255)
				pl.Range = contactRadius * 2.4
				pl.Brightness = 1.6
				pl.Shadows = false
				pl.Parent = rig.body
				rig.contactLight = pl
			end

			-- Re-seed sharp zig-zag lightning geometry ~18 times per second for authentic electric crackle.
			if clock >= rig.nextBoltReseedAt or #rig.boltSeeds ~= boltCount then
				rig.nextBoltReseedAt = clock + (if isActive then 0.055 else 0.085)
				table.clear(rig.boltSeeds)
				for b = 1, boltCount do
					table.insert(rig.boltSeeds, {
						angle = (b / boltCount) * math.pi * 2 + (math.random() - 0.5) * 0.95,
						distFrac = if isActive then (0.72 + math.random() * 0.34) else (0.32 + math.random() * 0.32),
						jitter1 = Vector3.new((math.random() - 0.5) * 2.6, (math.random() - 0.35) * 2.2, (math.random() - 0.5) * 2.6),
						jitter2 = Vector3.new((math.random() - 0.5) * 2.8, (math.random() - 0.45) * 1.9, (math.random() - 0.5) * 2.8),
						colorIdx = math.random(1, 3),
					})
				end
			end

			if rig.contactLight then
				rig.contactLight.Color = if isActive then Color3.fromRGB(90, 245, 255) else Color3.fromRGB(255, 232, 95)
				rig.contactLight.Brightness = if isActive then (2.2 + math.random() * 1.4) else (0.8 + phaseProgress * 1.1)
			end

			local originBody = Vector3.new(pos.X, pos.Y + 0.6, pos.Z)
			for b = 1, boltCount do
				local seed = rig.boltSeeds[b]
				local rEnd = contactRadius * seed.distFrac * (if isActive then 1 else (0.45 + 0.55 * phaseProgress))
				local endPt: Vector3
				local startPt: Vector3
				if isActive and b == boltCount then
					-- One perimeter-to-perimeter chain arc snapping horizontally around the outside.
					local s1 = rig.boltSeeds[1]
					local s2 = rig.boltSeeds[3]
					startPt = Vector3.new(pos.X + math.cos(s1.angle) * contactRadius * 0.92, 1.4, pos.Z + math.sin(s1.angle) * contactRadius * 0.92)
					endPt = Vector3.new(pos.X + math.cos(s2.angle) * contactRadius * 0.92, 1.4, pos.Z + math.sin(s2.angle) * contactRadius * 0.92)
				else
					startPt = originBody + Vector3.new(math.cos(seed.angle) * 0.9, (b % 2 - 0.5) * 0.9, math.sin(seed.angle) * 0.9)
					endPt = Vector3.new(pos.X + math.cos(seed.angle) * rEnd, if isActive then 0.35 else (1.2 + (b % 2) * 1.1), pos.Z + math.sin(seed.angle) * rEnd)
				end

				local p1 = startPt:Lerp(endPt, 0.28) + seed.jitter1 * (if isActive then 0.85 else 0.45)
				local p2 = startPt:Lerp(endPt, 0.56) + seed.jitter2 * (if isActive then 0.95 else 0.5)
				local p3 = startPt:Lerp(endPt, 0.82) - seed.jitter1 * (if isActive then 0.55 else 0.3)
				local pts = { startPt, p1, p2, p3, endPt }

				local boltColor = if not isActive
					then Color3.fromRGB(255, 232, 95)
					elseif seed.colorIdx == 1 then Color3.fromRGB(220, 252, 255)
					elseif seed.colorIdx == 2 then Color3.fromRGB(70, 242, 255)
					else Color3.fromRGB(255, 245, 120)
				local baseThick = if isActive then 0.24 else 0.15

				for s = 1, segsPerBolt do
					local segPart = bolts[(b - 1) * segsPerBolt + s]
					if segPart and segPart.Parent then
						positionSegment(segPart, pts[s], pts[s + 1], baseThick * (1.1 - s * 0.14))
						segPart.Color = boltColor
						segPart.Transparency = if isActive then 0.05 else 0.25
					end
				end

				local sp = sparks[b]
				if sp and sp.Parent then
					local sz = if isActive then (0.45 + math.random() * 0.55) else (0.25 + phaseProgress * 0.25)
					sp.Size = Vector3.one * sz
					sp.Position = endPt
					sp.Color = boltColor
					sp.Transparency = if isActive then 0.12 else 0.45
				end
			end

			-- Subtle slim dashed outer perimeter so the exact electric danger range stays legible.
			local perimR = contactRadius * (if isActive then 1 else (0.5 + 0.5 * phaseProgress))
			for k, seg in ipairs(ringSegs) do
				if seg.Parent then
					local a = clock * (if isActive then 3.2 else 1.6) + (k / 12) * math.pi * 2
					local pt = Vector3.new(pos.X + math.cos(a) * perimR, 0.16, pos.Z + math.sin(a) * perimR)
					local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
					seg.Size = Vector3.new(0.22, 0.1, if isActive then 1.35 else 0.9)
					seg.CFrame = CFrame.lookAt(pt, pt + tangent)
					seg.Color = if isActive then Color3.fromRGB(75, 245, 255) else Color3.fromRGB(255, 228, 85)
					seg.Transparency = if isActive then (0.42 + 0.22 * math.sin(clock * 26 + k)) else (0.7 - 0.25 * phaseProgress)
				end
			end
		else
			if rig.contactAura then
				rig.contactAura:Destroy()
				rig.contactAura = nil
			end
			if rig.contactArcs then
				destroyPartList(rig.contactArcs)
				rig.contactArcs = nil
			end
			if rig.contactBolts then
				destroyPartList(rig.contactBolts)
				rig.contactBolts = nil
			end
			if rig.contactSparks then
				destroyPartList(rig.contactSparks)
				rig.contactSparks = nil
			end
			if rig.contactRingSegs then
				destroyPartList(rig.contactRingSegs)
				rig.contactRingSegs = nil
			end
			if rig.contactLight and rig.contactLight.Parent then
				rig.contactLight:Destroy()
			end
			rig.contactLight = nil
		end

		-- Overhead yellow warning triangle (`!`) for Grabber and single-sword Paso Fantasma abilities.
		if model:GetAttribute("AlertIcon") == true then
			local alert = rig.alertGui
			if not alert or not alert.Parent then
				alert = createAlertGui(rig.body)
				rig.alertGui = alert
			end
			if alert then
				local baseY = rig.body.Size.Y / 2 + 3.4
				alert.StudsOffset = Vector3.new(0, baseY + 0.32 * math.abs(math.sin(clock * 14)), 0)
			end
		elseif rig.alertGui then
			rig.alertGui:Destroy()
			rig.alertGui = nil
		end

		-- Spinning golden stun halo (3 orbiting stars above head) while stunned.
		if isStunned then
			local orbs = rig.stunOrbs
			if not orbs then
				orbs = {}
				for i = 1, 3 do
					local star = Instance.new("Part")
					star.Name = "EnemyStunStar"
					star.Shape = Enum.PartType.Ball
					star.Anchored = true
					star.CanCollide = false
					star.CanQuery = false
					star.CanTouch = false
					star.CastShadow = false
					star.Material = Enum.Material.Neon
					star.Color = if i == 1 then Color3.fromRGB(255, 240, 120) else Color3.fromRGB(255, 195, 45)
					star.Transparency = 0.1
					star.Size = Vector3.one * 0.48
					star.Parent = getCorpseFolder()
					table.insert(orbs, star)
				end
				rig.stunOrbs = orbs
			end
			local haloY = pos.Y + rig.body.Size.Y / 2 + 1.45
			local orbitR = math.max(rig.body.Size.X * 0.45, 1.35)
			for i, star in ipairs(orbs) do
				if star.Parent then
					local angle = clock * 5.2 + (i - 1) * (math.pi * 2 / 3)
					local bob = math.sin(clock * 9 + i) * 0.14
					star.Position = Vector3.new(
						pos.X + math.cos(angle) * orbitR,
						haloY + bob,
						pos.Z + math.sin(angle) * orbitR
					)
				end
			end
		elseif rig.stunOrbs then
			for _, orb in ipairs(rig.stunOrbs) do
				if orb.Parent then
					orb:Destroy()
				end
			end
			rig.stunOrbs = nil
		end

		-- Hide every part of the axe enemy's in-hand battle-axe while its thrown axe is flying or
		-- embedded in the floor (prefix match covers all detailed weapon parts automatically).
		if rig.weapon == "axe" then
			local axeHidden = model:GetAttribute("AxeThrown") == true
			local targetAlpha = if axeHidden then 1 else 0
			for _, child in ipairs(model:GetChildren()) do
				if child:IsA("BasePart") and child.Name:sub(1, 3) == "Axe" and child.Transparency ~= targetAlpha then
					child.Transparency = targetAlpha
				end
			end
		end

		-- Instant snap during high-speed spin, Paso Fantasma dash, or initial ranged recoil punch
		-- so fast kickback and dashes never blur out.
		if phase == "spin" or phase == "phantomStep" or (fireElapsed >= 0 and fireElapsed < 0.09) then
			rig.currentPose = targetPose
		else
			rig.currentPose = EnemyAnim.blend(rig.currentPose, targetPose, blendRate)
		end
		applyPose(rig.joints, rig.currentPose)

		-- Paso Fantasma neon afterimage trail sampled rapidly after posing limbs.
		if phase == "phantomStep" and clock - rig.lastAfterimageAt >= 0.042 then
			rig.lastAfterimageAt = clock
			rig.afterimageIndex = (rig.afterimageIndex % #PHANTOM_STEP_COLORS) + 1
			spawnPhantomStepGhost(model, PHANTOM_STEP_COLORS[rig.afterimageIndex])
		end

		-- Vivid pulsing parry-only glint while the Paso Fantasma finisher is winding up.
		if model:GetAttribute("ParryTelegraph") == true then
			local glint = rig.parryGlint
			if not glint or not glint.Parent then
				local flare = Instance.new("Part")
				flare.Name = "PhantomStepParryGlint"
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
				local pulse = 1.2 + 0.75 * math.abs(math.sin(clock * 32))
				glint.Size = Vector3.one * pulse
				glint.Color = if math.sin(clock * 36) > 0
					then Color3.fromRGB(70, 245, 255)
					else Color3.fromRGB(255, 230, 85)
				glint.Transparency = 0.2
				glint.Position = pos + Vector3.new(0, 2.2, 0) + rig.body.CFrame.LookVector * 1.4
			end
		elseif rig.parryGlint then
			rig.parryGlint:Destroy()
			rig.parryGlint = nil
		end
	end

	-- Animate active Artillero / Gon bubbling swirling toxic pools on the floor.
	for source, pool in pairs(toxicPools) do
		if not source.Parent then
			detachToxicPool(source)
			continue
		end
		local active = source:GetAttribute("HazardActive") == true
		local fadeAttr = source:GetAttribute("HazardFade")
		local fade = if type(fadeAttr) == "number" then math.clamp(fadeAttr, 0, 1) else 0
		pool.emitter.Enabled = active and fade < 0.75

		local center = source.Position
		local radius = pool.radius
		if not active then
			for _, p in ipairs(pool.swirls) do
				p.Transparency = 1
			end
			for _, p in ipairs(pool.rimSegs) do
				p.Transparency = 1
			end
			for _, b in ipairs(pool.bubbles) do
				b.part.Transparency = 1
			end
		else
			-- Counter-rotating organic toxic currents churning across the acid puddle.
			for i, p in ipairs(pool.swirls) do
				if p.Parent then
					local dirSign = if i % 2 == 0 then 1 else -1
					local a = clock * (1.3 + (i % 3) * 0.35) * dirSign + i * 1.05
					local ringR = radius * (0.28 + ((i - 1) % 3) * 0.24)
					local pt = Vector3.new(center.X + math.cos(a) * ringR, 0.24, center.Z + math.sin(a) * ringR)
					local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
					local waveLen = radius * (0.42 + 0.14 * math.sin(clock * 4.5 + i))
					p.Size = Vector3.new(0.55 + 0.2 * math.sin(clock * 6 + i), 0.12, waveLen)
					p.CFrame = CFrame.lookAt(pt, pt + tangent)
					p.Transparency = 0.42 + 0.58 * fade
				end
			end

			-- Undulating toxic edge rim around the puddle perimeter.
			local rimLen = (2 * math.pi * radius) / #pool.rimSegs * 0.78
			for i, p in ipairs(pool.rimSegs) do
				if p.Parent then
					local a = clock * 0.55 + (i / #pool.rimSegs) * math.pi * 2
					local wobble = radius * (0.96 + 0.04 * math.sin(clock * 5.2 + i * 1.4))
					local pt = Vector3.new(center.X + math.cos(a) * wobble, 0.22, center.Z + math.sin(a) * wobble)
					local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
					p.Size = Vector3.new(0.45, 0.14, rimLen)
					p.CFrame = CFrame.lookAt(pt, pt + tangent)
					p.Transparency = 0.35 + 0.65 * fade
				end
			end

			-- Rising, swelling, and popping acid bubbles across the puddle.
			for _, b in ipairs(pool.bubbles) do
				if b.part.Parent then
					local u = (clock * b.speed + b.phase) % 1
					local popAlpha = if u > 0.82 then (u - 0.82) / 0.18 else 0
					local grow = math.sin(math.min(u / 0.82, 1) * math.pi * 0.5)
					local diam = math.max(b.maxSize * (0.25 + 0.75 * grow) * (1 + popAlpha * 0.45), 0.15)
					local r = radius * b.distFrac
					local drift = clock * 0.35 + b.angle
					local bx = center.X + math.cos(drift) * r + math.sin(clock * 5 + b.phase * 12) * 0.25
					local bz = center.Z + math.sin(drift) * r + math.cos(clock * 5 + b.phase * 12) * 0.25
					local by = 0.25 + u * b.maxRise
					b.part.Size = Vector3.one * diam
					b.part.Position = Vector3.new(bx, by, bz)
					b.part.Transparency = math.clamp(0.22 + popAlpha * 0.78 + fade * 0.78, 0, 1)
				end
			end
		end
	end

	-- Advance ballistic explosion shrapnel & toxic acid droplets with real gravity.
	for i = #ballistics, 1, -1 do
		local c = ballistics[i]
		local u = (clock - c.startedAt) / math.max(c.duration, 0.05)
		if u >= 1 or not c.part.Parent then
			if c.part.Parent then
				c.part:Destroy()
			end
			table.remove(ballistics, i)
		else
			local vel = c.velocity + Vector3.new(0, -c.gravity * dt, 0)
			local nextPos = c.part.Position + vel * dt
			if nextPos.Y < 0.22 then
				nextPos = Vector3.new(nextPos.X, 0.22, nextPos.Z)
				vel = Vector3.new(vel.X * 0.45, math.abs(vel.Y) * 0.28, vel.Z * 0.45)
			end
			c.velocity = vel
			if c.stretch and vel.Magnitude > 1 then
				c.part.CFrame = CFrame.lookAt(nextPos, nextPos + vel)
				c.part.Size = Vector3.new(c.baseSize.X * (1 - u * 0.4), c.baseSize.Y * (1 - u * 0.4), c.baseSize.Z * (1 - u * 0.35))
			else
				c.part.Position = nextPos
				c.part.Size = c.baseSize * (1 - u * 0.5)
			end
			c.part.Transparency = 0.08 + 0.92 * (u * u)
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
		elseif eventKind == "bossConeSmash" then
			if typeof(arg1) == "Instance" and arg1:IsA("Model") then
				local rig = rigs[arg1]
				if rig then
					rig.strikeStartedAt = os.clock()
				end
			end
			if typeof(arg2) == "Vector3" and typeof(arg3) == "Vector3" and type(arg4) == "number" then
				local flat = Vector3.new(arg3.X, 0, arg3.Z)
				local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
				local impact = Vector3.new(arg2.X, 0.25, arg2.Z) + dir * (arg4 * 0.45)
				spawnSlamShockwave(impact, arg4 * 0.62)
			end
		elseif eventKind == "slamImpact" then
			if typeof(arg1) == "Instance" and arg1:IsA("Model") then
				local rig = rigs[arg1]
				if rig then
					rig.strikeStartedAt = os.clock()
				end
			end
			if typeof(arg2) == "Vector3" and type(arg3) == "number" then
				spawnSlamShockwave(arg2, arg3)
			end
		elseif eventKind == "explosion" then
			if typeof(arg1) == "Vector3" and type(arg2) == "number" then
				local color = if typeof(arg3) == "Color3" then arg3 else nil
				spawnExplosion(arg1, arg2, color)
			end
		elseif eventKind == "toxicSplash" then
			if typeof(arg1) == "Vector3" and type(arg2) == "number" then
				spawnToxicSplash(arg1, arg2)
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
