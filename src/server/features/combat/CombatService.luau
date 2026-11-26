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
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local CombatAudio = require(Shared.features.combat.CombatAudio)
local Defense = require(Shared.features.combat.Defense)
local Drops = require(Shared.features.drops.Drops)
local Melee = require(Shared.features.combat.Melee)
local Classes = require(Shared.features.classes.Classes)
local Waves = require(Shared.features.enemies.Waves)

local CombatService = {}

-- A client one frame ahead of the server's clock is not cheating. Cooldowns are checked against
-- this much slack, so a dash pressed the instant the HUD says "ready" is never silently refused.
local COOLDOWN_SLACK = 0.1

type Enemy = { body: BasePart, model: Model?, radius: number, health: number, dead: boolean?, spec: any, state: any }
type Enemies = {
	list: () -> { Enemy },
	damage: (Enemy, number) -> (),
	taunt: (Enemy, Player, number) -> (),
	shove: (Enemy, Vector3, number, number, number, number) -> (),
	stun: (Enemy, number) -> (),
}

local enemies: Enemies = nil :: any
local isPaused: (() -> boolean)? = nil

local function paused(): boolean
	return isPaused ~= nil and isPaused()
end

-- Per player, server-only: the combo and heavy-charge clocks are judged on the server's own
-- `os.clock()`, which a client cannot move. Forgotten in `forget`, from PlayerRemoving.
local swings: { [Player]: { step: number, lastAt: number } } = {}
local heavyCharges: { [Player]: number } = {}
local overDriveTokens: { [Player]: number } = {}
local dashStates: { [Player]: { charges: number, rechargeAt: number } } = {}

-- Active Support 10 s healing zones, Support ranged bolts/arcane orbs, and Damage boomerang daggers.
type HealZone = { position: Vector3, radius: number, untilAt: number, nextTickAt: number }
type PlayerBolt = {
	id: number,
	owner: Player,
	position: Vector3,
	velocity: Vector3,
	radius: number,
	damage: number,
	splashRadius: number,
	stunDuration: number,
	expiresAt: number,
	kind: string,
}
type Boomerang = {
	owner: Player,
	startPos: Vector3,
	apexPos: Vector3,
	startedAt: number,
	outSeconds: number,
	returnSeconds: number,
	outDamage: number,
	returnDamage: number,
	hitOut: { [Enemy]: boolean },
	hitBack: { [Enemy]: boolean },
}

local healZones: { HealZone } = {}
local playerBolts: { PlayerBolt } = {}
local boomerangs: { Boomerang } = {}
local nextBoltId = 0

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

local function classIdOf(player: Player): string?
	local classId = player:GetAttribute("Class")
	return if type(classId) == "string" and classId ~= "" then classId else nil
end

-- Clones one tracked `.rbxmx` weapon and welds its `Grip` to a hand. Falls back to finding `Grip`
-- by name because Rojo 7 live-sync can drop `Model.PrimaryPart` on `.rbxmx` imports.
--
-- The grip attachment's -Z runs down the forearm, so the weapon is pitched forward by its own
-- `GripPitch` attribute (written by scripts/generate-models.luau), or by SWORD_GRIP_PITCH, to be
-- held out in front instead of hanging into the floor.
local function equipWeapon(character: Model, modelName: string, handName: string, attachmentName: string)
	local models = ReplicatedStorage:FindFirstChild("Models")
	local template = models and models:FindFirstChild(modelName)
	if not template or not template:IsA("Model") then
		warn(`no weapon model "{modelName}" under ReplicatedStorage.Models`)
		return
	end
	local hand = character:WaitForChild(handName, 5)
	if not hand or not hand:IsA("BasePart") or not hand:IsDescendantOf(character) then
		return
	end

	local weapon = template:Clone()
	local grip = weapon.PrimaryPart or weapon:FindFirstChild("Grip")
	if not grip or not grip:IsA("BasePart") then
		weapon:Destroy()
		return
	end
	weapon.PrimaryPart = grip
	weapon.WorldPivot = grip.CFrame
	weapon:SetAttribute("EquippedWeapon", true)

	local function angle(attribute: string, default: number): number
		local value = template:GetAttribute(attribute)
		return math.rad(if type(value) == "number" then value else default)
	end
	local turn = CFrame.Angles(angle("GripPitch", Config.SWORD_GRIP_PITCH), angle("GripYaw", 0), angle("GripRoll", 0))
	local gripAttachment = hand:FindFirstChild(attachmentName)
	if gripAttachment and gripAttachment:IsA("Attachment") then
		weapon:PivotTo(gripAttachment.WorldCFrame * turn)
	else
		weapon:PivotTo(hand.CFrame * CFrame.new(0, -1, 0))
	end
	weapon.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Name = "WeaponGripWeld"
	weld.Part0 = hand
	weld.Part1 = grip
	weld.Parent = grip
end

-- Arms the character for its class: main weapon in the right hand, the off-hand weapon (shield,
-- second dagger) in the left. With no class yet, the test sword. Also called on
-- `CharacterAppearanceLoaded`, because Roblox replaces R15 body parts after `CharacterAdded`.
local function equipWeapons(player: Player, character: Model)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("EquippedWeapon") == true then
			child:Destroy()
		end
	end
	local class = Classes.get(classIdOf(player))
	if not class then
		equipWeapon(character, Config.TEST_SWORD_MODEL, "RightHand", "RightGripAttachment")
		return
	end
	equipWeapon(character, class.weapon, "RightHand", "RightGripAttachment")
	if class.offHandWeapon then
		equipWeapon(character, class.offHandWeapon, "LeftHand", "LeftGripAttachment")
	end
end

local function isStunned(player: Player, t: number?): boolean
	local stunnedUntil = player:GetAttribute("StunnedUntil")
	return type(stunnedUntil) == "number" and (t or now()) < stunnedUntil
end

