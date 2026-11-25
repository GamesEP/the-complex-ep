--[[
	The local player's own swing, dash and spin, drawn the instant they press — before the server
	has heard about it. Client-only parts: nobody else sees them, and nothing collides with them.

	Kept apart from CombatInput so the input code reads as decisions and this reads as visuals.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local CombatAudio = require(Shared.features.combat.CombatAudio)

local PlayerAnimator = require(script.Parent.PlayerAnimator)
local SoundPlayer = require(script.Parent.SoundPlayer)

local Effects = {}

local chargeRing: Part? = nil
local chargeConn: RBXScriptConnection? = nil

local function ghost(size: Vector3, cframe: CFrame, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.25
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Parent = workspace
	return part
end

-- Plays only the local attack pose (used when a lunge starts so the windup plays during the
-- step-in and the attack audio fires at impact).
function Effects.attackWindup(step: number)
	PlayerAnimator.playLocal("attack", step)
end

-- No placeholder block hitbox visual: the equipped sword and PlayerAnimator combo pose carry
-- the swing visually.
function Effects.slash(_root: BasePart, _direction: Vector3, step: number, animStarted: boolean?)
	-- Local player's own kit plays non-spatially (nil position) so it is always crisp regardless
	-- of camera distance or respawn timing; teammates receive a 3D broadcast from CombatService.
	SoundPlayer.play(CombatAudio.attackCue(step, Config.COMBO_HITS), nil, step)
	if not animStarted then
		PlayerAnimator.playLocal("attack", step)
	end
end

function Effects.spin(root: BasePart)
	local diameter = Config.SPIN_RADIUS * 2
	-- A cylinder's axis is X, so it is turned on its side to lie flat as a disc.
	local cframe = CFrame.new(root.Position - Vector3.new(0, 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local part = ghost(Vector3.new(0.4, 4, 4), cframe, Color3.fromRGB(255, 200, 90), Enum.PartType.Cylinder)
	TweenService:Create(part, TweenInfo.new(0.2), { Size = Vector3.new(0.4, diameter, diameter), Transparency = 1 }):Play()
	Debris:AddItem(part, 0.25)
	SoundPlayer.play("playerSpin")
	PlayerAnimator.playLocal("spin")
end

function Effects.dash(root: BasePart)
	local part = ghost(Vector3.new(2, 5, 1), root.CFrame, Color3.fromRGB(140, 200, 255))
	TweenService:Create(part, TweenInfo.new(0.2), { Transparency = 1 }):Play()
	Debris:AddItem(part, 0.25)
	SoundPlayer.play("playerDash")
	PlayerAnimator.playLocal("dash")
end

-- Pulsing golden-orange energy ring at the player's feet while charging the 3 s heavy attack.
function Effects.startCharge(root: BasePart)
	Effects.stopCharge()
	local startedAt = os.clock()
	local duration = math.max(Config.HEAVY_CHARGE_SECONDS - Config.HEAVY_CHARGE_DELAY, 0.1)
	local ring = ghost(
		Vector3.new(0.3, 5, 5),
		CFrame.new(root.Position - Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(255, 175, 55),
		Enum.PartType.Cylinder
	)
	ring.Transparency = 0.45
	chargeRing = ring
	SoundPlayer.play("playerHeavyCharge")

	chargeConn = RunService.RenderStepped:Connect(function()
		if not ring.Parent or not root.Parent then
			Effects.stopCharge()
			return
		end
		local elapsed = os.clock() - startedAt
		local progress = math.clamp(elapsed / duration, 0, 1)
		local pulse = 0.65 * math.sin(elapsed * (7 + progress * 10))
		local diameter = 4.5 + progress * 4.5 + pulse
		ring.Size = Vector3.new(0.25 + progress * 0.15, diameter, diameter)
		ring.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Color = Color3.fromRGB(255, math.round(175 - progress * 80), math.round(55 - progress * 25))
		ring.Transparency = 0.55 - progress * 0.35
	end)
end

function Effects.stopCharge()
	if chargeConn then
		chargeConn:Disconnect()
		chargeConn = nil
	end
	if chargeRing then
		chargeRing:Destroy()
		chargeRing = nil
	end
end

-- Massive forward shockwave burst + ground ring when the charged heavy attack unleashes.
function Effects.heavyAttack(root: BasePart, direction: Vector3)
	Effects.stopCharge()
	local ringDiameter = Config.HEAVY_ATTACK_RANGE * 1.65
	local groundPos = root.Position - Vector3.new(0, 2.2, 0)
	local ring = ghost(
		Vector3.new(0.5, 5, 5),
		CFrame.new(groundPos) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(255, 120, 45),
		Enum.PartType.Cylinder
	)
	ring.Transparency = 0.15
	TweenService:Create(
		ring,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.5, ringDiameter, ringDiameter), Transparency = 1 }
	):Play()
	Debris:AddItem(ring, 0.32)

	-- Sweeping forward energy wave along `direction` so the wide 160-deg reach reads clearly.
	local waveStart = CFrame.lookAt(root.Position + direction * 2.5, root.Position + direction * 10)
	local waveEnd = CFrame.lookAt(root.Position + direction * (Config.HEAVY_ATTACK_RANGE * 0.72), root.Position + direction * (Config.HEAVY_ATTACK_RANGE + 5))
	local wave = ghost(Vector3.new(8, 2.2, 1.4), waveStart, Color3.fromRGB(255, 200, 85))
	wave.Transparency = 0.1
	TweenService:Create(
		wave,
		TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(Config.HEAVY_ATTACK_RANGE * 1.45, 0.6, 2.4), CFrame = waveEnd, Transparency = 1 }
	):Play()
	Debris:AddItem(wave, 0.28)

	SoundPlayer.play("playerHeavyAttack")
	PlayerAnimator.playLocal("heavyAttack")
end

return Effects
