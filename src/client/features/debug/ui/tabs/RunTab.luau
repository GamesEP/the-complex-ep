local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local Client = script:FindFirstAncestor("Client")
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local DevPrimitives = require(script.Parent.Parent.DevPrimitives)

local WORLD_ATTRS = { "Room", "RoomCount", "RoomName", "RunState", "Difficulty", "DoorOpen", "DebugSandbox" }

local function RunTab(props: { world: Instance })
	local world = hooks.useAttributes(props.world, WORLD_ATTRS)
	local currentRoom = world.Room or 1
	local currentDiff = world.Difficulty or Config.DEFAULT_DIFFICULTY
	local runState = world.RunState or "preparing"
	local sandbox = world.DebugSandbox == true

	local roomButtons: { [string]: any } = {}
	for i = 1, #Config.FLOOR_ROOMS do
		local def = Config.FLOOR_ROOMS[i]
		local label = if def.isBossRoom then `R{i} BOSS` else `R{i}`
		roomButtons[`Room{i}`] = React.createElement(DevPrimitives.ChipButton, {
			text = label,
			active = currentRoom == i and runState == "fighting",
			accent = if def.isBossRoom then ui.STRIKE else ui.HAZARD,
			order = i,
			onActivated = function()
				DevPrimitives.send("jumpRoom", { room = i })
			end,
		})
	end

	local diffButtons: { [string]: any } = {}
	for i, diffId in ipairs(Config.DIFFICULTY_ORDER) do
		local def = Config.DIFFICULTIES[diffId]
		diffButtons[`Diff_{diffId}`] = React.createElement(DevPrimitives.ChipButton, {
			text = def.shortName,
			active = currentDiff == diffId,
			accent = def.color,
			order = i,
			onActivated = function()
				DevPrimitives.send("setDifficulty", { difficulty = diffId })
			end,
		})
	end

	return React.createElement("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, {
		Layout = React.createElement("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Summary = React.createElement(ui.Title, {
			text = `Estado: {tostring(runState):upper()} · Sala {currentRoom}/{world.RoomCount or 5} ({world.RoomName or "-"})`,
			font = ui.MONO_FONT,
			textSize = 11,
			color = ui.KINETIC,
			order = 1,
		}),
		RoomsHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Saltar a Sala", order = 2 }),
		RoomsRow = React.createElement(DevPrimitives.WrapRow, { order = 3 }, roomButtons),

		FlowHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Control de Sala y Oleadas", order = 4 }),
		FlowRow = React.createElement(DevPrimitives.WrapRow, { order = 5 }, {
			ClearRoom = React.createElement(DevPrimitives.ChipButton, {
				text = "Limpiar Sala",
				accent = ui.VITAL,
				order = 1,
				onActivated = function()
					DevPrimitives.send("clearRoom", {})
				end,
			}),
			OpenDoor = React.createElement(DevPrimitives.ChipButton, {
				text = if world.DoorOpen then "Puerta Abierta" else "Abrir Puerta",
				active = world.DoorOpen == true,
				accent = ui.VITAL,
				order = 2,
				onActivated = function()
					DevPrimitives.send("openDoor", {})
				end,
			}),
			Sandbox = React.createElement(DevPrimitives.ChipButton, {
				text = if sandbox then "Sandbox: ON" else "Sandbox: OFF",
				active = sandbox,
				accent = ui.KINETIC,
				order = 3,
				onActivated = function()
					DevPrimitives.send("setSandbox", { enabled = not sandbox })
				end,
			}),
		}),

		DiffHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Dificultad en Vivo", order = 6 }),
		DiffRow = React.createElement(DevPrimitives.WrapRow, { order = 7 }, diffButtons),

		StateHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Forzar Estado de Run", order = 8 }),
		StateRow = React.createElement(DevPrimitives.WrapRow, { order = 9 }, {
			Preparing = React.createElement(DevPrimitives.ChipButton, {
				text = "Preparing",
				active = runState == "preparing",
				order = 1,
				onActivated = function()
					DevPrimitives.send("forceRunState", { state = "preparing" })
				end,
			}),
			Victory = React.createElement(DevPrimitives.ChipButton, {
				text = "Victory",
				active = runState == "victory",
				accent = ui.VITAL,
				order = 2,
				onActivated = function()
					DevPrimitives.send("forceRunState", { state = "victory" })
				end,
			}),
			Defeat = React.createElement(DevPrimitives.ChipButton, {
				text = "Defeat",
				active = runState == "defeat",
				accent = ui.STRIKE,
				order = 3,
				onActivated = function()
					DevPrimitives.send("forceRunState", { state = "defeat" })
				end,
			}),
		}),

		PlayerHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Posición y Respawn", order = 10 }),
		PlayerRow = React.createElement(DevPrimitives.WrapRow, { order = 11 }, {
			Teleport = React.createElement(DevPrimitives.ChipButton, {
				text = "TP a Spawn",
				order = 1,
				onActivated = function()
					DevPrimitives.send("teleportSpawn", {})
				end,
			}),
			Respawn = React.createElement(DevPrimitives.ChipButton, {
				text = "Respawn (Test UI)",
				accent = ui.HEAVY,
				order = 2,
				onActivated = function()
					DevPrimitives.send("respawnPlayer", {})
				end,
			}),
		}),
	})
end

return RunTab