local function refreshWalkSpeed(player: Player, humanoid: Humanoid?)
	local targetHumanoid = humanoid
	if not targetHumanoid then
		local character = player.Character
		targetHumanoid = character and character:FindFirstChildOfClass("Humanoid")
	end
	if not targetHumanoid or targetHumanoid.Health <= 0 then
		return
	end
	local t = now()
	local stunned = isStunned(player, t)
	local chargingOverDrive = player:GetAttribute("OverDriveCharging") == true
	local chargingHeavy = player:GetAttribute("ChargingHeavy") == true
	local chargeMultiplier = if chargingOverDrive
		then Config.OVERDRIVE_CHARGE_MOVE_MULTIPLIER
		else Config.HEAVY_CHARGE_MOVE_MULTIPLIER
	local class = Classes.get(classIdOf(player))
	targetHumanoid.WalkSpeed = Defense.walkSpeed(
		if class then class.moveSpeed else Config.MOVE_SPEED,
		player:GetAttribute("SpeedBuffUntil"),
		player:GetAttribute("Blocking") == true,
		player:GetAttribute("Grabbed") == true,
		t,
		Config.BUFF_SPEED_MULTIPLIER,
		Config.BLOCK_MOVE_MULTIPLIER,
		chargingOverDrive or chargingHeavy,
		chargeMultiplier,
		stunned
	)
end

local function cancelOverDrive(player: Player)
	overDriveTokens[player] = (overDriveTokens[player] or 0) + 1
	if player:GetAttribute("OverDriveCharging") == true then
		player:SetAttribute("OverDriveCharging", false)
		player:SetAttribute("OverDriveChargeStart", 0)
		refreshWalkSpeed(player)
	end
end

local function cancelCharge(player: Player)
	heavyCharges[player] = nil
	if player:GetAttribute("ChargingHeavy") == true then
		player:SetAttribute("ChargingHeavy", false)
		player:SetAttribute("HeavyChargeStart", 0)
		refreshWalkSpeed(player)
	end
