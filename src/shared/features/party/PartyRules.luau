--!strict
--[[
	Pure Party state machine (`plans/gdd/systems.md`, `plans/roadmap.md HS-03 / HS-24`).

	No Roblox services: manages open/private parties up to `Config.PARTY_MAX_PLAYERS` (4),
	private-party invitations with `Config.PARTY_INVITE_SECONDS` expiry, leader kick, automatic
	leader transfer to the longest-standing remaining member on disconnect, and run-launch locking.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)
local Difficulty = require(script.Parent.Parent.enemies.Difficulty)

local PartyRules = {}

export type Privacy = "open" | "private"

export type Party = {
	id: string,
	leaderId: number,
	privacy: Privacy,
	difficulty: string,
	locked: boolean,
	-- Ordered oldest-to-newest so leader transfer always promotes the longest-standing member.
	members: { number },
}

export type Invite = {
	partyId: string,
	fromId: number,
	targetId: number,
	expiresAt: number,
}

export type State = {
	nextId: number,
	parties: { [string]: Party },
	playerParty: { [number]: string },
	-- invites[targetId][partyId] = Invite
	invites: { [number]: { [string]: Invite } },
}

export type LaunchPayload = {
	partyId: string?,
	leaderId: number,
	difficulty: string,
	members: { number },
}

function PartyRules.isValidPrivacy(privacy: any): boolean
	return privacy == "open" or privacy == "private"
end

function PartyRules.new(): State
	return {
		nextId = 1,
		parties = {},
		playerParty = {},
		invites = {},
	}
end

function PartyRules.getPlayerParty(state: State, userId: number): Party?
	local partyId = state.playerParty[userId]
	if not partyId then
		return nil
	end
	return state.parties[partyId]
end

local function clearInvitesForParty(state: State, partyId: string)
	for targetId, bucket in pairs(state.invites) do
		bucket[partyId] = nil
		if next(bucket) == nil then
			state.invites[targetId] = nil
		end
	end
end

function PartyRules.pruneExpiredInvites(state: State, now: number): { Invite }
	local expired: { Invite } = {}
	for targetId, bucket in pairs(state.invites) do
		for partyId, invite in pairs(bucket) do
			if now >= invite.expiresAt or state.parties[partyId] == nil then
				table.insert(expired, invite)
				bucket[partyId] = nil
			end
		end
		if next(bucket) == nil then
			state.invites[targetId] = nil
		end
	end
	return expired
end

function PartyRules.getPendingInvites(state: State, targetId: number, now: number): { Invite }
	PartyRules.pruneExpiredInvites(state, now)
	local bucket = state.invites[targetId]
	if not bucket then
		return {}
	end
	local out: { Invite } = {}
	for _, invite in pairs(bucket) do
		table.insert(out, invite)
	end
	table.sort(out, function(a, b)
		return a.expiresAt < b.expiresAt
	end)
	return out
end

-- Removes `userId` from their current party. Promotes the longest-standing remaining member if the
-- leader leaves, or disbands the party when the last member exits.
function PartyRules.leave(state: State, userId: number): (boolean, string?, number?)
	local partyId = state.playerParty[userId]
	if not partyId then
		return false, "not_in_party", nil
	end
	local party = state.parties[partyId]
	state.playerParty[userId] = nil
	if not party then
		return true, nil, nil
	end

	local idx = table.find(party.members, userId)
	if idx then
		table.remove(party.members, idx)
	end

	if #party.members == 0 then
		state.parties[partyId] = nil
		clearInvitesForParty(state, partyId)
		return true, "disbanded", nil
	end

	local newLeader: number? = nil
	if party.leaderId == userId then
		party.leaderId = party.members[1]
		newLeader = party.leaderId
	end
	return true, "left", newLeader
end

-- Creates a new party with `userId` as leader. Leaves any previous party first cleanly.
function PartyRules.createParty(
	state: State,
	userId: number,
	privacy: any?,
	difficulty: any?
): (Party?, string?)
	local existing = PartyRules.getPlayerParty(state, userId)
	if existing and existing.locked then
		return nil, "party_locked"
	end
	if existing then
		PartyRules.leave(state, userId)
	end

	local resolvedPrivacy: Privacy = if privacy == "private" then "private" else "open"
	local resolvedDiff = if Difficulty.isValid(difficulty) then difficulty :: string else Config.DEFAULT_DIFFICULTY
	local id = `party_{state.nextId}`
	state.nextId += 1

	local party: Party = {
		id = id,
		leaderId = userId,
		privacy = resolvedPrivacy,
		difficulty = resolvedDiff,
		locked = false,
		members = { userId },
	}
	state.parties[id] = party
	state.playerParty[userId] = id
	return party, nil
end

function PartyRules.setPrivacy(state: State, userId: number, privacy: any): (boolean, string?)
	if not PartyRules.isValidPrivacy(privacy) then
		return false, "invalid_privacy"
	end
	local party = PartyRules.getPlayerParty(state, userId)
	if not party then
		return false, "not_in_party"
	end
	if party.leaderId ~= userId then
		return false, "not_leader"
	end
	if party.locked then
		return false, "party_locked"
	end
	party.privacy = privacy :: Privacy
	return true, nil
end

function PartyRules.setDifficulty(state: State, userId: number, difficulty: any): (boolean, string?)
	if not Difficulty.isValid(difficulty) then
		return false, "invalid_difficulty"
	end
	local party = PartyRules.getPlayerParty(state, userId)
	if not party then
		return false, "not_in_party"
	end
	if party.leaderId ~= userId then
		return false, "not_leader"
	end
	if party.locked then
		return false, "party_locked"
	end
	party.difficulty = difficulty :: string
	return true, nil
end

function PartyRules.joinOpen(state: State, userId: number, partyId: string): (boolean, string?)
	local target = state.parties[partyId]
	if not target then
		return false, "party_not_found"
	end
	if target.locked then
		return false, "party_locked"
	end
	if target.privacy ~= "open" then
		return false, "party_private"
	end
	if table.find(target.members, userId) ~= nil then
		return true, nil
	end
	if #target.members >= Config.PARTY_MAX_PLAYERS then
		return false, "party_full"
	end
	local current = PartyRules.getPlayerParty(state, userId)
	if current and current.locked then
		return false, "party_locked"
	end
	if current then
		PartyRules.leave(state, userId)
	end
	table.insert(target.members, userId)
	state.playerParty[userId] = target.id
	if state.invites[userId] then
		state.invites[userId][target.id] = nil
	end
	return true, nil
end

function PartyRules.invite(state: State, leaderId: number, targetId: number, now: number): (Invite?, string?)
	PartyRules.pruneExpiredInvites(state, now)
	if leaderId == targetId then
		return nil, "cannot_invite_self"
	end
	local party = PartyRules.getPlayerParty(state, leaderId)
	if not party then
		return nil, "not_in_party"
	end
	if party.leaderId ~= leaderId then
		return nil, "not_leader"
	end
	if party.locked then
		return nil, "party_locked"
	end
	if #party.members >= Config.PARTY_MAX_PLAYERS then
		return nil, "party_full"
	end
	if table.find(party.members, targetId) ~= nil then
		return nil, "already_in_party"
	end
	local targetParty = PartyRules.getPlayerParty(state, targetId)
	if targetParty and targetParty.locked then
		return nil, "target_locked"
	end

	local bucket = state.invites[targetId]
	if not bucket then
		bucket = {}
		state.invites[targetId] = bucket
	end
	local invite: Invite = {
		partyId = party.id,
		fromId = leaderId,
		targetId = targetId,
		expiresAt = now + Config.PARTY_INVITE_SECONDS,
	}
	bucket[party.id] = invite
	return invite, nil
end

function PartyRules.respondInvite(
	state: State,
	targetId: number,
	partyId: string,
	accept: boolean,
	now: number
): (boolean, string?)
	PartyRules.pruneExpiredInvites(state, now)
	local bucket = state.invites[targetId]
	local invite = bucket and bucket[partyId]
	if not invite then
		return false, "invite_expired"
	end
	bucket[partyId] = nil
	if next(bucket) == nil then
		state.invites[targetId] = nil
	end
	if not accept then
		return true, "declined"
	end

	local party = state.parties[partyId]
	if not party then
		return false, "party_not_found"
	end
	if party.locked then
		return false, "party_locked"
	end
	if #party.members >= Config.PARTY_MAX_PLAYERS then
		return false, "party_full"
	end
	local current = PartyRules.getPlayerParty(state, targetId)
	if current and current.locked then
		return false, "party_locked"
	end
	if current then
		PartyRules.leave(state, targetId)
	end
	table.insert(party.members, targetId)
	state.playerParty[targetId] = party.id
	return true, "joined"
end

function PartyRules.kick(state: State, leaderId: number, targetId: number): (boolean, string?)
	if leaderId == targetId then
		return false, "cannot_kick_self"
	end
	local party = PartyRules.getPlayerParty(state, leaderId)
	if not party then
		return false, "not_in_party"
	end
	if party.leaderId ~= leaderId then
		return false, "not_leader"
	end
	if party.locked then
		return false, "party_locked"
	end
	if table.find(party.members, targetId) == nil then
		return false, "target_not_in_party"
	end
	PartyRules.leave(state, targetId)
	return true, nil
end

-- Locks a party for teleport/run launch (leader only) or builds a solo launch payload when the
-- player is not in any party.
function PartyRules.lockForRun(state: State, userId: number, soloDifficulty: any?): (LaunchPayload?, string?)
	local party = PartyRules.getPlayerParty(state, userId)
	if not party then
		local diff = if Difficulty.isValid(soloDifficulty) then soloDifficulty :: string else Config.DEFAULT_DIFFICULTY
		return {
			partyId = nil,
			leaderId = userId,
			difficulty = diff,
			members = { userId },
		}, nil
	end
	if party.leaderId ~= userId then
		return nil, "not_leader"
	end
	if party.locked then
		return nil, "party_locked"
	end
	party.locked = true
	clearInvitesForParty(state, party.id)
	return {
		partyId = party.id,
		leaderId = party.leaderId,
		difficulty = party.difficulty,
		members = table.clone(party.members),
	}, nil
end

function PartyRules.unlockParty(state: State, partyId: string?): boolean
	if not partyId then
		return false
	end
	local party = state.parties[partyId]
	if not party then
		return false
	end
	party.locked = false
	return true
end

function PartyRules.removePlayer(state: State, userId: number): (string?, number?)
	state.invites[userId] = nil
	local _, reason, newLeader = PartyRules.leave(state, userId)
	return reason, newLeader
end

--=============================================================================
-- Self test
--=============================================================================

function PartyRules.selfTest()
	local s = PartyRules.new()

	-- 1. Create open party and join up to 4 players; 5th player rejected.
	local p1, err1 = PartyRules.createParty(s, 101, "open", "hard")
	assert(p1 ~= nil and err1 == nil and p1.leaderId == 101 and p1.privacy == "open" and p1.difficulty == "hard", "create open party")
	assert((PartyRules.joinOpen(s, 102, p1.id)) == true, "member 2 joins open party")
	assert((PartyRules.joinOpen(s, 103, p1.id)) == true, "member 3 joins open party")
	assert((PartyRules.joinOpen(s, 104, p1.id)) == true, "member 4 joins open party")
	local ok5, err5 = PartyRules.joinOpen(s, 105, p1.id)
	assert(not ok5 and err5 == "party_full", "5th player blocked at PARTY_MAX_PLAYERS = 4")

	-- 2. Non-leader cannot change privacy, difficulty, kick, or launch.
	local okPriv, errPriv = PartyRules.setPrivacy(s, 102, "private")
	assert(not okPriv and errPriv == "not_leader", "non-leader cannot change privacy")
	local okKick, errKick = PartyRules.kick(s, 102, 103)
	assert(not okKick and errKick == "not_leader", "non-leader cannot kick")
	local launchNonLeader, errLaunch = PartyRules.lockForRun(s, 102)
	assert(launchNonLeader == nil and errLaunch == "not_leader", "non-leader cannot start run")

	-- 3. Leader kicks member 104, switches to private; open join now refused.
	assert((PartyRules.kick(s, 101, 104)) == true, "leader kicks member 4")
	assert(#p1.members == 3 and PartyRules.getPlayerParty(s, 104) == nil, "kicked member removed")
	assert((PartyRules.setPrivacy(s, 101, "private")) == true, "leader sets party private")
	local okPrivJoin, errPrivJoin = PartyRules.joinOpen(s, 105, p1.id)
	assert(not okPrivJoin and errPrivJoin == "party_private", "private party refuses direct join")

	-- 4. Private invite expiry and accept flow.
	local inv1, invErr = PartyRules.invite(s, 101, 105, 100)
	assert(inv1 ~= nil and invErr == nil and inv1.expiresAt == 100 + Config.PARTY_INVITE_SECONDS, "invite created with TTL")
	local okExp, errExp = PartyRules.respondInvite(s, 105, p1.id, true, 100 + Config.PARTY_INVITE_SECONDS + 0.1)
	assert(not okExp and errExp == "invite_expired", "expired invite rejected")

	local inv2 = PartyRules.invite(s, 101, 105, 200)
	assert(inv2 ~= nil, "re-invite succeeds")
	local okAcc, resAcc = PartyRules.respondInvite(s, 105, p1.id, true, 205)
	assert(okAcc and resAcc == "joined" and #p1.members == 4, "valid invite joins private party")

	-- 5. Leader disconnect transfers leadership to longest-standing member (102).
	local reason, newLeader = PartyRules.removePlayer(s, 101)
	assert(reason == "left" and newLeader == 102 and p1.leaderId == 102, "leader transfers to longest-standing member")

	-- 6. New leader locks party for launch; locked party refuses joins/kicks until unlocked.
	local payload, lockErr = PartyRules.lockForRun(s, 102)
	assert(payload ~= nil and lockErr == nil and payload.leaderId == 102 and #payload.members == 3, "leader locks party for run")
	local okKickLocked, errKickLocked = PartyRules.kick(s, 102, 103)
	assert(not okKickLocked and errKickLocked == "party_locked", "locked party blocks kick")
	assert(PartyRules.unlockParty(s, payload.partyId), "unlocks party after teleport failure")

	-- 7. Solo player without a party launches directly.
	local soloPayload, soloErr = PartyRules.lockForRun(s, 999, "deadzone")
	assert(soloPayload ~= nil and soloErr == nil and #soloPayload.members == 1 and soloPayload.difficulty == "deadzone", "solo launch works")
end

return PartyRules
