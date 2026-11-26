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
local Hitbox = require(Shared.features.enemies.Hitbox)
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
	burstLeft: number,
	nextBurstAt: number,
	beamDirection: Vector3?,
	beamLocked: boolean,
	evadeOrigin: Vector3?,
	evadeTarget: Vector3?,
	evadeStartedAt: number,
	evadeDuration: number,
	sandyOrigin: Vector3?,
	sandyTarget: Vector3?,
	sandyStartedAt: number,
	sandyDuration: number,
	sandyStepIndex: number,
}

type Projectile = {
	part: BasePart,
	velocity: Vector3,
	expiresAt: number,
	damage: number,
	reflected: boolean,
	isTracer: boolean,
	shooter: Enemy?,
}

-- How far inside the walls an enemy is kept.
local WALL_MARGIN = 3
local FLASH_SECONDS = 0.08
local HIT_COLOR = Color3.new(1, 1, 1)
local PARRIED_SHOT_COLOR = Color3.fromRGB(255, 225, 90)

local hurt: (Player, number, { canDodge: boolean?, canBlock: boolean?, canParry: boolean? }?) -> (boolean, string?) =
	nil :: any
local onKill: ((Vector3) -> ())? = nil
local canGrab: ((Player) -> boolean)? = nil
local setGrabbed: ((Player, boolean, number?, number?) -> ())? = nil
local warnGrab: ((Player, number) -> ())? = nil
local warnParry: ((Player, number) -> ())? = nil
local folder: Folder = nil :: any

local enemies: { Enemy } = {}
local projectiles: { Projectile } = {}
local variantCursor: { [string]: number } = {}
local lastRangedShotAt: { [Player]: number } = {}
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

-- Returns `(freeTargets, grabbedPositions)`: non-grabbed living players for enemies to chase,
-- and grabbed player positions so roaming enemies steer clear when no free target exists.
local function targets(): ({ { player: Player, root: BasePart } }, { Vector3 })
	local list = {}
	local grabbed = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
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
	local spacing = if enemy.kind == "ranged" then Config.AI_RANGED_SPACING else Config.ENEMY_SPACING
	local neighbors = grid:queryRadius(position.X, position.Z, spacing, separationScratch)
	table.clear(neighborPosScratch)
	for _, other in ipairs(neighbors) do
		if other ~= enemy and not other.dead then
			if enemy.kind ~= "ranged" or other.kind == "ranged" or (position - other.body.Position).Magnitude < Config.ENEMY_SPACING then
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

local function setTelegraph(enemy: Enemy, on: boolean)
	-- Neon while winding up or fused: the tell a player reads to know when to dash or parry.
	-- Restores each part's authored material (e.g. Metal on EnemyMelee, SmoothPlastic on
	-- single-part fallbacks) so multi-part `.rbxmx` enemies keep their look after windup.
	for _, entry in ipairs(enemy.visuals) do
		if entry.material ~= Enum.Material.Neon then
			entry.part.Material = if on then Enum.Material.Neon else entry.material
		end
	end
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

