--!strict
--[[
	What an enemy decides each frame, as a pure function: given its kind, its state and how far
	the nearest player is, where it moves and whether it acts.

	Pure so the timings can be asserted rather than watched. "The melee enemy always telegraphs
	before it hits" is the rule that makes a dash a skill instead of luck, and it is three lines
	here against a Play session and a stopwatch.
]]

local Brain = {}

-- chase: moving into position. windup: about to strike, frozen and telegraphing. recover: just
-- struck, frozen. fuse: the exploder is about to go off. spent: the exploder went off.
export type Phase = "chase" | "windup" | "recover" | "fuse" | "spent"

export type State = {
	phase: Phase,
	endsAt: number,
	nextFireAt: number,
}

export type Intent = {
	move: "toward" | "away" | "hold",
	action: ("strike" | "fire" | "explode")?,
}

-- The fields of a kind this module reads. Config.ENEMY_KINDS entries carry more.
export type Kind = {
	reach: number?,
	windup: number?,
	recover: number?,
	keepAway: number?,
	fireEvery: number?,
	trigger: number?,
	fuse: number?,
}

-- A ranged enemy backs off inside this fraction of its distance, and only fires inside this
-- multiple of it, so it never shoots across the whole room at somebody it cannot see coming.
Brain.TOO_CLOSE = 0.7
Brain.FIRE_REACH = 1.6

-- A ranged enemy waits this long after spawning before its first shot, so a wave arriving does
-- not open with a volley the player had no time to see.
Brain.FIRST_SHOT_DELAY = 1

function Brain.initial(now: number): State
	return { phase = "chase", endsAt = 0, nextFireAt = now + Brain.FIRST_SHOT_DELAY }
end

local function with(state: State, phase: Phase, endsAt: number): State
	return { phase = phase, endsAt = endsAt, nextFireAt = state.nextFireAt }
end

local function melee(kind: Kind, state: State, distance: number, now: number): (State, Intent)
	local reach = kind.reach or 0
	if state.phase == "windup" then
		if now >= state.endsAt then
			return with(state, "recover", now + (kind.recover or 0)), { move = "hold", action = "strike" }
		end
		return state, { move = "hold" }
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

local function ranged(kind: Kind, state: State, distance: number, now: number): (State, Intent)
	local keepAway = kind.keepAway or 0
	local move: "toward" | "away" | "hold" = "hold"
	if distance < keepAway * Brain.TOO_CLOSE then
		move = "away"
	elseif distance > keepAway then
		move = "toward"
	end
	if now >= state.nextFireAt and distance <= keepAway * Brain.FIRE_REACH then
		local fired = { phase = state.phase, endsAt = state.endsAt, nextFireAt = now + (kind.fireEvery or 1) }
		return fired, { move = move, action = "fire" }
	end
	return state, { move = move }
end

local function exploder(kind: Kind, state: State, distance: number, now: number): (State, Intent)
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

local BEHAVIOURS = {
	melee = melee,
	ranged = ranged,
	exploder = exploder,
}

-- An unknown kind stands still rather than erroring: one bad Config row should cost one enemy
-- its brain, not the whole server its Heartbeat.
function Brain.step(kindName: string, kind: Kind, state: State, distance: number, now: number): (State, Intent)
	local behaviour = BEHAVIOURS[kindName]
	if not behaviour then
		return state, { move = "hold" }
	end
	return behaviour(kind, state, distance, now)
end

-- Flat (X/Z) blast reach check shared between player hits and enemy friendly-fire hits.
function Brain.inBlast(origin: Vector3, target: Vector3, blastRadius: number, targetRadius: number): boolean
	local dx = target.X - origin.X
	local dz = target.Z - origin.Z
	local reach = blastRadius + math.max(targetRadius, 0)
	return dx * dx + dz * dz <= reach * reach
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

	local _, unknown = Brain.step("nonsense", {}, Brain.initial(0), 1, 1)
	assert(is(unknown.move, "hold") and is(unknown.action, nil), "an unknown kind stands still")

	-- Blast radius check (flat X/Z, includes target body radius).
	local blastOrigin = Vector3.new(0, 2, 0)
	assert(Brain.inBlast(blastOrigin, Vector3.new(9, 2, 0), 10, 0), "target inside blast radius is hit")
	assert(Brain.inBlast(blastOrigin, Vector3.new(11.5, 8, 0), 10, 2), "body radius extends edge hit and ignores Y")
	assert(not Brain.inBlast(blastOrigin, Vector3.new(13, 2, 0), 10, 2), "target outside blast + radius is safe")
end

return Brain
