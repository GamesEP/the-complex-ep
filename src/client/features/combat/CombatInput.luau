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
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local CombatAnim = require(Shared.features.combat.CombatAnim)
local CombatState = require(Shared.features.combat.CombatState)
local Defense = require(Shared.features.combat.Defense)
local Drops = require(Shared.features.drops.Drops)
local Melee = require(Shared.features.combat.Melee)
local Classes = require(Shared.features.classes.Classes)
local UpgradePool = require(Shared.features.upgrades.UpgradePool)
local Waves = require(Shared.features.enemies.Waves)

local Effects = require(script.Parent.Effects)
local PlayerAnimator = require(script.Parent.PlayerAnimator)
local AbilityStore = require(script.Parent.stores.AbilityStore)

local CombatInput = {}

local player = Players.LocalPlayer
local shakeCamera: ((number, number) -> ())? = nil

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
	-- A tracked lunge's per-frame steering, and how it finishes when the wall guard stops it, so
	-- a lunge into a pillar still lands its swing instead of silently eating the input.
	conn: RBXScriptConnection?,
	onWall: (() -> ())?,
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

-- Active attack/skill lunge & forward cleave-step state; gated on generation tokens so a dash,
-- block, knockback, stun, grab, or respawn cancels any in-flight motion cleanly with a single
-- velocity owner on HumanoidRootPart at all times (shared/features/combat/CombatState.luau).
local lungeToken = 0
local activeLunge: ActiveMove? = nil
local stepToken = 0
local activeStep: ActiveMove? = nil
local startupToken = 0
local dashEndsAt = 0
local knockbackEndsAt = 0
local parryCounterEndsAt = 0
local parryCounterCancelAt = 0

-- Active offensive animation recovery & input buffer (DMC-style cancel window): once `clock >=
-- activeAction.cancelAt`, any other attack or ability cancels recovery cleanly into the next move.
type ActiveAction = {
	key: string,
	startedAt: number,
	activeAt: number,
	baseCancelAt: number,
	cancelAt: number,
	moveCancelAt: number,
	endsAt: number,
	hitConfirmed: boolean,
	hitstopEndsAt: number,
	isMeleeSwing: boolean,
	aimDir: Vector3,
}
type BufferedKind = string
local activeAction: ActiveAction? = nil
local bufferedAction: { kind: BufferedKind, abilityId: string?, expiresAt: number }? = nil

-- DMC soft target lock: keeps the enemy locked while neutral or steering in its general direction
-- (`TARGET_LOCK_CONE`), tracks small recoil movement to stay in the sweet spot, and breaks
-- immediately when steering in any other direction.
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
		if activeLunge.conn then
			activeLunge.conn:Disconnect()
		end
		activeLunge.velocity:Destroy()
		activeLunge.attachment:Destroy()
		activeLunge = nil
		-- A hard stop zeroes horizontal momentum on arrival so the LinearVelocity never slides the
		-- player past the target's sweet-spot range.
		dampenAfterMove(moveRoot, hardStop == true)
	end
end

local function clearStep(hardStop: boolean?)
	if activeStep then
		local moveRoot = activeStep.root
		if activeStep.conn then
			activeStep.conn:Disconnect()
		end
		activeStep.velocity:Destroy()
		activeStep.attachment:Destroy()
		activeStep = nil
		dampenAfterMove(moveRoot, hardStop == true)
	end
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

-- Single velocity owner teardown: cancels lunge, attack step, dash, and pending startup before
-- starting a competing velocity (Dash, Knockback, Guard, CC, Respawn).
local function clearAllMotion(hardStop: boolean?)
	startupToken += 1
	lungeToken += 1
	clearLunge(hardStop)
	stepToken += 1
	clearStep(hardStop)
	dashToken += 1
	clearDash(hardStop)
end

local function recordAction(
	actionName: string,
	step: number?,
	startedAt: number,
	startupSeconds: number?,
	useWhiffPenalty: boolean?,
	aimDir: Vector3?
)
	local key = CombatAnim.specKey(actionName, step)
	local spec = Config.ANIMATIONS[key]
	if not spec then
		return
	end
	local baseCancelAt = startedAt + spec.cancelAt
	local cancelAt = if useWhiffPenalty
		then CombatState.effectiveCancelAt(baseCancelAt, false, Config.ATTACK_WHIFF_CANCEL_PENALTY)
		else baseCancelAt
	local isMeleeSwing = actionName == "attack" or actionName == "heavyAttack"
	activeAction = {
		key = key,
		startedAt = startedAt,
		activeAt = startedAt + (startupSeconds or 0),
		baseCancelAt = baseCancelAt,
		cancelAt = cancelAt,
		moveCancelAt = cancelAt + Config.ATTACK_MOVE_CANCEL_OFFSET,
		endsAt = startedAt + spec.duration,
		hitConfirmed = not useWhiffPenalty,
		hitstopEndsAt = 0,
		isMeleeSwing = isMeleeSwing,
		aimDir = Melee.flat(aimDir or Vector3.new(0, 0, -1)) or Vector3.new(0, 0, -1),
	}
end

local function canStartOffensiveAction(clock: number, kind: BufferedKind, abilityId: string?): boolean
	if activeLunge then
		bufferedAction = { kind = kind, abilityId = abilityId, expiresAt = clock + Config.COMBO_INPUT_BUFFER }
		return false
	end
	if clock < parryCounterEndsAt and clock < parryCounterCancelAt then
		bufferedAction = { kind = kind, expiresAt = parryCounterCancelAt + 0.08 }
		return false
	end
	if activeAction and clock < activeAction.cancelAt then
		if activeAction.cancelAt - clock <= Config.COMBO_INPUT_BUFFER then
			bufferedAction = { kind = kind, abilityId = abilityId, expiresAt = activeAction.cancelAt + 0.08 }
		end
		return false
	end
	bufferedAction = nil
	return true
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

local function hasDoubleDash(): boolean
	return player:GetAttribute("HasDoubleDash") == true
end

local function cooldownMult(): number
	local v = player:GetAttribute("UpgradeCooldownMult")
	if type(v) ~= "number" or v <= 0 then
		return 1
	end
	return math.max(v, Config.MIN_COOLDOWN_MULTIPLIER)
end

local function abilitySlotInfo(slot: number): (string?, number)
	local attr = player:GetAttribute(`AbilitySlot{slot}`)
	if type(attr) == "string" and attr ~= "" then
		local lv = player:GetAttribute(`AbilityLevel{slot}`)
		return attr, if type(lv) == "number" and lv >= 1 then math.floor(lv) else 1
	end
	local legacy = Classes.abilityAt(classId(), slot)
	return legacy, if legacy then 1 else 0
end

local function effectiveCooldown(baseCooldown: number, level: number): number
	local _, lvCd = UpgradePool.levelMultipliers(math.max(level, 1))
	return math.max(baseCooldown * lvCd * cooldownMult(), 0.35)
end

-- Matches RunService.isPaused(): blocks combat inputs while in the Hub, while downed in co-op,
-- or on the pre-run / end-of-run screens, while allowing full combat during `"fighting"` and `"transition"`.
local function isChoosingClass(): boolean
	if player:GetAttribute("Downed") == true then
		return true
	end
	local world = workspace:FindFirstChild("World")
	if world and world:GetAttribute("ServerMode") == "hub" then
		return true
	end
	local runState = world and world:GetAttribute("RunState")
	if type(runState) == "string" then
		return runState ~= "fighting" and runState ~= "transition"
	end
	return true
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

