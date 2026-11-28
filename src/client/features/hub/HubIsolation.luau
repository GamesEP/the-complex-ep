--!strict
--[[
	Client-side visual Hub isolation (`plans/gdd/systems.md`, `plans/roadmap.md HS-23`).

	While `workspace.World:GetAttribute("ServerMode") == "hub"`, every other player's avatar is
	hidden locally (`LocalTransparencyModifier = 1` + visual emitters/billboards disabled) so each
	player sees an empty, calm staging bay while still receiving every replicated `Player`
	attribute (`PartyId`, `PartyPrivacy`, `PartyRole`, etc.) for the Hub player list. When entering
	a Run (`ServerMode == "run"`), all teammate avatars are immediately restored.
]]

local Players = game:GetService("Players")

local HubIsolation = {}

local localPlayer = Players.LocalPlayer
local world: Instance = nil :: any
local connections: { [Player]: { RBXScriptConnection } } = {}

local function isHubMode(): boolean
	return world ~= nil and world:GetAttribute("ServerMode") == "hub"
end

local function applyDescendantHidden(inst: Instance, hidden: boolean)
	if inst:IsA("BasePart") then
		inst.LocalTransparencyModifier = if hidden then 1 else 0
	elseif inst:IsA("Decal") or inst:IsA("Texture") then
		-- Preserve original transparency via attribute on first hide.
		if hidden then
			if inst:GetAttribute("_HubOrigTrans") == nil then
				inst:SetAttribute("_HubOrigTrans", inst.Transparency)
			end
			inst.Transparency = 1
		else
			local orig = inst:GetAttribute("_HubOrigTrans")
			if type(orig) == "number" then
				inst.Transparency = orig
			end
		end
	elseif inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") or inst:IsA("ParticleEmitter") or inst:IsA("PointLight") or inst:IsA("Beam") or inst:IsA("Trail") then
		if hidden then
			if inst:GetAttribute("_HubOrigEnabled") == nil then
				inst:SetAttribute("_HubOrigEnabled", (inst :: any).Enabled)
			end
			(inst :: any).Enabled = false
		else
			local orig = inst:GetAttribute("_HubOrigEnabled")
			if type(orig) == "boolean" then
				(inst :: any).Enabled = orig
			end
		end
	elseif inst:IsA("Humanoid") then
		inst.DisplayDistanceType = if hidden
			then Enum.HumanoidDisplayDistanceType.None
			else Enum.HumanoidDisplayDistanceType.Viewer
	end
end

local function setCharacterHidden(character: Model, hidden: boolean)
	for _, desc in ipairs(character:GetDescendants()) do
		applyDescendantHidden(desc, hidden)
	end
end

local function refreshAll()
	local hidden = isHubMode()
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer and player.Character then
			setCharacterHidden(player.Character, hidden)
		end
	end
end

local function watchCharacter(player: Player, character: Model)
	if player == localPlayer then
		return
	end
	if isHubMode() then
		setCharacterHidden(character, true)
	end
	character.DescendantAdded:Connect(function(desc: Instance)
		if isHubMode() then
			applyDescendantHidden(desc, true)
		end
	end)
end

local function watchPlayer(player: Player)
	if player == localPlayer then
		return
	end
	local list: { RBXScriptConnection } = {}
	connections[player] = list
	table.insert(list, player.CharacterAdded:Connect(function(character: Model)
		watchCharacter(player, character)
	end))
	if player.Character then
		watchCharacter(player, player.Character)
	end
end

function HubIsolation.start()
	world = workspace:WaitForChild("World")
	world:GetAttributeChangedSignal("ServerMode"):Connect(refreshAll)

	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		local list = connections[player]
		if list then
			for _, conn in ipairs(list) do
				conn:Disconnect()
			end
			connections[player] = nil
		end
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
	refreshAll()
end

return HubIsolation