local function kill(enemy: Enemy)
	if enemy.dead then
		return
	end
	enemy.dead = true
	grid:remove(enemy)
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
	local dir = aim.Unit
	local spreadDeg = enemy.spec.burstSpreadDeg or 0
	if spreadDeg > 0 then
		local rad = math.rad((math.random() * 2 - 1) * spreadDeg)
		local cosA, sinA = math.cos(rad), math.sin(rad)
		dir = Vector3.new(dir.X * cosA - dir.Z * sinA, 0, dir.X * sinA + dir.Z * cosA).Unit
	end

	local isTracer = enemy.spec.projectileStyle == "tracer"
	local speed = enemy.spec.projectileSpeed or 45
	local damage = enemy.spec.projectileDamage or enemy.spec.damage or 8
	local spawnPos = Vector3.new(origin.X, Config.PROJECTILE_HEIGHT, origin.Z)

	local part = Instance.new("Part")
	part.Name = if isTracer then "Tracer" else "Shot"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	if isTracer then
		-- Sleek glowing ballistic tracer line for minigun bursts.
		part.Shape = Enum.PartType.Block
		part.Color = Color3.fromRGB(255, 205, 65)
		part.Size = Vector3.new(0.28, 0.28, 3.8)
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
		velocity = dir * speed,
		expiresAt = now() + (enemy.spec.projectileLife or 2.5),
		damage = damage,
		reflected = false,
		isTracer = isTracer,
		shooter = enemy,
	})
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
					EnemyService.damage(other, enemyDamage)
				end
			end
		end
	end

	burst(origin, blastRadius, enemy.spec.color, blastHeight)
	Remotes.CombatSfx:FireAllClients("enemyExploderBlast", origin)
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
	local holdXZ = Waves.clamp(origin + forward * Config.GRAB_HOLD_DISTANCE, Config.ROOM_SIZE, WALL_MARGIN)
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
			or enemy.state.phase == "sandevistan"
			or enemy.state.phase == "beamCharge"
			or enemy.state.phase == "evade"
			or enemy.state.phase == "lunge"
			or enemy.state.phase == "fuse"
		then
			enemy.state = Brain.initial(t)
			enemy.lungeDirection = nil
			enemy.beamDirection = nil
			enemy.beamLocked = false
			enemy.sandyOrigin = nil
			enemy.sandyTarget = nil
			enemy.sandyStepIndex = 0
			enemy.model:SetAttribute("BeamDir", nil)
			enemy.model:SetAttribute("BeamLocked", false)
			enemy.model:SetAttribute("ParryTelegraph", false)
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
		local moved = Waves.clamp(candidate, Config.ROOM_SIZE, WALL_MARGIN)
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
		setTelegraph(
			enemy,
			state.phase == "windup"
				or state.phase == "spin"
				or state.phase == "sandevistan"
				or state.phase == "beamCharge"
				or state.phase == "lunge"
				or state.phase == "fuse"
		)
		syncPhase(enemy, t)
		if before == "sandevistan" and state.phase ~= "sandevistan" then
			enemy.sandyStepIndex = 0
			enemy.sandyOrigin = nil
			enemy.sandyTarget = nil
		end
		enemy.model:SetAttribute("ParryTelegraph", state.phase == "windup" and state.sandevistanFinisher == true)
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
			elseif state.pendingSandevistan then
				Remotes.CombatSfx:FireAllClients("playerHeavyCharge", position)
			elseif state.sandevistanFinisher then
				Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
				if warnParry then
					warnParry(target.player, state.endsAt)
				end
			else
				Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
			end
		elseif state.phase == "spin" then
			Remotes.CombatSfx:FireAllClients("playerSpin", position)
		elseif state.phase == "beamCharge" then
			Remotes.CombatSfx:FireAllClients("playerHeavyCharge", position)
		elseif state.phase == "fuse" then
			Remotes.CombatSfx:FireAllClients("enemyExploderFuse", position)
		end
	end

	local function latchGrab(victim: Player)
		enemy.state = Brain.enterHolding(enemy.state)
		enemy.grabTarget = victim
		enemy.grabProgress = 0
		enemy.nextGrabDamageAt = t + Config.GRAB_DAMAGE_TICK_SECONDS
		enemy.lungeDirection = nil
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
		if enemy.state.sandevistanFinisher then
			-- Sandevistan ambush finisher is unavoidable at hyper-speed: even if the player runs,
			-- jumps, or Dashes, the swordsman stays locked on them and only a timed Parry stops it.
			local baseY = enemy.spec.size.Y / 2
			local toEnemy = Vector3.new(position.X - target.root.Position.X, 0, position.Z - target.root.Position.Z)
			local offsetDir = if toEnemy.Magnitude > 1e-3
				then toEnemy.Unit
				else -Vector3.new(target.root.CFrame.LookVector.X, 0, target.root.CFrame.LookVector.Z).Unit
			local snapXZ = Waves.clamp(target.root.Position + offsetDir * 4.4, Config.ROOM_SIZE, WALL_MARGIN)
			local snapPos = Vector3.new(snapXZ.X, baseY, snapXZ.Z)
			local lookAtPlayer = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
			if (lookAtPlayer - snapPos).Magnitude > 1e-3 then
				moveEnemy(enemy, CFrame.lookAt(snapPos, lookAtPlayer))
			else
				moveEnemy(enemy, CFrame.new(snapPos))
			end
			grid:move(enemy, snapPos.X, snapPos.Z)
			position = snapPos

			local strikeDamage = enemy.spec.sandevistanDamage or enemy.spec.damage
			local _, outcome = hurt(target.player, strikeDamage, {
				canDodge = false,
				canBlock = false,
				canParry = true,
			})
			if outcome == "parry" then
				enemy.state = Brain.releaseGrab(enemy.state, Config.PARRY_STUN_SECONDS, t)
				syncPhase(enemy, t)
			end
		else
			-- Checked in 3D at the moment of the strike: dashing out or jumping over during the windup
			-- both earn the miss.
			local strikeRadius = (enemy.spec.reach + enemy.radius) * 1.2
			local strikeHeight = enemy.spec.strikeHeight or enemy.spec.size.Y
			if Hitbox.inEllipsoid(position, target.root.Position, strikeRadius, strikeHeight) then
				local _, outcome = hurt(target.player, enemy.spec.damage, { canBlock = true, canParry = true })
				if outcome == "parry" then
					-- Parrying a melee strike staggers the attacker into an extended recover window.
					enemy.state = Brain.releaseGrab(enemy.state, Config.PARRY_STUN_SECONDS, t)
					syncPhase(enemy, t)
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
					enemy.state = Brain.releaseGrab(enemy.state, Config.PARRY_STUN_SECONDS, t)
					setTelegraph(enemy, false)
					syncPhase(enemy, t)
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
	elseif intent.action == "beamStart" then
		local toTarget = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
		local dir = if toTarget.Magnitude > 1e-3 then toTarget.Unit else Vector3.new(0, 0, -1)
		enemy.beamDirection = dir
		enemy.beamLocked = false
		enemy.model:SetAttribute("BeamDir", dir)
		enemy.model:SetAttribute("BeamLocked", false)
		enemy.model:SetAttribute("BeamRange", enemy.spec.beamRange or 55)
	elseif intent.action == "beamFire" then
		local dir = enemy.beamDirection
		if not dir or dir.Magnitude < 1e-3 then
			local toTarget = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
			dir = if toTarget.Magnitude > 1e-3 then toTarget.Unit else Vector3.new(0, 0, -1)
		end
		local beamOrigin = Vector3.new(position.X, 2.4, position.Z)
		local beamRange = enemy.spec.beamRange or 55
		local beamRadius = enemy.spec.beamRadius or 2.4
		local beamHeight = enemy.spec.beamHeight or 3.2
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
				hurt(candidate.player, beamDamage, { canBlock = true, canParry = false })
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
		local bestLanding = Waves.clamp(position + candidates[1] * leapDist, Config.ROOM_SIZE, WALL_MARGIN)
		local bestClearance = Vector3.new(bestLanding.X - position.X, 0, bestLanding.Z - position.Z).Magnitude
		if bestClearance < leapDist * 0.55 then
			for i = 2, #candidates do
				local landing = Waves.clamp(position + candidates[i] * leapDist, Config.ROOM_SIZE, WALL_MARGIN)
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
	elseif intent.action == "sandevistanHop" then
		-- Single-sword Cyberpunk Sandevistan: chain 3+ rapid dashes across sharp angles before
		-- snapping close behind the player for a surprise slash.
		if before ~= "sandevistan" then
			enemy.sandyStepIndex = 1
		else
			enemy.sandyStepIndex += 1
		end
		local totalSteps = math.max(enemy.spec.sandevistanSteps or 3, 3)
		local rawWaypoint = Tactics.sandevistanWaypoint(
			position,
			target.root.Position,
			target.root.CFrame.LookVector,
			enemy.sandyStepIndex,
			totalSteps,
			enemy.orbitSign
		)
		local clamped = Waves.clamp(rawWaypoint, Config.ROOM_SIZE, WALL_MARGIN)
		local baseY = enemy.spec.size.Y / 2
		enemy.sandyOrigin = Vector3.new(position.X, baseY, position.Z)
		enemy.sandyTarget = Vector3.new(clamped.X, baseY, clamped.Z)
		enemy.sandyStartedAt = t
		enemy.sandyDuration = enemy.spec.sandevistanStepDuration or 0.15
		Remotes.CombatSfx:FireAllClients("playerDash", position)
	elseif intent.action == "fire" then
		lastRangedShotAt[target.player] = t
		local burstCount = enemy.spec.burstCount or 1
		if burstCount > 1 then
			enemy.burstLeft = burstCount - 1
			enemy.nextBurstAt = t + (enemy.spec.burstInterval or 0.18)
		end
		fire(enemy, target.root)
	elseif intent.action == "explode" then
		explode(enemy, list)
		return
	end

	-- Continue any in-progress multi-shot burst (double-shot shotgun/plasma or 6-round minigun).
	if enemy.burstLeft > 0 and t >= enemy.nextBurstAt then
		enemy.burstLeft -= 1
		enemy.nextBurstAt = t + (enemy.spec.burstInterval or 0.18)
		fire(enemy, target.root)
	end

	local toward = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
	local direction = Vector3.zero
	local speedScale = 1
	local isLunging = intent.move == "lunge"
	if intent.move == "sandevistan" and enemy.sandyOrigin and enemy.sandyTarget then
		local dur = math.max(enemy.sandyDuration, 0.04)
		local u = math.clamp((t - enemy.sandyStartedAt) / dur, 0, 1)
		local ease = 1 - (1 - u) * (1 - u)
		local baseY = enemy.spec.size.Y / 2
		local dashPos = Vector3.new(
			enemy.sandyOrigin.X + (enemy.sandyTarget.X - enemy.sandyOrigin.X) * ease,
			baseY,
			enemy.sandyOrigin.Z + (enemy.sandyTarget.Z - enemy.sandyOrigin.Z) * ease
		)
		local totalSteps = math.max(enemy.spec.sandevistanSteps or 3, 3)
		local travel = Vector3.new(enemy.sandyTarget.X - enemy.sandyOrigin.X, 0, enemy.sandyTarget.Z - enemy.sandyOrigin.Z)
		local lookTarget: Vector3
		if enemy.sandyStepIndex >= totalSteps and u >= 0.65 then
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
	elseif enemy.state.phase == "windup" and enemy.state.sandevistanFinisher then
		-- Shadow-step lock during the Sandevistan finisher windup: if the player tries to sprint,
		-- jump, or Dash out of range, the hyper-speed swordsman sticks right on them.
		local baseY = enemy.spec.size.Y / 2
		local toEnemy = Vector3.new(position.X - target.root.Position.X, 0, position.Z - target.root.Position.Z)
		local offsetDir = if toEnemy.Magnitude > 1e-3
			then toEnemy.Unit
			else -Vector3.new(target.root.CFrame.LookVector.X, 0, target.root.CFrame.LookVector.Z).Unit
		local desiredXZ = Waves.clamp(target.root.Position + offsetDir * 4.4, Config.ROOM_SIZE, WALL_MARGIN)
		local alpha = math.clamp(dt * 24, 0, 1)
		local lockPos = Vector3.new(
			position.X + (desiredXZ.X - position.X) * alpha,
			baseY,
			position.Z + (desiredXZ.Z - position.Z) * alpha
		)
		local look = Vector3.new(target.root.Position.X, baseY, target.root.Position.Z)
		local nextCFrame = if (look - lockPos).Magnitude > 1e-3 then CFrame.lookAt(lockPos, look) else CFrame.new(lockPos)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, lockPos.X, lockPos.Z)
		return
	elseif intent.move == "evade" and enemy.evadeOrigin and enemy.evadeTarget then
		-- Parabolic backstep leap: fast horizontal ease-out + real aerial jump arc, facing the player.
		local dur = math.max(enemy.evadeDuration, 0.05)
		local u = math.clamp((t - enemy.evadeStartedAt) / dur, 0, 1)
		local ease = 1 - (1 - u) * (1 - u)
		local arcHeight = enemy.spec.evadeArcHeight or 5.5
		local baseY = enemy.spec.size.Y / 2
		local leapPos = Vector3.new(
			enemy.evadeOrigin.X + (enemy.evadeTarget.X - enemy.evadeOrigin.X) * ease,
			baseY + 4 * arcHeight * u * (1 - u),
			enemy.evadeOrigin.Z + (enemy.evadeTarget.Z - enemy.evadeOrigin.Z) * ease
		)
		local look = Vector3.new(target.root.Position.X, leapPos.Y, target.root.Position.Z)
		local nextCFrame = if (look - leapPos).Magnitude > 1e-3 then CFrame.lookAt(leapPos, look) else CFrame.new(leapPos)
		moveEnemy(enemy, nextCFrame)
		grid:move(enemy, leapPos.X, leapPos.Z)
		return
	elseif enemy.state.phase == "beamCharge" then
		-- Track the player during early charge, then lock aim for the final `beamLockTime` so the
		-- player can react with a lateral Dash or jump.
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
	elseif isLunging then
		local chargeDir = enemy.lungeDirection or (if toward.Magnitude > 1e-3 then toward.Unit else Vector3.new(0, 0, -1))
		local lungeSpeed = enemy.spec.lungeSpeed or (enemy.spec.speed * 3.5)
		local moved = Waves.clamp(position + chargeDir * lungeSpeed * dt, Config.ROOM_SIZE, WALL_MARGIN)
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
		elseif enemy.kind == "ranged" then
			direction = Tactics.steerToSector(
				position,
				target.root.Position,
				sectorAngle,
				(enemy.spec.keepAway or 28) + enemy.radiusBias,
				3.5,
				enemy.orbitSign,
				0.35
			)
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
		elseif enemy.kind == "ranged" then
			-- Ranged units spread across opposite firing sectors around the player for crossfire.
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

	-- Separation via the spatial grid, so a wave spreads into a crowd in O(local) rather than O(N^2).
	local push = separationPush(enemy, position)

	local candidate = position + (direction * (enemy.spec.speed * speedScale) + push * enemy.spec.speed) * dt
	local moved = Waves.clamp(candidate, Config.ROOM_SIZE, WALL_MARGIN)
	if (moved.X ~= candidate.X or moved.Z ~= candidate.Z) and (intent.move == "flank" or enemy.kind == "ranged") then
		enemy.orbitSign = -enemy.orbitSign
		enemy.orbitFlipAt = t + 3.5 + math.random() * 2.5
	end
	local look = Vector3.new(target.root.Position.X, moved.Y, target.root.Position.Z)
	local nextCFrame = if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved)
	moveEnemy(enemy, nextCFrame)
	grid:move(enemy, moved.X, moved.Z)
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
		local position = shot.part.Position + shot.velocity * dt
		local done = t >= shot.expiresAt
		if not done then
			local inside = Waves.clamp(position, Config.ROOM_SIZE, 0)
			done = inside.X ~= position.X or inside.Z ~= position.Z
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
							EnemyService.damage(enemy, shot.damage)
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
						local landed, outcome = hurt(target.player, shot.damage, { canBlock = true, canParry = true })
						if outcome == "parry" then
							-- Deflect the shot back toward the shooter (or nearest enemy) at boosted speed.
							local dir = reflectDirection(position, shot.velocity, shot.shooter)
							local speed = shot.velocity.Magnitude * Config.PARRY_PROJECTILE_SPEED_MULTIPLIER
							shot.reflected = true
							shot.velocity = dir * speed
							shot.damage = Config.PARRY_PROJECTILE_DAMAGE
							shot.expiresAt = t + Config.PARRY_PROJECTILE_LIFE
							shot.part.Color = PARRIED_SHOT_COLOR
							if shot.isTracer then
								shot.part.Size = Vector3.new(0.45, 0.45, 4.4)
							else
								shot.part.Size = Vector3.one * 2.1
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
			shot.part:Destroy()
			table.remove(projectiles, i)
		else
			if shot.isTracer and shot.velocity.Magnitude > 1e-3 then
				shot.part.CFrame = CFrame.lookAt(position, position + shot.velocity)
			else
				shot.part.Position = position
			end
		end
	end
