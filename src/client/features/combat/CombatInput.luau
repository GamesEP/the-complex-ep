--[[
	The player's kit on every input: attack, dash and spin, on mouse and keyboard, touch and
	gamepad (plans/gdd/technical.md: no control may exist on only one of them).

	ContextActionService rather than raw input events, because one binding covers all three:
	`createTouchButton` draws the on-screen button on a phone, and the same action fires from a
	key, a mouse button and a gamepad button. Moving and jumping are Roblox's own controls.

	Each action is predicted here and confirmed by the server: the swing is drawn and the dash
	moves the character the moment the button goes down, and the server decides what it hit and
	whether the cooldown allowed it. See docs/combat.md.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local Drops = require(Shared.features.drops.Drops)
local Melee = require(Shared.features.combat.Melee)
local Classes = require(Shared.features.classes.Classes)
local Waves = require(Shared.features.enemies.Waves)

local Effects = require(script.Parent.Effects)
local AbilityStore = require(script.Parent.stores.AbilityStore)

local CombatInput = {}

local player = Players.LocalPlayer

-- Predicted, in server time so they compare directly with the attributes the server writes.
-- The local value stops a double press from firing twice before the attribute replicates.
local comboStep = 0
local lastSwingAt = -math.huge
local dashCharges = 1
local dashRechargeAt = 0
local lastDashAt = -math.huge
type ActiveMove = {
	velocity: LinearVelocity,
	attachment: Attachment,
	root: BasePart,
	direction: Vector3,
	speed: number,
}

local activeDash: ActiveMove? = nil
local dashToken = 0
local spinReadyAt = 0
local stingerReadyAt = 0
local overDriveReadyAt = 0
-- Predicted ready times for the class abilities that came with the classes, by ability id.
local classAbilityReadyAt: { [string]: number } = {}
local blockReadyAt = 0
local heavyReadyAt = 0
local blocking = false
local attackHeld = false
local chargingHeavy = false
local chargeToken = 0

-- Active attack lunge state; gated on `lungeToken` so a dash or respawn cancels any in-flight
-- step-in cleanly without firing a stale swing.
local lungeToken = 0
local activeLunge: ActiveMove? = nil
local dashEndsAt = 0

-- Sticky target picked by the first basic attack or ability in a combo. Tracked with its own
-- `lastEngageAt` clock (separate from `lastSwingAt`) so an ability can seed or refresh the lock
-- without altering the server-synced combo step window.
local lockedTarget: BasePart? = nil
local lastEngageAt = -math.huge

-- Builds RaycastParams that hit only solid world geometry (`RespectCanCollide = true` skips
-- enemies, drops, floor plates, and VFX) while excluding all player characters.
local function wallCastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local excluded: { Instance } = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(excluded, p.Character)
		end
	end
	params.FilterDescendantsInstances = excluded
	return params
end

-- True when a solid wall, pillar, cover bunker, or prop lies within `distance` studs ahead.
-- Ignores near-horizontal floor normals (`|Normal.Y| >= 0.65`).
local function hitsWallAhead(root: BasePart, direction: Vector3, distance: number): boolean
	local params = wallCastParams()
	local sphere = workspace:Spherecast(root.Position, 1.05, direction * distance, params)
	if sphere and math.abs(sphere.Normal.Y) < 0.65 then
		return true
	end
	local ray = workspace:Raycast(root.Position, direction * (distance + 0.9), params)
	if ray and math.abs(ray.Normal.Y) < 0.65 then
		return true
	end
	return false
end

-- Stops residual horizontal velocity and suppresses any upward wall-impact rebound impulse.
local function dampenAfterMove(root: BasePart, hardStop: boolean)
	if not root.Parent then
		return
	end
	local vel = root.AssemblyLinearVelocity
	local y = if hardStop then math.min(vel.Y, 0) else math.min(vel.Y, 4)
	if hardStop then
		root.AssemblyLinearVelocity = Vector3.new(0, y, 0)
	else
		local horiz = Vector3.new(vel.X, 0, vel.Z)
		local maxCarry = Config.MOVE_SPEED * 1.15
		if horiz.Magnitude > maxCarry then
			horiz = horiz.Unit * maxCarry
		end
		root.AssemblyLinearVelocity = Vector3.new(horiz.X, y, horiz.Z)
	end
end

-- Creates a bounded-force horizontal LinearVelocity (never `math.huge`, which causes Roblox's
-- solver to fling characters vertically out of the arena on wall/corner contact). Returns nil
-- if already flush against a solid obstacle in `direction`.
local function startSafeVelocity(root: BasePart, direction: Vector3, speed: number): ActiveMove?
	if hitsWallAhead(root, direction, 1.4) then
		dampenAfterMove(root, true)
		return nil
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	velocity.LineDirection = direction
	velocity.LineVelocity = speed
	velocity.MaxForce = math.max(root.AssemblyMass * 2200, 30000)
	velocity.Parent = root
	return {
		velocity = velocity,
		attachment = attachment,
		root = root,
		direction = direction,
		speed = speed,
	}
end

local function clearLunge(hardStop: boolean?)
	if activeLunge then
		local moveRoot = activeLunge.root
		activeLunge.velocity:Destroy()
		activeLunge.attachment:Destroy()
		activeLunge = nil
		dampenAfterMove(moveRoot, hardStop == true)
	end
end

local function cancelHeavyCharge(notifyServer: boolean)
	chargeToken += 1
	attackHeld = false
	if chargingHeavy then
		chargingHeavy = false
		Effects.stopCharge()
		if notifyServer then
			Remotes.HeavyCharge:FireServer(false)
		end
	elseif notifyServer and player:GetAttribute("ChargingHeavy") == true then
		Effects.stopCharge()
		Remotes.HeavyCharge:FireServer(false)
	end
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function isStunned(): boolean
	local stunnedUntil = player:GetAttribute("StunnedUntil")
	return type(stunnedUntil) == "number" and now() < stunnedUntil
end

local function classId(): string?
	local current = player:GetAttribute("Class")
	return if type(current) == "string" and current ~= "" then current else nil
end

-- Matches ClassService.isPaused(): blocks combat inputs while this player or any teammate is still
-- on the class selection screen so nobody attacks frozen enemies or casts before picking a class.
local function isChoosingClass(): boolean
	if not classId() then
		return true
	end
	for _, other in ipairs(Players:GetPlayers()) do
		local c = other:GetAttribute("Class")
		if type(c) ~= "string" or c == "" then
			return true
		end
	end
	return false
end

-- True when a desktop mouse click lands on an active GuiButton (e.g. ability actuator or menu
-- button) so clicking UI never also fires a basic attack or starts charging a heavy attack.
local function pointerOverGuiButton(input: InputObject?): boolean
	if not input or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return false
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	for _, guiObj in ipairs(playerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y)) do
		if guiObj:IsA("GuiButton") and guiObj.Visible and guiObj.Active then
			return true
		end
	end
	return false
end

local function body(): (BasePart?, Humanoid?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or humanoid.Health <= 0 or not root then
		return nil, nil
	end
	return root, humanoid
end

local function ready(predicted: number, attribute: string): boolean
	local t = now()
	local confirmed = player:GetAttribute(attribute)
	return t >= predicted and (type(confirmed) ~= "number" or t >= confirmed)
end

-- Snapshots every living enemy body in `World.Enemies` as flat targets for `Melee.pickTarget`.
local function enemyTargets(): ({ Melee.Target }, { BasePart })
	local targets: { Melee.Target } = {}
	local bodies: { BasePart } = {}
	local world = workspace:FindFirstChild("World")
	local enemies = world and world:FindFirstChild("Enemies")
	if not enemies then
		return targets, bodies
	end
	for _, model in ipairs(enemies:GetChildren()) do
		local enemyBody = model:FindFirstChild("Body")
		if enemyBody and enemyBody:IsA("BasePart") then
			local radius = math.max(enemyBody.Size.X, enemyBody.Size.Z) / 2
			table.insert(targets, { position = enemyBody.Position, radius = radius })
			table.insert(bodies, enemyBody)
		end
	end
	return targets, bodies
end

-- Resolves the attack/ability target: keeps `lockedTarget` while continuing a combo and still
-- heading toward it, otherwise picks the best enemy in the forward cone.
local function selectTarget(root: BasePart, facing: Vector3, clock: number): (Melee.TargetPick?, BasePart?)
	local targets, bodies = enemyTargets()
	local preferredIndex: number? = nil
	if lockedTarget and clock - lastEngageAt <= Config.COMBO_WINDOW and lockedTarget:IsDescendantOf(workspace) then
		preferredIndex = table.find(bodies, lockedTarget)
	end
	local assistRange = if Classes.isRanged(classId()) then Config.STAFF_AIM_ASSIST_RANGE else Config.AIM_ASSIST_RANGE
	local pick = Melee.pickTarget(
		root.Position,
		facing,
		targets,
		assistRange,
		Config.AIM_ASSIST_CONE,
		Config.AIM_ASSIST_ANGLE_WEIGHT,
		preferredIndex,
		Config.TARGET_LOCK_CONE
	)
	local targetBody: BasePart? = if pick then bodies[pick.index] else nil
	return pick, targetBody
end

local function attack()
	if isChoosingClass() then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid then
		return
	end
	-- While held by a grabber, every Attack press (click / X / R2 / touch button) feeds the
	-- escape struggle instead of launching a melee swing.
	if player:GetAttribute("Grabbed") == true then
		lungeToken += 1
		clearLunge()
		Effects.attackWindup(1)
		Remotes.GrabEscape:FireServer()
		return
	end
	if blocking or player:GetAttribute("Blocking") == true or isStunned() then
		return
	end
	local clock = os.clock()
	if clock - lastSwingAt < Config.ATTACK_INTERVAL then
		return
	end

	-- Every input device (mouse, gamepad, touch) swings along where the character is moving or
	-- looking, snapping onto the enemy best aligned inside the forward cone.
	local facing = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end

	local pick, targetBody = selectTarget(root, facing, clock)
	local aim = if pick then pick.direction else facing
	local ranged = Classes.isRanged(classId())

	local lungeDist = 0
	if not ranged and pick and clock >= dashEndsAt then
		lungeDist = Melee.lungeDistance(
			pick.distance,
			pick.radius,
			Config.ATTACK_LUNGE_STOP_DISTANCE,
			Config.ATTACK_LUNGE_MAX_DISTANCE
		)
	end
	local lungeDuration = if lungeDist > 0 and Config.ATTACK_LUNGE_SPEED > 0
		then lungeDist / Config.ATTACK_LUNGE_SPEED
		else 0

	comboStep = Melee.nextStep(comboStep, lastSwingAt, clock, Config.COMBO_HITS, Config.COMBO_WINDOW)
	local step = comboStep
	-- Anchor the swing clock to when the remote fires (after any lunge), so the server's interval
	-- gate never drops the next combo hit and another press cannot start mid-lunge.
	lastSwingAt = clock + lungeDuration
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock + lungeDuration else -math.huge
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)

	if lungeDuration > 0 then
		lungeToken += 1
		local myToken = lungeToken
		clearLunge()

		-- Horizontal-only bounded-force velocity: stops cleanly on walls/pillars without flinging.
		activeLunge = startSafeVelocity(root, aim, Config.ATTACK_LUNGE_SPEED)

		-- Play the attack windup immediately during the step-in, then draw the slash and notify
		-- the server once the lunge has closed the gap.
		Effects.attackWindup(step)
		task.delay(lungeDuration, function()
			if lungeToken ~= myToken then
				return
			end
			clearLunge()
			local currentRoot = body()
			if currentRoot ~= root then
				return
			end
			local finalAim = aim
			-- IsDescendantOf(workspace) rather than .Parent: server Destroy() leaves client child
			-- pointers intact (see docs/roblox-gotchas.md).
			if targetBody and targetBody:IsDescendantOf(workspace) then
				finalAim = Melee.flat(targetBody.Position - root.Position) or aim
			end
			root.CFrame = CFrame.lookAt(root.Position, root.Position + finalAim)
			Effects.slash(root, finalAim, step, true)
			Remotes.Attack:FireServer(finalAim)
		end)
	elseif ranged then
		Effects.staffAttack(root, aim, step)
		Remotes.Attack:FireServer(aim)
	else
		Effects.slash(root, aim, step)
		Remotes.Attack:FireServer(aim)
	end
end

local function releaseHeavyAttack()
	chargingHeavy = false
	attackHeld = false
	chargeToken += 1
	Effects.stopCharge()

	if player:GetAttribute("Grabbed") == true or blocking or player:GetAttribute("Blocking") == true then
		Remotes.HeavyCharge:FireServer(false)
		return
	end
	local root, humanoid = body()
	if not root or not humanoid then
		Remotes.HeavyCharge:FireServer(false)
		return
	end

	local clock = os.clock()
	local facing = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		Remotes.HeavyCharge:FireServer(false)
		return
	end

	local pick, targetBody = selectTarget(root, facing, clock)
	local aim = if pick then pick.direction else facing
	local currentClass = classId()
	local ranged = Classes.isRanged(currentClass)

	local lungeDist = 0
	if not ranged and pick and clock >= dashEndsAt then
		lungeDist = Melee.lungeDistance(
			pick.distance,
			pick.radius,
			Config.ATTACK_LUNGE_STOP_DISTANCE,
			Config.HEAVY_ATTACK_LUNGE_MAX_DISTANCE
		)
	end
	local lungeDuration = if lungeDist > 0 and Config.ATTACK_LUNGE_SPEED > 0
		then lungeDist / Config.ATTACK_LUNGE_SPEED
		else 0

	comboStep = 0
	lastSwingAt = clock + lungeDuration
	heavyReadyAt = now() + Config.HEAVY_ATTACK_COOLDOWN
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock + lungeDuration else -math.huge
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)

	if lungeDuration > 0 then
		lungeToken += 1
		local myToken = lungeToken
		clearLunge()

		activeLunge = startSafeVelocity(root, aim, Config.ATTACK_LUNGE_SPEED)

		task.delay(lungeDuration, function()
			if lungeToken ~= myToken then
				return
			end
			clearLunge()
			local currentRoot = body()
			if currentRoot ~= root then
				return
			end
			local finalAim = aim
			if targetBody and targetBody:IsDescendantOf(workspace) then
				finalAim = Melee.flat(targetBody.Position - root.Position) or aim
			end
			root.CFrame = CFrame.lookAt(root.Position, root.Position + finalAim)
			Effects.heavyAttack(root, finalAim, currentClass, true)
			Remotes.HeavyAttack:FireServer(finalAim)
		end)
	else
		Effects.heavyAttack(root, aim, currentClass, true)
		Remotes.HeavyAttack:FireServer(aim)
	end
