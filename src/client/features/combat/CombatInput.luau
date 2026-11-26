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
local CombatAnim = require(Shared.features.combat.CombatAnim)
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

-- Active attack/skill lunge state; gated on `lungeToken` so a dash, block, or respawn cancels
-- any in-flight step-in cleanly without firing a stale swing or leaving residual slide velocity.
local lungeToken = 0
local activeLunge: ActiveMove? = nil
local dashEndsAt = 0

-- Active offensive animation recovery & input buffer (DMC-style cancel window): once `clock >=
-- activeAction.cancelAt`, any other attack or ability cancels recovery cleanly into the next move.
type ActiveAction = {
	key: string,
	startedAt: number,
	cancelAt: number,
	endsAt: number,
}
type BufferedKind = "attack" | "spin" | "stinger" | "overDrive"
local activeAction: ActiveAction? = nil
local bufferedAction: { kind: BufferedKind, expiresAt: number }? = nil

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

local function recordAction(actionName: string, step: number?, startedAt: number)
	local key = CombatAnim.specKey(actionName, step)
	local spec = Config.ANIMATIONS[key]
	if not spec then
		return
	end
	activeAction = {
		key = key,
		startedAt = startedAt,
		cancelAt = startedAt + spec.cancelAt,
		endsAt = startedAt + spec.duration,
	}
end

local function canStartOffensiveAction(clock: number, kind: BufferedKind): boolean
	if activeLunge then
		bufferedAction = { kind = kind, expiresAt = clock + Config.COMBO_INPUT_BUFFER }
		return false
	end
	if activeAction and clock < activeAction.cancelAt then
		if activeAction.cancelAt - clock <= Config.COMBO_INPUT_BUFFER then
			bufferedAction = { kind = kind, expiresAt = activeAction.cancelAt + 0.08 }
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

