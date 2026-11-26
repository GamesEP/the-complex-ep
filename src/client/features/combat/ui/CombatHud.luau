--[[
	The fight's HUD: top-left red health bar (+ active pickup buffs), top-center wave counter &
	telegraph banners, and a bottom-left recharging icon for the Spin ability.

	Everything it shows is replicated state the server owns — health and cooldowns as attributes
	on the player, the wave as attributes on the World folder — so there is no store and no remote
	here. Anything that updates every frame is a binding, never state (docs/ui-architecture.md).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Drops = require(Shared.features.drops.Drops)
local Melee = require(Shared.features.combat.Melee)

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Client = script:FindFirstAncestor("Client")

local UI = require(Client.ui.Mount)
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local AbilityStore = require(script.Parent.Parent.stores.AbilityStore)

local ROOM_ATTRIBUTES = { "Wave", "WaveCount", "EnemiesLeft", "RoomState" }

local HEALTH_COLOR = Color3.fromRGB(220, 44, 54)
local HEALTH_HIGHLIGHT = Color3.fromRGB(255, 110, 115)
local SPIN_COLOR = Color3.fromRGB(255, 200, 90)
local SPIN_DIM_COLOR = Color3.fromRGB(130, 115, 85)
local STINGER_COLOR = Color3.fromRGB(255, 105, 65)
local STINGER_DIM_COLOR = Color3.fromRGB(135, 85, 72)
local OVERDRIVE_COLOR = Color3.fromRGB(225, 85, 255)
local OVERDRIVE_DIM_COLOR = Color3.fromRGB(120, 75, 138)
local SLOT_STROKE_DIM = Color3.fromRGB(72, 78, 96)
local SLOT_STROKE_SELECTED = Color3.fromRGB(255, 255, 255)
local DAMAGE_BUFF_COLOR = Color3.fromRGB(255, 105, 60)
local SPEED_BUFF_COLOR = Color3.fromRGB(70, 225, 255)
local DEFENSE_BUFF_COLOR = Color3.fromRGB(75, 145, 255)
local GRAB_COLOR = Color3.fromRGB(235, 85, 225)
local GRAB_WARN_COLOR = Color3.fromRGB(255, 195, 60)
local PARRY_WARN_COLOR = Color3.fromRGB(70, 245, 255)
local HEAVY_CHARGE_COLOR = Color3.fromRGB(255, 135, 45)

local function Bar(props)
	return React.createElement("Frame", {
		Name = props.name,
		Size = UDim2.new(1, 0, 0, props.height or 16),
		BackgroundColor3 = ui.INK,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		LayoutOrder = props.order,
		Visible = if props.visible ~= nil then props.visible else true,
	}, {
		Corner = React.createElement(ui.Round, { radius = props.radius or 5 }),
		Fill = React.createElement("Frame", {
			Size = props.fill,
			BackgroundColor3 = props.color,
			BorderSizePixel = 0,
			ClipsDescendants = true,
		}, {
			Corner = React.createElement(ui.Round, { radius = props.radius or 5 }),
			Gloss = if props.glossColor
				then React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0.42, 0),
					BackgroundColor3 = props.glossColor,
					BackgroundTransparency = 0.72,
					BorderSizePixel = 0,
				})
				else nil,
		}),
		Label = React.createElement("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = ui.TITLE_FONT,
			TextSize = props.textSize or 12,
			TextColor3 = ui.TEXT,
			TextStrokeTransparency = 0.5,
			Text = props.text,
			ZIndex = 2,
		}),
	})
end

