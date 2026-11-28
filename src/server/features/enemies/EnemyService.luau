--[[
	The enemies: spawning them, moving them, letting them act, and taking damage.

	Enemies are anchored parts the server moves every Heartbeat, not Humanoid rigs. A rig per enemy
	brings physics, pathfinding and a network owner the game does not need in a flat room, and
	its cost is paid per enemy — exactly the number a horde game wants to be large. What an enemy
	*decides* is `shared/features/enemies/Brain`, pure and tested; this module only carries it out.

	Who gets hurt is never decided here: `hurt` is CombatService's, passed in, so the dash's
	invulnerability applies to every source of damage without this module knowing it exists.
	See docs/combat.md.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local Brain = require(Shared.features.enemies.Brain)
local Difficulty = require(Shared.features.enemies.Difficulty)
local Hitbox = require(Shared.features.enemies.Hitbox)
local Melee = require(Shared.features.combat.Melee)
local SpatialGrid = require(Shared.features.enemies.SpatialGrid)
local Tactics = require(Shared.features.enemies.Tactics)
local Waves = require(Shared.features.enemies.Waves)

local EnemyService = {}

type PartVisual = {
	part: BasePart,
	color: Color3,
	material: Enum.Material,
}

export type Enemy = {
	kind: string,
	modelName: string?,
	weapon: string?,
	hasJoints: boolean,
	spec: any,
	model: Model,
	body: BasePart,
	visuals: { PartVisual },
	flashToken: number,
	fill: Frame,
	radius: number,
	health: number,
	state: Brain.State,
	dead: boolean,
	grabTarget: Player?,
	grabProgress: number,
	nextGrabDamageAt: number,
	wanderHeading: Vector3,
	wanderUntil: number,
	orbitSign: number,
	orbitFlipAt: number,
	sectorJitter: number,
	radiusBias: number,
	lungeDirection: Vector3?,
	-- Grabber rush: heading locked at launch, and who it has already run into this rush so a
	-- player standing in its path is hit once, not every frame they overlap.
	rushDirection: Vector3?,
	rushHit: { [Player]: boolean }?,
	-- Tank taunt: the player this enemy must target until `tauntUntil` (server time).
	tauntedBy: Player?,
	tauntUntil: number,
	-- Support shockwave: a short push (velocity until `shoveUntil`) and a slow (its whole step runs
	-- at `slowFactor` of real time until `slowUntil`).
	shoveVelocity: Vector3?,
	shoveUntil: number,
	slowFactor: number,
	slowUntil: number,
	-- Hard stun (Tank war cry, Support shockwave, Heavy slams): enemy cannot move, attack, or fuse.
	stunUntil: number,
	burstLeft: number,
	nextBurstAt: number,
	beamDirection: Vector3?,
	beamLocked: boolean,
	evadeOrigin: Vector3?,
	evadeTarget: Vector3?,
	evadeStartedAt: number,
	evadeDuration: number,
	phantomOrigin: Vector3?,
	phantomTarget: Vector3?,
	phantomStartedAt: number,
	phantomDuration: number,
	phantomStepIndex: number,
	bossConeDir: Vector3?,
	bossLeapOrigin: Vector3?,
	bossLeapTarget: Vector3?,
	bossLeapStartedAt: number,
	bossLeapDuration: number,
	axeInFlight: boolean,
	droppedAxePart: Model?,
	droppedAxePos: Vector3?,
	staggerStacks: number,
	dazeUntil: number,
	hitCount: number,
	knockbackDir: Vector3?,
	knockbackSpeed: number,
	knockbackEndsAt: number,
	contactHitAt: { [Player]: number },
	myDashDir: Vector3?,
	myDashHit: { [Player]: boolean }?,
	mySweepBaseDir: Vector3?,
	mySweepSign: number,
	mySweepStartedAt: number,
	mySweepDuration: number,
	mySweepHitAt: { [Player]: number },
	gonGravityPos: Vector3?,
	gonGravityRing: Part?,
	gonGravityCore: Part?,
	gonGravityNextPullAt: number,
}

type ShockRing = {
	origin: Vector3,
	startedAt: number,
	duration: number,
	maxRadius: number,
	height: number,
	damage: number,
	hit: { [Player]: boolean },
	part: Part,
}

export type HitInfo = {
	tier: ("light" | "medium" | "heavy")?,
	sourcePos: Vector3?,
}

type HazardZone = {
	position: Vector3,
	radius: number,
	height: number,
	launchedAt: number,
	telegraphDuration: number,
	telegraphEndsAt: number,
	expiresAt: number,
	detonated: boolean,
	impactDamage: number,
	tickDamage: number,
	tickEvery: number,
	nextTickAt: number,
	shellOrigin: Vector3,
	partOuter: Part,
	partInner: Part,
	partShell: Part?,
}

type Projectile = {
	part: BasePart,
	model: Model?,
	position: Vector3,
	velocity: Vector3,
	expiresAt: number,
	damage: number,
	reflected: boolean,
	isTracer: boolean,
	isAxe: boolean?,
	originPos: Vector3?,
	maxDistance: number?,
	spinAngle: number?,
	canParry: boolean,
	shooter: Enemy?,
}

-- How far inside the walls an enemy is kept.
local WALL_MARGIN = 3
local FLASH_SECONDS = 0.08
local HIT_COLOR = Color3.new(1, 1, 1)
local PARRIED_SHOT_COLOR = Color3.fromRGB(255, 225, 90)

local hurt: (Player, number, { canDodge: boolean?, canBlock: boolean?, canParry: boolean?, origin: Vector3? }?) -> (boolean, string?) =
	nil :: any
local onKill: ((Vector3) -> ())? = nil
local canGrab: ((Player) -> boolean)? = nil
local setGrabbed: ((Player, boolean, number?, number?) -> ())? = nil
local warnGrab: ((Player, number) -> ())? = nil
local warnParry: ((Player, number) -> ())? = nil
local stunPlayer: ((Player, number) -> ())? = nil
-- ClassService's "somebody is still choosing a class": the whole board waits while it is true.
local isPaused: (() -> boolean)? = nil
local folder: Folder = nil :: any
local worldRef: Instance? = nil

local enemies: { Enemy } = {}
local projectiles: { Projectile } = {}
local hazardZones: { HazardZone } = {}
local shockRings: { ShockRing } = {}
local destroyHazardZone: (HazardZone) -> ()
local variantCursor: { [string]: number } = {}
local lastRangedShotAt: { [Player]: number } = {}
local lastAreaLaunchAt: { [Player]: number } = {}
local nextOrbitSign = 1
local grid = SpatialGrid.new(Config.ENEMY_GRID_CELL_SIZE)
local separationScratch: { Enemy } = {}
local neighborPosScratch: { Vector3 } = {}
local maxEnemyRadius = 0

local function pickVariant(kind: string, spec: any): (string?, string?, any?)
	local variants = spec.variants
	if type(variants) == "table" and #variants > 0 then
		local totalWeight = 0
		local hasWeights = false
		for _, v in ipairs(variants) do
			if type(v.weight) == "number" and v.weight > 0 then
				hasWeights = true
				totalWeight += v.weight
			else
				totalWeight += 1
			end
		end
		if hasWeights and totalWeight > 0 then
			local roll = math.random() * totalWeight
			local acc = 0
			for _, v in ipairs(variants) do
				acc += if type(v.weight) == "number" and v.weight > 0 then v.weight else 1
				if roll <= acc then
					return v.model, v.weapon, v
				end
			end
			local last = variants[#variants]
			return last.model, last.weapon, last
		end
		local idx = variantCursor[kind]
		if not idx then
			idx = math.random(1, #variants)
		else
			idx = (idx % #variants) + 1
		end
		variantCursor[kind] = idx
		local choice = variants[idx]
		return choice.model, choice.weapon, choice
	end
	return spec.model, nil, nil
end

-- Moves an enemy cleanly: rigged Motor6D models only update `Body.CFrame` so the client's
-- 60 FPS `Motor6D.C0` limb animations are never overwritten by server replication.
local function moveEnemy(enemy: Enemy, nextCFrame: CFrame)
	if enemy.hasJoints then
		enemy.body.CFrame = nextCFrame
	else
		enemy.model:PivotTo(nextCFrame)
	end
end

local function syncPhase(enemy: Enemy, t: number)
	enemy.model:SetAttribute("Phase", enemy.state.phase)
	enemy.model:SetAttribute("PhaseStartedAt", t)
	enemy.model:SetAttribute("PhaseDuration", math.max((enemy.state.endsAt or 0) - t, 0))
end

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Resolves the active arena layout's obstacle table dynamically whenever RunService swaps arenas.
local function activeObstacles(): { Waves.Obstacle }
	return Config.getArenaObstacles(worldRef and worldRef:GetAttribute("ArenaModel"))
end

-- Keeps any enemy (or grab hold point) strictly inside the room perimeter and outside every
-- solid arena structure/prop (pillars, bunkers, cryo tanks, crates, consoles, racks, pallets).
local function clampEnemyPos(candidate: Vector3, radius: number): Vector3
	local clamped = Waves.clamp(candidate, Config.ROOM_SIZE, WALL_MARGIN)
	local cleared = Waves.avoidObstacles(clamped, radius, activeObstacles())
	return Waves.clamp(cleared, Config.ROOM_SIZE, WALL_MARGIN)
end

-- Returns `(freeTargets, grabbedPositions)`: non-grabbed living players for enemies to chase,
-- and grabbed player positions so roaming enemies steer clear when no free target exists.
local function targets(): ({ { player: Player, root: BasePart } }, { Vector3 })
	local list = {}
	local grabbed = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") and player:GetAttribute("Downed") ~= true then
			if player:GetAttribute("Grabbed") == true then
				table.insert(grabbed, root.Position)
			else
				table.insert(list, { player = player, root = root })
			end
		end
	end
	return list, grabbed
end

local function randomHeading(): Vector3
	local angle = math.random() * math.pi * 2
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

-- Strong anti-clumping repulsion via the spatial grid in O(local) rather than O(N^2).
-- Ranged units push farther apart from each other (`AI_RANGED_SPACING`) to form crossfire angles.
local function separationPush(enemy: Enemy, position: Vector3): Vector3
	local isArtilleryOrRanged = enemy.kind == "ranged" or enemy.kind == "area"
	local spacing = if isArtilleryOrRanged then Config.AI_RANGED_SPACING else Config.ENEMY_SPACING
	local neighbors = grid:queryRadius(position.X, position.Z, spacing, separationScratch)
	table.clear(neighborPosScratch)
	for _, other in ipairs(neighbors) do
		if other ~= enemy and not other.dead then
			local otherFar = other.kind == "ranged" or other.kind == "area"
			if not isArtilleryOrRanged or otherFar or (position - other.body.Position).Magnitude < Config.ENEMY_SPACING then
				table.insert(neighborPosScratch, other.body.Position)
			end
		end
	end
	return Tactics.antiClumpPush(position, neighborPosScratch, spacing, enemy.orbitSign, Config.AI_SEPARATION_WEIGHT)
end

local function nearest(position: Vector3, list: { { player: Player, root: BasePart } })
	local best, bestDistance = nil, math.huge
	for _, target in ipairs(list) do
		local distance =
			Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z).Magnitude
		if distance < bestDistance then
			best, bestDistance = target, distance
		end
	end
	return best, bestDistance
end

local function healthBar(body: BasePart, height: number): Frame
	local gui = Instance.new("BillboardGui")
	gui.Name = "Health"
	gui.Size = UDim2.fromScale(4, 0.45)
	gui.StudsOffset = Vector3.new(0, height / 2 + 1.5, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = body

	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(230, 70, 70)
	fill.BorderSizePixel = 0
	fill.Parent = back

	gui.Parent = body
	return fill
end

-- A short-lived visual the server owns, so every player sees it. Passing a distinct
-- `verticalRadius` renders a non-uniform oval via SpecialMesh (PartType.Ball clamps to a sphere).
local function burst(position: Vector3, radius: number, color: Color3, verticalRadius: number?)
	local part = Instance.new("Part")
	local heightRadius = verticalRadius or radius
	if math.abs(heightRadius - radius) > 1e-3 then
		part.Shape = Enum.PartType.Block
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	else
		part.Shape = Enum.PartType.Ball
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.one * 2
	part.Position = position
	part.Parent = folder
	local targetSize = Vector3.new(radius * 2, heightRadius * 2, radius * 2)
	TweenService:Create(part, TweenInfo.new(0.3), { Size = targetSize, Transparency = 1 }):Play()
	task.delay(0.35, function()
		part:Destroy()
	end)
end

local function setTelegraph(enemy: Enemy, on: boolean, color: Color3?)
	-- Crisp zero-bloom Highlight outline while telegraphing an attack or ability (never turns the
	-- whole body Neon, which over-blooms under AgX tonemapping). Destroyed immediately when off so
	-- active Highlights stay well under Roblox's 31-instance limit.
	local existing = enemy.model:FindFirstChild("TelegraphHighlight")
	if not on then
		if existing then
			existing:Destroy()
		end
		return
	end
	local tint = color or Color3.fromRGB(255, 190, 85)
	local hl: Highlight
	if existing and existing:IsA("Highlight") then
		hl = existing
	else
		hl = Instance.new("Highlight")
		hl.Name = "TelegraphHighlight"
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.FillTransparency = 0.72
		hl.OutlineTransparency = 0.08
		hl.Parent = enemy.model
	end
	hl.FillColor = tint
	hl.OutlineColor = tint
end

local function releaseGrab(enemy: Enemy, t: number, playEscapeSfx: boolean)
	local victim = enemy.grabTarget
	if not victim then
		return
	end
	enemy.grabTarget = nil
	enemy.grabProgress = 0
	enemy.nextGrabDamageAt = 0
	enemy.lungeDirection = nil
	if not enemy.dead then
		enemy.state = Brain.releaseGrab(enemy.state, enemy.spec.recover or 1.6, t)
		syncPhase(enemy, t)
	end
	if setGrabbed then
		setGrabbed(victim, false, 0, Config.GRAB_ESCAPE_PRESSES)
	end
	if playEscapeSfx and enemy.body and enemy.body.Parent then
		Remotes.CombatSfx:FireAllClients("enemyGrabberEscape", enemy.body.Position)
	end
end

local function syncBossHud(enemy: Enemy?)
	if not worldRef then
		return
	end
	if enemy and not enemy.dead and enemy.spec.isBoss == true then
		worldRef:SetAttribute("BossName", enemy.spec.bossTitle or enemy.spec.displayName or "JEFE")
		worldRef:SetAttribute("BossHealth", math.max(enemy.health, 0))
		worldRef:SetAttribute("BossMaxHealth", enemy.spec.health)
		worldRef:SetAttribute("BossPhase", if enemy.state.bossPhase2 then 2 else 1)
	else
		worldRef:SetAttribute("BossName", "")
		worldRef:SetAttribute("BossHealth", 0)
		worldRef:SetAttribute("BossMaxHealth", 0)
		worldRef:SetAttribute("BossPhase", 0)
	end
end

local function clearBossEffects(enemy: Enemy)
	enemy.myDashDir = nil
	enemy.myDashHit = nil
	enemy.mySweepBaseDir = nil
	table.clear(enemy.mySweepHitAt)
	enemy.gonGravityPos = nil
	if enemy.gonGravityRing and enemy.gonGravityRing.Parent then
		enemy.gonGravityRing:Destroy()
	end
	enemy.gonGravityRing = nil
	if enemy.gonGravityCore and enemy.gonGravityCore.Parent then
		enemy.gonGravityCore:Destroy()
	end
	enemy.gonGravityCore = nil
	if enemy.model and enemy.model.Parent then
		enemy.model:SetAttribute("MyDashDir", nil)
		enemy.model:SetAttribute("SweepDir", nil)
		enemy.model:SetAttribute("SweepActive", false)
	end
end

local function clearDroppedAxe(enemy: Enemy)
	if enemy.droppedAxePart then
		enemy.droppedAxePart:Destroy()
		enemy.droppedAxePart = nil
	end
	enemy.droppedAxePos = nil
	enemy.axeInFlight = false
end

local function cloneBattleAxe(): (Model?, BasePart?)
	local models = ReplicatedStorage:FindFirstChild("Models")
	local template = models and models:FindFirstChild("EnemyBattleAxe")
	if not template or not template:IsA("Model") then
		return nil, nil
	end
	local axe = template:Clone()
	local pivot = axe.PrimaryPart or axe:FindFirstChild("Pivot")
	if not pivot or not pivot:IsA("BasePart") then
		axe:Destroy()
		return nil, nil
	end
	axe.PrimaryPart = pivot
	axe.WorldPivot = pivot.CFrame
	for _, desc in ipairs(axe:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
		end
	end
	return axe, pivot
end

local function createDroppedAxe(pos: Vector3): Model
	local m = Instance.new("Model")
	m.Name = "DroppedEnemyAxe"
	local safeXZ = clampEnemyPos(pos, 1.8)
	local base = Vector3.new(safeXZ.X, 0, safeXZ.Z)

	-- Glowing pickup ring on the floor so players & the unarmed enemy clearly spot the dropped axe.
	local ring = Instance.new("Part")
	ring.Name = "PickupRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 130, 45)
	ring.Transparency = 0.45
	ring.Size = Vector3.new(0.16, 4.4, 4.4)
	ring.CFrame = CFrame.new(base.X, 0.1, base.Z) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = m

	-- Clone the real `.rbxmx` battle-axe embedded blade-first diagonally into the arena floor.
	local axeModel = cloneBattleAxe()
	if axeModel then
		axeModel.Name = "DroppedAxeModel"
		axeModel:PivotTo(CFrame.new(base.X, 1.35, base.Z) * CFrame.Angles(math.rad(-72), math.rad(25), math.rad(16)))
		axeModel.Parent = m
	end

	m.Parent = folder
	return m
end

local function throwAxe(enemy: Enemy, target: BasePart)
	local origin = enemy.body.Position
	local aim = Vector3.new(target.Position.X - origin.X, 0, target.Position.Z - origin.Z)
	if aim.Magnitude < 1e-3 then
		return
	end
	local dir = aim.Unit
	local speed = enemy.spec.axeThrowSpeed or 54
	local damage = enemy.spec.axeThrowDamage or 18
	local maxDist = enemy.spec.axeThrowMaxDistance or 40
	local spawnPos = Vector3.new(origin.X + dir.X * 2.2, Config.PROJECTILE_HEIGHT + 0.5, origin.Z + dir.Z * 2.2)

	enemy.axeInFlight = true
	enemy.model:SetAttribute("AxeThrown", true)

	local axeModel, pivot = cloneBattleAxe()
	local part: BasePart
	if axeModel and pivot then
		axeModel.Name = "ThrownAxe"
		axeModel:PivotTo(CFrame.lookAt(spawnPos, spawnPos + dir) * CFrame.Angles(0, 0, math.rad(76)))
		axeModel.Parent = folder
		part = pivot
	else
		local fallback = Instance.new("Part")
		fallback.Name = "ThrownAxe"
		fallback.Anchored = true
		fallback.CanCollide = false
		fallback.CanQuery = false
		fallback.CanTouch = false
		fallback.Material = Enum.Material.Neon
		fallback.Color = Color3.fromRGB(255, 92, 46)
		fallback.Size = Vector3.new(0.4, 1.4, 2.6)
		fallback.CFrame = CFrame.lookAt(spawnPos, spawnPos + dir)
		fallback.Parent = folder
		part = fallback
	end

	table.insert(projectiles, {
		part = part,
		model = axeModel,
		position = spawnPos,
		velocity = dir * speed,
		expiresAt = now() + (maxDist / math.max(speed, 1)) + 0.5,
		damage = damage,
		reflected = false,
		isTracer = false,
		isAxe = true,
		originPos = spawnPos,
		maxDistance = maxDist,
		spinAngle = 0,
		canParry = true,
		shooter = enemy,
	})
	if enemy.hasJoints then
		Remotes.EnemyAnim:FireAllClients("strike", enemy.model, "axe")
	end
	Remotes.CombatSfx:FireAllClients("enemyMeleeStrike", origin)
end

local function kill(enemy: Enemy)
	if enemy.dead then
		return
	end
	enemy.dead = true
	if enemy.spec.isBoss == true then
		syncBossHud(nil)
		-- Clean up lingering boss-owned hazard zones & shock rings immediately on boss defeat (`HS-18`/`HS-20`).
		for _, zone in ipairs(hazardZones) do
			destroyHazardZone(zone)
		end
		table.clear(hazardZones)
		for _, ring in ipairs(shockRings) do
			if ring.part.Parent then
				ring.part:Destroy()
			end
		end
		table.clear(shockRings)
	end
	clearBossEffects(enemy)
	grid:remove(enemy)
	clearDroppedAxe(enemy)
	releaseGrab(enemy, now(), true)
	local position = enemy.body.Position
	if enemy.hasJoints and enemy.modelName then
		Remotes.EnemyAnim:FireAllClients("death", enemy.modelName, enemy.weapon, enemy.body.CFrame)
		burst(position, enemy.radius * 0.6, enemy.spec.color)
	else
		burst(position, enemy.radius, enemy.spec.color)
	end
	enemy.model:Destroy()
	if onKill then
		onKill(position)
	end
end

local function fire(enemy: Enemy, target: BasePart)
	local origin = enemy.body.Position
	local aim = Vector3.new(target.Position.X - origin.X, 0, target.Position.Z - origin.Z)
	if aim.Magnitude < 1e-3 then
		return
	end
	local baseDir = aim.Unit
	local pelletCount = math.max(enemy.spec.pelletCount or 1, 1)
	local pelletSpreadDeg = enemy.spec.pelletSpreadDeg or 0
	local spreadDeg = enemy.spec.burstSpreadDeg or 0
	local isTracer = enemy.spec.projectileStyle == "tracer"
	local isShotgun = enemy.weapon == "shotgun"
	local speed = enemy.spec.projectileSpeed or 45
	local damage = enemy.spec.projectileDamage or enemy.spec.damage or 8
	local spawnPos = Vector3.new(origin.X, Config.PROJECTILE_HEIGHT, origin.Z)
	local canParry = if enemy.spec.canParry ~= nil then enemy.spec.canParry else true

	for p = 1, pelletCount do
		local dir = baseDir
		if pelletCount > 1 and pelletSpreadDeg > 0 then
			-- Fan out evenly across 4 diverging directions while facing straight ahead.
			local frac = (p - 1) / (pelletCount - 1) - 0.5
			local rad = math.rad(frac * pelletSpreadDeg)
			local cosA, sinA = math.cos(rad), math.sin(rad)
			dir = Vector3.new(baseDir.X * cosA - baseDir.Z * sinA, 0, baseDir.X * sinA + baseDir.Z * cosA).Unit
		elseif spreadDeg > 0 then
			local rad = math.rad((math.random() * 2 - 1) * spreadDeg)
			local cosA, sinA = math.cos(rad), math.sin(rad)
			dir = Vector3.new(baseDir.X * cosA - baseDir.Z * sinA, 0, baseDir.X * sinA + baseDir.Z * cosA).Unit
		end

		local part = Instance.new("Part")
		part.Name = if isTracer then (if isShotgun then "ShotgunTracer" else "Tracer") else "Shot"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Material = Enum.Material.Neon
		if isTracer then
			part.Shape = Enum.PartType.Block
			part.Color = if isShotgun then Color3.fromRGB(115, 235, 255) else Color3.fromRGB(255, 205, 65)
			part.Size = if isShotgun then Vector3.new(0.32, 0.32, 4.4) else Vector3.new(0.28, 0.28, 3.8)
			part.CFrame = CFrame.lookAt(spawnPos, spawnPos + dir)
		else
			part.Shape = Enum.PartType.Ball
			part.Color = enemy.spec.color
			part.Size = Vector3.one * 1.5
			part.Position = spawnPos
		end
		part.Parent = folder
		table.insert(projectiles, {
			part = part,
			position = spawnPos,
			velocity = dir * speed,
			expiresAt = now() + (enemy.spec.projectileLife or 2.5),
			damage = damage,
			reflected = false,
			isTracer = isTracer,
			canParry = canParry,
			shooter = enemy,
		})
	end

	if enemy.hasJoints then
		Remotes.EnemyAnim:FireAllClients("fire", enemy.model, enemy.weapon)
	end
	Remotes.CombatSfx:FireAllClients("enemyRangedFire", origin)
end

local function explode(enemy: Enemy, list: { { player: Player, root: BasePart } })
	local origin = enemy.body.Position
	local blastRadius = enemy.spec.blastRadius
	local blastHeight = enemy.spec.blastHeight or blastRadius

	-- Mark and remove before applying splash damage so the exploder never hits itself.
	enemy.dead = true
	grid:remove(enemy)
	enemy.model:Destroy()

	for _, target in ipairs(list) do
		if Hitbox.inEllipsoid(origin, target.root.Position, blastRadius, blastHeight) then
			hurt(target.player, enemy.spec.damage, { canBlock = true, canParry = false })
		end
	end

	local enemyDamage = enemy.spec.enemyDamage or enemy.spec.damage
	if enemyDamage and enemyDamage > 0 then
		-- Query only the spatial grid cells overlapping the blast instead of scanning all enemies.
		local candidates = grid:queryRadius(origin.X, origin.Z, blastRadius + maxEnemyRadius)
		for _, other in ipairs(candidates) do
			if not other.dead then
				local halfHeight = other.spec.size.Y / 2
				if
					Hitbox.inEllipsoid(
						origin,
						other.body.Position,
						blastRadius + other.radius,
						blastHeight + halfHeight
					)
				then
					EnemyService.damage(other, enemyDamage, { tier = "heavy", sourcePos = origin })
				end
			end
		end
	end

	Remotes.EnemyAnim:FireAllClients("explosion", origin, blastRadius, enemy.spec.color)
	Remotes.CombatSfx:FireAllClients("enemyExploderBlast", origin)
end

function destroyHazardZone(zone: HazardZone)
	if zone.partOuter.Parent then
		zone.partOuter:Destroy()
	end
	if zone.partInner.Parent then
		zone.partInner:Destroy()
	end
	if zone.partShell and zone.partShell.Parent then
		zone.partShell:Destroy()
	end
end

local function spawnShockRing(origin: Vector3, maxRadius: number, duration: number, height: number, damage: number, color: Color3, t: number)
	local part = Instance.new("Part")
	part.Name = "BossShockRing"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.22
	part.Size = Vector3.new(0.45, 4, 4)
	part.CFrame = CFrame.new(origin.X, 0.35, origin.Z) * CFrame.Angles(0, 0, math.rad(90))
	part.Parent = folder
	table.insert(shockRings, {
		origin = Vector3.new(origin.X, 0, origin.Z),
		startedAt = t,
		duration = math.max(duration, 0.2),
		maxRadius = maxRadius,
		height = height,
		damage = damage,
		hit = {},
		part = part,
	})
	Remotes.CombatSfx:FireAllClients("enemyAreaDetonate", origin)
end

local function stepShockRings(list: { { player: Player, root: BasePart } }, t: number)
	for i = #shockRings, 1, -1 do
		local ring = shockRings[i]
		local u = (t - ring.startedAt) / ring.duration
		if u >= 1 or not ring.part.Parent then
			if ring.part.Parent then
				ring.part:Destroy()
			end
			table.remove(shockRings, i)
		else
			local curRadius = 2 + (ring.maxRadius - 2) * u
			local diam = curRadius * 2
			ring.part.Size = Vector3.new(0.42, diam, diam)
			ring.part.Transparency = 0.22 + 0.72 * (u * u)
			local innerR = math.max(curRadius - 2.6, 0)
			local outerR = curRadius + 2.6
			for _, candidate in ipairs(list) do
				if not ring.hit[candidate.player] then
					local pos = candidate.root.Position
					local dy = pos.Y - ring.origin.Y
					if dy <= ring.height then
						local dx = pos.X - ring.origin.X
						local dz = pos.Z - ring.origin.Z
						local dist = math.sqrt(dx * dx + dz * dz)
						if dist >= innerR and dist <= outerR then
							ring.hit[candidate.player] = true
							hurt(candidate.player, ring.damage, { canBlock = true, canParry = false, origin = ring.origin })
						end
					end
				end
			end
		end
	end
end

-- Launches an Artillero (`area`) or Boss Gon/OhMyGon arcing mortar round toward `targetPos`, creating a floor warning
-- circle that fills over `areaTelegraph` seconds before detonating into an active hazard pool.
-- Enforces `Tactics.isGrabSafeZone` so a player trapped by a Coloso is never melted unfairly.
local function launchAreaHazard(
	enemy: Enemy,
	targetPos: Vector3,
	grabbedPositions: { Vector3 },
	t: number,
	overrides: { radius: number?, telegraph: number?, duration: number?, impactDamage: number?, tickDamage: number? }?
)
	local radius = (overrides and overrides.radius) or enemy.spec.areaRadius or 11
	local height = enemy.spec.areaHeight or 3.6
	local telegraphDur = (overrides and overrides.telegraph) or enemy.spec.areaTelegraph or 1.05
	local activeDur = (overrides and overrides.duration) or enemy.spec.areaDuration or 3.5
	local tickEvery = enemy.spec.areaTickEvery or 0.5
	local impactDmg = (overrides and overrides.impactDamage) or enemy.spec.areaImpactDamage or 14
	local tickDmg = (overrides and overrides.tickDamage) or enemy.spec.areaTickDamage or 10

	local rawLand = Vector3.new(targetPos.X, 0, targetPos.Z)
	local clamped = Waves.clamp(rawLand, Config.ROOM_SIZE, math.max(WALL_MARGIN, radius * 0.45))
	local landPos = Vector3.new(clamped.X, 0, clamped.Z)
	if not Tactics.isGrabSafeZone(landPos, radius, grabbedPositions, 2.5) then
		return
	end

	local diam = radius * 2
	local outer = Instance.new("Part")
	outer.Name = "AreaHazardOuter"
	outer.Shape = Enum.PartType.Cylinder
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.CastShadow = false
	outer.Material = Enum.Material.Neon
	outer.Color = Color3.fromRGB(255, 165, 45)
	outer.Transparency = 0.68
	outer.Size = Vector3.new(0.14, diam, diam)
	outer.CFrame = CFrame.new(landPos.X, 0.14, landPos.Z) * CFrame.Angles(0, 0, math.rad(90))
	outer:SetAttribute("HazardZone", true)
	outer:SetAttribute("HazardRadius", radius)
	outer:SetAttribute("HazardActive", false)
	outer:SetAttribute("HazardFade", 0)
	outer.Parent = folder

	local inner = Instance.new("Part")
	inner.Name = "AreaHazardInner"
	inner.Shape = Enum.PartType.Cylinder
	inner.Anchored = true
	inner.CanCollide = false
	inner.CanQuery = false
	inner.CanTouch = false
	inner.CastShadow = false
	inner.Material = Enum.Material.Neon
	inner.Color = Color3.fromRGB(165, 255, 70)
	inner.Transparency = 0.58
	inner.Size = Vector3.new(0.2, 2.0, 2.0)
	inner.CFrame = CFrame.new(landPos.X, 0.2, landPos.Z) * CFrame.Angles(0, 0, math.rad(90))
	inner.Parent = folder

	local shellOrigin = enemy.body.Position + Vector3.new(0, 2.2, 0)
	local shell = Instance.new("Part")
	shell.Name = "AreaMortarShell"
	shell.Shape = Enum.PartType.Ball
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CanTouch = false
	shell.CastShadow = false
	shell.Material = Enum.Material.Neon
	shell.Color = Color3.fromRGB(165, 255, 65)
	shell.Size = Vector3.one * 1.5
	shell.Position = shellOrigin
	local shellTrail = Instance.new("ParticleEmitter")
	shellTrail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 255, 85)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(50, 150, 32)),
	})
	shellTrail.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.1),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	shellTrail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	shellTrail.Lifetime = NumberRange.new(0.25, 0.45)
	shellTrail.Rate = 40
	shellTrail.Speed = NumberRange.new(1, 3)
	shellTrail.SpreadAngle = Vector2.new(35, 35)
	shellTrail.LightEmission = 0.7
	shellTrail.Parent = shell
	shell.Parent = folder

	table.insert(hazardZones, {
		position = landPos,
		radius = radius,
		height = height,
		launchedAt = t,
		telegraphDuration = telegraphDur,
		telegraphEndsAt = t + telegraphDur,
		expiresAt = t + telegraphDur + activeDur,
		detonated = false,
		impactDamage = impactDmg,
		tickDamage = tickDmg,
		tickEvery = tickEvery,
		nextTickAt = t + telegraphDur + tickEvery,
		shellOrigin = shellOrigin,
		partOuter = outer,
		partInner = inner,
		partShell = shell,
	})
	Remotes.CombatSfx:FireAllClients("enemyAreaLaunch", enemy.body.Position)
end

local function stepHazardZones(list: { { player: Player, root: BasePart } }, t: number)
	for i = #hazardZones, 1, -1 do
		local zone = hazardZones[i]
		if t >= zone.expiresAt then
			destroyHazardZone(zone)
			table.remove(hazardZones, i)
		elseif not zone.detonated then
			local u = math.clamp((t - zone.launchedAt) / math.max(zone.telegraphDuration, 0.05), 0, 1)
			local diam = zone.radius * 2
			local fillDiam = math.max(diam * u, 1.8)
			zone.partInner.Size = Vector3.new(0.2, fillDiam, fillDiam)
			zone.partInner.Transparency = 0.66 - 0.34 * u
			zone.partOuter.Transparency = 0.72 - 0.16 * math.abs(math.sin(t * 20))
			if zone.partShell and zone.partShell.Parent then
				local arcHeight = 22
				local sx = zone.shellOrigin.X + (zone.position.X - zone.shellOrigin.X) * u
				local sz = zone.shellOrigin.Z + (zone.position.Z - zone.shellOrigin.Z) * u
				local sy = zone.shellOrigin.Y * (1 - u) + 0.5 * u + 4 * arcHeight * u * (1 - u)
				zone.partShell.Position = Vector3.new(sx, sy, sz)
			end
			if t >= zone.telegraphEndsAt then
				zone.detonated = true
				if zone.partShell and zone.partShell.Parent then
					zone.partShell:Destroy()
					zone.partShell = nil
				end
				-- Dark toxic sludge base + subtle inner slick; client EnemyAnimator adds swirling
				-- surface ripples, rising/popping acid bubbles, and toxic mist over `HazardActive`.
				zone.partOuter.Material = Enum.Material.SmoothPlastic
				zone.partOuter.Color = Color3.fromRGB(34, 96, 26)
				zone.partOuter.Transparency = 0.22
				zone.partOuter:SetAttribute("HazardActive", true)
				zone.partInner.Color = Color3.fromRGB(120, 240, 52)
				zone.partInner.Size = Vector3.new(0.2, diam * 0.88, diam * 0.88)
				zone.partInner.Transparency = 0.66
				Remotes.EnemyAnim:FireAllClients("toxicSplash", zone.position, zone.radius)
				Remotes.CombatSfx:FireAllClients("enemyAreaDetonate", zone.position)
				for _, target in ipairs(list) do
					if Hitbox.inGroundZone(zone.position, target.root.Position, zone.radius, zone.height) then
						hurt(target.player, zone.impactDamage, { canBlock = true, canParry = false, origin = zone.position })
					end
				end
			end
		else
			-- Active bubbling toxic pool: subtle organic breathing on the sludge base + DoT ticks.
			local remain = math.max(zone.expiresAt - t, 0)
			local fade = if remain < 0.5 then 1 - remain / 0.5 else 0
			local pulse = 0.84 + 0.08 * math.sin(t * 7.5)
			local diam = zone.radius * 2
			zone.partInner.Size = Vector3.new(0.2, diam * pulse, diam * pulse)
			zone.partOuter.Transparency = 0.22 + 0.78 * fade
			zone.partInner.Transparency = 0.66 + 0.34 * fade
			zone.partOuter:SetAttribute("HazardFade", fade)
			if t >= zone.nextTickAt then
				zone.nextTickAt = t + zone.tickEvery
				for _, target in ipairs(list) do
					if Hitbox.inGroundZone(zone.position, target.root.Position, zone.radius, zone.height) then
						hurt(target.player, zone.tickDamage, { canBlock = true, canParry = false, origin = zone.position })
					end
				end
			end
		end
	end
end

-- Checks Voltaico (`contact`) body/surge shock damage against every free player with per-player
-- debounce. Routed through `CombatService.hurt` so Dash i-frames & Block apply cleanly.
local function applyContactDamage(enemy: Enemy, pos: Vector3, list: { { player: Player, root: BasePart } }, t: number)
	local isActive = enemy.state.phase == "contactActive"
	if not isActive and enemy.state.phase ~= "chase" then
		return
	end
	local radius = if isActive then (enemy.spec.contactRadius or 5.5) else (enemy.spec.passiveContactRadius or 2.9)
	local height = enemy.spec.contactHeight or 4.6
	local dmg = if isActive then (enemy.spec.contactDamage or 10) else (enemy.spec.passiveContactDamage or 5)
	local tickEvery = if isActive
		then (enemy.spec.contactTickEvery or 0.6)
		else (enemy.spec.passiveContactTickEvery or 0.75)

	for _, candidate in ipairs(list) do
		local nextAt = enemy.contactHitAt[candidate.player] or 0
		if t >= nextAt and Hitbox.inEllipsoid(pos, candidate.root.Position, radius, height) then
			local landed = hurt(candidate.player, dmg, { canBlock = true, canParry = false, origin = pos })
			if landed then
				enemy.contactHitAt[candidate.player] = t + tickEvery
				Remotes.CombatSfx:FireAllClients("enemyContactZap", candidate.root.Position)
			end
		end
	end
end

local function stepHeldGrab(enemy: Enemy, t: number)
	local victim = enemy.grabTarget
	if not victim then
		return
	end
	local character = victim.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not victim.Parent or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		releaseGrab(enemy, t, false)
		return
	end

	-- Hold the player visibly inside the grabber's front claws.
	local origin = enemy.body.Position
	local forward = enemy.body.CFrame.LookVector
	local holdXZ = clampEnemyPos(origin + forward * Config.GRAB_HOLD_DISTANCE, 1.8)
	local holdPos = Vector3.new(holdXZ.X, root.Position.Y, holdXZ.Z)
	local facePos = Vector3.new(origin.X, root.Position.Y, origin.Z)
	if (facePos - holdPos).Magnitude > 1e-3 then
		root.CFrame = CFrame.lookAt(holdPos, facePos)
	else
		root.CFrame = CFrame.new(holdPos)
	end
	root.AssemblyLinearVelocity = Vector3.zero

	-- Continuous drain (8 HP/s in Config.GRAB_DAMAGE_TICK_SECONDS ticks) while held.
	if t >= enemy.nextGrabDamageAt then
		enemy.nextGrabDamageAt = t + Config.GRAB_DAMAGE_TICK_SECONDS
		local dps = enemy.spec.grabDamagePerSecond or 8
		hurt(victim, dps * Config.GRAB_DAMAGE_TICK_SECONDS, { canBlock = false, canParry = false })
		if humanoid.Health <= 0 then
			releaseGrab(enemy, t, false)
		end
	end
end

local function stepEnemy(
	enemy: Enemy,
	list,
	grabbedPositions: { Vector3 },
	target: { player: Player, root: BasePart }?,
	distance: number,
	canAttack: boolean,
	sectorAngle: number,
	dt: number,
	t: number
)
	if enemy.grabTarget then
		stepHeldGrab(enemy, t)
		return
	end

	local body = enemy.body
	local position = body.Position
	if not target then
		-- Cancel any in-progress windup/spin/beamCharge/evade/lunge/fuse/burst so an ignored
		-- enemy cannot fire a buffered attack or hover mid-air when all players are grabbed.
		enemy.burstLeft = 0
		if
			enemy.state.phase == "windup"
			or enemy.state.phase == "spin"
			or enemy.state.phase == "phantomStep"
			or enemy.state.phase == "slamWindup"
			or enemy.state.phase == "axeThrowWindup"
			or enemy.state.phase == "beamCharge"
			or enemy.state.phase == "evade"
			or enemy.state.phase == "lunge"
			or enemy.state.phase == "rushWindup"
			or enemy.state.phase == "rush"
			or enemy.state.phase == "fuse"
			or enemy.state.phase == "areaWindup"
			or enemy.state.phase == "contactWindup"
			or enemy.state.phase == "contactActive"
		then
			enemy.state = Brain.initial(t)
			enemy.lungeDirection = nil
			enemy.rushDirection = nil
			enemy.rushHit = nil
			enemy.beamDirection = nil
			enemy.beamLocked = false
			enemy.phantomOrigin = nil
			enemy.phantomTarget = nil
			enemy.phantomStepIndex = 0
			enemy.model:SetAttribute("BeamDir", nil)
			enemy.model:SetAttribute("BeamLocked", false)
			enemy.model:SetAttribute("ParryTelegraph", false)
			enemy.model:SetAttribute("AlertIcon", false)
			enemy.model:SetAttribute("SlamRadius", nil)
			setTelegraph(enemy, false)
			syncPhase(enemy, t)
		end
		local baseY = enemy.spec.size.Y / 2
		if math.abs(position.Y - baseY) > 0.05 then
			position = Vector3.new(position.X, baseY, position.Z)
		end
		-- Keep prowling around the room while steering clear of grabbed players instead of
		-- freezing like statues when playing solo (or when every teammate is grabbed).
		if t >= enemy.wanderUntil then
			enemy.wanderHeading = randomHeading()
			enemy.wanderUntil = t + Config.ENEMY_WANDER_INTERVAL * (0.7 + math.random() * 0.6)
		end
		local roamDir = Brain.wanderDirection(position, enemy.wanderHeading, grabbedPositions, Config.ENEMY_GRAB_AVOID_RADIUS)
		local push = separationPush(enemy, position)
		local roamSpeed = enemy.spec.speed * Config.ENEMY_WANDER_SPEED_FACTOR
		local candidate = position + (roamDir * roamSpeed + push * enemy.spec.speed) * dt
		local moved = clampEnemyPos(candidate, enemy.radius)
		if moved.X ~= candidate.X or moved.Z ~= candidate.Z then
			-- Hit a room wall while roaming: steer smoothly back toward the room interior.
			local inward = Vector3.new(-position.X, 0, -position.Z)
			if inward.Magnitude > 1e-3 then
				local tangent = Vector3.new(-inward.Z, 0, inward.X).Unit
				enemy.wanderHeading = (inward.Unit + tangent * (math.random() * 2 - 1) * 0.6).Unit
			else
				enemy.wanderHeading = randomHeading()
			end
			enemy.wanderUntil = t + Config.ENEMY_WANDER_INTERVAL
		end
		local look = Vector3.new(moved.X + roamDir.X, moved.Y, moved.Z + roamDir.Z)
		local nextCFrame = if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, moved.X, moved.Z)
		return
	end

	-- Periodically shift flank direction, sector jitter, and standoff radius unpredictably so
	-- enemies resist being herded into predictable circles.
	if t >= enemy.orbitFlipAt then
		if math.random() < 0.7 then
			enemy.orbitSign = -enemy.orbitSign
		end
		enemy.sectorJitter = math.random() * 0.6 - 0.3
		enemy.radiusBias = math.random() * 5 - 2.5
		enemy.orbitFlipAt = t + Config.AI_SHIFT_MIN_SECONDS + math.random() * (Config.AI_SHIFT_MAX_SECONDS - Config.AI_SHIFT_MIN_SECONDS)
	end

	if enemy.kind == "melee" then
		enemy.model:SetAttribute("Role", if canAttack then "attacker" else "flanker")
	end

	local before = enemy.state.phase
	local state, intent = Brain.step(enemy.kind, enemy.spec, enemy.state, distance, t, canAttack)
	enemy.state = state
	if state.phase ~= before then
		local telegraphColor: Color3? = nil
		if state.phase == "phantomStep" or (state.phase == "windup" and (state.phantomStepFinisher or state.pendingPhantomStep)) then
			telegraphColor = Color3.fromRGB(70, 235, 255)
		elseif state.phase == "slamWindup" or state.phase == "axeThrowWindup" then
			telegraphColor = Color3.fromRGB(255, 165, 55)
		elseif state.phase == "spin" then
			telegraphColor = Color3.fromRGB(255, 85, 120)
		elseif state.phase == "beamCharge" then
			telegraphColor = Color3.fromRGB(90, 225, 255)
		elseif state.phase == "fuse" then
			telegraphColor = Color3.fromRGB(255, 110, 45)
		elseif state.phase == "rushWindup" or state.phase == "rush" then
			-- Red, not the grab's amber: a different tell for a different answer (dash sideways out
			-- of the line, rather than away).
			telegraphColor = Color3.fromRGB(255, 60, 60)
		elseif state.phase == "bossConeWindup" then
			telegraphColor = Color3.fromRGB(255, 130, 45)
		elseif state.phase == "bossLeapWindup" or state.phase == "bossLeap" then
			telegraphColor = Color3.fromRGB(255, 55, 70)
		elseif state.phase == "bossNovaWindup" then
			telegraphColor = Color3.fromRGB(215, 85, 255)
		elseif state.phase == "areaWindup" then
			telegraphColor = Color3.fromRGB(170, 255, 65)
		elseif state.phase == "contactWindup" then
			telegraphColor = Color3.fromRGB(255, 232, 75)
		elseif state.phase == "contactActive" then
			telegraphColor = Color3.fromRGB(55, 240, 255)
		elseif state.phase == "myDashWindup" or state.phase == "myDash" or state.phase == "myBladesWindup" then
			telegraphColor = Color3.fromRGB(220, 75, 255)
		elseif state.phase == "mySweepWindup" or state.phase == "mySweep" then
			telegraphColor = Color3.fromRGB(75, 240, 255)
		elseif state.phase == "gonRainWindup" or state.phase == "gonGravityWindup" or state.phase == "gonGravity" or state.phase == "gonRingsWindup" then
			telegraphColor = Color3.fromRGB(78, 255, 138)
		elseif state.phase == "bossPhaseShift" then
			telegraphColor = Color3.fromRGB(255, 42, 62)
		elseif state.phase == "windup" or state.phase == "lunge" then
			telegraphColor = Color3.fromRGB(255, 190, 85)
		end
		setTelegraph(enemy, telegraphColor ~= nil, telegraphColor)
		syncPhase(enemy, t)
		if before == "phantomStep" and state.phase ~= "phantomStep" then
			enemy.phantomStepIndex = 0
			enemy.phantomOrigin = nil
			enemy.phantomTarget = nil
		end
		local isPhantomFinisher = state.phase == "windup" and state.phantomStepFinisher == true
		local isPhantomAbility = state.phase == "phantomStep"
			or (state.phase == "windup" and (state.pendingPhantomStep == true or state.phantomStepFinisher == true))
		local isGrabAlert = enemy.kind == "grabber"
			and (state.phase == "windup" or state.phase == "lunge" or state.phase == "rushWindup" or state.phase == "rush")
		local isBossAlert = enemy.spec.isBoss == true
			and (
				state.phase == "bossConeWindup"
				or state.phase == "bossLeapWindup"
				or state.phase == "bossNovaWindup"
				or state.phase == "myDashWindup"
				or state.phase == "mySweepWindup"
				or state.phase == "gonGravityWindup"
				or state.phase == "gonRingsWindup"
			)
		local isAxeAlert = state.phase == "axeThrowWindup"
		enemy.model:SetAttribute("ParryTelegraph", isPhantomFinisher)
		enemy.model:SetAttribute("AlertIcon", isPhantomAbility or isGrabAlert or isBossAlert or isAxeAlert)
		enemy.model:SetAttribute("SlamRadius", if state.phase == "slamWindup" then (enemy.spec.slamRadius or 15.5) else nil)
		if state.phase == "bossConeWindup" then
			local toT = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
			local dir = if toT.Magnitude > 1e-3 then toT.Unit else Vector3.new(0, 0, -1)
			enemy.bossConeDir = dir
			enemy.model:SetAttribute("BossConeDir", dir)
			enemy.model:SetAttribute("BossConeRange", enemy.spec.coneRange or 24)
			enemy.model:SetAttribute("BossConeArc", enemy.spec.coneArc or 115)
			Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", position)
		elseif before == "bossConeWindup" then
			enemy.model:SetAttribute("BossConeDir", nil)
		end
		if state.phase == "bossLeapWindup" then
			local rawLand = Vector3.new(target.root.Position.X, enemy.spec.size.Y / 2, target.root.Position.Z)
			local clampedLand = Waves.clamp(rawLand, Config.ROOM_SIZE, WALL_MARGIN + enemy.radius)
			local safeLand = Waves.avoidObstacles(clampedLand, enemy.radius, activeObstacles())
			enemy.bossLeapTarget = safeLand
			enemy.model:SetAttribute("BossLeapTarget", Vector3.new(safeLand.X, 0.15, safeLand.Z))
			enemy.model:SetAttribute("BossLeapRadius", enemy.spec.leapRadius or 18)
			Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", position)
		elseif state.phase ~= "bossLeap" and (before == "bossLeapWindup" or before == "bossLeap") then
			enemy.model:SetAttribute("BossLeapTarget", nil)
		end
		if state.phase == "bossNovaWindup" then
			Remotes.CombatSfx:FireAllClients("playerHeavyCharge", position)
		end
		if state.phase == "myDashWindup" then
			local toT = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
			local dir = if toT.Magnitude > 1e-3 then toT.Unit else Vector3.new(0, 0, -1)
			enemy.myDashDir = dir
			enemy.model:SetAttribute("MyDashDir", dir)
			Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", position)
		elseif before == "myDashWindup" and state.phase ~= "myDash" then
			enemy.model:SetAttribute("MyDashDir", nil)
		end
		if state.phase == "mySweepWindup" then
			local toT = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
			local dir = if toT.Magnitude > 1e-3 then toT.Unit else Vector3.new(0, 0, -1)
			enemy.mySweepBaseDir = dir
			enemy.mySweepSign = if math.random() < 0.5 then 1 else -1
			enemy.model:SetAttribute("SweepDir", dir)
			enemy.model:SetAttribute("SweepRange", enemy.spec.mySweepRange or 42)
			enemy.model:SetAttribute("SweepActive", false)
			Remotes.CombatSfx:FireAllClients("playerHeavyCharge", position)
		elseif before == "mySweep" or (before == "mySweepWindup" and state.phase ~= "mySweep") then
			enemy.model:SetAttribute("SweepDir", nil)
			enemy.model:SetAttribute("SweepActive", false)
		end
		if state.phase == "gonGravityWindup" then
			local rawG = Vector3.new(target.root.Position.X, 0, target.root.Position.Z)
			local clampedG = Waves.clamp(rawG, Config.ROOM_SIZE, 14)
			enemy.gonGravityPos = Vector3.new(clampedG.X, 0, clampedG.Z)
			Remotes.CombatSfx:FireAllClients("playerHeavyCharge", position)
		elseif state.phase == "gonRainWindup" or state.phase == "gonRingsWindup" or state.phase == "myBladesWindup" then
			Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
		end
		if before == "evade" then
			-- Ensure ground elevation snaps cleanly to exact floor height on landing.
			local baseY = enemy.spec.size.Y / 2
			if math.abs(position.Y - baseY) > 0.01 then
				position = Vector3.new(position.X, baseY, position.Z)
			end
		end
		if state.phase == "windup" then
			if enemy.kind == "grabber" then
				Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", position)
				if warnGrab then
					warnGrab(target.player, state.endsAt + (enemy.spec.lungeDuration or 0))
				end
			elseif state.pendingPhantomStep then
				Remotes.CombatSfx:FireAllClients("playerHeavyCharge", position)
			elseif state.phantomStepFinisher then
				Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
				if warnParry then
					warnParry(target.player, state.endsAt)
				end
			else
				Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
			end
		elseif state.phase == "slamWindup" or state.phase == "axeThrowWindup" then
			Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
		elseif state.phase == "rushWindup" then
			Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", position)
		elseif state.phase == "spin" then
			Remotes.CombatSfx:FireAllClients("playerSpin", position)
		elseif state.phase == "beamCharge" then
			Remotes.CombatSfx:FireAllClients("playerHeavyCharge", position)
		elseif state.phase == "fuse" then
			Remotes.CombatSfx:FireAllClients("enemyExploderFuse", position)
		elseif state.phase == "areaWindup" then
			Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
		elseif state.phase == "contactWindup" then
			Remotes.CombatSfx:FireAllClients("enemyContactSurge", position)
		end
	end

	local function latchGrab(victim: Player)
		enemy.state = Brain.enterHolding(enemy.state)
		enemy.grabTarget = victim
		enemy.grabProgress = 0
		enemy.nextGrabDamageAt = t + Config.GRAB_DAMAGE_TICK_SECONDS
		enemy.lungeDirection = nil
		enemy.model:SetAttribute("AlertIcon", false)
		setTelegraph(enemy, false)
		syncPhase(enemy, t)
		if setGrabbed then
			setGrabbed(victim, true, 0, Config.GRAB_ESCAPE_PRESSES)
		end
		Remotes.CombatSfx:FireAllClients("enemyGrabberGrab", enemy.body.Position)
	end

	if intent.action == "strike" then
		Remotes.CombatSfx:FireAllClients("enemyMeleeStrike", position)
		if enemy.hasJoints then
			Remotes.EnemyAnim:FireAllClients("strike", enemy.model, enemy.weapon)
		end
		if enemy.state.phantomStepFinisher then
			-- Paso Fantasma ambush finisher is unavoidable at hyper-speed: even if the player runs,
			-- jumps, or Dashes, the swordsman stays locked on them and only a timed Parry stops it.
			local baseY = enemy.spec.size.Y / 2
			local toEnemy = Vector3.new(position.X - target.root.Position.X, 0, position.Z - target.root.Position.Z)
			local offsetDir = if toEnemy.Magnitude > 1e-3
				then toEnemy.Unit
				else -Vector3.new(target.root.CFrame.LookVector.X, 0, target.root.CFrame.LookVector.Z).Unit
			local snapXZ = clampEnemyPos(target.root.Position + offsetDir * 4.4, enemy.radius)
			local snapPos = Vector3.new(snapXZ.X, baseY, snapXZ.Z)
			local lookAtPlayer = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
			if (lookAtPlayer - snapPos).Magnitude > 1e-3 then
				moveEnemy(enemy, CFrame.lookAt(snapPos, lookAtPlayer))
			else
				moveEnemy(enemy, CFrame.new(snapPos))
			end
			grid:move(enemy, snapPos.X, snapPos.Z)
			position = snapPos

			local strikeDamage = enemy.spec.phantomStepDamage or enemy.spec.damage
			local _, outcome = hurt(target.player, strikeDamage, {
				canDodge = false,
				canBlock = false,
				canParry = true,
			})
			if outcome == "parry" then
				EnemyService.stun(enemy, Config.PARRY_STUN_SECONDS)
			end
		else
			-- Checked in 3D at the moment of the strike: dashing out or jumping over during the windup
			-- both earn the miss.
			local strikeRadius = (enemy.spec.reach + enemy.radius) * 1.2
			local strikeHeight = enemy.spec.strikeHeight or enemy.spec.size.Y
			if Hitbox.inEllipsoid(position, target.root.Position, strikeRadius, strikeHeight) then
				local _, outcome = hurt(target.player, enemy.spec.damage, { canBlock = true, canParry = true })
				if outcome == "parry" then
					-- Parrying a melee strike hard-stuns the attacker in place with dazed visuals.
					EnemyService.stun(enemy, Config.PARRY_STUN_SECONDS)
				end
			end
		end
	elseif intent.action == "slam" then
		-- Heavy mace ground slam: seismic shockwave that staggers & stuns grounded players inside
		-- `slamRadius` (jumping over `slamHeight` or Dashing with i-frames cleanly avoids it).
		local slamRadius = enemy.spec.slamRadius or 15.5
		local slamHeight = enemy.spec.slamHeight or 4.2
		local slamDamage = enemy.spec.slamDamage or 14
		local slamStun = enemy.spec.slamStunDuration or 1.6
		Remotes.CombatSfx:FireAllClients("enemyExploderBlast", position)
		Remotes.EnemyAnim:FireAllClients("slamImpact", enemy.model, position, slamRadius)
		for _, candidate in ipairs(list) do
			if Hitbox.inEllipsoid(position, candidate.root.Position, slamRadius, slamHeight) then
				local landed, outcome = hurt(candidate.player, slamDamage, { canBlock = true, canParry = false })
				if landed and stunPlayer then
					local stunDur = if outcome == "block" then slamStun * 0.45 else slamStun
					stunPlayer(candidate.player, stunDur)
				end
			end
		end
	elseif intent.action == "spinTick" then
		-- Dual-blade tornado spin DPS tick: hits every living free player inside `spinRadius`.
		-- Parrying a tick interrupts the spin and staggers the attacker into `recover`.
		Remotes.CombatSfx:FireAllClients("enemyMeleeStrike", position)
		local spinRadius = enemy.spec.spinRadius or 8.0
		local strikeHeight = enemy.spec.strikeHeight or enemy.spec.size.Y
		local tickDamage = enemy.spec.spinTickDamage or 6
		for _, candidate in ipairs(list) do
			if Hitbox.inEllipsoid(position, candidate.root.Position, spinRadius, strikeHeight) then
				local _, outcome = hurt(candidate.player, tickDamage, { canBlock = true, canParry = true })
				if outcome == "parry" then
					EnemyService.stun(enemy, Config.PARRY_STUN_SECONDS)
					break
				end
			end
		end
	elseif intent.action == "grab" then
		if distance <= (enemy.spec.reach + enemy.radius) * 1.2 and (not canGrab or canGrab(target.player)) then
			latchGrab(target.player)
			return
		end
	elseif intent.action == "grabLunge" or intent.action == "grabCheck" then
		if intent.action == "grabLunge" then
			-- Lock charge heading when the lunge launches so a well-timed lateral Dash dodges it.
			local toTarget = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
			local fallback = Vector3.new(body.CFrame.LookVector.X, 0, body.CFrame.LookVector.Z)
			if toTarget.Magnitude > 1e-3 then
				enemy.lungeDirection = toTarget.Unit
			elseif fallback.Magnitude > 1e-3 then
				enemy.lungeDirection = fallback.Unit
			else
				enemy.lungeDirection = Vector3.new(0, 0, -1)
			end
			Remotes.CombatSfx:FireAllClients("enemyMeleeStrike", position)
		end
		local catchRadius = enemy.spec.grabRadius or 4.6
		for _, candidate in ipairs(list) do
			local dXZ = Vector3.new(candidate.root.Position.X - position.X, 0, candidate.root.Position.Z - position.Z).Magnitude
			if dXZ <= catchRadius and (not canGrab or canGrab(candidate.player)) then
				latchGrab(candidate.player)
				return
			end
		end
	elseif intent.action == "rushLaunch" then
		-- Heading locked here, at the end of the windup, like the grab lunge: the windup is the
		-- warning, and stepping sideways out of the line is the counter.
		local toTarget = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
		local fallback = Vector3.new(body.CFrame.LookVector.X, 0, body.CFrame.LookVector.Z)
		if toTarget.Magnitude > 1e-3 then
			enemy.rushDirection = toTarget.Unit
		elseif fallback.Magnitude > 1e-3 then
			enemy.rushDirection = fallback.Unit
		else
			enemy.rushDirection = Vector3.new(0, 0, -1)
		end
		enemy.rushHit = {}
		Remotes.CombatSfx:FireAllClients("enemyMeleeStrike", position)
	elseif intent.action == "beamStart" then
		local toTarget = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
		local dir = if toTarget.Magnitude > 1e-3 then toTarget.Unit else Vector3.new(0, 0, -1)
		enemy.beamDirection = dir
		enemy.beamLocked = false
		enemy.model:SetAttribute("BeamDir", dir)
		enemy.model:SetAttribute("BeamLocked", false)
		enemy.model:SetAttribute("BeamRange", enemy.spec.beamRange or 55)
	elseif intent.action == "beamFire" then
		local toTarget = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
		local dir = enemy.beamDirection or (if toTarget.Magnitude > 1e-3 then toTarget.Unit else Vector3.new(0, 0, -1))
		local beamOrigin = Vector3.new(position.X, 2.4, position.Z)
		local beamRange = enemy.spec.beamRange or 65
		local beamRadius = enemy.spec.beamRadius or 2.6
		local beamHeight = enemy.spec.beamHeight or 3.4
		local beamDamage = enemy.spec.beamDamage or 32

		enemy.beamDirection = nil
		enemy.beamLocked = false
		enemy.model:SetAttribute("BeamDir", nil)
		enemy.model:SetAttribute("BeamLocked", false)
		lastRangedShotAt[target.player] = t

		Remotes.EnemyAnim:FireAllClients("beamFire", enemy.model, beamOrigin, dir, beamRange)
		Remotes.CombatSfx:FireAllClients("playerHeavyAttack", position)
		for _, candidate in ipairs(list) do
			if Hitbox.inBeam(beamOrigin, dir, beamRange, candidate.root.Position, beamRadius, beamHeight) then
				hurt(candidate.player, beamDamage, { canBlock = true, canParry = false, origin = beamOrigin })
			end
		end
	elseif intent.action == "evade" then
		-- Fast backstep leap away from a close player. If backed into a wall/corner, pick the
		-- clearest lateral escape path along the room edge so the unit never leaps into a wall.
		enemy.burstLeft = 0
		local away = Vector3.new(position.X - target.root.Position.X, 0, position.Z - target.root.Position.Z)
		local awayUnit = if away.Magnitude > 1e-3 then away.Unit else Vector3.new(0, 0, 1)
		local side = Vector3.new(-awayUnit.Z * enemy.orbitSign, 0, awayUnit.X * enemy.orbitSign)
		local leapDist = enemy.spec.evadeDistance or 20
		local baseY = enemy.spec.size.Y / 2

		local candidates = {
			(awayUnit + side * 0.28).Unit,
			(awayUnit - side * 0.28).Unit,
			(side + awayUnit * 0.2).Unit,
			(-side + awayUnit * 0.2).Unit,
		}
		local bestLanding = clampEnemyPos(position + candidates[1] * leapDist, enemy.radius)
		local bestClearance = Vector3.new(bestLanding.X - position.X, 0, bestLanding.Z - position.Z).Magnitude
		if bestClearance < leapDist * 0.55 then
			for i = 2, #candidates do
				local landing = clampEnemyPos(position + candidates[i] * leapDist, enemy.radius)
				local clearance = Vector3.new(landing.X - position.X, 0, landing.Z - position.Z).Magnitude
				if clearance > bestClearance then
					bestClearance = clearance
					bestLanding = landing
				end
			end
		end

		enemy.evadeOrigin = Vector3.new(position.X, baseY, position.Z)
		enemy.evadeTarget = Vector3.new(bestLanding.X, baseY, bestLanding.Z)
		enemy.evadeStartedAt = t
		enemy.evadeDuration = enemy.spec.evadeDuration or 0.34
		Remotes.CombatSfx:FireAllClients("playerDash", position)
	elseif intent.action == "phantomStepHop" then
		-- Single-sword Paso Fantasma: chain 3+ rapid dashes across sharp angles before
		-- snapping close behind the player for a surprise parry-only slash.
		if before ~= "phantomStep" then
			enemy.phantomStepIndex = 1
		else
			enemy.phantomStepIndex += 1
		end
		local totalSteps = math.max(enemy.spec.phantomStepCount or 3, 3)
		local rawWaypoint = Tactics.phantomStepWaypoint(
			position,
			target.root.Position,
			target.root.CFrame.LookVector,
			enemy.phantomStepIndex,
			totalSteps,
			enemy.orbitSign
		)
		local clamped = clampEnemyPos(rawWaypoint, enemy.radius)
		local baseY = enemy.spec.size.Y / 2
		enemy.phantomOrigin = Vector3.new(position.X, baseY, position.Z)
		enemy.phantomTarget = Vector3.new(clamped.X, baseY, clamped.Z)
		enemy.phantomStartedAt = t
		enemy.phantomDuration = enemy.spec.phantomStepDuration or 0.15
		Remotes.CombatSfx:FireAllClients("playerDash", position)
	elseif intent.action == "axeThrow" then
		throwAxe(enemy, target.root)
	elseif intent.action == "fire" then
		lastRangedShotAt[target.player] = t
		local burstCount = enemy.spec.burstCount or 1
		if burstCount > 1 then
			enemy.burstLeft = burstCount - 1
			enemy.nextBurstAt = t + (enemy.spec.burstInterval or 0.18)
		end
		fire(enemy, target.root)
	elseif intent.action == "bossConeSmash" then
		-- Boss Oh: massive frontal cone smash with Titanic Maul.
		local toT = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
		local dir = enemy.bossConeDir or (if toT.Magnitude > 1e-3 then toT.Unit else Vector3.new(0, 0, -1))
		local coneRange = enemy.spec.coneRange or 24
		local coneArc = enemy.spec.coneArc or 115
		local coneDamage = enemy.spec.coneDamage or 26
		local coneStun = enemy.spec.coneStunDuration or 0.9
		enemy.bossConeDir = nil
		Remotes.CombatSfx:FireAllClients("enemyExploderBlast", position)
		Remotes.EnemyAnim:FireAllClients("bossConeSmash", enemy.model, position, dir, coneRange)
		for _, candidate in ipairs(list) do
			if Melee.inArc(position, dir, candidate.root.Position, coneRange, coneArc) then
				local landed, outcome = hurt(candidate.player, coneDamage, { canBlock = true, canParry = false, origin = position })
				if landed and stunPlayer then
					stunPlayer(candidate.player, if outcome == "block" then coneStun * 0.45 else coneStun)
				end
			end
		end
	elseif intent.action == "bossLeapLaunch" then
		enemy.bossLeapOrigin = position
		enemy.bossLeapStartedAt = t
		enemy.bossLeapDuration = enemy.spec.leapDuration or 0.72
		if not enemy.bossLeapTarget then
			local rawLand = Vector3.new(target.root.Position.X, enemy.spec.size.Y / 2, target.root.Position.Z)
			enemy.bossLeapTarget = Waves.avoidObstacles(Waves.clamp(rawLand, Config.ROOM_SIZE, WALL_MARGIN + enemy.radius), enemy.radius, activeObstacles())
		end
		Remotes.CombatSfx:FireAllClients("playerDash", position)
	elseif intent.action == "bossLeapLand" then
		local baseY = enemy.spec.size.Y / 2
		local land = enemy.bossLeapTarget or Vector3.new(position.X, baseY, position.Z)
		local landPos = Vector3.new(land.X, baseY, land.Z)
		local look = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
		moveEnemy(enemy, if (look - landPos).Magnitude > 1e-3 then CFrame.lookAt(landPos, look) else CFrame.new(landPos))
		grid:move(enemy, landPos.X, landPos.Z)
		position = landPos
		enemy.bossLeapOrigin = nil
		enemy.bossLeapTarget = nil
		enemy.model:SetAttribute("BossLeapTarget", nil)

		local leapRadius = enemy.spec.leapRadius or 18
		local leapHeight = enemy.spec.leapHeight or 5.0
		local leapDamage = enemy.spec.leapDamage or 32
		local leapStun = enemy.spec.leapStunDuration or 1.2
		Remotes.CombatSfx:FireAllClients("enemyExploderBlast", landPos)
		Remotes.EnemyAnim:FireAllClients("slamImpact", enemy.model, landPos, leapRadius)
		for _, candidate in ipairs(list) do
			if Hitbox.inEllipsoid(landPos, candidate.root.Position, leapRadius, leapHeight) then
				local landed, outcome = hurt(candidate.player, leapDamage, { canBlock = true, canParry = false, origin = landPos })
				if landed and stunPlayer then
					stunPlayer(candidate.player, if outcome == "block" then leapStun * 0.45 else leapStun)
				end
			end
		end
	elseif intent.action == "bossNovaFire" then
		-- Boss Oh / OhMyGon: fires staggered 360-deg rings of plasma orbs (jumpable, cover-blockable, and parriable!).
		local wavesCount = (enemy.spec.novaWaves or 2) + (if enemy.state.bossPhase2 then 1 else 0)
		local orbCount = enemy.spec.novaOrbCount or 10
		local orbSpeed = enemy.spec.novaOrbSpeed or 34
		local orbDamage = enemy.spec.novaDamage or 18
		local function emitRing(angleOffset: number)
			if enemy.dead then
				return
			end
			local ringOrigin = enemy.body.Position
			Remotes.CombatSfx:FireAllClients("enemyRangedFire", ringOrigin)
			for k = 0, orbCount - 1 do
				local angle = angleOffset + (k / orbCount) * math.pi * 2
				local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
				local part = Instance.new("Part")
				part.Name = "BossNovaOrb"
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.Shape = Enum.PartType.Ball
				part.Size = Vector3.one * 2.15
				part.Color = Color3.fromRGB(255, 115, 45)
				part.Material = Enum.Material.Neon
				local orbPos = Vector3.new(ringOrigin.X + dir.X * (enemy.radius + 1.5), Config.PROJECTILE_HEIGHT, ringOrigin.Z + dir.Z * (enemy.radius + 1.5))
				part.Position = orbPos
				part.Parent = folder
				table.insert(projectiles, {
					part = part,
					position = orbPos,
					velocity = dir * orbSpeed,
					expiresAt = now() + 3.2,
					damage = orbDamage,
					reflected = false,
					isTracer = false,
					canParry = true,
					shooter = enemy,
				})
			end
		end
		emitRing(0)
		for w = 2, wavesCount do
			local offset = (math.pi / orbCount) * (w - 1)
			task.delay(0.35 * (w - 1), function()
				if not enemy.dead and enemy.body.Parent and not (isPaused and isPaused()) then
					emitRing(offset)
				end
			end)
		end
	elseif intent.action == "explode" then
		explode(enemy, list)
		return
	elseif intent.action == "areaLaunch" then
		lastAreaLaunchAt[target.player] = t
		launchAreaHazard(enemy, target.root.Position, grabbedPositions, t)
	elseif intent.action == "contactSurgeStart" then
		Remotes.CombatSfx:FireAllClients("enemyContactZap", position)
	elseif intent.action == "myDashLaunch" then
		local toT = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
		local dir = if toT.Magnitude > 1e-3 then toT.Unit else (enemy.myDashDir or Vector3.new(0, 0, -1))
		enemy.myDashDir = dir
		enemy.myDashHit = {}
		enemy.model:SetAttribute("MyDashDir", dir)
		Remotes.CombatSfx:FireAllClients("playerDash", position)
	elseif intent.action == "mySweepStart" then
		enemy.mySweepStartedAt = t
		enemy.mySweepDuration = enemy.spec.mySweepDuration or 1.15
		table.clear(enemy.mySweepHitAt)
		enemy.model:SetAttribute("SweepActive", true)
		Remotes.CombatSfx:FireAllClients("playerHeavyAttack", position)
	elseif intent.action == "myBladesFire" then
		local toT = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
		local baseDir = if toT.Magnitude > 1e-3 then toT.Unit else Vector3.new(0, 0, -1)
		local count = (enemy.spec.myBladesCount or 4) + (if enemy.state.bossPhase2 then 2 else 0)
		local spread = enemy.spec.myBladesSpreadDeg or 54
		local speed = enemy.spec.myBladeSpeed or 56
		local dmg = enemy.spec.myBladeDamage or 16
		local spawnPos = Vector3.new(position.X, Config.PROJECTILE_HEIGHT + 0.3, position.Z)
		for b = 1, count do
			local frac = if count > 1 then ((b - 1) / (count - 1) - 0.5) else 0
			local rad = math.rad(frac * spread)
			local c, s = math.cos(rad), math.sin(rad)
			local dir = Vector3.new(baseDir.X * c - baseDir.Z * s, 0, baseDir.X * s + baseDir.Z * c).Unit
			local blade = Instance.new("Part")
			blade.Name = "BossMyBlade"
			blade.Anchored = true
			blade.CanCollide = false
			blade.CanQuery = false
			blade.CanTouch = false
			blade.Material = Enum.Material.Neon
			blade.Color = if b % 2 == 0 then Color3.fromRGB(70, 242, 255) else Color3.fromRGB(224, 78, 255)
			blade.Size = Vector3.new(2.2, 0.32, 3.6)
			blade.CFrame = CFrame.lookAt(spawnPos, spawnPos + dir)
			blade.Parent = folder
			table.insert(projectiles, {
				part = blade,
				position = spawnPos,
				velocity = dir * speed,
				expiresAt = t + 2.6,
				damage = dmg,
				reflected = false,
				isTracer = true,
				canParry = true,
				shooter = enemy,
			})
		end
		Remotes.CombatSfx:FireAllClients("enemyRangedFire", position)
	elseif intent.action == "gonRainFire" then
		local count = (enemy.spec.gonRainCount or 4) + (if enemy.state.bossPhase2 then 1 else 0)
		local overrides = {
			radius = enemy.spec.gonRainRadius or 10,
			telegraph = enemy.spec.gonRainTelegraph or 1.1,
			duration = enemy.spec.gonRainDuration or 4.0,
			impactDamage = enemy.spec.gonRainImpactDamage or 18,
			tickDamage = enemy.spec.gonRainTickDamage or 10,
		}
		-- First zone targets player; remaining zones form a tactical ring cutting off escape lanes.
		launchAreaHazard(enemy, target.root.Position, grabbedPositions, t, overrides)
		for k = 2, count do
			local angle = ((k - 2) / math.max(count - 1, 1)) * math.pi * 2 + math.random() * 0.5
			local dist = 16 + math.random() * 14
			local spot = target.root.Position + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
			launchAreaHazard(enemy, spot, grabbedPositions, t, overrides)
		end
	elseif intent.action == "gonGravityStart" then
		local gPos = enemy.gonGravityPos or Vector3.new(target.root.Position.X, 0, target.root.Position.Z)
		enemy.gonGravityPos = gPos
		enemy.gonGravityNextPullAt = t
		local pullR = enemy.spec.gonGravityPullRadius or 24
		local coreR = enemy.spec.gonGravityCoreRadius or 12
		local ring = Instance.new("Part")
		ring.Name = "GonGravityWell"
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.Material = Enum.Material.Neon
		ring.Color = Color3.fromRGB(68, 255, 145)
		ring.Transparency = 0.68
		ring.Size = Vector3.new(0.22, pullR * 2, pullR * 2)
		ring.CFrame = CFrame.new(gPos.X, 0.18, gPos.Z) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = folder
		enemy.gonGravityRing = ring

		local core = Instance.new("Part")
		core.Name = "GonGravityCore"
		core.Shape = Enum.PartType.Cylinder
		core.Anchored = true
		core.CanCollide = false
		core.CanQuery = false
		core.CanTouch = false
		core.Material = Enum.Material.Neon
		core.Color = Color3.fromRGB(230, 255, 95)
		core.Transparency = 0.45
		core.Size = Vector3.new(0.28, coreR * 2, coreR * 2)
		core.CFrame = CFrame.new(gPos.X, 0.24, gPos.Z) * CFrame.Angles(0, 0, math.rad(90))
		core.Parent = folder
		enemy.gonGravityCore = core
	elseif intent.action == "gonGravityEnd" then
		local gPos = enemy.gonGravityPos
		clearBossEffects(enemy)
		if gPos then
			local coreR = enemy.spec.gonGravityCoreRadius or 12
			local dmg = enemy.spec.gonGravityDamage or 28
			burst(gPos + Vector3.new(0, 1, 0), coreR, Color3.fromRGB(85, 255, 145), 6)
			Remotes.CombatSfx:FireAllClients("enemyExploderBlast", gPos)
			for _, candidate in ipairs(list) do
				if Hitbox.inEllipsoid(gPos, candidate.root.Position, coreR, 5.5) then
					local landed, outcome = hurt(candidate.player, dmg, { canBlock = true, canParry = false, origin = gPos })
					if landed and stunPlayer then
						stunPlayer(candidate.player, if outcome == "block" then 0.4 else 0.85)
					end
				end
			end
		end
	elseif intent.action == "gonRingsFire" then
		local count = (enemy.spec.gonRingsCount or 2) + (if enemy.state.bossPhase2 then 1 else 0)
		local maxR = enemy.spec.gonRingMaxRadius or 46
		local dur = enemy.spec.gonRingDuration or 1.25
		local h = enemy.spec.gonRingHeight or 3.2
		local dmg = enemy.spec.gonRingDamage or 20
		local color = if enemy.kind == "bossOhMyGon" then Color3.fromRGB(255, 85, 72) else Color3.fromRGB(85, 255, 145)
		spawnShockRing(position, maxR, dur, h, dmg, color, t)
		for k = 2, count do
			task.delay(0.45 * (k - 1), function()
				if not enemy.dead and enemy.body.Parent and not (isPaused and isPaused()) then
					spawnShockRing(enemy.body.Position, maxR, dur, h, dmg, color, now())
				end
			end)
		end
	elseif intent.action == "bossPhaseShiftDone" then
		syncBossHud(enemy)
	end

	-- Continue any in-progress multi-shot burst (double-shot shotgun/plasma or 6-round minigun).
	if enemy.burstLeft > 0 and t >= enemy.nextBurstAt then
		enemy.burstLeft -= 1
		enemy.nextBurstAt = t + (enemy.spec.burstInterval or 0.18)
		fire(enemy, target.root)
	end

	-- Hitstun: enemy is reeling from player hits, cannot attack or chase, only slides briefly on
	-- damped micro-knockback with heavily reduced separation so combos stay rock-solid.
	if enemy.state.phase == "hitstun" then
		local baseY = enemy.spec.size.Y / 2
		local standPos = Vector3.new(position.X, baseY, position.Z)
		local recoil = Vector3.zero
		if enemy.knockbackDir and t < enemy.knockbackEndsAt then
			local dur = math.max(Config.ENEMY_KNOCKBACK_DURATION, 0.04)
			local remain = math.clamp((enemy.knockbackEndsAt - t) / dur, 0, 1)
			recoil = enemy.knockbackDir * (enemy.knockbackSpeed * remain)
		end
		local push = separationPush(enemy, standPos) * Config.ENEMY_HITSTUN_SEPARATION_SCALE
		local candidate = standPos + (recoil + push * enemy.spec.speed) * dt
		local moved = clampEnemyPos(candidate, enemy.radius)
		local look = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
		local nextCFrame = if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, moved.X, moved.Z)
		return
	end

	local toward = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
	local direction = Vector3.zero
	local speedScale = 1
	-- Progressive post-hitstun daze slowdown: consecutive combo hits leave the target sluggish
	-- even after hitstun expires, decaying once the daze window clears.
	if t < enemy.dazeUntil then
		speedScale *= Brain.dazeSpeedFactor(enemy.staggerStacks, Config.ENEMY_DAZE_SPEED_FACTORS)
	elseif enemy.staggerStacks > 0 then
		enemy.staggerStacks = 0
	end
	local isLunging = intent.move == "lunge"
	if intent.move == "phantomStep" and enemy.phantomOrigin and enemy.phantomTarget then
		local dur = math.max(enemy.phantomDuration, 0.04)
		local u = math.clamp((t - enemy.phantomStartedAt) / dur, 0, 1)
		local ease = 1 - (1 - u) * (1 - u)
		local baseY = enemy.spec.size.Y / 2
		local rawDash = Vector3.new(
			enemy.phantomOrigin.X + (enemy.phantomTarget.X - enemy.phantomOrigin.X) * ease,
			baseY,
			enemy.phantomOrigin.Z + (enemy.phantomTarget.Z - enemy.phantomOrigin.Z) * ease
		)
		local dashPos = clampEnemyPos(rawDash, enemy.radius)
		local totalSteps = math.max(enemy.spec.phantomStepCount or 3, 3)
		local travel = Vector3.new(enemy.phantomTarget.X - enemy.phantomOrigin.X, 0, enemy.phantomTarget.Z - enemy.phantomOrigin.Z)
		local lookTarget: Vector3
		if enemy.phantomStepIndex >= totalSteps and u >= 0.65 then
			lookTarget = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
		elseif travel.Magnitude > 1e-3 then
			lookTarget = dashPos + travel.Unit
		else
			lookTarget = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
		end
		local nextCFrame = if (lookTarget - dashPos).Magnitude > 1e-3
			then CFrame.lookAt(dashPos, lookTarget)
			else CFrame.new(dashPos)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, dashPos.X, dashPos.Z)
		return
	elseif enemy.state.phase == "windup" and enemy.state.phantomStepFinisher then
		-- Shadow-step lock during the Paso Fantasma finisher windup: if the player tries to sprint,
		-- jump, or Dash out of range, the hyper-speed swordsman sticks right on them.
		local baseY = enemy.spec.size.Y / 2
		local toEnemy = Vector3.new(position.X - target.root.Position.X, 0, position.Z - target.root.Position.Z)
		local offsetDir = if toEnemy.Magnitude > 1e-3
			then toEnemy.Unit
			else -Vector3.new(target.root.CFrame.LookVector.X, 0, target.root.CFrame.LookVector.Z).Unit
		local desiredXZ = clampEnemyPos(target.root.Position + offsetDir * 4.4, enemy.radius)
		local alpha = math.clamp(dt * 24, 0, 1)
		local lockPos = clampEnemyPos(
			Vector3.new(
				position.X + (desiredXZ.X - position.X) * alpha,
				baseY,
				position.Z + (desiredXZ.Z - position.Z) * alpha
			),
			enemy.radius
		)
		local look = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
		local nextCFrame = if (look - lockPos).Magnitude > 1e-3 then CFrame.lookAt(lockPos, look) else CFrame.new(lockPos)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, lockPos.X, lockPos.Z)
		return
	elseif intent.move == "bossLeap" and enemy.bossLeapOrigin and enemy.bossLeapTarget then
		-- Parabolic meteor leap arc across the arena straight onto the locked red target circle.
		local dur = math.max(enemy.bossLeapDuration, 0.1)
		local u = math.clamp((t - enemy.bossLeapStartedAt) / dur, 0, 1)
		local arcHeight = enemy.spec.leapArcHeight or 16
		local baseY = enemy.spec.size.Y / 2
		local leapPos = Vector3.new(
			enemy.bossLeapOrigin.X + (enemy.bossLeapTarget.X - enemy.bossLeapOrigin.X) * u,
			baseY + 4 * arcHeight * u * (1 - u),
			enemy.bossLeapOrigin.Z + (enemy.bossLeapTarget.Z - enemy.bossLeapOrigin.Z) * u
		)
		local look = Vector3.new(enemy.bossLeapTarget.X, leapPos.Y, enemy.bossLeapTarget.Z)
		local nextCFrame = if (look - leapPos).Magnitude > 1e-3 then CFrame.lookAt(leapPos, look) else CFrame.new(leapPos)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, leapPos.X, leapPos.Z)
		return
	elseif intent.move == "evade" and enemy.evadeOrigin and enemy.evadeTarget then
		-- Parabolic backstep leap: fast horizontal ease-out + real aerial jump arc, facing the player.
		local dur = math.max(enemy.evadeDuration, 0.05)
		local u = math.clamp((t - enemy.evadeStartedAt) / dur, 0, 1)
		local ease = 1 - (1 - u) * (1 - u)
		local arcHeight = enemy.spec.evadeArcHeight or 5.5
		local baseY = enemy.spec.size.Y / 2
		local rawLeap = Vector3.new(
			enemy.evadeOrigin.X + (enemy.evadeTarget.X - enemy.evadeOrigin.X) * ease,
			baseY + 4 * arcHeight * u * (1 - u),
			enemy.evadeOrigin.Z + (enemy.evadeTarget.Z - enemy.evadeOrigin.Z) * ease
		)
		local leapPos = clampEnemyPos(rawLeap, enemy.radius)
		local look = Vector3.new(target.root.Position.X, leapPos.Y, target.root.Position.Z)
		local nextCFrame = if (look - leapPos).Magnitude > 1e-3 then CFrame.lookAt(leapPos, look) else CFrame.new(leapPos)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, leapPos.X, leapPos.Z)
		return
	elseif enemy.state.phase == "beamCharge" then
		-- Track the player until the final `beamLockTime` lock window so players can sidestep,
		-- jump over, or dash out of the locked red rail-beam line.
		local lockWindow = enemy.spec.beamLockTime or 0.4
		if not enemy.beamLocked then
			if state.endsAt - t <= lockWindow then
				enemy.beamLocked = true
				enemy.model:SetAttribute("BeamLocked", true)
			elseif toward.Magnitude > 1e-3 then
				enemy.beamDirection = toward.Unit
				enemy.model:SetAttribute("BeamDir", enemy.beamDirection)
			end
		end
		local aimDir = enemy.beamDirection or (if toward.Magnitude > 1e-3 then toward.Unit else Vector3.new(0, 0, -1))
		local baseY = enemy.spec.size.Y / 2
		local standPos = Vector3.new(position.X, baseY, position.Z)
		moveEnemy(enemy, CFrame.lookAt(standPos, standPos + aimDir))
		return
	elseif intent.move == "myDash" then
		-- Boss My / OhMyGon high-speed photonic dash slash: parriable at crossing!
		local dashDir = enemy.myDashDir or (if toward.Magnitude > 1e-3 then toward.Unit else Vector3.new(0, 0, -1))
		local dashSpeed = enemy.spec.myDashSpeed or 82
		local candidatePos = position + dashDir * dashSpeed * dt
		local moved = clampEnemyPos(candidatePos, enemy.radius)
		local look = Vector3.new(moved.X + dashDir.X, moved.Y, moved.Z + dashDir.Z)
		moveEnemy(enemy, if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved))
		grid:move(enemy, moved.X, moved.Z)
		local hitSet = enemy.myDashHit or {}
		enemy.myDashHit = hitSet
		local hitRadius = enemy.spec.myDashRadius or 5.4
		for _, candidate in ipairs(list) do
			if not hitSet[candidate.player] and Hitbox.inEllipsoid(moved, candidate.root.Position, hitRadius, 5.2) then
				hitSet[candidate.player] = true
				local _, outcome = hurt(candidate.player, enemy.spec.myDashDamage or 20, { canBlock = true, canParry = true, origin = moved })
				if outcome == "parry" then
					EnemyService.stun(enemy, Config.PARRY_STUN_SECONDS)
					return
				end
			end
		end
		return
	elseif intent.move == "mySweep" then
		-- Boss My / OhMyGon continuous sweeping photonic laser across `mySweepArc` (140 deg).
		local baseDir = enemy.mySweepBaseDir or (if toward.Magnitude > 1e-3 then toward.Unit else Vector3.new(0, 0, -1))
		local dur = math.max(enemy.mySweepDuration, 0.2)
		local u = math.clamp((t - enemy.mySweepStartedAt) / dur, 0, 1)
		local halfArc = math.rad((enemy.spec.mySweepArc or 140) * 0.5)
		local theta = (-halfArc + u * halfArc * 2) * enemy.mySweepSign
		local c, s = math.cos(theta), math.sin(theta)
		local curDir = Vector3.new(baseDir.X * c - baseDir.Z * s, 0, baseDir.X * s + baseDir.Z * c).Unit
		enemy.model:SetAttribute("SweepDir", curDir)
		local baseY = enemy.spec.size.Y / 2
		local standPos = Vector3.new(position.X, baseY, position.Z)
		moveEnemy(enemy, CFrame.lookAt(standPos, standPos + curDir))
		local beamOrigin = Vector3.new(standPos.X, 2.4, standPos.Z)
		local range = enemy.spec.mySweepRange or 42
		local height = enemy.spec.mySweepHeight or 3.5
		local dmg = enemy.spec.mySweepDamage or 18
		for _, candidate in ipairs(list) do
			local nextAt = enemy.mySweepHitAt[candidate.player] or 0
			if t >= nextAt and Hitbox.inBeam(beamOrigin, curDir, range, candidate.root.Position, 2.4, height) then
				enemy.mySweepHitAt[candidate.player] = t + 0.45
				hurt(candidate.player, dmg, { canBlock = true, canParry = false, origin = beamOrigin })
			end
		end
		return
	elseif enemy.state.phase == "gonGravity" and enemy.gonGravityPos then
		-- Active Gravity Well gently pulls free players inward toward the core before detonation.
		local gPos = enemy.gonGravityPos
		local pullR = enemy.spec.gonGravityPullRadius or 24
		if t >= enemy.gonGravityNextPullAt then
			enemy.gonGravityNextPullAt = t + 0.25
			for _, candidate in ipairs(list) do
				local toCenter = Vector3.new(gPos.X - candidate.root.Position.X, 0, gPos.Z - candidate.root.Position.Z)
				local dist = toCenter.Magnitude
				if dist > 2.5 and dist <= pullR then
					Remotes.Knockback:FireClient(candidate.player, toCenter.Unit, 22, 0, 0.18)
				end
			end
		end
		local baseY = enemy.spec.size.Y / 2
		local standPos = Vector3.new(position.X, baseY, position.Z)
		local look = Vector3.new(gPos.X, baseY, gPos.Z)
		if (look - standPos).Magnitude > 1e-3 then
			moveEnemy(enemy, CFrame.lookAt(standPos, look))
		end
		return
	elseif enemy.state.phase == "bossPhaseShift" then
		return
	elseif intent.move == "rush" then
		local rushDir = enemy.rushDirection or (if toward.Magnitude > 1e-3 then toward.Unit else Vector3.new(0, 0, -1))
		local rushSpeed = enemy.spec.rushSpeed or (enemy.spec.speed * 4)
		local candidatePos = position + rushDir * rushSpeed * dt
		local moved = clampEnemyPos(candidatePos, enemy.radius)
		local look = Vector3.new(moved.X + rushDir.X, moved.Y, moved.Z + rushDir.Z)
		moveEnemy(enemy, if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved))
		grid:move(enemy, moved.X, moved.Z)
		-- Checked after this frame's step, so a 58 stud/s charge cannot tunnel past a player.
		local hitAlready = enemy.rushHit or {}
		enemy.rushHit = hitAlready
		for _, candidate in ipairs(list) do
			if
				not hitAlready[candidate.player]
				and Hitbox.inEllipsoid(moved, candidate.root.Position, enemy.spec.rushHitRadius or 5.2, enemy.spec.rushHitHeight or 5)
			then
				hitAlready[candidate.player] = true
				local landed, outcome = hurt(candidate.player, enemy.spec.rushDamage or 12, { canBlock = true, canParry = false })
				if landed then
					-- Flung along the charge, bent away from the grabber's centre line so a
					-- player clipped on the side flies off to that side.
					local away = Vector3.new(candidate.root.Position.X - moved.X, 0, candidate.root.Position.Z - moved.Z)
					local fling = if away.Magnitude > 1e-3 then (rushDir * 0.7 + away.Unit * 0.3) else rushDir
					local share = if outcome == "block" then 0.5 else 1
					Remotes.Knockback:FireClient(
						candidate.player,
						fling.Unit,
						(enemy.spec.rushKnockbackSpeed or 55) * share,
						(enemy.spec.rushKnockbackUp or 28) * share,
						enemy.spec.rushKnockbackSeconds or 0.32
					)
					if stunPlayer then
						stunPlayer(candidate.player, (enemy.spec.rushStunDuration or 1.3) * (if outcome == "block" then 0.45 else 1))
					end
					Remotes.CombatSfx:FireAllClients("enemyExploderBlast", candidate.root.Position)
				end
			end
		end
		-- A wall ends the charge early, straight into recovery: it must not grind along the wall
		-- for the rest of the rush.
		if moved.X ~= candidatePos.X or moved.Z ~= candidatePos.Z then
			enemy.state = Brain.endRush(enemy.state, enemy.spec.rushRecover or enemy.spec.recover or 1.1, t)
			enemy.rushDirection = nil
			enemy.rushHit = nil
			setTelegraph(enemy, false)
			enemy.model:SetAttribute("AlertIcon", false)
			syncPhase(enemy, t)
		end
		return
	elseif isLunging then
		local chargeDir = enemy.lungeDirection or (if toward.Magnitude > 1e-3 then toward.Unit else Vector3.new(0, 0, -1))
		local lungeSpeed = enemy.spec.lungeSpeed or (enemy.spec.speed * 3.5)
		local moved = clampEnemyPos(position + chargeDir * lungeSpeed * dt, enemy.radius)
		local look = Vector3.new(moved.X + chargeDir.X, moved.Y, moved.Z + chargeDir.Z)
		local nextCFrame = if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, moved.X, moved.Z)
		-- Check again after advancing this frame's lunge step so high-speed dashes never tunnel past.
		local catchRadius = enemy.spec.grabRadius or 4.6
		for _, candidate in ipairs(list) do
			local dXZ = Vector3.new(candidate.root.Position.X - moved.X, 0, candidate.root.Position.Z - moved.Z).Magnitude
			if dXZ <= catchRadius and (not canGrab or canGrab(candidate.player)) then
				latchGrab(candidate.player)
				return
			end
		end
		return
	elseif intent.move == "spin" then
		-- Dual-blade spin slowly tracks the player while whirling so players must Dash or Parry.
		if toward.Magnitude > 1e-3 then
			direction = toward.Unit
		end
		speedScale = enemy.spec.spinMoveFactor or 0.65
	elseif intent.move == "contactSurge" then
		-- Voltaico electrified surge: high-tempo spiral pursuit sweeping into contact radius.
		direction = Tactics.spiralApproach(position, target.root.Position, enemy.orbitSign, 0.58)
		speedScale = enemy.spec.contactSpeedFactor or 1.18
	elseif intent.move == "flank" then
		-- Melee units without an attack token peel off to their own angular sector around the
		-- player so waiting enemies surround from every side instead of clumping together.
		direction = Tactics.steerToSector(
			position,
			target.root.Position,
			sectorAngle,
			Config.AI_FLANK_RADIUS + enemy.radiusBias,
			Config.AI_FLANK_BAND,
			enemy.orbitSign,
			0.55
		)
		speedScale = Config.AI_FLANK_SPEED_FACTOR
	elseif intent.move == "toward" then
		if enemy.kind == "melee" then
			-- Active attackers curve in along their assigned sector for pincer pressure.
			direction = Tactics.pincerApproach(
				position,
				target.root.Position,
				sectorAngle,
				Config.AI_ATTACKER_PINCER_WEIGHT
			)
		elseif enemy.kind == "exploder" then
			local intercept = Tactics.interceptPoint(
				position,
				target.root.Position,
				target.root.AssemblyLinearVelocity,
				Config.AI_EXPLODER_LEAD_SECONDS
			)
			direction = Tactics.pincerApproach(position, intercept, sectorAngle, Config.AI_EXPLODER_CURVE_WEIGHT)
		elseif enemy.kind == "grabber" then
			local ambush = Tactics.grabberApproach(
				position,
				target.root.Position,
				target.root.CFrame.LookVector,
				enemy.orbitSign,
				Config.AI_GRABBER_FLANK_WEIGHT
			)
			local pincer = Tactics.pincerApproach(position, target.root.Position, sectorAngle, 0.5)
			local blend = Vector3.new(ambush.X + pincer.X, 0, ambush.Z + pincer.Z)
			direction = if blend.Magnitude > 1e-3 then blend.Unit else ambush
		elseif enemy.kind == "ranged" or enemy.kind == "area" then
			direction = Tactics.steerToSector(
				position,
				target.root.Position,
				sectorAngle,
				(enemy.spec.keepAway or 28) + enemy.radiusBias,
				3.5,
				enemy.orbitSign,
				0.35
			)
		elseif enemy.kind == "contact" then
			direction = Tactics.pincerApproach(position, target.root.Position, sectorAngle, 0.6)
		elseif toward.Magnitude > 1e-3 then
			direction = toward.Unit
		end
	elseif intent.move == "away" and toward.Magnitude > 1e-3 then
		-- Retreat diagonally toward own angular sector so backing ranged enemies split apart.
		local back = -toward.Unit
		local side = Vector3.new(-back.Z * enemy.orbitSign, 0, back.X * enemy.orbitSign) * 0.45
		direction = (back + side).Unit
	elseif intent.move == "hold" then
		if enemy.kind == "melee" and enemy.state.phase == "recover" and distance < Config.AI_FLANK_RADIUS * 0.75 and toward.Magnitude > 1e-3 then
			-- Diagonal tactical backstep after striking to open room for a flanker rotating in.
			local back = -toward.Unit
			local side = Vector3.new(-back.Z * enemy.orbitSign, 0, back.X * enemy.orbitSign) * 0.45
			direction = (back + side).Unit
			speedScale = Config.AI_RECOVER_BACKSTEP_FACTOR
		elseif enemy.kind == "ranged" or (enemy.kind == "area" and enemy.state.phase == "chase") then
			-- Ranged and artillery units spread across opposite firing sectors around the player.
			direction = Tactics.steerToSector(
				position,
				target.root.Position,
				sectorAngle,
				(enemy.spec.keepAway or 28) + enemy.radiusBias,
				4,
				enemy.orbitSign,
				0.48
			)
			speedScale = Config.AI_RANGED_STRAFE_FACTOR
		end
	end

	-- Unarmed axe enemy sprints straight to its dropped battle-axe on the floor and picks it up.
	if intent.move == "axeRetrieve" then
		local axePos = enemy.droppedAxePos
		if not axePos then
			enemy.model:SetAttribute("AxeThrown", false)
			enemy.state = Brain.finishAxeRetrieve(enemy.state, 0.2, enemy.spec.axeThrowCooldown or 6.5, t)
			syncPhase(enemy, t)
			return
		end
		local toAxe = Vector3.new(axePos.X - position.X, 0, axePos.Z - position.Z)
		local pickupRadius = enemy.spec.axePickupRadius or 4.2
		if toAxe.Magnitude <= pickupRadius then
			clearDroppedAxe(enemy)
			enemy.model:SetAttribute("AxeThrown", false)
			enemy.state = Brain.finishAxeRetrieve(enemy.state, 0.45, enemy.spec.axeThrowCooldown or 6.5, t)
			syncPhase(enemy, t)
			Remotes.CombatSfx:FireAllClients("playerBlock", position)
			return
		end
		local dir = toAxe.Unit
		local retrieveSpeed = enemy.spec.speed * (enemy.spec.axeRetrieveSpeedFactor or 1.28)
		local candidate = position + dir * retrieveSpeed * dt
		local moved = clampEnemyPos(candidate, enemy.radius)
		local look = Vector3.new(axePos.X, moved.Y, axePos.Z)
		moveEnemy(enemy, if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved))
		grid:move(enemy, moved.X, moved.Z)
		return
	end

	-- Separation via the spatial grid, so a wave spreads into a crowd in O(local) rather than O(N^2).
	local push = separationPush(enemy, position)

	local candidate = position + (direction * (enemy.spec.speed * speedScale) + push * enemy.spec.speed) * dt
	local moved = clampEnemyPos(candidate, enemy.radius)
	if (moved.X ~= candidate.X or moved.Z ~= candidate.Z) and (intent.move == "flank" or enemy.kind == "ranged" or enemy.kind == "area" or enemy.kind == "contact") then
		enemy.orbitSign = -enemy.orbitSign
		enemy.orbitFlipAt = t + 3.5 + math.random() * 2.5
	end
	local look = Vector3.new(target.root.Position.X, moved.Y, target.root.Position.Z)
	local nextCFrame = if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved)
	moveEnemy(enemy, nextCFrame)
	grid:move(enemy, moved.X, moved.Z)
	if enemy.kind == "contact" then
		applyContactDamage(enemy, moved, list, t)
	end
