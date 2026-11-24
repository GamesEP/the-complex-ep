--[[
	The shared look, as values. Colours, fonts and the handful of sizes every panel is built
	from, so two screens written a month apart cannot drift into two different games.

	Values only. Anything that *builds* something is a component in `Widgets.luau` next door;
	the two helpers at the bottom survive here for the per-frame draw loops that build
	instances by hand and always will — a reconciler has nothing to offer something that is
	repositioned every Heartbeat.
]]

local Theme = {}

Theme.TITLE_FONT = Enum.Font.GothamBold
Theme.BODY_FONT = Enum.Font.Gotham

Theme.INK = Color3.fromRGB(18, 20, 28)
Theme.PANEL = Color3.fromRGB(38, 42, 56)
Theme.PANEL_LIGHT = Color3.fromRGB(58, 64, 84)
Theme.HIGHLIGHT = Color3.fromRGB(88, 160, 255)
Theme.TEXT = Color3.fromRGB(246, 248, 252)
Theme.MUTED = Color3.fromRGB(158, 166, 184)

-- Design units against Config.UI_REFERENCE, like every other offset under a Scaled.Frame.
Theme.BUTTON_HEIGHT = 44
Theme.MARGIN = 20
Theme.CORNER = 10

function Theme.outline(instance: GuiObject, thickness: number?): UIStroke
	local edge = Instance.new("UIStroke")
	edge.Color = Theme.INK
	edge.Thickness = thickness or 2
	edge.Transparency = 0.2
	edge.Parent = instance
	return edge
end

function Theme.round(instance: GuiObject, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or Theme.CORNER)
	corner.Parent = instance
	return corner
end

return Theme