local function buildAbilityEmblem(kind: string, tileSize: number, accentColor: any)
	if kind == "stinger" then
		-- DMC Stinger lance emblem: bold forward thrust arrow + high-speed twin streaks.
		local shaftLen = math.round(tileSize * 0.56)
		local headSz = math.round(tileSize * 0.24)
		return {
			Shaft = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.46, 0.54),
				Size = UDim2.fromOffset(shaftLen, 6),
				Rotation = -45,
				BackgroundColor3 = accentColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 3 }),
			}),
			SpearHead = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.68, 0.32),
				Size = UDim2.fromOffset(headSz, headSz),
				Rotation = 45,
				BackgroundColor3 = ui.TEXT,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 3 }),
				Stroke = React.createElement("UIStroke", {
					Color = accentColor,
					Thickness = 2,
				}),
			}),
			StreakTop = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.32, 0.36),
				Size = UDim2.fromOffset(math.round(tileSize * 0.34), 3),
				Rotation = -45,
				BackgroundColor3 = accentColor,
				BackgroundTransparency = 0.28,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
			}),
			StreakBottom = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.62, 0.68),
				Size = UDim2.fromOffset(math.round(tileSize * 0.34), 3),
				Rotation = -45,
				BackgroundColor3 = accentColor,
				BackgroundTransparency = 0.28,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
			}),
		}
	elseif kind == "overdrive" then
		-- DMC Over Drive ultimate emblem: 3 stacked crescent energy slash waves + radiant core.
		local waveW = math.round(tileSize * 0.58)
		local coreSz = math.round(tileSize * 0.16)
		return {
			Wave1 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.28),
				Size = UDim2.fromOffset(math.round(waveW * 0.78), 5),
				Rotation = -16,
				BackgroundColor3 = accentColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 3 }),
			}),
			Wave2 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(waveW, 6),
				Rotation = -16,
				BackgroundColor3 = ui.TEXT,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 3 }),
				Stroke = React.createElement("UIStroke", {
					Color = accentColor,
					Thickness = 2,
				}),
			}),
			Wave3 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.72),
				Size = UDim2.fromOffset(math.round(waveW * 0.86), 5),
				Rotation = -16,
				BackgroundColor3 = accentColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 3 }),
			}),
			Core = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(coreSz, coreSz),
				BackgroundColor3 = ui.TEXT,
				BorderSizePixel = 0,
			}, {
				Circle = React.createElement("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			}),
		}
	end

	-- Default Slot 1: Spin cyclone emblem.
	local outerRing = math.round(tileSize * 0.58)
	local innerRing = math.round(tileSize * 0.34)
	local slashLen = math.round(tileSize * 0.64)
	local coreSize = math.round(tileSize * 0.14)
	return {
		OuterRing = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(outerRing, outerRing),
			BackgroundTransparency = 1,
		}, {
			Circle = React.createElement("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Stroke = React.createElement("UIStroke", {
				Color = accentColor,
				Thickness = 3.5,
				Transparency = 0.12,
			}),
		}),
		InnerRing = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(innerRing, innerRing),
			BackgroundTransparency = 1,
		}, {
			Circle = React.createElement("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Stroke = React.createElement("UIStroke", {
				Color = accentColor,
				Thickness = 2,
				Transparency = 0.35,
			}),
		}),
		BladeA = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(slashLen, 5),
			Rotation = 38,
			BackgroundColor3 = accentColor,
			BorderSizePixel = 0,
		}, {
			Round = React.createElement(ui.Round, { radius = 3 }),
		}),
		BladeB = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(slashLen, 5),
			Rotation = -38,
			BackgroundColor3 = accentColor,
			BorderSizePixel = 0,
		}, {
			Round = React.createElement(ui.Round, { radius = 3 }),
		}),
		Core = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(coreSize, coreSize),
			BackgroundColor3 = ui.TEXT,
			BorderSizePixel = 0,
		}, {
			Circle = React.createElement("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		}),
	}
end

-- Recharging ability slot tile (1 = Giro, 2 = Stinger, 3 = Over Drive).
local function AbilitySlotIcon(props)
	local tileSize = if props.compact then 58 else 72
	local chargeBinding = props.charge
	local remainingBinding = props.remaining
	local baseColor = props.color
	local dimColor = props.dimColor
	local selected = props.selected == true

	local accentColor = chargeBinding:map(function(v: number)
		return if v >= 1 then baseColor else dimColor
	end)
	local borderColor = chargeBinding:map(function(v: number)
		if selected then
			return if v >= 1 then SLOT_STROKE_SELECTED else baseColor
		end
		return if v >= 1 then baseColor else SLOT_STROKE_DIM
	end)
	local borderThickness = if selected then 3 else 2
	local chargeFillSize = chargeBinding:map(function(v: number)
		return UDim2.fromScale(1, v)
	end)
	local cooldownCurtainSize = chargeBinding:map(function(v: number)
		return UDim2.fromScale(1, math.clamp(1 - v, 0, 1))
	end)
	local sweepLinePos = chargeBinding:map(function(v: number)
		return UDim2.fromScale(0, math.clamp(1 - v, 0, 1))
	end)
	local isCooling = chargeBinding:map(function(v: number)
		return v < 1
	end)
	local isMidCharge = chargeBinding:map(function(v: number)
		return v > 0.01 and v < 0.995
	end)
	local timerText = remainingBinding:map(function(secs: number)
		if secs <= 0.05 then
			return ""
		end
		if secs >= 10 then
			return string.format("%.0f", math.ceil(secs))
		end
		return string.format("%.1f", secs)
	end)

	local lift = if selected then -6 else 0

	return React.createElement("Frame", {
		Name = props.name,
		LayoutOrder = props.slotIndex,
		Size = UDim2.fromOffset(tileSize, tileSize + (if props.compact then 6 else 24)),
		BackgroundTransparency = 1,
	}, {
		Slot = React.createElement("TextButton", {
			Name = "Slot",
			Position = UDim2.fromOffset(0, lift),
			Size = UDim2.fromOffset(tileSize, tileSize),
			BackgroundColor3 = if selected then ui.PANEL_LIGHT else ui.PANEL,
			BackgroundTransparency = if selected then 0.02 else 0.14,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Text = "",
			[React.Event.Activated] = function()
				AbilityStore.select(props.slotIndex)
			end,
		}, {
			Corner = React.createElement(ui.Round, { radius = 12 }),
			Border = React.createElement("UIStroke", {
				Color = borderColor,
				Thickness = borderThickness,
				Transparency = if selected then 0 else 0.2,
			}),
			Clip = React.createElement("Frame", {
				Name = "Clip",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				ClipsDescendants = true,
			}, {
				Corner = React.createElement(ui.Round, { radius = 12 }),
				ChargeFill = React.createElement("Frame", {
					Name = "ChargeFill",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					Size = chargeFillSize,
					BackgroundColor3 = baseColor,
					BackgroundTransparency = if selected then 0.72 else 0.82,
					BorderSizePixel = 0,
					ZIndex = 1,
				}),
				Emblem = React.createElement("Frame", {
					Name = "Emblem",
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					ZIndex = 2,
				}, buildAbilityEmblem(props.kind, tileSize, accentColor)),
				CooldownCurtain = React.createElement("Frame", {
					Name = "CooldownCurtain",
					Position = UDim2.fromScale(0, 0),
					Size = cooldownCurtainSize,
					BackgroundColor3 = ui.INK,
					BackgroundTransparency = 0.34,
					BorderSizePixel = 0,
					Visible = isCooling,
					ZIndex = 3,
				}),
				SweepLine = React.createElement("Frame", {
					Name = "SweepLine",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = sweepLinePos,
					Size = UDim2.new(1, 0, 0, 2),
					BackgroundColor3 = baseColor,
					BackgroundTransparency = 0.08,
					BorderSizePixel = 0,
					Visible = isMidCharge,
					ZIndex = 4,
				}),
				Timer = React.createElement("TextLabel", {
					Name = "Timer",
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					Font = ui.TITLE_FONT,
					TextSize = if props.compact then 17 else 21,
					TextColor3 = ui.TEXT,
					TextStrokeTransparency = 0.25,
					Text = timerText,
					Visible = isCooling,
					ZIndex = 5,
				}),
			}),
			SlotNumber = React.createElement("TextLabel", {
				Name = "SlotNumber",
				Position = UDim2.fromOffset(-4, -4),
				Size = UDim2.fromOffset(20, 20),
				BackgroundColor3 = if selected then baseColor else ui.INK,
				BackgroundTransparency = 0.05,
				BorderSizePixel = 0,
				Font = ui.TITLE_FONT,
				TextSize = 11,
				TextColor3 = if selected then ui.INK else ui.TEXT,
				Text = tostring(props.slotIndex),
				ZIndex = 6,
			}, {
				Corner = React.createElement(ui.Round, { radius = 6 }),
				Edge = React.createElement(ui.Outline, { color = baseColor, thickness = 1.5, transparency = 0.25 }),
			}),
			CastBadge = if selected and not props.touch
				then React.createElement("TextLabel", {
					Name = "CastBadge",
					AnchorPoint = Vector2.new(1, 1),
					Position = UDim2.new(1, 4, 1, 4),
					Size = UDim2.fromOffset(22, 22),
					BackgroundColor3 = ui.INK,
					BackgroundTransparency = 0.05,
					BorderSizePixel = 0,
					Font = ui.TITLE_FONT,
					TextSize = 12,
					TextColor3 = baseColor,
					Text = "E",
					ZIndex = 6,
				}, {
					Corner = React.createElement(ui.Round, { radius = 6 }),
					Edge = React.createElement(ui.Outline, { color = baseColor, thickness = 1.5, transparency = 0.2 }),
				})
				else nil,
		}),
		Caption = if not props.compact
			then React.createElement("TextLabel", {
				Name = "Caption",
				Position = UDim2.fromOffset(0, tileSize + 4),
				Size = UDim2.fromOffset(tileSize, 16),
				BackgroundTransparency = 1,
				Font = ui.TITLE_FONT,
				TextSize = 11,
				TextColor3 = if selected then baseColor else ui.MUTED,
				TextStrokeTransparency = 0.45,
				Text = props.label,
			})
			else nil,
	})
end

-- 0 just used, 1 ready, from a ready-at time in server seconds and the cooldown's length.
local function charge(readyAt: any, cooldown: number, now: number): number
	if type(readyAt) ~= "number" or cooldown <= 0 then
		return 1
	end
	return math.clamp(1 - (readyAt - now) / cooldown, 0, 1)
end

local function remainingSeconds(readyAt: any, now: number): number
	if type(readyAt) ~= "number" then
		return 0
	end
	return math.max(readyAt - now, 0)
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
	local chargingHeavy = hooks.useAttribute(player, "ChargingHeavy") == true
	local grabbed = hooks.useAttribute(player, "Grabbed") == true
	local grabProgress = hooks.useAttribute(player, "GrabProgress") or 0
	local grabGoal = hooks.useAttribute(player, "GrabGoal") or Config.GRAB_ESCAPE_PRESSES
	local room = hooks.useAttributes(props.world, ROOM_ATTRIBUTES)
	local activeSlot = hooks.useAtom(AbilityStore.slot)

	-- Per frame, so bindings: React writes the bars and icon fills without re-rendering the screen.
	local spinCharge, setSpinCharge = React.useBinding(1)
	local spinRemaining, setSpinRemaining = React.useBinding(0)
	local stingerCharge, setStingerCharge = React.useBinding(1)
	local stingerRemaining, setStingerRemaining = React.useBinding(0)
	local overDriveCharge, setOverDriveCharge = React.useBinding(1)
	local overDriveRemaining, setOverDriveRemaining = React.useBinding(0)
	local damageBuff, setDamageBuff = React.useBinding(0)
	local speedBuff, setSpeedBuff = React.useBinding(0)
	local defenseBuff, setDefenseBuff = React.useBinding(0)
	local heavyCharge, setHeavyCharge = React.useBinding(0)
	local grabWarn, setGrabWarn = React.useBinding(false)
	local parryWarn, setParryWarn = React.useBinding(false)
	hooks.useSignal(RunService.Heartbeat, function()
		local now = workspace:GetServerTimeNow()
		local spinReadyAt = player:GetAttribute("SpinReadyAt")
		setSpinCharge(charge(spinReadyAt, Config.SPIN_COOLDOWN, now))
		setSpinRemaining(remainingSeconds(spinReadyAt, now))

		local stingerReadyAt = player:GetAttribute("StingerReadyAt")
		setStingerCharge(charge(stingerReadyAt, Config.STINGER_COOLDOWN, now))
		setStingerRemaining(remainingSeconds(stingerReadyAt, now))

		local overDriveReadyAt = player:GetAttribute("OverDriveReadyAt")
		setOverDriveCharge(charge(overDriveReadyAt, Config.OVERDRIVE_COOLDOWN, now))
		setOverDriveRemaining(remainingSeconds(overDriveReadyAt, now))

		setDamageBuff(Drops.buffRemaining(player:GetAttribute("DamageBuffUntil"), Config.BUFF_DAMAGE_DURATION, now))
		setSpeedBuff(Drops.buffRemaining(player:GetAttribute("SpeedBuffUntil"), Config.BUFF_SPEED_DURATION, now))
		setDefenseBuff(Drops.buffRemaining(player:GetAttribute("DefenseBuffUntil"), Config.BUFF_DEFENSE_DURATION, now))
		if player:GetAttribute("ChargingHeavy") == true then
			setHeavyCharge(Melee.chargeProgress(player:GetAttribute("HeavyChargeStart"), now, Config.HEAVY_CHARGE_SECONDS))
		else
			setHeavyCharge(0)
		end
		local warnUntil = player:GetAttribute("GrabWarningUntil")
		setGrabWarn(type(warnUntil) == "number" and now < warnUntil and player:GetAttribute("Grabbed") ~= true)
		local parryUntil = player:GetAttribute("ParryWarningUntil")
		setParryWarn(type(parryUntil) == "number" and now < parryUntil and player:GetAttribute("Grabbed") ~= true)
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

	local width = math.min(250, metrics.room.X - 2 * ui.MARGIN)
	-- Leave breathing room above the bottom-left environment watermark (and touch thumbstick band).
	local bottomOffset = ui.MARGIN + 64 + Layout.band()

	return React.createElement(Scaled.Frame, nil, {
		Kit = React.createElement(ui.Panel, {
			name = "Kit",
			width = width,
			padding = 10,
			-- `inset()` by hand: IgnoreGuiInset is on, so anything pinned to the top pays the top
			-- bar back itself or sits under it on a phone.
			position = UDim2.fromOffset(ui.MARGIN, ui.MARGIN + Layout.inset()),
		}, {
			List = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 7),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Health = React.createElement(Bar, {
				name = "Health",
				order = 1,
				height = 24,
				radius = 6,
				textSize = 14,
				color = HEALTH_COLOR,
				glossColor = HEALTH_HIGHLIGHT,
				fill = UDim2.fromScale(math.clamp(health / math.max(maxHealth, 1), 0, 1), 1),
				text = `Vida {math.ceil(health)}/{maxHealth}`,
			}),
			DamageBuff = React.createElement(Bar, {
				name = "DamageBuff",
				order = 2,
				color = DAMAGE_BUFF_COLOR,
				fill = fillOf(damageBuff),
				visible = activeOf(damageBuff),
				text = `Daño +{math.round((Config.BUFF_DAMAGE_MULTIPLIER - 1) * 100)}%`,
			}),
			SpeedBuff = React.createElement(Bar, {
				name = "SpeedBuff",
				order = 3,
				color = SPEED_BUFF_COLOR,
				fill = fillOf(speedBuff),
				visible = activeOf(speedBuff),
				text = `Velocidad +{math.round((Config.BUFF_SPEED_MULTIPLIER - 1) * 100)}%`,
			}),
			DefenseBuff = React.createElement(Bar, {
				name = "DefenseBuff",
				order = 4,
				color = DEFENSE_BUFF_COLOR,
				fill = fillOf(defenseBuff),
				visible = activeOf(defenseBuff),
				text = `Defensa +{math.round(Config.BUFF_DEFENSE_REDUCTION * 100)}%`,
			}),
		}),
		AbilityBar = React.createElement("Frame", {
			Name = "AbilityBar",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, ui.MARGIN + 8, 1, -bottomOffset),
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			BackgroundTransparency = 1,
		}, {
			Row = React.createElement("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Bottom,
				Padding = UDim.new(0, if metrics.compact then 8 else 12),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			SpinAbility = React.createElement(AbilitySlotIcon, {
				name = "SpinAbility",
				slotIndex = 1,
				kind = "spin",
				label = "Giro",
				color = SPIN_COLOR,
				dimColor = SPIN_DIM_COLOR,
				charge = spinCharge,
				remaining = spinRemaining,
				selected = activeSlot == 1,
				compact = metrics.compact,
				touch = metrics.touch,
			}),
			StingerAbility = React.createElement(AbilitySlotIcon, {
				name = "StingerAbility",
				slotIndex = 2,
				kind = "stinger",
				label = "Stinger",
				color = STINGER_COLOR,
				dimColor = STINGER_DIM_COLOR,
				charge = stingerCharge,
				remaining = stingerRemaining,
				selected = activeSlot == 2,
				compact = metrics.compact,
				touch = metrics.touch,
			}),
			OverDriveAbility = React.createElement(AbilitySlotIcon, {
				name = "OverDriveAbility",
				slotIndex = 3,
				kind = "overdrive",
				label = "Over Drive",
				color = OVERDRIVE_COLOR,
				dimColor = OVERDRIVE_DIM_COLOR,
				charge = overDriveCharge,
				remaining = overDriveRemaining,
				selected = activeSlot == 3,
				compact = metrics.compact,
				touch = metrics.touch,
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
		ParryWarning = React.createElement("TextLabel", {
			Name = "ParryWarning",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, ui.MARGIN + Layout.inset() + 72),
			Size = UDim2.fromOffset(math.min(420, metrics.room.X - 2 * ui.MARGIN), 30),
			BackgroundColor3 = ui.INK,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			Font = ui.TITLE_FONT,
			TextSize = 18,
			TextColor3 = PARRY_WARN_COLOR,
			TextStrokeTransparency = 0.35,
			Text = "¡SANDEVISTAN! ¡Haz PARRY!",
			Visible = parryWarn,
		}, {
			Corner = React.createElement(ui.Round, { radius = 6 }),
		}),
		HeavyCharge = if chargingHeavy and not grabbed
			then React.createElement(ui.Panel, {
				name = "HeavyCharge",
				width = math.min(300, metrics.room.X - 2 * ui.MARGIN),
				padding = 10,
				anchorPoint = Vector2.new(0.5, 1),
				position = UDim2.new(0.5, 0, 1, -ui.MARGIN * 2),
			}, {
				Bar = React.createElement(Bar, {
					name = "ChargeProgress",
					order = 1,
					height = 24,
					color = HEAVY_CHARGE_COLOR,
					fill = fillOf(heavyCharge),
					text = heavyCharge:map(function(value: number)
						local secs = math.min(value * Config.HEAVY_CHARGE_SECONDS, Config.HEAVY_CHARGE_SECONDS)
						return string.format("Ataque Pesado  %.1fs / %.1fs", secs, Config.HEAVY_CHARGE_SECONDS)
					end),
				}),
			})
			else nil,
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