end

local function beginAttackHold()
	if attackHeld or isChoosingClass() then
		return
	end
	attack()
	if player:GetAttribute("Grabbed") == true or blocking or player:GetAttribute("Blocking") == true then
		return
	end
	if not ready(heavyReadyAt, "HeavyReadyAt") then
		return
	end
	local root = body()
	if not root then
		return
	end

	chargeToken += 1
	local myToken = chargeToken
	attackHeld = true

	-- Keep normal combo taps instant on Begin; holding past HEAVY_CHARGE_DELAY transitions cleanly
	-- into the heavy-attack charge (HEAVY_CHARGE_SECONDS) and unleashes automatically at full charge.
	task.delay(Config.HEAVY_CHARGE_DELAY, function()
		if chargeToken ~= myToken or not attackHeld then
			return
		end
		if player:GetAttribute("Grabbed") == true or blocking or player:GetAttribute("Blocking") == true then
			cancelHeavyCharge(false)
			return
		end
		local currentRoot = body()
		if not currentRoot or not ready(heavyReadyAt, "HeavyReadyAt") then
			cancelHeavyCharge(false)
			return
		end

		chargingHeavy = true
		Effects.startCharge(currentRoot, classId())
		Remotes.HeavyCharge:FireServer(true)

		local remaining = math.max(Config.HEAVY_CHARGE_SECONDS - Config.HEAVY_CHARGE_DELAY, 0)
		task.delay(remaining, function()
			if chargeToken ~= myToken or not chargingHeavy then
				return
			end
			releaseHeavyAttack()
		end)
	end)
