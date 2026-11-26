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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local Drops = require(Shared.features.drops.Drops)
local Melee = require(Shared.features.combat.Melee)
local Classes = require(Shared.features.classes.Classes)

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
local activeDash: { velocity: LinearVelocity, attachment: Attachment }? = nil
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
local activeLunge: { velocity: LinearVelocity, attachment: Attachment }? = nil
local dashEndsAt = 0

-- Sticky target picked by the first basic attack or ability in a combo. Tracked with its own
-- `lastEngageAt` clock (separate from `lastSwingAt`) so an ability can seed or refresh the lock
-- without altering the server-synced combo step window.
local lockedTarget: BasePart? = nil
local lastEngageAt = -math.huge

local function clearLunge()
	if activeLunge then
		activeLunge.velocity:Destroy()
		activeLunge.attachment:Destroy()
		activeLunge = nil
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
	local pick = Melee.pickTarget(
		root.Position,
		facing,
		targets,
		Config.AIM_ASSIST_RANGE,
		Config.AIM_ASSIST_CONE,
		Config.AIM_ASSIST_ANGLE_WEIGHT,
		preferredIndex,
		Config.TARGET_LOCK_CONE
	)
	local targetBody: BasePart? = if pick then bodies[pick.index] else nil
	return pick, targetBody
end

local function attack()
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

	local lungeDist = 0
	if pick and clock >= dashEndsAt then
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

		-- Horizontal-only velocity, same as dash: respects room walls and leaves gravity alone.
		local attachment = Instance.new("Attachment")
		attachment.Parent = root
		local velocity = Instance.new("LinearVelocity")
		velocity.Attachment0 = attachment
		velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
		velocity.LineDirection = aim
		velocity.LineVelocity = Config.ATTACK_LUNGE_SPEED
		velocity.MaxForce = math.huge
		velocity.Parent = root
		activeLunge = { velocity = velocity, attachment = attachment }

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

	local lungeDist = 0
	if pick and clock >= dashEndsAt then
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

		local attachment = Instance.new("Attachment")
		attachment.Parent = root
		local velocity = Instance.new("LinearVelocity")
		velocity.Attachment0 = attachment
		velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
		velocity.LineDirection = aim
		velocity.LineVelocity = Config.ATTACK_LUNGE_SPEED
		velocity.MaxForce = math.huge
		velocity.Parent = root
		activeLunge = { velocity = velocity, attachment = attachment }

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
			Effects.heavyAttack(root, finalAim)
			Remotes.HeavyAttack:FireServer(finalAim)
		end)
	else
		Effects.heavyAttack(root, aim)
		Remotes.HeavyAttack:FireServer(aim)
	end
end

local function beginAttackHold()
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
		Effects.startCharge(currentRoot)
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

local function clearDash()
	if activeDash then
		activeDash.velocity:Destroy()
		activeDash.attachment:Destroy()
		activeDash = nil
	end
end

local function dash()
	if player:GetAttribute("Grabbed") == true or isStunned() then
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

	-- The character is the client's to move, so the dash is a velocity held along one line for
	-- its duration: horizontal only, gravity left alone, and gone before the next frame's input.
	dashToken += 1
	local myDashToken = dashToken
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	velocity.LineDirection = direction
	velocity.LineVelocity = Config.DASH_DISTANCE / Config.DASH_DURATION
	velocity.MaxForce = math.huge
	velocity.Parent = root
	activeDash = { velocity = velocity, attachment = attachment }
	task.delay(Config.DASH_DURATION, function()
		if dashToken == myDashToken then
			clearDash()
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

	-- Explosive horizontal piercing thrust (DMC Stinger), keeping gravity intact and respecting walls.
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	velocity.LineDirection = aim
	velocity.LineVelocity = Config.STINGER_DISTANCE / math.max(Config.STINGER_DURATION, 0.05)
	velocity.MaxForce = math.huge
	velocity.Parent = root
	activeLunge = { velocity = velocity, attachment = attachment }
	local myToken = lungeToken
	task.delay(Config.STINGER_DURATION, function()
		if lungeToken == myToken then
			clearLunge()
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

local function classId(): string?
	local current = player:GetAttribute("Class")
	return if type(current) == "string" and current ~= "" then current else nil
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

local function updateAbilityTouchTitle(slot: number)
	local abilityId = Classes.abilityAt(classId(), slot)
	local ability = abilityId and Config.ABILITIES[abilityId]
	ContextActionService:SetTitle("Ability", if ability then ability.name else "Habilidad")
end

local function selectAbilitySlot(slot: number)
	local chosen = AbilityStore.select(slot)
	updateAbilityTouchTitle(chosen)
end

-- The selected slot's ability for this player's class. No class yet (still on the selection
-- screen) means no ability.
local function useActiveAbility()
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

local function setBlock(active: boolean)
	if active then
		if
			blocking
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

function CombatInput.start()
	-- A new class means a new kit: back to slot 1, with its name on the touch button.
	player:GetAttributeChangedSignal("Class"):Connect(function()
		table.clear(classAbilityReadyAt)
		AbilityStore.reset()
		updateAbilityTouchTitle(1)
	end)
	for name, action in pairs(ACTIONS) do
		ContextActionService:BindActionAtPriority(name, function(_, state: Enum.UserInputState)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			action.run()
			return Enum.ContextActionResult.Sink
		end, true, Enum.ContextActionPriority.High.Value, table.unpack(action.inputs))
		ContextActionService:SetTitle(name, action.title)
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
		updateAbilityTouchTitle(AbilityStore.cycle(-1))
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.DPadLeft)

	ContextActionService:BindActionAtPriority("AbilityCycleNext", function(_, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		updateAbilityTouchTitle(AbilityStore.cycle(1))
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.DPadRight)

	-- Attack: tap fires the basic combo immediately; holding continuously for HEAVY_CHARGE_SECONDS
	-- (2 s) charges and unleashes the Heavy Attack. Releasing early cancels the charge cleanly.
	ContextActionService:BindActionAtPriority("Attack", function(_, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			beginAttackHold()
			return Enum.ContextActionResult.Sink
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			cancelHeavyCharge(true)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.ContextActionPriority.High.Value, table.unpack(ATTACK_INPUTS))
	ContextActionService:SetTitle("Attack", "Atacar")

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
	end, true, Enum.ContextActionPriority.High.Value, table.unpack(BLOCK_INPUTS))
	ContextActionService:SetTitle("Block", "Bloquear")

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
