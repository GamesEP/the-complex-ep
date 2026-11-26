--[[
	Flings the local player when the server says they were knocked back (the grabber's rush).

	The client owns its character's physics, so the server cannot move it: a velocity set there is
	overwritten by the next physics update from this client. The server decides *that* the player
	was hit and fires `Remotes.Knockback`; this applies it. The stun that comes with it is the
	server's (`StunnedUntil`), and CombatInput already cancels any attack lunge when it lands.

	A plain module rather than part of CombatInput: it reacts to the server, not to input.
	See docs/combat.md.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.core.Net.Remotes)

local Knockback = {}

local player = Players.LocalPlayer

-- One fling at a time: a newer one replaces the older instead of two velocities fighting.
local token = 0
local active: { velocity: LinearVelocity, attachment: Attachment }? = nil

local function clear()
	if active then
		active.velocity:Destroy()
		active.attachment:Destroy()
		active = nil
	end
end

local function fling(direction: Vector3, speed: number, upSpeed: number, seconds: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end
	-- The server sent a unit vector, but this is the boundary where a bad value would turn into a
	-- NaN velocity, so it is flattened and checked again rather than trusted.
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 or speed ~= speed or upSpeed ~= upSpeed then
		return
	end
	flat = flat.Unit

	token += 1
	local mine = token
	clear()

	-- Horizontal: held along one line for `seconds`, like the dash, so ground friction cannot eat
	-- it. Vertical: one upward kick, left to gravity, which is what makes it read as a launch.
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	velocity.LineDirection = flat
	velocity.LineVelocity = speed
	velocity.MaxForce = math.huge
	velocity.Parent = root
	active = { velocity = velocity, attachment = attachment }

	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, upSpeed, root.AssemblyLinearVelocity.Z)

	task.delay(seconds, function()
		if token == mine then
			clear()
		end
	end)
end

function Knockback.start()
	Remotes.Knockback.OnClientEvent:Connect(fling)
	-- A respawn must not inherit a fling aimed at the previous body.
	player.CharacterAdded:Connect(function()
		token += 1
		clear()
	end)
end

return Knockback
