--[[
	The local player's own swing, dash and spin, drawn the instant they press — before the server
	has heard about it. Client-only parts: nobody else sees them, and nothing collides with them.

	Kept apart from CombatInput so the input code reads as decisions and this reads as visuals.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

local Effects = {}

-- One colour per hit of the combo, brightest on the heavy last hit.
local SLASH_COLORS = {
	Color3.fromRGB(210, 230, 255),
	Color3.fromRGB(170, 210, 255),
	Color3.fromRGB(255, 220, 120),
}

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

function Effects.slash(root: BasePart, direction: Vector3, step: number)
	local reach = Config.ATTACK_RANGE
	local position = root.Position + direction * (reach / 2)
	local cframe = CFrame.lookAt(position, position + direction)
	local part = ghost(Vector3.new(reach * 1.1, 0.3, reach * 0.55), cframe, SLASH_COLORS[step] or SLASH_COLORS[1])
	TweenService:Create(part, TweenInfo.new(0.12), { Transparency = 1 }):Play()
	Debris:AddItem(part, 0.15)
end

function Effects.spin(root: BasePart)
	local diameter = Config.SPIN_RADIUS * 2
	-- A cylinder's axis is X, so it is turned on its side to lie flat as a disc.
	local cframe = CFrame.new(root.Position - Vector3.new(0, 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local part = ghost(Vector3.new(0.4, 4, 4), cframe, Color3.fromRGB(255, 200, 90), Enum.PartType.Cylinder)
	TweenService:Create(part, TweenInfo.new(0.2), { Size = Vector3.new(0.4, diameter, diameter), Transparency = 1 }):Play()
	Debris:AddItem(part, 0.25)
end

function Effects.dash(root: BasePart)
	local part = ghost(Vector3.new(2, 5, 1), root.CFrame, Color3.fromRGB(140, 200, 255))
	TweenService:Create(part, TweenInfo.new(0.2), { Transparency = 1 }):Play()
	Debris:AddItem(part, 0.25)
end

return Effects
