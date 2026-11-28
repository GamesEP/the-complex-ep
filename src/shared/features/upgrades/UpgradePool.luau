--!strict
--[[
	Pure 1-of-3 run upgrade roll, slot-full conversion, queue, and floor-exit auto-resolve
	(plans/gdd/systems.md, "Mejoras de run", plans/roadmap.md VS-16).

	Every player starts with 0 active abilities (`slots = {}`), base stats, and no movement
	passives. Offers stack in an unbounded queue within a floor so combat never pauses; when all
	3 active slots are full, a rolled new active ability converts randomly into (a) an upgrade to
	an owned active, (b) a replacement offer, or (c) a stat upgrade.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local UpgradePool = {}

export type CardKind = "newAbility" | "upgradeAbility" | "replaceAbility" | "stat" | "passive"

export type UpgradeCard = {
	id: string,
	kind: CardKind,
	title: string,
	effect: string,
	category: "ability" | "stat" | "passive",
	abilityId: string?,
	nextLevel: number?,
	statId: string?,
	passiveId: string?,
	color: Color3,
}

export type Offer = {
	offerId: number,
	isStarter: boolean,
	cards: { UpgradeCard },
}

export type PlayerBuild = {
	slots: { string },
	levels: { [string]: number },
	maxHealthBonus: number,
	damageBonus: number,
	speedBonus: number,
	cooldownMult: number,
	critChance: number,
	lifeOnKill: number,
	heavyChargeMult: number,
	parryBonus: number,
	hasDoubleJump: boolean,
	hasDoubleDash: boolean,
	hasDashBoost: boolean,
	hasSwiftDash: boolean,
	queue: { Offer },
	nextOfferId: number,
}

local STAT_COLOR = Color3.fromRGB(245, 196, 0) -- ui.HAZARD
local PASSIVE_COLOR = Color3.fromRGB(56, 212, 255) -- ui.KINETIC

function UpgradePool.initial(): PlayerBuild
	return {
		slots = {},
		levels = {},
		maxHealthBonus = 0,
		damageBonus = 0,
		speedBonus = 0,
		cooldownMult = 1.0,
		critChance = 0,
		lifeOnKill = 0,
		heavyChargeMult = 1.0,
		parryBonus = 0,
		hasDoubleJump = false,
		hasDoubleDash = false,
		hasDashBoost = false,
		hasSwiftDash = false,
		queue = {},
		nextOfferId = 1,
	}
end

function UpgradePool.hasPassive(build: PlayerBuild, attribute: string): boolean
	if attribute == "HasDoubleJump" then
		return build.hasDoubleJump
	elseif attribute == "HasDoubleDash" then
		return build.hasDoubleDash
	elseif attribute == "HasDashBoost" then
		return build.hasDashBoost
	elseif attribute == "HasSwiftDash" then
		return build.hasSwiftDash
	end
	return false
end

function UpgradePool.critMultiplier(critChance: number, roll: number): number
	if critChance > 0 and roll < math.min(critChance, Config.MAX_CRIT_CHANCE or 0.75) then
		return Config.CRIT_DAMAGE_MULTIPLIER or 1.6
	end
	return 1
end

function UpgradePool.slotOf(build: PlayerBuild, abilityId: string): number?
	for i, owned in ipairs(build.slots) do
		if owned == abilityId then
			return i
		end
	end
	return nil
end

function UpgradePool.abilityLevel(build: PlayerBuild, abilityId: string): number
	return build.levels[abilityId] or 0
end

-- Damage and cooldown multipliers for an owned active ability at `level` (1..ABILITY_MAX_LEVEL).
function UpgradePool.levelMultipliers(level: number): (number, number)
	local extra = math.max(level - 1, 0)
	local dmgMult = 1 + extra * Config.ABILITY_LEVEL_DAMAGE_STEP
	local cdMult = math.max(1 - extra * Config.ABILITY_LEVEL_COOLDOWN_STEP, 0.5)
	return dmgMult, cdMult
end

local function upgradeEffectCopy(abilityId: string): string
	if abilityId == "bulwark" or abilityId == "protectField" then
		return "+20% duración · -10% recarga"
	elseif abilityId == "healPulse" then
		return "+25% curación · -10% recarga"
	end
	return "+25% daño · -10% recarga"
end

local function makeAbilityCard(abilityId: string, kind: "newAbility" | "upgradeAbility" | "replaceAbility", level: number): UpgradeCard
	local def = Config.ABILITIES[abilityId]
	local name = if def then def.name else abilityId
	local color = if def and def.color then def.color else STAT_COLOR
	local copy = Config.UPGRADE_ABILITY_COPY[abilityId] or "Habilidad activa"
	local title = if kind == "upgradeAbility"
		then `{name} Nv.{level}`
		elseif kind == "replaceAbility" then `Cambiar: {name}`
		else name
	local effect = if kind == "upgradeAbility"
		then upgradeEffectCopy(abilityId)
		elseif kind == "replaceAbility" then `Reemplaza hueco · {copy}`
		else copy
	return {
		id = `{kind}_{abilityId}`,
		kind = kind,
		title = title,
		effect = effect,
		category = "ability",
		abilityId = abilityId,
		nextLevel = level,
		color = color,
	}
end

local function makeStatCard(def: Config.StatUpgradeDef): UpgradeCard
	return {
		id = def.id,
		kind = "stat",
		title = def.title,
		effect = def.effect,
		category = "stat",
		statId = def.id,
		color = STAT_COLOR,
	}
end

local function makePassiveCard(def: Config.PassiveUpgradeDef): UpgradeCard
	return {
		id = def.id,
		kind = "passive",
		title = def.title,
		effect = def.effect,
		category = "passive",
		passiveId = def.id,
		color = PASSIVE_COLOR,
	}
end

local function findStatDef(statId: string?): Config.StatUpgradeDef?
	if not statId then
		return nil
	end
	for _, def in ipairs(Config.STAT_UPGRADES) do
		if def.id == statId then
			return def
		end
	end
	return nil
end

local function findPassiveDef(passiveId: string?): Config.PassiveUpgradeDef?
	if not passiveId then
		return nil
	end
	for _, def in ipairs(Config.PASSIVE_UPGRADES) do
		if def.id == passiveId then
			return def
		end
	end
	return nil
end

local function shuffleCopy<T>(items: { T }, rng: () -> number): { T }
	local out = table.clone(items)
	for i = #out, 2, -1 do
		local j = math.clamp(math.floor(rng() * i) + 1, 1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- Rolls 3 distinct starter active abilities for the beginning of a run (`START_ABILITY_CHOICES`).
function UpgradePool.rollStarter(build: PlayerBuild, rng: (() -> number)?): Offer
	local rand = rng or math.random
	local pool = shuffleCopy(Config.UPGRADE_ABILITY_ORDER, rand)
	local cards: { UpgradeCard } = {}
	local count = math.min(Config.START_ABILITY_CHOICES, #pool)
	for i = 1, count do
		table.insert(cards, makeAbilityCard(pool[i], "newAbility", 1))
	end
	local offerId = build.nextOfferId
	build.nextOfferId += 1
	return {
		offerId = offerId,
		isStarter = true,
		cards = cards,
	}
end

-- Rolls 3 distinct upgrade cards for a room clear. When all 3 active slots are full, any rolled
-- unowned active ability converts randomly into (a) upgrading an owned active, (b) a replacement
-- offer, or (c) a stat upgrade.
function UpgradePool.rollRoomOffer(build: PlayerBuild, rng: (() -> number)?): Offer
	local rand = rng or math.random
	local slotsFull = #build.slots >= Config.ABILITY_SLOTS

	-- Collect upgradeable owned abilities and unowned abilities.
	local upgradeableOwned: { string } = {}
	for _, id in ipairs(build.slots) do
		if (build.levels[id] or 1) < Config.ABILITY_MAX_LEVEL then
			table.insert(upgradeableOwned, id)
		end
	end
	local unownedAbilities: { string } = {}
	for _, id in ipairs(Config.UPGRADE_ABILITY_ORDER) do
		if not UpgradePool.slotOf(build, id) then
			table.insert(unownedAbilities, id)
		end
	end
	local unownedPassives: { Config.PassiveUpgradeDef } = {}
	for _, def in ipairs(Config.PASSIVE_UPGRADES) do
		if not UpgradePool.hasPassive(build, def.attribute) then
			table.insert(unownedPassives, def)
		end
	end

	-- Build candidate card pool.
	local candidates: { UpgradeCard } = {}
	for _, statDef in ipairs(Config.STAT_UPGRADES) do
		table.insert(candidates, makeStatCard(statDef))
	end
	for _, pDef in ipairs(unownedPassives) do
		table.insert(candidates, makePassiveCard(pDef))
	end
	for _, ownedId in ipairs(upgradeableOwned) do
		table.insert(candidates, makeAbilityCard(ownedId, "upgradeAbility", (build.levels[ownedId] or 1) + 1))
	end

	local shuffledUnowned = shuffleCopy(unownedAbilities, rand)
	if not slotsFull then
		-- Offer up to 3 unowned active abilities cleanly in the candidate mix.
		for i = 1, math.min(3, #shuffledUnowned) do
			table.insert(candidates, makeAbilityCard(shuffledUnowned[i], "newAbility", 1))
		end
	elseif #shuffledUnowned > 0 then
		-- Slots full (3/3): each of the 3 rolled unowned active slots converts randomly into one
		-- of the 3 GDD rules (owned level-up, slot replacement, or stat boost) so probabilities
		-- stay balanced even after deduplicating `card.id` below.
		for i = 1, math.min(3, #shuffledUnowned) do
			local roll = rand()
			if roll < 0.34 and #upgradeableOwned > 0 then
				local pickIdx = math.clamp(math.floor(rand() * #upgradeableOwned) + 1, 1, #upgradeableOwned)
				local ownedId = upgradeableOwned[pickIdx]
				table.insert(candidates, makeAbilityCard(ownedId, "upgradeAbility", (build.levels[ownedId] or 1) + 1))
			elseif roll < 0.67 then
				table.insert(candidates, makeAbilityCard(shuffledUnowned[i], "replaceAbility", 1))
			else
				local statIdx = math.clamp(math.floor(rand() * #Config.STAT_UPGRADES) + 1, 1, #Config.STAT_UPGRADES)
				table.insert(candidates, makeStatCard(Config.STAT_UPGRADES[statIdx]))
			end
		end
	end

	local shuffled = shuffleCopy(candidates, rand)
	local cards: { UpgradeCard } = {}
	local seenIds: { [string]: boolean } = {}
	for _, card in ipairs(shuffled) do
		if not seenIds[card.id] then
			seenIds[card.id] = true
			table.insert(cards, card)
			if #cards >= Config.UPGRADE_CHOICES then
				break
			end
		end
	end

	local offerId = build.nextOfferId
	build.nextOfferId += 1
	return {
		offerId = offerId,
		isStarter = false,
		cards = cards,
	}
end

function UpgradePool.enqueue(build: PlayerBuild, offer: Offer)
	table.insert(build.queue, offer)
end

function UpgradePool.currentOffer(build: PlayerBuild): Offer?
	return build.queue[1]
end

function UpgradePool.pendingBehind(build: PlayerBuild): number
	return math.max(#build.queue - 1, 0)
end

-- Refreshes the new queue head after an earlier pick changed the player's build, so queued offers
-- can never waste a pick on an already-owned passive, an already-maxed ability, or an ability
-- that was replaced out of the player's slots.
local function sanitizeHeadOffer(build: PlayerBuild, rng: (() -> number)?)
	local head = build.queue[1]
	if not head or head.isStarter then
		return
	end
	local rand = rng or math.random
	local usedIds: { [string]: boolean } = {}
	for _, card in ipairs(head.cards) do
		usedIds[card.id] = true
	end

	local function pickFreshStat(): UpgradeCard
		local stats = shuffleCopy(Config.STAT_UPGRADES, rand)
		for _, statDef in ipairs(stats) do
			if not usedIds[statDef.id] then
				usedIds[statDef.id] = true
				return makeStatCard(statDef)
			end
		end
		return makeStatCard(Config.STAT_UPGRADES[1])
	end

	for i, card in ipairs(head.cards) do
		local stale = false
		if card.kind == "passive" then
			local def = findPassiveDef(card.passiveId)
			if def then
				stale = UpgradePool.hasPassive(build, def.attribute)
			end
		elseif card.kind == "upgradeAbility" and card.abilityId then
			local ownedSlot = UpgradePool.slotOf(build, card.abilityId)
			local curLevel = build.levels[card.abilityId] or 0
			if not ownedSlot or curLevel >= Config.ABILITY_MAX_LEVEL then
				stale = true
			elseif card.nextLevel ~= curLevel + 1 then
				head.cards[i] = makeAbilityCard(card.abilityId, "upgradeAbility", curLevel + 1)
			end
		elseif card.kind == "replaceAbility" and card.abilityId then
			if UpgradePool.slotOf(build, card.abilityId) ~= nil then
				local curLevel = build.levels[card.abilityId] or 1
				if curLevel < Config.ABILITY_MAX_LEVEL then
					local upgraded = makeAbilityCard(card.abilityId, "upgradeAbility", curLevel + 1)
					if not usedIds[upgraded.id] then
						usedIds[upgraded.id] = true
						head.cards[i] = upgraded
					else
						stale = true
					end
				else
					stale = true
				end
			end
		end
		if stale then
			head.cards[i] = pickFreshStat()
		end
	end
end

-- Applies a player's pick from the head of the queue. Returns `(ok, healAmount, pickedCard)`.
function UpgradePool.applyPick(
	build: PlayerBuild,
	offerId: number,
	cardIndex: number,
	replaceSlot: number?
): (boolean, number, UpgradeCard?)
	local offer = build.queue[1]
	if not offer or offer.offerId ~= offerId then
		return false, 0, nil
	end
	if cardIndex < 1 or cardIndex > #offer.cards or math.floor(cardIndex) ~= cardIndex then
		return false, 0, nil
	end
	local card = offer.cards[cardIndex]
	local healDelta = 0

	if card.kind == "newAbility" and card.abilityId then
		local existingSlot = UpgradePool.slotOf(build, card.abilityId)
		if existingSlot then
			local cur = build.levels[card.abilityId] or 1
			build.levels[card.abilityId] = math.min(cur + 1, Config.ABILITY_MAX_LEVEL)
		elseif #build.slots < Config.ABILITY_SLOTS then
			table.insert(build.slots, card.abilityId)
			build.levels[card.abilityId] = 1
		else
			-- Slots filled while this offer sat in queue: require a valid replaceSlot (1..3).
			if not replaceSlot or replaceSlot < 1 or replaceSlot > Config.ABILITY_SLOTS or math.floor(replaceSlot) ~= replaceSlot then
				return false, 0, nil
			end
			local oldId = build.slots[replaceSlot]
			if oldId then
				build.levels[oldId] = nil
			end
			build.slots[replaceSlot] = card.abilityId
			build.levels[card.abilityId] = 1
		end
	elseif card.kind == "upgradeAbility" and card.abilityId then
		if UpgradePool.slotOf(build, card.abilityId) then
			local cur = build.levels[card.abilityId] or 1
			build.levels[card.abilityId] = math.min(cur + 1, Config.ABILITY_MAX_LEVEL)
		elseif #build.slots < Config.ABILITY_SLOTS then
			table.insert(build.slots, card.abilityId)
			build.levels[card.abilityId] = 1
		end
	elseif card.kind == "replaceAbility" and card.abilityId then
		local existingSlot = UpgradePool.slotOf(build, card.abilityId)
		if existingSlot then
			local cur = build.levels[card.abilityId] or 1
			build.levels[card.abilityId] = math.min(cur + 1, Config.ABILITY_MAX_LEVEL)
		else
			if not replaceSlot or replaceSlot < 1 or replaceSlot > Config.ABILITY_SLOTS or math.floor(replaceSlot) ~= replaceSlot then
				return false, 0, nil
			end
			local oldId = build.slots[replaceSlot]
			if oldId then
				build.levels[oldId] = nil
			end
			build.slots[replaceSlot] = card.abilityId
			build.levels[card.abilityId] = 1
		end
	elseif card.kind == "stat" then
		local def = findStatDef(card.statId)
		if not def then
			return false, 0, nil
		end
		if def.stat == "maxHealth" then
			build.maxHealthBonus += def.amount
			healDelta = def.amount
		elseif def.stat == "damage" then
			build.damageBonus += def.amount
		elseif def.stat == "speed" then
			build.speedBonus += def.amount
		elseif def.stat == "cooldown" then
			build.cooldownMult = math.max(build.cooldownMult * (1 - def.amount), Config.MIN_COOLDOWN_MULTIPLIER)
		elseif def.stat == "crit" then
			build.critChance = math.min(build.critChance + def.amount, Config.MAX_CRIT_CHANCE or 0.75)
		elseif def.stat == "lifeOnKill" then
			build.lifeOnKill += def.amount
		elseif def.stat == "heavyHaste" then
			build.heavyChargeMult = math.max(build.heavyChargeMult * (1 - def.amount), Config.MIN_HEAVY_CHARGE_MULT or 0.45)
		elseif def.stat == "parryBonus" then
			build.parryBonus += def.amount
		end
	elseif card.kind == "passive" then
		local def = findPassiveDef(card.passiveId)
		if not def then
			return false, 0, nil
		end
		if def.attribute == "HasDoubleJump" then
			build.hasDoubleJump = true
		elseif def.attribute == "HasDoubleDash" then
			build.hasDoubleDash = true
		elseif def.attribute == "HasDashBoost" then
			build.hasDashBoost = true
		elseif def.attribute == "HasSwiftDash" then
			build.hasSwiftDash = true
		end
	else
		return false, 0, nil
	end

	table.remove(build.queue, 1)
	sanitizeHeadOffer(build)
	return true, healDelta, card
end

-- Auto-resolves every remaining queued offer randomly (used when exiting a floor).
function UpgradePool.autoResolveAll(build: PlayerBuild, rng: (() -> number)?): number
	local rand = rng or math.random
	local totalHeal = 0
	local guard = 0
	while #build.queue > 0 and guard < 64 do
		guard += 1
		local offer = build.queue[1]
		local cardIdx = math.clamp(math.floor(rand() * #offer.cards) + 1, 1, #offer.cards)
		local slotIdx = math.clamp(math.floor(rand() * Config.ABILITY_SLOTS) + 1, 1, Config.ABILITY_SLOTS)
		local ok, heal = UpgradePool.applyPick(build, offer.offerId, cardIdx, slotIdx)
		if ok then
			totalHeal += heal
		else
			table.remove(build.queue, 1)
		end
	end
	return totalHeal
end

--=============================================================================
-- Direct build editing helpers (used by admin DebugService)
--=============================================================================

-- Assigns `abilityId` at `level` (1..ABILITY_MAX_LEVEL) into `slot` (1..ABILITY_SLOTS), keeping
-- `build.slots` compact (no nil holes) and preventing duplicate abilities across slots.
function UpgradePool.setSlot(build: PlayerBuild, slot: number, abilityId: string, level: number?): boolean
	if slot < 1 or slot > Config.ABILITY_SLOTS or math.floor(slot) ~= slot then
		return false
	end
	if table.find(Config.UPGRADE_ABILITY_ORDER, abilityId) == nil then
		return false
	end
	local clampedLevel = math.clamp(math.floor(level or 1), 1, Config.ABILITY_MAX_LEVEL)

	local existingSlot = UpgradePool.slotOf(build, abilityId)
	if existingSlot == slot then
		build.levels[abilityId] = clampedLevel
		return true
	end
	if existingSlot then
		table.remove(build.slots, existingSlot)
		if existingSlot < slot then
			slot = math.max(1, slot - 1)
		end
	end

	if slot <= #build.slots then
		local oldId = build.slots[slot]
		if oldId and oldId ~= abilityId then
			build.levels[oldId] = nil
		end
		build.slots[slot] = abilityId
	else
		table.insert(build.slots, abilityId)
	end
	build.levels[abilityId] = clampedLevel
	return true
end

function UpgradePool.clearSlot(build: PlayerBuild, slot: number): boolean
	if slot < 1 or slot > Config.ABILITY_SLOTS or math.floor(slot) ~= slot then
		return false
	end
	local oldId = build.slots[slot]
	if not oldId then
		return true
	end
	build.levels[oldId] = nil
	table.remove(build.slots, slot)
	return true
end

function UpgradePool.applyStatDirect(build: PlayerBuild, statId: string, count: number?): (boolean, number)
	local def = findStatDef(statId)
	if not def then
		return false, 0
	end
	local n = math.clamp(math.floor(count or 1), 1, 10)
	local healDelta = 0
	for _ = 1, n do
		if def.stat == "maxHealth" then
			build.maxHealthBonus += def.amount
			healDelta += def.amount
		elseif def.stat == "damage" then
			build.damageBonus += def.amount
		elseif def.stat == "speed" then
			build.speedBonus += def.amount
		elseif def.stat == "cooldown" then
			build.cooldownMult = math.max(build.cooldownMult * (1 - def.amount), Config.MIN_COOLDOWN_MULTIPLIER)
		end
	end
	return true, healDelta
end

function UpgradePool.setPassiveDirect(build: PlayerBuild, passiveId: string, enabled: boolean): boolean
	local def = findPassiveDef(passiveId)
	if not def then
		return false
	end
	if def.attribute == "HasDoubleJump" then
		build.hasDoubleJump = enabled == true
		return true
	elseif def.attribute == "HasDoubleDash" then
		build.hasDoubleDash = enabled == true
		return true
	end
	return false
end

--=============================================================================
-- Self test
--=============================================================================

function UpgradePool.selfTest()
	local seed = 0.13
	local function detRng(): number
		seed = (seed * 7.31 + 0.29) % 1
		return seed
	end

	-- Starter offer yields 3 distinct active abilities.
	local build = UpgradePool.initial()
	local starter = UpgradePool.rollStarter(build, detRng)
	assert(#starter.cards == 3 and starter.isStarter, "starter rolls 3 active abilities")
	assert(starter.cards[1].id ~= starter.cards[2].id and starter.cards[2].id ~= starter.cards[3].id, "starter cards are distinct")

	UpgradePool.enqueue(build, starter)
	assert(UpgradePool.currentOffer(build) == starter and UpgradePool.pendingBehind(build) == 0, "queue head matches")

	-- Reject wrong offerId and out-of-range index.
	local badOk = UpgradePool.applyPick(build, 999, 1)
	assert(not badOk, "wrong offerId rejected")
	local badIdx = UpgradePool.applyPick(build, starter.offerId, 4)
	assert(not badIdx, "out-of-range cardIndex rejected")

	-- Picking starter equips slot 1 at Lv.1.
	local ok1 = UpgradePool.applyPick(build, starter.offerId, 1)
	assert(ok1 and #build.slots == 1 and build.levels[build.slots[1]] == 1, "starter equips slot 1 at Lv.1")

	-- Queue multiple room offers without pausing.
	local o2 = UpgradePool.rollRoomOffer(build, detRng)
	local o3 = UpgradePool.rollRoomOffer(build, detRng)
	UpgradePool.enqueue(build, o2)
	UpgradePool.enqueue(build, o3)
	assert(UpgradePool.pendingBehind(build) == 1, "two queued offers report +1 behind head")

	-- Fill all 3 slots, then verify replaceAbility requires a valid slot 1..3.
	build.slots = { "spin", "stinger", "overdrive" }
	build.levels = { spin = 1, stinger = 1, overdrive = 1 }
	table.clear(build.queue)
	local replaceOffer: Offer = {
		offerId = 50,
		isStarter = false,
		cards = { makeAbilityCard("healPulse", "replaceAbility", 1) },
	}
	UpgradePool.enqueue(build, replaceOffer)
	assert(not UpgradePool.applyPick(build, 50, 1, nil), "replaceAbility requires a slot index")
	assert(UpgradePool.applyPick(build, 50, 1, 2), "replaceAbility swaps slot 2 cleanly")
	assert(build.slots[2] == "healPulse" and build.levels.healPulse == 1 and build.levels.stinger == nil, "slot 2 swapped cleanly")

	-- Floor-exit auto-resolve drains the entire queue cleanly.
	UpgradePool.enqueue(build, UpgradePool.rollRoomOffer(build, detRng))
	UpgradePool.enqueue(build, UpgradePool.rollRoomOffer(build, detRng))
	UpgradePool.autoResolveAll(build, detRng)
	assert(#build.queue == 0, "autoResolveAll empties the queue")

	-- Level scaling math and honest upgrade copy per ability type.
	local d1, c1 = UpgradePool.levelMultipliers(1)
	local d3, c3 = UpgradePool.levelMultipliers(3)
	assert(d1 == 1 and c1 == 1 and d3 > d1 and c3 < c1, "ability levels boost damage and lower cooldown")
	assert(string.find(makeAbilityCard("bulwark", "upgradeAbility", 2).effect, "duración") ~= nil, "bulwark level copy mentions duration")
	assert(string.find(makeAbilityCard("protectField", "upgradeAbility", 2).effect, "duración") ~= nil, "protectField level copy mentions duration")
	assert(string.find(makeAbilityCard("healPulse", "upgradeAbility", 2).effect, "curación") ~= nil, "healPulse level copy mentions healing")
	assert(string.find(makeAbilityCard("spin", "upgradeAbility", 2).effect, "daño") ~= nil, "spin level copy mentions damage")

	-- Queued duplicate passive sanitization: picking Double Jump from Offer 1 replaces the
	-- now-redundant Double Jump card in Offer 2 with a fresh stat card so no pick is wasted.
	local qBuild = UpgradePool.initial()
	qBuild.slots = { "spin", "stinger", "overdrive" }
	qBuild.levels = { spin = Config.ABILITY_MAX_LEVEL, stinger = 1, overdrive = 1 }
	local djDef = Config.PASSIVE_UPGRADES[1]
	UpgradePool.enqueue(qBuild, {
		offerId = 101,
		isStarter = false,
		cards = { makePassiveCard(djDef), makeStatCard(Config.STAT_UPGRADES[1]), makeStatCard(Config.STAT_UPGRADES[2]) },
	})
	UpgradePool.enqueue(qBuild, {
		offerId = 102,
		isStarter = false,
		cards = {
			makePassiveCard(djDef),
			makeAbilityCard("spin", "upgradeAbility", 4),
			makeStatCard(Config.STAT_UPGRADES[1]),
		},
	})
	assert(UpgradePool.applyPick(qBuild, 101, 1), "picks Double Jump from Offer 1")
	local nextHead = UpgradePool.currentOffer(qBuild)
	assert(nextHead ~= nil and nextHead.offerId == 102, "Offer 2 becomes head")
	assert(nextHead.cards[1].kind == "stat", "redundant Double Jump in Offer 2 converted to stat card")
	assert(nextHead.cards[2].kind == "stat", "already-maxed spin upgrade in Offer 2 converted to stat card")

	-- HS-14 expanded synergies & Lv.4 scaling: crit, life-on-kill, heavy haste, parry bonus, dash passives.
	local d4, c4 = UpgradePool.levelMultipliers(4)
	assert(d4 > d3 and c4 < c3, "Lv.4 evolution rank scales beyond Lv.3")
	assert(UpgradePool.critMultiplier(0.3, 0.1) > 1 and UpgradePool.critMultiplier(0.3, 0.9) == 1, "critMultiplier rolls cleanly")
	local synBuild = UpgradePool.initial()
	UpgradePool.enqueue(synBuild, {
		offerId = 201,
		isStarter = false,
		cards = {
			makeStatCard(findStatDef("stat_crit") :: Config.StatUpgradeDef),
			makeStatCard(findStatDef("stat_lifesteal") :: Config.StatUpgradeDef),
			makePassiveCard(findPassiveDef("passive_dash_boost") :: Config.PassiveUpgradeDef),
		},
	})
	assert(UpgradePool.applyPick(synBuild, 201, 1) and synBuild.critChance == 0.15, "crit card boosts critChance")
	UpgradePool.enqueue(synBuild, {
		offerId = 202,
		isStarter = false,
		cards = {
			makeStatCard(findStatDef("stat_heavy_haste") :: Config.StatUpgradeDef),
			makeStatCard(findStatDef("stat_parry") :: Config.StatUpgradeDef),
			makePassiveCard(findPassiveDef("passive_swift_dash") :: Config.PassiveUpgradeDef),
		},
	})
	assert(UpgradePool.applyPick(synBuild, 202, 3) and synBuild.hasSwiftDash, "swift dash passive activates cleanly")

	-- Direct debug build-editing helpers.
	local dbg = UpgradePool.initial()
	assert(UpgradePool.setSlot(dbg, 1, "spin", 2), "setSlot equips spin Lv.2")
	assert(dbg.slots[1] == "spin" and dbg.levels.spin == 2, "slot 1 holds spin Lv.2")
	assert(UpgradePool.setSlot(dbg, 2, "overdrive", 3), "setSlot equips overdrive Lv.3")
	assert(UpgradePool.setSlot(dbg, 1, "overdrive", 3), "moving owned ability deduplicates slots")
	assert(#dbg.slots == 1 and dbg.slots[1] == "overdrive", "no duplicate ability across slots")
	assert(UpgradePool.clearSlot(dbg, 1) and #dbg.slots == 0 and dbg.levels.overdrive == nil, "clearSlot removes ability cleanly")
	local statOk, heal = UpgradePool.applyStatDirect(dbg, "stat_hp", 2)
	assert(statOk and heal == 50 and dbg.maxHealthBonus == 50, "applyStatDirect stacks HP bonus and heal")
	assert(UpgradePool.setPassiveDirect(dbg, "passive_double_jump", true) and dbg.hasDoubleJump, "setPassiveDirect enables double jump")
	assert(UpgradePool.setPassiveDirect(dbg, "passive_double_jump", false) and not dbg.hasDoubleJump, "setPassiveDirect disables double jump")
end

return UpgradePool
