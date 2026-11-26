-- Zero-pause 1-of-3 run upgrades (plans/gdd/systems.md, "Mejoras de run", plans/roadmap.md VS-15).
-- Everyone starts equal with the base sword and 0 active abilities (Pillar 1); every starter and
-- room-clear choice draws 3 distinct cards from this catalog.
local Config = {}

export type StatUpgradeDef = {
	id: string,
	title: string,
	effect: string,
	stat: "maxHealth" | "damage" | "speed" | "cooldown",
	amount: number,
}

export type PassiveUpgradeDef = {
	id: string,
	title: string,
	effect: string,
	attribute: "HasDoubleJump" | "HasDoubleDash",
}

Config.UPGRADE_CHOICES = 3
Config.START_ABILITY_CHOICES = 3
Config.ABILITY_MAX_LEVEL = 3

-- Per-level active ability scaling (Lv.1 = 1.0x, Lv.2 = 1.25x dmg / 0.90x cd, Lv.3 = 1.50x / 0.80x).
Config.ABILITY_LEVEL_DAMAGE_STEP = 0.25
Config.ABILITY_LEVEL_COOLDOWN_STEP = 0.10
-- Floor on cumulative cooldown multiplier so haste upgrades stay fast without zero-second spam.
Config.MIN_COOLDOWN_MULTIPLIER = 0.45

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
} :: { PassiveUpgradeDef }

return Config
