--!strict
--[[
	Pure squad-level tactical AI for enemies:
	  - Attack-token budgeting per player (`assignMeleeTokens`): at most `maxAttackers` melee units
	    commit to striking a given player at once; extras become flankers orbiting at a pressure
	    ring and rotate in the instant an attacker enters recovery or dies.
	  - Flanking orbit vector (`flankDirection`): smoothly holds `flankRadius` while circling around
	    the player's flanks instead of dogpiling or standing frozen.
	  - Co-op target distribution (`chooseTarget`): spreads enemies across teammates using a crowd
	    penalty rather than sending the entire wave at one player.
	  - Ranged stagger (`canFireStaggered`), ranged lateral strafe (`strafeDirection`), exploder
	    intercept lead (`interceptPoint`), and grabber back-flank bias (`grabberApproach`).

	Pure so `make test` proves every tactical rule offline without needing Studio. See docs/combat.md.
]]

local Tactics = {}

export type MeleeCandidate = {
	id: any,
	targetKey: any,
	distance: number,
	phase: string,
}

export type TargetInfo = {
	key: any,
	position: Vector3,
}

export type SectorEntry = {
	id: any,
	targetKey: any,
	position: Vector3,
	targetPosition: Vector3,
	jitter: number?,
}

local TWO_PI = math.pi * 2

