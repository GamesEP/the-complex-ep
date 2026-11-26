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
local Defense = require(Shared.features.combat.Defense)
local Drops = require(Shared.features.drops.Drops)
local Melee = require(Shared.features.combat.Melee)
local Classes = require(Shared.features.classes.Classes)

local CombatService = {}

-- A client one frame ahead of the server's clock is not cheating. Cooldowns are checked against
-- this much slack, so a dash pressed the instant the HUD says "ready" is never silently refused.
local COOLDOWN_SLACK = 0.1

type Enemy = { body: BasePart, radius: number, health: number, spec: any, state: any }
type Enemies = {
	list: () -> { Enemy },
	damage: (Enemy, number) -> (),
	taunt: (Enemy, Player, number) -> (),
	shove: (Enemy, Vector3, number, number, number, number) -> (),
}

local enemies: Enemies = nil :: any

-- Per player, server-only: the combo and heavy-charge clocks are judged on the server's own
-- `os.clock()`, which a client cannot move. Forgotten in `forget`, from PlayerRemoving.
local swings: { [Player]: { step: number, lastAt: number } } = {}
local heavyCharges: { [Player]: number } = {}
local overDriveTokens: { [Player]: number } = {}
local dashStates: { [Player]: { charges: number, rechargeAt: number } } = {}

-- Active Support protect fields. Server-only: what they *look* like is a CombatVfx broadcast.
local protectFields: { { position: Vector3, radius: number, untilAt: number } } = {}

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
function CombatService.start(dependencies: { enemies: any })
	enemies = dependencies.enemies :: Enemies
	Players.RespawnTime = Config.RESPAWN_SECONDS
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
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

-- How much of a hit survives the class and the Support's protect field: the Tank's passive and a
-- player standing in a field each cut it, and they stack.
local function classReduction(player: Player, position: Vector3?, t: number): number
	local multiplier = Classes.incomingMultiplier(classIdOf(player))
	if position then
		for _, field in ipairs(protectFields) do
			if t < field.untilAt and Melee.inRadius(field.position, position, field.radius) then
				multiplier *= 1 - Config.PROTECT_FIELD_REDUCTION
				break
			end
		end
	end
	return multiplier
end

-- Every hit a player lands goes through here: the class multiplier, and the Damage passive when
-- the enemy is recovering from its own attack (its stun window) or is hit from behind.
local function hitEnemy(player: Player, enemy: Enemy, damage: number, from: Vector3)
	local vulnerable = (enemy.state and enemy.state.phase == "recover")
		or Classes.isBehind(enemy.body.Position, enemy.body.CFrame.LookVector, from, Config.DPS_BACKSTAB_FRONT_ARC)
	enemies.damage(enemy, damage * Classes.outgoingMultiplier(classIdOf(player), vulnerable))
end

-- Whether a hit from `origin` lands on the Tank's raised Muralla: inside its frontal arc.
local function stoppedByBulwark(player: Player, root: BasePart?, origin: Vector3?, t: number): boolean
	local untilAt = player:GetAttribute("BulwarkUntil")
	if not root or not origin or type(untilAt) ~= "number" or t >= untilAt then
		return false
	end
	local facing = Melee.flat(root.CFrame.LookVector)
	return facing ~= nil and Melee.inArc(root.Position, facing, origin, math.huge, Config.BULWARK_ARC)
end

-- The one way anything hurts a player. Returns `(hitLanded, outcome)` so projectiles pass
-- through a dashing player ("invulnerable") and reflect back on a perfect "parry".
--
-- `origin` is where the hit came from, for the attacks the Tank's Muralla can stop (shots and
-- beams); a hit without one is never stopped by it.
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
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local rootBase = if rootPart and rootPart:IsA("BasePart") then rootPart else nil
	amount *= classReduction(player, if rootBase then rootBase.Position else nil, t)
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

	-- After the dodge check (a dash still passes through), before a parry: the shield takes it.
	-- Reported as a landed block so a projectile is stopped by the shield instead of flying on.
	if outcome ~= "parry" and stoppedByBulwark(player, rootBase, options and options.origin, t) then
		if rootBase then
			Remotes.CombatSfx:FireAllClients("playerBlock", rootBase.Position)
		end
		return true, "block"
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

	if player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player, t) then
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
	if player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player) then
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

-- Remote "HeavyAttack": unleashes the wide crushing cleave once the server confirms the full
-- full HEAVY_CHARGE_SECONDS hold completed.
function CombatService.heavyAttack(player: Player, aim: Vector3)
	if player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player) then
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
	player:SetAttribute("HeavyReadyAt", t + Config.HEAVY_ATTACK_COOLDOWN)
	swings[player] = { step = 0, lastAt = os.clock() }

	local damage = Config.HEAVY_ATTACK_DAMAGE
		* Drops.damageMultiplier(player:GetAttribute("DamageBuffUntil"), t, Config.BUFF_DAMAGE_MULTIPLIER)
	broadcastOthers(player, "playerHeavyAttack", root.Position)
	broadcastAnimOthers(player, "heavyAttack")

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
	if hitAt then
		Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
	end
