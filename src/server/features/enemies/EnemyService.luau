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
local Waves = require(Shared.features.enemies.Waves)

local EnemyService = {}

export type Enemy = {
	kind: string,
	spec: any,
	model: Model,
	body: BasePart,
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
}

type Projectile = {
	part: BasePart,
	velocity: Vector3,
	expiresAt: number,
	damage: number,
	reflected: boolean,
	shooter: Enemy?,
}

-- How far inside the walls an enemy is kept.
local WALL_MARGIN = 3
local FLASH_SECONDS = 0.08
local HIT_COLOR = Color3.new(1, 1, 1)
local PARRIED_SHOT_COLOR = Color3.fromRGB(255, 225, 90)

local hurt: (Player, number, { canBlock: boolean?, canParry: boolean? }?) -> (boolean, string?) = nil :: any
local onKill: ((Vector3) -> ())? = nil
local canGrab: ((Player) -> boolean)? = nil
local setGrabbed: ((Player, boolean, number?, number?) -> ())? = nil
local warnGrab: ((Player, number) -> ())? = nil
local folder: Folder = nil :: any

local enemies: { Enemy } = {}
local projectiles: { Projectile } = {}

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

local function separationPush(enemy: Enemy, position: Vector3): Vector3
	local push = Vector3.zero
	for _, other in ipairs(enemies) do
		if other ~= enemy and not other.dead then
			local apart = Vector3.new(position.X - other.body.Position.X, 0, position.Z - other.body.Position.Z)
			local gap = apart.Magnitude
			if gap > 1e-3 and gap < Config.ENEMY_SPACING then
				push += apart.Unit * (Config.ENEMY_SPACING - gap) / Config.ENEMY_SPACING
			end
		end
	end
	return push
end

local function nearest(position: Vector3, list: { { player: Player, root: BasePart } })
	local best, bestDistance = nil, math.huge
	for _, target in ipairs(list) do
		local distance = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z).Magnitude
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

-- A short-lived visual the server owns, so every player sees it.
local function burst(position: Vector3, radius: number, color: Color3)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.one * 2
	part.Position = position
	part.Parent = folder
	TweenService:Create(part, TweenInfo.new(0.3), { Size = Vector3.one * radius * 2, Transparency = 1 }):Play()
	task.delay(0.35, function()
		part:Destroy()
	end)
end

local function setTelegraph(enemy: Enemy, on: boolean)
	-- Neon while winding up or fused: the tell a player reads to know when to dash.
	local mat = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
	enemy.body.Material = mat
	if enemy.kind == "grabber" then
		for _, armName in ipairs({ "LeftArm", "RightArm" }) do
			local arm = enemy.model:FindFirstChild(armName)
			if arm and arm:IsA("BasePart") then
				arm.Material = mat
			end
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
	if not enemy.dead then
		enemy.state = Brain.releaseGrab(enemy.state, enemy.spec.recover or 1.6, t)
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
	releaseGrab(enemy, now(), true)
	local position = enemy.body.Position
	burst(position, enemy.radius, enemy.spec.color)
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
	local part = Instance.new("Part")
	part.Name = "Shot"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = enemy.spec.color
	part.Size = Vector3.one * 1.5
	-- At chest height of a standing character, so it reads as "aimed at me" from the camera.
	part.Position = Vector3.new(origin.X, 3, origin.Z)
	part.Parent = folder
	table.insert(projectiles, {
		part = part,
		velocity = aim.Unit * enemy.spec.projectileSpeed,
		expiresAt = now() + enemy.spec.projectileLife,
		damage = enemy.spec.damage,
		reflected = false,
		shooter = enemy,
	})
	Remotes.CombatSfx:FireAllClients("enemyRangedFire", origin)
end

local function explode(enemy: Enemy, list: { { player: Player, root: BasePart } })
	local origin = enemy.body.Position
	local blastRadius = enemy.spec.blastRadius
	-- Mark dead before applying AoE so the exploder never damages itself.
	enemy.dead = true
	for _, target in ipairs(list) do
		if Brain.inBlast(origin, target.root.Position, blastRadius, 0) then
			hurt(target.player, enemy.spec.damage, { canBlock = true, canParry = false })
		end
	end
	local enemyDamage = enemy.spec.enemyDamage or enemy.spec.damage
	if enemyDamage and enemyDamage > 0 then
		-- Snapshot living targets in blast range so kills do not affect iteration.
		local caught: { Enemy } = {}
		for _, other in ipairs(enemies) do
			if other ~= enemy and not other.dead and Brain.inBlast(origin, other.body.Position, blastRadius, other.radius) then
				table.insert(caught, other)
			end
		end
		for _, other in ipairs(caught) do
			EnemyService.damage(other, enemyDamage)
		end
	end
	burst(origin, blastRadius, enemy.spec.color)
	Remotes.CombatSfx:FireAllClients("enemyExploderBlast", origin)
	enemy.model:Destroy()
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