-- Resolves the attack/ability target: keeps `lockedTarget` while neutral (`moveDir == nil`) or
-- steering in its general direction (`TARGET_LOCK_CONE`); steering any other direction drops the
-- lock immediately and picks a new target in `moveDir` (or ends the lock if none is there).
local function selectTarget(
	root: BasePart,
	moveDir: Vector3?,
	fallbackFacing: Vector3,
	clock: number
): (Melee.TargetPick?, BasePart?)
	local targets, bodies = enemyTargets()
	local preferredIndex: number? = nil
	local lockAlive = activeAction ~= nil or (clock - lastEngageAt <= Config.TARGET_LOCK_DURATION)
	if lockedTarget and lockAlive and lockedTarget:IsDescendantOf(workspace) then
		preferredIndex = table.find(bodies, lockedTarget)
	end
	local assistRange = if Classes.isRanged(classId()) then Config.STAFF_AIM_ASSIST_RANGE else Config.AIM_ASSIST_RANGE
	local hasMoveInput = moveDir ~= nil
	local facing = moveDir or fallbackFacing
	local pick = Melee.pickTarget(
		root.Position,
		facing,
		targets,
		assistRange,
		Config.AIM_ASSIST_CONE,
		Config.AIM_ASSIST_ANGLE_WEIGHT,
		preferredIndex,
		Config.TARGET_LOCK_CONE,
		hasMoveInput
	)
	local targetBody: BasePart? = if pick then bodies[pick.index] else nil
	return pick, targetBody
end

local function currentPhase(clock: number): CombatState.Phase
	if player:GetAttribute("Grabbed") == true then
		return "grabbed"
	end
	if clock < knockbackEndsAt then
		return "knockback"
	end
	if isStunned() then
		return "stunned"
	end
	if activeDash ~= nil or clock < dashEndsAt then
		return "dash"
	end
	if blocking or player:GetAttribute("Blocking") == true then
		return "guard"
	end
	if chargingHeavy or player:GetAttribute("ChargingHeavy") == true or player:GetAttribute("OverDriveCharging") == true then
		return "charge"
	end
	if activeLunge ~= nil then
		return "lunge"
	end
	if activeAction ~= nil then
		if clock < activeAction.hitstopEndsAt then
			return "hitstop"
		end
		if clock < activeAction.activeAt then
			return "startup"
		end
		if clock < activeAction.baseCancelAt then
			return if activeAction.isMeleeSwing then "active" else "ability"
		end
		return "recovery"
	end
	if clock < parryCounterEndsAt then
		return "parryCounter"
	end
	return "locomotion"
end

-- Enforces `CombatState.movementPolicy` on the local Humanoid every frame so MoveDir never causes
-- sideways/backward skating during Startup, Active, Lunge, Hitstop, Ability, Dash, or Recovery.
-- Only exits Recovery early when `allowRecoveryMoveCancel` is explicitly true (steering away with
-- no buffered action), preventing any WalkSpeed/AutoRotate leak between combo attacks.
local function syncMovementPolicy(humanoid: Humanoid, clock: number, allowRecoveryMoveCancel: boolean?)
	local phase = currentPhase(clock)
	local canUnlockRecovery = allowRecoveryMoveCancel == true and bufferedAction == nil
	local policy = CombatState.movementPolicy(phase, canUnlockRecovery)
	if humanoid.AutoRotate ~= policy.autoRotate then
		humanoid.AutoRotate = policy.autoRotate
	end

	local t = now()
	local speedMultAttr = player:GetAttribute("UpgradeSpeedMult")
	local upgradeSpeed = if type(speedMultAttr) == "number" and speedMultAttr > 0 then speedMultAttr else 1
	local class = Classes.get(classId())
	local baseSpeed = (if class then class.moveSpeed else Config.MOVE_SPEED) * upgradeSpeed
	local chargingOverDrive = player:GetAttribute("OverDriveCharging") == true
	local chargingHeavyAttr = chargingHeavy or player:GetAttribute("ChargingHeavy") == true
	local chargeMult = if chargingOverDrive
		then Config.OVERDRIVE_CHARGE_MOVE_MULTIPLIER
		else Config.HEAVY_CHARGE_MOVE_MULTIPLIER
	local targetSpeed = Defense.walkSpeed(
		baseSpeed,
		player:GetAttribute("SpeedBuffUntil"),
		blocking or player:GetAttribute("Blocking") == true,
		player:GetAttribute("Grabbed") == true,
		t,
		Config.BUFF_SPEED_MULTIPLIER,
		Config.BLOCK_MOVE_MULTIPLIER,
		chargingOverDrive or chargingHeavyAttr,
		chargeMult,
		isStunned(),
		not policy.allowMoveInput
	)
	if math.abs(humanoid.WalkSpeed - targetSpeed) > 0.05 then
		humanoid.WalkSpeed = targetSpeed
	end
end

-- Short wall-safe forward cleave step for in-range or untargeted swings so attacking still feels
-- kinetic while WalkSpeed = 0 removes directional skating. Stops before a nearby target's sweet-spot.
local function startAttackStep(
	root: BasePart,
	aim: Vector3,
	distance: number,
	speed: number,
	targetBody: BasePart?,
	targetRadius: number?
)
	local stepDist = distance
	if targetBody and targetBody:IsDescendantOf(workspace) then
		local dist = Melee.distance(root.Position, targetBody.Position)
		local gap = dist - ((targetRadius or 0) + Config.ATTACK_LUNGE_STOP_DISTANCE)
		stepDist = math.clamp(gap, 0, distance)
	end
	if stepDist <= 0.12 or speed <= 0 then
		return
	end

	stepToken += 1
	local myToken = stepToken
	clearStep(false)

	local move = startSafeVelocity(root, aim, speed)
	if not move then
		return
	end

	local startPos = root.Position
	local startedAt = os.clock()
	local maxDuration = (stepDist / speed) + 0.04

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if stepToken ~= myToken then
			conn:Disconnect()
			return
		end
		local currentRoot = body()
		if currentRoot ~= root then
			clearStep(false)
			return
		end
		if activeAction and os.clock() < activeAction.hitstopEndsAt then
			move.velocity.LineVelocity = 0
			return
		end
		move.velocity.LineVelocity = speed

		local traveled = Melee.distance(startPos, root.Position)
		local reachedTarget = false
		if targetBody and targetBody:IsDescendantOf(workspace) then
			local dist = Melee.distance(root.Position, targetBody.Position)
			if dist <= (targetRadius or 0) + Config.ATTACK_LUNGE_STOP_DISTANCE + 0.2 then
				reachedTarget = true
			end
		end
		if reachedTarget or traveled >= stepDist or os.clock() - startedAt >= maxDuration then
			stepToken += 1
			clearStep(true)
		end
	end)
	move.conn = conn
	activeStep = move
end

