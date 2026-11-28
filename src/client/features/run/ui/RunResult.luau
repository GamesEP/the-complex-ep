--[[
	End-of-run summary plate (plans/gdd/ui.md, plans/roadmap.md VS-14).

	Visible only when `World.RunState` is `"victory"` (Boss Oh defeated in Room 5) or `"defeat"`
	(squad wipe). Displays rooms cleared, elapsed run time, hostiles defeated, difficulty, and a
	one-click REINTENTAR button firing `Remotes.RetryRun`.
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
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local RESULT_ATTRIBUTES = { "RunState", "Floor", "FloorCount", "RoomsCleared", "RoomCount", "TotalRoomCount", "RunElapsed", "RunKills", "Difficulty" }

local function formatDuration(seconds: number): string
	local total = math.max(math.floor(seconds + 0.5), 0)
	local mins = math.floor(total / 60)
	local secs = total % 60
	return string.format("%02d:%02d", mins, secs)
end

local function StatRow(props)
	return React.createElement("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
	}, {
		Label = React.createElement("TextLabel", {
			Size = UDim2.fromScale(0.58, 1),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 13,
			TextColor3 = ui.MUTED,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = props.label,
		}),
		Value = React.createElement("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromScale(0.42, 1),
			BackgroundTransparency = 1,
			Font = ui.DISPLAY_FONT,
			TextSize = 15,
			TextColor3 = props.color or ui.TEXT,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = props.value,
		}),
	})
end

