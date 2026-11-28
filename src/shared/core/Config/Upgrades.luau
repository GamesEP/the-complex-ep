-- Zero-pause 1-of-3 run upgrades (plans/gdd/systems.md, "Mejoras de run", plans/roadmap.md VS-15).
-- Everyone starts equal with the base sword and 0 active abilities (Pillar 1); every starter and
-- room-clear choice draws 3 distinct cards from this catalog.
local Config = {}

export type StatUpgradeDef = {
	id: string,
	title: string,
	effect: string,
	stat: "maxHealth" | "damage" | "speed" | "cooldown" | "crit" | "lifeOnKill" | "heavyHaste" | "parryBonus",
	amount: number,
}

export type PassiveUpgradeDef = {
	id: string,
	title: string,
	effect: string,
	attribute: "HasDoubleJump" | "HasDoubleDash" | "HasDashBoost" | "HasSwiftDash",
}

Config.UPGRADE_CHOICES = 3
Config.START_ABILITY_CHOICES = 3
Config.ABILITY_MAX_LEVEL = 4

-- Per-level active ability scaling (Lv.1 = 1.0x, Lv.2 = 1.25x, Lv.3 = 1.50x, Lv.4 = 1.75x dmg / 0.70x cd).
Config.ABILITY_LEVEL_DAMAGE_STEP = 0.25
Config.ABILITY_LEVEL_COOLDOWN_STEP = 0.10
-- Floor on cumulative cooldown multiplier so haste upgrades stay fast without zero-second spam.
Config.MIN_COOLDOWN_MULTIPLIER = 0.45

-- Build-defining synergy caps & movement passive multipliers (`HS-14`).
Config.CRIT_DAMAGE_MULTIPLIER = 1.6
Config.MAX_CRIT_CHANCE = 0.75
Config.MIN_HEAVY_CHARGE_MULT = 0.45
Config.PARRY_COUNTER_RADIUS = 12
Config.PARRY_COUNTER_BASE_DAMAGE = 24
Config.DASH_BOOST_DISTANCE_MULT = 1.25
Config.SWIFT_DASH_COOLDOWN_MULT = 0.75

-- Mid-air jump velocity for the Double Jump movement passive (matches Roblox JumpPower scale).
Config.DOUBLE_JUMP_POWER = 54

-- All 9 active abilities available in the roguelite 1-of-3 pool (with concise card copy).
Config.UPGRADE_ABILITY_ORDER = {
	"spin",
	"taunt",
	"bulwark",
	"stinger",
	"execute",
	"overdrive",
	"healPulse",
	"protectField",
	"shockwave",
}

Config.UPGRADE_ABILITY_COPY = {
	spin = "Giro 360° cortante en área",
	taunt = "Grito que aturde y atrae",
	bulwark = "-75% daño recibido temporal",
	stinger = "Embestida perforante veloz",
	execute = "Dagas boomerang ida y vuelta",
	overdrive = "3 ondas cortantes a distancia",
	healPulse = "Zona curativa de 10 s",
	protectField = "-45% daño a todo el equipo",
	shockwave = "Onda que empuja y aturde",
} :: { [string]: string }

-- Repeatable stat upgrades in the 1-of-3 pool.
Config.STAT_UPGRADES = {
	{
		id = "stat_hp",
		title = "Blindaje",
		effect = "+25 Vida Máx. y cura",
		stat = "maxHealth",
		amount = 25,
	},
	{
		id = "stat_dmg",
		title = "Filo Sobrecargado",
		effect = "+20% Daño total",
		stat = "damage",
		amount = 0.20,
	},
	{
		id = "stat_spd",
		title = "Impulso Cinético",
		effect = "+12% Velocidad",
		stat = "speed",
		amount = 0.12,
	},
	{
		id = "stat_cdr",
		title = "Núcleo Acelerado",
		effect = "-15% Recargas",
		stat = "cooldown",
		amount = 0.15,
	},
	{
		id = "stat_crit",
		title = "Golpe Crítico",
		effect = "+15% Crítico (×1,6)",
		stat = "crit",
		amount = 0.15,
	},
	{
		id = "stat_lifesteal",
		title = "Sifón Vital",
		effect = "+8 HP al eliminar",
		stat = "lifeOnKill",
		amount = 8,
	},
	{
		id = "stat_heavy_haste",
		title = "Carga Rápida",
		effect = "-20% carga Pesado",
		stat = "heavyHaste",
		amount = 0.20,
	},
	{
		id = "stat_parry",
		title = "Contragolpe",
		effect = "Parry desata onda +40%",
		stat = "parryBonus",
		amount = 0.40,
	},
} :: { StatUpgradeDef }

-- Unique movement passives (always active once picked; combine together and do not use an ability slot).
Config.PASSIVE_UPGRADES = {
	{
		id = "passive_double_jump",
		title = "Doble Salto",
		effect = "Salto extra en el aire",
		attribute = "HasDoubleJump",
	},
	{
		id = "passive_double_dash",
		title = "Doble Dash",
		effect = "2 cargas de Dash",
		attribute = "HasDoubleDash",
	},
	{
		id = "passive_dash_boost",
		title = "Impulso Turbo",
		effect = "+25% distancia Dash",
		attribute = "HasDashBoost",
	},
	{
		id = "passive_swift_dash",
		title = "Reflejos Ágiles",
		effect = "-25% recarga Dash",
		attribute = "HasSwiftDash",
	},
} :: { PassiveUpgradeDef }

return Config