local function flatUnit(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude < 1e-3 then
		return nil
	end
	return f.Unit
end

-- Shortest signed angular delta from `fromAngle` to `toAngle` in (-pi, pi].
local function angleDelta(fromAngle: number, toAngle: number): number
	local diff = (toAngle - fromAngle + math.pi) % TWO_PI - math.pi
	return diff
end

-- Assigns spread-out 360-degree approach angles around each player so enemies fan out and surround
-- the player from distinct directions instead of clumping into a single herdable ball.
-- Sorting by current angle around the player minimizes crossing paths while forcing even tightly
-- spawned enemies apart by `2*pi / N` radians.
function Tactics.assignSectors(entries: { SectorEntry }, rotationOffset: number?): { [any]: number }
	local assigned: { [any]: number } = {}
	local byTarget: { [any]: { { entry: SectorEntry, currentAngle: number } } } = {}

	for _, entry in ipairs(entries) do
		local dx = entry.position.X - entry.targetPosition.X
		local dz = entry.position.Z - entry.targetPosition.Z
		local curAngle = math.atan2(dz, dx)
		local bucket = byTarget[entry.targetKey]
		if not bucket then
			bucket = {}
			byTarget[entry.targetKey] = bucket
		end
		table.insert(bucket, { entry = entry, currentAngle = curAngle })
	end

	local baseSpin = rotationOffset or 0
	for _, bucket in pairs(byTarget) do
		table.sort(bucket, function(a, b)
			if math.abs(a.currentAngle - b.currentAngle) > 1e-4 then
				return a.currentAngle < b.currentAngle
			end
			return (a.entry.jitter or 0) < (b.entry.jitter or 0)
		end)
		local count = #bucket
		local step = TWO_PI / math.max(count, 1)
		-- Anchor the ring to the first unit's sector + slow dynamic rotation so the whole pack
		-- never snaps abruptly while still fanning out aggressively.
		local anchor = bucket[1].currentAngle + baseSpin
		for i, item in ipairs(bucket) do
			local jitter = math.clamp(item.entry.jitter or 0, -0.35, 0.35) * step
			assigned[item.entry.id] = anchor + (i - 1) * step + jitter
		end
	end

	return assigned
end

-- Computes a curved steering vector toward an enemy's assigned angular slot around `targetPos` at
-- `desiredRadius`. When the enemy is far from its assigned angle (e.g. clumped with allies on one
-- side), it swings wide tangentially around the player to break the clump and pincer from its own
-- direction instead of marching straight into the pile.
function Tactics.steerToSector(
	position: Vector3,
	targetPosition: Vector3,
	targetAngle: number,
	desiredRadius: number,
	band: number,
	orbitSign: number,
	orbitBias: number?
): Vector3
	local fromTarget = Vector3.new(position.X - targetPosition.X, 0, position.Z - targetPosition.Z)
	local dist = fromTarget.Magnitude
	local radialOut = if dist > 1e-3 then fromTarget / dist else Vector3.new(math.cos(targetAngle), 0, math.sin(targetAngle))
	local currentAngle = math.atan2(radialOut.Z, radialOut.X)
	local dAngle = angleDelta(currentAngle, targetAngle)

	-- Tangent along the shortest angular arc toward `targetAngle` (or `orbitSign` once on slot).
	local dirSign: number
	if math.abs(dAngle) > 0.22 then
		dirSign = if dAngle >= 0 then 1 else -1
	else
		dirSign = if orbitSign < 0 then -1 else 1
	end
	local tangent = Vector3.new(-radialOut.Z * dirSign, 0, radialOut.X * dirSign)

	-- Radial pull toward `desiredRadius`; hold slightly wider while swinging around to another side
	-- so enemies never cut directly across the front pile.
	local swingOut = math.clamp(math.abs(dAngle) / math.pi, 0, 1)
	local effectiveRadius = desiredRadius + swingOut * 5
	local halfBand = math.max(band, 0.5)
	local radialWeight = 0
	if dist > effectiveRadius + halfBand then
		radialWeight = -math.clamp((dist - effectiveRadius) / math.max(effectiveRadius, 1), 0.35, 1.35)
	elseif dist < effectiveRadius - halfBand then
		radialWeight = math.clamp((effectiveRadius - dist) / math.max(effectiveRadius, 1), 0.45, 1.35)
	end

	local tangentWeight = math.max(math.clamp(math.abs(dAngle) * 1.15, 0, 1.45), orbitBias or 0.55)
	local combined = tangent * tangentWeight + radialOut * radialWeight
	return flatUnit(combined) or tangent
end

-- Computes a pincer approach vector for an active attacker (or exploder) moving in toward its
-- assigned sector angle: arcs sideways while outside close strike distance so multiple attackers
-- arrive from opposite sides instead of shoulder-to-shoulder.
function Tactics.pincerApproach(
	position: Vector3,
	targetPosition: Vector3,
	targetAngle: number,
	curveWeight: number
): Vector3
	local toTarget = Vector3.new(targetPosition.X - position.X, 0, targetPosition.Z - position.Z)
	local dist = toTarget.Magnitude
	local radialIn = if dist > 1e-3 then toTarget / dist else Vector3.new(-math.cos(targetAngle), 0, -math.sin(targetAngle))
	if dist < 5.5 or curveWeight <= 0 then
		return radialIn
	end
	local currentAngle = math.atan2(-radialIn.Z, -radialIn.X)
	local dAngle = angleDelta(currentAngle, targetAngle)
	local arcSign = if dAngle >= 0 then 1 else -1
	-- Tangent around the player in the direction that moves the enemy toward `targetAngle`.
	local tangent = Vector3.new(radialIn.Z * arcSign, 0, -radialIn.X * arcSign)
	local angularNeed = math.clamp(math.abs(dAngle) / (math.pi * 0.65), 0, 1)
	local distFade = math.clamp((dist - 5.5) / 10, 0.2, 1)
	local combined = radialIn + tangent * (angularNeed * curveWeight * 1.65 * distFade)
	return flatUnit(combined) or radialIn
end

-- Strong anti-clumping repulsion vector away from nearby allies, including a lateral deflection
-- component when two allies are tightly stacked so they peel apart around each other cleanly.
function Tactics.antiClumpPush(
	position: Vector3,
	neighborPositions: { Vector3 },
	spacing: number,
	orbitSign: number,
	weight: number?
): Vector3
	if spacing <= 0 then
		return Vector3.zero
	end
	local push = Vector3.zero
	local sign = if orbitSign < 0 then -1 else 1
	for _, otherPos in ipairs(neighborPositions) do
		local apart = Vector3.new(position.X - otherPos.X, 0, position.Z - otherPos.Z)
		local gap = apart.Magnitude
		if gap < spacing then
			local unit = if gap > 1e-3 then apart / gap else Vector3.new(sign, 0, 0)
			-- Quadratic ramp makes close overlap strongly repulsive so waves resist balling up.
			local t = (spacing - gap) / spacing
			local strength = t * (0.75 + 1.25 * t)
			local side = Vector3.new(-unit.Z * sign, 0, unit.X * sign) * (0.35 * t)
			push += (unit + side) * strength
		end
	end
	local scale = weight or 1
	if push.Magnitude > 1e-3 then
		push *= scale
		if push.Magnitude > 2.2 then
			push = push.Unit * 2.2
		end
	end
	return push
end

-- Assigns up to `maxAttackers` melee attack tokens per `targetKey`. Units already in `windup`
-- keep priority so an active telegraph is never interrupted mid-swing; remaining slots go to
-- the closest ready (`chase`) units. Units in `recover` never hold a token so flankers rotate in.
function Tactics.assignMeleeTokens(candidates: { MeleeCandidate }, maxAttackers: number): { [any]: boolean }
	local granted: { [any]: boolean } = {}
	if maxAttackers <= 0 then
		return granted
	end

	local byTarget: { [any]: { MeleeCandidate } } = {}
	for _, c in ipairs(candidates) do
		if c.phase ~= "recover" and c.phase ~= "spent" and c.phase ~= "holding" then
			local bucket = byTarget[c.targetKey]
			if not bucket then
				bucket = {}
				byTarget[c.targetKey] = bucket
			end
			table.insert(bucket, c)
		end
	end

	for _, bucket in pairs(byTarget) do
		table.sort(bucket, function(a, b)
			local aCommitted = a.phase == "windup" or a.phase == "spin" or a.phase == "sandevistan"
			local bCommitted = b.phase == "windup" or b.phase == "spin" or b.phase == "sandevistan"
			if aCommitted ~= bCommitted then
				return aCommitted
			end
			return a.distance < b.distance
		end)
		local limit = math.min(#bucket, maxAttackers)
		for i = 1, limit do
			granted[bucket[i].id] = true
		end
	end

	return granted
end

-- Picks the best target for an enemy, biasing slightly away from already-crowded teammates in
-- co-op (`crowdPenalty` studs per enemy already assigned to that target).
function Tactics.chooseTarget(
	position: Vector3,
	targets: { TargetInfo },
	assignedCounts: { [any]: number },
	crowdPenalty: number
): (TargetInfo?, number)
	local best: TargetInfo? = nil
	local bestScore = math.huge
	local bestRealDist = math.huge
	for _, target in ipairs(targets) do
		local dist = Vector3.new(target.position.X - position.X, 0, target.position.Z - position.Z).Magnitude
		local crowd = assignedCounts[target.key] or 0
		local score = dist + crowd * math.max(crowdPenalty, 0)
		if score < bestScore then
			best = target
			bestScore = score
			bestRealDist = dist
		end
	end
	return best, bestRealDist
end

-- Flat movement direction for a flanking unit orbiting a target at `flankRadius` (+/- `band`).
-- Moves outward if too close, inward if too far, and circles tangentially (`orbitSign` +1/-1)
-- around the player so waiting enemies actively surround them instead of stacking or freezing.
function Tactics.flankDirection(
	position: Vector3,
	targetPosition: Vector3,
	flankRadius: number,
	band: number,
	orbitSign: number
): Vector3
	local toTarget = Vector3.new(targetPosition.X - position.X, 0, targetPosition.Z - position.Z)
	local dist = toTarget.Magnitude
	local radial = if dist > 1e-3 then toTarget / dist else Vector3.new(0, 0, -1)
	local sign = if orbitSign < 0 then -1 else 1
	-- Tangent perpendicular to radial on the XZ floor.
	local tangent = Vector3.new(-radial.Z * sign, 0, radial.X * sign)

	local halfBand = math.max(band, 0.5)
	local radialWeight = 0
	if dist > flankRadius + halfBand then
		radialWeight = math.clamp((dist - flankRadius) / math.max(flankRadius, 1), 0.35, 1.2)
	elseif dist < flankRadius - halfBand then
		radialWeight = -math.clamp((flankRadius - dist) / math.max(flankRadius, 1), 0.35, 1.2)
	end

	local combined = tangent + radial * radialWeight
	return flatUnit(combined) or tangent
end

-- Lateral strafe direction for a ranged unit holding its preferred distance so it repositions
-- around cover/crowd rather than acting like a static turret.
function Tactics.strafeDirection(position: Vector3, targetPosition: Vector3, orbitSign: number): Vector3
	local toTarget = Vector3.new(targetPosition.X - position.X, 0, targetPosition.Z - position.Z)
	local radial = flatUnit(toTarget) or Vector3.new(0, 0, -1)
	local sign = if orbitSign < 0 then -1 else 1
	return Vector3.new(-radial.Z * sign, 0, radial.X * sign)
end

-- Enforces minimum stagger spacing between ranged shots directed at the same player so waves
-- create readable dodging/parry rhythms instead of simultaneous instant volleys.
function Tactics.canFireStaggered(lastShotAt: number?, now: number, staggerSeconds: number): boolean
	if type(lastShotAt) ~= "number" or staggerSeconds <= 0 then
		return true
	end
	return now - lastShotAt >= staggerSeconds
end

-- Predicted intercept point for an exploder cutting off a moving player instead of tail-chasing.
-- Scales down lead smoothly at close range so the exploder still locks directly onto the player
-- when closing in to detonate.
function Tactics.interceptPoint(
	enemyPos: Vector3,
	targetPos: Vector3,
	targetVelocity: Vector3,
	leadSeconds: number,
	maxLeadDistance: number?
): Vector3
	local flatVel = Vector3.new(targetVelocity.X, 0, targetVelocity.Z)
	if leadSeconds <= 0 or flatVel.Magnitude < 1e-2 then
		return targetPos
	end
	local dist = Vector3.new(targetPos.X - enemyPos.X, 0, targetPos.Z - enemyPos.Z).Magnitude
	local scale = math.clamp((dist - 4) / 14, 0, 1)
	local offset = flatVel * (leadSeconds * scale)
	local cap = maxLeadDistance or 12
	if offset.Magnitude > cap then
		offset = offset.Unit * cap
	end
	return Vector3.new(targetPos.X + offset.X, targetPos.Y, targetPos.Z + offset.Z)
end

-- Steers a grabber toward a player's flank/blindspot when approaching from directly in front
-- of where the player is facing, creating genuine ambush pressure.
function Tactics.grabberApproach(
	enemyPos: Vector3,
	targetPos: Vector3,
	targetFacing: Vector3,
	orbitSign: number,
	flankWeight: number
): Vector3
	local toTarget = Vector3.new(targetPos.X - enemyPos.X, 0, targetPos.Z - enemyPos.Z)
	local dist = toTarget.Magnitude
	local radial = flatUnit(toTarget) or Vector3.new(0, 0, -1)
	local facing = flatUnit(targetFacing)
	if not facing or dist < 7 or flankWeight <= 0 then
		return radial
	end
	-- `fromTarget` points from target toward enemy; positive dot means enemy is in front of player.
	local inFront = (-radial):Dot(facing)
	if inFront <= 0.1 then
		return radial
	end
	local sign = if orbitSign < 0 then -1 else 1
	local tangent = Vector3.new(-radial.Z * sign, 0, radial.X * sign)
	return flatUnit(radial + tangent * (inFront * flankWeight * 1.4)) or radial
end

-- Computes the destination waypoint for each hop of a Sandevistan multi-dash ambush (`stepIndex`
-- in `1..totalSteps`). Alternates sharply across left/right flanks before snapping behind/beside
-- the player on the final hop so every dash moves in a distinct unpredictable direction.
function Tactics.sandevistanWaypoint(
	enemyPos: Vector3,
	targetPos: Vector3,
	targetFacing: Vector3,
	stepIndex: number,
	totalSteps: number,
	orbitSign: number
): Vector3
	local fromTarget = Vector3.new(enemyPos.X - targetPos.X, 0, enemyPos.Z - targetPos.Z)
	local baseAngle = if fromTarget.Magnitude > 1e-3 then math.atan2(fromTarget.Z, fromTarget.X) else 0
	local sign = if orbitSign < 0 then -1 else 1
	local steps = math.max(totalSteps, 3)

	if stepIndex >= steps then
		-- Final ambush hop: snap right behind (or sharp side-back of) where the player is facing.
		local facing = flatUnit(targetFacing)
		local ambushAngle = if facing
			then math.atan2(-facing.Z, -facing.X) + sign * math.rad(28)
			else baseAngle + sign * math.rad(145)
		local strikeDist = 5.2
		return Vector3.new(
			targetPos.X + math.cos(ambushAngle) * strikeDist,
			enemyPos.Y,
			targetPos.Z + math.sin(ambushAngle) * strikeDist
		)
	end

	-- Intermediate zig-zag hops: snap sharply across opposing angles around the player.
	local swingDeg = if stepIndex % 2 == 1 then 82 else -118
	local nextAngle = baseAngle + sign * math.rad(swingDeg)
	local ringDist = if stepIndex % 2 == 1 then 13.5 else 10.5
	return Vector3.new(
		targetPos.X + math.cos(nextAngle) * ringDist,
		enemyPos.Y,
		targetPos.Z + math.sin(nextAngle) * ringDist
	)
end

--=============================================================================
-- Self test
--=============================================================================

function Tactics.selfTest()
	-- Attack tokens: cap at maxAttackers per target, prioritize active windup, skip recover.
	local tokens = Tactics.assignMeleeTokens({
		{ id = "a", targetKey = "p1", distance = 5, phase = "recover" },
		{ id = "b", targetKey = "p1", distance = 12, phase = "windup" },
		{ id = "c", targetKey = "p1", distance = 7, phase = "chase" },
		{ id = "d", targetKey = "p1", distance = 9, phase = "chase" },
		{ id = "e", targetKey = "p2", distance = 15, phase = "chase" },
	}, 2)
	assert(not tokens["a"], "recovering melee unit yields its attack token")
	assert(tokens["b"], "enemy already in windup retains its token")
	assert(tokens["c"], "closest ready enemy fills the remaining token slot")
	assert(not tokens["d"], "extra enemy becomes a flanker rather than dogpiling")
	assert(tokens["e"], "separate target gets its own token pool")

	-- Co-op target distribution spreads pressure when one player is already crowded.
	local t1 = { key = "p1", position = Vector3.new(0, 0, 10) }
	local t2 = { key = "p2", position = Vector3.new(0, 0, 14) }
	local pickedFirst = Tactics.chooseTarget(Vector3.zero, { t1, t2 }, { p1 = 0, p2 = 0 }, 6)
	assert(pickedFirst ~= nil and pickedFirst.key == "p1", "picks closer player when crowd is equal")
	local pickedSpread = Tactics.chooseTarget(Vector3.zero, { t1, t2 }, { p1 = 2, p2 = 0 }, 6)
	assert(pickedSpread ~= nil and pickedSpread.key == "p2", "crowd penalty shifts extra enemies to open teammate")

	-- Flanking orbit: retreats when inside inner band, advances when far, circles tangentially on ring.
	local onRing = Tactics.flankDirection(Vector3.new(13, 0, 0), Vector3.zero, 13, 2.5, 1)
	assert(math.abs(onRing.X) < 0.05 and math.abs(onRing.Z) > 0.95, "on the flank ring, orbits tangentially")
	local tooClose = Tactics.flankDirection(Vector3.new(5, 0, 0), Vector3.zero, 13, 2.5, 1)
	assert(tooClose.X > 0.2, "inside inner band, backs outward while orbiting")
	local tooFar = Tactics.flankDirection(Vector3.new(30, 0, 0), Vector3.zero, 13, 2.5, 1)
	assert(tooFar.X < -0.2, "outside outer band, closes toward flank ring while orbiting")

	-- Ranged stagger prevents simultaneous volleys at the same player.
	assert(Tactics.canFireStaggered(nil, 10, 0.55), "first ranged shot is allowed")
	assert(not Tactics.canFireStaggered(10, 10.3, 0.55), "second shot too soon is staggered")
	assert(Tactics.canFireStaggered(10, 10.6, 0.55), "shot after stagger window is allowed")

	-- Exploder intercept leads ahead of moving targets at mid-range and collapses cleanly at point-blank.
	local leadFar = Tactics.interceptPoint(Vector3.new(0, 0, 0), Vector3.new(0, 0, 20), Vector3.new(20, 0, 0), 0.35, 12)
	assert(leadFar.X > 4, "exploder leads ahead of moving player at mid-range")
	local leadClose = Tactics.interceptPoint(Vector3.new(0, 0, 0), Vector3.new(0, 0, 3), Vector3.new(20, 0, 0), 0.35, 12)
	assert(math.abs(leadClose.X) < 0.01, "exploder aims straight at player once in detonation range")

	-- Grabber curves sideways when approaching from directly in front of player.
	local frontCurve = Tactics.grabberApproach(Vector3.new(0, 0, -15), Vector3.zero, Vector3.new(0, 0, -1), 1, 0.45)
	assert(math.abs(frontCurve.X) > 0.25, "grabber angles toward flank when in front of player")
	local backDirect = Tactics.grabberApproach(Vector3.new(0, 0, 15), Vector3.zero, Vector3.new(0, 0, -1), 1, 0.45)
	assert(math.abs(backDirect.X) < 0.01 and backDirect.Z < -0.99, "grabber goes straight in from behind")

	-- Sector dispersion spreads even identically positioned enemies across 360 degrees.
	local clumped: { SectorEntry } = {}
	for i = 1, 4 do
		table.insert(clumped, {
			id = i,
			targetKey = "p1",
			position = Vector3.new(0, 0, -15),
			targetPosition = Vector3.zero,
			jitter = (i - 2.5) * 0.05,
		})
	end
	local sectors = Tactics.assignSectors(clumped, 0)
	local d12 = math.abs(angleDelta(sectors[1], sectors[2]))
	local d13 = math.abs(angleDelta(sectors[1], sectors[3]))
	assert(d12 > 1.2 and d13 > 2.4, "clumped enemies receive well-separated 360-deg sectors")

	-- Pincer approach curves sideways when enemy is far from its assigned sector angle.
	local pincer = Tactics.pincerApproach(Vector3.new(0, 0, -16), Vector3.zero, math.rad(45), 0.65)
	assert(math.abs(pincer.X) > 0.35, "pincer curves laterally to surround from assigned sector")

	-- Sector steering peels clumped flankers apart in opposite directions.
	local steerLeft = Tactics.steerToSector(Vector3.new(0, 0, -14), Vector3.zero, math.rad(-150), 14, 2.5, 1, 0.6)
	local steerRight = Tactics.steerToSector(Vector3.new(0, 0, -14), Vector3.zero, math.rad(-30), 14, 2.5, 1, 0.6)
	assert(steerLeft.X * steerRight.X < 0, "opposite assigned sectors steer clumped allies apart")

	-- Strong anti-clumping push increases sharply at close overlap.
	local pushClose = Tactics.antiClumpPush(Vector3.zero, { Vector3.new(2, 0, 0) }, 10, 1, 1.45)
	local pushEdge = Tactics.antiClumpPush(Vector3.zero, { Vector3.new(8, 0, 0) }, 10, 1, 1.45)
	assert(pushClose.X < 0 and pushClose.Magnitude > pushEdge.Magnitude * 3, "anti-clump push ramps up strongly")

	-- Sandevistan 3-hop waypoints move in 3 distinct directions and finish close behind the player.
	local p0 = Vector3.new(0, 2.5, -18)
	local w1 = Tactics.sandevistanWaypoint(p0, Vector3.zero, Vector3.new(0, 0, -1), 1, 3, 1)
	local w2 = Tactics.sandevistanWaypoint(w1, Vector3.zero, Vector3.new(0, 0, -1), 2, 3, 1)
	local w3 = Tactics.sandevistanWaypoint(w2, Vector3.zero, Vector3.new(0, 0, -1), 3, 3, 1)
	local d1 = Vector3.new(w1.X - p0.X, 0, w1.Z - p0.Z).Unit
	local d2 = Vector3.new(w2.X - w1.X, 0, w2.Z - w1.Z).Unit
	local d3 = Vector3.new(w3.X - w2.X, 0, w3.Z - w2.Z).Unit
	assert(d1:Dot(d2) < 0.5 and d2:Dot(d3) < 0.7, "Sandevistan hops change direction sharply")
	assert(w3.Z > 2 and Vector3.new(w3.X, 0, w3.Z).Magnitude < 6, "final hop lands close behind player")
end

return Tactics
