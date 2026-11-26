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

export type DropKind = "heal" | "damage" | "speed" | "defense"

-- Deterministic order for enemy-kill drops (defense spawns periodically on the map instead).
local KINDS: { DropKind } = { "heal", "damage", "speed" }
local ALL_KINDS: { DropKind } = { "heal", "damage", "speed", "defense" }

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

-- Damage intake factor while `now < buffUntil` (e.g. 0.5 for 50% defense), otherwise 1.
function Drops.defenseFactor(buffUntil: any, now: number, reduction: number): number
	if type(buffUntil) == "number" and now < buffUntil then
		return math.clamp(1 - reduction, 0, 1)
	end
	return 1
end

-- Remaining fraction in [0, 1] for HUD buff bars; 0 once expired.
function Drops.buffRemaining(buffUntil: any, duration: number, now: number): number
	if type(buffUntil) ~= "number" or duration <= 0 then
		return 0
	end
	return math.clamp((buffUntil - now) / duration, 0, 1)
end

-- Maximum Dash charges: 2 while the Speed Buff is active, 1 normally.
function Drops.maxDashCharges(speedBuffUntil: any, now: number): number
	if type(speedBuffUntil) == "number" and now < speedBuffUntil then
		return 2
	end
	return 1
end

-- Refills elapsed Dash charges up to `maxCharges` and attempts to consume 1 charge.
-- Returns `(allowed, nextCharges, nextRechargeAt)`.
function Drops.consumeDash(
	charges: number,
	rechargeAt: number,
	maxCharges: number,
	now: number,
	cooldown: number,
	slack: number?
): (boolean, number, number)
	local cap = math.max(maxCharges, 1)
	local cur = charges
	local nextAt = rechargeAt
	local tol = slack or 0

	if cur < cap and nextAt > 0 and now >= nextAt - tol then
		local step = math.max(cooldown, 1e-3)
		local gained = 1 + math.floor(math.max(now - nextAt, 0) / step)
		cur = math.min(cap, cur + gained)
		nextAt = if cur >= cap then 0 else nextAt + gained * step
	elseif cur < cap and nextAt <= 0 then
		cur = cap
	end
	if cur > cap then
		cur = cap
	end
	if cur >= cap then
		nextAt = 0
	end

	if cur <= 0 then
		return false, 0, nextAt
	end

	local remaining = cur - 1
	local outRecharge = if nextAt > 0 and now < nextAt then nextAt else now + cooldown
	return true, remaining, outRecharge
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
	assert(math.abs(Drops.defenseFactor(20, 15, 0.50) - 0.5) < 1e-6, "active 50% defense buff halves damage")
	assert(Drops.defenseFactor(20, 20, 0.50) == 1, "expired defense buff returns 1")

	-- HUD remaining fraction.
	assert(math.abs(Drops.buffRemaining(20, 10, 15) - 0.5) < 1e-6, "halfway through buff reports 0.5")
	assert(Drops.buffRemaining(20, 10, 25) == 0, "expired buff reports 0")

	-- Speed buff grants 2 Dash charges; without it only 1 Dash is allowed per cooldown.
	assert(Drops.maxDashCharges(0, 10) == 1, "base dash charges is 1")
	assert(Drops.maxDashCharges(20, 10) == 2, "active speed buff grants 2 dash charges")
	assert(Drops.maxDashCharges(10, 10) == 1, "expired speed buff drops back to 1 dash charge")

	local ok1, c1, r1 = Drops.consumeDash(1, 0, 1, 10, 0.7, 0)
	assert(ok1 and c1 == 0 and math.abs(r1 - 10.7) < 1e-6, "single dash consumes sole charge")
	local ok2, c2 = Drops.consumeDash(c1, r1, 1, 10.2, 0.7, 0)
	assert(not ok2 and c2 == 0, "second dash without speed buff is refused during cooldown")

	-- With speed buff active (2 charges), two back-to-back dashes succeed and a third waits.
	local sOk1, sC1, sR1 = Drops.consumeDash(2, 0, 2, 10.0, 0.7, 0)
	assert(sOk1 and sC1 == 1 and math.abs(sR1 - 10.7) < 1e-6, "first speed-buff dash leaves 1 charge")
	local sOk2, sC2, sR2 = Drops.consumeDash(sC1, sR1, 2, 10.2, 0.7, 0)
	assert(sOk2 and sC2 == 0 and math.abs(sR2 - 10.7) < 1e-6, "second immediate dash consumes 2nd charge")
	local sOk3, sC3 = Drops.consumeDash(sC2, sR2, 2, 10.4, 0.7, 0)
	assert(not sOk3 and sC3 == 0, "third dash waits for recharge")
	local sOk4, sC4 = Drops.consumeDash(sC2, sR2, 2, 10.75, 0.7, 0)
	assert(sOk4 and sC4 == 0, "recharged dash succeeds at 10.75")

	-- Every kind has a configured model name.
	for _, kind in ipairs(ALL_KINDS) do
		assert(type(Config.DROP_MODELS[kind]) == "string" and #Config.DROP_MODELS[kind] > 0, `missing DROP_MODELS.{kind}`)
	end
end

return Drops
