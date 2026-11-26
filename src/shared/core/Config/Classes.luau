-- The three test classes (plans/gdd/systems.md, "Clases") and the nine abilities they share out.
-- A temporary exception to pillar 1 so the gameplay can be tried with distinct roles; every number
-- here is a starting value to tune by playing.
local Combat = require(script.Parent.Combat)

local Config = {}

export type AbilityDef = {
	name: string,
	cooldown: number,
	-- The player attribute holding the server-time this ability is ready again. The three original
	-- abilities keep the names they already had, so nothing that reads them had to change.
	readyAttribute: string,
	color: Color3,
	-- Letter drawn on the HUD tile for abilities that have no bespoke emblem yet.
	glyph: string?,
}

export type ClassDef = {
	displayName: string,
	description: string,
	color: Color3,
	maxHealth: number,
	moveSpeed: number,
	damageMultiplier: number,
	-- Multiplies every hit this class takes (the Tank's passive).
	incomingMultiplier: number,
	-- "melee" swings in a frontal arc with step-in lunge; "ranged" fires energy bolts with no lunge.
	attackStyle: "melee" | "ranged",
	weapon: string,
	-- How the selection screen names the weapon.
	weaponName: string,
	-- Extra weapon model for the off hand (the Tank's shield, the Damage class's second dagger).
	offHandWeapon: string?,
	heavyName: string,
	abilities: { string },
	passive: string,
}

Config.ABILITIES = {
	spin = {
		name = "Torbellino",
		cooldown = Combat.SPIN_COOLDOWN,
		readyAttribute = "SpinReadyAt",
		color = Color3.fromRGB(255, 210, 65),
	},
	stinger = {
		name = "Estocada",
		cooldown = Combat.STINGER_COOLDOWN,
		readyAttribute = "StingerReadyAt",
		color = Color3.fromRGB(255, 110, 70),
	},
	overdrive = {
		name = "Corte Final",
		cooldown = Combat.OVERDRIVE_COOLDOWN,
		readyAttribute = "OverDriveReadyAt",
		color = Color3.fromRGB(215, 110, 255),
	},
	taunt = {
		name = "Rugido",
		cooldown = 10,
		readyAttribute = "TauntReadyAt",
		color = Color3.fromRGB(255, 145, 45),
		glyph = "!",
	},
	bulwark = {
		name = "Coraza",
		cooldown = 12,
		readyAttribute = "BulwarkReadyAt",
		color = Color3.fromRGB(85, 200, 255),
		glyph = "C",
	},
	execute = {
		name = "Vórtice",
		cooldown = 6.5,
		readyAttribute = "ExecuteReadyAt",
		color = Color3.fromRGB(255, 65, 130),
		glyph = "V",
	},
	healPulse = {
		name = "Santuario",
		cooldown = 14,
		readyAttribute = "HealPulseReadyAt",
		color = Color3.fromRGB(70, 245, 145),
		glyph = "+",
	},
	protectField = {
		name = "Barrera",
		cooldown = 14,
		readyAttribute = "ProtectFieldReadyAt",
		color = Color3.fromRGB(75, 225, 255),
		glyph = "B",
	},
	shockwave = {
		name = "Repulsión",
		cooldown = 9,
		readyAttribute = "ShockwaveReadyAt",
		color = Color3.fromRGB(205, 165, 255),
		glyph = "~",
	},
} :: { [string]: AbilityDef }

-- Order of the cards on the selection screen.
Config.CLASS_ORDER = { "tank", "dps", "support" }

Config.CLASSES = {
	tank = {
		displayName = "Tanque",
		description = "Aguanta en primera línea, aturde con su rugido y resiste golpes pesados.",
		color = Color3.fromRGB(110, 160, 255),
		maxHealth = 160,
		moveSpeed = 22,
		damageMultiplier = 0.85,
		incomingMultiplier = 0.8,
		attackStyle = "melee",
		weapon = "WeaponSpikedMace",
		weaponName = "Mazo con púas y escudo",
		offHandWeapon = "WeaponShield",
		heavyName = "IMPACTO SÍSMICO",
		abilities = { "spin", "taunt", "bulwark" },
		passive = "Recibe un 20 % menos de daño.",
	},
	dps = {
		displayName = "Daño",
		description = "Rápido y letal: atraviesa líneas y lanza sus dagas como boomerang.",
		color = Color3.fromRGB(255, 90, 90),
		maxHealth = 85,
		moveSpeed = 28,
		damageMultiplier = 1.25,
		incomingMultiplier = 1,
		attackStyle = "melee",
		weapon = "WeaponDagger",
		weaponName = "Dos dagas",
		offHandWeapon = "WeaponDagger",
		heavyName = "DESGARRO",
		abilities = { "stinger", "execute", "overdrive" },
		passive = "+25 % de daño a enemigos aturdidos o por la espalda.",
	},
	support = {
		displayName = "Apoyo",
		description = "Dispara energía a distancia, crea un santuario curativo y protege al grupo.",
		color = Color3.fromRGB(90, 230, 150),
		maxHealth = 100,
		moveSpeed = 25,
		damageMultiplier = 0.9,
		incomingMultiplier = 1,
		attackStyle = "ranged",
		weapon = "WeaponStaff",
		weaponName = "Báculo de energía (a distancia)",
		heavyName = "ORBE DE PLASMA",
		abilities = { "healPulse", "protectField", "shockwave" },
		passive = "Regenera vida poco a poco a los aliados cercanos (y a sí mismo).",
	},
} :: { [string]: ClassDef }

-- Support ranged staff basic attacks (3-step combo fired as traveling energy bolts).
Config.STAFF_AIM_ASSIST_RANGE = 42
Config.STAFF_BOLT_RANGE = 42
Config.STAFF_BOLT_SPEED = 78
Config.STAFF_BOLT_RADIUS = 2.0
Config.STAFF_BOLT_FINISHER_RADIUS = 2.8
Config.STAFF_BOLT_FINISHER_SPLASH = 6.5

-- Tank War Cry (taunt): stuns every enemy in radius, interrupts their windups/abilities, and
-- draws their aggro back to the tank once they wake up.
Config.TAUNT_RADIUS = 22
Config.TAUNT_DURATION = 5
Config.TAUNT_STUN_DURATION = 2.6
Config.TAUNT_DAMAGE = 8

-- Tank Muralla (bulwark): personal armored buff cutting ALL incoming damage by 75%.
Config.BULWARK_DURATION = 5.5
Config.BULWARK_REDUCTION = 0.75

-- Damage Boomerang Daggers (execute): throws twin spinning daggers out and curves them back to
-- the player's live position, slicing enemies on both the outbound and return passes.
Config.BOOMERANG_RANGE = 30
Config.BOOMERANG_OUT_SECONDS = 0.42
Config.BOOMERANG_RETURN_SECONDS = 0.45
Config.BOOMERANG_HIT_RADIUS = 3.2
Config.BOOMERANG_OUT_DAMAGE = 24
Config.BOOMERANG_RETURN_DAMAGE = 28
Config.EXECUTE_THRESHOLD = 0.35
Config.EXECUTE_MULTIPLIER = 1.6

-- Damage passive: bonus against an enemy stunned/recovering or hit from behind.
-- "Behind" is outside this cone in front of the enemy, in degrees.
Config.DPS_PASSIVE_BONUS = 0.25
Config.DPS_BACKSTAB_FRONT_ARC = 180

-- Support Healing Zone (healPulse): persistent 10 s floor zone healing every player inside.
Config.HEAL_ZONE_DURATION = 10
Config.HEAL_ZONE_RADIUS = 13
Config.HEAL_ZONE_TICK_SECONDS = 0.5
Config.HEAL_ZONE_HEAL_PER_SECOND = 14
Config.HEAL_ZONE_INITIAL_BURST = 12

-- Support Squad Shield (protectField): team-wide defense buff applied to every living player.
Config.PROTECT_BUFF_DURATION = 8
Config.PROTECT_BUFF_REDUCTION = 0.45

-- Support Shockwave (shockwave): damages, pushes back, and stuns every enemy around the caster.
Config.SHOCKWAVE_RADIUS = 15
Config.SHOCKWAVE_DAMAGE = 16
Config.SHOCKWAVE_PUSH_DISTANCE = 11
Config.SHOCKWAVE_PUSH_SECONDS = 0.25
Config.SHOCKWAVE_STUN_DURATION = 2.4
Config.SHOCKWAVE_SLOW_FACTOR = 0.55
Config.SHOCKWAVE_SLOW_SECONDS = 4.0

-- Support passive: health restored per second to every living player inside the aura.
Config.SUPPORT_REGEN_PER_SECOND = 2
Config.SUPPORT_REGEN_RADIUS = 20

-- Role-specific Heavy Attack tunables (all share Config.HEAVY_CHARGE_SECONDS and cooldown).
-- Tank: circular greatsword seismic slam that staggers/stuns nearby enemies.
Config.TANK_HEAVY_DAMAGE = 60
Config.TANK_HEAVY_RADIUS = 14
Config.TANK_HEAVY_OFFSET = 3.5
Config.TANK_HEAVY_STUN_DURATION = 1.15
Config.TANK_HEAVY_PUSH_DISTANCE = 4.5
-- Damage: twin diagonal X-slash burst (two rapid strikes).
Config.DPS_HEAVY_HIT_DAMAGE = 30
Config.DPS_HEAVY_RANGE = 12.5
Config.DPS_HEAVY_ARC = 135
Config.DPS_HEAVY_SECOND_DELAY = 0.09
-- Support: long-range exploding arcane orb with AoE stun.
Config.SUPPORT_HEAVY_DAMAGE = 52
Config.SUPPORT_HEAVY_RANGE = 46
Config.SUPPORT_HEAVY_SPEED = 58
Config.SUPPORT_HEAVY_ORB_RADIUS = 2.6
Config.SUPPORT_HEAVY_BLAST_RADIUS = 12
Config.SUPPORT_HEAVY_STUN_DURATION = 1.05

return Config
