--!strict
--[[
	Diegetic ground revive ring & overhead beacon for downed teammates (`plans/gdd/ui.md`,
	`plans/roadmap.md HS-30`).

	Watches every player's `Downed` and `ReviveProgress` attributes. When a player enters `Downed`,
	mounts a high-contrast 8-stud (`Config.ALLY_REVIVE_RADIUS`) ground ring + inner radial progress
	disc + overhead BillboardGui (`CAÍDO — REANIMAR 5s`), smoothly following their position and
	cleaning up immediately on revive, reset, or disconnect.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local ReviveVisuals = {}

type DownedRig = {
	outer: Part,
	fill: Part,
	billboard: BillboardGui,
	statusLabel: TextLabel,
	barFill: Frame,
}

local rigs: { [Player]: DownedRig } = {}
local folder: Folder = nil :: any

local COLOR_DOWNED = Color3.fromRGB(255, 76, 86)
local COLOR_CHANNELING = Color3.fromRGB(68, 240, 152)

local function destroyRig(player: Player)
	local rig = rigs[player]
	if not rig then
		return
	end
	rigs[player] = nil
	if rig.outer.Parent then
		rig.outer:Destroy()
	end
	if rig.fill.Parent then
		rig.fill:Destroy()
	end
	if rig.billboard.Parent then
		rig.billboard:Destroy()
	end
end

local function createRig(player: Player): DownedRig
	local diam = Config.ALLY_REVIVE_RADIUS * 2

	local outer = Instance.new("Part")
	outer.Name = `ReviveRingOuter_{player.UserId}`
	outer.Shape = Enum.PartType.Cylinder
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.CastShadow = false
	outer.Material = Enum.Material.Neon
	outer.Color = COLOR_DOWNED
	outer.Transparency = 0.62
	outer.Size = Vector3.new(0.14, diam, diam)
	outer.Parent = folder

	local fill = Instance.new("Part")
	fill.Name = `ReviveRingFill_{player.UserId}`
	fill.Shape = Enum.PartType.Cylinder
	fill.Anchored = true
	fill.CanCollide = false
	fill.CanQuery = false
	fill.CanTouch = false
	fill.CastShadow = false
	fill.Material = Enum.Material.Neon
	fill.Color = COLOR_CHANNELING
	fill.Transparency = 0.45
	fill.Size = Vector3.new(0.2, 0.8, 0.8)
	fill.Parent = folder

	local billboard = Instance.new("BillboardGui")
	billboard.Name = `DownedBeacon_{player.UserId}`
	billboard.Size = UDim2.fromOffset(170, 46)
	billboard.StudsOffset = Vector3.new(0, 4.4, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = folder

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(14, 17, 23)
	frame.BackgroundTransparency = 0.14
	frame.BorderSizePixel = 0
	frame.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_DOWNED
	stroke.Thickness = 1.6
	stroke.Parent = frame

	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(6, 4)
	label.Size = UDim2.new(1, -12, 0, 20)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextColor3 = COLOR_DOWNED
	label.Text = `{player.DisplayName}  ·  CAÍDO`
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = frame

	local track = Instance.new("Frame")
	track.Position = UDim2.fromOffset(8, 28)
	track.Size = UDim2.new(1, -16, 0, 10)
	track.BackgroundColor3 = Color3.fromRGB(28, 34, 44)
	track.BorderSizePixel = 0
	track.Parent = frame

	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = COLOR_CHANNELING
	barFill.BorderSizePixel = 0
	barFill.Parent = track

	local rig: DownedRig = {
		outer = outer,
		fill = fill,
		billboard = billboard,
		statusLabel = label,
		barFill = barFill,
	}
	rigs[player] = rig
	return rig
end

local function step()
	local seen: { [Player]: boolean } = {}
	local diam = Config.ALLY_REVIVE_RADIUS * 2

	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("Downed") == true then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				seen[player] = true
				local rig = rigs[player] or createRig(player)
				local progAttr = player:GetAttribute("ReviveProgress")
				local progress = if type(progAttr) == "number" then math.clamp(progAttr, 0, 1) else 0
				local channeling = progress > 0.005

				local pos = root.Position
				rig.outer.CFrame = CFrame.new(pos.X, 0.14, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
				rig.outer.Color = if channeling then COLOR_CHANNELING else COLOR_DOWNED

				local fillDiam = math.max(diam * progress, 0.6)
				rig.fill.Size = Vector3.new(0.2, fillDiam, fillDiam)
				rig.fill.CFrame = CFrame.new(pos.X, 0.2, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
				rig.fill.Transparency = if channeling then 0.42 else 1

				rig.billboard.Adornee = root
				rig.barFill.Size = UDim2.fromScale(progress, 1)
				if channeling then
					local rem = math.max((1 - progress) * Config.ALLY_REVIVE_SECONDS, 0)
					rig.statusLabel.TextColor3 = COLOR_CHANNELING
					rig.statusLabel.Text = string.format("REANIMANDO  %.1fs", rem)
				else
					rig.statusLabel.TextColor3 = COLOR_DOWNED
					rig.statusLabel.Text = `{player.DisplayName} · CAÍDO`
				end
			end
		end
	end

	for player, _ in pairs(rigs) do
		if not seen[player] then
			destroyRig(player)
		end
	end
end

function ReviveVisuals.start()
	folder = Instance.new("Folder")
	folder.Name = "ReviveVisuals"
	folder.Parent = workspace

	Players.PlayerRemoving:Connect(destroyRig)
	RunService.Heartbeat:Connect(step)
end

return ReviveVisuals
