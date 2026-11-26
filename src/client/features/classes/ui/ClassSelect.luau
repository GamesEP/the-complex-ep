--[[
	The class selection screen (plans/gdd/ui.md, "ClassSelect"): three cards, one per test class,
	shown until the player picks. While any player is still on it the enemies wait (ClassService).

	Everything it shows comes from Config.CLASSES and Config.ABILITIES, so tuning a class never
	means editing this file. It opens and closes on the replicated `Class` attribute, which the
	server sets when it accepts the choice — the screen never decides for itself that a class
	was chosen. Picking fires `ChooseClass` and waits for that attribute.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Client = script:FindFirstAncestor("Client")

local UI = require(Client.ui.Mount)
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local CARD_GAP = 16
local MAX_CARD_WIDTH = 260

local function Line(props)
	return React.createElement(ui.Title, {
		text = props.text,
		font = props.font or ui.BODY_FONT,
		textSize = props.textSize or 14,
		color = props.color or ui.TEXT,
		order = props.order,
	})
end

local function Card(props)
	local class = props.class
	local abilityNames = {}
	for _, abilityId in ipairs(class.abilities) do
		local ability = Config.ABILITIES[abilityId]
		table.insert(abilityNames, if ability then ability.name else abilityId)
	end
	local damagePercent = math.round(class.damageMultiplier * 100)

	return React.createElement(ui.Panel, {
		name = props.classId,
		width = props.width,
		padding = 14,
		order = props.order,
	}, {
		List = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Name = React.createElement(Line, {
			text = class.displayName,
			font = ui.TITLE_FONT,
			textSize = 24,
			color = class.color,
			order = 1,
		}),
		Description = React.createElement(Line, { text = class.description, color = ui.MUTED, order = 2 }),
		Stats = React.createElement(Line, {
			text = `Vida {class.maxHealth}  ·  Velocidad {class.moveSpeed}  ·  Daño {damagePercent} %`,
			textSize = 13,
			order = 3,
		}),
		Weapon = React.createElement(Line, { text = `Arma: {class.weaponName}`, textSize = 13, order = 4 }),
		Abilities = React.createElement(Line, {
			text = `Habilidades: {table.concat(abilityNames, ", ")}`,
			textSize = 13,
			order = 5,
		}),
		Passive = React.createElement(Line, {
			text = `Pasiva: {class.passive}`,
			textSize = 13,
			color = ui.HIGHLIGHT,
			order = 6,
		}),
		Choose = React.createElement(ui.Button, {
			text = "Elegir",
			order = 7,
			active = props.pending,
			onActivated = props.onChoose,
		}),
	})
end

local function ClassSelect()
	local player = Players.LocalPlayer
	local metrics = Scaled.useLayout()
	local current = hooks.useAttribute(player, "Class")
	-- Which card was pressed, so a second press does not fire again while the server answers.
	local pending, setPending = React.useState(nil :: string?)

	if type(current) == "string" and current ~= "" then
		return nil
	end

	local count = #Config.CLASS_ORDER
	local available = metrics.room.X - 2 * ui.MARGIN
	-- Side by side while three fit at a readable width; stacked on a narrow (phone) screen.
	local stacked = metrics.compact or available < count * 200 + (count - 1) * CARD_GAP
	local cardWidth = if stacked
		then math.min(MAX_CARD_WIDTH * 1.4, available)
		else math.min(MAX_CARD_WIDTH, (available - (count - 1) * CARD_GAP) / count)

	local cards = {
		List = React.createElement("UIListLayout", {
			FillDirection = if stacked then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, CARD_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, classId in ipairs(Config.CLASS_ORDER) do
		local class = Config.CLASSES[classId]
		if class then
			cards[classId] = React.createElement(Card, {
				classId = classId,
				class = class,
				width = cardWidth,
				order = index,
				pending = pending == classId,
				onChoose = function()
					if pending then
						return
					end
					setPending(classId)
					Remotes.ChooseClass:FireServer(classId)
				end,
			})
		end
	end

	return React.createElement(Scaled.Frame, nil, {
		-- A button, not a frame, so it sinks the input behind it while the screen is open
		-- (CLAUDE.md: a Frame does not sink input).
		Backdrop = React.createElement("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = ui.INK,
			-- Dark enough that the HUD underneath (the wave counter sits right behind the
			-- heading) does not read through it.
			BackgroundTransparency = 0.12,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Active = true,
		}),
		Content = React.createElement("ScrollingFrame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, ui.MARGIN + Layout.inset()),
			Size = UDim2.new(1, -2 * ui.MARGIN, 1, -(2 * ui.MARGIN + Layout.inset())),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = true,
			ScrollBarThickness = 4,
			CanvasSize = UDim2.fromScale(0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
		}, {
			List = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 14),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Heading = React.createElement("TextLabel", {
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 34),
				BackgroundTransparency = 1,
				Font = ui.TITLE_FONT,
				TextSize = 30,
				TextColor3 = ui.TEXT,
				Text = "Elige tu clase",
			}),
			Subheading = React.createElement("TextLabel", {
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, 20),
				BackgroundTransparency = 1,
				Font = ui.BODY_FONT,
				TextSize = 15,
				TextColor3 = ui.MUTED,
				Text = "Los enemigos esperan a que elijas.",
			}),
			Cards = React.createElement("Frame", {
				LayoutOrder = 3,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, cards),
		}),
	})
end

local screen = {}

function screen.start()
	-- Above every other screen: while it is open nothing else should take a press.
	return UI.mount("ClassSelect", ClassSelect, { displayOrder = 50 })
end

return screen