local function stepEnemy(enemy: Enemy, list, grabbedPositions: { Vector3 }, dt: number, t: number)
	if enemy.grabTarget then
		stepHeldGrab(enemy, t)
		return
	end

	local body = enemy.body
	local position = body.Position
	local target, distance = nearest(position, list)
	if not target then
		-- Cancel any in-progress windup/fuse so an ignored enemy cannot fire an instant buffered
		-- strike or blast the frame the player breaks free.
		if enemy.state.phase == "windup" or enemy.state.phase == "fuse" then
			enemy.state = Brain.initial(t)
			setTelegraph(enemy, false)
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
		enemy.model:PivotTo(nextCFrame)
		return
	end

	local before = enemy.state.phase
	local state, intent = Brain.step(enemy.kind, enemy.spec, enemy.state, distance, t)
	enemy.state = state
	if state.phase ~= before then
		setTelegraph(enemy, state.phase == "windup" or state.phase == "fuse")
		if state.phase == "windup" then
			if enemy.kind == "grabber" then
				Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", position)
				if warnGrab then
					warnGrab(target.player, state.endsAt)
				end
			else
				Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
			end
		elseif state.phase == "fuse" then
			Remotes.CombatSfx:FireAllClients("enemyExploderFuse", position)
		end
	end

	if intent.action == "strike" then
		Remotes.CombatSfx:FireAllClients("enemyMeleeStrike", position)
		-- The reach is checked again at the moment of the strike, with a little slack: the windup
		-- is the warning, and a player who dashed out during it has earned the miss.
		if distance <= (enemy.spec.reach + enemy.radius) * 1.2 then
			local _, outcome = hurt(target.player, enemy.spec.damage, { canBlock = true, canParry = true })
			if outcome == "parry" then
				-- Parrying a melee strike staggers the attacker into an extended recover window.
				enemy.state = Brain.releaseGrab(enemy.state, Config.PARRY_STUN_SECONDS, t)
			end
		end
	elseif intent.action == "grab" then
		if distance <= (enemy.spec.reach + enemy.radius) * 1.2 and (not canGrab or canGrab(target.player)) then
			enemy.state = Brain.enterHolding(enemy.state)
			enemy.grabTarget = target.player
			enemy.grabProgress = 0
			enemy.nextGrabDamageAt = t + Config.GRAB_DAMAGE_TICK_SECONDS
			if setGrabbed then
				setGrabbed(target.player, true, 0, Config.GRAB_ESCAPE_PRESSES)
			end
			Remotes.CombatSfx:FireAllClients("enemyGrabberGrab", position)
			return
		end
	elseif intent.action == "fire" then
		fire(enemy, target.root)
	elseif intent.action == "explode" then
		explode(enemy, list)
		return
	end

	local toward = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
	local direction = Vector3.zero
	if toward.Magnitude > 1e-3 then
		if intent.move == "toward" then
			direction = toward.Unit
		elseif intent.move == "away" then
			direction = -toward.Unit
		end
	end

	-- Separation, so a wave spreads into a crowd instead of stacking into one block.
	local push = separationPush(enemy, position)

	local moved = position + (direction * enemy.spec.speed + push * enemy.spec.speed) * dt
	moved = Waves.clamp(moved, Config.ROOM_SIZE, WALL_MARGIN)
	local look = Vector3.new(target.root.Position.X, moved.Y, target.root.Position.Z)
	local nextCFrame = if (look - moved).Magnitude > 1e-3 then CFrame.lookAt(moved, look) else CFrame.new(moved)
	-- PivotTo moves multi-part `.rbxmx` enemies (like EnemyGrabber) together with Body.
	enemy.model:PivotTo(nextCFrame)
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
				for _, enemy in ipairs(enemies) do
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
					local offset = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
					if offset.Magnitude <= Config.PROJECTILE_HIT_RADIUS then
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
							shot.part.Size = Vector3.one * 2.1
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
			shot.part.Position = position
		end
	end
end

local function step(dt: number)
	local t = now()
	local list, grabbedPositions = targets()
	for _, enemy in ipairs(enemies) do
		if not enemy.dead then
			stepEnemy(enemy, list, grabbedPositions, dt, t)
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
	hurt: (Player, number, { canBlock: boolean?, canParry: boolean? }?) -> (boolean, string?),
	world: Instance,
	onKill: ((Vector3) -> ())?,
	canGrab: ((Player) -> boolean)?,
	setGrabbed: ((Player, boolean, number?, number?) -> ())?,
	warnGrab: ((Player, number) -> ())?,
})
	hurt = dependencies.hurt
	onKill = dependencies.onKill
	canGrab = dependencies.canGrab
	setGrabbed = dependencies.setGrabbed
	warnGrab = dependencies.warnGrab
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
	local models = spec.model and ReplicatedStorage:FindFirstChild("Models")
	local template = models and models:FindFirstChild(spec.model)
	if template and template:IsA("Model") then
		model = template:Clone()
		local foundBody = model.PrimaryPart or model:FindFirstChild("Body")
		assert(foundBody and foundBody:IsA("BasePart"), `enemy model {spec.model} must carry a Body BasePart`)
		body = foundBody
		-- Re-stamp PrimaryPart/WorldPivot because Rojo 7 live-sync can drop PrimaryPart on .rbxmx.
		model.PrimaryPart = body
		model.WorldPivot = body.CFrame
		model.Name = kind
		model:SetAttribute("Kind", kind)
		model:PivotTo(CFrame.new(position.X, spec.size.Y / 2, position.Z))
	else
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

	local enemy: Enemy = {
		kind = kind,
		spec = spec,
		model = model,
		body = body,
		fill = healthBar(body, spec.size.Y),
		radius = math.max(spec.size.X, spec.size.Z) / 2,
		health = spec.health,
		state = Brain.initial(now()),
		dead = false,
		grabTarget = nil,
		grabProgress = 0,
		nextGrabDamageAt = 0,
		wanderHeading = randomHeading(),
		wanderUntil = now() + Config.ENEMY_WANDER_INTERVAL * math.random(),
	}
	model.Parent = folder
	table.insert(enemies, enemy)
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
	local body = enemy.body
	body.Color = HIT_COLOR
	task.delay(FLASH_SECONDS, function()
		if not enemy.dead then
			body.Color = enemy.spec.color
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
	for _, shot in ipairs(projectiles) do
		shot.part:Destroy()
	end
	table.clear(projectiles)
end

return EnemyService
