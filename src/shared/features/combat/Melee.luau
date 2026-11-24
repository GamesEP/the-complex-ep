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

	assert(Melee.flat(Vector3.new(0, -3, 0)) == nil, "a vertical direction has no flat part")
end

return Melee