end

local function reflectDirection(origin: Vector3, currentVelocity: Vector3, shooter: Enemy?): Vector3
	if shooter and not shooter.dead and shooter.body and shooter.body.Parent then
		local toShooter = Vector3.new(shooter.body.Position.X - origin.X, 0, shooter.body.Position.Z - origin.Z)
		if toShooter.Magnitude > 1e-3 then
			return toShooter.Unit
		end
	end
	local bestDir: Vector3? = nil
	local bestDist = math.huge
	for _, enemy in ipairs(enemies) do
		if not enemy.dead and enemy.body and enemy.body.Parent then
			local delta = Vector3.new(enemy.body.Position.X - origin.X, 0, enemy.body.Position.Z - origin.Z)
			local dist = delta.Magnitude
			if dist > 1e-3 and dist < bestDist then
				bestDist = dist
				bestDir = delta.Unit
			end
		end
	end
	if bestDir then
		return bestDir
	end
	return if currentVelocity.Magnitude > 1e-3 then -currentVelocity.Unit else Vector3.new(0, 0, -1)
end

local function stepProjectiles(list, dt: number, t: number)
	for i = #projectiles, 1, -1 do
		local shot = projectiles[i]
		local prevPos = shot.position
		local position = prevPos + shot.velocity * dt
		local done = t >= shot.expiresAt
		local axeMissed = false
		if not done and shot.isAxe and not shot.reflected and shot.originPos and shot.maxDistance then
			local traveled = Vector3.new(position.X - shot.originPos.X, 0, position.Z - shot.originPos.Z).Magnitude
			if traveled >= shot.maxDistance then
				done = true
				axeMissed = true
			end
		end
		if not done then
			local inside = Waves.clamp(position, Config.ROOM_SIZE, 0)
			if inside.X ~= position.X or inside.Z ~= position.Z or Waves.hitsObstacle(position, Config.PROJECTILE_HIT_RADIUS * 0.45, activeObstacles()) then
				done = true
				if shot.isAxe and not shot.reflected then
					axeMissed = true
				end
			end
		end
		if not done then
			if shot.reflected then
				local candidates = grid:queryRadius(position.X, position.Z, Config.PROJECTILE_HIT_RADIUS + maxEnemyRadius)
				for _, enemy in ipairs(candidates) do
					if not enemy.dead and enemy.body and enemy.body.Parent then
						local dx = enemy.body.Position.X - position.X
						local dz = enemy.body.Position.Z - position.Z
						local hitRange = Config.PROJECTILE_HIT_RADIUS + enemy.radius
						if dx * dx + dz * dz <= hitRange * hitRange then
							EnemyService.damage(enemy, shot.damage, { tier = "medium", sourcePos = position })
							Remotes.CombatSfx:FireAllClients("playerHit", enemy.body.Position)
							done = true
							break
						end
					end
				end
			else
				for _, target in ipairs(list) do
					-- Checked in 3D (X/Z + Y): a dashing or jumping player is not hit, and the shot
					-- carries on past them.
					if
						Hitbox.inEllipsoid(
							position,
							target.root.Position,
							Config.PROJECTILE_HIT_RADIUS,
							Config.PROJECTILE_HIT_HEIGHT
						)
					then
						local landed, outcome = hurt(
							target.player,
							shot.damage,
							{ canBlock = true, canParry = shot.canParry, origin = position }
						)
						if outcome == "parry" then
							-- Deflect the shot back toward the shooter (or nearest enemy) at boosted speed.
							local dir = reflectDirection(position, shot.velocity, shot.shooter)
							local speed = shot.velocity.Magnitude * Config.PARRY_PROJECTILE_SPEED_MULTIPLIER
							shot.reflected = true
							shot.velocity = dir * speed
							shot.damage = Config.PARRY_PROJECTILE_DAMAGE
							shot.expiresAt = t + Config.PARRY_PROJECTILE_LIFE
							if shot.model then
								for _, desc in ipairs(shot.model:GetDescendants()) do
									if desc:IsA("BasePart") and desc.Material == Enum.Material.Neon then
										desc.Color = PARRIED_SHOT_COLOR
									end
								end
							else
								shot.part.Color = PARRIED_SHOT_COLOR
								if shot.isTracer then
									shot.part.Size = Vector3.new(0.45, 0.45, 4.4)
								elseif not shot.isAxe then
									shot.part.Size = Vector3.one * 2.1
								end
							end
							position = position + dir * 2
							break
						elseif landed then
							done = true
							break
						end
					end
				end
			end
		end
		if done then
			if shot.isAxe and shot.shooter and not shot.shooter.dead then
				local thrower = shot.shooter
				thrower.axeInFlight = false
				if axeMissed then
					-- Thrown axe missed the player: embed it on the floor so the enemy must run
					-- over and retrieve it before fighting with it again.
					clearDroppedAxe(thrower)
					local landPos = clampEnemyPos(prevPos, 1.8)
					thrower.droppedAxePos = Vector3.new(landPos.X, 0, landPos.Z)
					thrower.droppedAxePart = createDroppedAxe(thrower.droppedAxePos)
					thrower.model:SetAttribute("AxeThrown", true)
					thrower.state = Brain.enterAxeRetrieve(thrower.state)
					setTelegraph(thrower, false)
					syncPhase(thrower, t)
					Remotes.CombatSfx:FireAllClients("playerBlock", landPos)
				else
					-- Axe struck a player (or finished a parry bounce): returns cleanly to hand.
					thrower.model:SetAttribute("AxeThrown", false)
				end
			end
			if shot.model then
				shot.model:Destroy()
			else
				shot.part:Destroy()
			end
			table.remove(projectiles, i)
		else
			shot.position = position
			if shot.isAxe then
				shot.spinAngle = (shot.spinAngle or 0) + dt * 22
				local baseCf = if shot.velocity.Magnitude > 1e-3
					then CFrame.lookAt(position, position + shot.velocity)
					else CFrame.new(position)
				-- Spin the battle-axe flat-tilted in its blade plane so the full crescent silhouette
				-- and glowing plasma edge read clearly from the isometric camera.
				local spinCf = baseCf * CFrame.Angles(0, 0, math.rad(76)) * CFrame.Angles(shot.spinAngle, 0, 0)
				if shot.model then
					shot.model:PivotTo(spinCf)
				else
					shot.part.CFrame = spinCf
				end
			elseif shot.isTracer and shot.velocity.Magnitude > 1e-3 then
				shot.part.CFrame = CFrame.lookAt(position, position + shot.velocity)
			else
				shot.part.Position = position
			end
		end
	end
