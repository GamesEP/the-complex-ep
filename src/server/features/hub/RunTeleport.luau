--!strict
--[[
	Multi-place & Private Run Server teleportation (`plans/gdd/technical.md`, `plans/roadmap.md HS-27`).

	Determines whether the current server is running as the isolated Hub (`"hub"`) or a private Run
	server (`"run"`). In published multi-place universes (`RUN_PLACE_ID > 0`), `launchParty` reserves
	a private server with `TeleportService:ReserveServer` and teleports the 1-4 player squad together
	with `{ partyId, difficulty, leaderId, memberIds }`. In Studio or single-place local testing
	(`RUN_PLACE_ID == 0`), seamlessly falls back to local Hub -> Run -> Hub transitions in the same
	server so developers can test the full loop without live TeleportService failures.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunServiceEngine = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Environment = require(Shared.core.Environment)

local RunTeleport = {}

export type ServerMode = "hub" | "run"

export type LaunchPayload = {
	partyId: string?,
	leaderId: number,
	difficulty: string,
	members: { number },
}

local onTeleportFailed: ((Player, string, string) -> ())? = nil
local recordLog: ((string, string, { [string]: any }?) -> ())? = nil
local activeTeleports: { [number]: { partyId: string?, leaderId: number } } = {}
local lastAttemptAt: { [number]: number } = {}
local initialized = false

function RunTeleport.resolveServerMode(
	placeId: number,
	privateServerId: string,
	hubPlaceId: number,
	runPlaceId: number,
	isStudio: boolean
): ServerMode
	if runPlaceId > 0 and placeId == runPlaceId then
		return "run"
	end
	if privateServerId ~= "" and (hubPlaceId == 0 or placeId ~= hubPlaceId) then
		return "run"
	end
	if hubPlaceId > 0 and placeId == hubPlaceId then
		return "hub"
	end
	if isStudio then
		return if Config.STUDIO_START_IN_HUB then "hub" else "run"
	end
	return "hub"
end

function RunTeleport.currentServerMode(): ServerMode
	local hubPlaceId = Environment.id("HUB_PLACE_ID")
	local runPlaceId = Environment.id("RUN_PLACE_ID")
	return RunTeleport.resolveServerMode(
		game.PlaceId,
		game.PrivateServerId,
		hubPlaceId,
		runPlaceId,
		RunServiceEngine:IsStudio()
	)
end

function RunTeleport.isMultiPlaceLive(): boolean
	if RunServiceEngine:IsStudio() then
		return false
	end
	local runPlaceId = Environment.id("RUN_PLACE_ID")
	return runPlaceId > 0 and runPlaceId ~= game.PlaceId
end

function RunTeleport.extractTeleportDifficulty(player: Player): string?
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local tdata = joinData.TeleportData
	if type(tdata) == "table" and type(tdata.difficulty) == "string" then
		return tdata.difficulty
	end
	return nil
end

function RunTeleport.start(deps: {
	onTeleportFailed: ((Player, string, string) -> ())?,
	record: ((string, string, { [string]: any }?) -> ())?,
})
	onTeleportFailed = deps.onTeleportFailed
	recordLog = deps.record
	if initialized then
		return
	end
	initialized = true

	TeleportService.TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult, errorMessage: string)
		local meta = activeTeleports[player.UserId]
		activeTeleports[player.UserId] = nil
		if recordLog then
			recordLog("teleport", "TeleportInitFailed", {
				userId = player.UserId,
				result = tostring(result),
				message = errorMessage,
				partyId = if meta then meta.partyId else nil,
			})
		end
		if onTeleportFailed then
			onTeleportFailed(player, tostring(result), errorMessage)
		end
	end)
end

-- Launches `members` into a private Run server (or local Studio fallback via `onLocalFallback`).
function RunTeleport.launchParty(
	payload: LaunchPayload,
	onLocalFallback: (LaunchPayload, { Player }) -> ()
): (boolean, string?)
	local playerList: { Player } = {}
	for _, userId in ipairs(payload.members) do
		local p = Players:GetPlayerByUserId(userId)
		if p then
			table.insert(playerList, p)
		end
	end
	if #playerList == 0 then
		return false, "no_players"
	end

	-- Studio or single-place fallback: transition locally in the same server immediately.
	if not RunTeleport.isMultiPlaceLive() then
		onLocalFallback(payload, playerList)
		return true, "local"
	end

	local nowT = os.clock()
	local prev = lastAttemptAt[payload.leaderId] or 0
	if nowT - prev < Config.TELEPORT_RETRY_COOLDOWN then
		return false, "teleport_cooldown"
	end
	lastAttemptAt[payload.leaderId] = nowT

	local runPlaceId = Environment.id("RUN_PLACE_ID")
	local okReserve, accessCodeOrErr = pcall(function()
		return TeleportService:ReserveServer(runPlaceId)
	end)
	if not okReserve or type(accessCodeOrErr) ~= "string" then
		if recordLog then
			recordLog("teleport", "ReserveServerFailed", {
				runPlaceId = runPlaceId,
				error = tostring(accessCodeOrErr),
				partyId = payload.partyId,
			})
		end
		return false, "reserve_failed"
	end

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCodeOrErr
	options:SetTeleportData({
		partyId = payload.partyId,
		leaderId = payload.leaderId,
		difficulty = payload.difficulty,
		memberIds = payload.members,
	})

	for _, p in ipairs(playerList) do
		activeTeleports[p.UserId] = { partyId = payload.partyId, leaderId = payload.leaderId }
	end

	local okTp, tpErr = pcall(function()
		TeleportService:TeleportAsync(runPlaceId, playerList, options)
	end)
	if not okTp then
		for _, p in ipairs(playerList) do
			activeTeleports[p.UserId] = nil
		end
		if recordLog then
			recordLog("teleport", "TeleportAsyncFailed", {
				runPlaceId = runPlaceId,
				error = tostring(tpErr),
				partyId = payload.partyId,
			})
		end
		return false, "teleport_failed"
	end
	return true, "reserved"
end

function RunTeleport.returnToHub(player: Player, onLocalFallback: (Player) -> ()): boolean
	local hubPlaceId = Environment.id("HUB_PLACE_ID")
	if RunServiceEngine:IsStudio() or hubPlaceId <= 0 or hubPlaceId == game.PlaceId then
		onLocalFallback(player)
		return true
	end
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(hubPlaceId, { player })
	end)
	if not ok and recordLog then
		recordLog("teleport", "ReturnToHubFailed", {
			userId = player.UserId,
			hubPlaceId = hubPlaceId,
			error = tostring(err),
		})
	end
	return ok
end

function RunTeleport.forget(player: Player)
	activeTeleports[player.UserId] = nil
	lastAttemptAt[player.UserId] = nil
end

return RunTeleport
