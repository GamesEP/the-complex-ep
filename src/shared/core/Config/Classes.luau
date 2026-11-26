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
	weapon: string,
	-- How the selection screen names the weapon.
	weaponName: string,
	-- Extra weapon model for the off hand (the Tank's shield, the Damage class's second dagger).
	offHandWeapon: string?,
	abilities: { string },
	passive: string,
}

Config.ABILITIES = {
	spin = {
		name = "Giro",
		cooldown = Combat.SPIN_COOLDOWN,
		readyAttribute = "SpinReadyAt",
		color = Color3.fromRGB(255, 200, 90),
	},
	stinger = {
		name = "Stinger",
		cooldown = Combat.STINGER_COOLDOWN,
		readyAttribute = "StingerReadyAt",
		color = Color3.fromRGB(255, 110, 80),
	},
	overdrive = {
		name = "Over Drive",
		cooldown = Combat.OVERDRIVE_COOLDOWN,
		readyAttribute = "OverDriveReadyAt",
		color = Color3.fromRGB(215, 95, 255),
	},
	taunt = {
		name = "Provocación",
		cooldown = 12,
		readyAttribute = "TauntReadyAt",
		color = Color3.fromRGB(255, 80, 80),
		glyph = "!",
	},
	bulwark = {
		name = "Muralla",
		cooldown = 10,
		readyAttribute = "BulwarkReadyAt",
		color = Color3.fromRGB(120, 180, 255),
		glyph = "M",
	},
	execute = {
		name = "Ejecución",
		cooldown = 6,
		readyAttribute = "ExecuteReadyAt",
		color = Color3.fromRGB(230, 40, 60),
		glyph = "X",
	},
	healPulse = {
		name = "Pulso curativo",
		cooldown = 10,
		readyAttribute = "HealPulseReadyAt",
		color = Color3.fromRGB(90, 230, 130),
		glyph = "+",
	},
	protectField = {
		name = "Campo protector",
		cooldown = 14,
		readyAttribute = "ProtectFieldReadyAt",
		color = Color3.fromRGB(90, 200, 255),
		glyph = "O",
	},
	shockwave = {
		name = "Onda de choque",
		cooldown = 8,
		readyAttribute = "ShockwaveReadyAt",
		color = Color3.fromRGB(235, 235, 255),
		glyph = "~",
	},
} :: { [string]: AbilityDef }

-- Order of the cards on the selection screen.
Config.CLASS_ORDER = { "tank", "dps", "support" }

Config.CLASSES = {
	tank = {
		displayName = "Tanque",
		description = "Aguanta en primera línea y atrae a los enemigos.",
		color = Color3.fromRGB(110, 160, 255),
		maxHealth = 160,
		moveSpeed = 22,
		damageMultiplier = 0.85,
		incomingMultiplier = 0.8,
		weapon = "WeaponGreatsword",
		weaponName = "Espadón y escudo",
		offHandWeapon = "WeaponShield",
		abilities = { "spin", "taunt", "bulwark" },
		passive = "Recibe un 20 % menos de daño.",
	},
	dps = {
		displayName = "Daño",
		description = "Rápido y frágil: entra, destroza y sale.",
		color = Color3.fromRGB(255, 90, 90),
		maxHealth = 85,
		moveSpeed = 28,
		damageMultiplier = 1.25,
		incomingMultiplier = 1,
		weapon = "WeaponDagger",
		weaponName = "Dos dagas",
		offHandWeapon = "WeaponDagger",
		abilities = { "stinger", "execute", "overdrive" },
		passive = "+25 % de daño a enemigos aturdidos o por la espalda.",
	},
	support = {
		displayName = "Apoyo",
		description = "Mantiene vivo al grupo y controla a la horda.",
		color = Color3.fromRGB(90, 230, 150),
		maxHealth = 100,
		moveSpeed = 25,
		damageMultiplier = 0.9,
		incomingMultiplier = 1,
		weapon = "WeaponStaff",
		weaponName = "Báculo de energía",
		abilities = { "healPulse", "protectField", "shockwave" },
		passive = "Regenera vida poco a poco a los aliados cercanos (y a sí mismo).",
	},
} :: { [string]: ClassDef }

-- Taunt (Tank): every enemy within the radius targets the tank for the duration.
Config.TAUNT_RADIUS = 24
Config.TAUNT_DURATION = 4

-- Bulwark (Tank): a frontal shield that stops every ranged hit coming from in front.
Config.BULWARK_DURATION = 3.5
Config.BULWARK_ARC = 140

-- Execute (Damage): a frontal strike that does far more to an enemy already low on health.
Config.EXECUTE_DAMAGE = 30
Config.EXECUTE_RANGE = 9
Config.EXECUTE_ARC = 100
Config.EXECUTE_THRESHOLD = 0.35
Config.EXECUTE_MULTIPLIER = 3

-- Damage passive: bonus against an enemy recovering from its own attack (stunned) or hit from
-- behind. "Behind" is outside this cone in front of the enemy, in degrees.
Config.DPS_PASSIVE_BONUS = 0.25
Config.DPS_BACKSTAB_FRONT_ARC = 180

-- Heal pulse (Support): heals every living player in the radius, the caster included.
Config.HEAL_PULSE_AMOUNT = 30
Config.HEAL_PULSE_RADIUS = 18

-- Protect field (Support): a zone on the floor that cuts damage taken inside it.
Config.PROTECT_FIELD_DURATION = 6
Config.PROTECT_FIELD_RADIUS = 12
Config.PROTECT_FIELD_REDUCTION = 0.4

-- Shockwave (Support): hurts, pushes away and slows every enemy around the caster.
Config.SHOCKWAVE_RADIUS = 13
Config.SHOCKWAVE_DAMAGE = 12
Config.SHOCKWAVE_PUSH_DISTANCE = 10
Config.SHOCKWAVE_PUSH_SECONDS = 0.25
Config.SHOCKWAVE_SLOW_FACTOR = 0.5
Config.SHOCKWAVE_SLOW_SECONDS = 3

-- Support passive: health restored per second to every living player inside the aura.
Config.SUPPORT_REGEN_PER_SECOND = 2
Config.SUPPORT_REGEN_RADIUS = 20

return Config
