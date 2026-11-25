--!strict
--[[
	Pure rules for enemy combat drops and the temporary buffs they grant: rolling the 30% drop
	chance, picking a weighted kind (heal / damage / speed), computing healed health, and
	resolving active damage and speed multipliers.

	Pure so `make test` verifies the exact probability threshold and buff expiry math offline.
	See docs/combat.md.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local Drops = {}

export type DropKind = "heal" | "damage" | "speed"

-- Deterministic order so weighted rolls do not depend on `pairs` iteration order.
local KINDS: { DropKind } = { "heal", "damage", "speed" }

-- Rolls whether a defeated enemy drops an item and which kind. `chanceRoll` and `kindRoll` are
-- uniform values in [0, 1). Returns nil when `chanceRoll >= dropChance`.
function Drops.roll(
	chanceRoll: number,
	kindRoll: number,
	dropChance: number,
	weights: { [string]: number }
): DropKind?
	if dropChance <= 0 or chanceRoll >= dropChance then
		return nil
	end

	local total = 0
	for _, kind in ipairs(KINDS) do
		local w = weights[kind] or 0
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil
	end

	local target = math.clamp(kindRoll, 0, 0.999999) * total
	local cursor = 0
	for _, kind in ipairs(KINDS) do
		local w = weights[kind] or 0
		if w > 0 then
			cursor += w
			if target < cursor then
				return kind
			end
		end
	end
	return KINDS[#KINDS]
end

-- Returns `(newHealth, healed)`. A full-health player returns `healed = false` so the drop stays
-- on the floor for later or for a wounded teammate.
function Drops.heal(health: number, maxHealth: number, amount: number): (number, boolean)
	if health <= 0 or health >= maxHealth or amount <= 0 then
		return health, false
	end
	return math.min(health + amount, maxHealth), true
end

-- Damage multiplier while `now < buffUntil`, otherwise 1.
function Drops.damageMultiplier(buffUntil: any, now: number, multiplier: number): number
	if type(buffUntil) == "number" and now < buffUntil then
		return multiplier
	end
	return 1
end

-- WalkSpeed while `now < buffUntil`, otherwise `baseSpeed`.
function Drops.moveSpeed(baseSpeed: number, buffUntil: any, now: number, multiplier: number): number
	if type(buffUntil) == "number" and now < buffUntil then
		return baseSpeed * multiplier
	end
	return baseSpeed
end

-- Remaining fraction in [0, 1] for HUD buff bars; 0 once expired.
function Drops.buffRemaining(buffUntil: any, duration: number, now: number): number
	if type(buffUntil) ~= "number" or duration <= 0 then
		return 0
	end
	return math.clamp((buffUntil - now) / duration, 0, 1)
end

--=============================================================================
-- Self test
--=============================================================================

function Drops.selfTest()
	-- Drop probability gate (30% default in Config.DROP_CHANCE).
	assert(Config.DROP_CHANCE > 0 and Config.DROP_CHANCE < 1, "DROP_CHANCE must be a fraction between 0 and 1")
	assert(math.abs(Config.DROP_CHANCE - 0.30) < 1e-6, "DROP_CHANCE defaults to 30%")

	local weights = { heal = 40, damage = 30, speed = 30 }
	assert(Drops.roll(0.30, 0.1, 0.30, weights) == nil, "roll at threshold does not drop")
	assert(Drops.roll(0.85, 0.1, 0.30, weights) == nil, "high roll does not drop")
	assert(Drops.roll(0.0, 0.0, 0.30, weights) == "heal", "low kindRoll picks heal")
	assert(Drops.roll(0.29, 0.39, 0.30, weights) == "heal", "just below heal boundary picks heal")
	assert(Drops.roll(0.29, 0.45, 0.30, weights) == "damage", "mid kindRoll picks damage")
	assert(Drops.roll(0.29, 0.75, 0.30, weights) == "speed", "high kindRoll picks speed")

	-- Heal does not waste a pickup at full health and clamps at MaxHealth.
	local hpFull, didFull = Drops.heal(100, 100, 25)
	assert(hpFull == 100 and not didFull, "full-health player does not consume heal drop")
	local hpDead, didDead = Drops.heal(0, 100, 25)
	assert(hpDead == 0 and not didDead, "dead player does not consume heal drop")
	local hpMid, didMid = Drops.heal(60, 100, 25)
	assert(hpMid == 85 and didMid, "wounded player heals by DROP_HEAL_AMOUNT")
	local hpCap, didCap = Drops.heal(90, 100, 25)
	assert(hpCap == 100 and didCap, "heal clamps at maxHealth")

	-- Damage & speed buffs apply before expiry and drop cleanly at expiry.
	assert(Drops.damageMultiplier(20, 15, 1.5) == 1.5, "active damage buff multiplies damage")
	assert(Drops.damageMultiplier(20, 20, 1.5) == 1, "expired damage buff returns 1")
	assert(Drops.damageMultiplier(nil, 10, 1.5) == 1, "missing damage buff returns 1")

	assert(math.abs(Drops.moveSpeed(26, 20, 15, 1.35) - 26 * 1.35) < 1e-6, "active speed buff boosts WalkSpeed")
	assert(Drops.moveSpeed(26, 20, 21, 1.35) == 26, "expired speed buff restores base WalkSpeed")

	-- HUD remaining fraction.
	assert(math.abs(Drops.buffRemaining(20, 10, 15) - 0.5) < 1e-6, "halfway through buff reports 0.5")
	assert(Drops.buffRemaining(20, 10, 25) == 0, "expired buff reports 0")

	-- Every kind has a configured model name.
	for _, kind in ipairs(KINDS) do
		assert(type(Config.DROP_MODELS[kind]) == "string" and #Config.DROP_MODELS[kind] > 0, `missing DROP_MODELS.{kind}`)
	end
end

return Drops
