--[[
	The fight's HUD under the Hazard Arc design system (docs/ui-design-system.md):
	- Top-left: sharp architectural Vitals plate + active timed drop buff chips with live countdowns.
	- Top-center: Sector Hazard wave/hostiles pill (enemy Grabber / Paso Fantasma telegraphs appear
	  diegetically as overhead `!` triangles rather than invasive text banners).
	- Bottom-center: urgent Heavy Charge, Stun, and Grab Escape progress plates (same zone reserved
	  for future Boss HP bars so nothing collides with top-center UpgradeChoice banners).
	- Bottom-right: machined circular Hazard Arc actuators for Attack, Dash, Block and the 3
	  switchable abilities (1 Giro, 2 Stinger, 3 Over Drive) — read-only + click-to-select on
	  PC/console, one-tap interactive touch buttons wrapping Roblox's jump corner on mobile.

	Everything it shows is replicated state the server owns — health and cooldowns as attributes
	on the player, the wave as attributes on the World folder — plus client-owned active slot
	selection from `AbilityStore`. Values that move every frame are bindings, never state
	(docs/ui-architecture.md).
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
local CombatInput = require(script.Parent.Parent.CombatInput)

local ROOM_ATTRIBUTES = { "Wave", "WaveCount", "EnemiesLeft", "RoomState" }

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

local function healthColor(ratio: number): Color3
	if ratio <= 0.25 then
		return ui.STRIKE
	end
	if ratio <= 0.5 then
		return ui.HAZARD
	end
	return ui.VITAL
end

local function roomLabel(room: { [string]: any }, compact: boolean): (string, Color3)
	if room.RoomState == "cleared" then
		return if compact then "SALA LIMPIA" else "SEC-01  //  SALA LIMPIA", ui.VITAL
	end
	if room.RoomState ~= "fighting" then
		return if compact then "PREPARANDO..." else "SEC-01  //  PREPARANDO SECTOR", ui.MUTED
	end
	local wave = room.Wave or 1
	local waveCount = room.WaveCount or 1
	local left = room.EnemiesLeft or 0
	if compact then
		return `O{wave}/{waveCount}  |  {left} HOST.`, ui.HAZARD
	end
	return `SEC-01  //  OLEADA {wave}/{waveCount}  |  {left} HOSTILES`, ui.HAZARD
end

local function buildAbilityEmblem(kind: string, diameter: number, accentColor: any)
	if kind == "stinger" then
		-- Stinger lance emblem: forward thrust arrow + twin speed streaks.
		local shaftLen = math.round(diameter * 0.48)
		local headSz = math.round(diameter * 0.2)
		return {
			Shaft = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.46, 0.54),
				Size = UDim2.fromOffset(shaftLen, 4),
				Rotation = -45,
				BackgroundColor3 = accentColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
			}),
			SpearHead = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.66, 0.34),
				Size = UDim2.fromOffset(headSz, headSz),
				Rotation = 45,
				BackgroundColor3 = ui.TEXT,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", {
					Color = accentColor,
					Thickness = 1.5,
				}),
			}),
			StreakTop = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.34, 0.38),
				Size = UDim2.fromOffset(math.round(diameter * 0.28), 2),
				Rotation = -45,
				BackgroundColor3 = accentColor,
				BackgroundTransparency = 0.28,
				BorderSizePixel = 0,
			}),
			StreakBottom = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.6, 0.66),
				Size = UDim2.fromOffset(math.round(diameter * 0.28), 2),
				Rotation = -45,
				BackgroundColor3 = accentColor,
				BackgroundTransparency = 0.28,
				BorderSizePixel = 0,
			}),
		}
	elseif kind == "overdrive" then
		-- Over Drive ultimate emblem: 3 stacked crescent energy waves + bright core.
		local waveW = math.round(diameter * 0.48)
		local coreSz = math.round(diameter * 0.14)
		return {
			Wave1 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.3),
				Size = UDim2.fromOffset(math.round(waveW * 0.78), 4),
				Rotation = -16,
				BackgroundColor3 = accentColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
			}),
			Wave2 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(waveW, 5),
				Rotation = -16,
				BackgroundColor3 = ui.TEXT,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", {
					Color = accentColor,
					Thickness = 1.5,
				}),
			}),
			Wave3 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.7),
				Size = UDim2.fromOffset(math.round(waveW * 0.86), 4),
				Rotation = -16,
				BackgroundColor3 = accentColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
			}),
			Core = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(coreSz, coreSz),
				BackgroundColor3 = ui.TEXT,
				BorderSizePixel = 0,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
			}),
		}
	end

	-- Default Slot 1: Spin cyclone emblem.
	local outerRing = math.round(diameter * 0.5)
	local innerRing = math.round(diameter * 0.28)
	local slashLen = math.round(diameter * 0.54)
	local coreSize = math.round(diameter * 0.13)
	return {
		OuterRing = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(outerRing, outerRing),
			BackgroundTransparency = 1,
		}, {
			Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
			Stroke = React.createElement("UIStroke", {
				Color = accentColor,
				Thickness = 2.5,
				Transparency = 0.15,
			}),
		}),
		InnerRing = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(innerRing, innerRing),
			BackgroundTransparency = 1,
		}, {
			Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
			Stroke = React.createElement("UIStroke", {
				Color = accentColor,
				Thickness = 1.5,
				Transparency = 0.35,
			}),
		}),
		BladeA = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(slashLen, 4),
			Rotation = 38,
			BackgroundColor3 = accentColor,
			BorderSizePixel = 0,
		}, {
			Round = React.createElement(ui.Round, { radius = 2 }),
		}),
		BladeB = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(slashLen, 4),
			Rotation = -38,
			BackgroundColor3 = accentColor,
			BorderSizePixel = 0,
		}, {
			Round = React.createElement(ui.Round, { radius = 2 }),
		}),
		Core = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(coreSize, coreSize),
			BackgroundColor3 = ui.TEXT,
			BorderSizePixel = 0,
		}, {
			Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
		}),
	}
