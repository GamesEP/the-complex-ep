--[[
	Shared Hazard Arc micro-components and command sender for the in-game Dev Panel tabs.
	Every button uses `React.Event.Activated` so desktop clicks and mobile touch taps behave identically.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.core.Net.Remotes)

local Client = script:FindFirstAncestor("Client")
local ui = require(Client.ui.theme.Widgets)

local DevPrimitives = {}

function DevPrimitives.send(action: string, payload: { [string]: any }?)
	Remotes.AdminCommand:FireServer(action, payload or {})
end

function DevPrimitives.SectionHeader(props: { text: string, order: number })
	return React.createElement(ui.Title, {
		text = props.text:upper(),
		font = ui.DISPLAY_FONT,
		textSize = 11,
		color = Color3.fromRGB(186, 198, 212),
		order = props.order,
	})
end

function DevPrimitives.ChipButton(props: {
	text: string,
	active: boolean?,
	accent: Color3?,
	width: number?,
	height: number?,
	textSize: number?,
	padX: number?,
	order: number?,
	onActivated: () -> (),
})
	local active = props.active == true
	local accent = props.accent or ui.HAZARD
	local height = props.height or 25
	local padX = props.padX or 7
	local size = if props.width then UDim2.fromOffset(props.width, height) else UDim2.new(0, 0, 0, height)
	local autoSize = if props.width then Enum.AutomaticSize.None else Enum.AutomaticSize.X

	return React.createElement("TextButton", {
		Size = size,
		AutomaticSize = autoSize,
		BackgroundColor3 = if active then accent else ui.STEEL_TOP,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = ui.TITLE_FONT,
		TextSize = props.textSize or 12,
		TextColor3 = if active then ui.INK else ui.TEXT,
		Text = props.text,
		LayoutOrder = props.order,
		[React.Event.Activated] = props.onActivated,
	}, {
		Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
		Edge = React.createElement(ui.Outline, {
			color = if active then accent else ui.BORDER,
			thickness = 1,
		}),
		Pad = React.createElement(ui.Pad, { left = padX, right = padX, top = 3, bottom = 3 }),
	})
end

function DevPrimitives.WrapRow(props: { order: number, children: { [string]: any }? })
	local children = table.clone(props.children or {})
	children.Layout = React.createElement("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Wraps = true,
		Padding = UDim.new(0, 5),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	return React.createElement("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = props.order,
	}, children)
end

return DevPrimitives
