--!strict
--[[
	What an enemy decides each frame, as a pure function: given its kind, its state and how far
	the nearest player is, where it moves and whether it acts.

	Pure so the timings can be asserted rather than watched. "The melee enemy always telegraphs
	before it hits" is the rule that makes a dash a skill instead of luck, and it is three lines
	here against a Play session and a stopwatch.
]]

local Brain = {}

-- chase: moving into position. windup: about to strike, spin, sandevistan, or grab.
-- spin: dual-blade melee whirling continuously for high DPS. sandevistan: single-sword melee
-- chaining 3+ ultra-fast dashes in different directions before an ambush slash.
-- beamCharge: rifle ranged unit charging a devastating beam. evade: ranged unit leaping backward.
-- lunge: grabber charging forward. recover: just acted, frozen. fuse: the exploder is about to
-- go off. spent: the exploder went off. holding: the grabber is currently immobilising a player.
export type Phase =
	"chase"
	| "windup"
	| "spin"
	| "sandevistan"
	| "beamCharge"
	| "evade"
	| "lunge"
	| "recover"
	| "fuse"
	| "spent"
	| "holding"

export type State = {
	phase: Phase,
	endsAt: number,
	nextFireAt: number,
	nextSpinAt: number?,
	nextSpinTickAt: number?,
	pendingSpin: boolean?,
	nextBeamAt: number?,
	nextEvadeAt: number?,
	nextSandevistanAt: number?,
	sandevistanLeft: number?,
	pendingSandevistan: boolean?,
	sandevistanFinisher: boolean?,
}

export type Intent = {
	move: "toward" | "away" | "hold" | "flank" | "lunge" | "spin" | "sandevistan" | "evade",
	action: (
		"strike"
		| "spinTick"
		| "sandevistanHop"
		| "fire"
		| "beamStart"
		| "beamFire"
		| "evade"
		| "explode"
		| "grab"
		| "grabLunge"
		| "grabCheck"
	)?,
}

-- The fields of a kind this module reads. Config.ENEMY_KINDS entries carry more.
export type Kind = {
	reach: number?,
	windup: number?,
	lungeDuration: number?,
	recover: number?,
	keepAway: number?,
	fireEvery: number?,
	trigger: number?,
	fuse: number?,
	canSpin: boolean?,
	spinDuration: number?,
	spinTickEvery: number?,
	spinCooldown: number?,
	canSandevistan: boolean?,
	sandevistanSteps: number?,
	sandevistanStepDuration: number?,
	sandevistanRange: number?,
	sandevistanCooldown: number?,
	sandevistanStrikeWindup: number?,
	canBeam: boolean?,
	beamCharge: number?,
	beamCooldown: number?,
	beamRange: number?,
	beamRecover: number?,
	evadeTrigger: number?,
	evadeDuration: number?,
	evadeCooldown: number?,
}

-- A ranged enemy backs off inside this fraction of its distance, and only fires inside this
-- multiple of it, so it never shoots across the whole room at somebody it cannot see coming.
Brain.TOO_CLOSE = 0.7
Brain.FIRE_REACH = 1.6

-- A ranged enemy waits this long after spawning before its first shot, so a wave arriving does
-- not open with a volley the player had no time to see.
Brain.FIRST_SHOT_DELAY = 1

function Brain.initial(now: number): State
	return {
		phase = "chase",
		endsAt = 0,
		nextFireAt = now + Brain.FIRST_SHOT_DELAY,
		nextSpinAt = now + 2.0,
		nextSpinTickAt = 0,
		pendingSpin = false,
		nextBeamAt = now + 1.8,
		nextEvadeAt = 0,
		nextSandevistanAt = now + 1.8,
		sandevistanLeft = 0,
		pendingSandevistan = false,
		sandevistanFinisher = false,
	}
end

