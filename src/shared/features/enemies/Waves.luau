--!strict
--[[
	What a wave is made of and where it appears, as pure functions over Config.WAVES.

	Deterministic on purpose: the same wave spawns the same enemies in the same places every time,
	so "the third wave is too hard" is a claim somebody else can reproduce.
]]

local Waves = {}

-- A wave's kinds, one entry per enemy, in a stable order (by kind name) so spawn slots do not
-- shuffle between runs. Counts below one are skipped rather than trusted.
function Waves.expand(wave: { [string]: number }): { string }
	local kinds = {}
	for kind in pairs(wave) do
		table.insert(kinds, kind)
	end
	table.sort(kinds)

	local list = {}
	for _, kind in ipairs(kinds) do
		for _ = 1, math.floor(wave[kind]) do
			table.insert(list, kind)
		end
	end
	return list
end

-- Where the i-th of n enemies appears: evenly round a ring just inside the walls, so a wave
-- surrounds the player instead of arriving from one side.
function Waves.spawnPoint(i: number, n: number, room: Vector2, inset: number, height: number): Vector3
	local radius = math.min(room.X, room.Y) / 2 - inset
	local angle = (i - 1) / math.max(n, 1) * 2 * math.pi
	return Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
end

export type Obstacle = {
	x: number,
	z: number,
	radius: number?,
	halfX: number?,
	halfZ: number?,
}

-- Keeps a point inside the room, `margin` studs from the walls.
function Waves.clamp(point: Vector3, room: Vector2, margin: number): Vector3
	local halfX = room.X / 2 - margin
	local halfZ = room.Y / 2 - margin
	return Vector3.new(math.clamp(point.X, -halfX, halfX), point.Y, math.clamp(point.Z, -halfZ, halfZ))
end

local function pushOutOfObstacle(x: number, z: number, entityRadius: number, obs: Obstacle): (number, number)
	if obs.halfX and obs.halfZ then
		local hx = obs.halfX
		local hz = obs.halfZ
		local dx = x - obs.x
		local dz = z - obs.z
		local cx = math.clamp(dx, -hx, hx)
		local cz = math.clamp(dz, -hz, hz)
		local rx = dx - cx
		local rz = dz - cz
		local distSq = rx * rx + rz * rz
		if distSq == 0 then
			-- Center lies strictly inside the box: eject along the shallowest axis.
			local penX = hx - math.abs(dx)
			local penZ = hz - math.abs(dz)
			if penX <= penZ then
				local sx = if dx >= 0 then 1 else -1
				return obs.x + sx * (hx + entityRadius), z
			else
				local sz = if dz >= 0 then 1 else -1
				return x, obs.z + sz * (hz + entityRadius)
			end
		elseif distSq < entityRadius * entityRadius then
			local dist = math.sqrt(distSq)
			local scale = entityRadius / dist
			return obs.x + cx + rx * scale, obs.z + cz + rz * scale
		end
		return x, z
	end

	local radius = obs.radius or 0
	local dx = x - obs.x
	local dz = z - obs.z
	local minDist = radius + entityRadius
	local distSq = dx * dx + dz * dz
	if distSq < minDist * minDist then
		if distSq > 1e-6 then
			local dist = math.sqrt(distSq)
			local scale = minDist / dist
			return obs.x + dx * scale, obs.z + dz * scale
		end
		return obs.x + minDist, z
	end
	return x, z
end

-- Pushes `point` cleanly outside every solid obstacle (circles and axis-aligned boxes), running
-- two passes so adjacent props (e.g. twin crates) never nudge an entity into its neighbour.
function Waves.avoidObstacles(point: Vector3, entityRadius: number, obstacles: { Obstacle }?): Vector3
	if not obstacles or #obstacles == 0 then
		return point
	end
	local x, z = point.X, point.Z
	for _ = 1, 2 do
		for _, obs in ipairs(obstacles) do
			x, z = pushOutOfObstacle(x, z, entityRadius, obs)
		end
	end
	return Vector3.new(x, point.Y, z)
end

