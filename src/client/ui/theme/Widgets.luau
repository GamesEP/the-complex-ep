--[[
	The shared look, as components. The values stay in `Palette.luau` next door and are
	re-exported from here, so there is one place a colour is defined however a panel is built.

	Keep this file small and boring. It is for the three or four shapes every screen repeats —
	a surface, a heading, a button — not for anything a single feature needs. A widget that
	only one screen uses belongs to that screen's folder, where it can change without anybody
	auditing the rest of the game.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Theme = require(script.Parent.Palette)

local ui = {}

-- Everything from the palette: fonts, colours, sizes. Re-exported rather than copied, so a
-- screen imports one module and a tone cannot be defined twice.
for key, value in pairs(Theme) do
	ui[key] = value
end

--=============================================================================
-- The three modifiers every panel puts on something
--=============================================================================

function ui.Round(props)
	return React.createElement("UICorner", {
		CornerRadius = UDim.new(0, props.radius or Theme.CORNER),
	})
end

function ui.Outline(props)
	return React.createElement("UIStroke", {
		Color = props.color or Theme.INK,
		Thickness = props.thickness or 2,
		Transparency = props.transparency or 0.2,
	})
end

function ui.Pad(props)
	local amount = UDim.new(0, props.amount or 0)
	return React.createElement("UIPadding", {
		PaddingTop = if props.top then UDim.new(0, props.top) else amount,
		PaddingBottom = if props.bottom then UDim.new(0, props.bottom) else amount,
		PaddingLeft = if props.left then UDim.new(0, props.left) else amount,
		PaddingRight = if props.right then UDim.new(0, props.right) else amount,
	})
end

--=============================================================================
-- Surfaces
--=============================================================================

-- A panel that grows to fit what is put in it. `width` is a design unit like every other
-- offset under a `Scaled.Frame` — never multiply one by `Layout.scale()`, it is already scaled.
function ui.Panel(props)
	local children = table.clone(props.children or {})
	children.Corner = React.createElement(ui.Round, { radius = props.radius })
	children.Edge = React.createElement(ui.Outline, {})
	if props.padding then
		children.Padding = React.createElement(ui.Pad, { amount = props.padding })
	end

	return React.createElement("Frame", {
		Name = props.name or "Panel",
		Size = props.size or UDim2.fromOffset(props.width or 0, 0),
		AutomaticSize = props.automaticSize or Enum.AutomaticSize.Y,
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		BackgroundColor3 = props.color or Theme.PANEL,
		BackgroundTransparency = props.transparency or 0.1,
		LayoutOrder = props.order,
		Visible = props.visible,
		ZIndex = props.zIndex,
	}, children)
end

function ui.Title(props)
	return React.createElement("TextLabel", {
		Name = props.name,
		Size = props.size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = props.automaticSize or Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = props.font or Theme.TITLE_FONT,
		TextSize = props.textSize or 20,
		TextColor3 = props.color or Theme.TEXT,
		TextXAlignment = props.alignment or Enum.TextXAlignment.Left,
		TextWrapped = if props.wrapped == nil then true else props.wrapped,
		Text = props.text or "",
		LayoutOrder = props.order,
		ZIndex = props.zIndex,
		Visible = props.visible,
	})
end

function ui.Button(props)
	return React.createElement("TextButton", {
		Name = props.name or "Button",
		Size = props.size or UDim2.new(1, 0, 0, Theme.BUTTON_HEIGHT),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		BackgroundColor3 = if props.active then Theme.HIGHLIGHT else Theme.PANEL_LIGHT,
		AutoButtonColor = false,
		Font = Theme.TITLE_FONT,
		TextSize = props.textSize or 18,
		TextColor3 = Theme.TEXT,
		Text = props.text or "",
		LayoutOrder = props.order,
		Visible = props.visible,
		ZIndex = props.zIndex,
		-- Activated rather than MouseButton1Click: it is the one that means "tapped" on every
		-- input device, so a button written once works on a phone without a touch branch.
		[React.Event.Activated] = props.onActivated,
	}, {
		Corner = React.createElement(ui.Round, { radius = props.radius }),
		Edge = React.createElement(ui.Outline, {}),
	})
end

return ui