end

local function step(dt: number)
	-- Frozen while anybody is choosing a class: no movement, no attacks, no projectiles, no grab
	-- drain. Everything is on timers in server time, so nothing fires late when it resumes beyond
	-- what was already due.
	if isPaused and isPaused() then
		return
	end
	local t = now()
	local list, grabbedPositions = targets()

	-- Pass 1: squad-level target assignment (with co-op crowd spreading) and melee attack-token
	-- budgeting so at most `Config.AI_MAX_MELEE_ATTACKERS` melee enemies commit per player while
	-- extras flank and rotate in cleanly.
	local targetInfos: { Tactics.TargetInfo } = {}
	local targetByPlayer: { [Player]: { player: Player, root: BasePart } } = {}
	for _, entry in ipairs(list) do
		table.insert(targetInfos, { key = entry.player, position = entry.root.Position })
		targetByPlayer[entry.player] = entry
	end

	local assignedCounts: { [Player]: number } = {}
	local assignedTarget: { [Enemy]: { player: Player, root: BasePart } } = {}
	local assignedDistance: { [Enemy]: number } = {}
	local meleeCandidates: { Tactics.MeleeCandidate } = {}
	local closeSectorEntries: { Tactics.SectorEntry } = {}
	local rangedSectorEntries: { Tactics.SectorEntry } = {}

	if #targetInfos > 0 then
		for _, enemy in ipairs(enemies) do
			if not enemy.dead and not enemy.grabTarget then
				local chosen, dist = Tactics.chooseTarget(
					enemy.body.Position,
					targetInfos,
					assignedCounts,
					Config.AI_COOP_CROWD_PENALTY
				)
				-- A taunting tank overrides the choice while the taunt lasts and the tank is a target.
				local taunter = enemy.tauntedBy
				if taunter and t < enemy.tauntUntil and targetByPlayer[taunter] then
					local taunterRoot = targetByPlayer[taunter].root
					chosen = { key = taunter, position = taunterRoot.Position }
					dist = Vector3.new(
						taunterRoot.Position.X - enemy.body.Position.X,
						0,
						taunterRoot.Position.Z - enemy.body.Position.Z
					).Magnitude
				end
				if chosen then
					local playerKey = chosen.key :: Player
					assignedCounts[playerKey] = (assignedCounts[playerKey] or 0) + 1
					assignedTarget[enemy] = targetByPlayer[playerKey]
					assignedDistance[enemy] = dist
					local sectorEntry: Tactics.SectorEntry = {
						id = enemy,
						targetKey = playerKey,
						position = enemy.body.Position,
						targetPosition = chosen.position,
						jitter = enemy.sectorJitter,
					}
					if enemy.kind == "ranged" or enemy.kind == "area" then
						table.insert(rangedSectorEntries, sectorEntry)
					else
						table.insert(closeSectorEntries, sectorEntry)
					end
					if enemy.kind == "melee" then
						table.insert(meleeCandidates, {
							id = enemy,
							targetKey = playerKey,
							distance = dist,
							phase = enemy.state.phase,
						})
					end
				end
			end
		end
	end

	local meleeTokens = Tactics.assignMeleeTokens(meleeCandidates, Config.AI_MAX_MELEE_ATTACKERS)
	local drift = math.sin(t * 0.32) * 0.45
	local closeSectors = Tactics.assignSectors(closeSectorEntries, drift)
	local rangedSectors = Tactics.assignSectors(rangedSectorEntries, -drift * 0.7)

	-- Pass 2: execute each enemy's Brain + tactical movement.
	for _, enemy in ipairs(enemies) do
		if not enemy.dead then
			local target = assignedTarget[enemy]
			local dist = assignedDistance[enemy] or math.huge
			local canAttack = true
			local sectorAngle = 0
			if target then
				if enemy.kind == "melee" then
					canAttack = meleeTokens[enemy] == true
					sectorAngle = closeSectors[enemy] or 0
				elseif enemy.kind == "ranged" then
					canAttack = Tactics.canFireStaggered(lastRangedShotAt[target.player], t, Config.AI_RANGED_STAGGER_SECONDS)
					sectorAngle = rangedSectors[enemy] or 0
				elseif enemy.kind == "area" then
					canAttack = Tactics.canFireStaggered(lastAreaLaunchAt[target.player], t, 1.35)
					sectorAngle = rangedSectors[enemy] or 0
				else
					sectorAngle = closeSectors[enemy] or 0
				end
			end
			if enemy.shoveVelocity and t < enemy.shoveUntil then
				local here = enemy.body.Position
				local pushed = clampEnemyPos(here + enemy.shoveVelocity * dt, enemy.radius)
				moveEnemy(enemy, CFrame.new(pushed) * enemy.body.CFrame.Rotation)
				grid:move(enemy, pushed.X, pushed.Z)
			end
			if t < enemy.stunUntil then
				continue
			elseif enemy.model:GetAttribute("Phase") == "stunned" then
				setTelegraph(enemy, false)
				if enemy.droppedAxePos then
					enemy.state = Brain.enterAxeRetrieve(enemy.state)
				end
				syncPhase(enemy, t)
			end
			local enemyDt = if t < enemy.slowUntil then dt * enemy.slowFactor else dt
			stepEnemy(enemy, list, grabbedPositions, target, dist, canAttack, sectorAngle, enemyDt, t)
		end
	end
	for i = #enemies, 1, -1 do
		if enemies[i].dead then
			table.remove(enemies, i)
		end
	end
	stepProjectiles(list, dt, t)
	stepHazardZones(list, t)
	stepShockRings(list, t)