end

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local class = Classes.get(classIdOf(player))
	local maxHealth = if class then class.maxHealth else Config.PLAYER_MAX_HEALTH
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	humanoid.WalkSpeed = if class then class.moveSpeed else Config.MOVE_SPEED
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
	heavyCharges[player] = nil
	overDriveTokens[player] = (overDriveTokens[player] or 0) + 1
	dashStates[player] = { charges = 1, rechargeAt = 0 }
	player:SetAttribute("DashReadyAt", 0)
	player:SetAttribute("DashCharges", 1)
	player:SetAttribute("SpinReadyAt", 0)
	player:SetAttribute("StingerReadyAt", 0)
	player:SetAttribute("OverDriveReadyAt", 0)
	player:SetAttribute("OverDriveCharging", false)
	player:SetAttribute("OverDriveChargeStart", 0)
	player:SetAttribute("BlockReadyAt", 0)
	player:SetAttribute("Blocking", false)
	player:SetAttribute("ParryUntil", 0)
	player:SetAttribute("ChargingHeavy", false)
	player:SetAttribute("HeavyChargeStart", 0)
	player:SetAttribute("HeavyReadyAt", 0)
	player:SetAttribute("DamageBuffUntil", 0)
	player:SetAttribute("SpeedBuffUntil", 0)
	player:SetAttribute("DefenseBuffUntil", 0)
	player:SetAttribute("Grabbed", false)
	player:SetAttribute("GrabProgress", 0)
	player:SetAttribute("GrabGoal", Config.GRAB_ESCAPE_PRESSES)
	player:SetAttribute("GrabWarningUntil", 0)
	player:SetAttribute("ParryWarningUntil", 0)
	player:SetAttribute("StunnedUntil", 0)
	player:SetAttribute("GrabImmuneUntil", 0)
	player:SetAttribute("BulwarkUntil", 0)
	player:SetAttribute("ProtectBuffUntil", 0)
	for _, ability in pairs(Config.ABILITIES) do
		player:SetAttribute(ability.readyAttribute, 0)
	end
	task.spawn(equipWeapons, player, character)
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
		task.spawn(equipWeapons, player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

-- `any` in: EnemyService carries more than this module uses, and a sealed table type would
-- refuse it for that. What is read from it is the `Enemies` shape above.
function CombatService.start(dependencies: { enemies: any, isPaused: (() -> boolean)? })
	enemies = dependencies.enemies :: Enemies
	isPaused = dependencies.isPaused
	Players.RespawnTime = Config.RESPAWN_SECONDS
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
end

-- Clears in-flight player bolts, boomerang daggers, and persistent healing zones on room reset.
function CombatService.clear()
	for _, bolt in ipairs(playerBolts) do
		Remotes.CombatVfx:FireAllClients("boltImpact", bolt.id, bolt.position, "cancel", 0)
	end
	table.clear(playerBolts)
	table.clear(boomerangs)
	table.clear(healZones)
end

-- Called by ClassService once a player has picked a class: the character takes the class's health,
-- speed and weapons now, at full health, without waiting for a respawn.
function CombatService.applyClass(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local class = Classes.get(classIdOf(player))
	if not character or not humanoid or humanoid.Health <= 0 or not class then
		return
	end
	humanoid.MaxHealth = class.maxHealth
	humanoid.Health = class.maxHealth
	refreshWalkSpeed(player, humanoid)
	for _, ability in pairs(Config.ABILITIES) do
		player:SetAttribute(ability.readyAttribute, 0)
	end
	task.spawn(equipWeapons, player, character)
end

function CombatService.forget(player: Player)
	swings[player] = nil
	heavyCharges[player] = nil
	overDriveTokens[player] = nil
	dashStates[player] = nil
end

-- How much of a hit survives the class passive, the Tank's Muralla (-75%), and the Support's
-- squad-wide defense buff. They stack multiplicatively.
local function classReduction(player: Player, t: number): number
	local multiplier = Classes.incomingMultiplier(classIdOf(player))
	multiplier *= Classes.bulwarkMultiplier(player:GetAttribute("BulwarkUntil"), t)
	multiplier *= Classes.protectMultiplier(player:GetAttribute("ProtectBuffUntil"), t)
	return multiplier
end

-- Every hit a player lands goes through here: the class multiplier, and the Damage passive when
-- the enemy is stunned/recovering or hit from behind.
local function hitEnemy(player: Player, enemy: Enemy, damage: number, from: Vector3)
	local t = now()
	local stunnedAttr = if enemy.model then enemy.model:GetAttribute("StunnedUntil") else nil
	local isStunned = type(stunnedAttr) == "number" and t < stunnedAttr
	local vulnerable = isStunned
		or (enemy.state and enemy.state.phase == "recover")
		or Classes.isBehind(enemy.body.Position, enemy.body.CFrame.LookVector, from, Config.DPS_BACKSTAB_FRONT_ARC)
	enemies.damage(enemy, damage * Classes.outgoingMultiplier(classIdOf(player), vulnerable))
end

-- The one way anything hurts a player. Returns `(hitLanded, outcome)` so projectiles pass
-- through a dashing player ("invulnerable") and reflect back on a perfect "parry".
function CombatService.hurt(
	player: Player,
	amount: number,
	options: { canDodge: boolean?, canBlock: boolean?, canParry: boolean?, origin: Vector3? }?
): (boolean, Defense.HitOutcome)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return false, "invulnerable"
	end

	local t = now()
	amount *= classReduction(player, t)
	local finalDamage, outcome = Defense.resolveHit(amount, {
		now = t,
		invulnerableUntil = character:GetAttribute("InvulnerableUntil"),
		blocking = player:GetAttribute("Blocking") == true,
		parryUntil = player:GetAttribute("ParryUntil"),
		defenseBuffUntil = player:GetAttribute("DefenseBuffUntil"),
		canDodge = if options then options.canDodge else true,
		canBlock = if options then options.canBlock else true,
		canParry = if options then options.canParry else true,
		blockReduction = Config.BLOCK_DAMAGE_REDUCTION,
		defenseReduction = Config.BUFF_DEFENSE_REDUCTION,
	})

	if outcome == "invulnerable" then
		return false, "invulnerable"
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local pos = if root and root:IsA("BasePart") then root.Position else nil
	if outcome == "parry" then
		if pos then
			Remotes.CombatSfx:FireAllClients("playerParry", pos)
		end
		Remotes.CombatAnim:FireAllClients(player, "parry")
		return false, "parry"
	end

	if outcome == "block" and pos then
		Remotes.CombatSfx:FireAllClients("playerBlock", pos)
	end
	if finalDamage > 0 then
		humanoid:TakeDamage(finalDamage)
	end
	return true, outcome
end

-- Returns whether a grabber may latch onto `player` right now. Respects Dash invulnerability
-- (`InvulnerableUntil`), existing grabs, and post-escape immunity so Dash cleanly dodges grabs.
function CombatService.canGrab(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return false
	end
	if player:GetAttribute("Grabbed") == true then
		return false
	end
	local t = now()
	local invulnerableUntil = character:GetAttribute("InvulnerableUntil")
	if type(invulnerableUntil) == "number" and t < invulnerableUntil then
		return false
	end
	local immuneUntil = player:GetAttribute("GrabImmuneUntil")
	if type(immuneUntil) == "number" and t < immuneUntil then
		return false
	end
	return true
end

-- Signals an incoming grabber windup so the HUD displays the Dash warning for `player`.
function CombatService.warnGrab(player: Player, untilAt: number)
	local current = player:GetAttribute("GrabWarningUntil")
	if type(current) ~= "number" or untilAt > current then
		player:SetAttribute("GrabWarningUntil", untilAt)
	end
end

-- Signals an unavoidable Paso Fantasma ambush slash for `player`.
function CombatService.warnParry(player: Player, untilAt: number)
	local current = player:GetAttribute("ParryWarningUntil")
	if type(current) ~= "number" or untilAt > current then
		player:SetAttribute("ParryWarningUntil", untilAt)
	end
end

-- Staggers and stuns `player` (e.g. hit by a Mace enemy's seismic ground slam): cancels active
-- channels/guard, locks movement and jumping for `duration` seconds, then restores cleanly.
function CombatService.stun(player: Player, duration: number)
	if duration <= 0 then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	local t = now()
	local untilAt = t + duration
	local current = player:GetAttribute("StunnedUntil")
	if type(current) ~= "number" or untilAt > current then
		player:SetAttribute("StunnedUntil", untilAt)
	end
	cancelCharge(player)
	cancelOverDrive(player)
	if player:GetAttribute("Blocking") == true then
		player:SetAttribute("Blocking", false)
		player:SetAttribute("ParryUntil", 0)
	end
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	task.delay(duration + 0.05, function()
		if not player.Parent or not humanoid.Parent or humanoid.Health <= 0 then
			return
		end
		if not isStunned(player) and player:GetAttribute("Grabbed") ~= true then
			refreshWalkSpeed(player, humanoid)
			humanoid.JumpPower = Config.JUMP_POWER
		end
	end)
end

-- Locks or restores player movement when grabbed/released by a grabber. Restores speed buff if
-- active so escaping a grab never strips a running speed pickup.
function CombatService.setGrabbed(player: Player, grabbed: boolean, progress: number?, goal: number?)
	local t = now()
	player:SetAttribute("Grabbed", grabbed)
	player:SetAttribute("GrabProgress", progress or 0)
	player:SetAttribute("GrabGoal", goal or Config.GRAB_ESCAPE_PRESSES)
	if grabbed then
		player:SetAttribute("GrabWarningUntil", 0)
		player:SetAttribute("Blocking", false)
		player:SetAttribute("ParryUntil", 0)
		heavyCharges[player] = nil
		player:SetAttribute("ChargingHeavy", false)
		player:SetAttribute("HeavyChargeStart", 0)
		overDriveTokens[player] = (overDriveTokens[player] or 0) + 1
		player:SetAttribute("OverDriveCharging", false)
		player:SetAttribute("OverDriveChargeStart", 0)
	else
		player:SetAttribute("GrabImmuneUntil", t + Config.GRAB_IMMUNITY_SECONDS)
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if grabbed then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	else
		refreshWalkSpeed(player, humanoid)
		humanoid.JumpPower = Config.JUMP_POWER
	end
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
	elseif kind == "defense" then
		player:SetAttribute("DefenseBuffUntil", t + Config.BUFF_DEFENSE_DURATION)
		return true
	elseif kind == "speed" then
		local untilAt = t + Config.BUFF_SPEED_DURATION
		player:SetAttribute("SpeedBuffUntil", untilAt)
		-- Picking up a Speed Buff immediately unlocks Double Dash (2 charges).
		dashStates[player] = { charges = 2, rechargeAt = 0 }
		player:SetAttribute("DashCharges", 2)
		player:SetAttribute("DashReadyAt", 0)
		refreshWalkSpeed(player, humanoid)
		-- Re-check the attribute when the timer fires so picking up a second speed buff refreshes
		-- the timer instead of being reset early by the first timer.
		task.delay(Config.BUFF_SPEED_DURATION + 0.05, function()
			if humanoid.Parent and humanoid.Health > 0 then
				refreshWalkSpeed(player, humanoid)
			end
		end)
		return true
	end
	return false
end

-- Remote "Block": raises or lowers guard. Raising guard opens a short Parry window (`PARRY_WINDOW`);
-- lowering it starts `BLOCK_COOLDOWN` so players cannot spam guard for permanent Parry.
function CombatService.block(player: Player, active: boolean)
	local t = now()
	if not active then
		if player:GetAttribute("Blocking") == true then
			player:SetAttribute("Blocking", false)
			player:SetAttribute("ParryUntil", 0)
			player:SetAttribute("BlockReadyAt", t + Config.BLOCK_COOLDOWN)
			refreshWalkSpeed(player)
		end
		return
	end

	if paused() or player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player, t) then
		return
	end
	if not rootOf(player) then
		return
	end
	local readyAt = player:GetAttribute("BlockReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	cancelCharge(player)
	player:SetAttribute("Blocking", true)
	player:SetAttribute("ParryUntil", t + Config.PARRY_WINDOW)
	refreshWalkSpeed(player)
end

-- Remote "HeavyCharge": starts or cancels the server-authoritative heavy-attack charge (HEAVY_CHARGE_SECONDS).
function CombatService.heavyCharge(player: Player, active: boolean)
	if not active then
		cancelCharge(player)
		return
	end
	if paused() or player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player) then
		return
	end
	if player:GetAttribute("ChargingHeavy") == true then
		return
	end
	local root = rootOf(player)
	if not root then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute("HeavyReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	heavyCharges[player] = os.clock()
	player:SetAttribute("ChargingHeavy", true)
	-- Backdate by HEAVY_CHARGE_DELAY so the replicated HUD bar reflects the full button hold.
	player:SetAttribute("HeavyChargeStart", t - Config.HEAVY_CHARGE_DELAY)
	refreshWalkSpeed(player)
	broadcastOthers(player, "playerHeavyCharge", root.Position)
end

-- Spawns a server-authoritative player projectile (Support basic energy bolt or Heavy arcane orb).
local function spawnPlayerBolt(
	owner: Player,
	origin: Vector3,
	facing: Vector3,
	speed: number,
	range: number,
	radius: number,
	damage: number,
	splashRadius: number,
	stunDuration: number,
	kind: string,
	step: number
)
	nextBoltId += 1
	local boltId = nextBoltId
	local spawnPos = Vector3.new(origin.X + facing.X * 2.2, 2.5, origin.Z + facing.Z * 2.2)
	local life = math.max(range / math.max(speed, 1), 0.1)
	table.insert(playerBolts, {
		id = boltId,
		owner = owner,
		position = spawnPos,
		velocity = facing * speed,
		radius = radius,
		damage = damage,
		splashRadius = splashRadius,
		stunDuration = stunDuration,
		expiresAt = now() + life,
		kind = kind,
	})
	Remotes.CombatVfx:FireAllClients("staffBolt", boltId, spawnPos, facing, step)
end

-- Remote "HeavyAttack": unleashes a role- and weapon-specific heavy strike once the server
-- confirms the full HEAVY_CHARGE_SECONDS hold completed.
function CombatService.heavyAttack(player: Player, aim: Vector3)
	if paused() or player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player) then
		cancelCharge(player)
		return
	end
	local startedAt = heavyCharges[player]
	local requiredServerCharge = math.max(Config.HEAVY_CHARGE_SECONDS - Config.HEAVY_CHARGE_DELAY, 0)
	if not Melee.isChargeReady(startedAt, os.clock(), requiredServerCharge, Config.HEAVY_CHARGE_SLACK) then
		cancelCharge(player)
		return
	end
	cancelCharge(player)
	local root = rootOf(player)
	if not root then
		return
	end
	local facing = Melee.flat(aim) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end

	local t = now()
	local classId = classIdOf(player)
	local dmgMult = Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), t, Config.BUFF_DAMAGE_MULTIPLIER)
	player:SetAttribute("HeavyReadyAt", t + Config.HEAVY_ATTACK_COOLDOWN)
	swings[player] = { step = 0, lastAt = os.clock() }

	broadcastOthers(player, "playerHeavyAttack", root.Position)
	broadcastAnimOthers(player, "heavyAttack")

	if classId == "tank" then
		-- Tank (Greatsword & Shield): seismic ground slam that damages, shoves outward, and stuns.
		local impactPos = root.Position + facing * Config.TANK_HEAVY_OFFSET
		local damage = Config.TANK_HEAVY_DAMAGE * dmgMult
		local hitAt: Vector3? = nil
		for _, enemy in ipairs(enemies.list()) do
			if Melee.inRadius(impactPos, enemy.body.Position, Config.TANK_HEAVY_RADIUS + enemy.radius) then
				hitAt = hitAt or enemy.body.Position
				hitEnemy(player, enemy, damage, root.Position)
				local away = Melee.flat(enemy.body.Position - impactPos) or facing
				enemies.shove(enemy, away, Config.TANK_HEAVY_PUSH_DISTANCE, 0.2, 1, t)
				enemies.stun(enemy, Config.TANK_HEAVY_STUN_DURATION)
			end
		end
		Remotes.CombatSfx:FireAllClients("enemyExploderBlast", impactPos)
		Remotes.CombatVfx:FireAllClients("heavyAttack", player, root.Position, facing, "tank")
		if hitAt then
			Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
		end
	elseif classId == "dps" then
		-- Damage (Dual Daggers): blistering twin diagonal X-slash burst (two rapid strikes).
		local hitDamage = Config.DPS_HEAVY_HIT_DAMAGE * dmgMult
		local function doSlash(originPos: Vector3, slashFacing: Vector3)
			local hitAt: Vector3? = nil
			for _, enemy in ipairs(enemies.list()) do
				if
					Melee.inArc(
						originPos,
						slashFacing,
						enemy.body.Position,
						Config.DPS_HEAVY_RANGE + enemy.radius,
						Config.DPS_HEAVY_ARC
					)
				then
					hitAt = hitAt or enemy.body.Position
					hitEnemy(player, enemy, hitDamage, originPos)
				end
			end
			if hitAt then
				Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
			end
		end
		doSlash(root.Position, facing)
		Remotes.CombatVfx:FireAllClients("heavyAttack", player, root.Position, facing, "dps")
		task.delay(Config.DPS_HEAVY_SECOND_DELAY, function()
			local currentRoot = rootOf(player)
			if not currentRoot or player:GetAttribute("Grabbed") == true or isStunned(player) then
				return
			end
			local secondFacing = Melee.flat(currentRoot.CFrame.LookVector) or facing
			doSlash(currentRoot.Position, secondFacing)
		end)
	elseif classId == "support" then
		-- Support (Energy Staff): launches a long-range explosive arcane orb that stuns in an AoE.
		local damage = Config.SUPPORT_HEAVY_DAMAGE * dmgMult
		spawnPlayerBolt(
			player,
			root.Position,
			facing,
			Config.SUPPORT_HEAVY_SPEED,
			Config.SUPPORT_HEAVY_RANGE,
			Config.SUPPORT_HEAVY_ORB_RADIUS,
			damage,
			Config.SUPPORT_HEAVY_BLAST_RADIUS,
			Config.SUPPORT_HEAVY_STUN_DURATION,
			"supportHeavy",
			4
		)
	else
		-- Default (no class yet / test sword): classic wide horizontal crescent cleave.
		local damage = Config.HEAVY_ATTACK_DAMAGE * dmgMult
		local hitAt: Vector3? = nil
		for _, enemy in ipairs(enemies.list()) do
			if
				Melee.inArc(
					root.Position,
					facing,
					enemy.body.Position,
					Config.HEAVY_ATTACK_RANGE + enemy.radius,
					Config.HEAVY_ATTACK_ARC
				)
			then
				hitAt = hitAt or enemy.body.Position
				hitEnemy(player, enemy, damage, root.Position)
			end
		end
		Remotes.CombatVfx:FireAllClients("heavyAttack", player, root.Position, facing, "default")
		if hitAt then
			Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
		end
	end
end

-- Remote "Attack". `aim` is shape-checked by the contract; what it *means* is decided here. The
-- client sends its aim rather than the server reading the character's facing, because the facing
-- the server has is a physics update behind the remote that announced the swing.
function CombatService.attack(player: Player, aim: Vector3)
	if paused() or player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player) then
		return
	end
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

	-- Support fights at range with energy bolts from its staff instead of swinging in melee.
	if Classes.isRanged(classIdOf(player)) then
		local isFinisher = step >= Config.COMBO_HITS
		spawnPlayerBolt(
			player,
			root.Position,
			facing,
			Config.STAFF_BOLT_SPEED,
			Config.STAFF_BOLT_RANGE,
			if isFinisher then Config.STAFF_BOLT_FINISHER_RADIUS else Config.STAFF_BOLT_RADIUS,
			damage,
			if isFinisher then Config.STAFF_BOLT_FINISHER_SPLASH else 0,
			0,
			if isFinisher then "staffFinisher" else "staffBolt",
			step
		)
		return
	end

	local hitAt: Vector3? = nil
	for _, enemy in ipairs(enemies.list()) do
		if Melee.inArc(root.Position, facing, enemy.body.Position, Config.ATTACK_RANGE + enemy.radius, Config.ATTACK_ARC) then
			hitAt = hitAt or enemy.body.Position
			hitEnemy(player, enemy, damage, root.Position)
		end
	end
	if hitAt then
		Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
	end
