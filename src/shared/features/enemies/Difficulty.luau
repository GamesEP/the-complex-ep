--!strict
--[[
	Pure difficulty scaling rules shared by both realms (Fácil, Normal, Difícil, Zona Muerta).

	Scales enemy wave counts, damage, movement speed, and health cleanly from `Config.DIFFICULTIES`.
	Boss kinds (`spec.isBoss == true`) keep their count at 1 while still scaling health, damage,
	and movement speed.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local Difficulty = {}

local DAMAGE_FIELDS = {
	"damage",
	"projectileDamage",
	"beamDamage",
	"slamDamage",
	"axeThrowDamage",
	"spinTickDamage",
	"phantomStepDamage",
	"rushDamage",
	"grabDamagePerSecond",
	"blastDamage",
	"coneDamage",
	"leapDamage",
	"novaDamage",
	"areaImpactDamage",
	"areaTickDamage",
	"contactDamage",
	"passiveContactDamage",
	"myDashDamage",
	"mySweepDamage",
	"myBladeDamage",
	"gonRainImpactDamage",
	"gonRainTickDamage",
	"gonGravityDamage",
	"gonRingDamage",
}

local SPEED_FIELDS = {
	"speed",
	"lungeSpeed",
	"rushSpeed",
	"projectileSpeed",
	"axeThrowSpeed",
}

function Difficulty.isValid(id: any): boolean
	return type(id) == "string" and Config.DIFFICULTIES[id] ~= nil
end

function Difficulty.get(id: any): Config.DifficultyDef
	if type(id) == "string" and Config.DIFFICULTIES[id] then
		return Config.DIFFICULTIES[id]
	end
	return Config.DIFFICULTIES[Config.DEFAULT_DIFFICULTY]
end

function Difficulty.coopWaveMultiplier(playerCount: number?): number
	local clamped = math.clamp(math.floor(playerCount or 1), 1, Config.PARTY_MAX_PLAYERS)
	return Config.COOP_WAVE_COUNT_SCALE[clamped] or 1.0
end

function Difficulty.coopBossHealthMultiplier(playerCount: number?): number
	local clamped = math.clamp(math.floor(playerCount or 1), 1, Config.PARTY_MAX_PLAYERS)
	return Config.COOP_BOSS_HEALTH_SCALE[clamped] or 1.0
end

-- Scales an enemy count for `kind` under `diffId` and `playerCount` (1..4). Boss kinds never duplicate.
function Difficulty.scaleCount(kind: string, baseCount: number, diffId: any, playerCount: number?): number
	if baseCount <= 0 then
		return 0
	end
	local kindSpec = Config.ENEMY_KINDS[kind]
	if kindSpec and kindSpec.isBoss == true then
		return math.floor(baseCount)
	end
	local diff = Difficulty.get(diffId)
	local coopMult = Difficulty.coopWaveMultiplier(playerCount)
	return math.max(1, math.round(baseCount * diff.countMultiplier * coopMult))
end

function Difficulty.scaleWave(wave: { [string]: number }, diffId: any, playerCount: number?): { [string]: number }
	local out: { [string]: number } = {}
	for kind, count in pairs(wave) do
		local scaled = Difficulty.scaleCount(kind, count, diffId, playerCount)
		if scaled > 0 then
			out[kind] = scaled
		end
	end
	return out
end

-- Returns a shallow-cloned enemy spec with health, movement/charge speeds, and all damage fields
-- calibrated for `diffId` and `playerCount` (boss HP scales for 1-4 player co-op).
function Difficulty.scaleSpec(spec: { [string]: any }, diffId: any, playerCount: number?): { [string]: any }
	local diff = Difficulty.get(diffId)
	local scaled = table.clone(spec)
	if type(scaled.health) == "number" then
		local coopHp = if scaled.isBoss == true then Difficulty.coopBossHealthMultiplier(playerCount) else 1.0
		scaled.health = math.max(1, math.round(scaled.health * diff.healthMultiplier * coopHp))
	end
	for _, key in ipairs(SPEED_FIELDS) do
		if type(scaled[key]) == "number" then
			scaled[key] = scaled[key] * diff.speedMultiplier
		end
	end
	for _, key in ipairs(DAMAGE_FIELDS) do
		if type(scaled[key]) == "number" and scaled[key] > 0 then
			scaled[key] = math.max(1, math.round(scaled[key] * diff.damageMultiplier * 10) / 10)
		end
	end
	return scaled
end

--=============================================================================
-- Self test
--=============================================================================

function Difficulty.selfTest()
	for _, id in ipairs(Config.DIFFICULTY_ORDER) do
		assert(Difficulty.isValid(id), `DIFFICULTY_ORDER names unknown difficulty "{id}"`)
		local d = Difficulty.get(id)
		assert(d.countMultiplier > 0 and d.damageMultiplier > 0 and d.speedMultiplier > 0 and d.healthMultiplier > 0, `{id} multipliers must be positive`)
	end
	assert(not Difficulty.isValid("impossible") and not Difficulty.isValid(nil), "invalid difficulty rejected")
	assert(Difficulty.get("unknown") == Config.DIFFICULTIES[Config.DEFAULT_DIFFICULTY], "unknown id falls back to normal")

	-- Strictly increasing challenge from Easy -> Normal -> Hard -> Zona Muerta.
	local e = Difficulty.get("easy")
	local n = Difficulty.get("normal")
	local h = Difficulty.get("hard")
	local z = Difficulty.get("deadzone")
	assert(e.countMultiplier < n.countMultiplier and n.countMultiplier < h.countMultiplier and h.countMultiplier < z.countMultiplier, "counts scale up")
	assert(e.damageMultiplier < n.damageMultiplier and n.damageMultiplier < h.damageMultiplier and h.damageMultiplier < z.damageMultiplier, "damage scales up")
	assert(e.speedMultiplier < n.speedMultiplier and n.speedMultiplier < h.speedMultiplier and h.speedMultiplier < z.speedMultiplier, "speed scales up")

	-- Wave scaling keeps at least 1 enemy per non-zero kind and scales up in Zona Muerta,
	-- while boss kinds never duplicate regardless of difficulty.
	local scaledEasy = Difficulty.scaleWave({ melee = 4, ranged = 2 }, "easy")
	local scaledDead = Difficulty.scaleWave({ melee = 4, ranged = 2 }, "deadzone")
	assert(scaledEasy.melee == 3 and scaledEasy.ranged >= 1, "easy trims enemy count cleanly")
	assert(scaledDead.melee == 7 and scaledDead.ranged == 4, "Zona Muerta swells wave size")
	assert(Difficulty.scaleCount("bossOh", 1, "easy") == 1 and Difficulty.scaleCount("bossOh", 1, "deadzone") == 1, "boss count never duplicates")

	-- Spec scaling recalibrates health, speed, and damage fields without mutating the source table.
	local sample = { health = 100, speed = 20, damage = 10, slamDamage = 20 }
	local deadSpec = Difficulty.scaleSpec(sample, "deadzone")
	assert(sample.health == 100 and sample.damage == 10, "scaleSpec never mutates base spec")
	assert(deadSpec.health == 150 and deadSpec.damage == 17.5 and deadSpec.slamDamage == 35, "Zona Muerta scales health and damage")
	assert(math.abs(deadSpec.speed - 27) < 1e-5, "Zona Muerta scales movement speed")

	-- Co-op scaling (1..4 players): waves swell smoothly, bosses never duplicate, boss HP scales up.
	local soloWave = Difficulty.scaleWave({ melee = 4, bossOh = 1 }, "normal", 1)
	local duoWave = Difficulty.scaleWave({ melee = 4, bossOh = 1 }, "normal", 2)
	local quadWave = Difficulty.scaleWave({ melee = 4, bossOh = 1 }, "normal", 4)
	assert(soloWave.melee == 4 and duoWave.melee > soloWave.melee and quadWave.melee > duoWave.melee, "co-op wave counts scale 1->4")
	assert(soloWave.bossOh == 1 and duoWave.bossOh == 1 and quadWave.bossOh == 1, "co-op never duplicates bosses")

	local bossBase = { health = 1000, isBoss = true, speed = 15, damage = 20 }
	local boss1 = Difficulty.scaleSpec(bossBase, "normal", 1)
	local boss4 = Difficulty.scaleSpec(bossBase, "normal", 4)
	assert(boss1.health == 1000 and boss4.health > boss1.health, "boss HP scales for 4-player co-op")
	local mob1 = Difficulty.scaleSpec({ health = 100, speed = 15, damage = 10 }, "normal", 1)
	local mob4 = Difficulty.scaleSpec({ health = 100, speed = 15, damage = 10 }, "normal", 4)
	assert(mob1.health == mob4.health, "regular enemy HP stays crisp in co-op while count scales")
end

return Difficulty