-- Tracks a horizontal `LinearVelocity` impulse toward `targetBody` (or along `aim` if untargeted)
-- on `RenderStepped`, braking and zeroing horizontal velocity the exact frame the player enters
-- sweet-spot range (`targetRadius + stopDist`) so attacks & skills never overshoot past the target.
-- When `allowMoveAbort` is true, steering beyond `LUNGE_ABORT_ANGLE` aborts the lunge cleanly
-- into the new direction instead of pulling the player back toward the old target.
local function startTrackedLunge(
	root: BasePart,
	targetBody: BasePart?,
	targetRadius: number,
	aim: Vector3,
	maxDist: number,
	stopDist: number,
	speed: number,
	onComplete: (Vector3) -> (),
	allowMoveAbort: boolean?,
	onAbort: ((Vector3, BasePart?, number) -> ())?
): boolean
	local lungeDist = maxDist
	if targetBody and targetBody:IsDescendantOf(workspace) then
		local dist = Melee.distance(root.Position, targetBody.Position)
		lungeDist = Melee.lungeDistance(dist, targetRadius, stopDist, maxDist)
	end
	if lungeDist <= 0.15 or speed <= 0 then
		onComplete(aim)
		return false
	end

	lungeToken += 1
	local myToken = lungeToken
	clearLunge()
	stepToken += 1
	clearStep(false)

	-- Bounded force with a wall-stop (startSafeVelocity); nil means already flush against a wall,
	-- so the action fires in place.
	local move = startSafeVelocity(root, aim, speed)
	if not move then
		onComplete(aim)
		return false
	end
	local velocity = move.velocity

	local startPos = root.Position
	local startedAt = os.clock()
	local maxDuration = (lungeDist / speed) + 0.05
	local currentAim = aim

	local function finish(finalDir: Vector3)
		clearLunge(true)
		local finalAim = finalDir
		if targetBody and targetBody:IsDescendantOf(workspace) then
			finalAim = Melee.flat(targetBody.Position - root.Position) or finalDir
		end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + finalAim)
		onComplete(finalAim)
	end

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt: number)
		if lungeToken ~= myToken then
			conn:Disconnect()
			return
		end
		local currentRoot, currentHumanoid = body()
		if currentRoot ~= root or not currentHumanoid then
			clearLunge()
			return
		end

		-- Opposite-direction lunge abort: steering > LUNGE_ABORT_ANGLE away drops the lock and
		-- redirects cleanly into the player's new MoveDir instead of fighting their input.
		if allowMoveAbort then
			local moveDir = Melee.flat(currentHumanoid.MoveDirection)
			if CombatState.shouldAbortLunge(currentAim, moveDir, Config.LUNGE_ABORT_ANGLE) and moveDir then
				lungeToken += 1
				clearLunge(true)
				lockedTarget = nil
				local clock = os.clock()
				local newPick, newBody = selectTarget(root, moveDir, moveDir, clock)
				local newAim = if newPick then newPick.direction else moveDir
				local newRadius = if newPick then newPick.radius else 0
				lockedTarget = newBody
				lastEngageAt = if newBody then clock else -math.huge
				root.CFrame = CFrame.lookAt(root.Position, root.Position + newAim)
				if onAbort then
					onAbort(newAim, newBody, newRadius)
				else
					onComplete(newAim)
				end
				return
			end
		end

		local elapsed = os.clock() - startedAt
		local traveled = Melee.distance(startPos, root.Position)
		local reachedSweetSpot = false

		-- IsDescendantOf(workspace) rather than .Parent: server Destroy() leaves client child
		-- pointers intact (see docs/roblox-gotchas.md).
		if targetBody and targetBody:IsDescendantOf(workspace) then
			local toTarget = Vector3.new(targetBody.Position.X - root.Position.X, 0, targetBody.Position.Z - root.Position.Z)
			local dist = toTarget.Magnitude
			if dist > 1e-3 then
				currentAim = toTarget / dist
			end
			local sweetSpot = targetRadius + stopDist
			-- Tight lookahead brakes right inside close melee sweet-spot without stopping too early.
			local lookahead = speed * math.min(dt, 0.02) * 0.35
			if dist <= sweetSpot + lookahead then
				reachedSweetSpot = true
			else
				velocity.LineDirection = currentAim
				move.direction = currentAim
				root.CFrame = CFrame.lookAt(root.Position, root.Position + currentAim)
			end
		end

		if reachedSweetSpot or traveled >= lungeDist or elapsed >= maxDuration then
			finish(currentAim)
		end
	end)

	move.conn = conn
	move.onWall = function()
		finish(currentAim)
	end
	activeLunge = move
	return true
end

-- Executes a melee Startup -> Active sequence with MoveDir locked out, optional micro-pivot on
-- untargeted windup, and a short forward cleave step when no approach lunge ran.
local function beginMeleeStartup(
	root: BasePart,
	initialAim: Vector3,
	startupSeconds: number,
	stepDistance: number,
	targetBody: BasePart?,
	targetRadius: number?,
	allowStep: boolean,
	onStart: (number) -> (),
	onActive: (Vector3) -> ()
)
	startupToken += 1
	local myToken = startupToken
	local startedAt = os.clock()
	local activeAt = startedAt + math.max(startupSeconds, 0)
	local currentAim = initialAim

	root.CFrame = CFrame.lookAt(root.Position, root.Position + currentAim)
	onStart(startedAt)

	if allowStep and stepDistance > 0 then
		startAttackStep(root, currentAim, stepDistance, Config.ATTACK_STEP_SPEED, targetBody, targetRadius)
	end

	if startupSeconds <= 0 then
		onActive(currentAim)
		return
	end

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if startupToken ~= myToken then
			conn:Disconnect()
			return
		end
		local currentRoot, currentHumanoid = body()
		if
			currentRoot ~= root
			or not currentHumanoid
			or blocking
			or player:GetAttribute("Blocking") == true
			or player:GetAttribute("Grabbed") == true
			or isStunned()
		then
			conn:Disconnect()
			return
		end

		-- Allow subtle +/-35 deg windup aim correction when swinging untargeted, or track small
		-- target movement before committing the active blade arc.
		if targetBody and targetBody:IsDescendantOf(workspace) then
			local toTarget = Melee.flat(targetBody.Position - root.Position)
			if toTarget then
				currentAim = toTarget
			end
		else
			local moveDir = Melee.flat(currentHumanoid.MoveDirection)
			if moveDir then
				currentAim = CombatState.microPivot(initialAim, moveDir, Config.ATTACK_STARTUP_MICRO_PIVOT_DEG)
			end
		end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + currentAim)
		if activeStep and activeStep.root == root then
			activeStep.direction = currentAim
			activeStep.velocity.LineDirection = currentAim
		end

		if os.clock() >= activeAt then
			conn:Disconnect()
			onActive(currentAim)
		end
	end)
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
		clearAllMotion(true)
		Effects.attackWindup(1)
		Remotes.GrabEscape:FireServer()
		return
	end
	if
		blocking
		or player:GetAttribute("Blocking") == true
		or player:GetAttribute("OverDriveCharging") == true
		or isStunned()
		or os.clock() < knockbackEndsAt
	then
		return
	end
	local clock = os.clock()
	if not canStartOffensiveAction(clock, "attack") then
		return
	end
	local minInterval = Melee.attackInterval(
		comboStep,
		Config.COMBO_HITS,
		Config.ATTACK_INTERVAL,
		Config.ATTACK_FINISHER_INTERVAL
	)
	local sinceSwing = clock - lastSwingAt
	if sinceSwing < minInterval then
		if minInterval - sinceSwing <= Config.COMBO_INPUT_BUFFER then
			bufferedAction = { kind = "attack", expiresAt = lastSwingAt + minInterval + 0.08 }
		end
		return
	end

	-- Every input device (mouse, gamepad, touch) swings along where the character is moving or
	-- looking, keeping the locked target on neutral/general-direction input or snapping to a new
	-- target when steering in another direction.
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	if not facing or not fallbackFacing then
		return
	end

	local pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
	local aim = if pick then pick.direction else facing
	local targetRadius = if pick then pick.radius else 0
	local ranged = Classes.isRanged(classId())

	parryCounterEndsAt = 0
	comboStep = Melee.nextStep(comboStep, lastSwingAt, clock, Config.COMBO_HITS, Config.COMBO_WINDOW)
	local step = comboStep
	local isFinisher = step >= Config.COMBO_HITS
	local startupSeconds = if isFinisher then Config.ATTACK_FINISHER_STARTUP_SECONDS else Config.ATTACK_STARTUP_SECONDS
	local stepDistance = if isFinisher then Config.ATTACK_FINISHER_STEP_DISTANCE else Config.ATTACK_STEP_DISTANCE
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	syncMovementPolicy(humanoid, clock)

	if ranged then
		lastSwingAt = clock
		recordAction("attack", step, clock, 0, false, aim)
		Effects.staffAttack(root, aim, step)
		Remotes.Attack:FireServer(aim)
		return
	end

	local didLunge = false
	local function runSwing(swingAim: Vector3, swingTarget: BasePart?, swingRadius: number, allowStep: boolean)
		-- After a tracked lunge arrives at the tighter sweet-spot, wait a tiny settle beat so the
		-- client's arrival CFrame replicates to the server before `Attack` evaluates `Melee.inArc`.
		local windupDur = if didLunge then Config.ATTACK_POST_LUNGE_SETTLE_SECONDS else startupSeconds
		beginMeleeStartup(
			root,
			swingAim,
			windupDur,
			stepDistance,
			swingTarget,
			swingRadius,
			allowStep,
			function(startedAt: number)
				lastSwingAt = startedAt
				recordAction("attack", step, startedAt, windupDur, true, swingAim)
				if not didLunge then
					Effects.attackWindup(step)
				end
			end,
			function(finalAim: Vector3)
				local swingClock = os.clock()
				if swingTarget and swingTarget:IsDescendantOf(workspace) then
					lastEngageAt = swingClock
				end
				if activeAction then
					activeAction.aimDir = finalAim
				end
				Effects.slash(root, finalAim, step, true)
				Remotes.Attack:FireServer(finalAim)
			end
		)
	end

	if pick and targetBody and clock >= dashEndsAt then
		local dist = Melee.distance(root.Position, targetBody.Position)
		local willLunge = Melee.lungeDistance(
			dist,
			targetRadius,
			Config.ATTACK_LUNGE_STOP_DISTANCE,
			Config.ATTACK_LUNGE_MAX_DISTANCE
		) > 0.15
		if willLunge then
			didLunge = true
			Effects.attackWindup(step)
			startTrackedLunge(
				root,
				targetBody,
				targetRadius,
				aim,
				Config.ATTACK_LUNGE_MAX_DISTANCE,
				Config.ATTACK_LUNGE_STOP_DISTANCE,
				Config.ATTACK_LUNGE_SPEED,
				function(finalAim: Vector3)
					runSwing(finalAim, targetBody, targetRadius, false)
				end,
				true,
				function(abortAim: Vector3, abortBody: BasePart?, abortRadius: number)
					didLunge = false
					runSwing(abortAim, abortBody, abortRadius, true)
				end
			)
			return
		end
	end

	runSwing(aim, targetBody, targetRadius, true)
