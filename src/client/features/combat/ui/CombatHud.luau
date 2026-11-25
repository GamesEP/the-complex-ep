--[[
	The fight's HUD: the player's health, the dash and spin cooldowns, and the room's wave.

	Everything it shows is replicated state the server owns — health and cooldowns as attributes
	on the player, the wave as attributes on the World folder — so there is no store and no remote
	here. The cooldown bars move every frame, so they are bindings, never state
	(docs/ui-architecture.md).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Drops = require(Shared.features.drops.Drops)

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Client = script:FindFirstAncestor("Client")

local UI = require(Client.ui.Mount)
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local ROOM_ATTRIBUTES = { "Wave", "WaveCount", "EnemiesLeft", "RoomState" }

local HEALTH_COLOR = Color3.fromRGB(90, 210, 120)
local DASH_COLOR = Color3.fromRGB(120, 190, 255)
local SPIN_COLOR = Color3.fromRGB(255, 200, 90)
local BLOCK_COLOR = Color3.fromRGB(190, 210, 240)
local DAMAGE_BUFF_COLOR = Color3.fromRGB(255, 105, 60)
local SPEED_BUFF_COLOR = Color3.fromRGB(70, 225, 255)
local DEFENSE_BUFF_COLOR = Color3.fromRGB(75, 145, 255)
local GRAB_COLOR = Color3.fromRGB(235, 85, 225)
local GRAB_WARN_COLOR = Color3.fromRGB(255, 195, 60)

local function Bar(props)
	return React.createElement("Frame", {
		Name = props.name,
		Size = UDim2.new(1, 0, 0, props.height or 16),
		BackgroundColor3 = ui.INK,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		LayoutOrder = props.order,
		Visible = if props.visible ~= nil then props.visible else true,
	}, {
		Corner = React.createElement(ui.Round, { radius = 4 }),
		Fill = React.createElement("Frame", {
			Size = props.fill,
			BackgroundColor3 = props.color,
			BorderSizePixel = 0,
		}, {
			Corner = React.createElement(ui.Round, { radius = 4 }),
		}),
		Label = React.createElement("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = ui.TITLE_FONT,
			TextSize = 12,
			TextColor3 = ui.TEXT,
			TextStrokeTransparency = 0.6,
			Text = props.text,
			ZIndex = 2,
		}),
	})
end

-- 0 just used, 1 ready, from a ready-at time in server seconds and the cooldown's length.
local function charge(readyAt: any, cooldown: number, now: number): number
	if type(readyAt) ~= "number" or cooldown <= 0 then
		return 1
	end
	return math.clamp(1 - (readyAt - now) / cooldown, 0, 1)
end

local function roomText(room: { [string]: any }): string
	if room.RoomState == "cleared" then
		return "¡Sala limpia! Vuelve a empezar..."
	end
	if room.RoomState ~= "fighting" then
		return "Preparando la sala..."
	end
	return `Oleada {room.Wave or 1}/{room.WaveCount or 1}  ·  Enemigos: {room.EnemiesLeft or 0}`
end

local function CombatHud(props)
	local player = Players.LocalPlayer
	local metrics = Scaled.useLayout()

	local health = hooks.useAttribute(player, "Health") or 0
	local maxHealth = hooks.useAttribute(player, "MaxHealth") or Config.PLAYER_MAX_HEALTH
	local blocking = hooks.useAttribute(player, "Blocking") == true
	local grabbed = hooks.useAttribute(player, "Grabbed") == true
	local grabProgress = hooks.useAttribute(player, "GrabProgress") or 0
	local grabGoal = hooks.useAttribute(player, "GrabGoal") or Config.GRAB_ESCAPE_PRESSES
	local room = hooks.useAttributes(props.world, ROOM_ATTRIBUTES)

	-- Per frame, so bindings: React writes the bars' sizes without re-rendering the screen.
	local dashCharge, setDashCharge = React.useBinding(1)
	local spinCharge, setSpinCharge = React.useBinding(1)
	local blockCharge, setBlockCharge = React.useBinding(1)
	local damageBuff, setDamageBuff = React.useBinding(0)
	local speedBuff, setSpeedBuff = React.useBinding(0)
	local defenseBuff, setDefenseBuff = React.useBinding(0)
	local grabWarn, setGrabWarn = React.useBinding(false)
	hooks.useSignal(RunService.Heartbeat, function()
		local now = workspace:GetServerTimeNow()
		setDashCharge(charge(player:GetAttribute("DashReadyAt"), Config.DASH_COOLDOWN, now))
		setSpinCharge(charge(player:GetAttribute("SpinReadyAt"), Config.SPIN_COOLDOWN, now))
		setBlockCharge(charge(player:GetAttribute("BlockReadyAt"), Config.BLOCK_COOLDOWN, now))
		setDamageBuff(Drops.buffRemaining(player:GetAttribute("DamageBuffUntil"), Config.BUFF_DAMAGE_DURATION, now))
		setSpeedBuff(Drops.buffRemaining(player:GetAttribute("SpeedBuffUntil"), Config.BUFF_SPEED_DURATION, now))
		setDefenseBuff(Drops.buffRemaining(player:GetAttribute("DefenseBuffUntil"), Config.BUFF_DEFENSE_DURATION, now))
		local warnUntil = player:GetAttribute("GrabWarningUntil")
		setGrabWarn(type(warnUntil) == "number" and now < warnUntil and player:GetAttribute("Grabbed") ~= true)
	end)

	local function fillOf(binding)
		return binding:map(function(value: number)
			return UDim2.fromScale(value, 1)
		end)
	end

	local function activeOf(binding)
		return binding:map(function(value: number)
			return value > 0
		end)
	end

	local width = math.min(240, metrics.room.X - 2 * ui.MARGIN)

	return React.createElement(Scaled.Frame, nil, {
		Kit = React.createElement(ui.Panel, {
			name = "Kit",
			width = width,
			padding = 12,
			-- `inset()` by hand: IgnoreGuiInset is on, so anything pinned to the top pays the top
			-- bar back itself or sits under it on a phone.
			position = UDim2.fromOffset(ui.MARGIN, ui.MARGIN + Layout.inset()),
		}, {
			List = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Health = React.createElement(Bar, {
				name = "Health",
				order = 1,
				height = 20,
				color = HEALTH_COLOR,
				fill = UDim2.fromScale(math.clamp(health / math.max(maxHealth, 1), 0, 1), 1),
				text = `Vida {math.ceil(health)}/{maxHealth}`,
			}),
			Dash = React.createElement(Bar, {
				name = "Dash",
				order = 2,
				color = DASH_COLOR,
				fill = fillOf(dashCharge),
				text = "Dash",
			}),
			Spin = React.createElement(Bar, {
				name = "Spin",
				order = 3,
				color = SPIN_COLOR,
				fill = fillOf(spinCharge),
				text = "Giro",
			}),
			Block = React.createElement(Bar, {
				name = "Block",
				order = 4,
				color = if blocking then Color3.fromRGB(255, 225, 110) else BLOCK_COLOR,
				fill = fillOf(blockCharge),
				text = if blocking then "Bloqueando..." else "Bloquear / Parry",
			}),
			DamageBuff = React.createElement(Bar, {
				name = "DamageBuff",
				order = 5,
				color = DAMAGE_BUFF_COLOR,
				fill = fillOf(damageBuff),
				visible = activeOf(damageBuff),
				text = `Daño +{math.round((Config.BUFF_DAMAGE_MULTIPLIER - 1) * 100)}%`,
			}),
			SpeedBuff = React.createElement(Bar, {
				name = "SpeedBuff",
				order = 6,
				color = SPEED_BUFF_COLOR,
				fill = fillOf(speedBuff),
				visible = activeOf(speedBuff),
				text = `Velocidad +{math.round((Config.BUFF_SPEED_MULTIPLIER - 1) * 100)}%`,
			}),
			DefenseBuff = React.createElement(Bar, {
				name = "DefenseBuff",
				order = 7,
				color = DEFENSE_BUFF_COLOR,
				fill = fillOf(defenseBuff),
				visible = activeOf(defenseBuff),
				text = `Defensa +{math.round(Config.BUFF_DEFENSE_REDUCTION * 100)}%`,
			}),
		}),
		Room = React.createElement("TextLabel", {
			Name = "Room",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, ui.MARGIN + Layout.inset()),
			Size = UDim2.fromOffset(math.min(420, metrics.room.X - 2 * ui.MARGIN), 28),
			BackgroundTransparency = 1,
			Font = ui.TITLE_FONT,
			TextSize = 20,
			TextColor3 = ui.TEXT,
			TextStrokeTransparency = 0.5,
			TextWrapped = true,
			Text = roomText(room),
		}),
		GrabWarning = React.createElement("TextLabel", {
			Name = "GrabWarning",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, ui.MARGIN + Layout.inset() + 36),
			Size = UDim2.fromOffset(math.min(420, metrics.room.X - 2 * ui.MARGIN), 30),
			BackgroundColor3 = ui.INK,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Font = ui.TITLE_FONT,
			TextSize = 18,
			TextColor3 = GRAB_WARN_COLOR,
			TextStrokeTransparency = 0.4,
			Text = "¡AGARRE INMINENTE! Usa Dash",
			Visible = grabWarn,
		}, {
			Corner = React.createElement(ui.Round, { radius = 6 }),
		}),
		GrabEscape = if grabbed
			then React.createElement(ui.Panel, {
				name = "GrabEscape",
				width = math.min(340, metrics.room.X - 2 * ui.MARGIN),
				padding = 12,
				anchorPoint = Vector2.new(0.5, 1),
				position = UDim2.new(0.5, 0, 1, -ui.MARGIN * 2),
			}, {
				Bar = React.createElement(Bar, {
					name = "EscapeProgress",
					order = 1,
					height = 26,
					color = GRAB_COLOR,
					fill = UDim2.fromScale(math.clamp(grabProgress / math.max(grabGoal, 1), 0, 1), 1),
					text = `¡ATRAPADO! Pulsa Atacar ({grabProgress}/{grabGoal})`,
				}),
			})
			else nil,
	})
end

local screen = {}

function screen.start()
	-- Yields until the server has built the room; the HUD has nothing to show before that.
	local world = workspace:WaitForChild("World")
	local mounted = UI.mount("CombatHud", function()
		return React.createElement(CombatHud, { world = world })
	end)
	return mounted
end

return screen