end

local function ProgressTrack(props)
	local height = props.height or 10
	local children: { [string]: any } = {
		Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
		Fill = React.createElement("Frame", {
			Size = props.fill,
			BackgroundColor3 = props.color,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
		}),
	}

	if props.ticks then
		for index = 1, props.ticks do
			local frac = index / (props.ticks + 1)
			children[`Tick{index}`] = React.createElement("Frame", {
				Position = UDim2.fromScale(frac, 0),
				Size = UDim2.new(0, 1, 1, 0),
				BackgroundColor3 = ui.INK,
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
				ZIndex = 3,
			})
		end
	end

	return React.createElement("Frame", {
		Name = props.name or "Track",
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = ui.INK,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		LayoutOrder = props.order,
	}, children)
end

local function BuffChip(props)
	return React.createElement("Frame", {
		Name = props.name,
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = ui.PANEL,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		LayoutOrder = props.order,
		Visible = props.visible,
	}, {
		Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
		Edge = React.createElement(ui.Outline, { color = ui.BORDER, thickness = 1 }),
		Stripe = React.createElement("Frame", {
			Size = UDim2.new(0, ui.ACCENT_WIDTH, 1, 0),
			BackgroundColor3 = props.color,
			BorderSizePixel = 0,
			ZIndex = 2,
		}),
		Label = React.createElement("TextLabel", {
			Position = UDim2.fromOffset(ui.ACCENT_WIDTH + 6, 0),
			Size = UDim2.new(0.68, -(ui.ACCENT_WIDTH + 6), 1, -5),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 11,
			TextColor3 = ui.TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = props.text,
			ZIndex = 2,
		}),
		Timer = React.createElement("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 0),
			Size = UDim2.new(0.36, 0, 1, -5),
			BackgroundTransparency = 1,
			Font = ui.MONO_FONT,
			TextSize = 12,
			TextColor3 = props.color,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = props.remaining,
			ZIndex = 2,
		}),
		BarTrack = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, ui.ACCENT_WIDTH, 1, 0),
			Size = UDim2.new(1, -ui.ACCENT_WIDTH, 0, 5),
			BackgroundColor3 = ui.INK,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			Fill = React.createElement("Frame", {
				Size = props.fill,
				BackgroundColor3 = props.color,
				BorderSizePixel = 0,
			}),
		}),
	})
end

