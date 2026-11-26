--!strict
--[[
	The rules of a swing, shared by both realms: which hit of the combo a press is, and whether a
	target is inside a swing or a spin.

	The client calls these to *predict* (which slash to draw, which enemy to turn towards) and the
	server calls the same functions to *decide* (who takes damage). Keeping one copy is what stops
	"I clearly hit it" from being a bug report: if the two ever disagree, it is because the server
	saw an older position, never because it used a different rule.

	All geometry is flat (X/Z). The room is a floor, and a jump should not make a swing miss.
]]

local Melee = {}

export type Target = {
	position: Vector3,
	radius: number?,
}

export type TargetPick = {
	index: number,
	direction: Vector3,
	distance: number,
	radius: number,
}

-- Which hit of the combo this press is. A press inside `window` of the last one continues the
-- chain and wraps after the last hit; anything later, or a first press, starts it at 1.
function Melee.nextStep(step: number, lastAt: number, now: number, hits: number, window: number): number
	if step < 1 or hits < 1 or now - lastAt > window then
		return 1
	end
	return step % hits + 1
end

-- The horizontal part of a direction, as a unit vector — or nil when there is none, so a caller
-- with a straight-down aim falls back to the way the player is facing rather than to NaN.
function Melee.flat(direction: Vector3): Vector3?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return flat.Unit
end

-- Flat distance between two points.
function Melee.distance(a: Vector3, b: Vector3): number
	return Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
end

-- Inside a swing: within `range` of `origin`, and within `arc` degrees centred on `facing`.
-- A target standing on the player counts as in front of them — at zero distance there is no
-- direction to be outside of, and missing a point-blank enemy reads as a broken game.
function Melee.inArc(origin: Vector3, facing: Vector3, target: Vector3, range: number, arc: number): boolean
	local offset = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
	local distance = offset.Magnitude
	if distance > range then
		return false
	end
	if distance < 1e-3 then
		return true
	end
	local forward = Melee.flat(facing)
	if not forward then
		return false
	end
	return offset.Unit:Dot(forward) >= math.cos(math.rad(arc / 2)) - 1e-6
end

-- Inside a spin: within `radius` of `origin`, in every direction.
function Melee.inRadius(origin: Vector3, target: Vector3, radius: number): boolean
	return Melee.distance(origin, target) <= radius
end

-- Inside a forward corridor/capsule (used by Stinger piercing lunges and Over Drive ranged slash
-- waves): checks flat distance from `target` to the line segment `[origin, origin + forward * length]`.
function Melee.inCorridor(
	origin: Vector3,
	facing: Vector3,
	target: Vector3,
	length: number,
	halfWidth: number
): boolean
	if length <= 0 or halfWidth <= 0 then
		return false
	end
	local forward = Melee.flat(facing)
	if not forward then
		return false
	end
	local offset = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
	local along = math.clamp(offset:Dot(forward), 0, length)
	local closest = forward * along
	return (offset - closest).Magnitude <= halfWidth + 1e-6
end