end

-- Remote "Dash". The motion already happened on the client; this grants the invulnerability and
-- meters the cooldown (1 charge normally, 2 charges back-to-back while Speed Buff is active).
function CombatService.dash(player: Player)
	if paused() or player:GetAttribute("Grabbed") == true or isStunned(player) then
		return
	end
	local character = player.Character
	local root = rootOf(player)
	if not character or not root then
		return
	end
	local t = now()
	local maxCharges = Drops.maxDashCharges(player:GetAttribute("SpeedBuffUntil"), t)
	local state = dashStates[player] or { charges = maxCharges, rechargeAt = 0 }
	local allowed, nextCharges, nextRechargeAt =
		Drops.consumeDash(state.charges, state.rechargeAt, maxCharges, t, Config.DASH_COOLDOWN, COOLDOWN_SLACK)
	if not allowed then
		return
	end
	dashStates[player] = { charges = nextCharges, rechargeAt = nextRechargeAt }
	if player:GetAttribute("Blocking") == true then
		player:SetAttribute("Blocking", false)
		player:SetAttribute("ParryUntil", 0)
		refreshWalkSpeed(player)
	end
	cancelCharge(player)
	player:SetAttribute("DashCharges", nextCharges)
	player:SetAttribute("DashReadyAt", nextRechargeAt)
	character:SetAttribute("InvulnerableUntil", t + Config.DASH_IFRAMES)
	broadcastOthers(player, "playerDash", root.Position)
	broadcastAnimOthers(player, "dash")