end

function EnemyService.start(dependencies: {
	hurt: (Player, number, { canDodge: boolean?, canBlock: boolean?, canParry: boolean?, origin: Vector3? }?) -> (boolean, string?),
	world: Instance,
	onKill: ((Vector3) -> ())?,
	canGrab: ((Player) -> boolean)?,
	setGrabbed: ((Player, boolean, number?, number?) -> ())?,
	warnGrab: ((Player, number) -> ())?,
	warnParry: ((Player, number) -> ())?,
	stun: ((Player, number) -> ())?,
	isPaused: (() -> boolean)?,
})
	hurt = dependencies.hurt
	onKill = dependencies.onKill
	canGrab = dependencies.canGrab
	setGrabbed = dependencies.setGrabbed
	warnGrab = dependencies.warnGrab
	warnParry = dependencies.warnParry
	stunPlayer = dependencies.stun
	isPaused = dependencies.isPaused
	worldRef = dependencies.world
	folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = dependencies.world
	syncBossHud(nil)
	RunService.Heartbeat:Connect(step)
end

-- Remote "GrabEscape": each Attack press by a trapped player advances their escape counter.
function EnemyService.onGrabEscape(player: Player)
	for _, enemy in ipairs(enemies) do
		if not enemy.dead and enemy.grabTarget == player then
			local nextVal, freed = Brain.escapeProgress(enemy.grabProgress, 1, Config.GRAB_ESCAPE_PRESSES)
			enemy.grabProgress = nextVal
			player:SetAttribute("GrabProgress", nextVal)
			if freed then
				releaseGrab(enemy, now(), true)
			end
			return
		end
	end
