--!strict
--[[
	Server-authoritative Hub Party service (`plans/gdd/systems.md`, `plans/roadmap.md HS-25`).

	Owns `PartyRules` state and publishes each player's party membership cleanly onto `Player`
	attributes (`PartyId`, `PartyRole`, `PartyPrivacy`, `PartyDifficulty`, `PartyLocked`,
	`PartyOrder`) so every client in the Hub sees live open parties and their own squad roster
	without custom replication boilerplate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Difficulty = require(Shared.features.enemies.Difficulty)
local PartyRules = require(Shared.features.party.PartyRules)
local Remotes = require(Shared.core.Net.Remotes)

local PartyService = {}

local state: PartyRules.State = PartyRules.new()
local soloDifficulty: { [Player]: string } = {}
local isHubMode: (() -> boolean)? = nil
local onLaunchRequest: ((PartyRules.LaunchPayload) -> (boolean, string?))? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function notify(player: Player, kind: string, payload: { [string]: any })
	if player.Parent then
		Remotes.PartyEvent:FireClient(player, kind, payload)
	end
end

local function syncPlayerAttributes(player: Player)
	local party = PartyRules.getPlayerParty(state, player.UserId)
	if not party then
		player:SetAttribute("PartyId", "")
		player:SetAttribute("PartyRole", "")
		player:SetAttribute("PartyPrivacy", "")
		player:SetAttribute("PartyDifficulty", soloDifficulty[player] or Config.DEFAULT_DIFFICULTY)
		player:SetAttribute("PartyLocked", false)
		player:SetAttribute("PartyOrder", 0)
		return
	end
	local order = table.find(party.members, player.UserId) or 1
	player:SetAttribute("PartyId", party.id)
	player:SetAttribute("PartyRole", if party.leaderId == player.UserId then "leader" else "member")
	player:SetAttribute("PartyPrivacy", party.privacy)
	player:SetAttribute("PartyDifficulty", party.difficulty)
	player:SetAttribute("PartyLocked", party.locked)
	player:SetAttribute("PartyOrder", order)
end

local function syncAllPlayers()
	for _, player in ipairs(Players:GetPlayers()) do
		syncPlayerAttributes(player)
	end
end

local function canEditInHub(): boolean
	return isHubMode == nil or isHubMode()
end

function PartyService.getDifficultyFor(player: Player): string
	local party = PartyRules.getPlayerParty(state, player.UserId)
	if party then
		return party.difficulty
	end
	return soloDifficulty[player] or Config.DEFAULT_DIFFICULTY
end

function PartyService.setDifficulty(player: Player, diffId: string): boolean
	if not Difficulty.isValid(diffId) then
		return false
	end
	local party = PartyRules.getPlayerParty(state, player.UserId)
	if not party then
		soloDifficulty[player] = diffId
		syncPlayerAttributes(player)
		return true
	end
	local ok, err = PartyRules.setDifficulty(state, player.UserId, diffId)
	if not ok then
		notify(player, "notice", { tone = "warn", text = if err == "not_leader" then "Solo el líder puede cambiar la dificultad." else "No se pudo cambiar la dificultad." })
		return false
	end
	syncAllPlayers()
	return true
end

function PartyService.createParty(player: Player, privacy: string)
	if not canEditInHub() then
		return
	end
	local resolvedPrivacy = if PartyRules.isValidPrivacy(privacy) then privacy else "open"
	local party, err = PartyRules.createParty(state, player.UserId, resolvedPrivacy, soloDifficulty[player] or Config.DEFAULT_DIFFICULTY)
	if not party then
		notify(player, "notice", { tone = "warn", text = if err == "party_locked" then "El grupo está iniciando una run." else "No se pudo crear el grupo." })
		return
	end
	syncAllPlayers()
end

function PartyService.setPartyPrivacy(player: Player, privacy: string)
	if not canEditInHub() then
		return
	end
	local ok, err = PartyRules.setPrivacy(state, player.UserId, privacy)
	if not ok then
		if err == "not_in_party" then
			PartyService.createParty(player, privacy)
			return
		end
		notify(player, "notice", { tone = "warn", text = if err == "not_leader" then "Solo el líder puede cambiar la privacidad." else "No se pudo actualizar el grupo." })
		return
	end
	syncAllPlayers()
end

function PartyService.joinParty(player: Player, partyId: string)
	if not canEditInHub() then
		return
	end
	local ok, err = PartyRules.joinOpen(state, player.UserId, partyId)
	if not ok then
		local text = "No se pudo unir al grupo."
		if err == "party_full" then
			text = "El grupo ya está completo (4/4)."
		elseif err == "party_private" then
			text = "Ese grupo es privado (requiere invitación)."
		elseif err == "party_locked" then
			text = "Ese grupo ya está entrando en una run."
		end
		notify(player, "notice", { tone = "warn", text = text })
		return
	end
	syncAllPlayers()
end

function PartyService.invitePlayer(player: Player, targetUserId: number)
	if not canEditInHub() then
		return
	end
	local target = Players:GetPlayerByUserId(math.floor(targetUserId))
	if not target then
		notify(player, "notice", { tone = "warn", text = "Ese jugador ya no está en el Hub." })
		return
	end
	-- Auto-create a private party when a solo player invites someone so inviting is 1 click.
	if not PartyRules.getPlayerParty(state, player.UserId) then
		PartyRules.createParty(state, player.UserId, "private", soloDifficulty[player] or Config.DEFAULT_DIFFICULTY)
	end
	local invite, err = PartyRules.invite(state, player.UserId, target.UserId, now())
	if not invite then
		local text = "No se pudo enviar la invitación."
		if err == "not_leader" then
			text = "Solo el líder puede invitar jugadores."
		elseif err == "party_full" then
			text = "Tu grupo ya está lleno (4/4)."
		elseif err == "already_in_party" then
			text = "Ese jugador ya está en tu grupo."
		end
		notify(player, "notice", { tone = "warn", text = text })
		return
	end
	syncAllPlayers()
	notify(target, "invite", {
		partyId = invite.partyId,
		fromUserId = player.UserId,
		fromName = player.DisplayName,
		expiresAt = invite.expiresAt,
	})
	notify(player, "notice", { tone = "info", text = `Invitación enviada a {target.DisplayName}.` })
end

function PartyService.respondInvite(player: Player, partyId: string, accept: boolean)
	if not canEditInHub() then
		return
	end
	local ok, res = PartyRules.respondInvite(state, player.UserId, partyId, accept, now())
	notify(player, "inviteCleared", { partyId = partyId })
	if not ok then
		local text = if res == "invite_expired"
			then "La invitación expiró."
			elseif res == "party_full" then "El grupo se llenó antes de aceptar."
			else "No se pudo responder a la invitación."
		notify(player, "notice", { tone = "warn", text = text })
		return
	end
	syncAllPlayers()
	if res == "joined" then
		notify(player, "notice", { tone = "info", text = "Te uniste al grupo." })
	end
end

function PartyService.leaveParty(player: Player)
	if not canEditInHub() then
		return
	end
	local party = PartyRules.getPlayerParty(state, player.UserId)
	if party and party.locked then
		return
	end
	local ok, _, newLeaderId = PartyRules.leave(state, player.UserId)
	if ok then
		syncAllPlayers()
		if newLeaderId then
			local newLeader = Players:GetPlayerByUserId(newLeaderId)
			if newLeader then
				notify(newLeader, "notice", { tone = "info", text = "Ahora eres el líder del grupo." })
			end
		end
	end
end

function PartyService.kickMember(player: Player, targetUserId: number)
	if not canEditInHub() then
		return
	end
	local targetId = math.floor(targetUserId)
	local ok, err = PartyRules.kick(state, player.UserId, targetId)
	if not ok then
		if err == "not_leader" then
			notify(player, "notice", { tone = "warn", text = "Solo el líder puede expulsar miembros." })
		end
		return
	end
	syncAllPlayers()
	local kicked = Players:GetPlayerByUserId(targetId)
	if kicked then
		notify(kicked, "notice", { tone = "warn", text = "Fuiste expulsado del grupo." })
	end
end

function PartyService.requestLaunch(player: Player)
	if not canEditInHub() then
		return
	end
	local payload, err = PartyRules.lockForRun(state, player.UserId, soloDifficulty[player] or Config.DEFAULT_DIFFICULTY)
	if not payload then
		local text = if err == "not_leader"
			then "Solo el líder del grupo puede iniciar la run."
			elseif err == "party_locked" then "La run ya se está iniciando..."
			else "No se pudo iniciar la run."
		notify(player, "notice", { tone = "warn", text = text })
		return
	end
	syncAllPlayers()
	if onLaunchRequest then
		local ok, reason = onLaunchRequest(payload)
		if not ok then
			PartyRules.unlockParty(state, payload.partyId)
			syncAllPlayers()
			local msg = if reason == "teleport_cooldown"
				then "Espera un par de segundos antes de volver a iniciar."
				else "Error al reservar el servidor de la run. Intenta nuevamente."
			notify(player, "launchFailed", {
				reason = reason or "error",
				text = msg,
			})
		end
	end
end

function PartyService.unlockPlayerParty(player: Player, errorText: string?)
	local party = PartyRules.getPlayerParty(state, player.UserId)
	if party then
		PartyRules.unlockParty(state, party.id)
		syncAllPlayers()
	end
	notify(player, "launchFailed", {
		reason = "teleport_failed",
		text = errorText or "El teletransporte falló. El grupo fue desbloqueado.",
	})
end

function PartyService.unlockAll()
	for id, _ in pairs(state.parties) do
		PartyRules.unlockParty(state, id)
	end
	syncAllPlayers()
end

function PartyService.forget(player: Player)
	soloDifficulty[player] = nil
	local _, newLeaderId = PartyRules.removePlayer(state, player.UserId)
	syncAllPlayers()
	if newLeaderId then
		local newLeader = Players:GetPlayerByUserId(newLeaderId)
		if newLeader then
			notify(newLeader, "notice", { tone = "info", text = "El líder anterior salió. Ahora eres líder del grupo." })
		end
	end
end

function PartyService.start(deps: {
	isHubMode: (() -> boolean)?,
	onLaunchRequest: ((PartyRules.LaunchPayload) -> (boolean, string?))?,
})
	isHubMode = deps.isHubMode
	onLaunchRequest = deps.onLaunchRequest

	Players.PlayerAdded:Connect(function(player: Player)
		soloDifficulty[player] = Config.DEFAULT_DIFFICULTY
		syncPlayerAttributes(player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		soloDifficulty[player] = soloDifficulty[player] or Config.DEFAULT_DIFFICULTY
		syncPlayerAttributes(player)
	end

	-- Periodic sweep of expired private invites so clients clear stale toasts cleanly.
	task.spawn(function()
		while true do
			task.wait(2)
			local expired = PartyRules.pruneExpiredInvites(state, now())
			for _, inv in ipairs(expired) do
				local target = Players:GetPlayerByUserId(inv.targetId)
				if target then
					notify(target, "inviteCleared", { partyId = inv.partyId })
				end
			end
		end
	end)
end

return PartyService
