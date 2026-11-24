--[[
	The player's side of a fight: their stats, their swings, their dash and spin, and the one
	function anything uses to hurt them.

	The client moves its own character (Roblox gives it network ownership), so the dash *motion*
	is the client's. What the server owns is everything that decides an outcome: which swing hit
	what, whether a dash is off cooldown, and the invulnerability window a dash buys. Cooldowns the
	HUD shows are written as attributes in server time (`GetServerTimeNow`), which both realms read
	the same. See docs/combat.md.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Melee = require(Shared.features.combat.Melee)

local CombatService = {}

-- A client one frame ahead of the server's clock is not cheating. Cooldowns are checked against
-- this much slack, so a dash pressed the instant the HUD says "ready" is never silently refused.
local COOLDOWN_SLACK = 0.1

type Enemy = { body: BasePart, radius: number }
type Enemies = {
	list: () -> { Enemy },
	damage: (Enemy, number) -> (),
}

local enemies: Enemies = nil :: any

-- Per player, server-only: the combo is judged on the server's own clock, which a client cannot
-- move. Forgotten in `forget`, from the bootstrap's PlayerRemoving.
local swings: { [Player]: { step: number, lastAt: number } } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = Config.PLAYER_MAX_HEALTH
	humanoid.Health = Config.PLAYER_MAX_HEALTH
	humanoid.WalkSpeed = Config.MOVE_SPEED
	humanoid.UseJumpPower = true
	humanoid.JumpPower = Config.JUMP_POWER

	-- Mirrored onto the player rather than read off the Humanoid by the HUD: the player outlives
	-- every character, so the HUD subscribes once instead of re-finding a Humanoid per respawn.
	local function mirror()
		player:SetAttribute("Health", math.max(humanoid.Health, 0))
		player:SetAttribute("MaxHealth", humanoid.MaxHealth)
	end
	mirror()
	humanoid.HealthChanged:Connect(mirror)

	swings[player] = nil
	player:SetAttribute("DashReadyAt", 0)
	player:SetAttribute("SpinReadyAt", 0)
end

local function onPlayer(player: Player)
	-- Shift lock toggles on LeftShift, which is the dash. The isometric camera has no use for it.
	player.DevEnableMouseLock = false
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

-- `any` in: EnemyService carries more than this module uses, and a sealed table type would
-- refuse it for that. What is read from it is the `Enemies` shape above.
function CombatService.start(dependencies: { enemies: any })
	enemies = dependencies.enemies :: Enemies
	Players.RespawnTime = Config.RESPAWN_SECONDS
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
end

function CombatService.forget(player: Player)
	swings[player] = nil
end

-- The one way anything hurts a player. Returns whether the hit landed, so a projectile can pass
-- through a dashing player instead of vanishing on them.
function CombatService.hurt(player: Player, amount: number): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return false
	end
	local invulnerableUntil = character:GetAttribute("InvulnerableUntil")
	if type(invulnerableUntil) == "number" and now() < invulnerableUntil then
		return false
	end
	humanoid:TakeDamage(amount)
	return true
end

-- Remote "Attack". `aim` is shape-checked by the contract; what it *means* is decided here. The
-- client sends its aim rather than the server reading the character's facing, because the facing
-- the server has is a physics update behind the remote that announced the swing.
function CombatService.attack(player: Player, aim: Vector3)
	local root = rootOf(player)
	if not root then
		return
	end

	local clock = os.clock()
	local swing = swings[player] or { step = 0, lastAt = -math.huge }
	if clock - swing.lastAt < Config.ATTACK_INTERVAL * Config.ATTACK_TOLERANCE then
		return
	end
	local step = Melee.nextStep(swing.step, swing.lastAt, clock, Config.COMBO_HITS, Config.COMBO_WINDOW)
	swings[player] = { step = step, lastAt = clock }

	local facing = Melee.flat(aim) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end
	local damage = Config.COMBO_DAMAGE[step] or Config.COMBO_DAMAGE[1]
	for _, enemy in ipairs(enemies.list()) do
		if Melee.inArc(root.Position, facing, enemy.body.Position, Config.ATTACK_RANGE + enemy.radius, Config.ATTACK_ARC) then
			enemies.damage(enemy, damage)
		end
	end
end

-- Remote "Dash". The motion already happened on the client; this grants the invulnerability and
-- starts the cooldown, both of which have to be the server's or a client could keep them forever.
function CombatService.dash(player: Player)
	local character = player.Character
	if not character or not rootOf(player) then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute("DashReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	player:SetAttribute("DashReadyAt", t + Config.DASH_COOLDOWN)
	character:SetAttribute("InvulnerableUntil", t + Config.DASH_IFRAMES)
end

-- Remote "Spin". Everything around the player, once per cooldown.
function CombatService.spin(player: Player)
	local root = rootOf(player)
	if not root then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute("SpinReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	player:SetAttribute("SpinReadyAt", t + Config.SPIN_COOLDOWN)
	for _, enemy in ipairs(enemies.list()) do
		if Melee.inRadius(root.Position, enemy.body.Position, Config.SPIN_RADIUS + enemy.radius) then
			enemies.damage(enemy, Config.SPIN_DAMAGE)
		end
	end
end

return CombatService
