--[[
	The shared Hazard Arc look, as components. The values stay in `Palette.luau` next door and are
	re-exported from here, so there is one place a colour is defined however a panel is built.

	Keep this file small and boring. It is for the shapes every screen repeats — an architectural
	plate, a heading, a button, and a machined circular actuator (see docs/ui-design-system.md) —
	not for anything a single feature needs.
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

local STEEL_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Theme.STEEL_TOP),
	ColorSequenceKeypoint.new(1, Theme.INK),
})

local function isPointerInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

-- Maps a 0..1 progress value to a sharp transparency step for a -90 deg UIGradient inside a
-- circular frame. Avoids CanvasGroup overhead while keeping circular clipping exact (see
-- docs/ui-design-system.md#circular-cooldown-clipping-no-canvasgroup).
local function radialFillSequence(progress: number, filledAlpha: number, emptyAlpha: number): NumberSequence
	local clamped = math.clamp(progress, 0, 1)
	if clamped <= 0.005 then
		return NumberSequence.new(emptyAlpha)
	end
	if clamped >= 0.995 then
		return NumberSequence.new(filledAlpha)
	end
	local lo = math.max(clamped - 0.002, 0.001)
	local hi = math.min(clamped + 0.002, 0.999)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, filledAlpha),
		NumberSequenceKeypoint.new(lo, filledAlpha),
		NumberSequenceKeypoint.new(hi, emptyAlpha),
		NumberSequenceKeypoint.new(1, emptyAlpha),
	})
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
		Color = props.color or Theme.BORDER,
		Thickness = props.thickness or Theme.STROKE,
		Transparency = if props.transparency ~= nil then props.transparency else 0.15,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
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

-- Architectural steel plate with sharp 2px corners and an optional flush left/top semantic stripe.
-- `width` is a design unit like every other offset under a `Scaled.Frame` — never multiply one
-- by `Layout.scale()`, it is already scaled.
function ui.Panel(props)
	local automaticSize = if props.automaticSize ~= nil then props.automaticSize else Enum.AutomaticSize.Y
	local hasAccent = props.accentColor ~= nil
	local accentSide = props.accent or "left"
	local accentWidth = props.accentWidth or Theme.ACCENT_WIDTH

	local frameChildren: { [string]: any }
	if hasAccent then
		-- UIPadding shrinks every direct child, so when an accent bar is requested we put the
		-- padding on an inner Content frame and keep the stripe flush against the panel border.
		local contentChildren = table.clone(props.children or {})
		local pad = props.padding or 0
		if pad > 0 or hasAccent then
			contentChildren.Padding = React.createElement(ui.Pad, {
				top = pad + if accentSide == "top" then accentWidth else 0,
				bottom = pad,
				left = pad + if accentSide == "left" then accentWidth else 0,
				right = pad,
			})
		end
		local contentSize = if automaticSize == Enum.AutomaticSize.None
			then UDim2.fromScale(1, 1)
			elseif automaticSize == Enum.AutomaticSize.X then UDim2.new(0, 0, 1, 0)
			elseif automaticSize == Enum.AutomaticSize.XY then UDim2.fromOffset(0, 0)
			else UDim2.new(1, 0, 0, 0)

		frameChildren = {
			Corner = React.createElement(ui.Round, { radius = props.radius }),
			Edge = React.createElement(ui.Outline, {
				color = props.strokeColor,
				thickness = props.strokeThickness,
				transparency = props.strokeTransparency,
			}),
			Accent = React.createElement("Frame", {
				Size = if accentSide == "top" then UDim2.new(1, 0, 0, accentWidth) else UDim2.new(0, accentWidth, 1, 0),
				BackgroundColor3 = props.accentColor,
				BorderSizePixel = 0,
				ZIndex = (props.zIndex or 1) + 2,
			}),
			Content = React.createElement("Frame", {
				Size = contentSize,
				AutomaticSize = automaticSize,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ZIndex = (props.zIndex or 1) + 1,
			}, contentChildren),
		}
	else
		frameChildren = table.clone(props.children or {})
		frameChildren.Corner = React.createElement(ui.Round, { radius = props.radius })
		frameChildren.Edge = React.createElement(ui.Outline, {
			color = props.strokeColor,
			thickness = props.strokeThickness,
			transparency = props.strokeTransparency,
		})
		if props.padding then
			frameChildren.Padding = React.createElement(ui.Pad, { amount = props.padding })
		end
	end

	return React.createElement("Frame", {
		Name = props.name or "Panel",
		Size = props.size or UDim2.fromOffset(props.width or 0, 0),
		AutomaticSize = automaticSize,
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		BackgroundColor3 = props.color or Theme.PANEL,
		BackgroundTransparency = if props.transparency ~= nil then props.transparency else 0.08,
		BorderSizePixel = 0,
		LayoutOrder = props.order,
		Visible = props.visible,
		ZIndex = props.zIndex,
	}, frameChildren)