end

local function clearDash(hardStop: boolean?)
	if activeDash then
		local moveRoot = activeDash.root
		activeDash.velocity:Destroy()
		activeDash.attachment:Destroy()
		activeDash = nil
		dampenAfterMove(moveRoot, hardStop == true)
	end
end

local function dash()
	if isChoosingClass() or player:GetAttribute("Grabbed") == true or isStunned() then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid then
		return
	end
	local clock = os.clock()
	-- Small guard so a rapid double-tap chains smoothly instead of overlapping two dashes on the same frame.
	if clock - lastDashAt < Config.DASH_DURATION * 0.72 then
		return
	end
	local t = now()
	local maxCharges = Drops.maxDashCharges(player:GetAttribute("SpeedBuffUntil"), t)
	local allowed, nextCharges, nextRechargeAt =
		Drops.consumeDash(dashCharges, dashRechargeAt, maxCharges, t, Config.DASH_COOLDOWN, 0)
	if not allowed then
		return
	end
	local direction = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not direction then
		return
	end
	cancelHeavyCharge(true)
	lungeToken += 1
	clearLunge()
	clearDash()
	blocking = false
	dashCharges = nextCharges
	dashRechargeAt = nextRechargeAt
	lastDashAt = clock
	dashEndsAt = clock + Config.DASH_DURATION

	-- Bounded-force horizontal dash monitored every Heartbeat: cancels cleanly on wall/pillar
	-- contact so slamming into an obstacle never flings the player upward or out of the room.
	dashToken += 1
	local myDashToken = dashToken
	activeDash = startSafeVelocity(root, direction, Config.DASH_DISTANCE / Config.DASH_DURATION)
	task.delay(Config.DASH_DURATION, function()
		if dashToken == myDashToken then
			clearDash(false)
		end
	end)

	root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
	Effects.dash(root)
	Remotes.Dash:FireServer()