local function with(
	state: State,
	phase: Phase,
	endsAt: number,
	nextSpinAt: number?,
	nextSpinTickAt: number?,
	pendingSpin: boolean?,
	nextBeamAt: number?,
	nextEvadeAt: number?,
	nextSandevistanAt: number?,
	sandevistanLeft: number?,
	pendingSandevistan: boolean?,
	sandevistanFinisher: boolean?
): State
	return {
		phase = phase,
		endsAt = endsAt,
		nextFireAt = state.nextFireAt,
		nextSpinAt = if nextSpinAt ~= nil then nextSpinAt else state.nextSpinAt,
		nextSpinTickAt = if nextSpinTickAt ~= nil then nextSpinTickAt else state.nextSpinTickAt,
		pendingSpin = if pendingSpin ~= nil then pendingSpin else false,
		nextBeamAt = if nextBeamAt ~= nil then nextBeamAt else state.nextBeamAt,
		nextEvadeAt = if nextEvadeAt ~= nil then nextEvadeAt else state.nextEvadeAt,
		nextSandevistanAt = if nextSandevistanAt ~= nil then nextSandevistanAt else state.nextSandevistanAt,
		sandevistanLeft = if sandevistanLeft ~= nil then sandevistanLeft else 0,
		pendingSandevistan = if pendingSandevistan ~= nil then pendingSandevistan else false,
		sandevistanFinisher = if sandevistanFinisher ~= nil then sandevistanFinisher else false,
	}
end

local function melee(kind: Kind, state: State, distance: number, now: number, canAttack: boolean): (State, Intent)
	local reach = kind.reach or 0
	if state.phase == "sandevistan" then
		if now >= state.endsAt then
			local left = (state.sandevistanLeft or 1) - 1
			if left > 0 then
				local stepDur = kind.sandevistanStepDuration or 0.15
				return with(state, "sandevistan", now + stepDur, nil, nil, false, nil, nil, nil, left, false, false),
					{ move = "sandevistan", action = "sandevistanHop" }
			end
			-- Finished all rapid hops: brief ambush windup before the surprise slash.
			local strikeWindup = kind.sandevistanStrikeWindup or 0.28
			local cd = kind.sandevistanCooldown or 7.0
			return with(state, "windup", now + strikeWindup, nil, nil, false, nil, nil, now + cd, 0, false, true),
				{ move = "hold" }
		end
		return state, { move = "sandevistan" }
	end
	if state.phase == "spin" then
		if now >= state.endsAt then
			local spinCooldown = kind.spinCooldown or 6.5
			return with(state, "recover", now + (kind.recover or 0.8) * 1.4, now + spinCooldown, 0, false),
				{ move = "hold" }
		end
		local tickEvery = kind.spinTickEvery or 0.25
		if now >= (state.nextSpinTickAt or 0) then
			return with(state, "spin", state.endsAt, state.nextSpinAt, now + tickEvery, false),
				{ move = "spin", action = "spinTick" }
		end
		return state, { move = "spin" }
	end
	if state.phase == "windup" then
		if now >= state.endsAt then
			if state.pendingSandevistan and kind.canSandevistan then
				local steps = math.max(kind.sandevistanSteps or 3, 3)
				local stepDur = kind.sandevistanStepDuration or 0.15
				return with(state, "sandevistan", now + stepDur, nil, nil, false, nil, nil, nil, steps, false, false),
					{ move = "sandevistan", action = "sandevistanHop" }
			end
			if state.pendingSpin and kind.canSpin then
				local spinDur = kind.spinDuration or 1.6
				local tickEvery = kind.spinTickEvery or 0.25
				return with(state, "spin", now + spinDur, state.nextSpinAt, now + tickEvery, false),
					{ move = "spin", action = "spinTick" }
			end
			local rec = if state.sandevistanFinisher then (kind.recover or 0.8) * 1.3 else (kind.recover or 0)
			return with(state, "recover", now + rec, nil, nil, false, nil, nil, nil, 0, false, state.sandevistanFinisher),
				{ move = "hold", action = "strike" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "recover" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "hold" }
	end
	if not canAttack then
		return state, { move = "flank" }
	end
	-- Single-sword Sandevistan: activates from mid-range (up to sandevistanRange) to chain 3+
	-- rapid multi-directional dashes into a surprise ambush strike.
	local sandyRange = kind.sandevistanRange or 24
	if kind.canSandevistan == true and now >= (state.nextSandevistanAt or 0) and distance <= sandyRange then
		local prepWindup = (kind.windup or 0.45) * 0.85
		return with(state, "windup", now + prepWindup, nil, nil, false, nil, nil, nil, 0, true, false),
			{ move = "hold" }
	end
	if distance <= reach then
		local wantsSpin = kind.canSpin == true and now >= (state.nextSpinAt or 0)
		local windupTime = if wantsSpin then (kind.windup or 0.45) * 1.2 else (kind.windup or 0)
		return with(state, "windup", now + windupTime, state.nextSpinAt, 0, wantsSpin), { move = "hold" }
	end
	return state, { move = "toward" }