end

-- Remote "Spin". Everything around the player, once per cooldown.
function CombatService.spin(player: Player)
	-- Only for a class that owns it: a client cannot fire another class's ability by remote.
	if not Classes.hasAbility(classIdOf(player), "spin") then
		return
	end
	if
		paused()
		or player:GetAttribute("Grabbed") == true
		or player:GetAttribute("Blocking") == true
		or player:GetAttribute("OverDriveCharging") == true
		or isStunned(player)
	then
		return
	end
	local root = rootOf(player)
	if not root then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute("SpinReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	cancelCharge(player)
	player:SetAttribute("SpinReadyAt", t + Config.SPIN_COOLDOWN)
	broadcastOthers(player, "playerSpin", root.Position)
	broadcastAnimOthers(player, "spin")
	local spinDamage = Config.SPIN_DAMAGE
		* Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), t, Config.BUFF_DAMAGE_MULTIPLIER)
	local hitAt: Vector3? = nil
	for _, enemy in ipairs(enemies.list()) do
		if Melee.inRadius(root.Position, enemy.body.Position, Config.SPIN_RADIUS + enemy.radius) then
			hitAt = hitAt or enemy.body.Position
			hitEnemy(player, enemy, spinDamage, root.Position)
		end
	end
	if hitAt then
		Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
	end
