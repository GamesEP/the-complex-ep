--!strict
--[[
	Pure Co-op Downed & Ally Revive rules (`plans/gdd/systems.md`, `plans/roadmap.md HS-04 / HS-28`).

	No Roblox services:
	  - Solo player (0 standing teammates) triggers immediate squad wipe.
	  - In 2-4 player co-op, lethal damage puts the player into `Downed` while >= 1 teammate stands.
	  - Standing within `Config.ALLY_REVIVE_RADIUS` (8 studs) channels for `Config.ALLY_REVIVE_SECONDS`
	    (5 s) to revive at `Config.ALLY_REVIVE_HEALTH_FRACTION` (50%) HP.
	  - Normal damage on the rescuer does NOT reset the channel (`HS-04`); only leaving the radius,
	    getting hard-stunned, grabbed, or downed interrupts and resets progress to 0.
	  - `resolveWipe(onWipeOffer)` provides a clean extension hook for future monetization/wipe offers
	    while going straight to `"defeat"` in Phase 2.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local ReviveRules = {}

export type MemberStatus = {
	standing: boolean,
}

function ReviveRules.canEnterDowned(standingOtherCount: number): boolean
	return standingOtherCount >= 1
end

function ReviveRules.inReviveRadius(rescuerPos: Vector3, downedPos: Vector3, radius: number?): boolean
	local r = radius or Config.ALLY_REVIVE_RADIUS
	local dx = rescuerPos.X - downedPos.X
	local dz = rescuerPos.Z - downedPos.Z
	return dx * dx + dz * dz <= r * r
end

-- Returns true if a teammate qualifies to channel a revive this tick.
-- Taking normal damage does NOT disqualify the rescuer (`HS-04`); only leaving the radius,
-- going down, being hard-stunned, or being grabbed interrupts the channel.
function ReviveRules.isValidRescuer(
	rescuerPos: Vector3,
	downedPos: Vector3,
	rescuerDowned: boolean,
	rescuerStunned: boolean,
	rescuerGrabbed: boolean,
	radius: number?
): boolean
	if rescuerDowned or rescuerStunned or rescuerGrabbed then
		return false
	end
	return ReviveRules.inReviveRadius(rescuerPos, downedPos, radius)
end

-- Advances a downed player's revive progress (`0..1`). Resets to `0` immediately when no valid
-- rescuer remains inside the ring (`HS-04`). Returns `(nextProgress, completed)`.
function ReviveRules.stepChannel(
	currentProgress: number,
	dt: number,
	validHelperCount: number,
	reviveSeconds: number?,
	extraHelperBonus: number?
): (number, boolean)
	if validHelperCount <= 0 then
		return 0, false
	end
	local duration = math.max(reviveSeconds or Config.ALLY_REVIVE_SECONDS, 0.1)
	local bonus = extraHelperBonus or Config.ALLY_REVIVE_EXTRA_HELPER_BONUS
	local rate = 1 + math.max(validHelperCount - 1, 0) * bonus
	local nextProgress = math.clamp(currentProgress + (dt * rate) / duration, 0, 1)
	return nextProgress, nextProgress >= 1
end

function ReviveRules.reviveHealth(maxHealth: number, fraction: number?): number
	local f = fraction or Config.ALLY_REVIVE_HEALTH_FRACTION
	return math.max(1, math.round(maxHealth * f))
end

function ReviveRules.isSquadWiped(members: { MemberStatus }): boolean
	if #members == 0 then
		return false
	end
	for _, m in ipairs(members) do
		if m.standing then
			return false
		end
	end
	return true
end

-- Extension point for future wipe-revive offer flow (`HS-04` / `HS-28`).
-- In Phase 2 (`onWipeOffer == nil`), always resolves straight to `"defeat"`.
function ReviveRules.resolveWipe(onWipeOffer: (() -> string)?): string
	if onWipeOffer then
		local decision = onWipeOffer()
		if type(decision) == "string" and decision ~= "" then
			return decision
		end
	end
	return "defeat"
end

--=============================================================================
-- Self test
--=============================================================================

function ReviveRules.selfTest()
	-- 1. Solo instant wipe vs co-op downed transition.
	assert(not ReviveRules.canEnterDowned(0), "solo player (0 standing teammates) cannot enter downed")
	assert(ReviveRules.canEnterDowned(1), "2-player squad allows downed when 1 teammate stands")
	assert(ReviveRules.canEnterDowned(3), "4-player squad allows downed when teammates stand")

	-- 2. Rescuer proximity & interruption rules (stun/grab/downed/distance interrupt; normal damage does not).
	local downedPos = Vector3.new(10, 0, 10)
	local nearPos = Vector3.new(10 + Config.ALLY_REVIVE_RADIUS - 0.5, 0, 10)
	local farPos = Vector3.new(10 + Config.ALLY_REVIVE_RADIUS + 1.0, 0, 10)
	assert(ReviveRules.isValidRescuer(nearPos, downedPos, false, false, false), "standing ally inside 8 studs channels")
	assert(not ReviveRules.isValidRescuer(farPos, downedPos, false, false, false), "ally outside 8 studs cannot channel")
	assert(not ReviveRules.isValidRescuer(nearPos, downedPos, true, false, false), "downed ally cannot channel")
	assert(not ReviveRules.isValidRescuer(nearPos, downedPos, false, true, false), "hard-stunned ally interrupts channel")
	assert(not ReviveRules.isValidRescuer(nearPos, downedPos, false, false, true), "grabbed ally interrupts channel")

	-- 3. Exact 5 s channel completion with 1 helper, reset on 0 helpers, faster with 2 helpers.
	local prog, done = ReviveRules.stepChannel(0, 2.5, 1, 5, 0.35)
	assert(math.abs(prog - 0.5) < 1e-5 and not done, "halfway at 2.5s / 5s")
	local resetProg, resetDone = ReviveRules.stepChannel(prog, 0.1, 0, 5, 0.35)
	assert(resetProg == 0 and not resetDone, "leaving radius resets channel progress to 0")
	local finishProg, finishDone = ReviveRules.stepChannel(0.5, 2.5, 1, 5, 0.35)
	assert(finishProg == 1 and finishDone, "completes cleanly at 5s")

	local duoProg = ReviveRules.stepChannel(0, 2.5, 2, 5, 0.35)
	assert(duoProg > 0.5, "second helper speeds up revive")

	-- 4. Revive health restoration (50%).
	assert(ReviveRules.reviveHealth(100) == 50, "restores 50% of 100 HP")
	assert(ReviveRules.reviveHealth(140) == 70, "restores 50% of 140 HP")

	-- 5. Simultaneous all-downed wipe detection & extension hook.
	assert(not ReviveRules.isSquadWiped({ { standing = true }, { standing = false } }), "not wiped while 1 stands")
	assert(ReviveRules.isSquadWiped({ { standing = false }, { standing = false } }), "wiped when all members are downed")
	assert(ReviveRules.resolveWipe(nil) == "defeat", "default wipe hook goes straight to defeat in Phase 2")
	assert(ReviveRules.resolveWipe(function()
		return "revived"
	end) == "revived", "custom wipe offer hook can override decision")
end

return ReviveRules