-- Picks the best enemy in front of `facing` (within `cone` degrees and `range` studs + enemy
-- radius) to snap a basic attack onto. Prioritises enemies aligned with where the player is
-- looking, breaking ties by proximity so a nearby aligned enemy beats a far dead-ahead one.
-- When `preferredIndex` is given (continuing a combo or following an ability), that target stays
-- locked as long as it remains within range and inside `lockCone` (defaulting to `cone`).
function Melee.pickTarget(
	origin: Vector3,
	facing: Vector3,
	targets: { Target },
	range: number,
	cone: number,
	angleWeight: number?,
	preferredIndex: number?,
	lockCone: number?
): TargetPick?
	local forward = Melee.flat(facing)
	if not forward or range <= 0 or cone <= 0 then
		return nil
	end

	if preferredIndex ~= nil then
		local preferred = targets[preferredIndex]
		if preferred then
			local radius = preferred.radius or 0
			local offset = Vector3.new(preferred.position.X - origin.X, 0, preferred.position.Z - origin.Z)
			local distance = offset.Magnitude
			if distance <= range + radius then
				local dir = if distance < 1e-3 then forward else offset / distance
				local dot = if distance < 1e-3 then 1 else dir:Dot(forward)
				local keepCone = if lockCone ~= nil then lockCone else cone
				local keepMinDot = math.cos(math.rad(math.clamp(keepCone, 0, 360) / 2)) - 1e-6
				if keepCone > 0 and dot >= keepMinDot then
					return {
						index = preferredIndex,
						direction = dir,
						distance = distance,
						radius = radius,
					}
				end
			end
		end
	end

	local halfRad = math.rad(math.clamp(cone, 0, 360) / 2)
	local minDot = math.cos(halfRad) - 1e-6
	local weight = math.clamp(if angleWeight ~= nil then angleWeight else 0.65, 0, 1)

	local bestIndex: number? = nil
	local bestDirection: Vector3 = forward
	local bestDistance = 0
	local bestRadius = 0
	local bestScore = math.huge

	for index, target in ipairs(targets) do
		local radius = target.radius or 0
		local offset = Vector3.new(target.position.X - origin.X, 0, target.position.Z - origin.Z)
		local distance = offset.Magnitude
		if distance <= range + radius then
			local dir: Vector3
			local dot: number
			if distance < 1e-3 then
				dir = forward
				dot = 1
			else
				dir = offset / distance
				dot = dir:Dot(forward)
			end

			if dot >= minDot then
				local angleNorm = if halfRad > 1e-6 then math.acos(math.clamp(dot, -1, 1)) / halfRad else 0
				local distNorm = math.clamp(distance / range, 0, 1)
				local score = angleNorm * weight + distNorm * (1 - weight)
				if score < bestScore then
					bestScore = score
					bestIndex = index
					bestDirection = dir
					bestDistance = distance
					bestRadius = radius
				end
			end
		end
	end

	if not bestIndex then
		return nil
	end

	return {
		index = bestIndex,
		direction = bestDirection,
		distance = bestDistance,
		radius = bestRadius,
	}
end

-- How far the attacker should lunge toward a picked target so they stop `stopDistance` studs
-- outside `targetRadius` without overshooting past it. Returns 0 when already in sticking range.
function Melee.lungeDistance(distance: number, targetRadius: number, stopDistance: number, maxDistance: number): number
	if maxDistance <= 0 then
		return 0
	end
	local gap = distance - (targetRadius + stopDistance)
	if gap <= 0 then
		return 0
	end
	return math.min(gap, maxDistance)
end

-- Normalised [0, 1] heavy-attack charge progress from a start timestamp and required duration.
function Melee.chargeProgress(startedAt: any, now: number, duration: number): number
	if type(startedAt) ~= "number" or startedAt <= 0 or duration <= 0 then
		return 0
	end
	return math.clamp((now - startedAt) / duration, 0, 1)
end

-- True once a charge started at `startedAt` has reached `duration` (minus optional network slack).
function Melee.isChargeReady(startedAt: any, now: number, duration: number, slack: number?): boolean
	if type(startedAt) ~= "number" or startedAt <= 0 or duration <= 0 then
		return false
	end
	local required = math.max(duration - (slack or 0), 0)
	return now - startedAt >= required
end

--=============================================================================
-- Self test
--=============================================================================

