--[[
	The start screen (plans/gdd/ui.md, "ClassSelect"): difficulty selector (Fácil, Normal, Difícil,
	Zona Muerta) paired with the three test class cards (Tanque, Daño, Apoyo). While any player is
	still on it the enemies wait (ClassService).

	Everything it shows comes from Config.DIFFICULTIES, Config.CLASSES and Config.ABILITIES, and
	both difficulty (`World.Difficulty`) and class (`Player.Class`) are driven by replicated
	attributes written by the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local Difficulty = require(Shared.features.enemies.Difficulty)

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

local function DifficultyBar(props)
	local currentId = props.currentId
	local currentDef = Difficulty.get(currentId)
	local buttons: { [string]: any } = {
		List = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local btnWidth = if props.compact then 92 else 132
	for idx, diffId in ipairs(Config.DIFFICULTY_ORDER) do
		local def = Config.DIFFICULTIES[diffId]
		if def then
			local selected = diffId == currentId
			buttons[diffId] = React.createElement("TextButton", {
				Name = `Diff_{diffId}`,
				LayoutOrder = idx,
				Size = UDim2.fromOffset(btnWidth, 34),
				BackgroundColor3 = if selected then def.color else ui.STEEL,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Font = ui.DISPLAY_FONT,
				TextSize = if props.compact then 11 else 13,
				TextColor3 = if selected then ui.INK else ui.TEXT,
				Text = def.shortName,
				[React.Event.Activated] = function()
					Remotes.ChooseDifficulty:FireServer(diffId)
				end,
			}, {
				Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
				Stroke = React.createElement(ui.Outline, {
					color = if selected then ui.TEXT else def.color,
					thickness = if selected then 2 else 1.5,
				}),
			})
		end
	end

	local summary = string.format(
		"%s  ·  Enemigos ×%.2g  ·  Daño ×%.2g  ·  Vel. ×%.2g  ·  Vida ×%.2g",
		currentDef.description,
		currentDef.countMultiplier,
		currentDef.damageMultiplier,
		currentDef.speedMultiplier,
		currentDef.healthMultiplier
	)

	return React.createElement(ui.Panel, {
		name = "DifficultySelector",
		order = 3,
		size = UDim2.new(0, math.min(props.maxWidth, 620), 0, 0),
		padding = 10,
		accentColor = currentDef.color,
		accent = "left",
		strokeColor = currentDef.color,
	}, {
		List = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 6),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Title = React.createElement("TextLabel", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 16),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 12,
			TextColor3 = ui.MUTED,
			Text = "DIFICULTAD DEL SECTOR (6 OLEADAS · JEFE: OH)",
		}),
		Row = React.createElement("Frame", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 36),
			BackgroundTransparency = 1,
		}, buttons),
		Summary = React.createElement("TextLabel", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 11,
			TextColor3 = currentDef.color,
			TextWrapped = true,
			Text = summary,
		}),
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

local function ClassSelect(props)
	local player = Players.LocalPlayer
	local metrics = Scaled.useLayout()
	local current = hooks.useAttribute(player, "Class")
	local diffAttr = hooks.useAttribute(props.world, "Difficulty")
	local currentDifficulty = if Difficulty.isValid(diffAttr) then diffAttr else Config.DEFAULT_DIFFICULTY
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
				Padding = UDim.new(0, 12),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Heading = React.createElement("TextLabel", {
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundTransparency = 1,
				Font = ui.TITLE_FONT,
				TextSize = 28,
				TextColor3 = ui.TEXT,
				Text = "Prepara tu incursión",
			}),
			Subheading = React.createElement("TextLabel", {
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, 18),
				BackgroundTransparency = 1,
				Font = ui.BODY_FONT,
				TextSize = 14,
				TextColor3 = ui.MUTED,
				Text = "Elige la dificultad y tu rol. Los enemigos esperan a que empieces.",
			}),
			Difficulty = React.createElement(DifficultyBar, {
				currentId = currentDifficulty,
				compact = metrics.compact,
				maxWidth = available,
			}),
			Cards = React.createElement("Frame", {
				LayoutOrder = 4,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, cards),
		}),
	})
end

local screen = {}

function screen.start()
	local world = workspace:WaitForChild("World")
	-- Above every other screen: while it is open nothing else should take a press.
	return UI.mount("ClassSelect", function()
		return React.createElement(ClassSelect, { world = world })
	end, { displayOrder = 50 })
end

return screen
