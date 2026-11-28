local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local DebugCommands = require(Shared.features.debug.DebugCommands)

local Client = script:FindFirstAncestor("Client")
local hooks = require(Client.ui.hooks)
local ui = require(Client.ui.theme.Widgets)

local DevPrimitives = require(script.Parent.Parent.DevPrimitives)

local WORLD_ATTRS = { "DebugAiMode", "EnemiesLeft", "BossName", "BossHealth", "BossMaxHealth" }
local BOSS_HP_STEPS = { 0.75, 0.50, 0.25, 0.10 }

local function EnemiesTab(props: { world: Instance })
	local world = hooks.useAttributes(props.world, WORLD_ATTRS)
	local catalog = React.useMemo(DebugCommands.enemyCatalog, {})
	local selectedIdx, setSelectedIdx = React.useState(1)
	local spawnCount, setSpawnCount = React.useState(1)

	local aiMode = world.DebugAiMode or "normal"
	local selected = catalog[selectedIdx] or catalog[1]

	local catalogButtons: { [string]: any } = {}
	for i, entry in ipairs(catalog) do
		catalogButtons[`Enemy_{i}`] = React.createElement(DevPrimitives.ChipButton, {
			text = entry.label,
			active = i == selectedIdx,
			accent = if entry.isBoss then ui.STRIKE else ui.HAZARD,
			order = i,
			onActivated = function()
				setSelectedIdx(i)
			end,
		})
	end

	local countButtons: { [string]: any } = {}
	for i, n in ipairs(Config.DEBUG_SPAWN_COUNTS) do
		countButtons[`Count_{n}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `x{n}`,
			active = spawnCount == n,
			accent = ui.KINETIC,
			order = i,
			onActivated = function()
				setSpawnCount(n)
			end,
		})
	end

	local bossHpButtons: { [string]: any } = {}
	for i, pct in ipairs(BOSS_HP_STEPS) do
		bossHpButtons[`BossHp_{i}`] = React.createElement(DevPrimitives.ChipButton, {
			text = `{math.floor(pct * 100)}%`,
			accent = ui.STRIKE,
			order = i,
			onActivated = function()
				DevPrimitives.send("setBossHpPercent", { percent = pct })
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
		Status = React.createElement(ui.Title, {
			text = `Activos: {world.EnemiesLeft or 0}/{Config.DEBUG_MAX_SPAWN_COUNT} · IA: {tostring(aiMode):upper()}`,
			font = ui.MONO_FONT,
			textSize = 11,
			color = ui.KINETIC,
			order = 1,
		}),

		CatalogHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Tipo y Variante de Arma", order = 2 }),
		CatalogRow = React.createElement(DevPrimitives.WrapRow, { order = 3 }, catalogButtons),

		CountHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Cantidad y Spawn", order = 4 }),
		CountRow = React.createElement(DevPrimitives.WrapRow, { order = 5 }, countButtons),

		SpawnRow = React.createElement(DevPrimitives.WrapRow, { order = 6 }, {
			Spawn = React.createElement(DevPrimitives.ChipButton, {
				text = `Spawn {spawnCount}x {if selected then selected.label else "Enemy"}`,
				active = true,
				accent = ui.HAZARD,
				order = 1,
				onActivated = function()
					if selected then
						DevPrimitives.send("spawnEnemy", {
							kind = selected.kind,
							weapon = selected.weapon,
							count = spawnCount,
						})
					end
				end,
			}),
			Dummy = React.createElement(DevPrimitives.ChipButton, {
				text = "Spawn Dummy (9999 HP)",
				accent = ui.VITAL,
				order = 2,
				onActivated = function()
					DevPrimitives.send("spawnDummy", {})
				end,
			}),
			KillAll = React.createElement(DevPrimitives.ChipButton, {
				text = "Kill All",
				accent = ui.STRIKE,
				order = 3,
				onActivated = function()
					DevPrimitives.send("killAllEnemies", {})
				end,
			}),
		}),

		AiHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Modo de IA", order = 7 }),
		AiRow = React.createElement(DevPrimitives.WrapRow, { order = 8 }, {
			Normal = React.createElement(DevPrimitives.ChipButton, {
				text = "Normal",
				active = aiMode == "normal",
				order = 1,
				onActivated = function()
					DevPrimitives.send("setAiMode", { mode = "normal" })
				end,
			}),
			NoAttack = React.createElement(DevPrimitives.ChipButton, {
				text = "Sin Ataques",
				active = aiMode == "noAttack",
				accent = ui.HEAVY,
				order = 2,
				onActivated = function()
					DevPrimitives.send("setAiMode", { mode = "noAttack" })
				end,
			}),
			Frozen = React.createElement(DevPrimitives.ChipButton, {
				text = "Congelada",
				active = aiMode == "frozen",
				accent = ui.KINETIC,
				order = 3,
				onActivated = function()
					DevPrimitives.send("setAiMode", { mode = "frozen" })
				end,
			}),
		}),

		SpecialHeader = React.createElement(DevPrimitives.SectionHeader, { text = "Forzar Especial / Boss Oh", order = 9 }),
		SpecialRow = React.createElement(DevPrimitives.WrapRow, { order = 10 }, {
			Nearest = React.createElement(DevPrimitives.ChipButton, {
				text = "Reset CD Cercano",
				order = 1,
				onActivated = function()
					DevPrimitives.send("forceSpecial", {})
				end,
			}),
			Cone = React.createElement(DevPrimitives.ChipButton, {
				text = "Oh: Cono",
				accent = ui.STRIKE,
				order = 2,
				onActivated = function()
					DevPrimitives.send("forceSpecial", { move = "cone" })
				end,
			}),
			Leap = React.createElement(DevPrimitives.ChipButton, {
				text = "Oh: Salto",
				accent = ui.STRIKE,
				order = 3,
				onActivated = function()
					DevPrimitives.send("forceSpecial", { move = "leap" })
				end,
			}),
			Nova = React.createElement(DevPrimitives.ChipButton, {
				text = "Oh: Pulso",
				accent = ui.STRIKE,
				order = 4,
				onActivated = function()
					DevPrimitives.send("forceSpecial", { move = "nova" })
				end,
			}),
		}),

		BossHpHeader = React.createElement(DevPrimitives.SectionHeader, {
			text = `Vida del Jefe ({math.floor(world.BossHealth or 0)}/{math.floor(world.BossMaxHealth or 0)})`,
			order = 11,
		}),
		BossHpRow = React.createElement(DevPrimitives.WrapRow, { order = 12 }, bossHpButtons),
	})
end

return EnemiesTab
