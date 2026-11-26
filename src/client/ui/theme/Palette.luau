--[[
	The shared Hazard Arc look, as values. Colours, fonts and the handful of sizes every screen is
	built from, so two screens written a month apart cannot drift into two different games.

	Values only. Anything that *builds* something is a component in `Widgets.luau` next door;
	the two helpers at the bottom survive here for per-frame draw loops that build instances by
	hand. Full token rationale and layout rules live in docs/ui-design-system.md.
]]

local Theme = {}

Theme.DISPLAY_FONT = Enum.Font.GothamBlack
Theme.TITLE_FONT = Enum.Font.GothamBold
Theme.BODY_FONT = Enum.Font.Gotham
Theme.MONO_FONT = Enum.Font.RobotoMono

-- Architectural plate surfaces (Sector Hazard top & informational layer)
Theme.INK = Color3.fromRGB(20, 22, 24)
Theme.PANEL = Color3.fromRGB(24, 27, 31)
Theme.STEEL = Color3.fromRGB(34, 38, 43)
Theme.STEEL_TOP = Color3.fromRGB(46, 52, 60)
Theme.PANEL_LIGHT = Theme.STEEL
Theme.BORDER = Color3.fromRGB(58, 64, 72)

-- Semantic accents shared across plates and circular actuators
Theme.HAZARD = Color3.fromRGB(245, 196, 0)
Theme.HIGHLIGHT = Theme.HAZARD
Theme.STRIKE = Color3.fromRGB(255, 59, 48)
Theme.KINETIC = Color3.fromRGB(56, 212, 255)
Theme.VITAL = Color3.fromRGB(68, 227, 123)

Theme.ABILITY_1 = Theme.HAZARD
Theme.ABILITY_2 = Color3.fromRGB(44, 229, 184)
Theme.ABILITY_3 = Color3.fromRGB(185, 124, 255)
Theme.GUARD = Color3.fromRGB(207, 216, 227)
Theme.HEAVY = Color3.fromRGB(255, 159, 46)
Theme.GRAB = Color3.fromRGB(255, 46, 147)

Theme.BUFF_DAMAGE = Color3.fromRGB(255, 105, 60)
Theme.BUFF_SPEED = Theme.KINETIC
Theme.BUFF_DEFENSE = Color3.fromRGB(88, 160, 255)

Theme.TEXT = Color3.fromRGB(244, 245, 240)
Theme.MUTED = Color3.fromRGB(148, 158, 171)

-- Design units against Config.UI_REFERENCE, like every other offset under a Scaled.Frame.
Theme.BUTTON_HEIGHT = 44
Theme.MARGIN = 20
Theme.CORNER = 2
Theme.CORNER_ROUND = 999
Theme.ACCENT_WIDTH = 3
Theme.STROKE = 1.5
Theme.ACTUATOR_STROKE = 2.5

function Theme.outline(instance: GuiObject, thickness: number?, color: Color3?): UIStroke
	local edge = Instance.new("UIStroke")
	edge.Color = color or Theme.BORDER
	edge.Thickness = thickness or Theme.STROKE
	edge.Transparency = 0.15
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