end

local function ranged(kind: Kind, state: State, distance: number, now: number, canAttack: boolean): (State, Intent)
	if state.phase == "evade" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "evade" }
	end
	if state.phase == "beamCharge" then
		if now >= state.endsAt then
			local beamCooldown = kind.beamCooldown or 7.5
			local beamRecover = kind.beamRecover or 1.05
			return with(state, "recover", now + beamRecover, nil, nil, false, now + beamCooldown),
				{ move = "hold", action = "beamFire" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "recover" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "hold" }
	end

	-- Emergency backstep leap when a player closes too tightly (minimum 5 s cooldown).
	local evadeTrigger = kind.evadeTrigger or 0
	local evadeDuration = kind.evadeDuration or 0
	if evadeTrigger > 0 and evadeDuration > 0 and distance <= evadeTrigger and now >= (state.nextEvadeAt or 0) then
		local evadeCooldown = math.max(kind.evadeCooldown or 5.5, 5.0)
		return with(state, "evade", now + evadeDuration, nil, nil, false, nil, now + evadeCooldown),
			{ move = "evade", action = "evade" }
	end

	-- Rifle / plasma specialists periodically overcharge a devastating rail-beam from range.
	-- Not blocked by orb-volley stagger (`canAttack`) because the 1.4 s laser telegraph already
	-- gives the player clear reaction time.
	local beamRange = kind.beamRange or ((kind.keepAway or 28) * Brain.FIRE_REACH)
	if
		kind.canBeam == true
		and now >= (state.nextBeamAt or 0)
		and distance <= beamRange
		and distance > evadeTrigger
	then
		local chargeTime = kind.beamCharge or 1.4
		return with(state, "beamCharge", now + chargeTime), { move = "hold", action = "beamStart" }
	end

	local keepAway = kind.keepAway or 0
	local move: "toward" | "away" | "hold" = "hold"
	if distance < keepAway * Brain.TOO_CLOSE then
		move = "away"
	elseif distance > keepAway then
		move = "toward"
	end
	if canAttack and now >= state.nextFireAt and distance <= keepAway * Brain.FIRE_REACH then
		local fired = {
			phase = state.phase,
			endsAt = state.endsAt,
			nextFireAt = now + (kind.fireEvery or 1),
			nextSpinAt = state.nextSpinAt,
			nextSpinTickAt = state.nextSpinTickAt,
			pendingSpin = state.pendingSpin,
			nextBeamAt = state.nextBeamAt,
			nextEvadeAt = state.nextEvadeAt,
		}
		return fired, { move = move, action = "fire" }
	end
	return state, { move = move }
end

local function exploder(kind: Kind, state: State, distance: number, now: number, _canAttack: boolean): (State, Intent)
	if state.phase == "spent" then
		return state, { move = "hold" }
	end
	if state.phase == "fuse" then
		if now >= state.endsAt then
			return with(state, "spent", 0), { move = "hold", action = "explode" }
		end
		return state, { move = "hold" }
	end
	if distance <= (kind.trigger or 0) then
		return with(state, "fuse", now + (kind.fuse or 0)), { move = "hold" }
	end
	return state, { move = "toward" }
end

local function grabber(kind: Kind, state: State, distance: number, now: number, _canAttack: boolean): (State, Intent)
	if state.phase == "holding" then
		return state, { move = "hold" }
	end
	local reach = kind.reach or 0
	if state.phase == "windup" then
		if now >= state.endsAt then
			local lungeDuration = kind.lungeDuration or 0
			if lungeDuration > 0 then
				return with(state, "lunge", now + lungeDuration), { move = "lunge", action = "grabLunge" }
			end
			return with(state, "recover", now + (kind.recover or 0)), { move = "hold", action = "grab" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "lunge" then
		if now >= state.endsAt then
			return with(state, "recover", now + (kind.recover or 0)), { move = "hold" }
		end
		return state, { move = "lunge", action = "grabCheck" }
	end
	if state.phase == "recover" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "hold" }
	end
	if distance <= reach then
		return with(state, "windup", now + (kind.windup or 0)), { move = "hold" }
	end
	return state, { move = "toward" }
