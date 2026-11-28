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
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.core.Net.Remotes)

local CombatInput = require(script.Parent.CombatInput)

local Knockback = {}

local player = Players.LocalPlayer

-- One fling at a time: a newer one replaces the older instead of two velocities fighting.
local token = 0
local active: { velocity: LinearVelocity, attachment: Attachment, root: BasePart, direction: Vector3, speed: number }? = nil

local function clear(hardStop: boolean?)
	if active then
		local moveRoot = active.root
		active.velocity:Destroy()
		active.attachment:Destroy()
		active = nil
		if hardStop and moveRoot.Parent then
			local v = moveRoot.AssemblyLinearVelocity
			moveRoot.AssemblyLinearVelocity = Vector3.new(0, math.min(v.Y, 0), 0)
		end
	end
end

local function hitsWallAhead(root: BasePart, direction: Vector3, distance: number): boolean
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
	local sphere = workspace:Spherecast(root.Position, 1.05, direction * distance, params)
	if sphere and math.abs(sphere.Normal.Y) < 0.65 then
		return true
	end
	local ray = workspace:Raycast(root.Position, direction * (distance + 0.9), params)
	return ray ~= nil and math.abs(ray.Normal.Y) < 0.65
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
	clear(false)
	-- Cancel any active attack lunge, step, dash, charge, or buffer before applying knockback so
	-- only one LinearVelocity owns the root part at any instant (docs/combat.md).
	CombatInput.beginKnockback(seconds)

	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, upSpeed, root.AssemblyLinearVelocity.Z)

	if hitsWallAhead(root, flat, 1.4) then
		CombatInput.endKnockback()
		return
	end

	-- Horizontal: bounded-force velocity (never `math.huge`, which flings players over walls on
	-- impact) monitored each Heartbeat so wall contact halts horizontal travel cleanly.
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	velocity.LineDirection = flat
	velocity.LineVelocity = speed
	velocity.MaxForce = math.max(root.AssemblyMass * 2200, 30000)
	velocity.Parent = root
	active = { velocity = velocity, attachment = attachment, root = root, direction = flat, speed = speed }

	task.delay(seconds, function()
		if token == mine then
			clear(false)
			CombatInput.endKnockback()
		end
	end)
end

function Knockback.start()
	Remotes.Knockback.OnClientEvent:Connect(fling)
	RunService.Heartbeat:Connect(function(dt: number)
		if not active then
			return
		end
		local root = active.root
		local safeDt = math.min(dt, 1 / 30)
		local checkDist = math.clamp(active.speed * safeDt * 1.15, 1.2, 2.6)
		if not root.Parent or hitsWallAhead(root, active.direction, checkDist) then
			token += 1
			clear(true)
			CombatInput.endKnockback()
		end
	end)
	-- A respawn must not inherit a fling aimed at the previous body.
	player.CharacterAdded:Connect(function()
		token += 1
		clear(false)
		CombatInput.endKnockback()
	end)
end

return Knockback
