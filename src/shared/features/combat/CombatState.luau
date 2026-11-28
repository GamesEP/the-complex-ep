--!strict
--[[
	Pure player combat state machine and attack-movement rules shared by client and server.

	Owns the single source of truth for:
	- Movement removal during Startup / Active / Lunge / Ability / Hitstop / Dash / CC (WalkSpeed=0,
	  AutoRotate=false so only the attack/ability motion moves the character).
	- Opposite-direction lunge abort (`shouldAbortLunge`).
	- Startup micro-pivot aim clamping (`microPivot`).
	- Hit-confirm vs. whiff cancel timing and hitstop durations (`effectiveCancelAt`, `hitstopDuration`).
	- Recovery move-cancel gating (`canMoveCancel`).
	- Incoming-hit interruption & poise rules (`shouldCancelHeavyCharge`, `shouldInterruptByHit`),
	  where only heavy attacks and CC interrupt HeavyCharge while light hits preserve poise.

	Pure so `make test` asserts every branch and combination without Studio. See docs/combat.md.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)
local Melee = require(script.Parent.Melee)

local CombatState = {}

export type Phase =
	"locomotion"
	| "lunge"
	| "startup"
	| "active"
	| "hitstop"
	| "recovery"
	| "charge"
	| "ability"
	| "dash"
	| "guard"
	| "parryCounter"
	| "stunned"
	| "knockback"
	| "grabbed"
	| "dead"

export type HitTier = "light" | "medium" | "heavy"

export type MovementPolicy = {
	allowMoveInput: boolean,
	autoRotate: boolean,
	speedScale: number,
}

export type IncomingHit = {
	heavy: boolean?,
	stuns: boolean?,
	knocksBack: boolean?,
	grabs: boolean?,
	parryOnly: boolean?,
	lethal: boolean?,
	outcome: string?,
}

export type InterruptResult = "none" | "flinch" | "stunned" | "knockback" | "grabbed" | "dead"

-- Movement and rotation policy for each combat phase. During Startup, Active, Lunge, Hitstop,
-- Ability, Dash, ParryCounter, CC, and Recovery (unless explicitly move-canceling via an opposite/
-- break direction with no buffered action), directional MoveInput is completely removed so there
-- is zero movement or AutoRotate jitter between combo hits.
function CombatState.movementPolicy(phase: Phase, allowRecoveryMoveCancel: boolean?): MovementPolicy
	if phase == "locomotion" or phase == "charge" or phase == "guard" then
		return { allowMoveInput = true, autoRotate = true, speedScale = 1 }
	end
	if phase == "recovery" and allowRecoveryMoveCancel == true then
		return { allowMoveInput = true, autoRotate = true, speedScale = 1 }
	end
	return { allowMoveInput = false, autoRotate = false, speedScale = 0 }
end

-- True when the player's own movement input must be zeroed (`WalkSpeed = 0`, `AutoRotate = false`).
function CombatState.locksMovement(phase: Phase, allowRecoveryMoveCancel: boolean?): boolean
	return not CombatState.movementPolicy(phase, allowRecoveryMoveCancel).allowMoveInput
end

-- True when steering in `moveDir` diverges past `abortAngleDeg` (default 120 deg) from the
-- active lunge's direction, aborting the lunge cleanly into the new direction.
function CombatState.shouldAbortLunge(lungeDir: Vector3, moveDir: Vector3?, abortAngleDeg: number?): boolean
	if not moveDir then
		return false
	end
	local flatLunge = Melee.flat(lungeDir)
	local flatMove = Melee.flat(moveDir)
	if not flatLunge or not flatMove then
		return false
	end
	local thresholdDeg = math.clamp(if abortAngleDeg ~= nil then abortAngleDeg else Config.LUNGE_ABORT_ANGLE, 1, 180)
	local maxDot = math.cos(math.rad(thresholdDeg)) + 1e-6
	return flatLunge:Dot(flatMove) <= maxDot
end

-- Clamps an untargeted Startup aim adjustment toward `moveDir` by at most `maxDegrees` on XZ,
-- giving crisp micro-correction during windup without letting players spin 180° mid-swing.
function CombatState.microPivot(currentAim: Vector3, moveDir: Vector3?, maxDegrees: number): Vector3
	local aim = Melee.flat(currentAim)
	if not aim then
		return Vector3.new(0, 0, -1)
	end
	if not moveDir or maxDegrees <= 0 then
		return aim
	end
	local target = Melee.flat(moveDir)
	if not target then
		return aim
	end
	local dot = math.clamp(aim:Dot(target), -1, 1)
	local angle = math.acos(dot)
	local maxRad = math.rad(maxDegrees)
	if angle <= maxRad or angle < 1e-5 then
		return target
	end
	-- Signed Y cross product decides whether target lies clockwise or counter-clockwise of aim.
	local crossY = aim.X * target.Z - aim.Z * target.X
	local signed = if crossY >= 0 then maxRad else -maxRad
	local cosA = math.cos(signed)
	local sinA = math.sin(signed)
	return Vector3.new(aim.X * cosA - aim.Z * sinA, 0, aim.X * sinA + aim.Z * cosA).Unit
end

-- Effective cancel timestamp for offensive chains: hitting an enemy unlocks the faster base
-- `cancelAt`, while a whiff adds `whiffPenalty` (Dash and Block still cancel at any time).
function CombatState.effectiveCancelAt(baseCancelAt: number, hitConfirmed: boolean, whiffPenalty: number?): number
	if hitConfirmed then
		return baseCancelAt
	end
	return baseCancelAt + math.max(if whiffPenalty ~= nil then whiffPenalty else Config.ATTACK_WHIFF_CANCEL_PENALTY, 0)
end

-- True when steering in `moveDir` diverges outside `coneDeg` (i.e. opposite/away from the
-- locked enemy or current swing facing), signaling intent to break out of recovery and walk away.
function CombatState.isSteeringAway(referenceDir: Vector3, moveDir: Vector3?, coneDeg: number?): boolean
	if not moveDir then
		return false
	end
	local ref = Melee.flat(referenceDir)
	local flatMove = Melee.flat(moveDir)
	if not ref or not flatMove then
		return false
	end
	local cone = math.clamp(if coneDeg ~= nil then coneDeg else Config.TARGET_LOCK_CONE, 0, 360)
	local minDot = math.cos(math.rad(cone / 2)) - 1e-6
	return ref:Dot(flatMove) < minDot
end

-- True when an opposite/break directional input cleanly move-cancels out of Recovery into
-- Locomotion. Neutral input, steering toward the target, or having a buffered move NEVER unlocks
-- movement mid-recovery so combos stay rock-steady with zero movement/autorotation between hits.
function CombatState.canMoveCancel(
	phase: Phase,
	clock: number,
	moveCancelAt: number,
	steeringAway: boolean,
	hasBufferedAction: boolean?
): boolean
	return phase == "recovery" and not hasBufferedAction and steeringAway and clock >= moveCancelAt
end

-- Local impact freeze duration (seconds) and camera shake amplitude for confirmed hits.
function CombatState.hitstopSpec(tier: HitTier, armored: boolean?): (number, number)
	local duration: number
	local shake: number
	if tier == "heavy" then
		duration = Config.ATTACK_HITSTOP_HEAVY
		shake = Config.HITSTOP_CAMERA_SHAKE_HEAVY
	elseif tier == "medium" then
		duration = Config.ATTACK_HITSTOP_MEDIUM
		shake = Config.HITSTOP_CAMERA_SHAKE_MEDIUM
	else
		duration = Config.ATTACK_HITSTOP_LIGHT
		shake = Config.HITSTOP_CAMERA_SHAKE_LIGHT
	end
	if armored then
		shake *= 1.15
	end
	return duration, shake
end

-- True when an incoming hit cancels an active Heavy Charge. Light/normal hits deal damage without
-- interrupting the charge; only heavy enemy attacks, CC (stun/knockback/grab), or lethal hits do.
function CombatState.shouldCancelHeavyCharge(hit: IncomingHit): boolean
	if hit.outcome == "invulnerable" or hit.outcome == "parry" then
		return false
	end
	return hit.lethal == true
		or hit.grabs == true
		or hit.knocksBack == true
		or hit.stuns == true
		or hit.heavy == true
end

-- Resolves whether an incoming hit interrupts the player's current state, following the priority
-- hierarchy: Death > Grab > Knockback > Stun > Parry-Only Flinch > Poise (no interrupt).
function CombatState.shouldInterruptByHit(phase: Phase, hit: IncomingHit): InterruptResult
	if hit.outcome == "invulnerable" or hit.outcome == "parry" then
		return "none"
	end
	if hit.lethal == true then
		return "dead"
	end
	if hit.grabs == true then
		return "grabbed"
	end
	if hit.knocksBack == true then
		return "knockback"
	end
	if hit.stuns == true then
		return "stunned"
	end
	if hit.parryOnly == true and phase ~= "grabbed" and phase ~= "dead" then
		return "flinch"
	end
	return "none"
end

--=============================================================================
-- Self test
--=============================================================================

function CombatState.selfTest()
	-- Movement policy: completely removed during Startup, Active, Lunge, Hitstop, Ability, Dash, CC.
	for _, locked in ipairs({ "lunge", "startup", "active", "hitstop", "ability", "dash", "parryCounter", "stunned", "knockback", "grabbed", "dead" }) do
		local policy = CombatState.movementPolicy(locked :: Phase)
		assert(not policy.allowMoveInput and not policy.autoRotate and policy.speedScale == 0, `{locked} removes move input`)
		assert(CombatState.locksMovement(locked :: Phase), `locksMovement true for {locked}`)
	end

	-- Locomotion, Charge, and Guard keep player movement input active.
	for _, free in ipairs({ "locomotion", "charge", "guard" }) do
		local policy = CombatState.movementPolicy(free :: Phase)
		assert(policy.allowMoveInput and policy.autoRotate and policy.speedScale == 1, `{free} keeps move input`)
	end

	-- Recovery stays locked on neutral/toward input or buffered chains; ONLY steering away past
	-- moveCancelAt with no buffered action unlocks movement early.
	assert(CombatState.locksMovement("recovery", false), "recovery stays locked by default (neutral/toward)")
	assert(not CombatState.locksMovement("recovery", true), "recovery unlocks only when move-cancel triggers")
	assert(
		CombatState.canMoveCancel("recovery", 10.42, 10.40, true, false),
		"canMoveCancel fires when steering away past moveCancelAt with no buffer"
	)
	assert(
		not CombatState.canMoveCancel("recovery", 10.42, 10.40, false, false),
		"neutral or toward-target input NEVER unlocks recovery movement"
	)
	assert(
		not CombatState.canMoveCancel("recovery", 10.42, 10.40, true, true),
		"buffered action prevents recovery move-cancel"
	)
	assert(not CombatState.canMoveCancel("active", 10.50, 10.40, true, false), "canMoveCancel never fires during active swing")

	-- isSteeringAway checks divergence outside TARGET_LOCK_CONE (120 deg -> +/-60 deg).
	local northRef = Vector3.new(0, 0, -1)
	assert(not CombatState.isSteeringAway(northRef, nil, 120), "neutral input is not steering away")
	assert(not CombatState.isSteeringAway(northRef, northRef, 120), "forward input is not steering away")
	assert(
		not CombatState.isSteeringAway(northRef, Vector3.new(math.sin(math.rad(55)), 0, -math.cos(math.rad(55))), 120),
		"55 deg stays inside general direction"
	)
	assert(CombatState.isSteeringAway(northRef, Vector3.new(1, 0, 0), 120), "90 deg breaks general direction")
	assert(CombatState.isSteeringAway(northRef, Vector3.new(0, 0, 1), 120), "opposite direction steers away")

	-- Opposite-direction lunge abort (> 120 deg aborts; neutral / forward / 90 deg does not).
	local north = Vector3.new(0, 0, -1)
	local south = Vector3.new(0, 0, 1)
	local east = Vector3.new(1, 0, 0)
	local sw135 = Vector3.new(-math.sin(math.rad(135)), 0, -math.cos(math.rad(135)))
	local nw110 = Vector3.new(-math.sin(math.rad(110)), 0, -math.cos(math.rad(110)))
	assert(not CombatState.shouldAbortLunge(north, nil, 120), "neutral input never aborts lunge")
	assert(not CombatState.shouldAbortLunge(north, north, 120), "forward input never aborts lunge")
	assert(not CombatState.shouldAbortLunge(north, east, 120), "90-deg input does not abort 120-deg lunge")
	assert(not CombatState.shouldAbortLunge(north, nw110, 120), "110-deg input stays inside abort threshold")
	assert(CombatState.shouldAbortLunge(north, sw135, 120), "135-deg opposite input aborts lunge")
	assert(CombatState.shouldAbortLunge(north, south, 120), "180-deg opposite input aborts lunge")

	-- Startup micro-pivot clamps rotation to +/- maxDegrees.
	local pivoted = CombatState.microPivot(north, east, 35)
	local angleDeg = math.deg(math.acos(math.clamp(north:Dot(pivoted), -1, 1)))
	assert(math.abs(angleDeg - 35) < 0.25 and pivoted.X > 0, "microPivot clamps 90-deg input to +35 deg")
	local smallInput = Vector3.new(math.sin(math.rad(15)), 0, -math.cos(math.rad(15)))
	local exactPivot = CombatState.microPivot(north, smallInput, 35)
	assert(exactPivot:Dot(smallInput) > 0.999, "microPivot accepts small angle verbatim")

	-- Hit-confirm vs. whiff cancel timing and hitstop tiers.
	assert(CombatState.effectiveCancelAt(10.36, true, 0.04) == 10.36, "hit confirm uses exact cancelAt")
	assert(math.abs(CombatState.effectiveCancelAt(10.36, false, 0.04) - 10.40) < 1e-6, "whiff adds penalty")
	local dLight, sLight = CombatState.hitstopSpec("light", false)
	local dHeavy, sHeavy = CombatState.hitstopSpec("heavy", false)
	local _, sArmored = CombatState.hitstopSpec("heavy", true)
	assert(dHeavy > dLight and sHeavy > sLight and sArmored > sHeavy, "hitstop scales with tier and armor")

	-- Heavy charge interruption: ONLY heavy attacks / CC / lethal cancel charge; light hits do not.
	assert(not CombatState.shouldCancelHeavyCharge({ outcome = "hit" }), "light hit does NOT cancel heavy charge")
	assert(not CombatState.shouldCancelHeavyCharge({ heavy = true, outcome = "invulnerable" }), "dodged heavy hit does not cancel")
	assert(not CombatState.shouldCancelHeavyCharge({ heavy = true, outcome = "parry" }), "parried heavy hit does not cancel")
	assert(CombatState.shouldCancelHeavyCharge({ heavy = true, outcome = "hit" }), "heavy hit cancels heavy charge")
	assert(CombatState.shouldCancelHeavyCharge({ heavy = true, outcome = "block" }), "blocked heavy hit still cancels charge")
	assert(CombatState.shouldCancelHeavyCharge({ stuns = true, outcome = "hit" }), "stun cancels heavy charge")
	assert(CombatState.shouldCancelHeavyCharge({ grabs = true, outcome = "hit" }), "grab cancels heavy charge")
	assert(CombatState.shouldCancelHeavyCharge({ lethal = true, outcome = "hit" }), "lethal hit cancels heavy charge")

	-- Incoming hit interrupt matrix.
	assert(CombatState.shouldInterruptByHit("active", { outcome = "hit" }) == "none", "light hit preserves attack poise")
	assert(CombatState.shouldInterruptByHit("active", { stuns = true, outcome = "hit" }) == "stunned", "stun interrupts active swing")
	assert(CombatState.shouldInterruptByHit("active", { knocksBack = true, stuns = true, outcome = "hit" }) == "knockback", "knockback outranks stun")
	assert(CombatState.shouldInterruptByHit("active", { grabs = true, outcome = "hit" }) == "grabbed", "grab interrupts active swing")
	assert(CombatState.shouldInterruptByHit("active", { parryOnly = true, outcome = "hit" }) == "flinch", "parry-only hit interrupts active swing")
	assert(CombatState.shouldInterruptByHit("active", { lethal = true, stuns = true, outcome = "hit" }) == "dead", "lethal hit outranks all CC")
	assert(CombatState.shouldInterruptByHit("dash", { stuns = true, outcome = "invulnerable" }) == "none", "dash i-frames negate stun")
end

return CombatState
