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
	"AbilitySlot1",
	"AbilitySlot2",
	"AbilitySlot3",
	"AbilityLevel1",
	"AbilityLevel2",
	"AbilityLevel3",
	"HasDoubleJump",
	"HasDoubleDash",
}

local DROP_KINDS = {
	{ id = "heal", label = "Curación", color = ui.VITAL },
	{ id = "damage", label = "Daño", color = ui.BUFF_DAMAGE },
	{ id = "speed", label = "Velocidad", color = ui.BUFF_SPEED },
	{ id = "defense", label = "Defensa", color = ui.BUFF_DEFENSE },
}

local function BuildTab(props: { player: Player })
	local attrs = hooks.useAttributes(props.player, PLAYER_ATTRS)
	local targetSlot, setTargetSlot = React.useState(1)
	local targetLevel, setTargetLevel = React.useState(1)

	local slotButtons: { [string]: any } = {}
	for slot = 1, Config.ABILITY_SLOTS do
		local id = attrs[`AbilitySlot{slot}`]
		local lv = attrs[`AbilityLevel{slot}`] or 0
		local def = if type(id) == "string" and id ~= "" then Config.ABILITIES[id] else nil
		local label = if def then `S{slot}: {def.name} Lv.{lv}` else `S{slot}: Vacío`
		slotButtons[`Slot_{slot}`] = React.createElement(DevPrimitives.ChipButton, {
			text = label,
			active = targetSlot == slot,
			accent = ui.HAZARD,
			order = slot,
			onActivated = function()
				setTargetSlot(slot)
			end,
		})
	end
	slotButtons.ClearSlot = React.createElement(DevPrimitives.ChipButton, {
		text = `Limpiar S{targetSlot}`,
		accent = ui.STRIKE,
		order = Config.ABILITY_SLOTS + 1,
		onActivated = function()
			DevPrimitives.send("clearAbilitySlot", { slot = targetSlot })
		end,
	})

	local levelButtons: { [string]: any } = {}
	for lv = 1, Config.ABILITY_MAX_LEVEL do
		levelButtons[`Lv_{lv}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `Lv.{lv}`,
			active = targetLevel == lv,
			accent = ui.KINETIC,
			order = lv,
			onActivated = function()
				setTargetLevel(lv)
			end,
		})
	end

	local abilityButtons: { [string]: any } = {}
	for i, abilityId in ipairs(Config.UPGRADE_ABILITY_ORDER) do
		local def = Config.ABILITIES[abilityId]
		local owned = attrs[`AbilitySlot{targetSlot}`] == abilityId
		abilityButtons[`Ab_{abilityId}`] = React.createElement(DevPrimitives.ChipButton, {
			text = if def then def.name else abilityId,
			active = owned,
			accent = if def and def.color then def.color else ui.HAZARD,
			order = i,
			onActivated = function()
				DevPrimitives.send("setAbilitySlot", {
					slot = targetSlot,
					abilityId = abilityId,
					level = targetLevel,
				})
			end,
		})
	end

	local statButtons: { [string]: any } = {}
	for i, def in ipairs(Config.STAT_UPGRADES) do
		statButtons[`Stat_{def.id}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `+1 {def.title}`,
			order = i,
			onActivated = function()
				DevPrimitives.send("addStatUpgrade", { statId = def.id, count = 1 })
			end,
		})
	end

	local passiveButtons: { [string]: any } = {}
	for i, def in ipairs(Config.PASSIVE_UPGRADES) do
		local on = attrs[def.attribute] == true
		passiveButtons[`Pass_{def.id}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `{def.title}: {if on then "ON" else "OFF"}`,
			active = on,
			accent = ui.KINETIC,
			order = i,
			onActivated = function()
				DevPrimitives.send("setPassive", { passiveId = def.id, enabled = not on })
			end,
		})
	end

	local dropButtons: { [string]: any } = {}
	for i, item in ipairs(DROP_KINDS) do
		dropButtons[`Drop_{item.id}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `Drop {item.label}`,
			accent = item.color,
			order = i,
			onActivated = function()
				DevPrimitives.send("spawnDrop", { kind = item.id })
			end,
		})
	end

	local buffButtons: { [string]: any } = {}
	for i, item in ipairs(DROP_KINDS) do
		buffButtons[`Buff_{item.id}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `Buff {item.label}`,
			accent = item.color,
			order = i,
			onActivated = function()
				DevPrimitives.send("applyBuff", { kind = item.id })
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
		SlotHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Hueco y Nivel Objetivo", order = 1 }),
		SlotRow = React.createElement(DevPrimitives.WrapRow, { order = 2 }, slotButtons),
		LevelRow = React.createElement(DevPrimitives.WrapRow, { order = 3 }, levelButtons),

		AbHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Equipar Habilidad en Hueco", order = 4 }),
		AbRow = React.createElement(DevPrimitives.WrapRow, { order = 5 }, abilityButtons),

		OfferHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Ofertas 1-de-3 y Cola", order = 6 }),
		OfferRow = React.createElement(DevPrimitives.WrapRow, { order = 7 }, {
			Offer1 = React.createElement(DevPrimitives.ChipButton, {
				text = "+1 Oferta Sala",
				accent = ui.HAZARD,
				order = 1,
				onActivated = function()
					DevPrimitives.send("pushUpgradeOffer", { count = 1, isStarter = false })
				end,
			}),
			Offer3 = React.createElement(DevPrimitives.ChipButton, {
				text = "+3 Cola",
				accent = ui.HAZARD,
				order = 2,
				onActivated = function()
					DevPrimitives.send("pushUpgradeOffer", { count = 3, isStarter = false })
				end,
			}),
			Starter = React.createElement(DevPrimitives.ChipButton, {
				text = "Oferta Inicial",
				order = 3,
				onActivated = function()
					DevPrimitives.send("pushUpgradeOffer", { count = 1, isStarter = true })
				end,
			}),
			Reset = React.createElement(DevPrimitives.ChipButton, {
				text = "Reset Build",
				accent = ui.STRIKE,
				order = 4,
				onActivated = function()
					DevPrimitives.send("resetBuild", {})
				end,
			}),
		}),

		PassHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Pasivas de Movimiento", order = 8 }),
		PassRow = React.createElement(DevPrimitives.WrapRow, { order = 9 }, passiveButtons),

		StatHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Mejoras de Estadísticas", order = 10 }),
		StatRow = React.createElement(DevPrimitives.WrapRow, { order = 11 }, statButtons),

		DropHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Spawnear Drops en el Suelo", order = 12 }),
		DropRow = React.createElement(DevPrimitives.WrapRow, { order = 13 }, dropButtons),

		BuffHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Aplicar Buff Directo", order = 14 }),
		BuffRow = React.createElement(DevPrimitives.WrapRow, { order = 15 }, buffButtons),
	})
end

return BuildTab