end

local function step(dt: number)
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
					if enemy.kind == "ranged" then
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
				else
					sectorAngle = closeSectors[enemy] or 0
				end
			end
			stepEnemy(enemy, list, grabbedPositions, target, dist, canAttack, sectorAngle, dt, t)
		end
	end
	for i = #enemies, 1, -1 do
		if enemies[i].dead then
			table.remove(enemies, i)
		end
	end
	stepProjectiles(list, dt, t)
end

function EnemyService.start(dependencies: {
	hurt: (Player, number, { canDodge: boolean?, canBlock: boolean?, canParry: boolean? }?) -> (boolean, string?),
	world: Instance,
	onKill: ((Vector3) -> ())?,
	canGrab: ((Player) -> boolean)?,
	setGrabbed: ((Player, boolean, number?, number?) -> ())?,
	warnGrab: ((Player, number) -> ())?,
	warnParry: ((Player, number) -> ())?,
})
	hurt = dependencies.hurt
	onKill = dependencies.onKill
	canGrab = dependencies.canGrab
	setGrabbed = dependencies.setGrabbed
	warnGrab = dependencies.warnGrab
	warnParry = dependencies.warnParry
	folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = dependencies.world
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
	for _, enemy in ipairs(enemies) do
		if enemy.grabTarget == player then
			releaseGrab(enemy, now(), false)
		end
	end
