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

export type CardKind = "newAbility" | "upgradeAbility" | "replaceAbility" | "stat" | "passive"

export type CardData = {
	id: string,
	kind: CardKind,
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

-- Matches `UpgradePool.applyPick`: returns true when picking `card` requires choosing one of the
-- `Config.ABILITY_SLOTS` active slots to replace (`replaceAbility`, or a queued `newAbility`
-- whose slots filled up before the player picked it).
function UpgradeStore.needsSlotReplacement(card: CardData, ownedSlots: { string }): boolean
	if card.kind == "replaceAbility" then
		return card.abilityId ~= nil
	end
	if card.kind ~= "newAbility" or not card.abilityId then
		return false
	end
	for i = 1, Config.ABILITY_SLOTS do
		local id = ownedSlots[i]
		if not id or id == "" or id == card.abilityId then
			return false
		end
	end
	return true
end

function UpgradeStore.categoryLabel(card: CardData, willReplace: boolean?): string
	if card.kind == "replaceAbility" or willReplace == true then
		return "REEMPLAZAR"
	elseif card.kind == "upgradeAbility" then
		return "SUBIR NIVEL"
	elseif card.kind == "newAbility" then
		return "HABILIDAD"
	elseif card.kind == "stat" then
		return "ESTADÍSTICA"
	elseif card.kind == "passive" then
		return "PASIVA"
	end
	return string.upper(card.category)
end

function UpgradeStore.selfTest()
	UpgradeStore.reset()
	assert(not UpgradeStore.hasOffer(), "starts with no active offer")
	assert(UpgradeStore.pending() == 0, "starts with 0 pending offers")
	assert(UpgradeStore.replacingCardIndex() == nil, "starts outside replace mode")

	local cardNew: CardData = {
		id = "newAbility_spin",
		kind = "newAbility",
		title = "Torbellino",
		effect = "Giro 360°",
		category = "ability",
		abilityId = "spin",
		nextLevel = 1,
		color = nil,
	}
	local cardUpgrade: CardData = {
		id = "upgradeAbility_taunt",
		kind = "upgradeAbility",
		title = "Rugido Nv.2",
		effect = "+25% daño · -10% recarga",
		category = "ability",
		abilityId = "taunt",
		nextLevel = 2,
		color = nil,
	}
	local cardReplace: CardData = {
		id = "replaceAbility_healPulse",
		kind = "replaceAbility",
		title = "Cambiar: Santuario",
		effect = "Reemplaza hueco · Zona curativa",
		category = "ability",
		abilityId = "healPulse",
		nextLevel = 1,
		color = nil,
	}
	local cardStat: CardData = {
		id = "stat_dmg",
		kind = "stat",
		title = "Filo Sobrecargado",
		effect = "+20% Daño total",
		category = "stat",
		color = nil,
	}
	local cardPassive: CardData = {
		id = "passive_double_jump",
		kind = "passive",
		title = "Doble Salto",
		effect = "Salto extra en el aire",
		category = "passive",
		color = nil,
	}

	-- Slot replacement rules match server UpgradePool.applyPick.
	local emptySlots = { "", "", "" }
	local partialSlots = { "taunt", "stinger", "" }
	local fullSlots = { "taunt", "stinger", "overdrive" }
	local fullWithSpin = { "spin", "stinger", "overdrive" }

	assert(not UpgradeStore.needsSlotReplacement(cardNew, emptySlots), "newAbility into empty slots does not replace")
	assert(not UpgradeStore.needsSlotReplacement(cardNew, partialSlots), "newAbility into partial slots does not replace")
	assert(UpgradeStore.needsSlotReplacement(cardNew, fullSlots), "queued newAbility into 3/3 full slots requires replacement")
	assert(not UpgradeStore.needsSlotReplacement(cardNew, fullWithSpin), "queued newAbility already owned upgrades instead of replacing")
	assert(UpgradeStore.needsSlotReplacement(cardReplace, fullSlots), "replaceAbility requires choosing a slot")
	assert(not UpgradeStore.needsSlotReplacement(cardUpgrade, fullSlots), "upgradeAbility never opens replace picker")
	assert(not UpgradeStore.needsSlotReplacement(cardStat, fullSlots), "stat card never opens replace picker")
	assert(not UpgradeStore.needsSlotReplacement(cardPassive, fullSlots), "passive card never opens replace picker")

	assert(UpgradeStore.categoryLabel(cardNew, false) == "HABILIDAD", "newAbility label")
	assert(UpgradeStore.categoryLabel(cardNew, true) == "REEMPLAZAR", "queued newAbility into full slots shows REEMPLAZAR")
	assert(UpgradeStore.categoryLabel(cardReplace) == "REEMPLAZAR", "replaceAbility label")
	assert(UpgradeStore.categoryLabel(cardUpgrade) == "SUBIR NIVEL", "upgradeAbility label")
	assert(UpgradeStore.categoryLabel(cardStat) == "ESTADÍSTICA", "stat label")
	assert(UpgradeStore.categoryLabel(cardPassive) == "PASIVA", "passive label")

	local sampleOffer: OfferData = {
		offerId = 1,
		isStarter = true,
		cards = { cardNew, cardUpgrade, cardReplace },
	}

	UpgradeStore.setServerState(sampleOffer, 2)
	assert(UpgradeStore.hasOffer(), "hasOffer is true when offer has cards")
	assert(UpgradeStore.pending() == 2, "tracks queued offers behind active offer")

	assert(UpgradeStore.beginReplace(3), "enters replace mode for valid card index")
	assert(UpgradeStore.replacingCardIndex() == 3, "stores selected card index for replacement")
	assert(not UpgradeStore.beginReplace(99), "rejects out-of-range card index")

	-- Same offerId update preserves replace mode; new offerId clears replace mode.
	UpgradeStore.setServerState(sampleOffer, 1)
	assert(UpgradeStore.replacingCardIndex() == 3, "same offerId preserves replace mode")

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
