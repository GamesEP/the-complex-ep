--!strict
--[[
	What an enemy decides each frame, as a pure function: given its kind, its state and how far
	the nearest player is, where it moves and whether it acts.

	Pure so the timings can be asserted rather than watched. "The melee enemy always telegraphs
	before it hits" is the rule that makes a dash a skill instead of luck, and it is three lines
	here against a Play session and a stopwatch.
]]

local Brain = {}

-- chase: moving into position. windup: about to strike, spin, phantomStep, or grab.
-- spin: dual-blade melee whirling continuously for high DPS. phantomStep (Paso Fantasma):
-- single-sword melee chaining 3+ ultra-fast dashes in different directions before an ambush slash.
-- slamWindup: mace melee raising its crusher overhead before slamming the floor to stun players.
-- beamCharge: rifle ranged unit charging a devastating beam. evade: ranged unit leaping backward.
-- lunge: grabber charging forward. recover: just acted, frozen. hitstun: reeling from a player
-- hit, unable to act or move normally. fuse: the exploder is about to go off. spent: the exploder
-- went off. holding: the grabber is currently immobilising a player.
-- rushWindup / rush: the grabber lowering its shoulder, then bull-charging in a straight line to
-- knock players away (its answer to a player who keeps out of grab reach).
export type Phase =
	"chase"
	| "windup"
	| "spin"
	| "phantomStep"
	| "slamWindup"
	| "axeThrowWindup"
	| "axeRetrieve"
	| "beamCharge"
	| "evade"
	| "lunge"
	| "recover"
	| "hitstun"
	| "fuse"
	| "spent"
	| "holding"
	| "rushWindup"
	| "rush"
	| "bossConeWindup"
	| "bossLeapWindup"
	| "bossLeap"
	| "bossNovaWindup"
	| "areaWindup"
	| "contactWindup"
	| "contactActive"

export type State = {
	phase: Phase,
	endsAt: number,
	nextFireAt: number,
	nextSpinAt: number?,
	nextSpinTickAt: number?,
	pendingSpin: boolean?,
	nextBeamAt: number?,
	nextEvadeAt: number?,
	nextPhantomStepAt: number?,
	phantomStepLeft: number?,
	pendingPhantomStep: boolean?,
	phantomStepFinisher: boolean?,
	nextSlamAt: number?,
	nextAxeThrowAt: number?,
	nextRushAt: number?,
	nextLeapAt: number?,
	nextNovaAt: number?,
	nextAreaAt: number?,
	nextContactAt: number?,
}

