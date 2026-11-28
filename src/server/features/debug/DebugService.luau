--[[
	Server-side admin dev/debug command dispatcher (Phase 0 foundation).

	Security is enforced at two independent boundaries:
	  1. `Contract.AdminCommand` (`admin = true`), checked by `Dispatcher` before this runs.
	  2. `DebugCommands.canUse(Environment.name(), isAdmin(player), Config.DEBUG_ALLOW_IN_PRODUCTION)`,
	     keeping production zero-footprint even for staff unless explicitly opted in.

	Gameplay services are injected through `start(deps)` from `Bootstrap.server.luau` so no
	gameplay feature ever requires `debug`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Environment = require(Shared.core.Environment)
local Remotes = require(Shared.core.Net.Remotes)
local DebugCommands = require(Shared.features.debug.DebugCommands)
local Waves = require(Shared.features.enemies.Waves)

local DebugService = {}

export type CommandHandler = (Player, { [string]: any }) -> (boolean, string?)

export type Dependencies = {
	world: Instance,
	runService: any,
	waveDirector: any,
	enemyService: any,
	combatService: any,
	upgradeService: any,
	dropService: any,
	isAdmin: (Player) -> boolean,
	record: ((string, string, string, { [string]: any }?, number?) -> ())?,
}

local deps: Dependencies? = nil
local handlers: { [string]: CommandHandler } = {}
local adminPlayers: { [Player]: boolean } = {}
local logSeq = 0

local function canPlayerUse(player: Player): boolean
	if not deps then
		return false
	end
	return DebugCommands.canUse(
		Environment.name(),
		deps.isAdmin(player),
		Config.DEBUG_ALLOW_IN_PRODUCTION
	)
end

local function syncAdminAttribute(player: Player)
	local allowed = canPlayerUse(player)
	adminPlayers[player] = if allowed then true else nil
	player:SetAttribute("IsAdmin", allowed)
end

-- Registers or replaces an action handler (used by Phases 1–4 as each subsystem plugs in).
function DebugService.register(action: string, handler: CommandHandler)
	handlers[action] = handler
end

-- Pushes a structured combat-math or debug log line to every connected admin client.
function DebugService.emitCombatLog(
	tag: string,
	text: string,
	kind: ("info" | "hit" | "hurt" | "parry" | "warn")?,
	targetPlayer: Player?
)
	if Environment.isProduction() and not Config.DEBUG_ALLOW_IN_PRODUCTION then
		return
	end
	logSeq += 1
	local entry = {
		seq = logSeq,
		tag = tag,
		text = text,
		kind = kind or "info",
	}
	if targetPlayer then
		if adminPlayers[targetPlayer] then
			Remotes.DebugEvent:FireClient(targetPlayer, "combatLog", entry)
		end
		return
	end
	for player in pairs(adminPlayers) do
		if player.Parent then
			Remotes.DebugEvent:FireClient(player, "combatLog", entry)
		end
	end
end

-- Executes a single validated command (also called internally by `runPreset` steps).
function DebugService.execute(player: Player, action: string, payload: { [string]: any }): (boolean, string?)
	local valid, reason = DebugCommands.validate(action, payload)
	if not valid then
		return false, reason or "invalid payload"
	end

	local handler = handlers[action]
	if not handler then
		return false, `action "{action}" is not wired yet`
	end

	local ok, resultOrErr, message = pcall(handler, player, payload)
	if not ok then
		warn(`[DebugService] handler "{action}" errored: {resultOrErr}`)
		if deps and deps.record then
			deps.record("debug", "handler-error", tostring(resultOrErr), {
				action = action,
				player = player.Name,
			})
		end
		return false, "internal error"
	end
	return resultOrErr == true, message
end

-- Remote "AdminCommand(action, payload)". Connected through Dispatcher (`admin = true`).
function DebugService.onCommand(player: Player, action: string, payload: { [string]: any })
	if not canPlayerUse(player) then
		return
	end

	local ok, message = DebugService.execute(player, action, payload)
	if deps and deps.record then
		deps.record("debug", if ok then "admin-command" else "admin-command-rejected", action, {
			player = player.Name,
			userId = player.UserId,
			ok = ok,
			message = message or "",
		})
	end
	Remotes.DebugEvent:FireClient(player, "commandResult", {
		action = action,
		ok = ok,
		message = message,
	})
end

function DebugService.forget(player: Player)
	adminPlayers[player] = nil
end

function DebugService.start(dependencies: Dependencies)
	deps = dependencies

	-- Phase 1: Run, Room & Wave Controls.
	DebugService.register("jumpRoom", function(_player, payload)
		return dependencies.runService.debugJumpRoom(payload.room)
	end)
	DebugService.register("clearRoom", function()
		return dependencies.runService.debugClearRoom()
	end)
	DebugService.register("openDoor", function()
		return dependencies.runService.debugOpenDoor()
	end)
	DebugService.register("setDifficulty", function(_player, payload)
		return dependencies.runService.debugSetDifficulty(payload.difficulty)
	end)
	DebugService.register("forceRunState", function(_player, payload)
		return dependencies.runService.debugForceState(payload.state)
	end)
	DebugService.register("setSandbox", function(_player, payload)
		return dependencies.runService.debugSetSandbox(payload.enabled)
	end)
	DebugService.register("teleportSpawn", function(player)
		return dependencies.runService.debugTeleportToSpawn(player)
	end)
	DebugService.register("respawnPlayer", function(player)
		return dependencies.runService.debugRespawnPlayer(player)
	end)

	-- Phase 2: Enemy & Boss Spawner + AI Controls.
	local function playerForwardPos(player: Player, dist: number): Vector3
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			local dir = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
			return root.Position + dir * dist
		end
		return Vector3.new(0, 0, -dist)
	end

	DebugService.register("spawnEnemy", function(player, payload)
		-- If spawning while on the start screen, enter Sandbox automatically so enemies & combat run.
		if dependencies.world:GetAttribute("RunState") == "preparing" then
			dependencies.runService.debugSetSandbox(true)
		end
		local kind: string = payload.kind
		local weapon: string? = payload.weapon
		local count = math.clamp(math.floor(payload.count or 1), 1, Config.DEBUG_MAX_SPAWN_COUNT)
		local diffId = dependencies.runService.getDifficulty()
		local aroundPlayer = payload.aroundPlayer == true or count <= 3
		local spawned = 0

		for i = 1, count do
			local rawPos: Vector3
			if kind == "bossOh" and count == 1 and not payload.aroundPlayer then
				rawPos = Vector3.new(0, 0, -(Config.ROOM_SIZE.Y / 2 - 18))
			elseif aroundPlayer then
				local basePos = playerForwardPos(player, 18)
				local spreadAngle = if count > 1 then ((i - 1) / count) * math.pi * 2 else 0
				local radius = if count > 1 then 7 else 0
				rawPos = basePos + Vector3.new(math.cos(spreadAngle) * radius, 0, math.sin(spreadAngle) * radius)
			else
				rawPos = Waves.spawnPoint(i, count, Config.ROOM_SIZE, 13, 0)
			end
			local clamped = Waves.clamp(rawPos, Config.ROOM_SIZE, 6)
			local safePos = Waves.avoidObstacles(clamped, 3.5, Config.ARENA_PILLARS)
			if dependencies.enemyService.spawn(kind, safePos, diffId, { weapon = weapon }) then
				spawned += 1
			end
		end
		local label = if weapon and weapon ~= "" then `{kind}:{weapon}` else kind
		return spawned > 0, `Spawned {spawned}x {label}`
	end)

	DebugService.register("spawnDummy", function(player)
		if dependencies.world:GetAttribute("RunState") == "preparing" then
			dependencies.runService.debugSetSandbox(true)
		end
		return dependencies.enemyService.debugSpawnDummy(playerForwardPos(player, 12))
	end)
	DebugService.register("killAllEnemies", function()
		return dependencies.enemyService.debugKillAll()
	end)
	DebugService.register("setBossHpPercent", function(_player, payload)
		return dependencies.enemyService.debugSetBossHpPercent(payload.percent)
	end)
	DebugService.register("setAiMode", function(_player, payload)
		return dependencies.enemyService.debugSetAiMode(payload.mode)
	end)
	DebugService.register("forceSpecial", function(player, payload)
		local pos = playerForwardPos(player, 0)
		return dependencies.enemyService.debugForceSpecial(pos, payload.move)
	end)

	-- Phase 3: Build Editor, Upgrades, Drops & Player Combat Cheats.
	if dependencies.combatService and dependencies.combatService.setDebugLogHook then
		dependencies.combatService.setDebugLogHook(DebugService.emitCombatLog)
	end

	DebugService.register("setAbilitySlot", function(player, payload)
		return dependencies.upgradeService.debugSetSlot(player, payload.slot, payload.abilityId, payload.level)
	end)
	DebugService.register("clearAbilitySlot", function(player, payload)
		return dependencies.upgradeService.debugClearSlot(player, payload.slot)
	end)
	DebugService.register("pushUpgradeOffer", function(player, payload)
		return dependencies.upgradeService.debugPushOffer(player, payload.count, payload.isStarter)
	end)
	DebugService.register("addStatUpgrade", function(player, payload)
		return dependencies.upgradeService.debugApplyStat(player, payload.statId, payload.count)
	end)
	DebugService.register("setPassive", function(player, payload)
		return dependencies.upgradeService.debugSetPassive(player, payload.passiveId, payload.enabled)
	end)
	DebugService.register("resetBuild", function(player)
		return dependencies.upgradeService.debugResetBuild(player)
	end)
	DebugService.register("spawnDrop", function(player, payload)
		local spawned = dependencies.dropService.spawn(payload.kind, playerForwardPos(player, 6))
		if not spawned then
			return false, `missing drop model "{payload.kind}"`
		end
		return true, `Spawned {payload.kind} drop`
	end)
	DebugService.register("applyBuff", function(player, payload)
		local applied = dependencies.combatService.applyDrop(player, payload.kind)
		if not applied and payload.kind == "heal" then
			return true, "Already at full HP"
		end
		return applied, `Applied {payload.kind} buff`
	end)
	DebugService.register("setGodMode", function(player, payload)
		return dependencies.combatService.debugSetGodMode(player, payload.enabled)
	end)
	DebugService.register("setNoCooldowns", function(player, payload)
		return dependencies.combatService.debugSetNoCooldowns(player, payload.enabled)
	end)
	DebugService.register("setDamageMult", function(player, payload)
		return dependencies.combatService.debugSetDamageMult(player, payload.mult)
	end)
	DebugService.register("adjustHealth", function(player, payload)
		return dependencies.combatService.debugAdjustHealth(player, payload.mode, payload.amount)
	end)

	-- Phase 4: Built-in preset runner: executes every step of a validated preset in order.
	DebugService.register("runPreset", function(player: Player, payload: { [string]: any })
		local preset = DebugCommands.PRESETS[payload.presetId]
		if not preset then
			return false, "unknown preset"
		end
		for idx, step in ipairs(preset.steps) do
			local stepOk, stepMsg = DebugService.execute(player, step.action, step.payload)
			if not stepOk then
				return false, `preset step {idx} ({step.action}) failed: {tostring(stepMsg)}`
			end
		end
		if preset.openOverlay then
			Remotes.DebugEvent:FireClient(player, "openOverlay", { overlay = preset.openOverlay })
		end
		return true, `Preset "{preset.title}" applied`
	end)

	Players.PlayerAdded:Connect(syncAdminAttribute)
	for _, player in ipairs(Players:GetPlayers()) do
		syncAdminAttribute(player)
	end
end

return DebugService
