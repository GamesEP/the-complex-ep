--[[
	Client-only bobbing and rotation for enemy drops in `workspace.World.Drops`.

	Running the visual idle motion on the client avoids replicating CFrame updates from the server
	every Heartbeat for every pickup on the floor. See docs/combat.md.
]]

local RunService = game:GetService("RunService")

local DropVisuals = {}

local SPIN_RADIANS_PER_SECOND = 2.2
local BOB_AMPLITUDE = 0.35
local BOB_FREQUENCY = 3.2

local function step()
	local world = workspace:FindFirstChild("World")
	local drops = world and world:FindFirstChild("Drops")
	if not drops then
		return
	end
	local t = os.clock()
	for _, child in ipairs(drops:GetChildren()) do
		if child:IsA("Model") then
			local primary = child.PrimaryPart or child:FindFirstChild("Core")
			if primary and primary:IsA("BasePart") then
				local baseY = child:GetAttribute("BaseY")
				if type(baseY) ~= "number" then
					baseY = primary.Position.Y
					child:SetAttribute("BaseY", baseY)
				end
				local pos = primary.Position
				local phase = (pos.X + pos.Z) * 0.25
				local y = baseY + math.sin(t * BOB_FREQUENCY + phase) * BOB_AMPLITUDE
				local cf = CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, t * SPIN_RADIANS_PER_SECOND + phase, 0)
				child:PivotTo(cf)
			end
		end
	end
end

function DropVisuals.start()
	RunService.RenderStepped:Connect(step)
end

return DropVisuals