end

function EnemyService.forget(player: Player)
	lastRangedShotAt[player] = nil
	lastAreaLaunchAt[player] = nil
	for _, enemy in ipairs(enemies) do
		enemy.contactHitAt[player] = nil
		enemy.mySweepHitAt[player] = nil
		if enemy.myDashHit then
			enemy.myDashHit[player] = nil
		end
		if enemy.grabTarget == player then
			releaseGrab(enemy, now(), false)
		end
	end
	for _, ring in ipairs(shockRings) do
		ring.hit[player] = nil
	end
end

function EnemyService.spawn(kind: string, position: Vector3, diffId: string?, partySize: number?): Enemy?
	local spec = Config.ENEMY_KINDS[kind]
	if not spec then
		warn(`no enemy kind "{kind}" in Config.ENEMY_KINDS`)
		return nil
	end

	local model: Model
	local body: BasePart
	local modelName, weapon, variantSpec = pickVariant(kind, spec)
	-- Merge variant-specific combat overrides onto a per-enemy copy of `spec`, then apply the
	-- active difficulty & co-op multipliers (`Fácil`, `Normal`, `Difícil`, `Zona Muerta`, 1-4 players).
	local mergedSpec = table.clone(spec)
	if variantSpec then
		for k, v in pairs(variantSpec) do
			if k ~= "model" and k ~= "weapon" and k ~= "weight" then
				mergedSpec[k] = v
			end
		end
	end
	local effectiveSpec = Difficulty.scaleSpec(mergedSpec, diffId, partySize)
	local hasJoints = false
	local models = modelName and ReplicatedStorage:FindFirstChild("Models")
	local template = models and models:FindFirstChild(modelName)
	if template and template:IsA("Model") then
		model = template:Clone()
		local foundBody = model.PrimaryPart or model:FindFirstChild("Body")
		assert(foundBody and foundBody:IsA("BasePart"), `enemy model {modelName} must carry a Body BasePart`)
		body = foundBody
		-- Re-stamp PrimaryPart/WorldPivot and self-heal Motor6D Refs in case Rojo 7 live-sync
		-- dropped Instance Refs on `.rbxmx` imports.
		model.PrimaryPart = body
		model.WorldPivot = body.CFrame
		for _, child in ipairs(body:GetChildren()) do
			if child:IsA("Motor6D") then
				hasJoints = true
				if not child.Part0 then
					child.Part0 = body
				end
				if not child.Part1 and child.Name:sub(1, 6) == "Joint_" then
					local part = model:FindFirstChild(child.Name:sub(7))
					if part and part:IsA("BasePart") then
						child.Part1 = part
					end
				end
			end
		end
		model.Name = kind
		model:SetAttribute("Kind", kind)
		if weapon then
			model:SetAttribute("Weapon", weapon)
		end
		if kind == "contact" then
			model:SetAttribute("ContactRadius", effectiveSpec.contactRadius or 5.5)
		end
		local spawnCFrame = CFrame.new(position.X, spec.size.Y / 2, position.Z)
		if hasJoints then
			body.CFrame = spawnCFrame
		else
			model:PivotTo(spawnCFrame)
		end
	else
		modelName = nil
		model = Instance.new("Model")
		model.Name = kind
		model:SetAttribute("Kind", kind)

		local part = Instance.new("Part")
		part.Name = "Body"
		part.Anchored = true
		-- Players pass through enemies rather than being shoved by a part the server teleports
		-- every frame. Hits are judged by distance, so nothing needs the collision.
		part.CanCollide = false
		part.CanTouch = false
		part.Size = spec.size
		part.Color = spec.color
		part.Material = Enum.Material.SmoothPlastic
		if kind == "exploder" then
			part.Shape = Enum.PartType.Ball
		end
		part.Position = Vector3.new(position.X, spec.size.Y / 2, position.Z)
		part.Parent = model
		model.PrimaryPart = part
		model.WorldPivot = part.CFrame
		body = part
	end

	local visuals: { PartVisual } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(visuals, {
				part = desc,
				color = desc.Color,
				material = desc.Material,
			})
		end
	end

	local orbitSign = nextOrbitSign
	nextOrbitSign = -nextOrbitSign

	local spawnNow = now()
	local enemy: Enemy = {
		kind = kind,
		modelName = modelName,
		weapon = weapon,
		hasJoints = hasJoints,
		spec = effectiveSpec,
		model = model,
		body = body,
		visuals = visuals,
		flashToken = 0,
		fill = healthBar(body, effectiveSpec.size.Y),
		radius = math.max(effectiveSpec.size.X, effectiveSpec.size.Z) / 2,
		health = effectiveSpec.health,
		state = Brain.initial(spawnNow),
		dead = false,
		grabTarget = nil,
		grabProgress = 0,
		nextGrabDamageAt = 0,
		wanderHeading = randomHeading(),
		wanderUntil = spawnNow + Config.ENEMY_WANDER_INTERVAL * math.random(),
		orbitSign = orbitSign,
		orbitFlipAt = spawnNow + Config.AI_SHIFT_MIN_SECONDS + math.random() * (Config.AI_SHIFT_MAX_SECONDS - Config.AI_SHIFT_MIN_SECONDS),
		sectorJitter = math.random() * 0.6 - 0.3,
		radiusBias = math.random() * 5 - 2.5,
		lungeDirection = nil,
		burstLeft = 0,
		nextBurstAt = 0,
		beamDirection = nil,
		beamLocked = false,
		evadeOrigin = nil,
		evadeTarget = nil,
		evadeStartedAt = 0,
		evadeDuration = 0,
		phantomOrigin = nil,
		phantomTarget = nil,
		phantomStartedAt = 0,
		phantomDuration = 0,
		phantomStepIndex = 0,
		bossConeDir = nil,
		bossLeapOrigin = nil,
		bossLeapTarget = nil,
		bossLeapStartedAt = 0,
		bossLeapDuration = 0,
		axeInFlight = false,
		droppedAxePart = nil,
		droppedAxePos = nil,
		rushDirection = nil,
		rushHit = nil,
		tauntedBy = nil,
		tauntUntil = 0,
		shoveVelocity = nil,
		shoveUntil = 0,
		slowFactor = 1,
		slowUntil = 0,
		stunUntil = 0,
		staggerStacks = 0,
		dazeUntil = 0,
		hitCount = 0,
		knockbackDir = nil,
		knockbackSpeed = 0,
		knockbackEndsAt = 0,
		contactHitAt = {},
		myDashDir = nil,
		myDashHit = nil,
		mySweepBaseDir = nil,
		mySweepSign = 1,
		mySweepStartedAt = 0,
		mySweepDuration = 1.15,
		mySweepHitAt = {},
		gonGravityPos = nil,
		gonGravityRing = nil,
		gonGravityCore = nil,
		gonGravityNextPullAt = 0,
	}
	syncPhase(enemy, spawnNow)
	model.Parent = folder
	table.insert(enemies, enemy)
	grid:insert(enemy, body.Position.X, body.Position.Z)
	if enemy.radius > maxEnemyRadius then
		maxEnemyRadius = enemy.radius
	end
	if effectiveSpec.isBoss == true then
		syncBossHud(enemy)
	end
	return enemy