end

local function spin()
	if
		player:GetAttribute("Grabbed") == true
		or player:GetAttribute("OverDriveCharging") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(spinReadyAt, "SpinReadyAt") then
		return
	end
	cancelHeavyCharge(true)
	-- Seed or refresh the sticky target on ability use so basic attacks right after stay locked
	-- onto the same enemy while the player keeps heading toward it.
	local clock = os.clock()
	local facing = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if facing then
		local _, targetBody = selectTarget(root, facing, clock)
		lockedTarget = targetBody
		lastEngageAt = if targetBody then clock else -math.huge
	end
	spinReadyAt = now() + Config.SPIN_COOLDOWN
	Effects.spin(root)
	Remotes.Spin:FireServer()
end

local function stinger()
	if
		player:GetAttribute("Grabbed") == true
		or player:GetAttribute("OverDriveCharging") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(stingerReadyAt, "StingerReadyAt") then
		return
	end
	local clock = os.clock()
	local facing = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end
	local pick, targetBody = selectTarget(root, facing, clock)
	local aim = if pick then pick.direction else facing

	cancelHeavyCharge(true)
	lungeToken += 1
	clearLunge()
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock + Config.STINGER_DURATION else -math.huge
	stingerReadyAt = now() + Config.STINGER_COOLDOWN
	dashEndsAt = clock + Config.STINGER_DURATION

	-- Explosive horizontal piercing thrust (Estocada), bounded force + wall-stop guarded.
	local stingerSpeed = Config.STINGER_DISTANCE / math.max(Config.STINGER_DURATION, 0.05)
	activeLunge = startSafeVelocity(root, aim, stingerSpeed)
	local myToken = lungeToken
	task.delay(Config.STINGER_DURATION, function()
		if lungeToken == myToken then
			clearLunge(false)
		end
	end)

	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	Effects.stinger(root, aim, true)
	Remotes.Stinger:FireServer(aim)