end

function ui.Title(props)
	return React.createElement("TextLabel", {
		Name = props.name,
		Size = props.size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = if props.automaticSize ~= nil then props.automaticSize else Enum.AutomaticSize.Y,
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
	local active = props.active == true
	return React.createElement("TextButton", {
		Name = props.name or "Button",
		Size = props.size or UDim2.new(1, 0, 0, Theme.BUTTON_HEIGHT),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		BackgroundColor3 = if active then Theme.HAZARD else Theme.STEEL,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Theme.TITLE_FONT,
		TextSize = props.textSize or 18,
		TextColor3 = if active then Theme.INK else Theme.TEXT,
		Text = props.text or "",
		LayoutOrder = props.order,
		Visible = props.visible,
		ZIndex = props.zIndex,
		-- Activated rather than MouseButton1Click: it is the one that means "tapped" on every
		-- input device, so a button written once works on a phone without a touch branch.
		[React.Event.Activated] = props.onActivated,
	}, {
		Corner = React.createElement(ui.Round, { radius = props.radius }),
		Edge = React.createElement(ui.Outline, {
			color = if active then Theme.HAZARD else Theme.BORDER,
		}),
	})
end

-- Machined circular actuator: dark steel gradient core with a semantic luminous outer ring.
-- Renders as a TextButton when `interactive` is true so touch presses sink and never reach the
-- camera; renders as a Frame when read-only so desktop telemetry never steals mouse clicks.
function ui.Actuator(props)
	local diameter = props.size or 56
	local ringColor = props.ringColor or Theme.HAZARD
	local fillColor = props.fillColor or ringColor
	local filledAlpha = if props.fillTransparency ~= nil then props.fillTransparency else 0.72
	local emptyAlpha = if props.emptyTransparency ~= nil then props.emptyTransparency else 1
	local baseZ = props.zIndex or 2
	local selected = props.selected == true
	local ringThickness = props.ringThickness or (if selected then Theme.ACTUATOR_STROKE + 1 else Theme.ACTUATOR_STROKE)

	local fillTransparency = nil
	if props.fill ~= nil then
		if type(props.fill) == "number" then
			fillTransparency = radialFillSequence(props.fill, filledAlpha, emptyAlpha)
		else
			fillTransparency = props.fill:map(function(value: number)
				return radialFillSequence(value, filledAlpha, emptyAlpha)
			end)
		end
	end

	local children: { [string]: any } = {
		Corner = React.createElement(ui.Round, { radius = Theme.CORNER_ROUND }),
		Steel = React.createElement("UIGradient", {
			Rotation = 90,
			Color = STEEL_GRADIENT,
		}),
		Ring = React.createElement(ui.Outline, {
			color = if selected then Theme.TEXT else ringColor,
			thickness = ringThickness,
			transparency = if props.ringTransparency ~= nil then props.ringTransparency else 0,
		}),
	}

	if props.emblem then
		children.Emblem = React.createElement("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = baseZ + 2,
		}, props.emblem)
	end

	if props.label ~= nil and props.label ~= "" then
		children.Label = React.createElement("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = if props.subLabel ~= nil then UDim2.fromScale(0.5, 0.42) else UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0.86, 0, 0, math.round(diameter * 0.34)),
			BackgroundTransparency = 1,
			Font = props.font or Theme.DISPLAY_FONT,
			TextSize = props.textSize or math.max(11, math.round(diameter * 0.24)),
			TextColor3 = props.textColor or Theme.TEXT,
			TextStrokeColor3 = Theme.INK,
			TextStrokeTransparency = 0.4,
			Text = props.label,
			ZIndex = baseZ + 3,
		})
	end

	if fillTransparency ~= nil then
		children.Fill = React.createElement("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = fillColor,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			ZIndex = baseZ + 1,
		}, {
			Corner = React.createElement(ui.Round, { radius = Theme.CORNER_ROUND }),
			Sweep = React.createElement("UIGradient", {
				Rotation = -90,
				Transparency = fillTransparency,
			}),
		})
	end

	if props.subLabel ~= nil then
		children.SubLabel = React.createElement("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = if props.emblem and (props.label == nil or props.label == "")
				then UDim2.fromScale(0.5, 0.5)
				else UDim2.fromScale(0.5, 0.72),
			Size = UDim2.new(0.84, 0, 0, math.round(diameter * 0.28)),
			BackgroundTransparency = 1,
			Font = if props.emblem then Theme.DISPLAY_FONT else Theme.MONO_FONT,
			TextSize = props.subTextSize or math.max(9, math.round(diameter * 0.17)),
			TextColor3 = props.subColor or Theme.MUTED,
			TextStrokeColor3 = Theme.INK,
			TextStrokeTransparency = if props.emblem then 0.2 else 1,
			Text = props.subLabel,
			ZIndex = baseZ + 3,
		})
	end

	if props.keycap and not props.hideKeycap then
		children.Keycap = React.createElement("TextLabel", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 4, 1, 4),
			Size = UDim2.fromOffset(0, 16),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = if selected then ringColor else Theme.INK,
			BackgroundTransparency = 0.05,
			BorderSizePixel = 0,
			Font = Theme.MONO_FONT,
			TextSize = 10,
			TextColor3 = if selected then Theme.INK else Theme.TEXT,
			Text = props.keycap,
			ZIndex = baseZ + 4,
		}, {
			Corner = React.createElement(ui.Round, { radius = Theme.CORNER }),
			Edge = React.createElement(ui.Outline, {
				color = if selected then ringColor else Theme.BORDER,
				thickness = 1,
				transparency = 0.1,
			}),
			Pad = React.createElement(ui.Pad, { left = 4, right = 4, top = 0, bottom = 0 }),
		})
	end

	local sharedProps: { [any]: any } = {
		Name = props.name or "Actuator",
		Size = UDim2.fromOffset(diameter, diameter),
		Position = props.position,
		AnchorPoint = props.anchorPoint or Vector2.new(1, 1),
		BackgroundColor3 = props.coreColor or Theme.STEEL,
		BackgroundTransparency = if props.transparency ~= nil then props.transparency else 0.06,
		BorderSizePixel = 0,
		Visible = props.visible,
		ZIndex = baseZ,
	}

	if props.interactive then
		sharedProps.Text = ""
		sharedProps.AutoButtonColor = false
		sharedProps.Active = true
		-- Track the InputObject's own state transition rather than relying on InputEnded on the
		-- button alone: if a thumb slides off the actuator before lifting, hold actions (Block,
		-- Heavy Charge) must still release cleanly.
		sharedProps[React.Event.InputBegan] = function(_, input: InputObject)
			if not isPointerInput(input) then
				return
			end
			if props.onPress then
				props.onPress()
			end
			if props.onRelease then
				local conn: RBXScriptConnection? = nil
				conn = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
					local state = input.UserInputState
					if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
						if conn then
							conn:Disconnect()
							conn = nil
						end
						props.onRelease()
					end
				end)
			end
		end
		return React.createElement("TextButton", sharedProps, children)
	end

	return React.createElement("Frame", sharedProps, children)
end

return ui
