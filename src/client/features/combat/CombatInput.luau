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
local Melee = require(Shared.features.combat.Melee)

local Effects = require(script.Parent.Effects)

local CombatInput = {}

local player = Players.LocalPlayer

-- Predicted, in server time so they compare directly with the attributes the server writes.
-- The local value stops a double press from firing twice before the attribute replicates.
local comboStep = 0
local lastSwingAt = -math.huge
local dashReadyAt = 0
local spinReadyAt = 0
local blockReadyAt = 0
local blocking = false

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

local function now(): number
	return workspace:GetServerTimeNow()
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
	if blocking or player:GetAttribute("Blocking") == true then
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

local function dash()
	if player:GetAttribute("Grabbed") == true then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(dashReadyAt, "DashReadyAt") then
		return
	end
	local direction = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not direction then
		return
	end
	lungeToken += 1
	clearLunge()
	blocking = false
	dashReadyAt = now() + Config.DASH_COOLDOWN
	dashEndsAt = os.clock() + Config.DASH_DURATION

	-- The character is the client's to move, so the dash is a velocity held along one line for
	-- its duration: horizontal only, gravity left alone, and gone before the next frame's input.
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
	task.delay(Config.DASH_DURATION, function()
		velocity:Destroy()
		attachment:Destroy()
	end)

	root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
	Effects.dash(root)
	Remotes.Dash:FireServer()
end

local function spin()
	if player:GetAttribute("Grabbed") == true or blocking or player:GetAttribute("Blocking") == true then
		return
	end
	local root, humanoid = body()
	if not root or not humanoid or not ready(spinReadyAt, "SpinReadyAt") then
		return
	end
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

local function setBlock(active: boolean)
	if active then
		if blocking or player:GetAttribute("Grabbed") == true then
			return
		end
		local root = body()
		if not root or not ready(blockReadyAt, "BlockReadyAt") then
			return
		end
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
	Attack = {
		run = attack,
		title = "Atacar",
		inputs = { Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonX, Enum.KeyCode.ButtonR2 },
	},
	Dash = {
		run = dash,
		title = "Dash",
		inputs = { Enum.KeyCode.LeftShift, Enum.KeyCode.Q, Enum.KeyCode.ButtonB, Enum.KeyCode.ButtonL2 },
	},
	Spin = {
		run = spin,
		title = "Giro",
		inputs = { Enum.KeyCode.E, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonR1 },
	},
}

local BLOCK_INPUTS = { Enum.UserInputType.MouseButton2, Enum.KeyCode.F, Enum.KeyCode.ButtonL1 }

function CombatInput.start()
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

	-- A respawn is a fresh start: no combo carried over, nothing predicted from the last life.
	player.CharacterAdded:Connect(function()
		lungeToken += 1
		clearLunge()
		dashEndsAt = 0
		lockedTarget = nil
		lastEngageAt = -math.huge
		comboStep = 0
		lastSwingAt = -math.huge
		dashReadyAt = 0
		spinReadyAt = 0
		blockReadyAt = 0
		blocking = false
	end)
end

return CombatInput
