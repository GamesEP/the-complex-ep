local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)

local Client = script:FindFirstAncestor("Client")
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local DebugStore = require(script.Parent.Parent.Parent.stores.DebugStore)
local DevPrimitives = require(script.Parent.Parent.DevPrimitives)

local THEME_CHOICES = {
	{ key = "auto", label = "Auto" },
	{ key = "1", label = "W1 Cyan" },
	{ key = "2", label = "W2 Bio" },
	{ key = "3", label = "W3 Amber" },
	{ key = "4", label = "W4 Violet" },
	{ key = "5", label = "W5 Red" },
	{ key = "6", label = "Boss Oh" },
	{ key = "cleared", label = "Cleared" },
}

export type OverlaysTabProps = {
	player: Player,
	setArenaTheme: ((string?) -> ())?,
	setTonemapper: ((string?) -> ())?,
}

local function OverlaysTab(props: OverlaysTabProps)
	local overlays = hooks.useAtom(DebugStore.overlays)
	local hitboxLayers = hooks.useAtom(DebugStore.hitboxLayers)
	local themeOverride = hooks.useAtom(DebugStore.themeOverride)
	local toneOverride = hooks.useAtom(DebugStore.tonemapperOverride)

	local flagNames = React.useMemo(function()
		local names: { string } = {}
		for flagName in pairs(Config.FLAGS) do
			table.insert(names, `{Config.FLAG_ATTRIBUTE_PREFIX}{flagName}`)
		end
		table.sort(names)
		return names
	end, {})
	local flagValues = hooks.useAttributes(props.player, flagNames)

	local themeButtons: { [string]: any } = {}
	for i, item in ipairs(THEME_CHOICES) do
		local isActive = (item.key == "auto" and themeOverride == nil) or themeOverride == item.key
		themeButtons[`Theme_{item.key}`] = React.createElement(DevPrimitives.ChipButton, {
			text = item.label,
			active = isActive,
			accent = ui.KINETIC,
			order = i,
			onActivated = function()
				local nextKey = if item.key == "auto" then nil else item.key
				DebugStore.setThemeOverride(nextKey)
				if props.setArenaTheme then
					props.setArenaTheme(nextKey)
				end
			end,
		})
	end

	local toneButtons: { [string]: any } = {}
	for i, preset in ipairs(Config.TONEMAPPER_PRESETS) do
		local isActive = (toneOverride == nil and preset.id == Config.TONEMAPPER_DEFAULT) or toneOverride == preset.id
		toneButtons[`Tone_{preset.id}`] = React.createElement(DevPrimitives.ChipButton, {
			text = preset.label,
			active = isActive,
			accent = ui.HAZARD,
			order = i,
			onActivated = function()
				DebugStore.setTonemapperOverride(preset.id)
				if props.setTonemapper then
					props.setTonemapper(preset.id)
				end
			end,
		})
	end

	local flagSummary: string
	if #flagNames == 0 then
		flagSummary = "Ningún feature flag registrado en Config.FLAGS"
	else
		local parts = {}
		for _, attrName in ipairs(flagNames) do
			local short = attrName:sub(#Config.FLAG_ATTRIBUTE_PREFIX + 1)
			table.insert(parts, `{short}={tostring(flagValues[attrName])}`)
		end
		flagSummary = table.concat(parts, "  ·  ")
	end

	local function toggleLayer(layer: DebugStore.HitboxLayerName)
		local nextOn = not (hitboxLayers :: any)[layer]
		DebugStore.setHitboxLayer(layer, nextOn)
		if nextOn and not overlays.hitboxes then
			DebugStore.setOverlay("hitboxes", true)
		end
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

		VisHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Overlays y Visualizadores", order = 1 }),
		VisRow = React.createElement(DevPrimitives.WrapRow, { order = 2 }, {
			Metrics = React.createElement(DevPrimitives.ChipButton, {
				text = `Métricas FPS: {if overlays.metrics then "ON" else "OFF"}`,
				active = overlays.metrics,
				accent = ui.VITAL,
				order = 1,
				onActivated = function()
					DebugStore.toggleOverlay("metrics")
				end,
			}),
			Log = React.createElement(DevPrimitives.ChipButton, {
				text = `Log Combate: {if overlays.combatLog then "ON" else "OFF"}`,
				active = overlays.combatLog,
				accent = ui.KINETIC,
				order = 2,
				onActivated = function()
					DebugStore.toggleOverlay("combatLog")
				end,
			}),
			Inspector = React.createElement(DevPrimitives.ChipButton, {
				text = `Inspector Enemigos: {if overlays.enemyInspector then "ON" else "OFF"}`,
				active = overlays.enemyInspector,
				accent = ui.HAZARD,
				order = 3,
				onActivated = function()
					DebugStore.toggleOverlay("enemyInspector")
				end,
			}),
			Hitboxes = React.createElement(DevPrimitives.ChipButton, {
				text = `Hitboxes / Zonas: {if overlays.hitboxes then "ON" else "OFF"}`,
				active = overlays.hitboxes,
				accent = ui.HEAVY,
				order = 4,
				onActivated = function()
					DebugStore.toggleOverlay("hitboxes")
				end,
			}),
		}),

		HitboxLayerHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Capas de Hitbox", order = 3 }),
		HitboxLayerRow = React.createElement(DevPrimitives.WrapRow, { order = 4 }, {
			PlayerAim = React.createElement(DevPrimitives.ChipButton, {
				text = "Cono Aim",
				active = overlays.hitboxes and hitboxLayers.playerAim,
				accent = ui.KINETIC,
				order = 1,
				onActivated = function()
					toggleLayer("playerAim")
				end,
			}),
			AttackHitbox = React.createElement(DevPrimitives.ChipButton, {
				text = "Ataque Activo",
				active = overlays.hitboxes and hitboxLayers.attackHitbox,
				accent = ui.HAZARD,
				order = 2,
				onActivated = function()
					toggleLayer("attackHitbox")
				end,
			}),
			EnemyReach = React.createElement(DevPrimitives.ChipButton, {
				text = "Enemigos",
				active = overlays.hitboxes and hitboxLayers.enemyReach,
				accent = ui.HEAVY,
				order = 3,
				onActivated = function()
					toggleLayer("enemyReach")
				end,
			}),
			Pillars = React.createElement(DevPrimitives.ChipButton, {
				text = "Pilares",
				active = overlays.hitboxes and hitboxLayers.pillars,
				accent = ui.GUARD,
				order = 4,
				onActivated = function()
					toggleLayer("pillars")
				end,
			}),
			DoorZone = React.createElement(DevPrimitives.ChipButton, {
				text = "Puerta Norte",
				active = overlays.hitboxes and hitboxLayers.doorZone,
				accent = ui.VITAL,
				order = 5,
				onActivated = function()
					toggleLayer("doorZone")
				end,
			}),
			AllLayers = React.createElement(DevPrimitives.ChipButton, {
				text = "Todas",
				order = 6,
				onActivated = function()
					DebugStore.setAllHitboxLayers(true)
					DebugStore.setOverlay("hitboxes", true)
				end,
			}),
			NoLayers = React.createElement(DevPrimitives.ChipButton, {
				text = "Ninguna",
				order = 7,
				onActivated = function()
					DebugStore.setAllHitboxLayers(false)
				end,
			}),
		}),

		ThemeHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Vista Previa ArenaTheme", order = 5 }),
		ThemeRow = React.createElement(DevPrimitives.WrapRow, { order = 6 }, themeButtons),

		ToneHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Tonemapping Preset", order = 7 }),
		ToneRow = React.createElement(DevPrimitives.WrapRow, { order = 8 }, toneButtons),

		FlagsHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Feature Flags (LocalPlayer)", order = 9 }),
		FlagsText = React.createElement(ui.Title, {
			text = flagSummary,
			font = ui.MONO_FONT,
			textSize = 11,
			color = ui.MUTED,
			order = 10,
		}),
	})
end

return OverlaysTab