-- True when a projectile/orb at `point` overlaps any solid obstacle cover.
function Waves.hitsObstacle(point: Vector3, hitRadius: number, obstacles: { Obstacle }?): boolean
	if not obstacles or #obstacles == 0 then
		return false
	end
	for _, obs in ipairs(obstacles) do
		if obs.halfX and obs.halfZ then
			local dx = point.X - obs.x
			local dz = point.Z - obs.z
			local rx = dx - math.clamp(dx, -obs.halfX, obs.halfX)
			local rz = dz - math.clamp(dz, -obs.halfZ, obs.halfZ)
			if rx * rx + rz * rz <= hitRadius * hitRadius then
				return true
			end
		else
			local dx = point.X - obs.x
			local dz = point.Z - obs.z
			local limit = (obs.radius or 0) + hitRadius
			if dx * dx + dz * dz <= limit * limit then
				return true
			end
		end
	end
	return false
end

--=============================================================================
-- Self test
--=============================================================================

function Waves.selfTest()
	local list = Waves.expand({ ranged = 2, melee = 1, exploder = 0 })
	assert(#list == 3, "a wave expands to one entry per enemy")
	assert(list[1] == "melee" and list[2] == "ranged" and list[3] == "ranged", "kinds come out in a stable order")
	assert(#Waves.expand({ melee = -2 }) == 0, "a negative count spawns nothing")

	local room = Vector2.new(140, 140)
	local first = Waves.spawnPoint(1, 4, room, 10, 2)
	assert(math.abs(first.Magnitude - math.sqrt(60 * 60 + 2 * 2)) < 1e-3, "spawns sit on the ring inside the walls")
	local third = Waves.spawnPoint(3, 4, room, 10, 2)
	assert((first - third).Magnitude > 100, "spawns are spread round the room, not bunched")

	local inside = Waves.clamp(Vector3.new(500, 3, -500), room, 3)
	assert(inside.X == 67 and inside.Z == -67 and inside.Y == 3, "a point outside is pulled back in, height kept")

	local pillars = { { x = 38, z = 38, radius = 5.6 } }
	local pushed = Waves.avoidObstacles(Vector3.new(40, 2.5, 38), 2.0, pillars)
	assert(math.abs((pushed.X - 38) - 7.6) < 1e-4 and pushed.Y == 2.5, "avoidObstacles pushes outside pillar radius keeping Y")
	assert(Waves.hitsObstacle(Vector3.new(41, 2, 38), 1.0, pillars), "hitsObstacle detects shots hitting solid cover")
	assert(not Waves.hitsObstacle(Vector3.new(0, 2, 0), 1.0, pillars), "hitsObstacle ignores clear center arena")

	-- Box obstacles: exact AABB push-out (interior & corner) and projectile hit detection.
	local boxes = { { x = -38, z = -38, halfX = 4.6, halfZ = 4.6 } }
	local boxPushed = Waves.avoidObstacles(Vector3.new(-35, 2.5, -38), 2.0, boxes)
	assert(math.abs(boxPushed.X - (-38 + 4.6 + 2.0)) < 1e-4 and boxPushed.Y == 2.5, "avoidObstacles ejects from inside box along shallowest axis")
	local cornerPushed = Waves.avoidObstacles(Vector3.new(-32.8, 2.5, -32.8), 2.0, boxes)
	assert(not Waves.hitsObstacle(cornerPushed, 1.9, boxes), "corner push clears box corner cleanly")
	assert(Waves.hitsObstacle(Vector3.new(-33.5, 2, -33.5), 1.0, boxes), "hitsObstacle detects shots clipping box corner")
	assert(not Waves.hitsObstacle(Vector3.new(-20, 2, -38), 1.0, boxes), "hitsObstacle ignores clear lane outside box")

	-- Verify every tracked arena layout keeps the center spawn pad clear and produces valid safe spawns.
	local Config = require(script.Parent.Parent.Parent.core.Config)
	for layoutName, obstacles in pairs(Config.ARENA_LAYOUTS) do
		assert(not Waves.hitsObstacle(Vector3.new(0, 2, 0), 3.0, obstacles), `{layoutName} center spawn must stay clear`)
		for i = 1, 8 do
			local pt = Waves.spawnPoint(i, 8, room, 13, 0)
			local safe = Waves.avoidObstacles(pt, 3.5, obstacles)
			assert(not Waves.hitsObstacle(safe, 3.0, obstacles), `{layoutName} spawn {i} clears obstacles`)
		end
	end
end

return Waves