local function CombatHud(props)
	local player = Players.LocalPlayer
	local metrics = Scaled.useLayout()

	local health = hooks.useAttribute(player, "Health") or 0
	local maxHealth = hooks.useAttribute(player, "MaxHealth") or Config.PLAYER_MAX_HEALTH
	local blocking = hooks.useAttribute(player, "Blocking") == true
	local chargingHeavy = hooks.useAttribute(player, "ChargingHeavy") == true
	local grabbed = hooks.useAttribute(player, "Grabbed") == true
	local grabProgress = hooks.useAttribute(player, "GrabProgress") or 0
	local grabGoal = hooks.useAttribute(player, "GrabGoal") or Config.GRAB_ESCAPE_PRESSES
	local room = hooks.useAttributes(props.world, ROOM_ATTRIBUTES)
	local activeSlot = hooks.useAtom(AbilityStore.slot)

	-- Per frame, so bindings: React writes progress fills and countdown strings without
	-- re-rendering the screen (docs/ui-architecture.md).
	local dashCharge, setDashCharge = React.useBinding(1)
	local dashRemain, setDashRemain = React.useBinding(0)
	local blockCharge, setBlockCharge = React.useBinding(1)
	local spinCharge, setSpinCharge = React.useBinding(1)
	local spinRemain, setSpinRemain = React.useBinding(0)
	local stingerCharge, setStingerCharge = React.useBinding(1)
	local stingerRemain, setStingerRemain = React.useBinding(0)
	local overDriveCharge, setOverDriveCharge = React.useBinding(1)
	local overDriveRemain, setOverDriveRemain = React.useBinding(0)
	local damageBuff, setDamageBuff = React.useBinding(0)
	local damageBuffRemain, setDamageBuffRemain = React.useBinding(0)
	local speedBuff, setSpeedBuff = React.useBinding(0)
	local speedBuffRemain, setSpeedBuffRemain = React.useBinding(0)
	local defenseBuff, setDefenseBuff = React.useBinding(0)
	local defenseBuffRemain, setDefenseBuffRemain = React.useBinding(0)
	local heavyCharge, setHeavyCharge = React.useBinding(0)
	local stunRemaining, setStunRemaining = React.useBinding(0)

	hooks.useSignal(RunService.Heartbeat, function()
		local now = workspace:GetServerTimeNow()
		local dashReadyAt = player:GetAttribute("DashReadyAt")
		local blockReadyAt = player:GetAttribute("BlockReadyAt")
		local spinReadyAt = player:GetAttribute("SpinReadyAt")
		local stingerReadyAt = player:GetAttribute("StingerReadyAt")
		local overDriveReadyAt = player:GetAttribute("OverDriveReadyAt")
		local damageBuffUntil = player:GetAttribute("DamageBuffUntil")
		local speedBuffUntil = player:GetAttribute("SpeedBuffUntil")
		local defenseBuffUntil = player:GetAttribute("DefenseBuffUntil")

		setDashCharge(charge(dashReadyAt, Config.DASH_COOLDOWN, now))
		setDashRemain(remainingSeconds(dashReadyAt, now))
		setBlockCharge(charge(blockReadyAt, Config.BLOCK_COOLDOWN, now))

		setSpinCharge(charge(spinReadyAt, Config.SPIN_COOLDOWN, now))
		setSpinRemain(remainingSeconds(spinReadyAt, now))
		setStingerCharge(charge(stingerReadyAt, Config.STINGER_COOLDOWN, now))
		setStingerRemain(remainingSeconds(stingerReadyAt, now))
		setOverDriveCharge(charge(overDriveReadyAt, Config.OVERDRIVE_COOLDOWN, now))
		setOverDriveRemain(remainingSeconds(overDriveReadyAt, now))

		setDamageBuff(Drops.buffRemaining(damageBuffUntil, Config.BUFF_DAMAGE_DURATION, now))
		setDamageBuffRemain(remainingSeconds(damageBuffUntil, now))
		setSpeedBuff(Drops.buffRemaining(speedBuffUntil, Config.BUFF_SPEED_DURATION, now))
		setSpeedBuffRemain(remainingSeconds(speedBuffUntil, now))
		setDefenseBuff(Drops.buffRemaining(defenseBuffUntil, Config.BUFF_DEFENSE_DURATION, now))
		setDefenseBuffRemain(remainingSeconds(defenseBuffUntil, now))

		if player:GetAttribute("ChargingHeavy") == true then
			setHeavyCharge(
				Melee.chargeProgress(player:GetAttribute("HeavyChargeStart"), now, Config.HEAVY_CHARGE_SECONDS)
			)
		else
			setHeavyCharge(0)
		end

		local stunnedUntil = player:GetAttribute("StunnedUntil")
		if player:GetAttribute("Grabbed") ~= true and type(stunnedUntil) == "number" and now < stunnedUntil then
			setStunRemaining(stunnedUntil - now)
		else
			setStunRemaining(0)
		end
	end)

	local function fillOf(binding)
		return binding:map(function(value: number)
			return UDim2.fromScale(math.clamp(value, 0, 1), 1)
		end)
	end

	local function activeOf(binding)
		return binding:map(function(value: number)
			return value > 0
		end)
	end

	local function cooldownSub(binding, readyText: string)
		return binding:map(function(secs: number)
			if secs > 0.05 then
				if secs >= 10 then
					return string.format("%.0fs", math.ceil(secs))
				end
				return string.format("%.1fs", secs)
			end
			return readyText
		end)
	end

	local function abilityTimer(binding)
		return binding:map(function(secs: number)
			if secs <= 0.05 then
				return ""
			end
			if secs >= 10 then
				return string.format("%.0f", math.ceil(secs))
			end
			return string.format("%.1f", secs)
		end)
	end

	local function buffTimer(binding)
		return binding:map(function(secs: number)
			if secs <= 0.05 then
				return ""
			end
			return string.format("%.1fs", secs)
		end)
	end

	local function abilityEmblemColor(chargeBinding, readyColor: Color3)
		return chargeBinding:map(function(v: number)
			return if v >= 0.995 then readyColor else ui.MUTED
		end)
	end

	local topOffset = ui.MARGIN + Layout.inset()
	local hpRatio = math.clamp(health / math.max(maxHealth, 1), 0, 1)
	local hpTone = healthColor(hpRatio)
	local sectorText, sectorAccent = roomLabel(room, metrics.compact)

	local vitalsWidth = math.min(if metrics.compact then 176 else 214, math.floor(metrics.room.X * 0.34))
	local urgentWidth = math.min(340, metrics.room.X - 2 * ui.MARGIN)
	local urgentBottom = if metrics.touch then -(ui.MARGIN + 22) else -(ui.MARGIN + 10)

	-- Bottom-right radial arc geometry: on touch devices the 6 actuators wrap cleanly around
	-- Roblox's built-in bottom-right jump button (Config.TOUCH_BUTTON + Config.TOUCH_MARGIN) so
	-- jump is never obscured; on PC/console they fan tightly in the corner as compact telemetry.
	local touch = metrics.touch
	local atkSize = if touch then 76 else 64
	local moveSize = if touch then 58 else 46
	local skillSize = if touch then 58 else 52

	local jumpClear = Config.TOUCH_BUTTON + Config.TOUCH_MARGIN
	local atkPos = if touch then UDim2.new(1, -8, 1, -(jumpClear + 10)) else UDim2.new(1, -4, 1, -4)
	local dashPos = if touch then UDim2.new(1, -(jumpClear + 12), 1, -10) else UDim2.new(1, -82, 1, -6)
	local blockPos = if touch then UDim2.new(1, -(jumpClear + 78), 1, -30) else UDim2.new(1, -138, 1, -20)
	local spinPos = if touch then UDim2.new(1, -(jumpClear + 60), 1, -98) else UDim2.new(1, -124, 1, -76)
	local stingerPos = if touch then UDim2.new(1, -(jumpClear + 14), 1, -158) else UDim2.new(1, -72, 1, -116)
	local overDrivePos = if touch then UDim2.new(1, -16, 1, -(jumpClear + 98)) else UDim2.new(1, -10, 1, -92)

	return React.createElement(Scaled.Frame, nil, {
		-- Top-left: sharp Sector Hazard vitals plate + timed drop buffs stacked underneath so
		-- both bottom-left BuildStamp (dev) and the mobile thumbstick stay 100% clear.
		VitalsColumn = React.createElement("Frame", {
			Name = "VitalsColumn",
			Position = UDim2.fromOffset(ui.MARGIN, topOffset),
			Size = UDim2.fromOffset(vitalsWidth, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, {
			List = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Vitals = React.createElement(ui.Panel, {
				name = "Vitals",
				order = 1,
				size = UDim2.new(1, 0, 0, 0),
				padding = 8,
				accentColor = hpTone,
				accent = "left",
				strokeColor = if hpRatio <= 0.25 then ui.STRIKE else ui.BORDER,
			}, {
				Stack = React.createElement("UIListLayout", {
					Padding = UDim.new(0, 5),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Header = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 14),
					BackgroundTransparency = 1,
					LayoutOrder = 1,
				}, {
					Unit = React.createElement("TextLabel", {
						Size = UDim2.fromScale(0.5, 1),
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = 11,
						TextColor3 = ui.MUTED,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = "UNIT 01",
					}),
					Value = React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.fromScale(0.55, 1),
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = 12,
						TextColor3 = ui.TEXT,
						TextXAlignment = Enum.TextXAlignment.Right,
						Text = `{math.ceil(health)} / {maxHealth}`,
					}),
				}),
				HealthBar = React.createElement(ProgressTrack, {
					name = "HealthBar",
					order = 2,
					height = 10,
					color = hpTone,
					fill = UDim2.fromScale(hpRatio, 1),
					ticks = 3,
				}),
			}),
			DamageBuff = React.createElement(BuffChip, {
				name = "DamageBuff",
				order = 2,
				color = ui.BUFF_DAMAGE,
				fill = fillOf(damageBuff),
				remaining = buffTimer(damageBuffRemain),
				visible = activeOf(damageBuff),
				text = `DAÑO +{math.round((Config.BUFF_DAMAGE_MULTIPLIER - 1) * 100)}%`,
			}),
			SpeedBuff = React.createElement(BuffChip, {
				name = "SpeedBuff",
				order = 3,
				color = ui.BUFF_SPEED,
				fill = fillOf(speedBuff),
				remaining = buffTimer(speedBuffRemain),
				visible = activeOf(speedBuff),
				text = `VEL +{math.round((Config.BUFF_SPEED_MULTIPLIER - 1) * 100)}% · 2x`,
			}),
			DefenseBuff = React.createElement(BuffChip, {
				name = "DefenseBuff",
				order = 4,
				color = ui.BUFF_DEFENSE,
				fill = fillOf(defenseBuff),
				remaining = buffTimer(defenseBuffRemain),
				visible = activeOf(defenseBuff),
				text = `DEF +{math.round(Config.BUFF_DEFENSE_REDUCTION * 100)}%`,
			}),
		}),

		-- Top-center: Sector Hazard status pill (future 1-of-3 UpgradeChoice banner drops below).
		TopCenter = React.createElement("Frame", {
			Name = "TopCenter",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, topOffset),
			Size = UDim2.fromOffset(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, {
			List = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 6),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			SectorBar = React.createElement(ui.Panel, {
				name = "SectorBar",
				order = 1,
				size = UDim2.fromOffset(0, 0),
				automaticSize = Enum.AutomaticSize.XY,
				padding = 7,
				accentColor = sectorAccent,
				accent = "left",
				accentWidth = 4,
			}, {
				Label = React.createElement("TextLabel", {
					Size = UDim2.fromOffset(0, 18),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundTransparency = 1,
					Font = ui.MONO_FONT,
					TextSize = if metrics.compact then 13 else 14,
					TextColor3 = ui.TEXT,
					Text = sectorText,
				}),
			}),
		}),

		-- Bottom-center: urgent Heavy Charge, Stun & Grab Escape plates (same zone future Boss HP
		-- bars occupy so top-center UpgradeChoice banners never collide with combat bars).
		HeavyCharge = if chargingHeavy and not grabbed
			then React.createElement(ui.Panel, {
				name = "HeavyCharge",
				width = urgentWidth,
				padding = 9,
				accentColor = ui.HEAVY,
				accent = "left",
				strokeColor = ui.HEAVY,
				anchorPoint = Vector2.new(0.5, 1),
				position = UDim2.new(0.5, 0, 1, urgentBottom),
			}, {
				List = React.createElement("UIListLayout", {
					Padding = UDim.new(0, 5),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Header = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 15),
					BackgroundTransparency = 1,
					LayoutOrder = 1,
				}, {
					Title = React.createElement("TextLabel", {
						Size = UDim2.fromScale(0.6, 1),
						BackgroundTransparency = 1,
						Font = ui.DISPLAY_FONT,
						TextSize = 12,
						TextColor3 = ui.HEAVY,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = "ATAQUE PESADO",
					}),
					Timer = React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.fromScale(0.45, 1),
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = 12,
						TextColor3 = ui.TEXT,
						TextXAlignment = Enum.TextXAlignment.Right,
						Text = heavyCharge:map(function(value: number)
							local secs = math.min(value * Config.HEAVY_CHARGE_SECONDS, Config.HEAVY_CHARGE_SECONDS)
							return string.format("%.1fs / %.1fs", secs, Config.HEAVY_CHARGE_SECONDS)
						end),
					}),
				}),
				Track = React.createElement(ProgressTrack, {
					name = "ChargeProgress",
					order = 2,
					height = 10,
					color = ui.HEAVY,
					fill = fillOf(heavyCharge),
					ticks = 2,
				}),
			})
			else nil,

		StunBanner = React.createElement(ui.Panel, {
			name = "StunBanner",
			size = UDim2.fromOffset(0, 0),
			automaticSize = Enum.AutomaticSize.XY,
			padding = 8,
			color = ui.INK,
			transparency = 0.06,
			accentColor = ui.HEAVY,
			accent = "left",
			accentWidth = 4,
			strokeColor = ui.HEAVY,
			strokeThickness = 2,
			anchorPoint = Vector2.new(0.5, 1),
			position = UDim2.new(0.5, 0, 1, urgentBottom),
			visible = activeOf(stunRemaining),
		}, {
			Label = React.createElement("TextLabel", {
				Size = UDim2.fromOffset(0, 20),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
				Font = ui.DISPLAY_FONT,
				TextSize = if metrics.compact then 14 else 16,
				TextColor3 = ui.HEAVY,
				Text = stunRemaining:map(function(secs: number)
					return string.format("¡ATURDIDO!  //  %.1fs", math.max(secs, 0))
				end),
			}),
		}),

		GrabEscape = if grabbed
			then React.createElement(ui.Panel, {
				name = "GrabEscape",
				width = urgentWidth,
				padding = 10,
				accentColor = ui.GRAB,
				accent = "left",
				strokeColor = ui.GRAB,
				strokeThickness = 2,
				anchorPoint = Vector2.new(0.5, 1),
				position = UDim2.new(0.5, 0, 1, urgentBottom),
			}, {
				List = React.createElement("UIListLayout", {
					Padding = UDim.new(0, 5),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				Header = React.createElement("Frame", {
					Size = UDim2.new(1, 0, 0, 16),
					BackgroundTransparency = 1,
					LayoutOrder = 1,
				}, {
					Title = React.createElement("TextLabel", {
						Size = UDim2.fromScale(0.75, 1),
						BackgroundTransparency = 1,
						Font = ui.DISPLAY_FONT,
						TextSize = 13,
						TextColor3 = ui.GRAB,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = "¡ATRAPADO! PULSA ATACAR",
					}),
					Count = React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.fromScale(0.28, 1),
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = 13,
						TextColor3 = ui.TEXT,
						TextXAlignment = Enum.TextXAlignment.Right,
						Text = `{grabProgress}/{grabGoal}`,
					}),
				}),
				Track = React.createElement(ProgressTrack, {
					name = "EscapeProgress",
					order = 2,
					height = 12,
					color = ui.GRAB,
					fill = UDim2.fromScale(math.clamp(grabProgress / math.max(grabGoal, 1), 0, 1), 1),
				}),
			})
			else nil,

		-- Bottom-right: Machined Brawl Arc radial actuators (Attack, Dash, Block + 3 abilities).
		ActionArc = React.createElement("Frame", {
			Name = "ActionArc",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -ui.MARGIN, 1, -ui.MARGIN),
			Size = UDim2.fromOffset(if touch then 276 else 220, if touch then 274 else 188),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, {
			Attack = React.createElement(ui.Actuator, {
				name = "Attack",
				size = atkSize,
				position = atkPos,
				ringColor = if grabbed then ui.GRAB elseif chargingHeavy then ui.HEAVY else ui.STRIKE,
				fillColor = if grabbed then ui.GRAB else ui.HEAVY,
				fill = if chargingHeavy then heavyCharge else nil,
				fillTransparency = 0.55,
				label = if grabbed then "SOLTAR" else "ATK",
				subLabel = if grabbed
					then `{grabProgress}/{grabGoal}`
					elseif chargingHeavy then "CARGA"
					elseif not touch then "HOLD 3s"
					else nil,
				subColor = if grabbed then ui.GRAB elseif chargingHeavy then ui.HEAVY else ui.MUTED,
				keycap = "LMB",
				hideKeycap = touch,
				interactive = touch,
				onPress = CombatInput.beginAttack,
				onRelease = CombatInput.endAttack,
			}),
			Dash = React.createElement(ui.Actuator, {
				name = "Dash",
				size = moveSize,
				position = dashPos,
				ringColor = ui.KINETIC,
				fill = dashCharge,
				label = "DSH",
				subLabel = cooldownSub(dashRemain, "RDY"),
				keycap = "SH",
				hideKeycap = touch,
				interactive = touch,
				onPress = CombatInput.dash,
			}),
			Block = React.createElement(ui.Actuator, {
				name = "Block",
				size = moveSize,
				position = blockPos,
				ringColor = if blocking then ui.HAZARD else ui.GUARD,
				fill = blockCharge,
				fillColor = if blocking then ui.HAZARD else ui.GUARD,
				fillTransparency = if blocking then 0.52 else 0.78,
				label = "BLK",
				subLabel = if blocking then "GUARD" else "PARRY",
				subColor = if blocking then ui.HAZARD else ui.MUTED,
				keycap = "RMB",
				hideKeycap = touch,
				interactive = touch,
				onPress = CombatInput.beginBlock,
				onRelease = CombatInput.endBlock,
			}),
			-- 3 switchable active ability actuators (1 Giro, 2 Stinger, 3 Over Drive): on desktop,
			-- clicking selects the slot (and keys 1/2/3 + E cast); on touch, tapping casts directly.
			SpinAbility = React.createElement(ui.Actuator, {
				name = "SpinAbility",
				size = skillSize,
				position = spinPos,
				ringColor = ui.ABILITY_1,
				fill = spinCharge,
				selected = activeSlot == 1,
				emblem = buildAbilityEmblem("spin", skillSize, abilityEmblemColor(spinCharge, ui.ABILITY_1)),
				subLabel = abilityTimer(spinRemain),
				subTextSize = if touch then 17 else 16,
				subColor = ui.TEXT,
				keycap = if activeSlot == 1 then "1·E" else "1",
				hideKeycap = touch,
				interactive = true,
				onPress = if touch
					then CombatInput.spin
					else function()
						AbilityStore.select(1)
					end,
			}),
			StingerAbility = React.createElement(ui.Actuator, {
				name = "StingerAbility",
				size = skillSize,
				position = stingerPos,
				ringColor = ui.BUFF_DAMAGE,
				fill = stingerCharge,
				selected = activeSlot == 2,
				emblem = buildAbilityEmblem("stinger", skillSize, abilityEmblemColor(stingerCharge, ui.BUFF_DAMAGE)),
				subLabel = abilityTimer(stingerRemain),
				subTextSize = if touch then 17 else 16,
				subColor = ui.TEXT,
				keycap = if activeSlot == 2 then "2·E" else "2",
				hideKeycap = touch,
				interactive = true,
				onPress = if touch
					then CombatInput.stinger
					else function()
						AbilityStore.select(2)
					end,
			}),
			OverDriveAbility = React.createElement(ui.Actuator, {
				name = "OverDriveAbility",
				size = skillSize,
				position = overDrivePos,
				ringColor = ui.ABILITY_3,
				fill = overDriveCharge,
				selected = activeSlot == 3,
				emblem = buildAbilityEmblem("overdrive", skillSize, abilityEmblemColor(overDriveCharge, ui.ABILITY_3)),
				subLabel = abilityTimer(overDriveRemain),
				subTextSize = if touch then 17 else 16,
				subColor = ui.TEXT,
				keycap = if activeSlot == 3 then "3·E" else "3",
				hideKeycap = touch,
				interactive = true,
				onPress = if touch
					then CombatInput.overDrive
					else function()
						AbilityStore.select(3)
					end,
			}),
		}),
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