end

function EnemyService.spawn(kind: string, position: Vector3): Enemy?
	local spec = Config.ENEMY_KINDS[kind]
	if not spec then
		warn(`no enemy kind "{kind}" in Config.ENEMY_KINDS`)
		return nil
	end

	local model: Model
	local body: BasePart
	local modelName, weapon, variantSpec = pickVariant(kind, spec)
	-- Merge variant-specific combat overrides (e.g. dual spin DPS, double-burst, minigun tracers)
	-- onto a per-enemy copy of `spec` so `Brain` and `fire` stay generic.
	local effectiveSpec = if variantSpec then table.clone(spec) else spec
	if variantSpec then
		for k, v in pairs(variantSpec) do
			if k ~= "model" and k ~= "weapon" and k ~= "weight" then
				effectiveSpec[k] = v
			end
		end
	end
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
		sandyOrigin = nil,
		sandyTarget = nil,
		sandyStartedAt = 0,
		sandyDuration = 0,
		sandyStepIndex = 0,
	}
	syncPhase(enemy, spawnNow)
	model.Parent = folder
	table.insert(enemies, enemy)
	grid:insert(enemy, body.Position.X, body.Position.Z)
	if enemy.radius > maxEnemyRadius then
		maxEnemyRadius = enemy.radius
	end
	return enemy
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

function EnemyService.damage(enemy: Enemy, amount: number)
	if enemy.dead then
		return
	end
	enemy.health -= amount
	enemy.fill.Size = UDim2.fromScale(math.clamp(enemy.health / enemy.spec.health, 0, 1), 1)
	if enemy.health <= 0 then
		kill(enemy)
		return
	end
	-- Teammates attacking a grabber contribute toward breaking the trapped player free even if
	-- the trapped player is not pressing the escape button (plans/gdd/content.md).
	if enemy.grabTarget then
		local nextVal, freed =
			Brain.escapeProgress(enemy.grabProgress, Config.GRAB_ALLY_HIT_PROGRESS, Config.GRAB_ESCAPE_PRESSES)
		enemy.grabProgress = nextVal
		enemy.grabTarget:SetAttribute("GrabProgress", nextVal)
		if freed then
			releaseGrab(enemy, now(), true)
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
		releaseGrab(enemy, t, false)
		enemy.model:Destroy()
	end
	table.clear(enemies)
	table.clear(lastRangedShotAt)
	grid:clear()
	maxEnemyRadius = 0
	for _, shot in ipairs(projectiles) do
		shot.part:Destroy()
	end
	table.clear(projectiles)
end

return EnemyService