end

-- Tank taunt: this enemy targets `player` until `untilAt` (server time).
function EnemyService.taunt(enemy: Enemy, player: Player, untilAt: number)
	if not enemy.dead then
		enemy.tauntedBy = player
		enemy.tauntUntil = untilAt
	end
end

-- Support shockwave: push `distance` studs along `direction` over `seconds`, then run at
-- `slowFactor` of real time until `slowUntil`.
function EnemyService.shove(enemy: Enemy, direction: Vector3, distance: number, seconds: number, slowFactor: number, slowUntil: number)
	if enemy.dead or seconds <= 0 then
		return
	end
	local t = now()
	enemy.shoveVelocity = direction * (distance / seconds)
	enemy.shoveUntil = t + seconds
	enemy.slowFactor = slowFactor
	enemy.slowUntil = slowUntil
end

-- Hard-stuns an enemy for `duration` seconds: interrupts windups, abilities, beams, fuses, and
-- even active grabs (freeing a held teammate), and flags `StunnedUntil` for visuals and DPS passive.
function EnemyService.stun(enemy: Enemy, duration: number)
	if enemy.dead or duration <= 0 then
		return
	end
	if enemy.spec.isBoss == true then
		duration *= 0.5
	end
	local t = now()
	if enemy.grabTarget then
		releaseGrab(enemy, t, true)
	end
	enemy.burstLeft = 0
	enemy.lungeDirection = nil
	enemy.rushDirection = nil
	enemy.rushHit = nil
	enemy.beamDirection = nil
	enemy.beamLocked = false
	enemy.phantomOrigin = nil
	enemy.phantomTarget = nil
	enemy.phantomStepIndex = 0
	enemy.bossConeDir = nil
	enemy.bossLeapOrigin = nil
	enemy.bossLeapTarget = nil
	clearBossEffects(enemy)
	enemy.model:SetAttribute("BossConeDir", nil)
	enemy.model:SetAttribute("BossLeapTarget", nil)
	enemy.state = Brain.initial(t)
	local baseY = enemy.spec.size.Y / 2
	local pos = enemy.body.Position
	if math.abs(pos.Y - baseY) > 0.05 then
		local snapped = Vector3.new(pos.X, baseY, pos.Z)
		moveEnemy(enemy, CFrame.new(snapped) * enemy.body.CFrame.Rotation)
		grid:move(enemy, snapped.X, snapped.Z)
	end
	local untilAt = math.max(enemy.stunUntil, t + duration)
	enemy.stunUntil = untilAt
	enemy.model:SetAttribute("StunnedUntil", untilAt)
	enemy.model:SetAttribute("Phase", "stunned")
	enemy.model:SetAttribute("PhaseStartedAt", t)
	enemy.model:SetAttribute("PhaseDuration", untilAt - t)
	enemy.model:SetAttribute("BeamDir", nil)
	enemy.model:SetAttribute("BeamLocked", false)
	enemy.model:SetAttribute("ParryTelegraph", false)
	enemy.model:SetAttribute("AlertIcon", false)
	enemy.model:SetAttribute("SlamRadius", nil)
	setTelegraph(enemy, true, Color3.fromRGB(255, 225, 75))
