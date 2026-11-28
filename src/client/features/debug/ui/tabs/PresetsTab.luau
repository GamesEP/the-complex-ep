local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DebugCommands = require(Shared.features.debug.DebugCommands)

local Client = script:FindFirstAncestor("Client")
local ui = require(Client.ui.theme.Widgets)

local DevPrimitives = require(script.Parent.Parent.DevPrimitives)

local function PresetsTab()
	local children: { [string]: any } = {
		Layout = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Header = React.createElement(DevPrimitives.SectionHeader, {
			text = "Escenarios de Playtest en 1 Clic",
			order = 1,
		}),
	}

	for idx, presetId in ipairs(DebugCommands.PRESET_ORDER) do
		local def = DebugCommands.PRESETS[presetId]
		if def then
			children[`Preset_{presetId}`] = React.createElement("TextButton", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = ui.STEEL,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
				LayoutOrder = idx + 1,
				[React.Event.Activated] = function()
					DevPrimitives.send("runPreset", { presetId = presetId })
				end,
			}, {
				Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
				Edge = React.createElement(ui.Outline, { color = ui.BORDER, thickness = 1 }),
				Pad = React.createElement(ui.Pad, { left = 10, right = 10, top = 7, bottom = 7 }),
				Layout = React.createElement("UIListLayout", {
					Padding = UDim.new(0, 2),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Title = React.createElement(ui.Title, {
					text = def.title,
					font = ui.TITLE_FONT,
					textSize = 13,
					color = if presetId == "clean_reset" then ui.STRIKE else ui.HAZARD,
					order = 1,
				}),
				Desc = React.createElement(ui.Title, {
					text = def.description,
					font = ui.BODY_FONT,
					textSize = 11,
					color = ui.MUTED,
					order = 2,
				}),
			})
		end
	end

	return React.createElement("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, children)
end

return PresetsTab