end

local function overDrive()
	if
		player:GetAttribute("Grabbed") == true
		or player:GetAttribute("OverDriveCharging") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(overDriveReadyAt, "OverDriveReadyAt") then
		return
	end
	local clock = os.clock()
	local facing = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end
	local pick, targetBody = selectTarget(root, facing, clock)
	local aim = if pick then pick.direction else facing

	cancelHeavyCharge(true)
	lungeToken += 1
	clearLunge()
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	overDriveReadyAt = now() + Config.OVERDRIVE_COOLDOWN

	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	Remotes.OverDrive:FireServer(aim)
end

-- Every ability that came with the classes: aimed like the Stinger (forward target sticking),
-- predicted locally only for its cooldown and the caster's own pose. Its visuals come back from
-- the server to everyone, the caster included, so they are never drawn twice.
local function castClassAbility(abilityId: string)
	local ability = Config.ABILITIES[abilityId]
	if
		not ability
		or player:GetAttribute("Grabbed") == true
		or player:GetAttribute("OverDriveCharging") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(classAbilityReadyAt[abilityId] or 0, ability.readyAttribute) then
		return
	end
	local clock = os.clock()
	local facing = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not facing then
		return
	end
	local pick, targetBody = selectTarget(root, facing, clock)
	local aim = if pick then pick.direction else facing

	cancelHeavyCharge(true)
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	classAbilityReadyAt[abilityId] = now() + ability.cooldown
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	Effects.classAbilityLocal(abilityId)
	Remotes.UseAbility:FireServer(abilityId, aim)