end

local function releaseHeavyAttack()
	chargingHeavy = false
	attackHeld = false
	chargeToken += 1
	Effects.stopCharge()

	if
		player:GetAttribute("Grabbed") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
		or os.clock() < knockbackEndsAt
	then
		Remotes.HeavyCharge:FireServer(false)
		return
	end
	local root, humanoid = body()
	if not root or not humanoid then
		Remotes.HeavyCharge:FireServer(false)
		return
	end

	local clock = os.clock()
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	if not facing or not fallbackFacing then
		Remotes.HeavyCharge:FireServer(false)
		return
	end

	local pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
	local aim = if pick then pick.direction else facing
	local targetRadius = if pick then pick.radius else 0
	local currentClass = classId()
	local ranged = Classes.isRanged(currentClass)

	comboStep = 0
	bufferedAction = nil
	heavyReadyAt = now() + Config.HEAVY_ATTACK_COOLDOWN
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)

	local function runHeavy(heavyAim: Vector3, heavyTarget: BasePart?, heavyRadius: number, allowStep: boolean)
		local windupDur = if allowStep
			then Config.HEAVY_ATTACK_STARTUP_SECONDS
			else Config.ATTACK_POST_LUNGE_SETTLE_SECONDS
		beginMeleeStartup(
			root,
			heavyAim,
			windupDur,
			Config.HEAVY_ATTACK_STEP_DISTANCE,
			heavyTarget,
			heavyRadius,
			allowStep and not ranged,
			function(startedAt: number)
				lastSwingAt = startedAt
				recordAction("heavyAttack", nil, startedAt, windupDur, true, heavyAim)
			end,
			function(finalAim: Vector3)
				local doneClock = os.clock()
				if heavyTarget and heavyTarget:IsDescendantOf(workspace) then
					lastEngageAt = doneClock
				end
				if activeAction then
					activeAction.aimDir = finalAim
				end
				Effects.heavyAttack(root, finalAim, currentClass, true)
				Remotes.HeavyAttack:FireServer(finalAim)
			end
		)
	end

	if not ranged and pick and targetBody and clock >= dashEndsAt then
		startTrackedLunge(
			root,
			targetBody,
			targetRadius,
			aim,
			Config.HEAVY_ATTACK_LUNGE_MAX_DISTANCE,
			Config.ATTACK_LUNGE_STOP_DISTANCE,
			Config.ATTACK_LUNGE_SPEED,
			function(finalAim: Vector3)
				runHeavy(finalAim, targetBody, targetRadius, false)
			end,
			true,
			function(abortAim: Vector3, abortBody: BasePart?, abortRadius: number)
				runHeavy(abortAim, abortBody, abortRadius, true)
			end
		)
	else
		runHeavy(aim, targetBody, targetRadius, not ranged)
	end
end

local function beginAttackHold()
	if attackHeld or isChoosingClass() then
		return
	end
	attack()
	if
		player:GetAttribute("Grabbed") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
		or os.clock() < knockbackEndsAt
	then
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
	-- into Heavy Charge once any in-flight lunge/swing reaches cancelAt, and auto-fires at 2 s.
	local function enterCharge()
		if chargeToken ~= myToken or not attackHeld then
			return
		end
		if
			player:GetAttribute("Grabbed") == true
			or blocking
			or player:GetAttribute("Blocking") == true
			or isStunned()
			or os.clock() < knockbackEndsAt
		then
			cancelHeavyCharge(false)
			return
		end
		local currentRoot = body()
		if not currentRoot or not ready(heavyReadyAt, "HeavyReadyAt") then
			cancelHeavyCharge(false)
			return
		end
		local clock = os.clock()
		if activeLunge or (activeAction and clock < activeAction.baseCancelAt) then
			task.delay(0.03, enterCharge)
			return
		end

		chargingHeavy = true
		activeAction = nil
		bufferedAction = nil
		Effects.startCharge(currentRoot, classId())
		Remotes.HeavyCharge:FireServer(true)

		local chargeMultAttr = player:GetAttribute("UpgradeHeavyChargeMult")
		local chargeMult = if type(chargeMultAttr) == "number" and chargeMultAttr > 0
			then math.max(chargeMultAttr, Config.MIN_HEAVY_CHARGE_MULT or 0.45)
			else 1
		local remaining = math.max(Config.HEAVY_CHARGE_SECONDS * chargeMult - Config.HEAVY_CHARGE_DELAY, 0)
		task.delay(remaining, function()
			if chargeToken ~= myToken or not chargingHeavy then
				return
			end
			releaseHeavyAttack()
		end)
	end

	task.delay(Config.HEAVY_CHARGE_DELAY, enterCharge)
