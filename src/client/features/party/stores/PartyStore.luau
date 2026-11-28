--!strict
--[[
	Client-owned reactive store for Hub Party invitations and launch notices (`plans/roadmap.md HS-26`).

	Pure Luau Charm atoms — no Roblox services or remotes — so `make test ONLY=ui` verifies invite
	deduplication, expiration pruning, notice banners, launch pending state, and resets offline.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage:WaitForChild("Packages").charm)
local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

local PartyStore = {}

export type InviteItem = {
	partyId: string,
	fromUserId: number,
	fromName: string,
	expiresAt: number,
}

export type NoticeItem = {
	tone: "info" | "warn" | "error",
	text: string,
	expiresAt: number,
}

PartyStore.invites = Charm.atom({} :: { InviteItem })
PartyStore.notice = Charm.atom(nil :: NoticeItem?)
PartyStore.launching = Charm.atom(false)

function PartyStore.addInvite(item: InviteItem)
	local current = PartyStore.invites()
	local nextList: { InviteItem } = {}
	local replaced = false
	for _, existing in ipairs(current) do
		if existing.partyId == item.partyId then
			table.insert(nextList, item)
			replaced = true
		else
			table.insert(nextList, existing)
		end
	end
	if not replaced then
		table.insert(nextList, item)
	end
	PartyStore.invites(nextList)
end

function PartyStore.removeInvite(partyId: string)
	local current = PartyStore.invites()
	local nextList: { InviteItem } = {}
	local changed = false
	for _, existing in ipairs(current) do
		if existing.partyId == partyId then
			changed = true
		else
			table.insert(nextList, existing)
		end
	end
	if changed then
		PartyStore.invites(nextList)
	end
end

function PartyStore.pruneExpired(now: number)
	local current = PartyStore.invites()
	if #current > 0 then
		local nextList: { InviteItem } = {}
		local changed = false
		for _, item in ipairs(current) do
			if now < item.expiresAt then
				table.insert(nextList, item)
			else
				changed = true
			end
		end
		if changed then
			PartyStore.invites(nextList)
		end
	end
	local notice = PartyStore.notice()
	if notice and now >= notice.expiresAt then
		PartyStore.notice(nil)
	end
end

function PartyStore.showNotice(tone: "info" | "warn" | "error", text: string, now: number, duration: number?)
	PartyStore.notice({
		tone = tone,
		text = text,
		expiresAt = now + (duration or 4.5),
	})
end

function PartyStore.clearNotice()
	PartyStore.notice(nil)
end

function PartyStore.setLaunching(active: boolean)
	PartyStore.launching(active)
end

function PartyStore.reset()
	PartyStore.invites({})
	PartyStore.notice(nil)
	PartyStore.launching(false)
end

function PartyStore.selfTest()
	PartyStore.reset()
	assert(#PartyStore.invites() == 0, "starts with no invites")
	assert(PartyStore.notice() == nil, "starts with no notice")
	assert(PartyStore.launching() == false, "starts not launching")

	PartyStore.addInvite({
		partyId = "party_1",
		fromUserId = 10,
		fromName = "Alpha",
		expiresAt = 100 + Config.PARTY_INVITE_SECONDS,
	})
	assert(#PartyStore.invites() == 1, "adds invite cleanly")

	-- Re-inviting from the same party refreshes rather than duplicating.
	PartyStore.addInvite({
		partyId = "party_1",
		fromUserId = 10,
		fromName = "Alpha",
		expiresAt = 110 + Config.PARTY_INVITE_SECONDS,
	})
	assert(#PartyStore.invites() == 1 and PartyStore.invites()[1].expiresAt == 110 + Config.PARTY_INVITE_SECONDS, "deduplicates by partyId")

	PartyStore.addInvite({
		partyId = "party_2",
		fromUserId = 20,
		fromName = "Bravo",
		expiresAt = 105,
	})
	assert(#PartyStore.invites() == 2, "holds multiple distinct party invites")

	PartyStore.pruneExpired(106)
	assert(#PartyStore.invites() == 1 and PartyStore.invites()[1].partyId == "party_1", "prunes only expired invites")

	PartyStore.removeInvite("party_1")
	assert(#PartyStore.invites() == 0, "removes invite on accept/decline")

	PartyStore.showNotice("warn", "Grupo lleno", 200, 3)
	assert(PartyStore.notice() ~= nil and (PartyStore.notice() :: NoticeItem).text == "Grupo lleno", "shows notice")
	PartyStore.pruneExpired(204)
	assert(PartyStore.notice() == nil, "expires notice cleanly")

	PartyStore.setLaunching(true)
	assert(PartyStore.launching() == true, "tracks launching state")
	PartyStore.reset()
	assert(PartyStore.launching() == false, "reset clears launching state")
end

return PartyStore
