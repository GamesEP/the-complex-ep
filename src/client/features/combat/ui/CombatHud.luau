--[[
	The fight's HUD under the Hazard Arc design system (docs/ui-design-system.md):
	- Top-left: sharp architectural Vitals plate + active timed drop buff chips with live countdowns.
	- Top-center: Sector Hazard wave/hostiles pill (enemy Grabber / Paso Fantasma telegraphs appear
	  diegetically as overhead `!` triangles rather than invasive text banners).
	- Bottom-center: urgent Heavy Charge, Stun, and Grab Escape progress plates (same zone reserved
	  for future Boss HP bars so nothing collides with top-center UpgradeChoice banners).
	- Bottom-right: machined circular Hazard Arc actuators for Attack, Dash, Block and the 3
	  switchable ability slots of the player's class (docs/classes.md) — read-only +
	  click-to-select on PC/console, one-tap interactive touch buttons wrapping Roblox's jump
	  corner on mobile. No class chosen yet means no ability actuators.

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
local Difficulty = require(Shared.features.enemies.Difficulty)
local UpgradePool = require(Shared.features.upgrades.UpgradePool)

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Client = script:FindFirstAncestor("Client")

local UI = require(Client.ui.Mount)
local Layout = require(Client.ui.ScreenMetrics)
local Scaled = require(Client.ui.DesignScale)
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local AbilityStore = require(script.Parent.Parent.stores.AbilityStore)
local CombatInput = require(script.Parent.Parent.CombatInput)

local ROOM_ATTRIBUTES = {
	"Floor",
	"Room",
	"RoomCount",
	"RoomName",
	"RunState",
	"DoorOpen",
	"Wave",
	"WaveCount",
	"EnemiesLeft",
	"RoomState",
	"Difficulty",
	"BossName",
	"BossHealth",
	"BossMaxHealth",
}

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
	local diff = Difficulty.get(room.Difficulty)
	local floorIdx = if type(room.Floor) == "number" then math.floor(room.Floor) else 1
	local roomIdx = if type(room.Room) == "number" then math.floor(room.Room) else 1
	local roomCount = if type(room.RoomCount) == "number" then math.floor(room.RoomCount) else Config.ROOMS_PER_FLOOR
	local runState = room.RunState

	if runState == "victory" then
		return if compact then "SECTOR DESPEJADO" else `P{floorIdx}  //  {diff.shortName}  //  SECTOR DESPEJADO`, ui.VITAL
	end
	if runState == "defeat" then
		return if compact then "DERROTA" else `P{floorIdx}  //  {diff.shortName}  //  CAÍDA EN COMBATE`, ui.STRIKE
	end
	if runState == "transition" or room.DoorOpen == true then
		local nextRoom = math.min(roomIdx + 1, roomCount)
		if compact then
			return `PUERTA NORTE  ·  SALA {nextRoom}/{roomCount}`, ui.VITAL
		end
		return `SALA {roomIdx}/{roomCount} LIMPIA  //  CRUZA LA PUERTA NORTE → SALA {nextRoom}/{roomCount}`, ui.VITAL
	end
	if runState ~= "fighting" and room.RoomState ~= "fighting" then
		return if compact then "PREPARANDO..." else `P{floorIdx} · SALA {roomIdx}/{roomCount}  //  {diff.shortName}  //  PREPARANDO`, ui.MUTED
	end
	local wave = room.Wave or 1
	local waveCount = room.WaveCount or 1
	local left = room.EnemiesLeft or 0
	if compact then
		return `S{roomIdx}/{roomCount} | O{wave}/{waveCount} | {left}`, diff.color
	end
	return `P{floorIdx} · SALA {roomIdx}/{roomCount}  //  {diff.shortName}  //  OLEADA {wave}/{waveCount}  |  {left} HOSTILES`, diff.color
end

local ICON_READY = Color3.fromRGB(255, 255, 255)
local ICON_COOLDOWN = Color3.fromRGB(150, 162, 178)

local function buildAbilityEmblem(kind: string, diameter: number, iconColor: any)
	-- Every ability emblem renders in crisp pure white (dimming to cool silver on cooldown) with
	-- dark-ink contrast rims so the silhouette pops cleanly over any colored actuator fill.
	if kind == "stinger" then
		-- Estocada (Damage forward thrust): bold white spear shaft + arrowhead + speed streaks.
		local shaftLen = math.round(diameter * 0.5)
		local headSz = math.round(diameter * 0.22)
		return {
			Shaft = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.45, 0.55),
				Size = UDim2.fromOffset(shaftLen, 5),
				Rotation = -45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", {
					Color = ui.INK,
					Thickness = 1.4,
				}),
			}),
			SpearHead = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.66, 0.34),
				Size = UDim2.fromOffset(headSz, headSz),
				Rotation = 45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", {
					Color = ui.INK,
					Thickness = 1.6,
				}),
			}),
			StreakTop = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.32, 0.36),
				Size = UDim2.fromOffset(math.round(diameter * 0.28), 3),
				Rotation = -45,
				BackgroundColor3 = iconColor,
				BackgroundTransparency = 0.12,
				BorderSizePixel = 0,
			}, { Round = React.createElement(ui.Round, { radius = 2 }) }),
			StreakBottom = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.62, 0.68),
				Size = UDim2.fromOffset(math.round(diameter * 0.28), 3),
				Rotation = -45,
				BackgroundColor3 = iconColor,
				BackgroundTransparency = 0.12,
				BorderSizePixel = 0,
			}, { Round = React.createElement(ui.Round, { radius = 2 }) }),
		}
	elseif kind == "overdrive" then
		-- Corte Final (Damage 3 piercing slash waves): 3 crisp white stacked crescent waves + core.
		local waveW = math.round(diameter * 0.52)
		local coreSz = math.round(diameter * 0.16)
		return {
			Wave1 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.29),
				Size = UDim2.fromOffset(math.round(waveW * 0.8), 4),
				Rotation = -16,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
			Wave2 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(waveW, 6),
				Rotation = -16,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.4 }),
			}),
			Wave3 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.71),
				Size = UDim2.fromOffset(math.round(waveW * 0.88), 4),
				Rotation = -16,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
			Core = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(coreSz, coreSz),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.4 }),
			}),
		}
	elseif kind == "taunt" then
		-- Rugido (Tank war-cry stun): bold white radiating sonic shock rings + diamond core + rays.
		local outerSz = math.round(diameter * 0.62)
		local midSz = math.round(diameter * 0.4)
		local coreSz = math.round(diameter * 0.2)
		return {
			OuterWave = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.52),
				Size = UDim2.fromOffset(outerSz, outerSz),
				BackgroundTransparency = 1,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", {
					Color = iconColor,
					Thickness = 2.6,
					Transparency = 0.05,
				}),
			}),
			MidWave = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.52),
				Size = UDim2.fromOffset(midSz, midSz),
				BackgroundTransparency = 1,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", {
					Color = iconColor,
					Thickness = 2.2,
				}),
			}),
			RoarCore = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.52),
				Size = UDim2.fromOffset(coreSz, coreSz),
				Rotation = 45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.6 }),
			}),
			ShockRayL = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.24, 0.32),
				Size = UDim2.fromOffset(math.round(diameter * 0.18), 4),
				Rotation = 35,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
			ShockRayR = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.76, 0.32),
				Size = UDim2.fromOffset(math.round(diameter * 0.18), 4),
				Rotation = -35,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
		}
	elseif kind == "bulwark" then
		-- Coraza (Tank -75% armored shell): solid pure-white shield crest with dark inner armor cross.
		local shieldW = math.round(diameter * 0.46)
		local shieldH = math.round(diameter * 0.34)
		local tipSz = math.round(diameter * 0.32)
		return {
			ShieldTop = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.41),
				Size = UDim2.fromOffset(shieldW, shieldH),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 4 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.8 }),
			}),
			ShieldBase = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.56),
				Size = UDim2.fromOffset(tipSz, tipSz),
				Rotation = 45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
			}, {
				Round = React.createElement(ui.Round, { radius = 3 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.8 }),
			}),
			CoreVert = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(4, math.round(diameter * 0.34)),
				BackgroundColor3 = ui.INK,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, { Round = React.createElement(ui.Round, { radius = 2 }) }),
			CoreHoriz = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.43),
				Size = UDim2.fromOffset(math.round(diameter * 0.26), 4),
				BackgroundColor3 = ui.INK,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, { Round = React.createElement(ui.Round, { radius = 2 }) }),
		}
	elseif kind == "execute" then
		-- Vórtice (Damage boomerang twin daggers): bright white orbital ring + bold opposing white blades.
		local ringSz = math.round(diameter * 0.58)
		local bladeLen = math.round(diameter * 0.46)
		local hubSz = math.round(diameter * 0.16)
		return {
			OrbitRing = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(ringSz, ringSz),
				BackgroundTransparency = 1,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", {
					Color = iconColor,
					Thickness = 2.6,
				}),
			}),
			DaggerTop = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.57, 0.38),
				Size = UDim2.fromOffset(bladeLen, 5),
				Rotation = -30,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.5 }),
			}),
			DaggerBottom = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.43, 0.62),
				Size = UDim2.fromOffset(bladeLen, 5),
				Rotation = -30,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.5 }),
			}),
			Hub = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(hubSz, hubSz),
				Rotation = 45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.5 }),
			}),
		}
	elseif kind == "healPulse" then
		-- Santuario (Support 10 s healing zone): crisp white zone halo + bold solid white medical cross (+).
		local haloSz = math.round(diameter * 0.62)
		local armLen = math.round(diameter * 0.38)
		local armThick = math.max(math.round(diameter * 0.14), 7)
		return {
			ZoneHalo = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(haloSz, haloSz),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", {
					Color = iconColor,
					Thickness = 2.4,
				}),
			}),
			CrossV = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(armThick, armLen),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.5 }),
			}),
			CrossH = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(armLen, armThick),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.5 }),
			}),
		}
	elseif kind == "protectField" then
		-- Barrera (Support squad defense buff): crisp white barrier dome protecting 3 bold white squad nodes.
		local domeSz = math.round(diameter * 0.62)
		local pipSz = math.max(math.round(diameter * 0.13), 6)
		return {
			Dome = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(domeSz, domeSz),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", {
					Color = iconColor,
					Thickness = 2.8,
				}),
			}),
			PipCenter = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.41),
				Size = UDim2.fromOffset(pipSz + 2, pipSz + 2),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.4 }),
			}),
			PipLeft = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.35, 0.58),
				Size = UDim2.fromOffset(pipSz, pipSz),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.3 }),
			}),
			PipRight = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.65, 0.58),
				Size = UDim2.fromOffset(pipSz, pipSz),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.3 }),
			}),
		}
	elseif kind == "shockwave" then
		-- Repulsión (Support push + stun shockwave): bright white burst ring + 4 bold blast rays + core.
		local ringSz = math.round(diameter * 0.54)
		local rayLen = math.round(diameter * 0.24)
		local coreSz = math.round(diameter * 0.19)
		return {
			BlastRing = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(ringSz, ringSz),
				BackgroundTransparency = 1,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", {
					Color = iconColor,
					Thickness = 2.6,
				}),
			}),
			RayTL = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.29, 0.29),
				Size = UDim2.fromOffset(rayLen, 4),
				Rotation = 45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
			RayTR = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.71, 0.29),
				Size = UDim2.fromOffset(rayLen, 4),
				Rotation = -45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
			RayBL = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.29, 0.71),
				Size = UDim2.fromOffset(rayLen, 4),
				Rotation = -45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
			RayBR = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.71, 0.71),
				Size = UDim2.fromOffset(rayLen, 4),
				Rotation = 45,
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				Round = React.createElement(ui.Round, { radius = 2 }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.2 }),
			}),
			Core = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(coreSz, coreSz),
				BackgroundColor3 = iconColor,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
				Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.6 }),
			}),
		}
	end

	-- Default / Torbellino (`spin`): crisp pure-white cyclone vortex + crossed spin blades + core.
	local outerRing = math.round(diameter * 0.56)
	local innerRing = math.round(diameter * 0.3)
	local slashLen = math.round(diameter * 0.56)
	local coreSize = math.round(diameter * 0.16)
	return {
		OuterRing = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(outerRing, outerRing),
			BackgroundTransparency = 1,
		}, {
			Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
			Stroke = React.createElement("UIStroke", {
				Color = iconColor,
				Thickness = 2.8,
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
				Color = iconColor,
				Thickness = 1.8,
				Transparency = 0.2,
			}),
		}),
		BladeA = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(slashLen, 5),
			Rotation = 38,
			BackgroundColor3 = iconColor,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			Round = React.createElement(ui.Round, { radius = 2 }),
			Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.4 }),
		}),
		BladeB = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(slashLen, 5),
			Rotation = -38,
			BackgroundColor3 = iconColor,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			Round = React.createElement(ui.Round, { radius = 2 }),
			Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.4 }),
		}),
		Core = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(coreSize, coreSize),
			BackgroundColor3 = iconColor,
			BorderSizePixel = 0,
			ZIndex = 3,
		}, {
			Circle = React.createElement(ui.Round, { radius = ui.CORNER_ROUND }),
			Stroke = React.createElement("UIStroke", { Color = ui.INK, Thickness = 1.5 }),
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
	local hasDoubleJump = hooks.useAttribute(player, "HasDoubleJump") == true
	local hasDoubleDash = hooks.useAttribute(player, "HasDoubleDash") == true

	-- Active ability slots and levels come from drafted run upgrades (`AbilitySlot1..3`).
	local rawSlot1 = hooks.useAttribute(player, "AbilitySlot1")
	local rawSlot2 = hooks.useAttribute(player, "AbilitySlot2")
	local rawSlot3 = hooks.useAttribute(player, "AbilitySlot3")
	local rawLv1 = hooks.useAttribute(player, "AbilityLevel1")
	local rawLv2 = hooks.useAttribute(player, "AbilityLevel2")
	local rawLv3 = hooks.useAttribute(player, "AbilityLevel3")
	local slotAbility = {
		if type(rawSlot1) == "string" and rawSlot1 ~= "" then rawSlot1 else nil,
		if type(rawSlot2) == "string" and rawSlot2 ~= "" then rawSlot2 else nil,
		if type(rawSlot3) == "string" and rawSlot3 ~= "" then rawSlot3 else nil,
	}
	local slotLevel = {
		if type(rawLv1) == "number" then math.floor(rawLv1) else 0,
		if type(rawLv2) == "number" then math.floor(rawLv2) else 0,
		if type(rawLv3) == "number" then math.floor(rawLv3) else 0,
	}

	-- Per frame, so bindings: React writes progress fills and countdown strings without
	-- re-rendering the screen (docs/ui-architecture.md).
	local dashCharge, setDashCharge = React.useBinding(1)
	local dashSubLabel, setDashSubLabel = React.useBinding("RDY")
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
	local bulwarkBuff, setBulwarkBuff = React.useBinding(0)
	local bulwarkBuffRemain, setBulwarkBuffRemain = React.useBinding(0)
	local protectBuff, setProtectBuff = React.useBinding(0)
	local protectBuffRemain, setProtectBuffRemain = React.useBinding(0)
	local heavyCharge, setHeavyCharge = React.useBinding(0)
	local stunRemaining, setStunRemaining = React.useBinding(0)

	hooks.useSignal(RunService.Heartbeat, function()
		local now = workspace:GetServerTimeNow()
		local dashReadyAt = player:GetAttribute("DashReadyAt")
		local blockReadyAt = player:GetAttribute("BlockReadyAt")
		local cdMultAttr = player:GetAttribute("UpgradeCooldownMult")
		local cdMult = if type(cdMultAttr) == "number" and cdMultAttr > 0
			then math.max(cdMultAttr, Config.MIN_COOLDOWN_MULTIPLIER)
			else 1
		local function slotTimes(slot: number): (number?, number)
			local abilityId = player:GetAttribute(`AbilitySlot{slot}`)
			local ability = if type(abilityId) == "string" and abilityId ~= "" then Config.ABILITIES[abilityId] else nil
			if not ability then
				return nil, 1
			end
			local lvAttr = player:GetAttribute(`AbilityLevel{slot}`)
			local lv = if type(lvAttr) == "number" and lvAttr >= 1 then math.floor(lvAttr) else 1
			local _, lvCdMult = UpgradePool.levelMultipliers(lv)
			return player:GetAttribute(ability.readyAttribute), math.max(ability.cooldown * lvCdMult * cdMult, 0.35)
		end
		local spinReadyAt, spinCooldown = slotTimes(1)
		local stingerReadyAt, stingerCooldown = slotTimes(2)
		local overDriveReadyAt, overDriveCooldown = slotTimes(3)
		local damageBuffUntil = player:GetAttribute("DamageBuffUntil")
		local speedBuffUntil = player:GetAttribute("SpeedBuffUntil")
		local defenseBuffUntil = player:GetAttribute("DefenseBuffUntil")
		local bulwarkUntil = player:GetAttribute("BulwarkUntil")
		local protectBuffUntil = player:GetAttribute("ProtectBuffUntil")

		local dashChargesAttr = player:GetAttribute("DashCharges")
		local doubleDash = player:GetAttribute("HasDoubleDash") == true
		local maxDash = Drops.maxDashCharges(speedBuffUntil, now, doubleDash)
		local dashCooldown = math.max(Config.DASH_COOLDOWN * cdMult, 0.35)
		local dashSecs = remainingSeconds(dashReadyAt, now)
		local availableDash = if dashSecs <= 0.05
			then maxDash
			elseif type(dashChargesAttr) == "number" then math.clamp(dashChargesAttr, 0, maxDash)
			else 0
		if availableDash > 0 then
			setDashCharge(1)
			setDashSubLabel(if maxDash >= 2 then `x{availableDash}` else "RDY")
		else
			setDashCharge(charge(dashReadyAt, dashCooldown, now))
			setDashSubLabel(string.format("%.1fs", dashSecs))
		end
		setBlockCharge(charge(blockReadyAt, Config.BLOCK_COOLDOWN, now))

		setSpinCharge(charge(spinReadyAt, spinCooldown, now))
		setSpinRemain(remainingSeconds(spinReadyAt, now))
		setStingerCharge(charge(stingerReadyAt, stingerCooldown, now))
		setStingerRemain(remainingSeconds(stingerReadyAt, now))
		setOverDriveCharge(charge(overDriveReadyAt, overDriveCooldown, now))
		setOverDriveRemain(remainingSeconds(overDriveReadyAt, now))

		setDamageBuff(Drops.buffRemaining(damageBuffUntil, Config.BUFF_DAMAGE_DURATION, now))
		setDamageBuffRemain(remainingSeconds(damageBuffUntil, now))
		setSpeedBuff(Drops.buffRemaining(speedBuffUntil, Config.BUFF_SPEED_DURATION, now))
		setSpeedBuffRemain(remainingSeconds(speedBuffUntil, now))
		setDefenseBuff(Drops.buffRemaining(defenseBuffUntil, Config.BUFF_DEFENSE_DURATION, now))
		setDefenseBuffRemain(remainingSeconds(defenseBuffUntil, now))
		setBulwarkBuff(Drops.buffRemaining(bulwarkUntil, Config.BULWARK_DURATION, now))
		setBulwarkBuffRemain(remainingSeconds(bulwarkUntil, now))
		setProtectBuff(Drops.buffRemaining(protectBuffUntil, Config.PROTECT_BUFF_DURATION, now))
		setProtectBuffRemain(remainingSeconds(protectBuffUntil, now))

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

	local function abilityEmblemColor(chargeBinding)
		return chargeBinding:map(function(v: number)
			return if v >= 0.995 then ICON_READY else ICON_COOLDOWN
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

	local function slotColor(slot: number, fallback: Color3): Color3
		local abilityId = slotAbility[slot]
		local ability = abilityId and Config.ABILITIES[abilityId]
		return if ability and ability.color then ability.color else fallback
	end
	local slot1Color = slotColor(1, ui.ABILITY_1)
	local slot2Color = slotColor(2, ui.BUFF_DAMAGE)
	local slot3Color = slotColor(3, ui.ABILITY_3)

	local bossName = if type(room.BossName) == "string" and room.BossName ~= "" then room.BossName else nil
	local bossHealth = if type(room.BossHealth) == "number" then room.BossHealth else 0
	local bossMaxHealth = if type(room.BossMaxHealth) == "number" and room.BossMaxHealth > 0 then room.BossMaxHealth else 0
	local showBossBar = bossName ~= nil and bossMaxHealth > 0 and bossHealth > 0
	local bossRatio = if showBossBar then math.clamp(bossHealth / bossMaxHealth, 0, 1) else 0
	local bossWidth = math.min(if metrics.compact then 280 else 440, metrics.room.X - 2 * ui.MARGIN)
	local urgentOffset = if showBossBar then urgentBottom - 62 else urgentBottom

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
			PassivesRow = if hasDoubleJump or hasDoubleDash
				then React.createElement("Frame", {
					Name = "PassivesRow",
					LayoutOrder = 2,
					Size = UDim2.new(1, 0, 0, 20),
					BackgroundTransparency = 1,
				}, {
					Row = React.createElement("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, 6),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
					DoubleJumpBadge = if hasDoubleJump
						then React.createElement("Frame", {
							LayoutOrder = 1,
							Size = UDim2.fromOffset(0, 20),
							AutomaticSize = Enum.AutomaticSize.X,
							BackgroundColor3 = ui.PANEL,
							BackgroundTransparency = 0.08,
							BorderSizePixel = 0,
						}, {
							Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
							Stroke = React.createElement(ui.Outline, { color = ui.KINETIC, thickness = 1 }),
							Pad = React.createElement("UIPadding", {
								PaddingLeft = UDim.new(0, 6),
								PaddingRight = UDim.new(0, 6),
							}),
							Label = React.createElement("TextLabel", {
								Size = UDim2.fromOffset(0, 20),
								AutomaticSize = Enum.AutomaticSize.X,
								BackgroundTransparency = 1,
								Font = ui.MONO_FONT,
								TextSize = 10,
								TextColor3 = ui.KINETIC,
								Text = "2× SALTO",
							}),
						})
						else nil,
					DoubleDashBadge = if hasDoubleDash
						then React.createElement("Frame", {
							LayoutOrder = 2,
							Size = UDim2.fromOffset(0, 20),
							AutomaticSize = Enum.AutomaticSize.X,
							BackgroundColor3 = ui.PANEL,
							BackgroundTransparency = 0.08,
							BorderSizePixel = 0,
						}, {
							Corner = React.createElement(ui.Round, { radius = ui.CORNER }),
							Stroke = React.createElement(ui.Outline, { color = ui.BUFF_SPEED, thickness = 1 }),
							Pad = React.createElement("UIPadding", {
								PaddingLeft = UDim.new(0, 6),
								PaddingRight = UDim.new(0, 6),
							}),
							Label = React.createElement("TextLabel", {
								Size = UDim2.fromOffset(0, 20),
								AutomaticSize = Enum.AutomaticSize.X,
								BackgroundTransparency = 1,
								Font = ui.MONO_FONT,
								TextSize = 10,
								TextColor3 = ui.BUFF_SPEED,
								Text = "2× DASH",
							}),
						})
						else nil,
				})
				else nil,
			DamageBuff = React.createElement(BuffChip, {
				name = "DamageBuff",
				order = 3,
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
			BulwarkBuff = React.createElement(BuffChip, {
				name = "BulwarkBuff",
				order = 5,
				color = Color3.fromRGB(115, 190, 255),
				fill = fillOf(bulwarkBuff),
				remaining = buffTimer(bulwarkBuffRemain),
				visible = activeOf(bulwarkBuff),
				text = `CORAZA -{math.round(Config.BULWARK_REDUCTION * 100)}%`,
			}),
			ProtectBuff = React.createElement(BuffChip, {
				name = "ProtectBuff",
				order = 6,
				color = Color3.fromRGB(90, 205, 255),
				fill = fillOf(protectBuff),
				remaining = buffTimer(protectBuffRemain),
				visible = activeOf(protectBuff),
				text = `BARRERA +{math.round(Config.PROTECT_BUFF_REDUCTION * 100)}%`,
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

		-- Bottom-center: Boss HP plate (UNIT // OH) plus urgent Heavy Charge / Stun / Grab Escape
		-- stacked cleanly above it so nothing collides with top-center banners or side controls.
		BossBar = if showBossBar
			then React.createElement(ui.Panel, {
				name = "BossBar",
				width = bossWidth,
				padding = 9,
				accentColor = ui.STRIKE,
				accent = "left",
				accentWidth = 4,
				strokeColor = ui.STRIKE,
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
						Size = UDim2.fromScale(0.7, 1),
						BackgroundTransparency = 1,
						Font = ui.DISPLAY_FONT,
						TextSize = if metrics.compact then 12 else 14,
						TextColor3 = ui.STRIKE,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = `UNIT // {bossName}`,
					}),
					Hp = React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.fromScale(0.35, 1),
						BackgroundTransparency = 1,
						Font = ui.MONO_FONT,
						TextSize = 12,
						TextColor3 = ui.TEXT,
						TextXAlignment = Enum.TextXAlignment.Right,
						Text = `{math.ceil(bossHealth)} / {math.ceil(bossMaxHealth)}`,
					}),
				}),
				Track = React.createElement(ProgressTrack, {
					name = "BossHealthBar",
					order = 2,
					height = 12,
					color = ui.STRIKE,
					fill = UDim2.fromScale(bossRatio, 1),
					ticks = 3,
				}),
			})
			else nil,

		HeavyCharge = if chargingHeavy and not grabbed
			then React.createElement(ui.Panel, {
				name = "HeavyCharge",
				width = urgentWidth,
				padding = 9,
				accentColor = ui.HEAVY,
				accent = "left",
				strokeColor = ui.HEAVY,
				anchorPoint = Vector2.new(0.5, 1),
				position = UDim2.new(0.5, 0, 1, urgentOffset),
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
			position = UDim2.new(0.5, 0, 1, urgentOffset),
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
				position = UDim2.new(0.5, 0, 1, urgentOffset),
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
					elseif not touch then string.format("HOLD %.1fs", Config.HEAVY_CHARGE_SECONDS)
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
				subLabel = dashSubLabel,
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
			-- 3 switchable active ability actuators driven by the player's drafted run slots.
			SpinAbility = slotAbility[1] and React.createElement(ui.Actuator, {
				name = "SpinAbility",
				size = skillSize,
				position = spinPos,
				ringColor = slot1Color,
				fillColor = slot1Color,
				fill = spinCharge,
				selected = activeSlot == 1,
				emblem = buildAbilityEmblem(slotAbility[1] or "spin", skillSize, abilityEmblemColor(spinCharge)),
				subLabel = abilityTimer(spinRemain),
				subTextSize = if touch then 17 else 16,
				subColor = ui.TEXT,
				keycap = if slotLevel[1] >= 2
					then (if activeSlot == 1 then `1·E·N{slotLevel[1]}` else `1·N{slotLevel[1]}`)
					else (if activeSlot == 1 then "1·E" else "1"),
				hideKeycap = touch,
				interactive = true,
				onPress = if touch
					then CombatInput.spin
					else function()
						AbilityStore.select(1)
					end,
			}),
			StingerAbility = slotAbility[2] and React.createElement(ui.Actuator, {
				name = "StingerAbility",
				size = skillSize,
				position = stingerPos,
				ringColor = slot2Color,
				fillColor = slot2Color,
				fill = stingerCharge,
				selected = activeSlot == 2,
				emblem = buildAbilityEmblem(slotAbility[2] or "stinger", skillSize, abilityEmblemColor(stingerCharge)),
				subLabel = abilityTimer(stingerRemain),
				subTextSize = if touch then 17 else 16,
				subColor = ui.TEXT,
				keycap = if slotLevel[2] >= 2
					then (if activeSlot == 2 then `2·E·N{slotLevel[2]}` else `2·N{slotLevel[2]}`)
					else (if activeSlot == 2 then "2·E" else "2"),
				hideKeycap = touch,
				interactive = true,
				onPress = if touch
					then CombatInput.stinger
					else function()
						AbilityStore.select(2)
					end,
			}),
			OverDriveAbility = slotAbility[3] and React.createElement(ui.Actuator, {
				name = "OverDriveAbility",
				size = skillSize,
				position = overDrivePos,
				ringColor = slot3Color,
				fillColor = slot3Color,
				fill = overDriveCharge,
				selected = activeSlot == 3,
				emblem = buildAbilityEmblem(slotAbility[3] or "overdrive", skillSize, abilityEmblemColor(overDriveCharge)),
				subLabel = abilityTimer(overDriveRemain),
				subTextSize = if touch then 17 else 16,
				subColor = ui.TEXT,
				keycap = if slotLevel[3] >= 2
					then (if activeSlot == 3 then `3·E·N{slotLevel[3]}` else `3·N{slotLevel[3]}`)
					else (if activeSlot == 3 then "3·E" else "3"),
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