end

-- Remote "Stinger" (Slot 2): DMC-style piercing forward thrust hitting every enemy in the lunge corridor.
function CombatService.stinger(player: Player, aim: Vector3)
	-- Only for a class that owns it: a client cannot fire another class's ability by remote.
	if not Classes.hasAbility(classIdOf(player), "stinger") then
		return
	end
	if
		paused()
		or player:GetAttribute("Grabbed") == true
		or player:GetAttribute("Blocking") == true
		or player:GetAttribute("OverDriveCharging") == true
		or isStunned(player)
	then
		return
	end
	local root = rootOf(player)
	if not root then
		return
	end
	local facing = Melee.flat(aim) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute("StingerReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	cancelCharge(player)
	player:SetAttribute("StingerReadyAt", t + Config.STINGER_COOLDOWN)
	broadcastOthers(player, "playerDash", root.Position)
	broadcastOthers(player, "playerAttackHeavy", root.Position)
	broadcastAnimOthers(player, "stinger")
	Remotes.CombatVfx:FireAllClients("stinger", player, root.Position, facing)

	local damage = Config.STINGER_DAMAGE
		* Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), t, Config.BUFF_DAMAGE_MULTIPLIER)
	local halfWidth = Config.STINGER_WIDTH / 2
	local hitAt: Vector3? = nil
	for _, enemy in ipairs(enemies.list()) do
		if Melee.inCorridor(root.Position, facing, enemy.body.Position, Config.STINGER_DISTANCE, halfWidth + enemy.radius) then
			hitAt = hitAt or enemy.body.Position
			hitEnemy(player, enemy, damage, root.Position)
		end
	end
	if hitAt then
		Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
	end
end

-- Remote "OverDrive" (Slot 3, Ultimate): channels energy into the blade for OVERDRIVE_CHARGE_SECONDS,
-- then unleashes 3 devastating piercing crescent slash waves downrange.
function CombatService.overDrive(player: Player, aim: Vector3)
	-- Only for a class that owns it: a client cannot fire another class's ability by remote.
	if not Classes.hasAbility(classIdOf(player), "overdrive") then
		return
	end
	if
		paused()
		or player:GetAttribute("Grabbed") == true
		or player:GetAttribute("Blocking") == true
		or player:GetAttribute("OverDriveCharging") == true
		or isStunned(player)
	then
		return
	end
	local root = rootOf(player)
	if not root then
		return
	end
	local initialFacing = Melee.flat(aim) or Melee.flat(root.CFrame.LookVector)
	if not initialFacing then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute("OverDriveReadyAt") or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	cancelCharge(player)
	player:SetAttribute("OverDriveReadyAt", t + Config.OVERDRIVE_COOLDOWN)

	overDriveTokens[player] = (overDriveTokens[player] or 0) + 1
	local myToken = overDriveTokens[player]
	player:SetAttribute("OverDriveCharging", true)
	player:SetAttribute("OverDriveChargeStart", t)
	refreshWalkSpeed(player)
	Remotes.CombatSfx:FireAllClients("playerHeavyCharge", root.Position)
	Remotes.CombatVfx:FireAllClients("overdriveCharge", player, Config.OVERDRIVE_CHARGE_SECONDS)

	task.spawn(function()
		task.wait(Config.OVERDRIVE_CHARGE_SECONDS)
		if overDriveTokens[player] ~= myToken then
			return
		end
		if player:GetAttribute("Grabbed") == true or not rootOf(player) then
			cancelOverDrive(player)
			return
		end
		player:SetAttribute("OverDriveCharging", false)
		player:SetAttribute("OverDriveChargeStart", 0)
		refreshWalkSpeed(player)

		local waveCount = Config.OVERDRIVE_WAVES
		local halfWidth = Config.OVERDRIVE_WAVE_WIDTH / 2
		for wave = 1, waveCount do
			if overDriveTokens[player] ~= myToken or player:GetAttribute("Grabbed") == true then
				return
			end
			local waveRoot = rootOf(player)
			if not waveRoot then
				return
			end
			local waveFacing = Melee.flat(waveRoot.CFrame.LookVector) or initialFacing
			local baseDmg = Config.OVERDRIVE_WAVE_DAMAGE[wave] or Config.OVERDRIVE_WAVE_DAMAGE[#Config.OVERDRIVE_WAVE_DAMAGE] or 45
			local waveDmg = baseDmg
				* Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), now(), Config.BUFF_DAMAGE_MULTIPLIER)

			Remotes.CombatAnim:FireAllClients(player, "overdriveWave", wave)
			Remotes.CombatSfx:FireAllClients("playerHeavyAttack", waveRoot.Position, wave)
			Remotes.CombatVfx:FireAllClients("overdriveWave", waveRoot.Position, waveFacing, wave)

			local hitAt: Vector3? = nil
			for _, enemy in ipairs(enemies.list()) do
				if
					Melee.inCorridor(
						waveRoot.Position,
						waveFacing,
						enemy.body.Position,
						Config.OVERDRIVE_WAVE_RANGE,
						halfWidth + enemy.radius
					)
				then
					hitAt = hitAt or enemy.body.Position
					hitEnemy(player, enemy, waveDmg, waveRoot.Position)
				end
			end
			if hitAt then
				Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
			end
			if wave < waveCount then
				task.wait(Config.OVERDRIVE_WAVE_INTERVAL)
			end
		end
	end)
end

--=============================================================================
-- Class abilities (plans/gdd/systems.md, "Clases")
--=============================================================================

-- Every living player within `radius` of `position`, the caster included.
local function playersNear(position: Vector3, radius: number): { { player: Player, humanoid: Humanoid } }
	local found = {}
	for _, other in ipairs(Players:GetPlayers()) do
		local root = rootOf(other)
		local humanoid = other.Character and other.Character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and Melee.inRadius(position, root.Position, radius) then
			table.insert(found, { player = other, humanoid = humanoid })
		end
	end
	return found
end

local function heal(humanoid: Humanoid, amount: number)
	if humanoid.Health > 0 then
		humanoid.Health = math.min(humanoid.Health + amount, humanoid.MaxHealth)
	end
end

