--[[
	The start screen (plans/gdd/ui.md, plans/roadmap.md VS-01 / VS-13):
	Difficulty selector (Fácil, Normal, Difícil, Zona Muerta) paired with the universal Pillar 1
	loadout summary and a bold INICIAR RUN button. Everyone starts identical with the base sword
	and drafts their build from 1-of-3 upgrades during the run.

	Visible only while `World.RunState == "preparing"`.
]]

local ContextActionService = game:GetService("ContextActionService")
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
	local btnWidth = if props.compact then 90 else 132
	for idx, diffId in ipairs(Config.DIFFICULTY_ORDER) do
		local def = Config.DIFFICULTIES[diffId]
		if def then
			local selected = diffId == currentId
			buttons[diffId] = React.createElement("TextButton", {
				Name = `Diff_{diffId}`,
				LayoutOrder = idx,
				Size = UDim2.fromOffset(btnWidth, 36),
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
		padding = 12,
		accentColor = currentDef.color,
		accent = "left",
		strokeColor = currentDef.color,
	}, {
		List = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 8),
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
			Text = `DIFICULTAD DEL SECTOR ({Config.ROOMS_PER_FLOOR} SALAS · JEFE: OH)`,
		}),
		Row = React.createElement("Frame", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 38),
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

local function StartRunScreen(props)
	local metrics = Scaled.useLayout()
	local serverMode = hooks.useAttribute(props.world, "ServerMode")
	local runState = hooks.useAttribute(props.world, "RunState")
	local diffAttr = hooks.useAttribute(props.world, "Difficulty")
	local currentDifficulty = if Difficulty.isValid(diffAttr) then diffAttr else Config.DEFAULT_DIFFICULTY
	local currentDef = Difficulty.get(currentDifficulty)
	local pending, setPending = React.useState(false)

	React.useEffect(function()
		if runState ~= "preparing" then
			setPending(false)
		end
	end, { runState })

	if serverMode == "hub" or (runState ~= nil and runState ~= "preparing") then
		return nil
	end

	local available = metrics.room.X - 2 * ui.MARGIN
	local cardWidth = math.min(available, 620)

	local function startRun()
		if pending then
			return
		end
		setPending(true)
		Remotes.StartRun:FireServer()
	end

	return React.createElement(Scaled.Frame, nil, {
		-- Input-sinking backdrop while the pre-run screen is open.
		Backdrop = React.createElement("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = ui.INK,
			BackgroundTransparency = 0.14,
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
				TextSize = if metrics.compact then 24 else 30,
				TextColor3 = ui.TEXT,
				Text = "EL COMPLEJO  //  SECTOR 01",
			}),
			Subheading = React.createElement("TextLabel", {
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Font = ui.BODY_FONT,
				TextSize = 14,
				TextColor3 = ui.MUTED,
				TextWrapped = true,
				Text = "Todos inician iguales con la Espada Base. Al entrar elegirás tu primera habilidad y mejorarás tu build tras cada sala.",
			}),
			Difficulty = React.createElement(DifficultyBar, {
				currentId = currentDifficulty,
				compact = metrics.compact,
				maxWidth = available,
			}),
			Loadout = React.createElement(ui.Panel, {
				name = "BaseLoadout",
				order = 4,
				size = UDim2.new(0, cardWidth, 0, 0),
				padding = 14,
				accentColor = ui.HAZARD,
				accent = "left",
			}, {
				Stack = React.createElement("UIListLayout", {
					Padding = UDim.new(0, 6),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Title = React.createElement("TextLabel", {
					LayoutOrder = 1,
					Size = UDim2.new(1, 0, 0, 18),
					BackgroundTransparency = 1,
					Font = ui.MONO_FONT,
					TextSize = 12,
					TextColor3 = ui.HAZARD,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = "EQUIPO INICIAL UNIVERSAL  //  PISO 1 (5 SALAS)",
				}),
				Stats = React.createElement("TextLabel", {
					LayoutOrder = 2,
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					Font = ui.BODY_FONT,
					TextSize = 14,
					TextColor3 = ui.TEXT,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextWrapped = true,
					Text = `Vida {Config.PLAYER_MAX_HEALTH}  ·  Velocidad {Config.MOVE_SPEED}  ·  Espada Base (Combo 3 golpes + Ataque Pesado)  ·  Dash  ·  Bloqueo / Parry`,
				}),
				Progression = React.createElement("TextLabel", {
					LayoutOrder = 3,
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					Font = ui.MONO_FONT,
					TextSize = 12,
					TextColor3 = ui.MUTED,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextWrapped = true,
					Text = "Sin regeneración pasiva: cúrate con drops, Santuario o mejoras de Vida. Limpia cada sala y cruza la Puerta Norte hasta derrotar al Jefe Oh.",
				}),
			}),
			StartButton = React.createElement("TextButton", {
				Name = "StartRunButton",
				LayoutOrder = 5,
				Size = UDim2.fromOffset(math.min(cardWidth, 320), 48),
				BackgroundColor3 = currentDef.color,
				BorderSizePixel = 0,
				Font = ui.DISPLAY_FONT,
				TextSize = 18,
				TextColor3 = ui.INK,
				Text = if pending then "INICIANDO..." else "INICIAR RUN",
				[React.Event.Activated] = startRun,
			}, {
				Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
				Stroke = React.createElement(ui.Outline, { color = ui.TEXT, thickness = 1.5 }),
			}),
		}),
	})
end

local screen = {}

function screen.start()
	local world = workspace:WaitForChild("World")

	ContextActionService:BindActionAtPriority("StartRunConfirm", function(_, inputState: Enum.UserInputState)
		if world:GetAttribute("ServerMode") == "hub" then
			return Enum.ContextActionResult.Pass
		end
		local rs = world:GetAttribute("RunState")
		if rs ~= nil and rs ~= "preparing" then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			Remotes.StartRun:FireServer()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 60, Enum.KeyCode.Return, Enum.KeyCode.ButtonA)

	local function cycleDifficulty(delta: number)
		local order = Config.DIFFICULTY_ORDER
		if #order == 0 then
			return
		end
		local current = world:GetAttribute("Difficulty")
		local idx = table.find(order, current) or table.find(order, Config.DEFAULT_DIFFICULTY) or 1
		local nextIdx = ((idx - 1 + delta) % #order) + 1
		Remotes.ChooseDifficulty:FireServer(order[nextIdx])
	end

	ContextActionService:BindActionAtPriority("StartRunDiffPrev", function(_, inputState: Enum.UserInputState)
		local rs = world:GetAttribute("RunState")
		if rs ~= nil and rs ~= "preparing" then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			cycleDifficulty(-1)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 60, Enum.KeyCode.DPadLeft)

	ContextActionService:BindActionAtPriority("StartRunDiffNext", function(_, inputState: Enum.UserInputState)
		local rs = world:GetAttribute("RunState")
		if rs ~= nil and rs ~= "preparing" then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			cycleDifficulty(1)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 60, Enum.KeyCode.DPadRight)

	-- Above every other screen while open.
	return UI.mount("ClassSelect", function()
		return React.createElement(StartRunScreen, { world = world })
	end, { displayOrder = 50 })
end

return screen