end

local function dash()
	if isChoosingClass() or player:GetAttribute("Grabbed") == true or isStunned() or os.clock() < knockbackEndsAt then
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
	local maxCharges = Drops.maxDashCharges(player:GetAttribute("SpeedBuffUntil"), t, hasDoubleDash())
	local swiftMult = if player:GetAttribute("HasSwiftDash") == true then (Config.SWIFT_DASH_COOLDOWN_MULT or 0.75) else 1
	local dashCooldown = math.max(Config.DASH_COOLDOWN * cooldownMult() * swiftMult, 0.28)
	local allowed, nextCharges, nextRechargeAt =
		Drops.consumeDash(dashCharges, dashRechargeAt, maxCharges, t, dashCooldown, 0)
	if not allowed then
		return
	end
	local direction = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not direction then
		return
	end
	cancelHeavyCharge(true)
	clearAllMotion(true)
	activeAction = nil
	bufferedAction = nil
	parryCounterEndsAt = 0
	blocking = false
	dashCharges = nextCharges
	dashRechargeAt = nextRechargeAt
	lastDashAt = clock
	dashEndsAt = clock + Config.DASH_DURATION
	recordAction("dash", nil, clock, 0, false)

	-- Bounded-force horizontal dash monitored every Heartbeat: cancels cleanly on wall/pillar
	-- contact so slamming into an obstacle never flings the player upward or out of the room.
	dashToken += 1
	local myDashToken = dashToken
	local dashDist = Config.DASH_DISTANCE * (if player:GetAttribute("HasDashBoost") == true then (Config.DASH_BOOST_DISTANCE_MULT or 1.25) else 1)
	activeDash = startSafeVelocity(root, direction, dashDist / Config.DASH_DURATION)
	task.delay(Config.DASH_DURATION, function()
		if dashToken == myDashToken then
			clearDash(false)
		end
	end)

	root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
	syncMovementPolicy(humanoid, clock)
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
		or os.clock() < knockbackEndsAt
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(spinReadyAt, "SpinReadyAt") then
		return
	end
	local clock = os.clock()
	if not canStartOffensiveAction(clock, "spin") then
		return
	end
	cancelHeavyCharge(true)
	parryCounterEndsAt = 0
	-- Pick/keep the locked target and impulse right into sweet-spot range before unleashing Spin.
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	local pick: Melee.TargetPick? = nil
	local targetBody: BasePart? = nil
	if facing and fallbackFacing then
		pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
		lockedTarget = targetBody
		lastEngageAt = if targetBody then clock else -math.huge
	end
	local aim = if pick then pick.direction else facing
	if aim then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	end
	local _, slotLevel = abilitySlotInfo(AbilityStore.current())
	spinReadyAt = now() + effectiveCooldown(Config.SPIN_COOLDOWN, slotLevel)

	local function fireSpin()
		local spinClock = os.clock()
		if targetBody and targetBody:IsDescendantOf(workspace) then
			lastEngageAt = spinClock
		end
		recordAction("spin", nil, spinClock, 0, true, aim)
		Effects.spin(root)
		Remotes.Spin:FireServer()
	end

	if pick and targetBody and aim and clock >= dashEndsAt then
		startTrackedLunge(
			root,
			targetBody,
			pick.radius,
			aim,
			Config.SPIN_LUNGE_MAX_DISTANCE,
			Config.ATTACK_LUNGE_STOP_DISTANCE,
			Config.ATTACK_LUNGE_SPEED,
			function()
				fireSpin()
			end,
			true,
			function()
				fireSpin()
			end
		)
	else
		fireSpin()
	end
end

local function stinger()
	if
		player:GetAttribute("Grabbed") == true
		or player:GetAttribute("OverDriveCharging") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
		or os.clock() < knockbackEndsAt
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(stingerReadyAt, "StingerReadyAt") then
		return
	end
	local clock = os.clock()
	if not canStartOffensiveAction(clock, "stinger") then
		return
	end
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	if not facing or not fallbackFacing then
		return
	end
	local pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
	local aim = if pick then pick.direction else facing

	cancelHeavyCharge(true)
	clearAllMotion(false)
	parryCounterEndsAt = 0
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock + Config.STINGER_DURATION else -math.huge
	local _, slotLevel = abilitySlotInfo(AbilityStore.current())
	stingerReadyAt = now() + effectiveCooldown(Config.STINGER_COOLDOWN, slotLevel)
	dashEndsAt = clock + Config.STINGER_DURATION
	recordAction("stinger", nil, clock, 0, true, aim)

	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	syncMovementPolicy(humanoid, clock)
	Effects.stinger(root, aim, true)
	Remotes.Stinger:FireServer(aim)

	-- Explosive horizontal piercing thrust (DMC Stinger): brakes cleanly right in sweet-spot
	-- range before a locked target so recovery can cancel straight into combos/skills, or travels
	-- full distance when untargeted.
	local stingerSpeed = Config.STINGER_DISTANCE / math.max(Config.STINGER_DURATION, 0.05)
	startTrackedLunge(
		root,
		targetBody,
		if pick then pick.radius else 0,
		aim,
		Config.STINGER_DISTANCE,
		Config.STINGER_STOP_DISTANCE,
		stingerSpeed,
		function()
			dashEndsAt = os.clock()
			if targetBody and targetBody:IsDescendantOf(workspace) then
				lastEngageAt = os.clock()
			end
		end,
		false
	)
end

local function overDrive()
	if
		player:GetAttribute("Grabbed") == true
		or player:GetAttribute("OverDriveCharging") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
		or os.clock() < knockbackEndsAt
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(overDriveReadyAt, "OverDriveReadyAt") then
		return
	end
	local clock = os.clock()
	if not canStartOffensiveAction(clock, "overDrive") then
		return
	end
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	if not facing or not fallbackFacing then
		return
	end
	local pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
	local aim = if pick then pick.direction else facing

	cancelHeavyCharge(true)
	clearAllMotion(true)
	parryCounterEndsAt = 0
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	local _, slotLevel = abilitySlotInfo(AbilityStore.current())
	overDriveReadyAt = now() + effectiveCooldown(Config.OVERDRIVE_COOLDOWN, slotLevel)

	local waveSpec = Config.ANIMATIONS.overdriveWave
	local finalWaveAt = clock + Config.OVERDRIVE_CHARGE_SECONDS + Config.OVERDRIVE_WAVE_INTERVAL * (Config.OVERDRIVE_WAVES - 1)
	local baseCancelAt = finalWaveAt + waveSpec.cancelAt
	activeAction = {
		key = "overdriveWave",
		startedAt = clock,
		activeAt = clock + Config.OVERDRIVE_CHARGE_SECONDS,
		baseCancelAt = baseCancelAt,
		cancelAt = baseCancelAt,
		moveCancelAt = baseCancelAt + Config.ATTACK_MOVE_CANCEL_OFFSET,
		endsAt = finalWaveAt + waveSpec.duration,
		hitConfirmed = true,
		hitstopEndsAt = 0,
		isMeleeSwing = false,
		aimDir = aim,
	}

	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	Remotes.OverDrive:FireServer(aim)
end

