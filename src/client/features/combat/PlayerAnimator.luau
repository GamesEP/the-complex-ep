--[[
	Client-side procedural animator for every player's character: 3-hit combo attack, jump/land,
	dash and 360-degree spin.

	Drives `.Transform` on `AnimationConstraint` (modern R15 Avatar Joint Upgrade) and `Motor6D`
	(classic R15/R6) inside `RunService.Stepped`, which runs after Roblox's `Animator` updates
	locomotion and before physics/rendering reads joint transforms. That lets upper-body attacks
	layer cleanly over running/jumping while full-body dashes and spins take over smoothly.
	See docs/combat.md.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local CombatAnim = require(Shared.features.combat.CombatAnim)
local Melee = require(Shared.features.combat.Melee)

local PlayerAnimator = {}

type JointLike = Motor6D | AnimationConstraint

type RigState = {
	token: number,
	character: Model,
	humanoid: Humanoid,
	root: BasePart?,
	joints: { [string]: JointLike },
	connections: { RBXScriptConnection },
	airborne: boolean,
	action: string?,
	step: number?,
	startedAt: number,
}

-- Maps classic R6 joint names onto the canonical R15 names CombatAnim outputs.
local JOINT_ALIASES: { [string]: string } = {
	RootJoint = "Root",
	["Right Shoulder"] = "RightShoulder",
	["Left Shoulder"] = "LeftShoulder",
	["Right Hip"] = "RightHip",
	["Left Hip"] = "LeftHip",
}

local rigs: { [Player]: RigState } = {}
local nextToken = 0

local function isJoint(inst: Instance): boolean
	return inst:IsA("AnimationConstraint") or inst:IsA("Motor6D")
end

local function registerJoint(rig: RigState, inst: Instance)
	if not isJoint(inst) then
		return
	end
	local canonical = JOINT_ALIASES[inst.Name] or inst.Name
	rig.joints[canonical] = inst :: JointLike
end

local function isAirState(state: Enum.HumanoidStateType): boolean
	return state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall
end

local function disconnectRig(player: Player, expectedToken: number?)
	local existing = rigs[player]
	if not existing then
		return
	end
	if expectedToken and existing.token ~= expectedToken then
		return
	end
	for _, conn in ipairs(existing.connections) do
		conn:Disconnect()
	end
	rigs[player] = nil
end

local function trigger(rig: RigState, action: string, step: number?)
	local currentKey = if rig.action then CombatAnim.specKey(rig.action, rig.step) else nil
	local nextKey = CombatAnim.specKey(action, step)
	if not CombatAnim.canInterrupt(currentKey, nextKey) then
		return
	end
	rig.action = action
	rig.step = step
	rig.startedAt = os.clock()
end

local function attachCharacter(player: Player, character: Model)
	-- Token-gated teardown so an older character's cleanup can never wipe a newly spawned one.
	disconnectRig(player)
	nextToken += 1
	local token = nextToken

	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	-- CharacterAdded fires before Roblox parents the character to workspace, so only check
	-- that a newer respawn has not already replaced it.
	if player.Character ~= character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local rig: RigState = {
		token = token,
		character = character,
		humanoid = humanoid,
		root = if root and root:IsA("BasePart") then root else nil,
		joints = {},
		connections = {},
		airborne = isAirState(humanoid:GetState()),
		action = nil,
		step = nil,
		startedAt = 0,
	}

	for _, desc in ipairs(character:GetDescendants()) do
		registerJoint(rig, desc)
	end

	-- Parts and joints can finish replicating after CharacterAdded fires (CLAUDE.md).
	table.insert(
		rig.connections,
		character.DescendantAdded:Connect(function(desc)
			if desc.Name == "HumanoidRootPart" and desc:IsA("BasePart") then
				rig.root = desc
			else
				registerJoint(rig, desc)
			end
		end)
	)

	-- Jump and landing are driven from the character's replicated Humanoid state (no remote needed).
	table.insert(
		rig.connections,
		humanoid.StateChanged:Connect(function(oldState, newState)
			if isAirState(newState) then
				rig.airborne = true
			elseif rig.airborne and (newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running) then
				rig.airborne = false
				trigger(rig, "land")
			elseif not isAirState(oldState) and not isAirState(newState) then
				rig.airborne = false
			end
		end)
	)

	-- `Destroying` does not fire on clients for server-destroyed characters; watch ancestry instead.
	-- Wait until the character has actually entered workspace before treating `nil` as removal.
	local mounted = character.Parent ~= nil
	table.insert(
		rig.connections,
		character.AncestryChanged:Connect(function(_, parent)
			if parent ~= nil then
				mounted = true
			elseif mounted then
				disconnectRig(player, token)
			end
		end)
	)

	rigs[player] = rig
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(attachCharacter, player, character)
	end)
	player.CharacterRemoving:Connect(function()
		disconnectRig(player)
	end)
	if player.Character then
		task.spawn(attachCharacter, player, player.Character)
	end
end

local function applyPose(rig: RigState, pose: CombatAnim.Pose)
	if not pose.active or pose.weight <= 0 then
		return
	end
	for jointName, target in pairs(pose.joints) do
		local joint = rig.joints[jointName]
		if joint and joint.Parent then
			joint.Transform = joint.Transform:Lerp(target, pose.weight)
		end
	end
end

local function onStepped()
	local now = os.clock()
	for player, rig in pairs(rigs) do
		if rig.humanoid.Health <= 0 then
			rig.action = nil
			rig.airborne = false
			continue
		end

		-- Keep airborne state accurate even if a state transition was missed on spawn.
		local state = rig.humanoid:GetState()
		if isAirState(state) then
			rig.airborne = true
		elseif rig.airborne and state == Enum.HumanoidStateType.Running then
			rig.airborne = false
		end

		-- Layer 1: airborne jump pose (upper-body attacks and guard layer cleanly on top of this).
		if rig.airborne and rig.root then
			applyPose(rig, CombatAnim.jumpPose(rig.root.AssemblyLinearVelocity.Y))
		end

		-- Layer 1.5: seismic stagger/stun, continuous sword guard, Over Drive power-channeling, or
		-- coiled power-charge stance while holding Attack for the heavy attack.
		local serverNow = workspace:GetServerTimeNow()
		local classAttr = player:GetAttribute("Class")
		local classId = if type(classAttr) == "string" and classAttr ~= "" then classAttr else nil
		local stunnedUntil = player:GetAttribute("StunnedUntil")
		if type(stunnedUntil) == "number" and serverNow < stunnedUntil then
			applyPose(rig, CombatAnim.staggerPose(now))
		elseif player:GetAttribute("Blocking") == true then
			applyPose(rig, CombatAnim.blockPose(classId))
		elseif player:GetAttribute("OverDriveCharging") == true then
			local progress = Melee.chargeProgress(
				player:GetAttribute("OverDriveChargeStart"),
				serverNow,
				Config.OVERDRIVE_CHARGE_SECONDS
			)
			applyPose(rig, CombatAnim.overdriveChargePose(progress))
		elseif player:GetAttribute("ChargingHeavy") == true then
			local progress = Melee.chargeProgress(
				player:GetAttribute("HeavyChargeStart"),
				serverNow,
				Config.HEAVY_CHARGE_SECONDS
			)
			applyPose(rig, CombatAnim.chargePose(progress))
		end

		-- Layer 2: one-shot combat or landing action.
		if rig.action then
			local pose = CombatAnim.evaluate(rig.action, rig.step, now - rig.startedAt, classId)
			if pose.active then
				applyPose(rig, pose)
			else
				rig.action = nil
				rig.step = nil
			end
		end
	end
end

-- Called immediately by `Effects` for zero-latency local player feedback.
function PlayerAnimator.playLocal(action: string, step: number?)
	local player = Players.LocalPlayer
	local rig = player and rigs[player]
	if not rig then
		return
	end
	trigger(rig, action, step)
end

function PlayerAnimator.start()
	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(player)
		disconnectRig(player)
	end)

	Remotes.CombatAnim.OnClientEvent:Connect(function(source: Player, action: string, step: number?)
		if typeof(source) ~= "Instance" or not source:IsA("Player") or type(action) ~= "string" then
			return
		end
		local rig = rigs[source]
		if rig then
			trigger(rig, action, step)
		end
	end)

	RunService.Stepped:Connect(onStepped)
end

return PlayerAnimator
