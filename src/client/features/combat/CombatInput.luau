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
local UserInputService = game:GetService("UserInputService")

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

-- Where the mouse points, on the horizontal plane through the player.
local function mouseAim(root: BasePart): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = (root.Position.Y - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then
		return nil
	end
	return Melee.flat(ray.Origin + ray.Direction * t - root.Position)
end

-- Without a mouse there is nothing to point with, so the swing turns to the nearest enemy in
-- reach — the aim assist a thumb on a phone needs to fight a crowd at this speed.
local function assistAim(root: BasePart): Vector3?
	local world = workspace:FindFirstChild("World")
	local enemies = world and world:FindFirstChild("Enemies")
	if not enemies then
		return nil
	end
	local best, bestDistance = nil, Config.AIM_ASSIST_RANGE
	for _, model in ipairs(enemies:GetChildren()) do
		local enemyBody = model:FindFirstChild("Body")
		if enemyBody and enemyBody:IsA("BasePart") then
			local distance = Melee.distance(root.Position, enemyBody.Position)
			if distance < bestDistance then
				best, bestDistance = enemyBody, distance
			end
		end
	end
	return best and Melee.flat(best.Position - root.Position)
end

local function attack(input: InputObject)
	local root, humanoid = body()
	if not root or not humanoid then
		return
	end
	local clock = os.clock()
	if clock - lastSwingAt < Config.ATTACK_INTERVAL then
		return
	end

	local aim = if input.UserInputType == Enum.UserInputType.MouseButton1 then mouseAim(root) else assistAim(root)
	aim = aim or Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not aim then
		return
	end

	comboStep = Melee.nextStep(comboStep, lastSwingAt, clock, Config.COMBO_HITS, Config.COMBO_WINDOW)
	lastSwingAt = clock
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	Effects.slash(root, aim, comboStep)
	Remotes.Attack:FireServer(aim)
end

local function dash()
	local root, humanoid = body()
	if not root or not humanoid or not ready(dashReadyAt, "DashReadyAt") then
		return
	end
	local direction = Melee.flat(humanoid.MoveDirection) or Melee.flat(root.CFrame.LookVector)
	if not direction then
		return
	end
	dashReadyAt = now() + Config.DASH_COOLDOWN

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
	local root = body()
	if not root or not ready(spinReadyAt, "SpinReadyAt") then
		return
	end
	spinReadyAt = now() + Config.SPIN_COOLDOWN
	Effects.spin(root)
	Remotes.Spin:FireServer()
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

function CombatInput.start()
	for name, action in pairs(ACTIONS) do
		ContextActionService:BindActionAtPriority(name, function(_, state: Enum.UserInputState, input: InputObject)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			action.run(input)
			return Enum.ContextActionResult.Sink
		end, true, Enum.ContextActionPriority.High.Value, table.unpack(action.inputs))
		ContextActionService:SetTitle(name, action.title)
	end

	-- A respawn is a fresh start: no combo carried over, nothing predicted from the last life.
	player.CharacterAdded:Connect(function()
		comboStep = 0
		lastSwingAt = -math.huge
		dashReadyAt = 0
		spinReadyAt = 0
	end)
end

return CombatInput