local CLASS_ABILITY_ANIM: { [string]: { action: string, step: number? } } = {
	taunt = { action = "taunt" },
	bulwark = { action = "bulwark" },
	execute = { action = "attack", step = Config.COMBO_HITS },
	healPulse = { action = "healPulse" },
	protectField = { action = "protectField" },
	shockwave = { action = "shockwave" },
}

-- Every ability that came with the classes: now unified with the combat state machine so it
-- respects input buffering, clears active lunges/steps, locks MoveDir during commit, and enters
-- cancelable recovery cleanly.
local function castClassAbility(abilityId: string)
	local ability = Config.ABILITIES[abilityId]
	if
		not ability
		or player:GetAttribute("Grabbed") == true
		or player:GetAttribute("OverDriveCharging") == true
		or blocking
		or player:GetAttribute("Blocking") == true
		or isStunned()
		or os.clock() < knockbackEndsAt
	then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(classAbilityReadyAt[abilityId] or 0, ability.readyAttribute) then
		return
	end
	local clock = os.clock()
	if not canStartOffensiveAction(clock, abilityId) then
		return
	end
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	if not facing or not fallbackFacing then
		return
	end
	local pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
	local aim = if pick then pick.direction else facing

	cancelHeavyCharge(true)
	clearAllMotion(true)
	parryCounterEndsAt = 0
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	local _, slotLevel = abilitySlotInfo(AbilityStore.current())
	classAbilityReadyAt[abilityId] = now() + effectiveCooldown(ability.cooldown, slotLevel)
	local animInfo = CLASS_ABILITY_ANIM[abilityId]
	if animInfo then
		recordAction(animInfo.action, animInfo.step, clock, 0, false, aim)
	else
		recordAction(abilityId, nil, clock, 0, false, aim)
	end
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	syncMovementPolicy(humanoid, clock)
	Effects.classAbilityLocal(abilityId)
	Remotes.UseAbility:FireServer(abilityId, aim)
end

local function selectAbilitySlot(slot: number)
	AbilityStore.select(slot)
end

-- The selected slot's ability from the player's drafted run slots (`AbilitySlot1..3`).
local function useActiveAbility()
	if isChoosingClass() then
		return
	end
	local abilityId = abilitySlotInfo(AbilityStore.current())
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
			or os.clock() < knockbackEndsAt
		then
			return
		end
		local root, humanoid = body()
		if not root or not humanoid or not ready(blockReadyAt, "BlockReadyAt") then
			return
		end
		cancelHeavyCharge(true)
		clearAllMotion(true)
		activeAction = nil
		bufferedAction = nil
		parryCounterEndsAt = 0
		blocking = true
		syncMovementPolicy(humanoid, os.clock())
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

-- Called by `Knockback.luau` right before applying a fling so no active lunge, dash, step,
-- startup, charge, or buffer competes with Knockback's LinearVelocity.
function CombatInput.beginKnockback(duration: number)
	cancelHeavyCharge(false)
	clearAllMotion(false)
	blocking = false
	activeAction = nil
	bufferedAction = nil
	parryCounterEndsAt = 0
	lockedTarget = nil
	Effects.updateLockIndicator(nil)
	knockbackEndsAt = os.clock() + math.max(duration, 0)
end

function CombatInput.endKnockback()
	knockbackEndsAt = 0
end

