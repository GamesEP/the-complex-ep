--[[
	Compact live performance & combat-state telemetry strip (top-right).

	Uses `React.useBinding` updated from `RenderStepped` (throttled to ~10 Hz) so 60 FPS frame
	metrics never trigger React reconciler re-renders (CLAUDE.md).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local Client = script:FindFirstAncestor("Client")
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local function DebugMetrics(props: { world: Instance, player: Player })
	local metrics = Scaled.useLayout()
	local perfText, setPerfText = React.useBinding("FPS -- · -- ms")
	local worldText, setWorldText = React.useBinding("F1 R1/5 W1")
	local playerText, setPlayerText = React.useBinding("HP --/--")
	local flagsText, setFlagsText = React.useBinding("")

	local emaDtRef = React.useRef(1 / 60)
	local accumRef = React.useRef(0)

	hooks.useSignal(RunService.RenderStepped, function(dt: number)
		emaDtRef.current = emaDtRef.current * 0.9 + dt * 0.1
		accumRef.current += dt
		if accumRef.current < 0.1 then
			return
		end
		accumRef.current = 0

		local ms = emaDtRef.current * 1000
		local fps = if emaDtRef.current > 1e-4 then 1 / emaDtRef.current else 0
		local world = props.world
		local player = props.player

		local enemiesFolder = world:FindFirstChild("Enemies")
		local enemyCount = if enemiesFolder then #enemiesFolder:GetChildren() else (world:GetAttribute("EnemiesLeft") or 0)
		local dropsFolder = world:FindFirstChild("Drops")
		local dropCount = if dropsFolder then #dropsFolder:GetChildren() else 0

		setPerfText(string.format("FPS %3d · %4.1f ms · Enem %d/%d · Drops %d", math.floor(fps + 0.5), ms, enemyCount, Config.DEBUG_MAX_SPAWN_COUNT, dropCount))

		local floor = world:GetAttribute("Floor") or 1
		local room = world:GetAttribute("Room") or 1
		local roomCount = world:GetAttribute("RoomCount") or 5
		local wave = world:GetAttribute("Wave") or 1
		local runState = tostring(world:GetAttribute("RunState") or "?")
		local diff = tostring(world:GetAttribute("Difficulty") or "normal")
		setWorldText(string.format("F%d R%d/%d W%d · %s · %s", floor, room, roomCount, wave, runState:upper(), diff:upper()))

		local hp = math.floor(player:GetAttribute("Health") or 0)
		local maxHp = math.floor(player:GetAttribute("MaxHealth") or Config.PLAYER_MAX_HEALTH)
		local upgDmg = (player:GetAttribute("UpgradeDamageMult") or 1) * (player:GetAttribute("DebugDamageMult") or 1)
		local upgSpd = player:GetAttribute("UpgradeSpeedMult") or 1
		local upgCdr = player:GetAttribute("UpgradeCooldownMult") or 1
		local dashCharges = player:GetAttribute("DashCharges") or 1
		setPlayerText(string.format("HP %d/%d · Dmg %.2fx · Spd %.2fx · CDR %.2fx · Dash %d", hp, maxHp, upgDmg, upgSpd, upgCdr, dashCharges))

		local t = workspace:GetServerTimeNow()
		local char = player.Character
		local invulnUntil = if char then char:GetAttribute("InvulnerableUntil") else nil
		local parryUntil = player:GetAttribute("ParryUntil")
		local tags = {}
		if type(invulnUntil) == "number" and t < invulnUntil then
			table.insert(tags, "IFRAMES")
		end
		if type(parryUntil) == "number" and t < parryUntil then
			table.insert(tags, "PARRY")
		end
		if player:GetAttribute("Blocking") == true then
			table.insert(tags, "BLOCK")
		end
		if player:GetAttribute("DebugGodMode") == true then
			table.insert(tags, "GOD")
		end
		if player:GetAttribute("DebugNoCooldowns") == true then
			table.insert(tags, "NOCD")
		end
		if world:GetAttribute("DebugSandbox") == true then
			table.insert(tags, "SANDBOX")
		end
		local aiMode = world:GetAttribute("DebugAiMode")
		if aiMode and aiMode ~= "normal" then
			table.insert(tags, `AI:{tostring(aiMode):upper()}`)
		end
		setFlagsText(if #tags > 0 then table.concat(tags, " · ") else "ESTÁNDAR")
	end)

	return React.createElement(ui.Panel, {
		name = "DebugMetricsBar",
		width = math.min(324, metrics.room.X - 2 * ui.MARGIN),
		padding = 8,
		transparency = 0.12,
		accentColor = ui.VITAL,
		accent = "left",
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.fromOffset(metrics.room.X - ui.MARGIN, Layout.inset() + 12),
	}, {
		Layout = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Perf = React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 11,
			TextColor3 = ui.VITAL,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = perfText,
			LayoutOrder = 1,
		}),
		World = React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 11,
			TextColor3 = ui.TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = worldText,
			LayoutOrder = 2,
		}),
		Player = React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 11,
			TextColor3 = ui.KINETIC,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = playerText,
			LayoutOrder = 3,
		}),
		Flags = React.createElement("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = ui.DISPLAY_FONT,
			TextSize = 10,
			TextColor3 = ui.HAZARD,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = flagsText,
			LayoutOrder = 4,
		}),
	})
end

return DebugMetrics
