--[[
	Overhead Enemy Inspector billboards (plain Luau — zero React per-frame overhead).

	Driven by `DebugStore.overlays().enemyInspector`. Watches `workspace.World.Enemies` and
	displays `kind:weapon`, `HP/MaxHP`, `Phase`, and `Daze` stacks above each live enemy.
	Uses `AncestryChanged` for teardown because Roblox does not fire `Destroying` on the client
	when the server destroys a replicated instance (CLAUDE.md).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Charm = require(Packages.charm)

local Client = script:FindFirstAncestor("Client")
local Palette = require(Client.ui.theme.Palette)

local DebugStore = require(script.Parent.stores.DebugStore)

local EnemyInspector = {}

type Tracked = {
	gui: BillboardGui,
	conns: { RBXScriptConnection },
}

local enabled = false
local started = false
local enemiesFolderConn: RBXScriptConnection? = nil
local tracked: { [Instance]: Tracked } = {}

local function detach(model: Instance)
	local entry = tracked[model]
	if not entry then
		return
	end
	tracked[model] = nil
	for _, conn in ipairs(entry.conns) do
		conn:Disconnect()
	end
	if entry.gui.Parent then
		entry.gui:Destroy()
	end
end

local function detachAll()
	for model in pairs(tracked) do
		detach(model)
	end
	if enemiesFolderConn then
		enemiesFolderConn:Disconnect()
		enemiesFolderConn = nil
	end
end

local function attach(model: Instance)
	if not enabled or not model:IsA("Model") or tracked[model] then
		return
	end
	local adornee = model.PrimaryPart or model:FindFirstChild("Body")
	if not adornee or not adornee:IsA("BasePart") then
		task.spawn(function()
			local found = model:WaitForChild("Body", 3)
			if enabled and found and found:IsA("BasePart") and model:IsDescendantOf(workspace) then
				attach(model)
			end
		end)
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "DebugEnemyInspector"
	gui.Adornee = adornee
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Size = UDim2.fromOffset(170, 34)
	gui.StudsOffset = Vector3.new(0, adornee.Size.Y * 0.5 + 3.2, 0)

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Palette.INK
	bg.BackgroundTransparency = 0.22
	bg.BorderSizePixel = 0
	bg.Parent = gui
	Palette.round(bg, 2)
	Palette.outline(bg, 1, Palette.HAZARD)

	local topLabel = Instance.new("TextLabel")
	topLabel.Size = UDim2.new(1, -6, 0, 15)
	topLabel.Position = UDim2.fromOffset(3, 2)
	topLabel.BackgroundTransparency = 1
	topLabel.Font = Palette.DISPLAY_FONT
	topLabel.TextSize = 11
	topLabel.TextColor3 = Palette.HAZARD
	topLabel.TextXAlignment = Enum.TextXAlignment.Left
	topLabel.Parent = bg

	local botLabel = Instance.new("TextLabel")
	botLabel.Size = UDim2.new(1, -6, 0, 15)
	botLabel.Position = UDim2.fromOffset(3, 17)
	botLabel.BackgroundTransparency = 1
	botLabel.Font = Palette.MONO_FONT
	botLabel.TextSize = 10
	botLabel.TextColor3 = Palette.TEXT
	botLabel.TextXAlignment = Enum.TextXAlignment.Left
	botLabel.Parent = bg

	local function refresh()
		local kind = tostring(model:GetAttribute("Kind") or model.Name)
		local weapon = model:GetAttribute("Weapon")
		local isDummy = model:GetAttribute("DebugDummy") == true
		local header = if isDummy
			then "DUMMY (PASSIVE)"
			elseif type(weapon) == "string" and weapon ~= "" then `{kind}:{weapon}`
			else kind
		topLabel.Text = header

		local hp = math.floor(tonumber(model:GetAttribute("Health")) or 0)
		local maxHp = math.floor(tonumber(model:GetAttribute("MaxHealth")) or 0)
		local phase = tostring(model:GetAttribute("Phase") or "?")
		local daze = tonumber(model:GetAttribute("DazeStacks")) or 0
		botLabel.Text = `HP {hp}/{maxHp} · {phase} · D{daze}`
	end

	refresh()
	gui.Parent = adornee

	local conns: { RBXScriptConnection } = {}
	for _, attr in ipairs({ "Health", "MaxHealth", "Phase", "DazeStacks", "Weapon", "DebugDummy" }) do
		table.insert(conns, model:GetAttributeChangedSignal(attr):Connect(refresh))
	end
	table.insert(
		conns,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				detach(model)
			end
		end)
	)
	tracked[model] = { gui = gui, conns = conns }
end

local function enable()
	detachAll()
	local world = workspace:FindFirstChild("World")
	local enemiesFolder = world and world:FindFirstChild("Enemies")
	if not enemiesFolder then
		return
	end
	for _, child in ipairs(enemiesFolder:GetChildren()) do
		attach(child)
	end
	enemiesFolderConn = enemiesFolder.ChildAdded:Connect(attach)
end

function EnemyInspector.start()
	if started then
		return
	end
	started = true

	local function sync(overlays: DebugStore.OverlayFlags)
		local want = overlays.enemyInspector == true
		if want == enabled then
			return
		end
		enabled = want
		if enabled then
			enable()
		else
			detachAll()
		end
	end

	sync(DebugStore.overlays())
	Charm.subscribe(DebugStore.overlays, sync)
end

return EnemyInspector