function CombatInput.start(dependencies: { shake: ((number, number) -> ())? }?)
	shakeCamera = if dependencies then dependencies.shake else nil
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

	-- Clear local charge visuals and ALL active motion immediately on Grab, Stun, or heavy-hit
	-- server charge cancellation.
	player:GetAttributeChangedSignal("ChargingHeavy"):Connect(function()
		if player:GetAttribute("ChargingHeavy") ~= true and chargingHeavy then
			cancelHeavyCharge(false)
		end
	end)
	player:GetAttributeChangedSignal("Grabbed"):Connect(function()
		if player:GetAttribute("Grabbed") == true then
			cancelHeavyCharge(false)
			clearAllMotion(true)
			blocking = false
			activeAction = nil
			bufferedAction = nil
			parryCounterEndsAt = 0
			lockedTarget = nil
			Effects.updateLockIndicator(nil)
		end
	end)
	player:GetAttributeChangedSignal("StunnedUntil"):Connect(function()
		if isStunned() then
			cancelHeavyCharge(false)
			clearAllMotion(true)
			blocking = false
			activeAction = nil
			bufferedAction = nil
			parryCounterEndsAt = 0
			lockedTarget = nil
			Effects.updateLockIndicator(nil)
		end
	end)

	-- Server-confirmed impact feedback: hitstop freeze, hit-confirm cancelAt upgrade, kill
	-- auto-retargeting, parry counter window, and Paso Fantasma unparried flinch interrupt.
	Remotes.CombatVfx.OnClientEvent:Connect(function(kind: string, arg1: any, arg2: any, arg3: any, arg4: any)
		if kind == "hitConfirm" then
			local tier: CombatState.HitTier = if arg1 == "heavy" or arg1 == "medium" then arg1 else "light"
			local hitPos = if typeof(arg2) == "Vector3" then arg2 else nil
			local anyKilled = arg3 == true
			local allArmored = arg4 == true
			local duration, shake = CombatState.hitstopSpec(tier, allArmored)
			local firstImpact = not (activeAction and activeAction.hitConfirmed)
			if hitPos then
				Effects.hitSpark(hitPos, tier, allArmored)
			end
			if firstImpact then
				PlayerAnimator.hitstop(duration)
				if shakeCamera then
					shakeCamera(shake, duration + 0.06)
				end
			end
			if activeAction then
				activeAction.hitConfirmed = true
				activeAction.cancelAt = CombatState.effectiveCancelAt(activeAction.baseCancelAt, true)
				activeAction.moveCancelAt = activeAction.cancelAt + Config.ATTACK_MOVE_CANCEL_OFFSET
				if firstImpact then
					activeAction.hitstopEndsAt = math.max(activeAction.hitstopEndsAt, os.clock() + duration)
				end
			end
			if anyKilled and (not lockedTarget or not lockedTarget:IsDescendantOf(workspace)) then
				lockedTarget = nil
				Effects.updateLockIndicator(nil)
			end
		elseif kind == "parryConfirm" then
			local clock = os.clock()
			parryCounterCancelAt = clock + Config.PARRY_COUNTER_CANCEL_AT
			parryCounterEndsAt = clock + Config.ANIMATIONS.parry.duration
			if shakeCamera then
				shakeCamera(0.6, 0.1)
			end
		elseif kind == "parryOnlyHit" then
			cancelHeavyCharge(false)
			clearAllMotion(true)
			activeAction = nil
			bufferedAction = nil
		end
	end)

	-- Grant bonus dash charges immediately when picking up a Speed Buff drop or Double Dash passive,
	-- and clamp downward cleanly when a temporary buff expires or a fresh run resets passives.
	local function syncBonusDashCharges()
		local t = now()
		local maxCharges = Drops.maxDashCharges(player:GetAttribute("SpeedBuffUntil"), t, hasDoubleDash())
		if maxCharges >= 2 and dashCharges < maxCharges then
			dashCharges = maxCharges
			dashRechargeAt = 0
		elseif dashCharges > maxCharges then
			dashCharges = maxCharges
		end
	end
	player:GetAttributeChangedSignal("SpeedBuffUntil"):Connect(syncBonusDashCharges)
	player:GetAttributeChangedSignal("HasDoubleDash"):Connect(syncBonusDashCharges)

	-- Auto-focus a newly drafted ability slot whenever the currently selected slot is empty, and
	-- clear any stale local cooldown for a freshly equipped/replaced ability.
	local function onAbilitySlotChanged(slot: number)
		local id = player:GetAttribute(`AbilitySlot{slot}`)
		if type(id) == "string" and id ~= "" then
			if id == "spin" then
				spinReadyAt = 0
			elseif id == "stinger" then
				stingerReadyAt = 0
			elseif id == "overdrive" then
				overDriveReadyAt = 0
			else
				classAbilityReadyAt[id] = nil
			end
			if abilitySlotInfo(AbilityStore.current()) == nil then
				AbilityStore.select(slot)
			end
		end
	end
	for slot = 1, Config.ABILITY_SLOTS do
		player:GetAttributeChangedSignal(`AbilitySlot{slot}`):Connect(function()
			onAbilitySlotChanged(slot)
		end)
	end

	-- Double Jump passive (plans/roadmap.md VS-19): one crisp mid-air jump per ground touch on
	-- Space, mobile Jump button, and gamepad ButtonA via UserInputService.JumpRequest.
	local airJumpUsed = false
	local lastGroundJumpAt = -math.huge
	local jumpStateConn: RBXScriptConnection? = nil

	local function trackCharacterJump(character: Model)
		if jumpStateConn then
			jumpStateConn:Disconnect()
			jumpStateConn = nil
		end
		airJumpUsed = false
		lastGroundJumpAt = -math.huge
		local humanoid = character:WaitForChild("Humanoid", 5)
		if not humanoid or not humanoid:IsA("Humanoid") then
			return
		end
		jumpStateConn = humanoid.StateChanged:Connect(function(_old, newState)
			if newState == Enum.HumanoidStateType.Jumping then
				if not airJumpUsed then
					lastGroundJumpAt = os.clock()
				end
			elseif
				newState == Enum.HumanoidStateType.Landed
				or newState == Enum.HumanoidStateType.Running
				or newState == Enum.HumanoidStateType.RunningNoPhysics
				or newState == Enum.HumanoidStateType.Climbing
				or newState == Enum.HumanoidStateType.Swimming
				or newState == Enum.HumanoidStateType.Seated
			then
				airJumpUsed = false
			end
		end)
	end

	if player.Character then
		task.spawn(trackCharacterJump, player.Character)
	end

	UserInputService.JumpRequest:Connect(function()
		if
			player:GetAttribute("HasDoubleJump") ~= true
			or airJumpUsed
			or isChoosingClass()
			or player:GetAttribute("Grabbed") == true
			or isStunned()
		then
			return
		end
		local root, humanoid = body()
		if not root or not humanoid then
			return
		end
		local state = humanoid:GetState()
		local airborne = state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping
		if not airborne or os.clock() - lastGroundJumpAt < 0.14 then
			return
		end
		airJumpUsed = true
		local vel = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(vel.X, Config.DOUBLE_JUMP_POWER, vel.Z)
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		Effects.doubleJump(root)
	end)

	-- Per-frame wall-stop guard for active dashes/lunges + hard arena bounds safety clamp so
	-- no physics spike can ever fling the player onto a structure or outside the room.
	RunService.Heartbeat:Connect(function(dt: number)
		local root, humanoid = body()
		if not root or not humanoid then
			return
		end

		local safeDt = math.min(dt, 1 / 30)
		local grounded = humanoid:GetState() == Enum.HumanoidStateType.Running
		if activeDash then
			local checkDist = math.clamp(activeDash.speed * safeDt * 1.15, 1.2, 2.6)
			if activeDash.root ~= root or hitsWallAhead(root, activeDash.direction, checkDist) then
				dashToken += 1
				clearDash(true)
			elseif grounded and root.AssemblyLinearVelocity.Y > 6 then
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
			end
		end

		if activeLunge then
			local checkDist = math.clamp(activeLunge.speed * safeDt * 1.15, 1.2, 2.6)
			local onWall = activeLunge.onWall
			if activeLunge.root == root and onWall and hitsWallAhead(root, activeLunge.direction, checkDist) then
				onWall()
			elseif activeLunge.root ~= root or hitsWallAhead(root, activeLunge.direction, checkDist) then
				lungeToken += 1
				clearLunge(true)
			elseif grounded and root.AssemblyLinearVelocity.Y > 6 then
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
			end
		end

		if activeStep then
			local checkDist = math.clamp(activeStep.speed * safeDt * 1.15, 1.2, 2.2)
			if activeStep.root ~= root or hitsWallAhead(root, activeStep.direction, checkDist) then
				stepToken += 1
				clearStep(true)
			end
		end

		-- Arena/Hub bounds safety net: if a physics glitch ever pushes the character past the room
		-- perimeter or above/below the floor shell, pull them cleanly back inside.
		local world = workspace:FindFirstChild("World")
		local inHub = world ~= nil and world:GetAttribute("ServerMode") == "hub"
		local activeSize = if inHub then Config.HUB_ROOM_SIZE else Config.ROOM_SIZE
		local halfX = activeSize.X / 2 - 1.5
		local halfZ = activeSize.Y / 2 - 1.5
		local pos = root.Position
		if math.abs(pos.X) > halfX or math.abs(pos.Z) > halfZ or pos.Y > 33 or pos.Y < -4 then
			local clamped = Waves.clamp(pos, activeSize, 3.5)
			local safe = if inHub
				then clamped
				else Waves.avoidObstacles(clamped, 2.8, Config.getArenaObstacles(world and world:GetAttribute("ArenaModel")))
			local safeY = math.clamp(pos.Y, 3.5, 22)
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = CFrame.new(safe.X, safeY, safe.Z) * root.CFrame.Rotation
		end
	end)

	-- Per-frame DMC combat loop: fires buffered recovery-cancels on frame 1 of recovery, maintains
	-- or breaks the soft target lock based on directional input, gently tracks small target recoil
	-- to stay in sweet-spot range, and updates the lock-on ground ring.
	local wallRayParams = RaycastParams.new()
	wallRayParams.FilterType = Enum.RaycastFilterType.Exclude

	RunService.RenderStepped:Connect(function(dt: number)
		local clock = os.clock()
		if parryCounterEndsAt > 0 and clock >= parryCounterEndsAt then
			parryCounterEndsAt = 0
		end

		local root, humanoid = body()
		if not root or not humanoid then
			if activeAction and clock >= activeAction.endsAt then
				activeAction = nil
			end
			bufferedAction = nil
			lockedTarget = nil
			Effects.updateLockIndicator(nil)
			return
		end

		if player:GetAttribute("Grabbed") == true or isStunned() or clock < knockbackEndsAt then
			if activeAction and clock >= activeAction.endsAt then
				activeAction = nil
			end
			bufferedAction = nil
			lockedTarget = nil
			syncMovementPolicy(humanoid, clock, false)
			Effects.updateLockIndicator(nil)
			return
		end

		-- 1. Fire any buffered attack or ability BEFORE expiring activeAction or unlocking
		-- WalkSpeed/AutoRotate so combo transitions never leak a single frame of locomotion.
		if bufferedAction then
			if clock > bufferedAction.expiresAt then
				bufferedAction = nil
			elseif
				not activeLunge
				and (clock >= parryCounterCancelAt or parryCounterEndsAt == 0)
				and (not activeAction or clock >= activeAction.cancelAt)
			then
				local kind = bufferedAction.kind
				local canFire = true
				if kind == "attack" then
					local minInterval = Melee.attackInterval(
						comboStep,
						Config.COMBO_HITS,
						Config.ATTACK_INTERVAL,
						Config.ATTACK_FINISHER_INTERVAL
					)
					canFire = clock - lastSwingAt >= minInterval
				end
				if canFire then
					local bufferedAbilityId = bufferedAction.abilityId
					bufferedAction = nil
					if kind == "attack" then
						attack()
					elseif kind == "spin" then
						spin()
					elseif kind == "stinger" then
						stinger()
					elseif kind == "overDrive" then
						overDrive()
					elseif kind == "ability" and bufferedAbilityId then
						castClassAbility(bufferedAbilityId)
					elseif Config.ABILITIES[kind] then
						castClassAbility(kind)
					end
				end
			end
		end

		-- 2. Only expire Recovery cleanly once it completes with no buffered move chaining out.
		if activeAction and clock >= activeAction.endsAt then
			activeAction = nil
		end

		local moveDirNow = Melee.flat(humanoid.MoveDirection)
		local brokeLockThisFrame = false

		-- 3. Soft target lock check: stay locked on neutral or general-direction input (<=60 deg),
		-- drop immediately when steering outside TARGET_LOCK_CONE.
		if lockedTarget then
			local lockTimedOut = activeAction == nil and (clock - lastEngageAt > Config.TARGET_LOCK_DURATION)
			if lockTimedOut or not lockedTarget:IsDescendantOf(workspace) then
				lockedTarget = nil
			else
				local targetRadius = math.max(lockedTarget.Size.X, lockedTarget.Size.Z) * 0.5
				if
					not activeLunge
					and not Melee.shouldKeepLock(
						root.Position,
						lockedTarget.Position,
						targetRadius,
						moveDirNow,
						Config.TARGET_LOCK_BREAK_RANGE,
						Config.TARGET_LOCK_CONE
					)
				then
					lockedTarget = nil
					brokeLockThisFrame = moveDirNow ~= nil
				end
			end
		end

		-- 4. Recovery move-cancel: ONLY an opposite/break direction (outside TARGET_LOCK_CONE of
		-- the locked enemy or swing aim) with NO buffered move unlocks WalkSpeed/AutoRotate early.
		-- Neutral or toward-target input stays 100% locked until Recovery ends or next hit chains.
		local phaseNow = currentPhase(clock)
		if activeAction and phaseNow == "recovery" and moveDirNow ~= nil then
			local steeringAway = false
			if brokeLockThisFrame then
				steeringAway = true
			elseif not lockedTarget then
				steeringAway = CombatState.isSteeringAway(activeAction.aimDir, moveDirNow, Config.TARGET_LOCK_CONE)
			end
			if CombatState.canMoveCancel(phaseNow, clock, activeAction.moveCancelAt, steeringAway, bufferedAction ~= nil) then
				activeAction = nil
				PlayerAnimator.cancelRecovery()
				phaseNow = currentPhase(clock)
			end
		end

		-- 5. Enforce WalkSpeed & AutoRotate for the resolved phase.
		syncMovementPolicy(humanoid, clock, false)

		-- 6. Gentle aerial fall damping during active melee swings so mid-air slashes stay level.
		if
			(phaseNow == "startup" or phaseNow == "active" or phaseNow == "hitstop")
			and humanoid:GetState() == Enum.HumanoidStateType.Freefall
		then
			local v = root.AssemblyLinearVelocity
			if v.Y < -Config.AIR_ATTACK_MAX_FALL_SPEED then
				root.AssemblyLinearVelocity = Vector3.new(v.X, -Config.AIR_ATTACK_MAX_FALL_SPEED, v.Z)
			end
		end

		-- 7. Continuous target-facing rotation while locked (neutral or general direction of enemy)
		-- across Startup, Active, Hitstop, and Recovery — plus gentle magnetic follow in Recovery
		-- so follow-up combo hits always rotate cleanly onto the enemy without WalkSpeed interference.
		if
			lockedTarget
			and lockedTarget:IsDescendantOf(workspace)
			and not activeLunge
			and clock >= dashEndsAt
			and not blocking
			and player:GetAttribute("Blocking") ~= true
			and (activeAction ~= nil or clock - lastEngageAt <= Config.COMBO_WINDOW)
		then
			local toTarget = Vector3.new(
				lockedTarget.Position.X - root.Position.X,
				0,
				lockedTarget.Position.Z - root.Position.Z
			)
			local dist = toTarget.Magnitude
			if dist > 1e-3 then
				local dir = toTarget / dist
				local nextPos = root.Position
				if phaseNow == "recovery" and not activeStep and not Classes.isRanged(classId()) then
					local targetRadius = math.max(lockedTarget.Size.X, lockedTarget.Size.Z) * 0.5
					local sweetSpot = targetRadius + Config.ATTACK_LUNGE_STOP_DISTANCE
					if dist > sweetSpot + 0.35 and dist <= sweetSpot + Config.TARGET_LOCK_MAGNET_RANGE then
						local stepDist = math.min(dist - sweetSpot, Config.TARGET_LOCK_MAGNET_SPEED * dt)
						local character = player.Character
						local world = workspace:FindFirstChild("World")
						local enemiesFolder = world and world:FindFirstChild("Enemies")
						local exclude: { Instance } = {}
						if character then
							table.insert(exclude, character)
						end
						if enemiesFolder then
							table.insert(exclude, enemiesFolder)
						end
						wallRayParams.FilterDescendantsInstances = exclude
						if not workspace:Raycast(root.Position, dir * (stepDist + 1.2), wallRayParams) then
							nextPos = root.Position + dir * stepDist
						end
					end
				end
				root.CFrame = CFrame.lookAt(nextPos, nextPos + dir)
				if activeStep and activeStep.root == root then
					activeStep.direction = dir
					activeStep.velocity.LineDirection = dir
				end
			end
		end

		Effects.updateLockIndicator(lockedTarget)
	end)

	local function resetLocalCombatState(resetSlot: boolean)
		cancelHeavyCharge(false)
		clearAllMotion(false)
		dashEndsAt = 0
		knockbackEndsAt = 0
		parryCounterEndsAt = 0
		parryCounterCancelAt = 0
		activeAction = nil
		bufferedAction = nil
		lockedTarget = nil
		Effects.updateLockIndicator(nil)
		lastEngageAt = -math.huge
		comboStep = 0
		lastSwingAt = -math.huge
		dashCharges = Drops.maxDashCharges(nil, now(), hasDoubleDash())
		dashRechargeAt = 0
		lastDashAt = -math.huge
		spinReadyAt = 0
		stingerReadyAt = 0
		overDriveReadyAt = 0
		table.clear(classAbilityReadyAt)
		blockReadyAt = 0
		heavyReadyAt = 0
		blocking = false
		if resetSlot then
			AbilityStore.reset()
		end
	end

	-- A fresh run or retry resets local predicted cooldowns & active slot even when the character
	-- stays alive (e.g. RetryRun after Victory in Room 5 does not trigger CharacterAdded).
	task.spawn(function()
		local world = workspace:WaitForChild("World")
		world:GetAttributeChangedSignal("RunStartedAt"):Connect(function()
			local startedAt = world:GetAttribute("RunStartedAt")
			if type(startedAt) == "number" and startedAt > 0 then
				resetLocalCombatState(true)
			end
		end)
	end)

	-- A respawn is a fresh start: no combo carried over, nothing predicted from the last life.
	player.CharacterAdded:Connect(function(character)
		task.spawn(trackCharacterJump, character)
		resetLocalCombatState(false)
	end)
end

return CombatInput
