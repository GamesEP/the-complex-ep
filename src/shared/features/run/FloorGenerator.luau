--!strict
--[[
	Pure 5-Floor randomized room generator and active-enemy cap enforcer (plans/gdd/content.md,
	plans/gdd/technical.md, plans/roadmap.md HS-12).

	Floor 1 draws 5 warm-up combat rooms (no boss). Floors 2..5 draw Rooms 1..4 randomly from each
	floor's authored pool with zero back-to-back duplicate encounter IDs (and preferring distinct
	consecutive arena layouts), locking Room 5 to the floor's boss (Oh, My, Gon, OhMyGon).
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local FloorGenerator = {}

export type RoomPlan = {
	floor: number,
	room: number,
	id: string,
	name: string,
	arena: string,
	isBossRoom: boolean,
	bossKind: string?,
	waves: { { [string]: number } },
}

export type RunPlan = { [number]: { RoomPlan } }

local function cloneWaves(waves: { { [string]: number } }): { { [string]: number } }
	local out = {}
	for _, w in ipairs(waves) do
		table.insert(out, table.clone(w))
	end
	return out
end

-- Trims non-boss enemy counts proportionally so no single wave ever spawns more than `maxActive`
-- simultaneous hostiles (`Config.MAX_ACTIVE_ENEMIES = 25`), even under Zona Muerta difficulty.
function FloorGenerator.capWave(wave: { [string]: number }, maxActive: number?): { [string]: number }
	local cap = math.max(maxActive or Config.MAX_ACTIVE_ENEMIES or 25, 1)
	local out = table.clone(wave)
	local bossCount = 0
	local normalKinds: { string } = {}
	local normalTotal = 0

	for kind, count in pairs(out) do
		local c = math.max(math.floor(count), 0)
		out[kind] = c
		local spec = Config.ENEMY_KINDS[kind]
		if spec and spec.isBoss == true then
			bossCount += c
		elseif c > 0 then
			table.insert(normalKinds, kind)
			normalTotal += c
		end
	end

	local budget = math.max(cap - bossCount, 0)
	if normalTotal <= budget or #normalKinds == 0 then
		return out
	end

	table.sort(normalKinds)
	local scale = budget / normalTotal
	local assigned = 0
	for _, kind in ipairs(normalKinds) do
		local trimmed = math.max(1, math.floor(out[kind] * scale))
		out[kind] = trimmed
		assigned += trimmed
	end

	-- If rounding pushed slightly over budget, decrement the largest non-boss buckets until <= budget.
	while assigned > budget do
		local maxKind: string? = nil
		local maxVal = 0
		for _, kind in ipairs(normalKinds) do
			if out[kind] > maxVal then
				maxVal = out[kind]
				maxKind = kind
			end
		end
		if not maxKind or maxVal <= 0 then
			break
		end
		out[maxKind] -= 1
		assigned -= 1
	end

	return out
end

function FloorGenerator.generateFloor(floorIndex: number, rng: (() -> number)?): { RoomPlan }
	local rand = rng or math.random
	local floorDef = Config.FLOORS[floorIndex] or Config.FLOORS[1]
	local roomsPerFloor = math.max(Config.ROOMS_PER_FLOOR or 5, 1)
	local hasBoss = floorDef.bossRoom ~= nil
	local normalCount = if hasBoss then math.max(roomsPerFloor - 1, 0) else roomsPerFloor

	local plan: { RoomPlan } = {}
	local usedIds: { [string]: boolean } = {}
	local lastId: string? = nil
	local lastArena: string? = nil

	for roomIdx = 1, normalCount do
		local candidates: { Config.RoomPoolEntry } = {}
		-- Prefer unused encounters with a different arena from the immediately previous room.
		for _, entry in ipairs(floorDef.pool) do
			if not usedIds[entry.id] and entry.id ~= lastId and entry.arena ~= lastArena then
				table.insert(candidates, entry)
			end
		end
		-- Relax arena constraint if pool is tight.
		if #candidates == 0 then
			for _, entry in ipairs(floorDef.pool) do
				if not usedIds[entry.id] and entry.id ~= lastId then
					table.insert(candidates, entry)
				end
			end
		end
		-- Final fallback: any entry other than the immediately previous room.
		if #candidates == 0 then
			for _, entry in ipairs(floorDef.pool) do
				if entry.id ~= lastId then
					table.insert(candidates, entry)
				end
			end
		end
		if #candidates == 0 then
			candidates = floorDef.pool
		end

		local pickIdx = math.clamp(math.floor(rand() * #candidates) + 1, 1, #candidates)
		local picked = candidates[pickIdx]
		usedIds[picked.id] = true
		lastId = picked.id
		lastArena = picked.arena

		table.insert(plan, {
			floor = floorIndex,
			room = roomIdx,
			id = picked.id,
			name = picked.name,
			arena = picked.arena,
			isBossRoom = false,
			bossKind = nil,
			waves = cloneWaves(picked.waves),
		})
	end

	if hasBoss and floorDef.bossRoom then
		local b = floorDef.bossRoom
		table.insert(plan, {
			floor = floorIndex,
			room = roomsPerFloor,
			id = b.id,
			name = b.name,
			arena = b.arena,
			isBossRoom = true,
			bossKind = b.bossKind,
			waves = cloneWaves(b.waves),
		})
	end

	return plan
end

function FloorGenerator.generateRun(rng: (() -> number)?): RunPlan
	local rand = rng or math.random
	local floorsCount = math.max(Config.FLOORS_PER_RUN or 5, 1)
	local run: RunPlan = {}
	for f = 1, floorsCount do
		run[f] = FloorGenerator.generateFloor(f, rand)
	end
	return run
end

--=============================================================================
-- Self test
--=============================================================================

function FloorGenerator.selfTest()
	local seed = 0.27
	local function detRng(): number
		seed = (seed * 13.7 + 0.41) % 1
		return seed
	end

	local run = FloorGenerator.generateRun(detRng)
	assert(#run == 5, "generateRun builds 5 floors")

	-- Floor 1: 5 warm-up rooms with NO boss.
	assert(#run[1] == 5, "Floor 1 has 5 rooms")
	for r = 1, 5 do
		assert(not run[1][r].isBossRoom, `Floor 1 Room {r} has no boss`)
		assert(Config.ARENA_LAYOUTS[run[1][r].arena] ~= nil, `Floor 1 Room {r} uses a valid arena layout`)
		if r > 1 then
			assert(run[1][r].id ~= run[1][r - 1].id, "no back-to-back duplicate rooms on Floor 1")
		end
	end

	-- Floors 2..5: Rooms 1..4 randomized (no back-to-back duplicates), Room 5 locked to Oh/My/Gon/OhMyGon.
	local expectedBosses = { [2] = "bossOh", [3] = "bossMy", [4] = "bossGon", [5] = "bossOhMyGon" }
	for f = 2, 5 do
		local rooms = run[f]
		assert(#rooms == 5, `Floor {f} has 5 rooms`)
		for r = 1, 4 do
			assert(not rooms[r].isBossRoom, `Floor {f} Room {r} is a normal room`)
			assert(Config.ARENA_LAYOUTS[rooms[r].arena] ~= nil, `Floor {f} Room {r} uses valid arena`)
			if r > 1 then
				assert(rooms[r].id ~= rooms[r - 1].id, `Floor {f} has no back-to-back duplicate rooms`)
			end
		end
		assert(rooms[5].isBossRoom and rooms[5].bossKind == expectedBosses[f], `Floor {f} Room 5 locks boss {expectedBosses[f]}`)
	end

	-- Active enemy cap: Zona Muerta oversized wave is capped cleanly at <= Config.MAX_ACTIVE_ENEMIES (25).
	local hugeWave = { melee = 12, ranged = 10, exploder = 8, area = 6, contact = 6, grabber = 4 }
	local capped = FloorGenerator.capWave(hugeWave, 25)
	local total = 0
	for _, n in pairs(capped) do
		total += n
	end
	assert(total <= 25 and total >= 20, `capWave trims oversized wave to <= 25 (got {total})`)
	assert(capped.melee >= 1 and capped.grabber >= 1, "capWave keeps every enemy type represented")
end

return FloorGenerator
