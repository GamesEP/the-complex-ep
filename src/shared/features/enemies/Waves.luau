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

-- Keeps a point inside the room, `margin` studs from the walls.
function Waves.clamp(point: Vector3, room: Vector2, margin: number): Vector3
	local halfX = room.X / 2 - margin
	local halfZ = room.Y / 2 - margin
	return Vector3.new(math.clamp(point.X, -halfX, halfX), point.Y, math.clamp(point.Z, -halfZ, halfZ))
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
end

return Waves
