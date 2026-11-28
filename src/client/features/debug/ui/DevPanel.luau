--[[
	In-game Admin Dev Panel (Hazard Arc styled collapsible drawer + quick-action strip).

	Mounted only in non-production environments by `Bootstrap.client.luau` (matching `BuildStamp`),
	and additionally gated on `LocalPlayer:GetAttribute("IsAdmin")` (or `Environment.isStudio()`).
	Toggled with `Config.DEBUG_TOGGLE_KEY` (`F4`) on PC or via the bottom-left `DEV` pill on touch/mouse.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Environment = require(Shared.core.Environment)
local Remotes = require(Shared.core.Net.Remotes)

local Client = script:FindFirstAncestor("Client")
local UI = require(Client.ui.Mount)
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local DebugStore = require(script.Parent.Parent.stores.DebugStore)
local EnemyInspector = require(script.Parent.Parent.EnemyInspector)
local HitboxVisualizer = require(script.Parent.Parent.HitboxVisualizer)
local CombatLogPanel = require(script.Parent.CombatLogPanel)
local DebugMetrics = require(script.Parent.DebugMetrics)
local DevPrimitives = require(script.Parent.DevPrimitives)
local RunTab = require(script.Parent.tabs.RunTab)
local EnemiesTab = require(script.Parent.tabs.EnemiesTab)
local BuildTab = require(script.Parent.tabs.BuildTab)
local CheatsTab = require(script.Parent.tabs.CheatsTab)
local PresetsTab = require(script.Parent.tabs.PresetsTab)
local OverlaysTab = require(script.Parent.tabs.OverlaysTab)

local TAB_META = {
	{ id = "run", label = "Run" },
	{ id = "enemies", label = "Enem" },
	{ id = "build", label = "Build" },
	{ id = "cheats", label = "Cheats" },
	{ id = "presets", label = "Presets" },
	{ id = "overlays", label = "Overlay" },
}

local QUICK_WORLD_ATTRS = { "DebugSandbox" }
local QUICK_PLAYER_ATTRS = { "IsAdmin", "DebugGodMode", "DebugNoCooldowns" }

export type StartOptions = {
	setArenaTheme: ((string?) -> ())?,
	setTonemapper: ((string?) -> ())?,
}

local optionsRef: StartOptions = {}

local function QuickActionStrip(props: { world: Instance, player: Player, room: Vector2 })
	local worldAttrs = hooks.useAttributes(props.world, QUICK_WORLD_ATTRS)
	local playerAttrs = hooks.useAttributes(props.player, QUICK_PLAYER_ATTRS)
	local god = playerAttrs.DebugGodMode == true
	local noCd = playerAttrs.DebugNoCooldowns == true
	local sandbox = worldAttrs.DebugSandbox == true

	-- Bottom-center sits in open space between bottom-left BuildStamp/pills and bottom-right combat
	-- actuators, keeping the top-left HP Vitals bar and top-center SectorBar/UpgradeChoice clear.
	-- Never pass `zIndex > 1` on `ui.Panel`: ScreenGuis here use ZIndexBehavior.Global, so a
	-- parent Panel with ZIndex > 1 draws its dark background ON TOP OF all ZIndex = 1 children.
	return React.createElement(ui.Panel, {
		name = "DevQuickBar",
		automaticSize = Enum.AutomaticSize.XY,
		padding = 6,
		transparency = 0.10,
		accentColor = ui.HAZARD,
		accent = "left",
		anchorPoint = Vector2.new(0.5, 1),
		position = UDim2.fromOffset(math.floor(props.room.X * 0.5), props.room.Y - ui.MARGIN),
	}, {
		Layout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 5),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		God = React.createElement(DevPrimitives.ChipButton, {
			text = "God",
			active = god,
			accent = ui.VITAL,
			height = 24,
			order = 1,
			onActivated = function()
				DevPrimitives.send("setGodMode", { enabled = not god })
			end,
		}),
		NoCd = React.createElement(DevPrimitives.ChipButton, {
			text = "NoCD",
			active = noCd,
			accent = ui.KINETIC,
			height = 24,
			order = 2,
			onActivated = function()
				DevPrimitives.send("setNoCooldowns", { enabled = not noCd })
			end,
		}),
		KillAll = React.createElement(DevPrimitives.ChipButton, {
			text = "Kill All",
			accent = ui.STRIKE,
			height = 24,
			order = 3,
			onActivated = function()
				DevPrimitives.send("killAllEnemies", {})
			end,
		}),
		ClearRoom = React.createElement(DevPrimitives.ChipButton, {
			text = "Clear",
			accent = ui.VITAL,
			height = 24,
			order = 4,
			onActivated = function()
				DevPrimitives.send("clearRoom", {})
			end,
		}),
		BossOh = React.createElement(DevPrimitives.ChipButton, {
			text = "Boss Oh",
			accent = ui.STRIKE,
			height = 24,
			order = 5,
			onActivated = function()
				DevPrimitives.send("jumpRoom", { room = 5 })
			end,
		}),
		Offer = React.createElement(DevPrimitives.ChipButton, {
			text = "+Offer",
			accent = ui.HAZARD,
			height = 24,
			order = 6,
			onActivated = function()
				DevPrimitives.send("pushUpgradeOffer", { count = 1, isStarter = false })
			end,
		}),
		Sandbox = React.createElement(DevPrimitives.ChipButton, {
			text = "Sandbox",
			active = sandbox,
			accent = ui.KINETIC,
			height = 24,
			order = 7,
			onActivated = function()
				DevPrimitives.send("setSandbox", { enabled = not sandbox })
			end,
		}),
	})
end

local function DevPanelApp(props: { world: Instance, player: Player })
	local metrics = Scaled.useLayout()
	local isOpen = hooks.useAtom(DebugStore.isOpen)
	local activeTab = hooks.useAtom(DebugStore.activeTab)
	local quickVisible = hooks.useAtom(DebugStore.quickBarVisible)
	local overlays = hooks.useAtom(DebugStore.overlays)
	local status = hooks.useAtom(DebugStore.lastCommandStatus)
	local isAdminAttr = hooks.useAttribute(props.player, "IsAdmin")

	local allowed = Environment.isStudio() or isAdminAttr == true
	if not allowed then
		return nil
	end

	-- Compact 316px drawer stays cleanly to the left of the top-center UpgradeChoice 3-card strip,
	-- and starts below the top-left Vitals HP plate so the player's own HP stays readable at all times.
	local panelWidth = math.min(316, metrics.room.X - 2 * ui.MARGIN)
	local drawerTop = Layout.inset() + 86
	local drawerHeight = math.clamp(metrics.room.Y - drawerTop - 76, 220, 480)

	local tabButtons: { [string]: any } = {
		Layout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, 3),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, meta in ipairs(TAB_META) do
		tabButtons[`Tab_{meta.id}`] = React.createElement(DevPrimitives.ChipButton, {
			text = meta.label,
			active = activeTab == meta.id,
			accent = ui.HAZARD,
			height = 24,
			textSize = 11,
			padX = 5,
			order = i,
			onActivated = function()
				DebugStore.setTab(meta.id)
			end,
		})
	end

	local tabContent: any = nil
	if activeTab == "run" then
		tabContent = React.createElement(RunTab, { world = props.world })
	elseif activeTab == "enemies" then
		tabContent = React.createElement(EnemiesTab, { world = props.world })
	elseif activeTab == "build" then
		tabContent = React.createElement(BuildTab, { player = props.player })
	elseif activeTab == "cheats" then
		tabContent = React.createElement(CheatsTab, { player = props.player })
	elseif activeTab == "presets" then
		tabContent = React.createElement(PresetsTab)
	elseif activeTab == "overlays" then
		tabContent = React.createElement(OverlaysTab, {
			player = props.player,
			setArenaTheme = optionsRef.setArenaTheme,
			setTonemapper = optionsRef.setTonemapper,
		})
	end

	-- Bottom-left pills sit cleanly beside BuildStamp (190px wide) so mobile testers can reach them.
	local pillX = math.min(ui.MARGIN + 198, metrics.room.X - 140)
	local pillY = metrics.room.Y - ui.MARGIN

	return React.createElement(Scaled.Frame, nil, {
		TogglePills = React.createElement("Frame", {
			Size = UDim2.fromOffset(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromOffset(pillX, pillY),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, {
			Layout = React.createElement("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			DevPill = React.createElement(DevPrimitives.ChipButton, {
				text = if isOpen then "DEV [F4] ×" else "DEV [F4]",
				active = isOpen,
				accent = ui.HAZARD,
				height = 28,
				order = 1,
				onActivated = DebugStore.toggleOpen,
			}),
			QuickPill = React.createElement(DevPrimitives.ChipButton, {
				text = "QUICK",
				active = quickVisible,
				accent = ui.KINETIC,
				height = 28,
				order = 2,
				onActivated = DebugStore.toggleQuickBar,
			}),
		}),

		QuickBar = if quickVisible
			then React.createElement(QuickActionStrip, {
				world = props.world,
				player = props.player,
				room = metrics.room,
			})
			else nil,

		MetricsOverlay = if overlays.metrics
			then React.createElement(DebugMetrics, {
				world = props.world,
				player = props.player,
			})
			else nil,

		CombatLogOverlay = if overlays.combatLog
			then React.createElement(CombatLogPanel, {
				topY = Layout.inset() + (if overlays.metrics then 96 else 12),
			})
			else nil,

		Drawer = if isOpen
			then React.createElement(ui.Panel, {
				name = "DevDrawer",
				size = UDim2.fromOffset(panelWidth, drawerHeight),
				automaticSize = Enum.AutomaticSize.None,
				padding = 10,
				transparency = 0.06,
				accentColor = ui.HAZARD,
				accent = "top",
				position = UDim2.fromOffset(ui.MARGIN, drawerTop),
			}, {
				Header = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 24),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
				}, {
					Title = React.createElement(ui.Title, {
						text = "THE COMPLEX // ADMIN DEV PANEL",
						font = ui.DISPLAY_FONT,
						textSize = 13,
						color = ui.HAZARD,
						size = UDim2.new(1, -30, 1, 0),
						automaticSize = Enum.AutomaticSize.None,
					}),
					CloseWrap = React.createElement("Frame", {
						Size = UDim2.fromOffset(24, 22),
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						BackgroundTransparency = 1,
						BorderSizePixel = 0,
					}, {
						CloseBtn = React.createElement(DevPrimitives.ChipButton, {
							text = "×",
							width = 24,
							height = 22,
							padX = 0,
							accent = ui.STRIKE,
							onActivated = function()
								DebugStore.setOpen(false)
							end,
						}),
					}),
				}),

				Tabs = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 26),
					Position = UDim2.fromOffset(0, 28),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
				}, tabButtons),

				Divider = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 1),
					Position = UDim2.fromOffset(0, 58),
					BackgroundColor3 = ui.BORDER,
					BorderSizePixel = 0,
				}),

				-- Active = true sinks pointer/touch drags so scrolling the Dev Panel never rotates IsoCamera.
				Body = React.createElement("ScrollingFrame", {
					Size = UDim2.new(1, 0, 1, -90),
					Position = UDim2.fromOffset(0, 64),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Active = true,
					AutomaticCanvasSize = Enum.AutomaticSize.Y,
					CanvasSize = UDim2.new(0, 0, 0, 0),
					ScrollBarThickness = 4,
					ScrollBarImageColor3 = ui.HAZARD,
				}, {
					Pad = React.createElement(ui.Pad, { right = 6, top = 2, bottom = 8 }),
					Content = tabContent,
				}),

				FooterDivider = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 1),
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 0, 1, -22),
					BackgroundColor3 = ui.BORDER,
					BorderSizePixel = 0,
				}),

				FooterWrap = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 18),
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
				}, {
					Footer = React.createElement(ui.Title, {
						text = if status
							then `{if status.ok then "OK" else "ERR"} · {status.action}{if status.message and status.message ~= "" then `: {status.message}` else ""}`
							else "Listo · F4 abre/cierra el panel",
						font = ui.MONO_FONT,
						textSize = 11,
						color = if status and not status.ok then ui.STRIKE else ui.MUTED,
						size = UDim2.fromScale(1, 1),
						automaticSize = Enum.AutomaticSize.None,
						wrapped = false,
					}),
				}),
			})
			else nil,
	})
