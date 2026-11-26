--!strict
--[[
	Pure combat defense rules: Dash i-frames, Parry window, Guard block reduction, and the 50%
	Defense map buff — plus effective WalkSpeed when combining speed buff with blocking slowdown.

	Pure so `make test` asserts damage priority (`invulnerable > parry > block > hit`) and
	stacking math without needing Studio. See docs/combat.md.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local Defense = {}

export type HitOutcome = "invulnerable" | "parry" | "block" | "hit"

export type HitContext = {
	now: number,
	invulnerableUntil: any,
	blocking: boolean,
	parryUntil: any,
	defenseBuffUntil: any,
	canDodge: boolean?,
	canBlock: boolean?,
	canParry: boolean?,
	blockReduction: number,
	defenseReduction: number,
}

-- Resolves incoming damage against Dash i-frames, Parry window, Block guard, and Defense buff.
function Defense.resolveHit(rawDamage: number, ctx: HitContext): (number, HitOutcome)
	if rawDamage <= 0 then
		return 0, "hit"
	end
	local canDodge = if ctx.canDodge ~= nil then ctx.canDodge else true
	if canDodge and type(ctx.invulnerableUntil) == "number" and ctx.now < ctx.invulnerableUntil then
		return 0, "invulnerable"
	end

	local canParry = if ctx.canParry ~= nil then ctx.canParry else true
	if canParry and ctx.blocking and type(ctx.parryUntil) == "number" and ctx.now < ctx.parryUntil then
		return 0, "parry"
	end

	local defenseFactor = 1
	if type(ctx.defenseBuffUntil) == "number" and ctx.now < ctx.defenseBuffUntil then
		defenseFactor = math.clamp(1 - ctx.defenseReduction, 0, 1)
	end

	local canBlock = if ctx.canBlock ~= nil then ctx.canBlock else true
	if canBlock and ctx.blocking then
		local blockFactor = math.clamp(1 - ctx.blockReduction, 0, 1)
		return rawDamage * blockFactor * defenseFactor, "block"
	end

	return rawDamage * defenseFactor, "hit"
end

-- Computes WalkSpeed combining base speed, speed buff, blocking slowdown, heavy-attack charge
-- slowdown, grab lock, and seismic stun lock.
function Defense.walkSpeed(
	baseSpeed: number,
	speedBuffUntil: any,
	blocking: boolean,
	grabbed: boolean,
	now: number,
	speedMultiplier: number,
	blockMultiplier: number,
	charging: boolean?,
	chargeMultiplier: number?,
	stunned: boolean?
): number
	if grabbed or stunned then
		return 0
	end
	local speed = baseSpeed
	if type(speedBuffUntil) == "number" and now < speedBuffUntil then
		speed *= speedMultiplier
	end
	if blocking then
		speed *= blockMultiplier
	elseif charging then
		speed *= (chargeMultiplier or 1)
	end
	return speed
end

--=============================================================================
-- Self test
--=============================================================================

function Defense.selfTest()
	local base: HitContext = {
		now = 10,
		invulnerableUntil = 0,
		blocking = false,
		parryUntil = 0,
		defenseBuffUntil = 0,
		canBlock = true,
		canParry = true,
		blockReduction = Config.BLOCK_DAMAGE_REDUCTION,
		defenseReduction = Config.BUFF_DEFENSE_REDUCTION,
	}

	-- Normal unmitigated hit.
	local dmg, out = Defense.resolveHit(20, base)
	assert(dmg == 20 and out == "hit", "unmitigated hit takes full damage")

	-- Dash i-frames beat everything.
	local dashCtx = table.clone(base)
	dashCtx.invulnerableUntil = 10.2
	dashCtx.blocking = true
	dashCtx.parryUntil = 10.2
	dmg, out = Defense.resolveHit(20, dashCtx)
	assert(dmg == 0 and out == "invulnerable", "dash i-frames take priority and deal 0")

	-- Perfect Parry negates 100% damage.
	local parryCtx = table.clone(base)
	parryCtx.blocking = true
	parryCtx.parryUntil = 10.2
	dmg, out = Defense.resolveHit(20, parryCtx)
	assert(dmg == 0 and out == "parry", "parry inside PARRY_WINDOW deals 0")

	-- Normal Block (after Parry window) cuts damage by BLOCK_DAMAGE_REDUCTION (70%).
	local blockCtx = table.clone(base)
	blockCtx.blocking = true
	blockCtx.parryUntil = 9.5
	dmg, out = Defense.resolveHit(20, blockCtx)
	assert(math.abs(dmg - 20 * (1 - Config.BLOCK_DAMAGE_REDUCTION)) < 1e-6 and out == "block", "block reduces damage by 70%")

	-- 50% Defense buff halves unblocked damage and stacks with Block.
	local defCtx = table.clone(base)
	defCtx.defenseBuffUntil = 20
	dmg, out = Defense.resolveHit(20, defCtx)
	assert(math.abs(dmg - 10) < 1e-6 and out == "hit", "50% defense buff halves damage")

	local bothCtx = table.clone(blockCtx)
	bothCtx.defenseBuffUntil = 20
	dmg, out = Defense.resolveHit(20, bothCtx)
	assert(math.abs(dmg - 20 * (1 - Config.BLOCK_DAMAGE_REDUCTION) * 0.5) < 1e-6 and out == "block", "defense buff stacks with block")

	-- Unblockable grab drain still benefits from the 50% Defense buff.
	local grabCtx = table.clone(defCtx)
	grabCtx.blocking = true
	grabCtx.parryUntil = 11
	grabCtx.canBlock = false
	grabCtx.canParry = false
	dmg, out = Defense.resolveHit(8, grabCtx)
	assert(math.abs(dmg - 4) < 1e-6 and out == "hit", "unblockable drain ignores guard but keeps 50% defense buff")

	-- Parry-only Paso Fantasma strike: bypasses Dash i-frames and passive Block, countered only by Parry.
	local phantomDashCtx = table.clone(base)
	phantomDashCtx.invulnerableUntil = 10.5
	phantomDashCtx.canDodge = false
	phantomDashCtx.canBlock = false
	phantomDashCtx.canParry = true
	dmg, out = Defense.resolveHit(15, phantomDashCtx)
	assert(dmg == 15 and out == "hit", "parry-only strike bypasses dash i-frames")

	local phantomBlockCtx = table.clone(phantomDashCtx)
	phantomBlockCtx.blocking = true
	phantomBlockCtx.parryUntil = 9.5
	dmg, out = Defense.resolveHit(15, phantomBlockCtx)
	assert(dmg == 15 and out == "hit", "parry-only strike bypasses passive block outside parry window")

	local phantomParryCtx = table.clone(phantomDashCtx)
	phantomParryCtx.blocking = true
	phantomParryCtx.parryUntil = 10.2
	dmg, out = Defense.resolveHit(15, phantomParryCtx)
	assert(dmg == 0 and out == "parry", "parry negates parry-only strike completely")

	-- WalkSpeed combinations.
	assert(Defense.walkSpeed(26, 0, false, true, 10, 1.35, 0.55) == 0, "grabbed player has 0 WalkSpeed")
	assert(Defense.walkSpeed(26, 20, false, false, 10, 1.35, 0.55, false, 1, true) == 0, "stunned player has 0 WalkSpeed")
	assert(math.abs(Defense.walkSpeed(26, 0, true, false, 10, 1.35, 0.55) - 26 * 0.55) < 1e-6, "blocking slows WalkSpeed")
	assert(math.abs(Defense.walkSpeed(26, 20, true, false, 10, 1.35, 0.55) - 26 * 1.35 * 0.55) < 1e-6, "speed buff stacks with blocking")
	assert(
		math.abs(Defense.walkSpeed(26, 0, false, false, 10, 1.35, 0.55, true, 0.6) - 26 * 0.6) < 1e-6,
		"charging heavy attack slows WalkSpeed"
	)
end

return Defense
