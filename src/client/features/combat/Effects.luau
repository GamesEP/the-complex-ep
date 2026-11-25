--[[
	The local player's own swing, dash and spin, drawn the instant they press — before the server
	has heard about it. Client-only parts: nobody else sees them, and nothing collides with them.

	Kept apart from CombatInput so the input code reads as decisions and this reads as visuals.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local CombatAudio = require(Shared.features.combat.CombatAudio)

local PlayerAnimator = require(script.Parent.PlayerAnimator)
local SoundPlayer = require(script.Parent.SoundPlayer)

local Effects = {}

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

return Effects