end

local BEHAVIOURS = {
	melee = melee,
	ranged = ranged,
	exploder = exploder,
	grabber = grabber,
}

-- Transitions a grabber into `holding` once EnemyService confirms the target was caught.
function Brain.enterHolding(state: State): State
	return with(state, "holding", 0)
end

-- Transitions a grabber out of `holding` into `recover` so it cannot re-grab on the next frame.
function Brain.releaseGrab(state: State, recover: number, now: number): State
	return with(state, "recover", now + recover)
end

-- Advances grab-escape progress (from the trapped player's presses or teammates' hits) and
-- reports whether the player has broken free.
function Brain.escapeProgress(current: number, delta: number, goal: number): (number, boolean)
	if goal <= 0 then
		return 0, true
	end
	local nextVal = math.clamp(current + math.max(delta, 0), 0, goal)
	return nextVal, nextVal >= goal
end

-- An unknown kind stands still rather than erroring: one bad Config row should cost one enemy
-- its brain, not the whole server its Heartbeat. `canAttack` defaults to true when omitted so
-- single-enemy callers work unchanged while squad tactics can gate melee/ranged pressure.
function Brain.step(
	kindName: string,
	kind: Kind,
	state: State,
	distance: number,
	now: number,
	canAttack: boolean?
): (State, Intent)
	local behaviour = BEHAVIOURS[kindName]
	if not behaviour then
		return state, { move = "hold" }
	end
	return behaviour(kind, state, distance, now, if canAttack ~= nil then canAttack else true)
end

-- Flat (X/Z) blast reach check shared between player hits and enemy friendly-fire hits.
function Brain.inBlast(origin: Vector3, target: Vector3, blastRadius: number, targetRadius: number): boolean
	local dx = target.X - origin.X
	local dz = target.Z - origin.Z
	local reach = blastRadius + math.max(targetRadius, 0)
	return dx * dx + dz * dz <= reach * reach
end

-- Computes a flat unit roaming direction when no ungrabbed player is targetable, steering away
-- from any grabbed players inside `avoidRadius` so the crowd stays in motion while ignoring them.
function Brain.wanderDirection(position: Vector3, heading: Vector3, avoid: { Vector3 }, avoidRadius: number): Vector3
	local dir = Vector3.new(heading.X, 0, heading.Z)
	if dir.Magnitude > 1e-3 then
		dir = dir.Unit
	else
		dir = Vector3.new(1, 0, 0)
	end
	if avoidRadius > 0 then
		for _, spot in ipairs(avoid) do
			local away = Vector3.new(position.X - spot.X, 0, position.Z - spot.Z)
			local dist = away.Magnitude
			if dist < avoidRadius then
				local awayUnit = if dist > 1e-3 then away.Unit else dir
				local weight = 2 * (1 - dist / avoidRadius) + 0.5
				dir += awayUnit * weight
			end
		end
	end
	return if dir.Magnitude > 1e-3 then dir.Unit else Vector3.new(1, 0, 0)
end

--=============================================================================
-- Self test
--=============================================================================

