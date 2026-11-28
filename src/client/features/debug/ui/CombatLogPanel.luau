--[[
	Rolling combat-math & debug event log overlay (bottom-right).
	Reads the immutable `DebugStore.combatLog` atom populated by `Remotes.DebugEvent`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local Client = script:FindFirstAncestor("Client")
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local DebugStore = require(script.Parent.Parent.stores.DebugStore)
local DevPrimitives = require(script.Parent.DevPrimitives)

local KIND_COLORS: { [string]: Color3 } = {
	hit = ui.VITAL,
	hurt = ui.STRIKE,
	parry = ui.HAZARD,
	warn = ui.HEAVY,
	info = ui.KINETIC,
}

local function CombatLogPanel(props: { topY: number? })
	local metrics = Scaled.useLayout()
	local entries = hooks.useAtom(DebugStore.combatLog)

	local visibleCount = Config.DEBUG_LOG_VISIBLE_ENTRIES
	local startIdx = math.max(1, #entries - visibleCount + 1)

	local lines: { [string]: any } = {
		Layout = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	if #entries == 0 then
		lines.Empty = React.createElement(ui.Title, {
			text = "(Sin eventos de combate aún)",
			font = ui.MONO_FONT,
			textSize = 11,
			color = ui.MUTED,
			order = 1,
		})
	else
		local order = 1
		for i = startIdx, #entries do
			local e = entries[i]
			lines[`Line_{e.seq}_{i}`] = React.createElement(ui.Title, {
				text = `[{e.tag}] {e.text}`,
				font = ui.MONO_FONT,
				textSize = 11,
				color = KIND_COLORS[e.kind] or ui.TEXT,
				order = order,
			})
			order += 1
		end
	end

	-- Docked top-right (below DebugMetricsBar when active) so bottom-right combat actuators
	-- (BLK / DSH / ATK) stay completely unobstructed.
	return React.createElement(ui.Panel, {
		name = "CombatLogPanel",
		width = math.min(324, metrics.room.X - 2 * ui.MARGIN),
		padding = 8,
		transparency = 0.12,
		accentColor = ui.KINETIC,
		accent = "left",
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.fromOffset(metrics.room.X - ui.MARGIN, props.topY or 12),
	}, {
		Layout = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Header = React.createElement("Frame", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			LayoutOrder = 1,
		}, {
			Title = React.createElement(ui.Title, {
				text = "COMBAT MATH LOG",
				font = ui.DISPLAY_FONT,
				textSize = 11,
				color = ui.KINETIC,
				size = UDim2.new(1, -64, 1, 0),
				automaticSize = Enum.AutomaticSize.None,
			}),
			ClearWrap = React.createElement("Frame", {
				Size = UDim2.fromOffset(60, 22),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}, {
				ClearBtn = React.createElement(DevPrimitives.ChipButton, {
					text = "Limpiar",
					width = 60,
					height = 20,
					onActivated = DebugStore.clearLog,
				}),
			}),
		}),
		Lines = React.createElement("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			LayoutOrder = 2,
		}, lines),
	})
end

return CombatLogPanel