end

-- Remote "Attack". `aim` is shape-checked by the contract; what it *means* is decided here. The
-- client sends its aim rather than the server reading the character's facing, because the facing
-- the server has is a physics update behind the remote that announced the swing.
function CombatService.attack(player: Player, aim: Vector3)
	if player:GetAttribute("Grabbed") == true or player:GetAttribute("Blocking") == true or isStunned(player) then
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
	if player:GetAttribute("Grabbed") == true or isStunned(player) then
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
		player:GetAttribute("Grabbed") == true
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
		player:GetAttribute("Grabbed") == true
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
		player:GetAttribute("Grabbed") == true
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
	-- Tank: every enemy in reach targets the tank for a few seconds.
	taunt = function(player, root, _facing, t)
		local untilAt = t + Config.TAUNT_DURATION
		for _, enemy in ipairs(enemies.list()) do
			if Melee.inRadius(root.Position, enemy.body.Position, Config.TAUNT_RADIUS + enemy.radius) then
				enemies.taunt(enemy, player, untilAt)
			end
		end
		Remotes.CombatSfx:FireAllClients("enemyGrabberWindup", root.Position)
		Remotes.CombatVfx:FireAllClients("taunt", player, Config.TAUNT_RADIUS)
	end,

	-- Tank: a frontal shield that stops shots and beams from in front (see `stoppedByBulwark`).
	bulwark = function(player, root, _facing, t)
		player:SetAttribute("BulwarkUntil", t + Config.BULWARK_DURATION)
		Remotes.CombatSfx:FireAllClients("playerBlock", root.Position)
		Remotes.CombatVfx:FireAllClients("bulwark", player, Config.BULWARK_DURATION)
	end,

	-- Damage: a frontal strike that triples against an enemy already low on health.
	execute = function(player, root, facing, t)
		local base = buffed(player, Config.EXECUTE_DAMAGE, t)
		local hitAt: Vector3? = nil
		for _, enemy in ipairs(enemies.list()) do
			if Melee.inArc(root.Position, facing, enemy.body.Position, Config.EXECUTE_RANGE + enemy.radius, Config.EXECUTE_ARC) then
				hitAt = hitAt or enemy.body.Position
				local spec = enemy.spec or {}
				hitEnemy(player, enemy, Classes.executeDamage(base, enemy.health, spec.health or 1), root.Position)
			end
		end
		broadcastOthers(player, "playerHeavyAttack", root.Position)
		broadcastAnimOthers(player, "attack", Config.COMBO_HITS)
		Remotes.CombatVfx:FireAllClients("execute", root.Position, facing)
		if hitAt then
			Remotes.CombatSfx:FireAllClients("playerHit", hitAt)
		end
	end,

	-- Support: heals every living player in the radius, the caster included.
	healPulse = function(_player, root, _facing, _t)
		for _, entry in ipairs(playersNear(root.Position, Config.HEAL_PULSE_RADIUS)) do
			heal(entry.humanoid, Config.HEAL_PULSE_AMOUNT)
		end
		Remotes.CombatSfx:FireAllClients("dropHeal", root.Position)
		Remotes.CombatVfx:FireAllClients("healPulse", root.Position, Config.HEAL_PULSE_RADIUS)
	end,

	-- Support: a zone on the floor where every hit is cut (see `classReduction`).
	protectField = function(_player, root, _facing, t)
		local floorPoint = Vector3.new(root.Position.X, 0, root.Position.Z)
		table.insert(protectFields, {
			position = floorPoint,
			radius = Config.PROTECT_FIELD_RADIUS,
			untilAt = t + Config.PROTECT_FIELD_DURATION,
		})
		Remotes.CombatSfx:FireAllClients("dropBuff", root.Position)
		Remotes.CombatVfx:FireAllClients("protectField", floorPoint, Config.PROTECT_FIELD_RADIUS, Config.PROTECT_FIELD_DURATION)
	end,

	-- Support: hurts, pushes away and slows every enemy around the caster.
	shockwave = function(player, root, _facing, t)
		local damage = buffed(player, Config.SHOCKWAVE_DAMAGE, t)
		for _, enemy in ipairs(enemies.list()) do
			if Melee.inRadius(root.Position, enemy.body.Position, Config.SHOCKWAVE_RADIUS + enemy.radius) then
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
			end
		end
		Remotes.CombatSfx:FireAllClients("enemyExploderBlast", root.Position)
		Remotes.CombatVfx:FireAllClients("shockwave", root.Position, Config.SHOCKWAVE_RADIUS)
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
		player:GetAttribute("Grabbed") == true
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

-- The Support's passive and the protect fields' expiry, on one slow tick: once a second is plenty
-- for a regeneration and keeps it off every frame.
local function supportTick()
	local t = now()
	for i = #protectFields, 1, -1 do
		if t >= protectFields[i].untilAt then
			table.remove(protectFields, i)
		end
	end
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
	task.spawn(function()
		while true do
			task.wait(1)
			supportTick()
		end
	end)
end

return CombatService