local function buffed(player: Player, base: number, t: number): number
	return base * Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), t, Config.BUFF_DAMAGE_MULTIPLIER)
end

-- Each handler runs once the shared checks (class owns it, not grabbed/stunned/blocking, off
-- cooldown) have passed and the cooldown has started.
local ABILITY_HANDLERS: { [string]: (Player, BasePart, Vector3, number) -> () } = {
	-- Tank: deafening war cry that stuns every enemy in radius, interrupts windups/grabs, and draws aggro.
	taunt = function(player, root, _facing, t)
		local tauntUntil = t + Config.TAUNT_DURATION
		local shockDamage = buffed(player, Config.TAUNT_DAMAGE, t)
		local hitAt: Vector3? = nil
		for _, enemy in ipairs(enemies.list()) do
			if Melee.inRadius(root.Position, enemy.body.Position, Config.TAUNT_RADIUS + enemy.radius) then
				hitAt = hitAt or enemy.body.Position
				enemies.stun(enemy, Config.TAUNT_STUN_DURATION)
				enemies.taunt(enemy, player, tauntUntil)
				hitEnemy(player, enemy, shockDamage, root.Position)
			end
		end
		Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", root.Position)
		Remotes.CombatSfx:FireAllClients("enemyExploderBlast", root.Position)
		Remotes.CombatVfx:FireAllClients("taunt", player, Config.TAUNT_RADIUS)
		if hitAt then
			Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
		end
	end,

	-- Tank: personal armored self-buff cutting ALL incoming damage by 75% (see `classReduction`).
	bulwark = function(player, root, _facing, t)
		player:SetAttribute("BulwarkUntil", t + Config.BULWARK_DURATION)
		Remotes.CombatSfx:FireAllClients("dropBuff", root.Position)
		Remotes.CombatVfx:FireAllClients("bulwark", player, Config.BULWARK_DURATION)
	end,

	-- Damage: throws twin spinning boomerang daggers forward that pierce enemies and curve back to the caster.
	execute = function(player, root, facing, t)
		local startPos = Vector3.new(root.Position.X, 2.4, root.Position.Z)
		local clamped = Waves.clamp(startPos + facing * Config.BOOMERANG_RANGE, Config.ROOM_SIZE, 2)
		local apexPos = Vector3.new(clamped.X, 2.4, clamped.Z)
		table.insert(boomerangs, {
			owner = player,
			startPos = startPos,
			apexPos = apexPos,
			startedAt = t,
			outSeconds = Config.BOOMERANG_OUT_SECONDS,
			returnSeconds = Config.BOOMERANG_RETURN_SECONDS,
			outDamage = buffed(player, Config.BOOMERANG_OUT_DAMAGE, t),
			returnDamage = buffed(player, Config.BOOMERANG_RETURN_DAMAGE, t),
			hitOut = {},
			hitBack = {},
		})
		broadcastOthers(player, "playerAttackHeavy", root.Position)
		broadcastAnimOthers(player, "attack", Config.COMBO_HITS)
		Remotes.CombatVfx:FireAllClients("boomerang", player, startPos, apexPos)
	end,

	-- Support: drops a persistent 10 s healing zone on the floor that steadily heals every player passing through.
	healPulse = function(_player, root, _facing, t)
		local floorPoint = Vector3.new(root.Position.X, 0, root.Position.Z)
		for _, entry in ipairs(playersNear(floorPoint, Config.HEAL_ZONE_RADIUS)) do
			heal(entry.humanoid, Config.HEAL_ZONE_INITIAL_BURST)
		end
		table.insert(healZones, {
			position = floorPoint,
			radius = Config.HEAL_ZONE_RADIUS,
			untilAt = t + Config.HEAL_ZONE_DURATION,
			nextTickAt = t + Config.HEAL_ZONE_TICK_SECONDS,
		})
		Remotes.CombatSfx:FireAllClients("dropHeal", root.Position)
		Remotes.CombatVfx:FireAllClients("healZone", floorPoint, Config.HEAL_ZONE_RADIUS, Config.HEAL_ZONE_DURATION)
	end,

	-- Support: grants a team-wide defense buff to EVERY living player in the squad (see `classReduction`).
	protectField = function(_player, root, _facing, t)
		local untilAt = t + Config.PROTECT_BUFF_DURATION
		for _, other in ipairs(Players:GetPlayers()) do
			if rootOf(other) then
				local current = other:GetAttribute("ProtectBuffUntil")
				if type(current) ~= "number" or untilAt > current then
					other:SetAttribute("ProtectBuffUntil", untilAt)
				end
			end
		end
		Remotes.CombatSfx:FireAllClients("dropBuff", root.Position)
		Remotes.CombatVfx:FireAllClients("protectBuff", Config.PROTECT_BUFF_DURATION)
	end,

	-- Support: expanding shockwave that damages, shoves away, and hard-stuns every enemy around the caster.
	shockwave = function(player, root, _facing, t)
		local damage = buffed(player, Config.SHOCKWAVE_DAMAGE, t)
		local hitAt: Vector3? = nil
		for _, enemy in ipairs(enemies.list()) do
			if Melee.inRadius(root.Position, enemy.body.Position, Config.SHOCKWAVE_RADIUS + enemy.radius) then
				hitAt = hitAt or enemy.body.Position
				hitEnemy(player, enemy, damage, root.Position)
				local away = Melee.flat(enemy.body.Position - root.Position) or Melee.flat(root.CFrame.LookVector)
				if away then
					enemies.shove(
						enemy,
						away,
						Config.SHOCKWAVE_PUSH_DISTANCE,
						Config.SHOCKWAVE_PUSH_SECONDS,
						Config.SHOCKWAVE_SLOW_FACTOR,
						t + Config.SHOCKWAVE_SLOW_SECONDS
					)
				end
				enemies.stun(enemy, Config.SHOCKWAVE_STUN_DURATION)
			end
		end
		Remotes.CombatSfx:FireAllClients("enemyExploderBlast", root.Position)
		Remotes.CombatVfx:FireAllClients("shockwave", root.Position, Config.SHOCKWAVE_RADIUS)
		if hitAt then
			Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
		end
	end,
}