end

local function selectAbilitySlot(slot: number)
	AbilityStore.select(slot)
end

-- The selected slot's ability for this player's class. No class yet (still on the selection
-- screen) means no ability.
local function useActiveAbility()
	if isChoosingClass() then
		return
	end
	local abilityId = Classes.abilityAt(classId(), AbilityStore.current())
	if abilityId == "spin" then
		spin()
	elseif abilityId == "stinger" then
		stinger()
	elseif abilityId == "overdrive" then
		overDrive()
	elseif abilityId then
		castClassAbility(abilityId)
	end
end

-- Selects `slot` and fires whatever the player's class has in it (the HUD's touch actuators).
local function castAbilitySlot(slot: number)
	AbilityStore.select(slot)
	useActiveAbility()
end

local function setBlock(active: boolean)
	if active then
		if
			isChoosingClass()
			or blocking
			or player:GetAttribute("Grabbed") == true
			or player:GetAttribute("OverDriveCharging") == true
			or isStunned()
		then
			return
		end
		local root = body()
		if not root or not ready(blockReadyAt, "BlockReadyAt") then
			return
		end
		cancelHeavyCharge(true)
		lungeToken += 1
		clearLunge()
		blocking = true
		Remotes.Block:FireServer(true)
	else
		if not blocking and player:GetAttribute("Blocking") ~= true then
			return
		end
		blocking = false
		blockReadyAt = now() + Config.BLOCK_COOLDOWN
		Remotes.Block:FireServer(false)
	end
