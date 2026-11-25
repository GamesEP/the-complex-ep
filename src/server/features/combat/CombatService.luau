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
local Remotes = require(Shared.core.Net.Remotes)
local CombatAudio = require(Shared.features.combat.CombatAudio)
local Drops = require(Shared.features.drops.Drops)
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

-- The triggering client already played its own predicted swing/spin/dash locally with zero
-- latency; only teammates need the server broadcast so co-op actions are audible and visible
-- without double-playing.
local function broadcastOthers(source: Player, cue: string, position: Vector3, step: number?)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= source then
			Remotes.CombatSfx:FireClient(other, cue, position, step)
		end
	end
end

local function broadcastAnimOthers(source: Player, action: string, step: number?)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= source then
			Remotes.CombatAnim:FireClient(other, source, action, step)
		end
	end
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

-- Equips the tracked `.rbxmx` test sword onto the character's right hand so every client sees
-- it follow the procedural combat animations. Falls back to finding `Grip` by name because
-- Rojo 7 live-sync can drop `Model.PrimaryPart` on `.rbxmx` imports. Also called on
-- `CharacterAppearanceLoaded` because Roblox replaces R15 body parts after `CharacterAdded`.
local function equipTestSword(character: Model)
	local models = ReplicatedStorage:FindFirstChild("Models")
	local template = models and models:FindFirstChild(Config.TEST_SWORD_MODEL)
	if not template or not template:IsA("Model") then
		return
	end
	local hand = character:WaitForChild("RightHand", 5) or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") or not hand:IsDescendantOf(character) then
		return
	end
	local existing = character:FindFirstChild(Config.TEST_SWORD_MODEL)
	if existing then
		existing:Destroy()
	end

	local sword = template:Clone()
	local grip = sword.PrimaryPart or sword:FindFirstChild("Grip")
	if not grip or not grip:IsA("BasePart") then
		sword:Destroy()
		return
	end
	sword.PrimaryPart = grip
	sword.WorldPivot = grip.CFrame

	local gripAttachment = hand:FindFirstChild("RightGripAttachment")
	if gripAttachment and gripAttachment:IsA("Attachment") then
		-- RightGripAttachment points -Z forward and slightly down in idle; lift 25 deg so the
		-- blade sits level and reads clearly from the isometric camera.
		sword:PivotTo(gripAttachment.WorldCFrame * CFrame.Angles(math.rad(25), 0, 0))
	else
		sword:PivotTo(hand.CFrame * CFrame.new(0, -1, 0))
	end
	sword.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Name = "SwordGripWeld"
	weld.Part0 = hand
	weld.Part1 = grip
	weld.Parent = grip
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
	player:SetAttribute("DamageBuffUntil", 0)
	player:SetAttribute("SpeedBuffUntil", 0)
	task.spawn(equipTestSword, character)
end

local function onPlayer(player: Player)
	-- Shift lock toggles on LeftShift, which is the dash. The isometric camera has no use for it.
	player.DevEnableMouseLock = false
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	-- Roblox replaces R15 limbs when avatar appearance finishes loading, which breaks a weld
	-- attached during CharacterAdded; re-equip once the final RightHand is in place.
	player.CharacterAppearanceLoaded:Connect(function(character)
		task.spawn(equipTestSword, character)
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

-- Applies a combat drop collected from DropService. Returns whether the drop was consumed so a
-- full-health player leaves heal pickups on the floor for later or for teammates.
function CombatService.applyDrop(player: Player, kind: Drops.DropKind): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return false
	end

	local t = now()
	if kind == "heal" then
		local newHealth, healed = Drops.heal(humanoid.Health, humanoid.MaxHealth, Config.DROP_HEAL_AMOUNT)
		if not healed then
			return false
		end
		humanoid.Health = newHealth
		return true
	elseif kind == "damage" then
		player:SetAttribute("DamageBuffUntil", t + Config.BUFF_DAMAGE_DURATION)
		return true
	elseif kind == "speed" then
		local untilAt = t + Config.BUFF_SPEED_DURATION
		player:SetAttribute("SpeedBuffUntil", untilAt)
		humanoid.WalkSpeed = Drops.moveSpeed(Config.MOVE_SPEED, untilAt, t, Config.BUFF_SPEED_MULTIPLIER)
		-- Re-check the attribute when the timer fires so picking up a second speed buff refreshes
		-- the timer instead of being reset early by the first timer.
		task.delay(Config.BUFF_SPEED_DURATION + 0.05, function()
			if humanoid.Parent and humanoid.Health > 0 then
				humanoid.WalkSpeed = Drops.moveSpeed(
					Config.MOVE_SPEED,
					player:GetAttribute("SpeedBuffUntil"),
					now(),
					Config.BUFF_SPEED_MULTIPLIER
				)
			end
		end)
		return true
	end
	return false
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
	local baseDamage = Config.COMBO_DAMAGE[step] or Config.COMBO_DAMAGE[1]
	local damage = baseDamage
		* Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), now(), Config.BUFF_DAMAGE_MULTIPLIER)
	broadcastOthers(player, CombatAudio.attackCue(step, Config.COMBO_HITS), root.Position, step)
	broadcastAnimOthers(player, "attack", step)
	local hitAt: Vector3? = nil
	for _, enemy in ipairs(enemies.list()) do
		if Melee.inArc(root.Position, facing, enemy.body.Position, Config.ATTACK_RANGE + enemy.radius, Config.ATTACK_ARC) then
			hitAt = hitAt or enemy.body.Position
			enemies.damage(enemy, damage)
		end
	end
	if hitAt then
		Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
	end
end

-- Remote "Dash". The motion already happened on the client; this grants the invulnerability and
-- starts the cooldown, both of which have to be the server's or a client could keep them forever.
function CombatService.dash(player: Player)
	local character = player.Character
	local root = rootOf(player)
	if not character or not root then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute("DashReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	player:SetAttribute("DashReadyAt", t + Config.DASH_COOLDOWN)
	character:SetAttribute("InvulnerableUntil", t + Config.DASH_IFRAMES)
	broadcastOthers(player, "playerDash", root.Position)
	broadcastAnimOthers(player, "dash")
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
	broadcastOthers(player, "playerSpin", root.Position)
	broadcastAnimOthers(player, "spin")
	local spinDamage = Config.SPIN_DAMAGE
		* Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), t, Config.BUFF_DAMAGE_MULTIPLIER)
	local hitAt: Vector3? = nil
	for _, enemy in ipairs(enemies.list()) do
		if Melee.inRadius(root.Position, enemy.body.Position, Config.SPIN_RADIUS + enemy.radius) then
			hitAt = hitAt or enemy.body.Position
			enemies.damage(enemy, spinDamage)
		end
	end
	if hitAt then
		Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
	end
end

return CombatService