-- Remote "UseAbility": every class ability added with the classes. The contract checked the shapes;
-- this checks the class owns it and that it is off cooldown, then runs it.
function CombatService.useAbility(player: Player, abilityId: string, aim: Vector3)
	local handler = ABILITY_HANDLERS[abilityId]
	local ability = Config.ABILITIES[abilityId]
	if not handler or not ability or not Classes.hasAbility(classIdOf(player), abilityId) then
		return
	end
	if
		paused()
		or player:GetAttribute("Grabbed") == true
		or player:GetAttribute("Blocking") == true
		or player:GetAttribute("OverDriveCharging") == true
		or isStunned(player)
	then
		return
	end
	local root = rootOf(player)
	if not root then
		return
	end
	local facing = Melee.flat(aim) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end
	local t = now()
	local readyAt = player:GetAttribute(ability.readyAttribute) or 0
	if t < readyAt - COOLDOWN_SLACK then
		return
	end
	cancelCharge(player)
	player:SetAttribute(ability.readyAttribute, t + ability.cooldown)
	handler(player, root, facing, t)
end

-- Steps server-authoritative Support bolts/heavy orbs, Damage boomerang daggers, and persistent
-- 10 s healing zones every Heartbeat.
local function stepCombat(dt: number)
	if paused() then
		return
	end
	local t = now()
	local enemyList = enemies.list()

	-- 1. Support basic energy bolts & explosive arcane heavy orbs.
	for i = #playerBolts, 1, -1 do
		local bolt = playerBolts[i]
		local nextPos = bolt.position + bolt.velocity * dt
		bolt.position = nextPos
		local expired = t >= bolt.expiresAt
		if not expired then
			local inside = Waves.clamp(nextPos, Config.ROOM_SIZE, 0)
			expired = inside.X ~= nextPos.X or inside.Z ~= nextPos.Z
		end

		local hitEnemyTarget: Enemy? = nil
		if not expired then
			for _, enemy in ipairs(enemyList) do
				if not enemy.dead and Melee.inRadius(nextPos, enemy.body.Position, bolt.radius + enemy.radius) then
					hitEnemyTarget = enemy
					break
				end
			end
		end

		if hitEnemyTarget or expired then
			local impactPos = if hitEnemyTarget then hitEnemyTarget.body.Position else nextPos
			if bolt.splashRadius > 0 and (hitEnemyTarget or bolt.kind == "supportHeavy") then
				local anyHit = false
				for _, enemy in ipairs(enemyList) do
					if not enemy.dead and Melee.inRadius(impactPos, enemy.body.Position, bolt.splashRadius + enemy.radius) then
						anyHit = true
						hitEnemy(bolt.owner, enemy, bolt.damage, impactPos)
						if bolt.stunDuration > 0 then
							enemies.stun(enemy, bolt.stunDuration)
						end
					end
				end
				if bolt.kind == "supportHeavy" then
					Remotes.CombatSfx:FireAllClients("enemyExploderBlast", impactPos)
				end
				if anyHit then
					Remotes.CombatSfx:FireAllClients("playerHit", impactPos)
				end
			elseif hitEnemyTarget then
				hitEnemy(bolt.owner, hitEnemyTarget, bolt.damage, nextPos)
				Remotes.CombatSfx:FireAllClients("playerHit", impactPos)
			end
			Remotes.CombatVfx:FireAllClients("boltImpact", bolt.id, impactPos, bolt.kind, bolt.splashRadius)
			table.remove(playerBolts, i)
		end
	end

	-- 2. Damage Boomerang Daggers (outbound slice + live-homing return slice).
	for i = #boomerangs, 1, -1 do
		local b = boomerangs[i]
		local elapsed = t - b.startedAt
		local progress: number
		local returning = false
		if elapsed <= b.outSeconds then
			progress = elapsed / math.max(b.outSeconds, 0.05)
		else
			returning = true
			progress = 1 + (elapsed - b.outSeconds) / math.max(b.returnSeconds, 0.05)
		end
		if progress >= 2 or not b.owner.Parent then
			table.remove(boomerangs, i)
			continue
		end
		local casterRoot = rootOf(b.owner)
		local casterPos = if casterRoot
			then Vector3.new(casterRoot.Position.X, 2.4, casterRoot.Position.Z)
			else b.startPos
		local pos = Classes.boomerangPosition(b.startPos, b.apexPos, casterPos, progress)
		local hitSet = if returning then b.hitBack else b.hitOut
		local baseDmg = if returning then b.returnDamage else b.outDamage
		for _, enemy in ipairs(enemyList) do
			if not enemy.dead and not hitSet[enemy] and Melee.inRadius(pos, enemy.body.Position, Config.BOOMERANG_HIT_RADIUS + enemy.radius) then
				hitSet[enemy] = true
				local spec = enemy.spec or {}
				hitEnemy(b.owner, enemy, Classes.executeDamage(baseDmg, enemy.health, spec.health or 1), pos)
				Remotes.CombatSfx:FireAllClients("playerHit", enemy.body.Position)
			end
		end
	end

	-- 3. Persistent 10 s Support healing zones.
	for i = #healZones, 1, -1 do
		local zone = healZones[i]
		if t >= zone.untilAt then
			table.remove(healZones, i)
		elseif t >= zone.nextTickAt then
			zone.nextTickAt += Config.HEAL_ZONE_TICK_SECONDS
			local healTick = Config.HEAL_ZONE_HEAL_PER_SECOND * Config.HEAL_ZONE_TICK_SECONDS
			for _, entry in ipairs(playersNear(zone.position, zone.radius)) do
				heal(entry.humanoid, healTick)
			end
		end
	end
end

-- The Support's passive regeneration aura on a 1-second tick so it stays off every frame.
local function supportTick()
	for _, player in ipairs(Players:GetPlayers()) do
		if classIdOf(player) == "support" then
			local root = rootOf(player)
			if root then
				for _, entry in ipairs(playersNear(root.Position, Config.SUPPORT_REGEN_RADIUS)) do
					heal(entry.humanoid, Config.SUPPORT_REGEN_PER_SECOND)
				end
			end
		end
	end
end

-- Started from the server bootstrap after `start`.
function CombatService.startSupportTick()
	RunService.Heartbeat:Connect(stepCombat)
	task.spawn(function()
		while true do
			task.wait(1)
			supportTick()
		end
	end)
end

return CombatService