end

local ACTIONS = {
	Dash = {
		run = dash,
		title = "Dash",
		inputs = { Enum.KeyCode.LeftShift, Enum.KeyCode.Q, Enum.KeyCode.ButtonB, Enum.KeyCode.ButtonL2 },
	},
	Ability = {
		run = useActiveAbility,
		title = "Habilidad",
		inputs = { Enum.KeyCode.E, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonR1 },
	},
}

local ATTACK_INPUTS = { Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonX, Enum.KeyCode.ButtonR2 }
local BLOCK_INPUTS = { Enum.UserInputType.MouseButton2, Enum.KeyCode.F, Enum.KeyCode.ButtonL1 }

function CombatInput.beginAttack()
	beginAttackHold()
end

function CombatInput.endAttack()
	cancelHeavyCharge(true)
end

function CombatInput.dash()
	dash()
end

-- Fires the class ability in `slot` (1..3).
function CombatInput.castSlot(slot: number)
	castAbilitySlot(slot)
end

-- Slots 1, 2 and 3 under the names they had before the classes, when every player had Giro,
-- Stinger and Over Drive there. They fire *the slot*, whatever the class has in it.
function CombatInput.spin()
	castAbilitySlot(1)
end

function CombatInput.stinger()
	castAbilitySlot(2)
end

function CombatInput.overDrive()
	castAbilitySlot(3)
end

function CombatInput.useAbility()
	useActiveAbility()
end

function CombatInput.beginBlock()
	setBlock(true)
end

function CombatInput.endBlock()
	setBlock(false)
end