function Brain.selfTest()
	-- Comparisons go through `is`: an `assert(x == "a")` narrows x to "a" for the type checker,
	-- which then refuses the next `x == "b"` after x is reassigned. The values are what is tested.
	local function is(value: any, expected: any): boolean
		return value == expected
	end
	local meleeKind: Kind = { reach = 6, windup = 0.45, recover = 0.8 }
	local s: any = Brain.initial(0)
	local intent: any

	s, intent = Brain.step("melee", meleeKind, s, 20, 0)
	assert(is(intent.move, "toward") and is(intent.action, nil), "melee chases from afar")

	s, intent = Brain.step("melee", meleeKind, s, 5, 1)
	assert(is(s.phase, "windup") and is(intent.action, nil), "melee in reach winds up, it does not hit yet")

	s, intent = Brain.step("melee", meleeKind, s, 5, 1.2)
	assert(is(intent.action, nil) and is(intent.move, "hold"), "the windup holds still and does not hit early")

	s, intent = Brain.step("melee", meleeKind, s, 30, 1.45)
	assert(is(intent.action, "strike"), "the strike lands when the windup ends, wherever the player went")
	assert(is(s.phase, "recover"), "after a strike comes the recovery")

	s, intent = Brain.step("melee", meleeKind, s, 5, 2)
	assert(is(intent.action, nil) and is(s.phase, "recover"), "no second strike during recovery")

	s, intent = Brain.step("melee", meleeKind, s, 5, 2.3)
	assert(is(s.phase, "chase"), "recovery ends")

	-- Without an attack token, a melee unit flanks instead of starting a dogpile windup.
	local sf, intentF = Brain.step("melee", meleeKind, Brain.initial(0), 4, 1, false)
	assert(is(sf.phase, "chase") and is(intentF.move, "flank") and is(intentF.action, nil), "melee without token flanks")

	-- Dual-blade spin DPS ability: telegraphs windup -> enters spin -> emits periodic spinTicks -> recovers.
	local dualKind: Kind = {
		reach = 6,
		windup = 0.45,
		recover = 0.8,
		canSpin = true,
		spinDuration = 1.6,
		spinTickEvery = 0.25,
		spinCooldown = 6.5,
	}
	local sd: any = Brain.initial(0)
	sd, intent = Brain.step("melee", dualKind, sd, 5, 2.5)
	assert(is(sd.phase, "windup") and sd.pendingSpin == true, "dual melee winds up into spin when off cooldown")
	sd, intent = Brain.step("melee", dualKind, sd, 5, 3.1)
	assert(is(sd.phase, "spin") and is(intent.action, "spinTick") and is(intent.move, "spin"), "windup enters DPS spin")
	sd, intent = Brain.step("melee", dualKind, sd, 5, 3.2)
	assert(is(sd.phase, "spin") and is(intent.action, nil), "spin waits tick interval between DPS ticks")
	sd, intent = Brain.step("melee", dualKind, sd, 5, 3.4)
	assert(is(sd.phase, "spin") and is(intent.action, "spinTick"), "spin fires next DPS tick")
	sd, intent = Brain.step("melee", dualKind, sd, 5, 4.8)
	assert(is(sd.phase, "recover") and is(intent.move, "hold"), "spin ends into recover")

	-- Single-sword Sandevistan: prep windup -> 3 rapid multi-direction hops -> finisher windup -> strike.
	local sandyKind: Kind = {
		reach = 6,
		windup = 0.45,
		recover = 0.8,
		canSandevistan = true,
		sandevistanSteps = 3,
		sandevistanStepDuration = 0.15,
		sandevistanRange = 24,
		sandevistanCooldown = 7.0,
		sandevistanStrikeWindup = 0.28,
	}
	local ss: any = Brain.initial(0)
	ss, intent = Brain.step("melee", sandyKind, ss, 18, 2.0)
	assert(is(ss.phase, "windup") and ss.pendingSandevistan == true, "sword melee winds up into Sandevistan")
	ss, intent = Brain.step("melee", sandyKind, ss, 18, 2.45)
	assert(is(ss.phase, "sandevistan") and is(intent.action, "sandevistanHop") and ss.sandevistanLeft == 3, "hop 1 fires")
	ss, intent = Brain.step("melee", sandyKind, ss, 12, 2.61)
	assert(is(ss.phase, "sandevistan") and is(intent.action, "sandevistanHop") and ss.sandevistanLeft == 2, "hop 2 fires")
	ss, intent = Brain.step("melee", sandyKind, ss, 10, 2.77)
	assert(is(ss.phase, "sandevistan") and is(intent.action, "sandevistanHop") and ss.sandevistanLeft == 1, "hop 3 fires")
	ss, intent = Brain.step("melee", sandyKind, ss, 5, 2.93)
	assert(is(ss.phase, "windup") and ss.sandevistanFinisher == true, "after 3 hops enters ambush strike windup")
	ss, intent = Brain.step("melee", sandyKind, ss, 5, 3.25)
	assert(is(ss.phase, "recover") and is(intent.action, "strike"), "ambush windup unleashes surprise strike")

	-- Ranged enemy respects volley stagger gate (`canAttack = false`) without firing.
	local rHold, rHoldIntent = Brain.step("ranged", { keepAway = 28, fireEvery = 1.6 }, Brain.initial(0), 25, 2, false)
	assert(is(rHoldIntent.action, nil) and rHold.nextFireAt == 1, "ranged waits for stagger turn before firing")

	-- Ranged evade backstep leap with >= 5 s cooldown.
	local evadeRanged: Kind = { keepAway = 28, fireEvery = 1.6, evadeTrigger = 11, evadeDuration = 0.34, evadeCooldown = 5.5 }
	local re: any = Brain.initial(0)
	re, intent = Brain.step("ranged", evadeRanged, re, 9, 1)
	assert(is(re.phase, "evade") and is(intent.action, "evade") and is(intent.move, "evade"), "ranged leaps back when player gets too close")
	re, intent = Brain.step("ranged", evadeRanged, re, 15, 1.2)
	assert(is(re.phase, "evade") and is(intent.move, "evade"), "ranged stays in evade across jump duration")
	re, intent = Brain.step("ranged", evadeRanged, re, 15, 1.4)
	assert(is(re.phase, "chase"), "ranged finishes evade leap cleanly")
	-- Trying to trigger evade again after only 3 s (< 5 s cooldown) must NOT evade.
	re, intent = Brain.step("ranged", evadeRanged, re, 8, 4.0)
	assert(not is(re.phase, "evade") and is(intent.move, "away"), "ranged respects >= 5 s evade cooldown")
	re, intent = Brain.step("ranged", evadeRanged, re, 8, 6.6)
	assert(is(re.phase, "evade") and is(intent.action, "evade"), "ranged can evade again after cooldown")

	-- Rifle charged rail-beam: charges -> fires beam -> enters recover -> waits cooldown.
	local beamRifle: Kind = {
		keepAway = 28,
		fireEvery = 1.6,
		canBeam = true,
		beamCharge = 1.4,
		beamCooldown = 7.5,
		beamRange = 55,
		beamRecover = 1.05,
		evadeTrigger = 11,
	}
	local rb: any = Brain.initial(0)
	rb, intent = Brain.step("ranged", beamRifle, rb, 30, 3.2)
	assert(is(rb.phase, "beamCharge") and is(intent.action, "beamStart") and is(intent.move, "hold"), "rifle starts charging beam")
	rb, intent = Brain.step("ranged", beamRifle, rb, 30, 4.0)
	assert(is(rb.phase, "beamCharge") and is(intent.action, nil), "rifle holds during charge")
	rb, intent = Brain.step("ranged", beamRifle, rb, 30, 4.7)
	assert(is(rb.phase, "recover") and is(intent.action, "beamFire"), "rifle unleashes devastating beam after charge")

	local rangedKind: Kind = { keepAway = 28, fireEvery = 1.6 }
	local r: any = Brain.initial(0)
	r, intent = Brain.step("ranged", rangedKind, r, 25, 0.5)
	assert(is(intent.action, nil), "no shot before the first delay")
	r, intent = Brain.step("ranged", rangedKind, r, 25, 1)
	assert(is(intent.action, "fire") and is(intent.move, "hold"), "fires from its preferred distance")
	r, intent = Brain.step("ranged", rangedKind, r, 25, 1.5)
	assert(is(intent.action, nil), "does not fire again before its cooldown")
	r, intent = Brain.step("ranged", rangedKind, r, 10, 1.5)
	assert(is(intent.move, "away"), "backs off a player who closes in")
	r, intent = Brain.step("ranged", rangedKind, r, 100, 3)
	assert(is(intent.move, "toward") and is(intent.action, nil), "walks in, and does not fire from across the room")

	local exploderKind: Kind = { trigger = 6, fuse = 0.8 }
	local e: any = Brain.initial(0)
	e, intent = Brain.step("exploder", exploderKind, e, 20, 0)
	assert(is(intent.move, "toward"), "the exploder chases")
	e, intent = Brain.step("exploder", exploderKind, e, 5, 1)
	assert(is(e.phase, "fuse") and is(intent.action, nil), "the fuse lights, it does not go off at once")
	e, intent = Brain.step("exploder", exploderKind, e, 50, 1.5)
	assert(is(intent.action, nil), "a player running away does not put the fuse out, nor set it off early")
	e, intent = Brain.step("exploder", exploderKind, e, 50, 1.8)
	assert(is(intent.action, "explode"), "the fuse runs out")
	e, intent = Brain.step("exploder", exploderKind, e, 1, 5)
	assert(is(intent.action, nil), "it only explodes once")

	-- Grabber: telegraphs with windup before grabbing, holds still while holding, recovers on release.
	local grabberKind: Kind = { reach = 7, windup = 0.55, recover = 1.6 }
	local g: any = Brain.initial(0)
	g, intent = Brain.step("grabber", grabberKind, g, 20, 0)
	assert(is(intent.move, "toward") and is(intent.action, nil), "grabber chases from afar")
	g, intent = Brain.step("grabber", grabberKind, g, 6, 1)
	assert(is(g.phase, "windup") and is(intent.action, nil), "grabber telegraphs before grabbing")
	g, intent = Brain.step("grabber", grabberKind, g, 6, 1.55)
	assert(is(intent.action, "grab") and is(g.phase, "recover"), "grab fires after windup ends")
	g = Brain.enterHolding(g)
	g, intent = Brain.step("grabber", grabberKind, g, 1, 2)
	assert(is(g.phase, "holding") and is(intent.move, "hold") and is(intent.action, nil), "holding stays put")
	g = Brain.releaseGrab(g, 1.6, 3)
	assert(is(g.phase, "recover"), "release enters recover")
	g, intent = Brain.step("grabber", grabberKind, g, 1, 4.7)
	assert(is(g.phase, "chase"), "grabber resumes chasing after recover")

	-- Grabber lunge: windup launches into a timed lunge checking for contact, then recovers if missed.
	local lungeGrabber: Kind = { reach = 13, windup = 0.55, lungeDuration = 0.28, recover = 1.6 }
	local gl: any = Brain.initial(0)
	gl, intent = Brain.step("grabber", lungeGrabber, gl, 10, 1)
	assert(is(gl.phase, "windup"), "lunge grabber telegraphs first")
	gl, intent = Brain.step("grabber", lungeGrabber, gl, 10, 1.55)
	assert(is(gl.phase, "lunge") and is(intent.action, "grabLunge") and is(intent.move, "lunge"), "windup launches lunge")
	gl, intent = Brain.step("grabber", lungeGrabber, gl, 6, 1.7)
	assert(is(gl.phase, "lunge") and is(intent.action, "grabCheck"), "lunge checks grab contact each frame")
	gl, intent = Brain.step("grabber", lungeGrabber, gl, 12, 1.85)
	assert(is(gl.phase, "recover") and is(intent.move, "hold"), "missed lunge transitions to recover")

	-- Escape progress math (10 presses, plus ally hit contributions).
	local p1, freed1 = Brain.escapeProgress(0, 1, 10)
	assert(p1 == 1 and not freed1, "first press advances escape progress")
	local p2, freed2 = Brain.escapeProgress(8, 2, 10)
	assert(p2 == 10 and freed2, "reaching goal frees the player")

	local _, unknown = Brain.step("nonsense", {}, Brain.initial(0), 1, 1)
	assert(is(unknown.move, "hold") and is(unknown.action, nil), "an unknown kind stands still")

	-- Blast radius check (flat X/Z, includes target body radius).
	local blastOrigin = Vector3.new(0, 2, 0)
	assert(Brain.inBlast(blastOrigin, Vector3.new(9, 2, 0), 10, 0), "target inside blast radius is hit")
	assert(Brain.inBlast(blastOrigin, Vector3.new(11.5, 8, 0), 10, 2), "body radius extends edge hit and ignores Y")
	assert(not Brain.inBlast(blastOrigin, Vector3.new(13, 2, 0), 10, 2), "target outside blast + radius is safe")

	-- Roaming direction keeps enemies moving and steers away from grabbed players.
	local freeRoam = Brain.wanderDirection(Vector3.new(0, 0, 0), Vector3.new(1, 0, 0), {}, 12)
	assert(freeRoam.X > 0.99, "roaming keeps heading when nobody to avoid")
	local steerAway = Brain.wanderDirection(Vector3.new(5, 0, 0), Vector3.new(-1, 0, 0), { Vector3.new(0, 0, 0) }, 12)
	assert(steerAway.X > 0, "roaming steers away from a grabbed player inside avoidRadius")
	local farIgnore = Brain.wanderDirection(Vector3.new(30, 0, 0), Vector3.new(-1, 0, 0), { Vector3.new(0, 0, 0) }, 12)
	assert(farIgnore.X < -0.99, "roaming ignores grabbed players outside avoidRadius")
end

return Brain
