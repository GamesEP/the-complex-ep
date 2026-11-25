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
}

type Projectile = {
	part: BasePart,
	velocity: Vector3,
	expiresAt: number,
	damage: number,
}

-- How far inside the walls an enemy is kept.
local WALL_MARGIN = 3
local FLASH_SECONDS = 0.08
local HIT_COLOR = Color3.new(1, 1, 1)

local hurt: (Player, number) -> boolean = nil :: any
local onKill: ((Vector3) -> ())? = nil
local folder: Folder = nil :: any

local enemies: { Enemy } = {}
local projectiles: { Projectile } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Every living player's root, for the enemies to choose from.
local function targets(): { { player: Player, root: BasePart } }
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root then
			table.insert(list, { player = player, root = root :: BasePart })
		end
	end
	return list
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
	enemy.body.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
end

local function kill(enemy: Enemy)
	if enemy.dead then
		return
	end
	enemy.dead = true
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
			hurt(target.player, enemy.spec.damage)
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

local function stepEnemy(enemy: Enemy, list, dt: number, t: number)
	local body = enemy.body
	local position = body.Position
	local target, distance = nearest(position, list)
	if not target then
		return
	end

	local before = enemy.state.phase
	local state, intent = Brain.step(enemy.kind, enemy.spec, enemy.state, distance, t)
	enemy.state = state
	if state.phase ~= before then
		setTelegraph(enemy, state.phase == "windup" or state.phase == "fuse")
		if state.phase == "windup" then
			Remotes.CombatSfx:FireAllClients("enemyMeleeWindup", position)
		elseif state.phase == "fuse" then
			Remotes.CombatSfx:FireAllClients("enemyExploderFuse", position)
		end
	end

	if intent.action == "strike" then
		Remotes.CombatSfx:FireAllClients("enemyMeleeStrike", position)
		-- The reach is checked again at the moment of the strike, with a little slack: the windup
		-- is the warning, and a player who dashed out during it has earned the miss.
		if distance <= (enemy.spec.reach + enemy.radius) * 1.2 then
			hurt(target.player, enemy.spec.damage)
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

	local moved = position + (direction * enemy.spec.speed + push * enemy.spec.speed) * dt
	moved = Waves.clamp(moved, Config.ROOM_SIZE, WALL_MARGIN)
	local look = Vector3.new(target.root.Position.X, moved.Y, target.root.Position.Z)
	if (look - moved).Magnitude > 1e-3 then
		body.CFrame = CFrame.lookAt(moved, look)
	else
		body.CFrame = CFrame.new(moved)
	end
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
			for _, target in ipairs(list) do
				local offset = Vector3.new(target.root.Position.X - position.X, 0, target.root.Position.Z - position.Z)
				-- A dashing player is not hit, and the shot carries on through them.
				if offset.Magnitude <= Config.PROJECTILE_HIT_RADIUS and hurt(target.player, shot.damage) then
					done = true
					break
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
	local list = targets()
	for _, enemy in ipairs(enemies) do
		if not enemy.dead then
			stepEnemy(enemy, list, dt, t)
		end
	end
	for i = #enemies, 1, -1 do
		if enemies[i].dead then
			table.remove(enemies, i)
		end
	end
	stepProjectiles(list, dt, t)
end

function EnemyService.start(dependencies: { hurt: (Player, number) -> boolean, world: Instance, onKill: ((Vector3) -> ())? })
	hurt = dependencies.hurt
	onKill = dependencies.onKill
	folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = dependencies.world
	RunService.Heartbeat:Connect(step)
end

function EnemyService.spawn(kind: string, position: Vector3): Enemy?
	local spec = Config.ENEMY_KINDS[kind]
	if not spec then
		warn(`no enemy kind "{kind}" in Config.ENEMY_KINDS`)
		return nil
	end

	local model = Instance.new("Model")
	model.Name = kind
	model:SetAttribute("Kind", kind)

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Anchored = true
	-- Players pass through enemies rather than being shoved by a part the server teleports
	-- every frame. Hits are judged by distance, so nothing needs the collision.
	body.CanCollide = false
	body.CanTouch = false
	body.Size = spec.size
	body.Color = spec.color
	body.Material = Enum.Material.SmoothPlastic
	if kind == "exploder" then
		body.Shape = Enum.PartType.Ball
	end
	body.Position = Vector3.new(position.X, spec.size.Y / 2, position.Z)
	body.Parent = model
	model.PrimaryPart = body

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
	for _, enemy in ipairs(enemies) do
		enemy.dead = true
		enemy.model:Destroy()
	end
	table.clear(enemies)
	for _, shot in ipairs(projectiles) do
		shot.part:Destroy()
	end
	table.clear(projectiles)
end

return EnemyService