function CombatInput.start()
	-- A new class means a new kit: back to slot 1, with its name on the touch button.
	player:GetAttributeChangedSignal("Class"):Connect(function()
		table.clear(classAbilityReadyAt)
		AbilityStore.reset()
	end)
	for name, action in pairs(ACTIONS) do
		-- `createTouchButton = false`: mobile touch buttons are rendered by CombatHud's machined
		-- radial Hazard Arc (docs/ui-design-system.md) and call the public hooks above directly.
		ContextActionService:BindActionAtPriority(name, function(_, state: Enum.UserInputState)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			action.run()
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, table.unpack(action.inputs))
	end

	-- Switch active swordsman ability with keys 1, 2, 3 (and gamepad D-pad left/right).
	ContextActionService:BindActionAtPriority("AbilitySlot1", function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		selectAbilitySlot(1)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.One)

	ContextActionService:BindActionAtPriority("AbilitySlot2", function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		selectAbilitySlot(2)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Two)

	ContextActionService:BindActionAtPriority("AbilitySlot3", function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		selectAbilitySlot(3)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Three)

	ContextActionService:BindActionAtPriority("AbilityCyclePrev", function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		AbilityStore.cycle(-1)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.DPadLeft)

	ContextActionService:BindActionAtPriority("AbilityCycleNext", function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		AbilityStore.cycle(1)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.DPadRight)

	-- Attack: tap fires the basic combo immediately; holding continuously for HEAVY_CHARGE_SECONDS
	-- (2 s) charges and unleashes the Heavy Attack. Releasing early cancels the charge cleanly.
	ContextActionService:BindActionAtPriority("Attack", function(_, state: Enum.UserInputState, input: InputObject)
		if state == Enum.UserInputState.Begin then
			if pointerOverGuiButton(input) then
				return Enum.ContextActionResult.Pass
			end
			beginAttackHold()
			return Enum.ContextActionResult.Sink
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			cancelHeavyCharge(true)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value, table.unpack(ATTACK_INPUTS))

	-- Hold-to-block action: Begin raises guard (and opens the Parry window), End/Cancel lowers it.
	ContextActionService:BindActionAtPriority("Block", function(_, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			setBlock(true)
			return Enum.ContextActionResult.Sink
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			setBlock(false)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value, table.unpack(BLOCK_INPUTS))

	-- Clear local charge visuals immediately if a grabber catches or a mace stuns the player.
	player:GetAttributeChangedSignal("Grabbed"):Connect(function()
		if player:GetAttribute("Grabbed") == true then
			cancelHeavyCharge(false)
		end
	end)
	player:GetAttributeChangedSignal("StunnedUntil"):Connect(function()
		if isStunned() then
			cancelHeavyCharge(false)
			blocking = false
			lungeToken += 1
			clearLunge()
		end
	end)

	-- Grant the bonus Double Dash charge immediately when picking up a Speed Buff drop.
	player:GetAttributeChangedSignal("SpeedBuffUntil"):Connect(function()
		local t = now()
		local maxCharges = Drops.maxDashCharges(player:GetAttribute("SpeedBuffUntil"), t)
		if maxCharges >= 2 and dashCharges < 2 then
			dashCharges = 2
			dashRechargeAt = 0
		end
	end)

	-- Per-frame wall-stop guard for active dashes/lunges + hard arena bounds safety clamp so
	-- no physics spike can ever fling the player onto a structure or outside the room.
	RunService.Heartbeat:Connect(function(dt: number)
		local root, humanoid = body()
		if not root or not humanoid then
			return
		end

		local safeDt = math.min(dt, 1 / 30)
		if activeDash then
			local checkDist = math.clamp(activeDash.speed * safeDt * 1.15, 1.2, 2.6)
			if activeDash.root ~= root or hitsWallAhead(root, activeDash.direction, checkDist) then
				dashToken += 1
				clearDash(true)
			elseif humanoid:GetState() ~= Enum.HumanoidStateType.Jumping and root.AssemblyLinearVelocity.Y > 6 then
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
			end
		end

		if activeLunge then
			local checkDist = math.clamp(activeLunge.speed * safeDt * 1.15, 1.2, 2.6)
			if activeLunge.root ~= root or hitsWallAhead(root, activeLunge.direction, checkDist) then
				lungeToken += 1
				clearLunge(true)
			elseif humanoid:GetState() ~= Enum.HumanoidStateType.Jumping and root.AssemblyLinearVelocity.Y > 6 then
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
			end
		end

		-- Arena bounds safety net: if a physics glitch ever pushes the character past the room
		-- perimeter or above/below the arena shell, pull them cleanly back inside.
		local halfX = Config.ROOM_SIZE.X / 2 - 1.5
		local halfZ = Config.ROOM_SIZE.Y / 2 - 1.5
		local pos = root.Position
		if math.abs(pos.X) > halfX or math.abs(pos.Z) > halfZ or pos.Y > 33 or pos.Y < -4 then
			local clamped = Waves.clamp(pos, Config.ROOM_SIZE, 3.5)
			local safe = Waves.avoidObstacles(clamped, 2.8, Config.ARENA_PILLARS)
			local safeY = math.clamp(pos.Y, 3.5, 22)
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = CFrame.new(safe.X, safeY, safe.Z) * root.CFrame.Rotation
		end
	end)

	-- A respawn is a fresh start: no combo carried over, nothing predicted from the last life.
	player.CharacterAdded:Connect(function()
		cancelHeavyCharge(false)
		lungeToken += 1
		clearLunge()
		dashToken += 1
		clearDash()
		dashEndsAt = 0
		lockedTarget = nil
		lastEngageAt = -math.huge
		comboStep = 0
		lastSwingAt = -math.huge
		dashCharges = 1
		dashRechargeAt = 0
		lastDashAt = -math.huge
		spinReadyAt = 0
		stingerReadyAt = 0
		overDriveReadyAt = 0
		table.clear(classAbilityReadyAt)
		blockReadyAt = 0
		heavyReadyAt = 0
		blocking = false
	end)
end

return CombatInput
