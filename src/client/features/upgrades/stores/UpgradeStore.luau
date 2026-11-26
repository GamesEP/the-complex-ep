--!strict
--[[
	Client-owned reactive store for the zero-pause 1-of-3 UpgradeChoice banner (plans/roadmap.md VS-20).

	Pure Luau Charm atoms — no Roblox services or remotes — so `make test ONLY=ui` exercises offer
	updates, queue depth tracking, 3-slot replace mode transitions, and resets offline.
	`UpgradeChoice.luau` connects `Remotes.UpgradeOffer` and calls `setServerState`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage:WaitForChild("Packages").charm)
local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

local UpgradeStore = {}

export type CardData = {
	id: string,
	kind: "ability" | "stat" | "passive",
	title: string,
	effect: string,
	category: string,
	abilityId: string?,
	nextLevel: number?,
	color: any,
}

export type OfferData = {
	offerId: number,
	isStarter: boolean,
	cards: { CardData },
}

UpgradeStore.offer = Charm.atom(nil :: OfferData?)
UpgradeStore.pending = Charm.atom(0)
-- When non-nil (1..UPGRADE_CHOICES), the banner switches to the 3-slot replacement picker for that card.
UpgradeStore.replacingCardIndex = Charm.atom(nil :: number?)

function UpgradeStore.hasOffer(): boolean
	local cur = UpgradeStore.offer()
	return cur ~= nil and #cur.cards > 0
end

function UpgradeStore.setServerState(offer: OfferData?, pending: number)
	local prev = UpgradeStore.offer()
	local prevId = if prev then prev.offerId else nil
	local nextId = if offer then offer.offerId else nil

	UpgradeStore.offer(offer)
	UpgradeStore.pending(math.max(math.floor(pending or 0), 0))
	if prevId ~= nextId or offer == nil then
		UpgradeStore.replacingCardIndex(nil)
	end
end

function UpgradeStore.beginReplace(cardIndex: number): boolean
	local cur = UpgradeStore.offer()
	if not cur then
		return false
	end
	local idx = math.floor(cardIndex)
	if idx < 1 or idx > #cur.cards then
		return false
	end
	UpgradeStore.replacingCardIndex(idx)
	return true
end

function UpgradeStore.cancelReplace()
	UpgradeStore.replacingCardIndex(nil)
end

function UpgradeStore.reset()
	UpgradeStore.offer(nil)
	UpgradeStore.pending(0)
	UpgradeStore.replacingCardIndex(nil)
end

function UpgradeStore.selfTest()
	UpgradeStore.reset()
	assert(not UpgradeStore.hasOffer(), "starts with no active offer")
	assert(UpgradeStore.pending() == 0, "starts with 0 pending offers")
	assert(UpgradeStore.replacingCardIndex() == nil, "starts outside replace mode")

	local sampleOffer: OfferData = {
		offerId = 1,
		isStarter = true,
		cards = {
			{ id = "ability_spin", kind = "ability", title = "Torbellino", effect = "Giro 360°", category = "HABILIDAD", abilityId = "spin", nextLevel = 1, color = nil },
			{ id = "ability_taunt", kind = "ability", title = "Rugido", effect = "Aturde", category = "HABILIDAD", abilityId = "taunt", nextLevel = 1, color = nil },
			{ id = "ability_stinger", kind = "ability", title = "Estocada", effect = "Embestida", category = "HABILIDAD", abilityId = "stinger", nextLevel = 1, color = nil },
		},
	}

	UpgradeStore.setServerState(sampleOffer, 2)
	assert(UpgradeStore.hasOffer(), "hasOffer is true when offer has cards")
	assert(UpgradeStore.pending() == 2, "tracks queued offers behind active offer")

	assert(UpgradeStore.beginReplace(2), "enters replace mode for valid card index")
	assert(UpgradeStore.replacingCardIndex() == 2, "stores selected card index for replacement")
	assert(not UpgradeStore.beginReplace(99), "rejects out-of-range card index")

	-- Same offerId update preserves replace mode; new offerId clears replace mode.
	UpgradeStore.setServerState(sampleOffer, 1)
	assert(UpgradeStore.replacingCardIndex() == 2, "same offerId preserves replace mode")

	local nextOffer: OfferData = {
		offerId = 2,
		isStarter = false,
		cards = sampleOffer.cards,
	}
	UpgradeStore.setServerState(nextOffer, 0)
	assert(UpgradeStore.replacingCardIndex() == nil, "advancing to a new offer clears replace mode")
	assert(UpgradeStore.pending() == 0, "pending updates to 0")

	assert(Config.UPGRADE_CHOICES == 3, "config keeps 3 upgrade choices")
	UpgradeStore.reset()
	assert(not UpgradeStore.hasOffer(), "reset clears offer")
end

return UpgradeStore
