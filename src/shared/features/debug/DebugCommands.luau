--!strict
--[[
	Pure command schemas, permission policy, enemy/variant catalog, playtest presets, and log
	buffer helpers for the in-game admin dev/debug toolset.

	No Roblox services are touched here so `make test` validates every permission boundary,
	command payload rule, and preset reference offline.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local DebugCommands = {}

export type DebugTab = "run" | "enemies" | "build" | "cheats" | "presets" | "overlays"

export type EnemyCatalogEntry = {
	kind: string,
	weapon: string?,
	label: string,
	isBoss: boolean,
}

export type PresetStep = {
	action: string,
	payload: { [string]: any },
}

export type PresetDef = {
	id: string,
	title: string,
	description: string,
	openOverlay: string?,
	steps: { PresetStep },
}

export type LogEntry = {
	seq: number,
	tag: string,
	text: string,
	kind: "info" | "hit" | "hurt" | "parry" | "warn",
}

DebugCommands.TABS = { "run", "enemies", "build", "cheats", "presets", "overlays" } :: { DebugTab }

DebugCommands.AI_MODES = { "normal", "noAttack", "frozen" }
DebugCommands.FORCE_STATES = { "preparing", "victory", "defeat" }
DebugCommands.HEALTH_MODES = { "full", "damage", "set1" }
DebugCommands.BOSS_OH_MOVES = { "cone", "leap", "nova" }

local PREFERRED_KIND_ORDER = { "melee", "ranged", "exploder", "grabber", "bossOh" }

local WEAPON_LABELS: { [string]: string } = {
	sword = "Espada",
	dual = "Doble Hoja",
	axe = "Hacha",
	mace = "Maza",
	rifle = "Rifle",
	shotgun = "Escopeta",
	plasma = "Cañón Plasma",
	minigun = "Minigun",
}

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isIntegerInRange(v: any, minVal: number, maxVal: number): boolean
	return isFiniteNumber(v) and v % 1 == 0 and v >= minVal and v <= maxVal
end

local function inList(list: { string }, value: any): boolean
	if type(value) ~= "string" then
		return false
	end
	return table.find(list, value) ~= nil
end

--=============================================================================
-- Permission policy
--=============================================================================

--[[
	Pure gate deciding whether a player may use debug tools in the current environment.
	Enforces both `isAdmin` AND the production kill switch so production stays zero-footprint
	even for `Config.ADMIN_USER_IDS` unless `allowInProd` is explicitly enabled.
]]
function DebugCommands.canUse(envName: string, isAdmin: boolean, allowInProd: boolean?): boolean
	if not isAdmin then
		return false
	end
	if envName == Config.ENV_PRODUCTION then
		return allowInProd == true
	end
	return true
end

--=============================================================================
-- Catalog lookups (derived from Config so nothing drifts)
--=============================================================================

function DebugCommands.isValidTab(tab: any): boolean
	return inList(DebugCommands.TABS :: { string }, tab)
end

function DebugCommands.isValidDifficulty(diffId: any): boolean
	return type(diffId) == "string" and Config.DIFFICULTIES[diffId] ~= nil
end

function DebugCommands.isValidAbility(abilityId: any): boolean
	return type(abilityId) == "string" and table.find(Config.UPGRADE_ABILITY_ORDER, abilityId) ~= nil
end

function DebugCommands.isValidStat(statId: any): boolean
	if type(statId) ~= "string" then
		return false
	end
	for _, def in ipairs(Config.STAT_UPGRADES) do
		if def.id == statId then
			return true
		end
	end
	return false
end

function DebugCommands.isValidPassive(passiveId: any): boolean
	if type(passiveId) ~= "string" then
		return false
	end
	for _, def in ipairs(Config.PASSIVE_UPGRADES) do
		if def.id == passiveId then
			return true
		end
	end
	return false
end

function DebugCommands.isValidDrop(dropKind: any): boolean
	return type(dropKind) == "string" and Config.DROP_MODELS[dropKind] ~= nil
end

function DebugCommands.isValidEnemy(kind: any, weapon: any?): boolean
	if type(kind) ~= "string" then
		return false
	end
	local spec = Config.ENEMY_KINDS[kind]
	if not spec then
		return false
	end
	if weapon == nil or weapon == "" then
		return true
	end
	if type(weapon) ~= "string" or not spec.variants then
		return false
	end
	for _, variant in ipairs(spec.variants) do
		if variant.weapon == weapon then
			return true
		end
	end
	return false
end

-- Deterministic catalog of every spawnable `kind` + `weapon` pair from `Config.ENEMY_KINDS`.
function DebugCommands.enemyCatalog(): { EnemyCatalogEntry }
	local orderedKinds: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, kind in ipairs(PREFERRED_KIND_ORDER) do
		if Config.ENEMY_KINDS[kind] then
			table.insert(orderedKinds, kind)
			seen[kind] = true
		end
	end
	local extras: { string } = {}
	for kind in pairs(Config.ENEMY_KINDS) do
		if not seen[kind] then
			table.insert(extras, kind)
		end
	end
	table.sort(extras)
	for _, kind in ipairs(extras) do
		table.insert(orderedKinds, kind)
	end

	local out: { EnemyCatalogEntry } = {}
	for _, kind in ipairs(orderedKinds) do
		local spec = Config.ENEMY_KINDS[kind]
		local isBoss = spec.isBoss == true
		if spec.variants and #spec.variants > 0 then
			for _, variant in ipairs(spec.variants) do
				local weaponLabel = WEAPON_LABELS[variant.weapon] or variant.weapon
				table.insert(out, {
					kind = kind,
					weapon = variant.weapon,
					label = `{spec.displayName} ({weaponLabel})`,
					isBoss = isBoss,
				})
			end
		else
			table.insert(out, {
				kind = kind,
				weapon = nil,
				label = spec.displayName,
				isBoss = isBoss,
			})
		end
	end
	return out
end

--=============================================================================
-- One-click playtest presets
--=============================================================================

DebugCommands.PRESET_ORDER = {
	"boss_oh_practice",
	"parry_gym",
	"perf_25_enemies",
	"upgrade_queue_test",
	"clean_reset",
}

DebugCommands.PRESETS = {
	boss_oh_practice = {
		id = "boss_oh_practice",
		title = "Boss Oh Practice",
		description = "Room 5 + 3x Lv.2 abilities + Double Dash + Full HP",
		steps = {
			{ action = "setSandbox", payload = { enabled = false } },
			{ action = "setAiMode", payload = { mode = "normal" } },
			{ action = "jumpRoom", payload = { room = 5 } },
			{ action = "setAbilitySlot", payload = { slot = 1, abilityId = "spin", level = 2 } },
			{ action = "setAbilitySlot", payload = { slot = 2, abilityId = "stinger", level = 2 } },
			{ action = "setAbilitySlot", payload = { slot = 3, abilityId = "overdrive", level = 2 } },
			{ action = "setPassive", payload = { passiveId = "passive_double_dash", enabled = true } },
			{ action = "adjustHealth", payload = { mode = "full" } },
		},
	},
	parry_gym = {
		id = "parry_gym",
		title = "Parry Gym",
		description = "Sandbox + God Mode + Sword Centinela & Rifle Cazador",
		steps = {
			{ action = "setSandbox", payload = { enabled = true } },
			{ action = "setAiMode", payload = { mode = "normal" } },
			{ action = "killAllEnemies", payload = {} },
			{ action = "setGodMode", payload = { enabled = true } },
			{ action = "spawnEnemy", payload = { kind = "melee", weapon = "sword", count = 1, aroundPlayer = true } },
			{ action = "spawnEnemy", payload = { kind = "ranged", weapon = "rifle", count = 1, aroundPlayer = true } },
		},
	},
	perf_25_enemies = {
		id = "perf_25_enemies",
		title = "25-Enemy Perf Test",
		description = "Sandbox + 25 mixed enemies + live Metrics Bar (VS-23)",
		openOverlay = "metrics",
		steps = {
			{ action = "setSandbox", payload = { enabled = true } },
			{ action = "setAiMode", payload = { mode = "normal" } },
			{ action = "killAllEnemies", payload = {} },
			{ action = "spawnEnemy", payload = { kind = "melee", count = 10 } },
			{ action = "spawnEnemy", payload = { kind = "ranged", count = 8 } },
			{ action = "spawnEnemy", payload = { kind = "exploder", count = 4 } },
			{ action = "spawnEnemy", payload = { kind = "grabber", count = 3 } },
		},
	},
	upgrade_queue_test = {
		id = "upgrade_queue_test",
		title = "Upgrade Queue & Replace",
		description = "Fill all 3 ability slots + push 3 queued 1-of-3 offers",
		steps = {
			{ action = "setAbilitySlot", payload = { slot = 1, abilityId = "spin", level = 1 } },
			{ action = "setAbilitySlot", payload = { slot = 2, abilityId = "taunt", level = 1 } },
			{ action = "setAbilitySlot", payload = { slot = 3, abilityId = "stinger", level = 1 } },
			{ action = "pushUpgradeOffer", payload = { count = 3, isStarter = false } },
		},
	},
	clean_reset = {
		id = "clean_reset",
		title = "Clean Reset",
		description = "Disable all cheats & sandbox, reset build, restart Room 1",
		steps = {
			{ action = "setGodMode", payload = { enabled = false } },
			{ action = "setNoCooldowns", payload = { enabled = false } },
			{ action = "setDamageMult", payload = { mult = 1 } },
			{ action = "setSandbox", payload = { enabled = false } },
			{ action = "setAiMode", payload = { mode = "normal" } },
			{ action = "resetBuild", payload = {} },
			{ action = "jumpRoom", payload = { room = 1 } },
			{ action = "adjustHealth", payload = { mode = "full" } },
		},
	},
} :: { [string]: PresetDef }

--=============================================================================
-- Command payload validation
--=============================================================================

function DebugCommands.validate(action: any, payload: any): (boolean, string?)
	if type(action) ~= "string" then
		return false, "action must be a string"
	end
	if type(payload) ~= "table" then
		return false, "payload must be a table"
	end

	-- Phase 1: Run, Room & Wave Controls
	if action == "jumpRoom" then
		if not isIntegerInRange(payload.room, 1, #Config.FLOOR_ROOMS) then
			return false, `room must be 1..{#Config.FLOOR_ROOMS}`
		end
		return true, nil
	elseif action == "clearRoom" or action == "openDoor" or action == "teleportSpawn" or action == "respawnPlayer" then
		return true, nil
	elseif action == "setDifficulty" then
		if not DebugCommands.isValidDifficulty(payload.difficulty) then
			return false, "unknown difficulty"
		end
		return true, nil
	elseif action == "forceRunState" then
		if not inList(DebugCommands.FORCE_STATES, payload.state) then
			return false, "state must be preparing, victory, or defeat"
		end
		return true, nil
	elseif action == "setSandbox" then
		if type(payload.enabled) ~= "boolean" then
			return false, "enabled must be boolean"
		end
		return true, nil

	-- Phase 2: Enemy & Boss Spawner + AI Controls
	elseif action == "spawnEnemy" then
		if not DebugCommands.isValidEnemy(payload.kind, payload.weapon) then
			return false, "unknown enemy kind or weapon variant"
		end
		local count = if payload.count == nil then 1 else payload.count
		if not isIntegerInRange(count, 1, Config.DEBUG_MAX_SPAWN_COUNT) then
			return false, `count must be 1..{Config.DEBUG_MAX_SPAWN_COUNT}`
		end
		if payload.aroundPlayer ~= nil and type(payload.aroundPlayer) ~= "boolean" then
			return false, "aroundPlayer must be boolean"
		end
		return true, nil
	elseif action == "spawnDummy" or action == "killAllEnemies" then
		return true, nil
	elseif action == "setBossHpPercent" then
		if not isFiniteNumber(payload.percent) or payload.percent <= 0 or payload.percent > 1 then
			return false, "percent must be in (0, 1]"
		end
		return true, nil
	elseif action == "setAiMode" then
		if not inList(DebugCommands.AI_MODES, payload.mode) then
			return false, "mode must be normal, noAttack, or frozen"
		end
		return true, nil
	elseif action == "forceSpecial" then
		if payload.move ~= nil and payload.move ~= "" and not inList(DebugCommands.BOSS_OH_MOVES, payload.move) then
			return false, "unknown boss move"
		end
		return true, nil

	-- Phase 3: Build, Upgrades, Drops & Combat Cheats
	elseif action == "setAbilitySlot" then
		if not isIntegerInRange(payload.slot, 1, Config.ABILITY_SLOTS) then
			return false, `slot must be 1..{Config.ABILITY_SLOTS}`
		end
		if not DebugCommands.isValidAbility(payload.abilityId) then
			return false, "unknown abilityId"
		end
		local level = if payload.level == nil then 1 else payload.level
		if not isIntegerInRange(level, 1, Config.ABILITY_MAX_LEVEL) then
			return false, `level must be 1..{Config.ABILITY_MAX_LEVEL}`
		end
		return true, nil
	elseif action == "clearAbilitySlot" then
		if not isIntegerInRange(payload.slot, 1, Config.ABILITY_SLOTS) then
			return false, `slot must be 1..{Config.ABILITY_SLOTS}`
		end
		return true, nil
	elseif action == "pushUpgradeOffer" then
		local count = if payload.count == nil then 1 else payload.count
		if not isIntegerInRange(count, 1, 10) then
			return false, "count must be 1..10"
		end
		if payload.isStarter ~= nil and type(payload.isStarter) ~= "boolean" then
			return false, "isStarter must be boolean"
		end
		return true, nil
	elseif action == "addStatUpgrade" then
		if not DebugCommands.isValidStat(payload.statId) then
			return false, "unknown statId"
		end
		local count = if payload.count == nil then 1 else payload.count
		if not isIntegerInRange(count, 1, 10) then
			return false, "count must be 1..10"
		end
		return true, nil
	elseif action == "setPassive" then
		if not DebugCommands.isValidPassive(payload.passiveId) then
			return false, "unknown passiveId"
		end
		if type(payload.enabled) ~= "boolean" then
			return false, "enabled must be boolean"
		end
		return true, nil
	elseif action == "resetBuild" then
		return true, nil
	elseif action == "spawnDrop" or action == "applyBuff" then
		if not DebugCommands.isValidDrop(payload.kind) then
			return false, "unknown drop kind"
		end
		return true, nil
	elseif action == "setGodMode" or action == "setNoCooldowns" then
		if type(payload.enabled) ~= "boolean" then
			return false, "enabled must be boolean"
		end
		return true, nil
	elseif action == "setDamageMult" then
		if not isFiniteNumber(payload.mult) or payload.mult <= 0 or payload.mult > 1000 then
			return false, "mult must be in (0, 1000]"
		end
		return true, nil
	elseif action == "adjustHealth" then
		if not inList(DebugCommands.HEALTH_MODES, payload.mode) then
			return false, "mode must be full, damage, or set1"
		end
		if payload.mode == "damage" then
			local amount = if payload.amount == nil then 25 else payload.amount
			if not isFiniteNumber(amount) or amount <= 0 or amount > 10000 then
				return false, "damage amount must be in (0, 10000]"
			end
		end
		return true, nil

	-- Phase 4: One-click playtest presets
	elseif action == "runPreset" then
		if type(payload.presetId) ~= "string" or DebugCommands.PRESETS[payload.presetId] == nil then
			return false, "unknown presetId"
		end
		return true, nil
	end

	return false, `unknown action "{action}"`
end

--=============================================================================
-- Immutable ring-buffer helper for client combat log
--=============================================================================

-- Returns a fresh array capped at `maxEntries` without mutating `entries`, keeping Charm's
-- `frozen = true` atom contract satisfied offline and at runtime.
function DebugCommands.appendLog(entries: { LogEntry }, entry: LogEntry, maxEntries: number?): { LogEntry }
	local cap = math.max(1, math.floor(maxEntries or Config.DEBUG_LOG_MAX_ENTRIES))
	local nextList: { LogEntry } = {}
	local startIdx = math.max(1, #entries - (cap - 2))
	for i = startIdx, #entries do
		table.insert(nextList, entries[i])
	end
	table.insert(nextList, entry)
	return nextList
end

--=============================================================================
-- Self test
--=============================================================================

function DebugCommands.selfTest()
	local STUDIO = Config.ENV_STUDIO
	local DEV = Config.ENV_DEVELOPMENT
	local PROD = Config.ENV_PRODUCTION

	-- Security boundary: production is locked by default even for admins; non-admins never pass.
	assert(not Config.DEBUG_ALLOW_IN_PRODUCTION, "DEBUG_ALLOW_IN_PRODUCTION must default to false")
	assert(DebugCommands.canUse(STUDIO, true, false), "Studio admin must be allowed")
	assert(not DebugCommands.canUse(STUDIO, false, false), "Studio non-admin must be denied")
	assert(DebugCommands.canUse(DEV, true, false), "Dev admin must be allowed")
	assert(not DebugCommands.canUse(DEV, false, false), "Dev non-admin must be denied")
	assert(not DebugCommands.canUse(PROD, true, false), "Prod admin must be denied while kill switch is off")
	assert(not DebugCommands.canUse(PROD, false, true), "Prod non-admin must be denied even if allowInProd is true")
	assert(DebugCommands.canUse(PROD, true, true), "Prod admin allowed only when explicitly opted in")

	-- Enemy catalog must cover every current weapon variant + standalone kind.
	local catalog = DebugCommands.enemyCatalog()
	assert(#catalog >= 11, `expected at least 11 catalog entries, got {#catalog}`)
	assert(DebugCommands.isValidEnemy("melee", "sword"), "melee:sword must be valid")
	assert(DebugCommands.isValidEnemy("melee", "axe"), "melee:axe must be valid")
	assert(DebugCommands.isValidEnemy("ranged", "plasma"), "ranged:plasma must be valid")
	assert(DebugCommands.isValidEnemy("ranged", "minigun"), "ranged:minigun must be valid")
	assert(DebugCommands.isValidEnemy("bossOh", nil), "bossOh must be valid")
	assert(not DebugCommands.isValidEnemy("melee", "minigun"), "cross-kind weapon must fail")
	assert(not DebugCommands.isValidEnemy("nonexistent", nil), "unknown enemy kind must fail")

	-- Command validation happy & reject cases.
	local ok = DebugCommands.validate("jumpRoom", { room = 5 })
	assert(ok, "jumpRoom(5) must pass")
	assert(not DebugCommands.validate("jumpRoom", { room = 0 }), "room 0 must fail")
	assert(not DebugCommands.validate("jumpRoom", { room = 99 }), "room 99 must fail")
	assert(not DebugCommands.validate("jumpRoom", { room = 0 / 0 }), "NaN room must fail")
	assert(DebugCommands.validate("setDifficulty", { difficulty = "deadzone" }), "deadzone must pass")
	assert(not DebugCommands.validate("setDifficulty", { difficulty = "impossible" }), "unknown difficulty must fail")
	assert(DebugCommands.validate("spawnEnemy", { kind = "ranged", weapon = "minigun", count = 5 }), "spawnEnemy must pass")
	assert(not DebugCommands.validate("spawnEnemy", { kind = "ranged", count = 999 }), "over-cap count must fail")
	assert(DebugCommands.validate("setAbilitySlot", { slot = 3, abilityId = "overdrive", level = 3 }), "setAbilitySlot must pass")
	assert(not DebugCommands.validate("setAbilitySlot", { slot = 4, abilityId = "overdrive", level = 1 }), "slot 4 must fail")
	assert(not DebugCommands.validate("setBossHpPercent", { percent = 0 }), "0% boss HP must fail")
	assert(DebugCommands.validate("setBossHpPercent", { percent = 0.5 }), "50% boss HP must pass")
	assert(DebugCommands.validate("adjustHealth", { mode = "damage", amount = 25 }), "damage 25 must pass")
	assert(not DebugCommands.validate("adjustHealth", { mode = "damage", amount = -5 }), "negative damage must fail")
	assert(not DebugCommands.validate("unknownCommand", {}), "unknown command must fail")

	-- Every preset must exist in PRESET_ORDER and every step inside every preset must validate.
	for _, presetId in ipairs(DebugCommands.PRESET_ORDER) do
		local preset = DebugCommands.PRESETS[presetId]
		assert(preset ~= nil, `PRESET_ORDER names missing preset "{presetId}"`)
		assert(DebugCommands.validate("runPreset", { presetId = presetId }), `runPreset({presetId}) must validate`)
		assert(#preset.steps > 0, `preset "{presetId}" must have at least one step`)
		for idx, step in ipairs(preset.steps) do
			local stepOk, reason = DebugCommands.validate(step.action, step.payload)
			assert(stepOk, `preset "{presetId}" step {idx} ({step.action}) failed validation: {tostring(reason)}`)
		end
	end

	-- Immutable capped log helper.
	local log0: { LogEntry } = {}
	local log1 = DebugCommands.appendLog(log0, { seq = 1, tag = "HIT", text = "a", kind = "hit" }, 2)
	local log2 = DebugCommands.appendLog(log1, { seq = 2, tag = "HIT", text = "b", kind = "hit" }, 2)
	local log3 = DebugCommands.appendLog(log2, { seq = 3, tag = "PARRY", text = "c", kind = "parry" }, 2)
	assert(#log0 == 0 and #log1 == 1 and #log2 == 2 and #log3 == 2, "appendLog must not mutate prior snapshots and must cap")
	assert(log3[1].seq == 2 and log3[2].seq == 3, "appendLog must retain newest entries")
end

return DebugCommands
