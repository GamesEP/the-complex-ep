--!strict
--[[
	Client-owned reactive store for the in-game Dev Panel and client debug overlays.

	Pure Luau Charm atoms — no Roblox services or remotes — so `make test ONLY=ui` exercises
	panel state, tab navigation, overlay toggles, immutable log ring-buffering, and resets offline.
	Every table stored in an atom is replaced with a fresh copy rather than mutated in place to
	satisfy Charm's `frozen = true` check in the test runner.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage:WaitForChild("Packages").charm)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local DebugCommands = require(Shared.features.debug.DebugCommands)

local DebugStore = {}

export type OverlayFlags = {
	metrics: boolean,
	combatLog: boolean,
	enemyInspector: boolean,
	hitboxes: boolean,
}

export type OverlayName = "metrics" | "combatLog" | "enemyInspector" | "hitboxes"

export type HitboxLayers = {
	playerAim: boolean,
	attackHitbox: boolean,
	enemyReach: boolean,
	pillars: boolean,
	doorZone: boolean,
}

export type HitboxLayerName = "playerAim" | "attackHitbox" | "enemyReach" | "pillars" | "doorZone"

export type CommandStatus = {
	action: string,
	ok: boolean,
	message: string?,
}

local function defaultOverlays(): OverlayFlags
	return {
		metrics = false,
		combatLog = false,
		enemyInspector = false,
		hitboxes = false,
	}
end

local function defaultHitboxLayers(): HitboxLayers
	return {
		playerAim = true,
		attackHitbox = true,
		enemyReach = true,
		pillars = true,
		doorZone = true,
	}
end

DebugStore.isOpen = Charm.atom(false)
DebugStore.activeTab = Charm.atom("run" :: DebugCommands.DebugTab)
DebugStore.quickBarVisible = Charm.atom(false)
DebugStore.overlays = Charm.atom(defaultOverlays())
DebugStore.hitboxLayers = Charm.atom(defaultHitboxLayers())
DebugStore.themeOverride = Charm.atom(nil :: string?)
DebugStore.tonemapperOverride = Charm.atom(nil :: string?)
DebugStore.combatLog = Charm.atom({} :: { DebugCommands.LogEntry })
DebugStore.lastCommandStatus = Charm.atom(nil :: CommandStatus?)

function DebugStore.setOpen(open: boolean)
	DebugStore.isOpen(open == true)
end

function DebugStore.toggleOpen()
	DebugStore.isOpen(not DebugStore.isOpen())
end

function DebugStore.setTab(tab: string): boolean
	if not DebugCommands.isValidTab(tab) then
		return false
	end
	DebugStore.activeTab(tab :: DebugCommands.DebugTab)
	return true
end

function DebugStore.setQuickBarVisible(visible: boolean)
	DebugStore.quickBarVisible(visible == true)
end

function DebugStore.toggleQuickBar()
	DebugStore.quickBarVisible(not DebugStore.quickBarVisible())
end

function DebugStore.setOverlay(name: OverlayName, enabled: boolean): boolean
	local cur = DebugStore.overlays()
	if (cur :: any)[name] == nil then
		return false
	end
	local copy = table.clone(cur)
	;(copy :: any)[name] = enabled == true
	DebugStore.overlays(copy)
	return true
end

function DebugStore.toggleOverlay(name: OverlayName): boolean
	local cur = DebugStore.overlays()
	local currentVal = (cur :: any)[name]
	if currentVal == nil then
		return false
	end
	return DebugStore.setOverlay(name, not currentVal)
end

function DebugStore.setHitboxLayer(layer: HitboxLayerName, enabled: boolean): boolean
	local cur = DebugStore.hitboxLayers()
	if (cur :: any)[layer] == nil then
		return false
	end
	local copy = table.clone(cur)
	;(copy :: any)[layer] = enabled == true
	DebugStore.hitboxLayers(copy)
	return true
end

function DebugStore.toggleHitboxLayer(layer: HitboxLayerName): boolean
	local cur = DebugStore.hitboxLayers()
	local currentVal = (cur :: any)[layer]
	if currentVal == nil then
		return false
	end
	return DebugStore.setHitboxLayer(layer, not currentVal)
end

function DebugStore.setAllHitboxLayers(enabled: boolean)
	local on = enabled == true
	DebugStore.hitboxLayers({
		playerAim = on,
		attackHitbox = on,
		enemyReach = on,
		pillars = on,
		doorZone = on,
	})
end

function DebugStore.setThemeOverride(themeKey: string?)
	if themeKey == "" or themeKey == "auto" then
		DebugStore.themeOverride(nil)
	else
		DebugStore.themeOverride(themeKey)
	end
end

function DebugStore.setTonemapperOverride(presetId: string?)
	if presetId == "" or presetId == "auto" then
		DebugStore.tonemapperOverride(nil)
	else
		DebugStore.tonemapperOverride(presetId)
	end
end

function DebugStore.pushLog(entry: DebugCommands.LogEntry)
	local nextLog = DebugCommands.appendLog(
		DebugStore.combatLog(),
		entry,
		Config.DEBUG_LOG_MAX_ENTRIES
	)
	DebugStore.combatLog(nextLog)
end

function DebugStore.clearLog()
	DebugStore.combatLog({})
end

function DebugStore.setCommandStatus(status: CommandStatus?)
	if not status then
		DebugStore.lastCommandStatus(nil)
		return
	end
	DebugStore.lastCommandStatus({
		action = status.action,
		ok = status.ok == true,
		message = status.message,
	})
end

function DebugStore.reset()
	DebugStore.isOpen(false)
	DebugStore.activeTab("run")
	DebugStore.quickBarVisible(false)
	DebugStore.overlays(defaultOverlays())
	DebugStore.hitboxLayers(defaultHitboxLayers())
	DebugStore.themeOverride(nil)
	DebugStore.tonemapperOverride(nil)
	DebugStore.combatLog({})
	DebugStore.lastCommandStatus(nil)
end

function DebugStore.selfTest()
	DebugStore.reset()

	-- Panel open/close & tab validation.
	assert(not DebugStore.isOpen(), "panel starts closed")
	DebugStore.toggleOpen()
	assert(DebugStore.isOpen(), "toggleOpen opens panel")
	assert(DebugStore.setTab("enemies"), "valid tab must succeed")
	assert(DebugStore.activeTab() == "enemies", "activeTab must update")
	assert(not DebugStore.setTab("bogus"), "invalid tab must be rejected")
	assert(DebugStore.activeTab() == "enemies", "rejected tab must leave activeTab unchanged")

	-- Quick bar & overlay toggles (preserving immutability of prior snapshots).
	DebugStore.toggleQuickBar()
	assert(DebugStore.quickBarVisible(), "quickBarVisible must toggle on")
	local before = DebugStore.overlays()
	assert(DebugStore.toggleOverlay("metrics"), "toggleOverlay(metrics) must succeed")
	assert(DebugStore.overlays().metrics == true, "metrics overlay must be true")
	assert(before.metrics == false, "previous overlay snapshot must remain untouched")
	assert(not DebugStore.setOverlay("unknown" :: any, true), "unknown overlay must fail")

	-- Per-layer hitbox toggles preserve immutability and reject unknown layer names.
	local layersBefore = DebugStore.hitboxLayers()
	assert(
		layersBefore.playerAim
			and layersBefore.attackHitbox
			and layersBefore.enemyReach
			and layersBefore.pillars
			and layersBefore.doorZone,
		"all hitbox layers default on"
	)
	assert(DebugStore.toggleHitboxLayer("pillars"), "toggleHitboxLayer(pillars) must succeed")
	assert(DebugStore.hitboxLayers().pillars == false, "pillars layer must toggle off")
	assert(layersBefore.pillars == true, "previous hitboxLayers snapshot must remain untouched")
	assert(not DebugStore.setHitboxLayer("unknown" :: any, false), "unknown hitbox layer must fail")
	DebugStore.setAllHitboxLayers(false)
	assert(not DebugStore.hitboxLayers().playerAim and not DebugStore.hitboxLayers().doorZone, "setAllHitboxLayers(false) disables all")

	-- Theme / tonemapper override normalization.
	DebugStore.setThemeOverride("boss_room")
	assert(DebugStore.themeOverride() == "boss_room", "themeOverride must store key")
	DebugStore.setThemeOverride("auto")
	assert(DebugStore.themeOverride() == nil, "auto clears themeOverride")

	-- Combat log ring buffer capping.
	local cap = Config.DEBUG_LOG_MAX_ENTRIES
	for i = 1, cap + 5 do
		DebugStore.pushLog({ seq = i, tag = "HIT", text = `hit {i}`, kind = "hit" })
	end
	local entries = DebugStore.combatLog()
	assert(#entries == cap, `combatLog must cap at {cap}, got {#entries}`)
	assert(entries[1].seq == 6 and entries[#entries].seq == cap + 5, "combatLog must keep newest entries")

	-- Command status & full reset.
	DebugStore.setCommandStatus({ action = "jumpRoom", ok = true, message = "Room 5" })
	local st = DebugStore.lastCommandStatus()
	assert(st ~= nil and st.action == "jumpRoom" and st.ok, "commandStatus must record latest result")

	DebugStore.reset()
	assert(not DebugStore.isOpen(), "reset closes panel")
	assert(DebugStore.activeTab() == "run", "reset restores default tab")
	assert(not DebugStore.overlays().metrics, "reset clears overlays")
	assert(DebugStore.hitboxLayers().playerAim and DebugStore.hitboxLayers().pillars, "reset restores default hitbox layers")
	assert(#DebugStore.combatLog() == 0, "reset clears combatLog")
	assert(DebugStore.lastCommandStatus() == nil, "reset clears commandStatus")
end

return DebugStore
