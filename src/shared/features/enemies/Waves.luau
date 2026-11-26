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

export type Obstacle = { x: number, z: number, radius: number }

-- Keeps a point inside the room, `margin` studs from the walls.
function Waves.clamp(point: Vector3, room: Vector2, margin: number): Vector3
	local halfX = room.X / 2 - margin
	local halfZ = room.Y / 2 - margin
	return Vector3.new(math.clamp(point.X, -halfX, halfX), point.Y, math.clamp(point.Z, -halfZ, halfZ))
end

-- Pushes `point` radially outside any solid interior pillar (`obstacles`), preserving `point.Y`.
function Waves.avoidObstacles(point: Vector3, entityRadius: number, obstacles: { Obstacle }?): Vector3
	if not obstacles or #obstacles == 0 then
		return point
	end
	local x, z = point.X, point.Z
	for _, pillar in ipairs(obstacles) do
		local dx = x - pillar.x
		local dz = z - pillar.z
		local minDist = pillar.radius + entityRadius
		local distSq = dx * dx + dz * dz
		if distSq < minDist * minDist then
			if distSq > 1e-6 then
				local dist = math.sqrt(distSq)
				local scale = minDist / dist
				x = pillar.x + dx * scale
				z = pillar.z + dz * scale
			else
				x = pillar.x + minDist
			end
		end
	end
	return Vector3.new(x, point.Y, z)
end

-- True when a projectile/orb at `point` overlaps any solid pillar cover.
function Waves.hitsObstacle(point: Vector3, hitRadius: number, obstacles: { Obstacle }?): boolean
	if not obstacles or #obstacles == 0 then
		return false
	end
	for _, pillar in ipairs(obstacles) do
		local dx = point.X - pillar.x
		local dz = point.Z - pillar.z
		local limit = pillar.radius + hitRadius
		if dx * dx + dz * dz <= limit * limit then
			return true
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
end

return Waves