-- Tracks a horizontal `LinearVelocity` impulse toward `targetBody` (or along `aim` if untargeted)
-- on `RenderStepped`, braking and zeroing horizontal velocity the exact frame the player enters
-- sweet-spot range (`targetRadius + stopDist`) so attacks & skills never overshoot past the target.
local function startTrackedLunge(
	root: BasePart,
	targetBody: BasePart?,
	targetRadius: number,
	aim: Vector3,
	maxDist: number,
	stopDist: number,
	speed: number,
	onComplete: (Vector3) -> ()
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

	local function finish(currentAim: Vector3)
		clearLunge(true)
		local finalAim = currentAim
		if targetBody and targetBody:IsDescendantOf(workspace) then
			finalAim = Melee.flat(targetBody.Position - root.Position) or currentAim
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
		local currentRoot = body()
		if currentRoot ~= root then
			clearLunge()
			return
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
			-- Half-frame lookahead brakes just before the sweet spot rather than one frame past it.
			local lookahead = speed * math.min(dt, 0.033) * 0.5
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
		clearLunge(true)
		Effects.attackWindup(1)
		Remotes.GrabEscape:FireServer()
		return
	end
	if
		blocking
		or player:GetAttribute("Blocking") == true
		or player:GetAttribute("OverDriveCharging") == true
		or isStunned()
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
	local ranged = Classes.isRanged(classId())

	comboStep = Melee.nextStep(comboStep, lastSwingAt, clock, Config.COMBO_HITS, Config.COMBO_WINDOW)
	local step = comboStep
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)

	local didLunge = false
	local function fireSwing(finalAim: Vector3)
		local swingClock = os.clock()
		lastSwingAt = swingClock
		if targetBody and targetBody:IsDescendantOf(workspace) then
			lastEngageAt = swingClock
		end
		recordAction("attack", step, swingClock)
		if ranged then
			Effects.staffAttack(root, finalAim, step)
		else
			Effects.slash(root, finalAim, step, didLunge)
		end
		Remotes.Attack:FireServer(finalAim)
	end

	-- Ranged Support casts from where it stands; only melee classes step in.
	if not ranged and pick and targetBody and clock >= dashEndsAt then
		local dist = Melee.distance(root.Position, targetBody.Position)
		local willLunge = Melee.lungeDistance(
			dist,
			pick.radius,
			Config.ATTACK_LUNGE_STOP_DISTANCE,
			Config.ATTACK_LUNGE_MAX_DISTANCE
		) > 0.15
		if willLunge then
			didLunge = true
			Effects.attackWindup(step)
			startTrackedLunge(
				root,
				targetBody,
				pick.radius,
				aim,
				Config.ATTACK_LUNGE_MAX_DISTANCE,
				Config.ATTACK_LUNGE_STOP_DISTANCE,
				Config.ATTACK_LUNGE_SPEED,
				fireSwing
			)
			return
		end
	end

	fireSwing(aim)
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
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	if not facing or not fallbackFacing then
		Remotes.HeavyCharge:FireServer(false)
		return
	end

	local pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
	local aim = if pick then pick.direction else facing
	local currentClass = classId()
	local ranged = Classes.isRanged(currentClass)

	comboStep = 0
	bufferedAction = nil
	heavyReadyAt = now() + Config.HEAVY_ATTACK_COOLDOWN
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)

	local function fireHeavy(finalAim: Vector3)
		local doneClock = os.clock()
		lastSwingAt = doneClock
		if targetBody and targetBody:IsDescendantOf(workspace) then
			lastEngageAt = doneClock
		end
		recordAction("heavyAttack", nil, doneClock)
		Effects.heavyAttack(root, finalAim, currentClass, true)
		Remotes.HeavyAttack:FireServer(finalAim)
	end

	if not ranged and pick and targetBody and clock >= dashEndsAt then
		startTrackedLunge(
			root,
			targetBody,
			pick.radius,
			aim,
			Config.HEAVY_ATTACK_LUNGE_MAX_DISTANCE,
			Config.ATTACK_LUNGE_STOP_DISTANCE,
			Config.ATTACK_LUNGE_SPEED,
			fireHeavy
		)
	else
		fireHeavy(aim)
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
	clearLunge(true)
	clearDash()
	activeAction = nil
	bufferedAction = nil
	blocking = false
	dashCharges = nextCharges
	dashRechargeAt = nextRechargeAt
	lastDashAt = clock
	dashEndsAt = clock + Config.DASH_DURATION
	recordAction("dash", nil, clock)

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
	local clock = os.clock()
	if not canStartOffensiveAction(clock, "spin") then
		return
	end
	cancelHeavyCharge(true)
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
	spinReadyAt = now() + Config.SPIN_COOLDOWN

	local function fireSpin()
		local spinClock = os.clock()
		if targetBody and targetBody:IsDescendantOf(workspace) then
			lastEngageAt = spinClock
		end
		recordAction("spin", nil, spinClock)
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
	lungeToken += 1
	clearLunge()
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock + Config.STINGER_DURATION else -math.huge
	stingerReadyAt = now() + Config.STINGER_COOLDOWN
	dashEndsAt = clock + Config.STINGER_DURATION
	recordAction("stinger", nil, clock)

	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
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
		end
	)
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
	lungeToken += 1
	clearLunge(true)
	lockedTarget = targetBody
	lastEngageAt = if targetBody then clock else -math.huge
	overDriveReadyAt = now() + Config.OVERDRIVE_COOLDOWN

	local waveSpec = Config.ANIMATIONS.overdriveWave
	local finalWaveAt = clock + Config.OVERDRIVE_CHARGE_SECONDS + Config.OVERDRIVE_WAVE_INTERVAL * (Config.OVERDRIVE_WAVES - 1)
	activeAction = {
		key = "overdriveWave",
		startedAt = clock,
		cancelAt = finalWaveAt + waveSpec.cancelAt,
		endsAt = finalWaveAt + waveSpec.duration,
	}

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
	local moveDir = Melee.flat(humanoid.MoveDirection)
	local fallbackFacing = Melee.flat(root.CFrame.LookVector)
	local facing = moveDir or fallbackFacing
	if not facing or not fallbackFacing then
		return
	end
	local pick, targetBody = selectTarget(root, moveDir, fallbackFacing, clock)
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
		clearLunge(true)
		activeAction = nil
		bufferedAction = nil
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
			activeAction = nil
			bufferedAction = nil
			lockedTarget = nil
			Effects.updateLockIndicator(nil)
		end
	end)
	player:GetAttributeChangedSignal("StunnedUntil"):Connect(function()
		if isStunned() then
			cancelHeavyCharge(false)
			blocking = false
			lungeToken += 1
			clearLunge()
			activeAction = nil
			bufferedAction = nil
			lockedTarget = nil
			Effects.updateLockIndicator(nil)
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
			local onWall = activeLunge.onWall
			if activeLunge.root == root and onWall and hitsWallAhead(root, activeLunge.direction, checkDist) then
				onWall()
			elseif activeLunge.root ~= root or hitsWallAhead(root, activeLunge.direction, checkDist) then
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

	-- Per-frame DMC combat loop: fires buffered recovery-cancels on frame 1 of recovery, maintains
	-- or breaks the soft target lock based on directional input, gently tracks small target recoil
	-- to stay in sweet-spot range, and updates the lock-on ground ring.
	local wallRayParams = RaycastParams.new()
	wallRayParams.FilterType = Enum.RaycastFilterType.Exclude

	RunService.RenderStepped:Connect(function(dt: number)
		local clock = os.clock()
		if activeAction and clock >= activeAction.endsAt then
			activeAction = nil
		end

		local root, humanoid = body()
		if not root or not humanoid or player:GetAttribute("Grabbed") == true or isStunned() then
			bufferedAction = nil
			lockedTarget = nil
			Effects.updateLockIndicator(nil)
			return
		end

		-- Fire any buffered attack or ability on the exact frame recovery begins.
		if bufferedAction then
			if clock > bufferedAction.expiresAt then
				bufferedAction = nil
			elseif not activeLunge and (not activeAction or clock >= activeAction.cancelAt) then
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
					bufferedAction = nil
					if kind == "attack" then
						attack()
					elseif kind == "spin" then
						spin()
					elseif kind == "stinger" then
						stinger()
					elseif kind == "overDrive" then
						overDrive()
					end
				end
			end
		end

		-- Soft target lock maintenance: stay locked on neutral or general-direction input, drop
		-- immediately when pressing any other direction, and stay glued across small enemy recoil.
		if lockedTarget then
			local lockTimedOut = activeAction == nil and (clock - lastEngageAt > Config.TARGET_LOCK_DURATION)
			if lockTimedOut or not lockedTarget:IsDescendantOf(workspace) then
				lockedTarget = nil
			else
				local targetRadius = math.max(lockedTarget.Size.X, lockedTarget.Size.Z) * 0.5
				local moveDir = Melee.flat(humanoid.MoveDirection)
				if
					not activeLunge
					and not Melee.shouldKeepLock(
						root.Position,
						lockedTarget.Position,
						targetRadius,
						moveDir,
						Config.TARGET_LOCK_BREAK_RANGE,
						Config.TARGET_LOCK_CONE
					)
				then
					lockedTarget = nil
				elseif
					not activeLunge
					and clock >= dashEndsAt
					-- Ranged Support keeps its distance; the magnet would walk it into melee range.
					and not Classes.isRanged(classId())
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
						local sweetSpot = targetRadius + Config.ATTACK_LUNGE_STOP_DISTANCE
						local nextPos = root.Position
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
						root.CFrame = CFrame.lookAt(nextPos, nextPos + dir)
					end
				end
			end
		end

		Effects.updateLockIndicator(lockedTarget)
	end)

	-- A respawn is a fresh start: no combo carried over, nothing predicted from the last life.
	player.CharacterAdded:Connect(function()
		cancelHeavyCharge(false)
		lungeToken += 1
		clearLunge()
		dashToken += 1
		clearDash()
		dashEndsAt = 0
		activeAction = nil
		bufferedAction = nil
		lockedTarget = nil
		Effects.updateLockIndicator(nil)
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