end

function EnemyService.list(): { Enemy }
	return enemies
end

function EnemyService.count(): number
	local living = 0
	for _, enemy in ipairs(enemies) do
		if not enemy.dead then
			living += 1
		end
	end
	return living
end

function EnemyService.damage(enemy: Enemy, amount: number, hitInfo: HitInfo?)
	if enemy.dead or enemy.state.phase == "bossPhaseShift" then
		return
	end
	enemy.health -= amount
	enemy.fill.Size = UDim2.fromScale(math.clamp(enemy.health / enemy.spec.health, 0, 1), 1)
	if enemy.spec.isBoss == true then
		syncBossHud(enemy)
	end
	if enemy.health <= 0 then
		kill(enemy)
		return
	end
	local t = now()
	-- Boss OhMyGon Phase 2 transformation at <= 50% HP (single-fire, invulnerable 1.5 s beat).
	if
		enemy.kind == "bossOhMyGon"
		and not enemy.state.phase2Triggered
		and enemy.health / math.max(enemy.spec.health, 1) <= (enemy.spec.phase2Threshold or 0.5)
	then
		local nextState, shifted = Brain.triggerPhase2(enemy.state, enemy.spec.phase2Duration or 1.5, t)
		if shifted then
			clearBossEffects(enemy)
			enemy.state = nextState
			setTelegraph(enemy, true, Color3.fromRGB(255, 42, 62))
			syncPhase(enemy, t)
			syncBossHud(enemy)
			burst(enemy.body.Position, 16, Color3.fromRGB(255, 48, 68), 8)
			Remotes.CombatSfx:FireAllClients("bossOhEntry", enemy.body.Position)
		end
	end
	-- Teammates attacking a grabber contribute toward breaking the trapped player free even if
	-- the trapped player is not pressing the escape button (plans/gdd/content.md).
	if enemy.grabTarget then
		local nextVal, freed =
			Brain.escapeProgress(enemy.grabProgress, Config.GRAB_ALLY_HIT_PROGRESS, Config.GRAB_ESCAPE_PRESSES)
		enemy.grabProgress = nextVal
		enemy.grabTarget:SetAttribute("GrabProgress", nextVal)
		if freed then
			releaseGrab(enemy, t, true)
		end
	elseif t >= enemy.stunUntil and enemy.spec.isBoss ~= true then
		-- Skipped while hard-stunned: the stun already holds the enemy, and writing `hitstun` over
		-- its "stunned" Phase would keep the stun's exit (telegraph off, axe retrieve) from running.
		-- Bosses have super armour against flinches, or any combo would chain-lock the only boss.
		-- Apply DMC-style hitstun & progressive suppression so every hit disrupts enemy actions
		-- and slows movement while nudging them slightly back inside melee sweet-spot range.
		local tier = if hitInfo and hitInfo.tier then hitInfo.tier else "light"
		local baseStun = if tier == "heavy"
			then Config.ENEMY_HITSTUN_HEAVY
			elseif tier == "medium" then Config.ENEMY_HITSTUN_MEDIUM
			else Config.ENEMY_HITSTUN_LIGHT
		local knockbackDist = if tier == "heavy"
			then Config.ENEMY_KNOCKBACK_HEAVY
			elseif tier == "medium" then Config.ENEMY_KNOCKBACK_MEDIUM
			else Config.ENEMY_KNOCKBACK_LIGHT

		local currentStacks = if t < enemy.dazeUntil or enemy.state.phase == "hitstun" then enemy.staggerStacks else 0
		local nextStacks = math.min(currentStacks + 1, Config.ENEMY_HITSTUN_MAX_STACKS)
		local stunDuration = baseStun + (nextStacks - 1) * Config.ENEMY_HITSTUN_STACK_BONUS
		local nextState, stunned = Brain.applyHitstun(enemy.kind, enemy.state, stunDuration, t, Config.ENEMY_HIT_ACTION_DELAY)
		if stunned then
			enemy.staggerStacks = nextStacks
			enemy.hitCount += 1
			enemy.state = nextState
			enemy.dazeUntil = math.max(enemy.dazeUntil, nextState.endsAt + Config.ENEMY_DAZE_SECONDS)
			if nextState.phase == "hitstun" then
				enemy.burstLeft = 0
				enemy.beamDirection = nil
				enemy.beamLocked = false
				enemy.lungeDirection = nil
				enemy.model:SetAttribute("BeamDir", nil)
				enemy.model:SetAttribute("BeamLocked", false)
				enemy.model:SetAttribute("ParryTelegraph", false)
				enemy.model:SetAttribute("AlertIcon", false)
				enemy.model:SetAttribute("SlamRadius", nil)
				setTelegraph(enemy, false)
			end
			enemy.model:SetAttribute("HitCount", enemy.hitCount)
			syncPhase(enemy, t)

			if hitInfo and hitInfo.sourcePos and knockbackDist > 0 then
				local away = Vector3.new(
					enemy.body.Position.X - hitInfo.sourcePos.X,
					0,
					enemy.body.Position.Z - hitInfo.sourcePos.Z
				)
				if away.Magnitude > 1e-3 then
					enemy.knockbackDir = away.Unit
					enemy.knockbackSpeed = knockbackDist / math.max(Config.ENEMY_KNOCKBACK_DURATION, 0.04)
					enemy.knockbackEndsAt = t + Config.ENEMY_KNOCKBACK_DURATION
				end
			end
		end
	end
	-- A flash on every hit: the feedback that a swing connected, which a hack&slash lives on.
	-- Token-gated so rapid combo hits always restore every part's authored color cleanly.
	enemy.flashToken += 1
	local token = enemy.flashToken
	for _, entry in ipairs(enemy.visuals) do
		entry.part.Color = HIT_COLOR
	end
	task.delay(FLASH_SECONDS, function()
		if not enemy.dead and enemy.flashToken == token then
			for _, entry in ipairs(enemy.visuals) do
				entry.part.Color = entry.color
			end
		end
	end)
end

-- Everything off the board at once: the room resetting after everybody died.
function EnemyService.clear()
	local t = now()
	for _, enemy in ipairs(enemies) do
		enemy.dead = true
		clearDroppedAxe(enemy)
		clearBossEffects(enemy)
		releaseGrab(enemy, t, false)
		enemy.model:Destroy()
	end
	table.clear(enemies)
	table.clear(lastRangedShotAt)
	table.clear(lastAreaLaunchAt)
	grid:clear()
	maxEnemyRadius = 0
	for _, zone in ipairs(hazardZones) do
		destroyHazardZone(zone)
	end
	table.clear(hazardZones)
	for _, ring in ipairs(shockRings) do
		if ring.part.Parent then
			ring.part:Destroy()
		end
	end
	table.clear(shockRings)
	for _, shot in ipairs(projectiles) do
		if shot.model then
			shot.model:Destroy()
		else
			shot.part:Destroy()
		end
	end
	table.clear(projectiles)
	syncBossHud(nil)
end

return EnemyService