end

local DevPanel = {}
local started = false

function DevPanel.start(options: StartOptions?)
	if started then
		return nil
	end
	started = true
	optionsRef = options or {}

	local localPlayer = Players.LocalPlayer

	ContextActionService:BindAction("DevPanelToggle", function(_name, state)
		if state == Enum.UserInputState.Begin then
			if Environment.isStudio() or localPlayer:GetAttribute("IsAdmin") == true then
				DebugStore.toggleOpen()
			end
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Config.DEBUG_TOGGLE_KEY)

	Remotes.DebugEvent.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "commandResult" and type(data) == "table" then
			DebugStore.setCommandStatus({
				action = tostring(data.action or ""),
				ok = data.ok == true,
				message = if data.message ~= nil then tostring(data.message) else nil,
			})
		elseif kind == "combatLog" and type(data) == "table" then
			DebugStore.pushLog({
				seq = tonumber(data.seq) or 0,
				tag = tostring(data.tag or "LOG"),
				text = tostring(data.text or ""),
				kind = (data.kind or "info") :: any,
			})
		elseif kind == "openOverlay" and type(data) == "table" and type(data.overlay) == "string" then
			DebugStore.setOverlay(data.overlay :: any, true)
		end
	end)

	EnemyInspector.start()
	HitboxVisualizer.start()

	-- Wait for World asynchronously so DevPanel.start never blocks early client bootstrap.
	task.spawn(function()
		local world = workspace:WaitForChild("World")
		UI.mount("DevPanel", function()
			return React.createElement(DevPanelApp, {
				world = world,
				player = localPlayer,
			})
		end, { displayOrder = 90 })
	end)
	return nil
end

return DevPanel
