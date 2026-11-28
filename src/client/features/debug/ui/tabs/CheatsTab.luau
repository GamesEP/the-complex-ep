local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local Client = script:FindFirstAncestor("Client")
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local DevPrimitives = require(script.Parent.Parent.DevPrimitives)

local PLAYER_ATTRS = {
	"Health",
	"MaxHealth",
	"UpgradeDamageMult",
	"UpgradeSpeedMult",
	"UpgradeCooldownMult",
	"DebugGodMode",
	"DebugNoCooldowns",
	"DebugDamageMult",
}

local function CheatsTab(props: { player: Player })
	local attrs = hooks.useAttributes(props.player, PLAYER_ATTRS)
	local god = attrs.DebugGodMode == true
	local noCd = attrs.DebugNoCooldowns == true
	local dmgMult = attrs.DebugDamageMult or 1

	local multButtons: { [string]: any } = {}
	for i, mult in ipairs(Config.DEBUG_DAMAGE_MULTS) do
		multButtons[`Mult_{mult}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `{mult}x`,
			active = dmgMult == mult,
			accent = if mult > 1 then ui.STRIKE else ui.HAZARD,
			order = i,
			onActivated = function()
				DevPrimitives.send("setDamageMult", { mult = mult })
			end,
		})
	end

	local hp = math.floor(attrs.Health or 0)
	local maxHp = math.floor(attrs.MaxHealth or Config.PLAYER_MAX_HEALTH)
	local upgDmg = attrs.UpgradeDamageMult or 1
	local upgSpd = attrs.UpgradeSpeedMult or 1
	local upgCdr = attrs.UpgradeCooldownMult or 1

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
		Readout = React.createElement(ui.Title, {
			text = string.format("HP %d/%d · Dmg %.2fx · Spd %.2fx · CDR %.2fx", hp, maxHp, upgDmg * dmgMult, upgSpd, upgCdr),
			font = ui.MONO_FONT,
			textSize = 11,
			color = ui.KINETIC,
			order = 1,
		}),

		TogglesHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Toggles de Combate", order = 2 }),
		TogglesRow = React.createElement(DevPrimitives.WrapRow, { order = 3 }, {
			God = React.createElement(DevPrimitives.ChipButton, {
				text = if god then "God Mode: ON" else "God Mode: OFF",
				active = god,
				accent = ui.VITAL,
				order = 1,
				onActivated = function()
					DevPrimitives.send("setGodMode", { enabled = not god })
				end,
			}),
			NoCd = React.createElement(DevPrimitives.ChipButton, {
				text = if noCd then "No Cooldowns: ON" else "No Cooldowns: OFF",
				active = noCd,
				accent = ui.KINETIC,
				order = 2,
				onActivated = function()
					DevPrimitives.send("setNoCooldowns", { enabled = not noCd })
				end,
			}),
		}),

		DmgHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Multiplicador de Daño", order = 4 }),
		DmgRow = React.createElement(DevPrimitives.WrapRow, { order = 5 }, multButtons),

		HpHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Vida (ignora God Mode al autodañarse)", order = 6 }),
		HpRow = React.createElement(DevPrimitives.WrapRow, { order = 7 }, {
			FullHeal = React.createElement(DevPrimitives.ChipButton, {
				text = "Curar 100%",
				accent = ui.VITAL,
				order = 1,
				onActivated = function()
					DevPrimitives.send("adjustHealth", { mode = "full" })
				end,
			}),
			SelfDmg = React.createElement(DevPrimitives.ChipButton, {
				text = "-25 HP",
				accent = ui.HEAVY,
				order = 2,
				onActivated = function()
					DevPrimitives.send("adjustHealth", { mode = "damage", amount = 25 })
				end,
			}),
			Set1 = React.createElement(DevPrimitives.ChipButton, {
				text = "Fijar 1 HP",
				accent = ui.STRIKE,
				order = 3,
				onActivated = function()
					DevPrimitives.send("adjustHealth", { mode = "set1" })
				end,
			}),
		}),
	})
end

return CheatsTab
