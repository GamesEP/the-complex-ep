--!strict
--[[
	The rules of the test classes, shared by both realms: which ability sits in which slot, and how
	a class changes damage dealt and taken.

	The client reads these to know what to draw and which ability a key fires; the server reads the
	same functions to decide whether a player may use an ability and how hard it hits. One copy, so
	the HUD can never show an ability the server would refuse.

	A player with no class yet (`nil`, still on the selection screen) gets the neutral answer
	everywhere: no abilities, ×1 damage. See plans/gdd/systems.md, "Clases".
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local Classes = {}

function Classes.get(classId: string?): any
	if type(classId) ~= "string" then
		return nil
	end
	return Config.CLASSES[classId]
end

function Classes.isValid(classId: any): boolean
	return type(classId) == "string" and Config.CLASSES[classId] ~= nil
end

-- The ability id in `slot` (1..3) for this class, or nil.
function Classes.abilityAt(classId: string?, slot: number): string?
	local class = Classes.get(classId)
	if not class then
		return nil
	end
	return class.abilities[slot]
end

-- Whether this class owns this ability. The server refuses any ability a class does not have, so
-- a client cannot fire the Tank's taunt as the Damage class by sending its id.
function Classes.hasAbility(classId: string?, abilityId: string): boolean
	local class = Classes.get(classId)
	if not class then
		return false
	end
	return table.find(class.abilities, abilityId) ~= nil
end

-- Whether `attacker` is behind an enemy at `enemyPosition` facing `enemyLook`: outside the cone of
-- `frontArc` degrees in front of it. Flat, like every other combat check.
function Classes.isBehind(enemyPosition: Vector3, enemyLook: Vector3, attacker: Vector3, frontArc: number): boolean
	local toAttacker = Vector3.new(attacker.X - enemyPosition.X, 0, attacker.Z - enemyPosition.Z)
	local look = Vector3.new(enemyLook.X, 0, enemyLook.Z)
	if toAttacker.Magnitude < 1e-3 or look.Magnitude < 1e-3 then
		return false
	end
	return toAttacker.Unit:Dot(look.Unit) < math.cos(math.rad(frontArc / 2))
end

-- What a hit from this class is multiplied by. `vulnerable` is the Damage passive's condition
-- (the enemy is recovering from its own attack, or is hit from behind).
function Classes.outgoingMultiplier(classId: string?, vulnerable: boolean): number
	local class = Classes.get(classId)
	if not class then
		return 1
	end
	local multiplier = class.damageMultiplier
	if classId == "dps" and vulnerable then
		multiplier *= 1 + Config.DPS_PASSIVE_BONUS
	end
	return multiplier
end

-- What a hit taken by this class is multiplied by (the Tank passive).
function Classes.incomingMultiplier(classId: string?): number
	local class = Classes.get(classId)
	return if class then class.incomingMultiplier else 1
end

-- Execute: far more damage to an enemy at or below the threshold of its health.
function Classes.executeDamage(base: number, health: number, maxHealth: number): number
	if maxHealth > 0 and health / maxHealth <= Config.EXECUTE_THRESHOLD then
		return base * Config.EXECUTE_MULTIPLIER
	end
	return base
end

--=============================================================================
-- Self test
--=============================================================================

function Classes.selfTest()
	-- Every class has a full, valid kit and its weapons named.
	for _, classId in ipairs(Config.CLASS_ORDER) do
		local class = Classes.get(classId)
		assert(class ~= nil, `CLASS_ORDER names "{classId}", which is not in CLASSES`)
		assert(#class.abilities == Config.ABILITY_SLOTS, `{classId} must fill every ability slot`)
		for _, abilityId in ipairs(class.abilities) do
			assert(Config.ABILITIES[abilityId] ~= nil, `{classId} uses unknown ability "{abilityId}"`)
		end
		assert(class.weapon ~= "", `{classId} has no weapon`)
	end

	assert(not Classes.isValid(nil) and not Classes.isValid("wizard") and not Classes.isValid(3), "only real class ids are valid")
	assert(Classes.isValid("tank"), "tank is a class")

	assert(Classes.abilityAt("tank", 2) == "taunt", "the tank's second slot is taunt")
	assert(Classes.abilityAt(nil, 1) == nil, "no class, no abilities")
	assert(Classes.hasAbility("dps", "stinger") and not Classes.hasAbility("dps", "taunt"), "a class only owns its own kit")
	assert(not Classes.hasAbility(nil, "spin"), "no class owns nothing")

	-- Damage.
	assert(Classes.outgoingMultiplier(nil, true) == 1, "no class hits at x1")
	assert(Classes.outgoingMultiplier("tank", true) == 0.85, "the tank's passive bonus does not exist")
	assert(Classes.outgoingMultiplier("dps", false) == 1.25, "the damage class hits harder")
	assert(math.abs(Classes.outgoingMultiplier("dps", true) - 1.25 * 1.25) < 1e-6, "and harder still on a vulnerable enemy")
	assert(Classes.incomingMultiplier("tank") == 0.8 and Classes.incomingMultiplier("dps") == 1, "only the tank takes less")
	assert(Classes.incomingMultiplier(nil) == 1, "no class takes normal damage")

	-- Behind.
	local origin = Vector3.new(0, 0, 0)
	local facingNorth = Vector3.new(0, 0, -1)
	assert(not Classes.isBehind(origin, facingNorth, Vector3.new(0, 0, -5), 180), "in front is not behind")
	assert(Classes.isBehind(origin, facingNorth, Vector3.new(0, 0, 5), 180), "straight behind is behind")
	assert(not Classes.isBehind(origin, facingNorth, Vector3.new(5, 0, -1), 180), "beside and slightly ahead is not behind")
	assert(not Classes.isBehind(origin, facingNorth, origin, 180), "on top of it is not behind")

	-- Execute.
	assert(Classes.executeDamage(30, 100, 100) == 30, "a healthy enemy takes the base execute")
	assert(Classes.executeDamage(30, 30, 100) == 90, "a weakened enemy takes the full execute")
end

return Classes