local function RunResult(props)
	local metrics = Scaled.useLayout()
	local state = hooks.useAttributes(props.world, RESULT_ATTRIBUTES)
	local runState = state.RunState
	local pending, setPending = React.useState(false)

	React.useEffect(function()
		if runState ~= "victory" and runState ~= "defeat" then
			setPending(false)
		end
	end, { runState })

	if runState ~= "victory" and runState ~= "defeat" then
		return nil
	end

	local isVictory = runState == "victory"
	local accent = if isVictory then ui.VITAL else ui.STRIKE
	local diff = Difficulty.get(state.Difficulty)
	local floor = if type(state.Floor) == "number" then math.floor(state.Floor) else 1
	local floorCount = if type(state.FloorCount) == "number" then math.floor(state.FloorCount) else Config.FLOORS_PER_RUN
	local roomsCleared = if type(state.RoomsCleared) == "number" then math.floor(state.RoomsCleared) else 0
	local totalRoomCount = if type(state.TotalRoomCount) == "number"
		then math.floor(state.TotalRoomCount)
		else Config.ROOMS_PER_FLOOR * floorCount
	local elapsed = if type(state.RunElapsed) == "number" then state.RunElapsed else 0
	local kills = if type(state.RunKills) == "number" then math.floor(state.RunKills) else 0
	local panelWidth = math.min(if metrics.compact then 320 else 420, metrics.room.X - 2 * ui.MARGIN)
	local floorTag = string.format("PISO %02d/%02d", floor, floorCount)

	local function onRetry()
		if pending then
			return
		end
		setPending(true)
		Remotes.RetryRun:FireServer()
	end

	local function onReturnHub()
		if pending then
			return
		end
		setPending(true)
		Remotes.ReturnToHub:FireServer()
	end

	return React.createElement(Scaled.Frame, nil, {
		Backdrop = React.createElement("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = ui.INK,
			BackgroundTransparency = 0.22,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Active = true,
		}),
		Plate = React.createElement(ui.Panel, {
			name = "RunResultPlate",
			width = panelWidth,
			padding = 20,
			accentColor = accent,
			accent = "left",
			accentWidth = 5,
			strokeColor = accent,
			strokeThickness = 2,
			anchorPoint = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5),
		}, {
			List = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 10),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Badge = React.createElement("TextLabel", {
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 16),
				BackgroundTransparency = 1,
				Font = ui.MONO_FONT,
				TextSize = 12,
				TextColor3 = accent,
				Text = if isVictory then `{floorTag}  //  AMENAZA NEUTRALIZADA` else `{floorTag}  //  ESCUADRÓN DERROTADO`,
			}),
			Heading = React.createElement("TextLabel", {
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, 34),
				BackgroundTransparency = 1,
				Font = ui.TITLE_FONT,
				TextSize = if metrics.compact then 26 else 32,
				TextColor3 = ui.TEXT,
				Text = if isVictory then "COMPLEJO DESPEJADO" else "CAÍDA EN COMBATE",
			}),
			Subtitle = React.createElement("TextLabel", {
				LayoutOrder = 3,
				Size = UDim2.new(1, 0, 0, 18),
				BackgroundTransparency = 1,
				Font = ui.BODY_FONT,
				TextSize = 13,
				TextColor3 = ui.MUTED,
				Text = if isVictory
					then (if floorCount > 1
						then "Has vencido a OhMyGon y completado las 5 plantas."
						else "Has vencido al Jefe Oh y completado el sector.")
					else "Vuelve a intentarlo con una nueva combinación de mejoras.",
			}),
			Divider = React.createElement("Frame", {
				LayoutOrder = 4,
				Size = UDim2.new(1, 0, 0, 1),
				BackgroundColor3 = ui.BORDER,
				BorderSizePixel = 0,
			}),
			Stats = React.createElement("Frame", {
				LayoutOrder = 5,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}, {
				Stack = React.createElement("UIListLayout", {
					Padding = UDim.new(0, 4),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Rooms = React.createElement(StatRow, {
					order = 1,
					label = "SALAS SUPERADAS",
					value = `{roomsCleared} / {totalRoomCount}`,
					color = accent,
				}),
				Time = React.createElement(StatRow, {
					order = 2,
					label = "TIEMPO DE RUN",
					value = formatDuration(elapsed),
				}),
				Kills = React.createElement(StatRow, {
					order = 3,
					label = "HOSTILES ELIMINADOS",
					value = tostring(kills),
				}),
				Diff = React.createElement(StatRow, {
					order = 4,
					label = "DIFICULTAD",
					value = diff.shortName,
					color = diff.color,
				}),
			}),
			Retry = React.createElement("TextButton", {
				Name = "RetryButton",
				LayoutOrder = 6,
				Size = UDim2.new(1, 0, 0, 44),
				BackgroundColor3 = accent,
				BorderSizePixel = 0,
				Font = ui.DISPLAY_FONT,
				TextSize = 16,
				TextColor3 = ui.INK,
				Text = if pending then "CARGANDO..." else "REINTENTAR RUN",
				[React.Event.Activated] = onRetry,
			}, {
				Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
			}),
			ReturnHub = React.createElement("TextButton", {
				Name = "ReturnHubButton",
				LayoutOrder = 7,
				Size = UDim2.new(1, 0, 0, 38),
				BackgroundColor3 = ui.STEEL,
				BorderSizePixel = 0,
				Font = ui.DISPLAY_FONT,
				TextSize = 14,
				TextColor3 = ui.TEXT,
				Text = "VOLVER AL HUB",
				[React.Event.Activated] = onReturnHub,
			}, {
				Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
				Stroke = React.createElement(ui.Outline, { color = ui.BORDER, thickness = 1.5 }),
			}),
		}),
	})
end

local screen = {}

function screen.start()
	local world = workspace:WaitForChild("World")

	ContextActionService:BindActionAtPriority("RunResultRetry", function(_, inputState: Enum.UserInputState)
		local rs = world:GetAttribute("RunState")
		if rs ~= "victory" and rs ~= "defeat" then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			Remotes.RetryRun:FireServer()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 60, Enum.KeyCode.Return, Enum.KeyCode.ButtonA)

	return UI.mount("RunResult", function()
		return React.createElement(RunResult, { world = world })
	end, { displayOrder = 55 })
end

return screen