export type Intent = {
	move: "toward" | "away" | "hold" | "flank" | "lunge" | "spin" | "phantomStep" | "axeRetrieve" | "evade" | "rush" | "bossLeap" | "contactSurge",
	action: (
		"strike"
		| "spinTick"
		| "phantomStepHop"
		| "slam"
		| "axeThrow"
		| "fire"
		| "beamStart"
		| "beamFire"
		| "evade"
		| "explode"
		| "grab"
		| "grabLunge"
		| "grabCheck"
		| "rushLaunch"
		| "rushCheck"
		| "bossConeSmash"
		| "bossLeapLaunch"
		| "bossLeapLand"
		| "bossNovaFire"
		| "areaLaunch"
		| "contactSurgeStart"
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
	canPhantomStep: boolean?,
	phantomStepCount: number?,
	phantomStepDuration: number?,
	phantomStepRange: number?,
	phantomStepCooldown: number?,
	phantomStepStrikeWindup: number?,
	canSlam: boolean?,
	slamRange: number?,
	slamWindup: number?,
	slamCooldown: number?,
	canAxeThrow: boolean?,
	axeThrowMinRange: number?,
	axeThrowMaxRange: number?,
	axeThrowWindup: number?,
	axeThrowCooldown: number?,
	canBeam: boolean?,
	beamCharge: number?,
	beamCooldown: number?,
	beamRange: number?,
	beamRecover: number?,
	evadeTrigger: number?,
	evadeDuration: number?,
	evadeCooldown: number?,
	canRush: boolean?,
	rushMinRange: number?,
	rushMaxRange: number?,
	rushWindup: number?,
	rushDuration: number?,
	rushCooldown: number?,
	rushRecover: number?,
	coneWindup: number?,
	leapMinRange: number?,
	leapMaxRange: number?,
	leapWindup: number?,
	leapDuration: number?,
	leapCooldown: number?,
	novaWindup: number?,
	novaCooldown: number?,
	areaMaxRange: number?,
	areaWindup: number?,
	areaCooldown: number?,
	contactTriggerRange: number?,
	contactWindup: number?,
	contactDuration: number?,
	contactCooldown: number?,
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
		nextPhantomStepAt = now + 1.8,
		phantomStepLeft = 0,
		pendingPhantomStep = false,
		phantomStepFinisher = false,
		nextSlamAt = now + 1.8,
		nextAxeThrowAt = now + 2.2,
		-- Later than the other abilities: a wave should open with the grabber walking in, not
		-- with every grabber charging the moment it spawns.
		nextRushAt = now + 2.5,
		nextLeapAt = now + 3.0,
		nextNovaAt = now + 5.5,
		nextAreaAt = now + 1.4,
		nextContactAt = now + 1.2,
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
	nextPhantomStepAt: number?,
	phantomStepLeft: number?,
	pendingPhantomStep: boolean?,
	phantomStepFinisher: boolean?,
	nextSlamAt: number?,
	nextRushAt: number?,
	nextLeapAt: number?,
	nextNovaAt: number?,
	nextAxeThrowAt: number?,
	nextAreaAt: number?,
	nextContactAt: number?
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
		nextPhantomStepAt = if nextPhantomStepAt ~= nil then nextPhantomStepAt else state.nextPhantomStepAt,
		phantomStepLeft = if phantomStepLeft ~= nil then phantomStepLeft else 0,
		pendingPhantomStep = if pendingPhantomStep ~= nil then pendingPhantomStep else false,
		phantomStepFinisher = if phantomStepFinisher ~= nil then phantomStepFinisher else false,
		nextSlamAt = if nextSlamAt ~= nil then nextSlamAt else state.nextSlamAt,
		nextAxeThrowAt = if nextAxeThrowAt ~= nil then nextAxeThrowAt else state.nextAxeThrowAt,
		nextRushAt = if nextRushAt ~= nil then nextRushAt else state.nextRushAt,
		nextLeapAt = if nextLeapAt ~= nil then nextLeapAt else state.nextLeapAt,
		nextNovaAt = if nextNovaAt ~= nil then nextNovaAt else state.nextNovaAt,
		nextAreaAt = if nextAreaAt ~= nil then nextAreaAt else state.nextAreaAt,
		nextContactAt = if nextContactAt ~= nil then nextContactAt else state.nextContactAt,
	}
end

local function melee(kind: Kind, state: State, distance: number, now: number, canAttack: boolean): (State, Intent)
	local reach = kind.reach or 0
	if state.phase == "axeRetrieve" then
		-- Unarmed axe enemy sprints directly to its dropped axe on the arena floor.
		return state, { move = "axeRetrieve" }
	end
	if state.phase == "axeThrowWindup" then
		if now >= state.endsAt then
			local cd = kind.axeThrowCooldown or 6.5
			local rec = (kind.recover or 0.8) * 0.9
			return with(state, "recover", now + rec, nil, nil, false, nil, nil, nil, 0, false, false, nil, nil, nil, nil, now + cd),
				{ move = "hold", action = "axeThrow" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "slamWindup" then
		if now >= state.endsAt then
			local slamCd = kind.slamCooldown or 6.5
			local rec = (kind.recover or 0.8) * 1.45
			return with(state, "recover", now + rec, nil, nil, false, nil, nil, nil, 0, false, false, now + slamCd),
				{ move = "hold", action = "slam" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "phantomStep" then
		if now >= state.endsAt then
			local left = (state.phantomStepLeft or 1) - 1
			if left > 0 then
				local stepDur = kind.phantomStepDuration or 0.15
				return with(state, "phantomStep", now + stepDur, nil, nil, false, nil, nil, nil, left, false, false),
					{ move = "phantomStep", action = "phantomStepHop" }
			end
			-- Finished all rapid hops: brief ambush windup before the surprise slash.
			local strikeWindup = kind.phantomStepStrikeWindup or 0.38
			local cd = kind.phantomStepCooldown or 7.0
			return with(state, "windup", now + strikeWindup, nil, nil, false, nil, nil, now + cd, 0, false, true),
				{ move = "hold" }
		end
		return state, { move = "phantomStep" }
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
			if state.pendingPhantomStep and kind.canPhantomStep then
				local steps = math.max(kind.phantomStepCount or 3, 3)
				local stepDur = kind.phantomStepDuration or 0.15
				return with(state, "phantomStep", now + stepDur, nil, nil, false, nil, nil, nil, steps, false, false),
					{ move = "phantomStep", action = "phantomStepHop" }
			end
			if state.pendingSpin and kind.canSpin then
				local spinDur = kind.spinDuration or 1.6
				local tickEvery = kind.spinTickEvery or 0.25
				return with(state, "spin", now + spinDur, state.nextSpinAt, now + tickEvery, false),
					{ move = "spin", action = "spinTick" }
			end
			local rec = if state.phantomStepFinisher then (kind.recover or 0.8) * 1.3 else (kind.recover or 0)
			return with(state, "recover", now + rec, nil, nil, false, nil, nil, nil, 0, false, state.phantomStepFinisher),
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
	-- Axe Throw: mid-range melee specialist hurls its battle-axe at the player (on miss it drops
	-- onto the floor and the enemy must sprint over to retrieve it).
	local axeMin = kind.axeThrowMinRange or 13
	local axeMax = kind.axeThrowMaxRange or 42
	if kind.canAxeThrow == true and now >= (state.nextAxeThrowAt or 0) and distance >= axeMin and distance <= axeMax then
		local throwWindup = kind.axeThrowWindup or 0.65
		return with(state, "axeThrowWindup", now + throwWindup), { move = "hold" }
	end
	if not canAttack then
		return state, { move = "flank" }
	end
	-- Mace ground slam: hoists the heavy mace overhead and smashes the floor to stagger & stun.
	local slamRange = kind.slamRange or 13
	if kind.canSlam == true and now >= (state.nextSlamAt or 0) and distance <= slamRange then
		local slamWindup = kind.slamWindup or 0.78
		return with(state, "slamWindup", now + slamWindup), { move = "hold" }
	end
	-- Single-sword Paso Fantasma: activates from mid-range to chain 3+ rapid multi-directional
	-- dashes into a surprise parry-only ambush strike.
	local phantomRange = kind.phantomStepRange or 24
	if kind.canPhantomStep == true and now >= (state.nextPhantomStepAt or 0) and distance <= phantomRange then
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
	if state.phase == "rushWindup" then
		if now >= state.endsAt then
			return with(state, "rush", now + (kind.rushDuration or 0)), { move = "rush", action = "rushLaunch" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "rush" then
		if now >= state.endsAt then
			return with(state, "recover", now + (kind.rushRecover or kind.recover or 0)), { move = "hold" }
		end
		return state, { move = "rush", action = "rushCheck" }
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
	-- Out of grab reach but inside charging distance: the rush. Grab wins when both apply, so a
	-- player who walks into the grabber is still grabbed rather than merely shoved.
	if
		kind.canRush == true
		and now >= (state.nextRushAt or 0)
		and distance >= (kind.rushMinRange or 0)
		and distance <= (kind.rushMaxRange or 0)
	then
		local cooldownFrom = now + (kind.rushCooldown or 0)
		return with(state, "rushWindup", now + (kind.rushWindup or 0), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, cooldownFrom),
			{ move = "hold" }
	end
	return state, { move = "toward" }
end

local function bossOh(kind: Kind, state: State, distance: number, now: number, _canAttack: boolean): (State, Intent)
	if state.phase == "bossConeWindup" then
		if now >= state.endsAt then
			return with(state, "recover", now + (kind.recover or 1.2)), { move = "hold", action = "bossConeSmash" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "bossLeapWindup" then
		if now >= state.endsAt then
			return with(state, "bossLeap", now + (kind.leapDuration or 0.72)), { move = "bossLeap", action = "bossLeapLaunch" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "bossLeap" then
		if now >= state.endsAt then
			return with(state, "recover", now + (kind.recover or 1.25)), { move = "hold", action = "bossLeapLand" }
		end
		return state, { move = "bossLeap" }
	end
	if state.phase == "bossNovaWindup" then
		if now >= state.endsAt then
			return with(state, "recover", now + (kind.recover or 1.2)), { move = "hold", action = "bossNovaFire" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "recover" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "hold" }
	end

	-- 1. 360-deg plasma nova when off cooldown and within arena combat reach.
	if now >= (state.nextNovaAt or 0) and distance <= 52 then
		local nextNova = now + (kind.novaCooldown or 9.0)
		return with(state, "bossNovaWindup", now + (kind.novaWindup or 1.0), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nextNova),
			{ move = "hold" }
	end
	-- 2. Seismic meteor leap to close mid/long range gaps dramatically.
	if now >= (state.nextLeapAt or 0) and distance >= (kind.leapMinRange or 16) and distance <= (kind.leapMaxRange or 55) then
		local nextLeap = now + (kind.leapCooldown or 7.5)
		return with(state, "bossLeapWindup", now + (kind.leapWindup or 0.65), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nextLeap, nil),
			{ move = "hold" }
	end
	-- 3. Heavy frontal cone smash up close.
	if distance <= (kind.reach or 18) then
		return with(state, "bossConeWindup", now + (kind.coneWindup or 0.85)), { move = "hold" }
	end
	return state, { move = "toward" }
end

local function area(kind: Kind, state: State, distance: number, now: number, canAttack: boolean): (State, Intent)
	if state.phase == "areaWindup" then
		if now >= state.endsAt then
			local cd = kind.areaCooldown or 4.2
			local rec = kind.recover or 0.75
			return with(state, "recover", now + rec, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, now + cd, nil),
				{ move = "hold", action = "areaLaunch" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "recover" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "hold" }
	end

	local keepAway = kind.keepAway or 30
	local maxRange = kind.areaMaxRange or (keepAway * Brain.FIRE_REACH)
	if canAttack and now >= (state.nextAreaAt or 0) and distance <= maxRange then
		local windup = kind.areaWindup or 0.65
		return with(state, "areaWindup", now + windup), { move = "hold" }
	end

	local move: "toward" | "away" | "hold" = "hold"
	if distance < keepAway * 0.65 then
		move = "away"
	elseif distance > keepAway * 1.15 then
		move = "toward"
	end
	return state, { move = move }
end

local function contact(kind: Kind, state: State, distance: number, now: number, _canAttack: boolean): (State, Intent)
	if state.phase == "contactWindup" then
		if now >= state.endsAt then
			local dur = kind.contactDuration or 2.8
			return with(state, "contactActive", now + dur), { move = "contactSurge", action = "contactSurgeStart" }
		end
		return state, { move = "hold" }
	end
	if state.phase == "contactActive" then
		if now >= state.endsAt then
			local cd = kind.contactCooldown or 3.2
			local rec = kind.recover or 0.65
			return with(state, "recover", now + rec, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, now + cd),
				{ move = "hold" }
		end
		return state, { move = "contactSurge" }
	end
	if state.phase == "recover" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "hold" }
	end

	local triggerRange = kind.contactTriggerRange or 18
	if now >= (state.nextContactAt or 0) and distance <= triggerRange then
		local windup = kind.contactWindup or 0.55
		return with(state, "contactWindup", now + windup), { move = "hold" }
	end
	return state, { move = "toward" }
end

local BEHAVIOURS = {
	melee = melee,
	ranged = ranged,
	exploder = exploder,
	grabber = grabber,
	area = area,
	contact = contact,
	bossOh = bossOh,
}

-- Transitions a grabber into `holding` once EnemyService confirms the target was caught.
function Brain.enterHolding(state: State): State
	return with(state, "holding", 0)
end

-- Transitions a grabber out of `holding` into `recover` so it cannot re-grab on the next frame.
function Brain.releaseGrab(state: State, recover: number, now: number): State
	return with(state, "recover", now + recover)
end

-- Ends a rush early (it hit a wall), straight into the grabber's post-rush recovery.
function Brain.endRush(state: State, recover: number, now: number): State
	return with(state, "recover", now + recover)
end

-- Transitions an axe enemy into `axeRetrieve` when its thrown axe misses and lands on the floor.
function Brain.enterAxeRetrieve(state: State): State
	return with(state, "axeRetrieve", 0)
end

-- Finishes retrieving a dropped axe from the floor, entering a brief recovery before resuming melee.
function Brain.finishAxeRetrieve(state: State, recover: number, cooldown: number, now: number): State
	return with(state, "recover", now + recover, nil, nil, false, nil, nil, nil, 0, false, false, nil, nil, nil, nil, now + cooldown)
end

-- Applies DMC-style hitstun when an enemy takes a player hit: interrupts active windups/abilities,
-- locks the enemy in `hitstun` (unable to attack or chase), and pushes back its attack & evade
-- cooldowns so comboed targets cannot instantly retaliate or leap away between hits.
-- Grabbers holding a player, spent exploders, and active Paso Fantasma dashes are not overridden,
-- nor anything mid-flight: a rushing grabber, a leaping boss, or an axe enemy walking to its
-- dropped axe (hitstun would return it to `chase` unarmed, with the axe left on the floor).
function Brain.applyHitstun(
	kindName: string,
	state: State,
	duration: number,
	now: number,
	actionDelay: number?
): (State, boolean)
	if duration <= 0 then
		return state, false
	end
	if
		state.phase == "holding"
		or state.phase == "spent"
		or state.phase == "phantomStep"
		or state.phase == "rush"
		or state.phase == "bossLeap"
		or state.phase == "axeRetrieve"
		or (state.phase == "windup" and state.phantomStepFinisher == true)
	then
		return state, false
	end
	-- A fusing exploder jolts slightly without resetting its detonation forever.
	if kindName == "exploder" and state.phase == "fuse" then
		local delay = math.min(duration * 0.25, 0.2)
		return with(state, "fuse", state.endsAt + delay), true
	end

	local nextEndsAt = if state.phase == "hitstun" then math.max(state.endsAt, now + duration) else now + duration
	local readyAfter = nextEndsAt + math.max(actionDelay or 0, 0)
	local pushed = with(
		state,
		"hitstun",
		nextEndsAt,
		math.max(state.nextSpinAt or 0, readyAfter),
		0,
		false,
		math.max(state.nextBeamAt or 0, readyAfter),
		math.max(state.nextEvadeAt or 0, readyAfter),
		math.max(state.nextPhantomStepAt or 0, readyAfter),
		0,
		false,
		false,
		math.max(state.nextSlamAt or 0, readyAfter),
		math.max(state.nextRushAt or 0, readyAfter),
		nil,
		nil,
		math.max(state.nextAxeThrowAt or 0, readyAfter),
		math.max(state.nextAreaAt or 0, readyAfter),
		math.max(state.nextContactAt or 0, readyAfter)
	)
	pushed.nextFireAt = math.max(state.nextFireAt, readyAfter)
	return pushed, true
end

-- Movement speed multiplier while dazed after taking consecutive combo hits.
function Brain.dazeSpeedFactor(staggerStacks: number, factors: { number }): number
	if staggerStacks <= 0 or #factors == 0 then
		return 1
	end
	return factors[math.clamp(staggerStacks, 1, #factors)]
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
	if state.phase == "hitstun" then
		if now >= state.endsAt then
			return with(state, "chase", 0), { move = "hold" }
		end
		return state, { move = "hold" }
	end
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

	-- Axe Throw ability: mid-range windup -> throws axe -> on miss enters axeRetrieve until picked up.
	local axeKind: Kind = {
		reach = 6,
		windup = 0.45,
		recover = 0.8,
		canAxeThrow = true,
		axeThrowMinRange = 13,
		axeThrowMaxRange = 42,
		axeThrowWindup = 0.65,
		axeThrowCooldown = 6.5,
	}
	local sa: any = Brain.initial(0)
	sa, intent = Brain.step("melee", axeKind, sa, 24, 3.0)
	assert(is(sa.phase, "axeThrowWindup") and is(intent.move, "hold"), "axe enemy winds up throw at mid-range")
	sa, intent = Brain.step("melee", axeKind, sa, 24, 3.7)
	assert(is(intent.action, "axeThrow") and is(sa.phase, "recover"), "axe enemy hurls axe when windup completes")
	sa = Brain.enterAxeRetrieve(sa)
	sa, intent = Brain.step("melee", axeKind, sa, 24, 4.0)
	assert(is(sa.phase, "axeRetrieve") and is(intent.move, "axeRetrieve"), "unarmed axe enemy sprints to retrieve dropped axe")
	sa = Brain.finishAxeRetrieve(sa, 0.45, 6.5, 5.0)
	assert(is(sa.phase, "recover"), "picking up axe enters brief recovery")

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

	-- Single-sword Paso Fantasma: prep windup -> 3 rapid multi-direction hops -> finisher windup -> strike.
	local phantomKind: Kind = {
		reach = 6,
		windup = 0.45,
		recover = 0.8,
		canPhantomStep = true,
		phantomStepCount = 3,
		phantomStepDuration = 0.15,
		phantomStepRange = 24,
		phantomStepCooldown = 7.0,
		phantomStepStrikeWindup = 0.38,
	}
	local ss: any = Brain.initial(0)
	ss, intent = Brain.step("melee", phantomKind, ss, 18, 2.0)
	assert(is(ss.phase, "windup") and ss.pendingPhantomStep == true, "sword melee winds up into Paso Fantasma")
	ss, intent = Brain.step("melee", phantomKind, ss, 18, 2.45)
	assert(is(ss.phase, "phantomStep") and is(intent.action, "phantomStepHop") and ss.phantomStepLeft == 3, "hop 1 fires")
	ss, intent = Brain.step("melee", phantomKind, ss, 12, 2.61)
	assert(is(ss.phase, "phantomStep") and is(intent.action, "phantomStepHop") and ss.phantomStepLeft == 2, "hop 2 fires")
	ss, intent = Brain.step("melee", phantomKind, ss, 10, 2.77)
	assert(is(ss.phase, "phantomStep") and is(intent.action, "phantomStepHop") and ss.phantomStepLeft == 1, "hop 3 fires")
	ss, intent = Brain.step("melee", phantomKind, ss, 5, 2.93)
	assert(is(ss.phase, "windup") and ss.phantomStepFinisher == true, "after 3 hops enters ambush strike windup")
	ss, intent = Brain.step("melee", phantomKind, ss, 5, 3.35)
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

	-- Grabber rush: from charging distance it telegraphs, then charges in a straight line, then
	-- recovers; it waits out its cooldown, and grab still wins inside grab reach.
	local rusher: Kind = {
		reach = 13,
		windup = 0.55,
		lungeDuration = 0.28,
		recover = 1.6,
		canRush = true,
		rushMinRange = 16,
		rushMaxRange = 34,
		rushWindup = 0.7,
		rushDuration = 0.6,
		rushCooldown = 6.5,
		rushRecover = 1.1,
	}
	local ru = Brain.initial(0)
	ru, intent = Brain.step("grabber", rusher, ru, 25, 1)
	assert(is(ru.phase, "chase") and is(intent.move, "toward"), "no rush before its first cooldown")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 3)
	assert(is(ru.phase, "rushWindup") and is(intent.move, "hold") and is(intent.action, nil), "rush telegraphs, it does not charge at once")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 3.5)
	assert(is(ru.phase, "rushWindup") and is(intent.action, nil), "the rush windup holds still")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 3.7)
	assert(is(ru.phase, "rush") and is(intent.move, "rush") and is(intent.action, "rushLaunch"), "the windup launches the rush")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 3.9)
	assert(is(intent.action, "rushCheck"), "the rush checks for contact every frame")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 4.3)
	assert(is(ru.phase, "recover") and is(intent.move, "hold"), "the rush ends in recovery")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 5.5)
	assert(is(ru.phase, "chase"), "recovery ends")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 6)
	assert(is(ru.phase, "chase") and is(intent.move, "toward"), "no second rush inside the cooldown")
	ru, intent = Brain.step("grabber", rusher, ru, 25, 9.6)
	assert(is(ru.phase, "rushWindup"), "rushes again once the cooldown has passed")
	local near = Brain.initial(0)
	near, intent = Brain.step("grabber", rusher, near, 10, 5)
	assert(is(near.phase, "windup"), "inside grab reach the grabber grabs rather than rushes")
	local far = Brain.initial(0)
	far, intent = Brain.step("grabber", rusher, far, 50, 5)
	assert(is(far.phase, "chase") and is(intent.move, "toward"), "beyond rush range it walks in")
	local walled = Brain.endRush({ phase = "rush", endsAt = 9, nextFireAt = 0 }, 1.1, 4)
	assert(is(walled.phase, "recover") and walled.endsAt == 5.1, "a rush stopped by a wall recovers")

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

	-- Mace ground slam: hoists mace overhead in slamWindup, emits slam action on completion, then respects cooldown.
	local maceKind: Kind = {
		reach = 6,
		windup = 0.45,
		recover = 0.8,
		canSlam = true,
		slamRange = 13,
		slamWindup = 0.78,
		slamCooldown = 6.5,
	}
	local mc: any = Brain.initial(0)
	mc, intent = Brain.step("melee", maceKind, mc, 11, 2.0, true)
	assert(is(mc.phase, "slamWindup") and is(intent.move, "hold") and is(intent.action, nil), "mace enters slamWindup in slamRange")
	mc, intent = Brain.step("melee", maceKind, mc, 11, 2.4, true)
	assert(is(mc.phase, "slamWindup") and is(intent.action, nil), "mace holds during slamWindup")
	mc, intent = Brain.step("melee", maceKind, mc, 11, 2.8, true)
	assert(is(mc.phase, "recover") and is(intent.action, "slam"), "mace emits slam action at end of slamWindup")
	mc, intent = Brain.step("melee", maceKind, mc, 11, 5.0, true)
	assert(is(mc.phase, "chase"), "mace resumes chasing after slam recover")
	mc, intent = Brain.step("melee", maceKind, mc, 11, 5.1, true)
	assert(is(mc.phase, "chase"), "mace does not re-slam before slamCooldown elapses")
	mc, intent = Brain.step("melee", maceKind, mc, 11, 9.5, true)
	assert(is(mc.phase, "slamWindup"), "mace slams again once slamCooldown expires")

	-- Boss Oh cycles through cone smash, seismic leap, and 360-deg nova cleanly.
	local bossKind: Kind = {
		reach = 18,
		recover = 1.2,
		coneWindup = 0.85,
		leapMinRange = 16,
		leapMaxRange = 55,
		leapWindup = 0.65,
		leapDuration = 0.72,
		leapCooldown = 7.5,
		novaWindup = 1.0,
		novaCooldown = 9.0,
	}
	local bo: any = Brain.initial(0)
	bo, intent = Brain.step("bossOh", bossKind, bo, 12, 1.0, true)
	assert(is(bo.phase, "bossConeWindup"), "boss Oh winds up frontal cone smash up close")
	bo, intent = Brain.step("bossOh", bossKind, bo, 12, 1.9, true)
	assert(is(bo.phase, "recover") and is(intent.action, "bossConeSmash"), "boss Oh unleashes cone smash")
	bo, intent = Brain.step("bossOh", bossKind, bo, 28, 3.2, true)
	assert(is(bo.phase, "chase"), "boss Oh exits recover")
	bo, intent = Brain.step("bossOh", bossKind, bo, 28, 3.3, true)
	assert(is(bo.phase, "bossLeapWindup"), "boss Oh winds up seismic leap at mid range")
	bo, intent = Brain.step("bossOh", bossKind, bo, 28, 4.0, true)
	assert(is(bo.phase, "bossLeap") and is(intent.action, "bossLeapLaunch"), "boss Oh launches leap")
	bo, intent = Brain.step("bossOh", bossKind, bo, 5, 4.8, true)
	assert(is(bo.phase, "recover") and is(intent.action, "bossLeapLand"), "boss Oh lands seismic slam")
	bo, intent = Brain.step("bossOh", bossKind, bo, 20, 6.2, true)
	assert(is(bo.phase, "chase"), "boss Oh exits leap recover")
	bo, intent = Brain.step("bossOh", bossKind, bo, 20, 6.3, true)
	assert(is(bo.phase, "bossNovaWindup"), "boss Oh winds up 360 nova once cooldown is ready")
	bo, intent = Brain.step("bossOh", bossKind, bo, 20, 7.4, true)
	assert(is(bo.phase, "recover") and is(intent.action, "bossNovaFire"), "boss Oh fires 360 nova")

	-- Hitstun interrupts windups/actions, prevents attacking & chasing while staggered, pushes back
	-- ranged fire/evade cooldowns, and resumes chase cleanly once elapsed.
	local hs: any = Brain.initial(0)
	hs, intent = Brain.step("melee", meleeKind, hs, 5, 1)
	assert(is(hs.phase, "windup"), "melee starts windup before hitstun test")
	local stunned: boolean
	hs, stunned = Brain.applyHitstun("melee", hs, 0.65, 1.2, 0.35)
	assert(stunned and is(hs.phase, "hitstun"), "hitstun interrupts melee windup")
	hs, intent = Brain.step("melee", meleeKind, hs, 4, 1.5)
	assert(is(hs.phase, "hitstun") and is(intent.move, "hold") and is(intent.action, nil), "hitstun holds enemy still without attacking")
	hs, intent = Brain.step("melee", meleeKind, hs, 4, 1.9)
	assert(is(hs.phase, "chase"), "hitstun ends back into chase")

	-- Ranged enemy in hitstun cannot immediately fire or backstep-evade right when hitstun ends.
	local rhs: any = Brain.initial(0)
	rhs, stunned = Brain.applyHitstun("ranged", rhs, 0.6, 2.0, 0.4)
	assert(stunned and rhs.nextFireAt >= 3.0 and (rhs.nextEvadeAt or 0) >= 3.0, "hitstun delays ranged fire & evade")

	-- Holding grabber is not knocked out of holding by hitstun (handled by escape progress).
	local gHoldState = Brain.enterHolding(Brain.initial(0))
	local gAfter, gStunned = Brain.applyHitstun("grabber", gHoldState, 0.8, 2.0, 0.3)
	assert(not gStunned and is(gAfter.phase, "holding"), "hitstun does not break holding phase directly")

	-- Mid-flight phases are never flinched out of: they would freeze mid-air or strand an axe.
	for _, phase in ipairs({ "rush", "bossLeap", "axeRetrieve" }) do
		local flying: any = Brain.initial(0)
		flying.phase = phase
		local after, flinched = Brain.applyHitstun("melee", flying, 0.8, 2.0, 0.3)
		assert(not flinched and is(after.phase, phase), `hitstun does not interrupt {phase}`)
	end

	-- A flinched grabber cannot rush the instant hitstun ends.
	local rushReady: any = Brain.initial(0)
	rushReady.nextRushAt = 0
	local rushStunned = Brain.applyHitstun("grabber", rushReady, 0.6, 2.0, 0.4)
	assert((rushStunned.nextRushAt or 0) >= 3.0, "hitstun delays the grabber rush")

	-- Area (Artillero): holds mid-range, telegraphs mortar windup, launches hazard zone, recovers & respects cooldown.
	local areaKind: Kind = { keepAway = 30, areaMaxRange = 48, areaWindup = 0.65, areaCooldown = 4.2, recover = 0.75 }
	local ar: any = Brain.initial(0)
	ar, intent = Brain.step("area", areaKind, ar, 12, 0.5, true)
	assert(is(intent.move, "away") and is(intent.action, nil), "area unit backs off when player closes in")
	ar, intent = Brain.step("area", areaKind, ar, 30, 1.5, false)
	assert(is(ar.phase, "chase") and is(intent.action, nil), "area unit respects stagger gate")
	ar, intent = Brain.step("area", areaKind, ar, 30, 1.5, true)
	assert(is(ar.phase, "areaWindup") and is(intent.move, "hold"), "area unit winds up mortar launch in range")
	ar, intent = Brain.step("area", areaKind, ar, 30, 2.2, true)
	assert(is(ar.phase, "recover") and is(intent.action, "areaLaunch"), "area unit emits areaLaunch when windup finishes")
	ar, intent = Brain.step("area", areaKind, ar, 30, 3.0, true)
	assert(is(ar.phase, "chase"), "area unit exits recover")
	ar, intent = Brain.step("area", areaKind, ar, 30, 4.0, true)
	assert(is(ar.phase, "chase"), "area unit waits out areaCooldown before launching again")
	local arHit, arFl = Brain.applyHitstun("area", { phase = "areaWindup", endsAt = 5, nextFireAt = 0, nextAreaAt = 0 }, 0.6, 2.0, 0.4)
	assert(arFl and is(arHit.phase, "hitstun") and (arHit.nextAreaAt or 0) >= 3.0, "hitstun interrupts areaWindup and delays next launch")

	-- Contact (Voltaico): chases -> winds up electric surge -> moves in contactSurge -> recovers & respects cooldown.
	local contactKind: Kind = {
		contactTriggerRange = 18,
		contactWindup = 0.55,
		contactDuration = 2.8,
		contactCooldown = 3.2,
		recover = 0.65,
	}
	local ct: any = Brain.initial(0)
	ct, intent = Brain.step("contact", contactKind, ct, 30, 2.0, true)
	assert(is(ct.phase, "chase") and is(intent.move, "toward"), "contact unit chases when outside trigger range")
	ct, intent = Brain.step("contact", contactKind, ct, 14, 2.0, true)
	assert(is(ct.phase, "contactWindup") and is(intent.move, "hold"), "contact unit telegraphs surge windup")
	ct, intent = Brain.step("contact", contactKind, ct, 14, 2.6, true)
	assert(is(ct.phase, "contactActive") and is(intent.move, "contactSurge") and is(intent.action, "contactSurgeStart"), "contact unit enters active electric surge")
	ct, intent = Brain.step("contact", contactKind, ct, 8, 4.0, true)
	assert(is(ct.phase, "contactActive") and is(intent.move, "contactSurge") and is(intent.action, nil), "contact unit keeps surging during duration")
	ct, intent = Brain.step("contact", contactKind, ct, 8, 5.5, true)
	assert(is(ct.phase, "recover") and is(intent.move, "hold"), "contact surge ends in recover")
	ct, intent = Brain.step("contact", contactKind, ct, 8, 6.2, true)
	assert(is(ct.phase, "chase"), "contact unit resumes chasing after recover")
	ct, intent = Brain.step("contact", contactKind, ct, 8, 7.0, true)
	assert(is(ct.phase, "chase"), "contact unit waits out contactCooldown before surging again")
	local ctHit, ctFl = Brain.applyHitstun("contact", { phase = "contactActive", endsAt = 9, nextFireAt = 0, nextContactAt = 0 }, 0.6, 2.0, 0.4)
	assert(ctFl and is(ctHit.phase, "hitstun") and (ctHit.nextContactAt or 0) >= 3.0, "hitstun interrupts contactActive and delays next surge")

	-- Progressive daze speed factors drop with each stack and clamp cleanly.
	local factors = { 0.6, 0.4, 0.25, 0.15 }
	assert(Brain.dazeSpeedFactor(0, factors) == 1, "zero stacks keeps full speed")
	assert(Brain.dazeSpeedFactor(1, factors) == 0.6, "1 stack slows to 60%")
	assert(Brain.dazeSpeedFactor(3, factors) == 0.25, "3 stacks slows to 25%")
	assert(Brain.dazeSpeedFactor(9, factors) == 0.15, "excess stacks clamp to minimum speed factor")
end

return Brain