function Melee.selfTest()
	-- The combo.
	assert(Melee.nextStep(0, -math.huge, 10, 3, 0.6) == 1, "a first press is hit 1")
	assert(Melee.nextStep(1, 10, 10.3, 3, 0.6) == 2, "a press inside the window continues")
	assert(Melee.nextStep(2, 10, 10.3, 3, 0.6) == 3, "the chain reaches the heavy hit")
	assert(Melee.nextStep(3, 10, 10.3, 3, 0.6) == 1, "the chain wraps after the last hit")
	assert(Melee.nextStep(2, 10, 11, 3, 0.6) == 1, "a late press starts the chain again")

	-- The swing.
	local origin = Vector3.new(0, 0, 0)
	local north = Vector3.new(0, 0, -1)
	assert(Melee.inArc(origin, north, Vector3.new(0, 0, -5), 8, 120), "straight ahead is hit")
	assert(not Melee.inArc(origin, north, Vector3.new(0, 0, 5), 8, 120), "behind is not hit")
	assert(not Melee.inArc(origin, north, Vector3.new(0, 0, -9), 8, 120), "out of range is not hit")
	-- 60 degrees off a 120-degree arc is exactly on its edge, and the edge counts.
	local edge = Vector3.new(math.sin(math.rad(60)), 0, -math.cos(math.rad(60))) * 5
	assert(Melee.inArc(origin, north, edge, 8, 120), "the edge of the arc is hit")
	assert(Melee.inArc(origin, north, origin, 8, 120), "point blank is hit")
	-- Height is ignored: a target on a ledge or a player mid-jump is judged on the floor plan.
	assert(Melee.inArc(origin, north, Vector3.new(0, 6, -5), 8, 120), "height does not make a swing miss")
	assert(not Melee.inArc(origin, Vector3.new(0, -1, 0), Vector3.new(0, 0, -5), 8, 120), "no facing, no swing")

	-- The spin.
	assert(Melee.inRadius(origin, Vector3.new(0, 0, 11), 12), "inside the spin is hit")
	assert(Melee.inRadius(origin, Vector3.new(-11, 0, 0), 12), "the spin hits behind too")
	assert(not Melee.inRadius(origin, Vector3.new(13, 0, 0), 12), "outside the spin is not hit")

	-- Forward corridor (Stinger & Over Drive waves).
	assert(Melee.inCorridor(origin, north, Vector3.new(0, 0, -20), 26, 3.25), "center of corridor is hit")
	assert(Melee.inCorridor(origin, north, Vector3.new(3.0, 4, -12), 26, 3.25), "within half-width ignores height and hits")
	assert(Melee.inCorridor(origin, north, origin, 26, 3.25), "point-blank origin is hit")
	assert(not Melee.inCorridor(origin, north, Vector3.new(5.0, 0, -12), 26, 3.25), "outside lateral half-width misses")
	assert(not Melee.inCorridor(origin, north, Vector3.new(0, 0, -35), 26, 3.25), "beyond corridor length + cap misses")
	assert(not Melee.inCorridor(origin, north, Vector3.new(0, 0, 8), 26, 3.25), "far behind origin misses")
	assert(not Melee.inCorridor(origin, Vector3.new(0, -1, 0), Vector3.new(0, 0, -5), 26, 3.25), "vertical facing misses")

	assert(Melee.flat(Vector3.new(0, -3, 0)) == nil, "a vertical direction has no flat part")

	-- Forward target picking: aligned ahead beats closer off-angle, never snaps behind or sideways.
	local offAngle = Vector3.new(math.sin(math.rad(55)), 0, -math.cos(math.rad(55))) * 6
	local pickAligned = Melee.pickTarget(origin, north, {
		{ position = offAngle, radius = 2 },
		{ position = Vector3.new(0, 0, -10), radius = 2 },
	}, 15, 120, 0.65)
	assert(pickAligned ~= nil and pickAligned.index == 2, "aligned enemy ahead beats closer off-angle enemy")

	local pickCloser = Melee.pickTarget(origin, north, {
		{ position = Vector3.new(0, 0, -13), radius = 2 },
		{ position = Vector3.new(0, 0, -5), radius = 2 },
	}, 15, 120, 0.65)
	assert(pickCloser ~= nil and pickCloser.index == 2, "closer enemy on the same line wins")

	-- 120-degree cone means +/-60 degrees: 59 deg is picked, 65 deg is ignored.
	local insideCone = Vector3.new(math.sin(math.rad(59)), 0, -math.cos(math.rad(59))) * 6
	local outsideCone = Vector3.new(math.sin(math.rad(65)), 0, -math.cos(math.rad(65))) * 6
	local pickConeEdge = Melee.pickTarget(origin, north, {
		{ position = insideCone, radius = 2 },
	}, 15, 120, 0.65)
	assert(pickConeEdge ~= nil and pickConeEdge.index == 1, "enemy inside +/-60 deg window is picked")

	local pickNone = Melee.pickTarget(origin, north, {
		{ position = Vector3.new(0, 0, 3), radius = 2 }, -- directly behind
		{ position = outsideCone, radius = 2 }, -- 65 degrees off (> 60 deg half-cone)
		{ position = Vector3.new(4, 0, 0), radius = 2 }, -- 90 degrees to the side
		{ position = Vector3.new(0, 0, -20), radius = 2 }, -- beyond range + radius
	}, 15, 120, 0.65)
	assert(pickNone == nil, "enemies behind, outside +/-60 deg cone, or out of range are ignored")

	local pickPointBlank = Melee.pickTarget(origin, north, {
		{ position = Vector3.new(0, 4, 0), radius = 2 },
	}, 15, 120, 0.65)
	assert(
		pickPointBlank ~= nil and pickPointBlank.index == 1 and pickPointBlank.direction:Dot(north) > 0.999,
		"point-blank enemy keeps forward facing regardless of height"
	)

	assert(
		Melee.pickTarget(origin, Vector3.new(0, -1, 0), { { position = Vector3.new(0, 0, -5), radius = 2 } }, 15, 120)
			== nil,
		"vertical facing picks nothing"
	)

	-- Sticky combo targeting: keeps preferred enemy while still heading toward it, even if a
	-- closer/more-centered enemy appears; releases when steering away or out of range.
	local stickyTargets = {
		{ position = Vector3.new(0, 0, -5), radius = 2 }, -- dead ahead and closer
		{ position = Vector3.new(math.sin(math.rad(35)), 0, -math.cos(math.rad(35))) * 10, radius = 2 }, -- locked, 35 deg off
	}
	local kept = Melee.pickTarget(origin, north, stickyTargets, 15, 120, 0.65, 2, 110)
	assert(kept ~= nil and kept.index == 2, "keeps locked target while still within lock cone")

	-- Turning 75 degrees left puts target 2 at 110 degrees off facing (> 55 deg half-cone).
	local westish = Vector3.new(-math.sin(math.rad(75)), 0, -math.cos(math.rad(75)))
	local switched = Melee.pickTarget(origin, westish, {
		{ position = westish * 6, radius = 2 },
		stickyTargets[2],
	}, 15, 120, 0.65, 2, 110)
	assert(switched ~= nil and switched.index == 1, "drops lock and switches when player steers away")

	local droppedRange = Melee.pickTarget(origin, north, {
		{ position = Vector3.new(0, 0, -6), radius = 2 },
		{ position = Vector3.new(0, 0, -25), radius = 2 },
	}, 15, 120, 0.65, 2, 110)
	assert(droppedRange ~= nil and droppedRange.index == 1, "drops lock when locked target leaves range")

	-- Lunge distance: zero when already stuck to target, exact gap in mid-range, clamped at max.
	assert(Melee.lungeDistance(4, 2, 2.5, 8) == 0, "no lunge when already within stop distance")
	assert(math.abs(Melee.lungeDistance(8, 2, 2.5, 8) - 3.5) < 1e-4, "mid-range lunges exact remaining gap")
	assert(Melee.lungeDistance(15, 2, 2.5, 8) == 8, "far target clamps lunge to max distance")

	-- Charged heavy attack progress & readiness.
	assert(Melee.chargeProgress(0, 10, 3) == 0, "inactive charge reports 0 progress")
	assert(math.abs(Melee.chargeProgress(10, 11.5, 3) - 0.5) < 1e-6, "halfway through 3 s charge is 0.5")
	assert(Melee.chargeProgress(10, 15, 3) == 1, "progress clamps to 1 at or past duration")
	assert(not Melee.isChargeReady(10, 12.5, 3, 0.15), "2.5 s is not ready for a 3 s charge")
	assert(Melee.isChargeReady(10, 12.86, 3, 0.15), "within slack of 3 s is accepted")
	assert(Melee.isChargeReady(10, 13.0, 3, 0), "exact 3 s is ready")
end

return Melee
