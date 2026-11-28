-- Combat difficulty tiers: Fácil, Normal, Difícil and Zona Muerta (extreme).
-- Scales enemy wave counts, damage, movement speed, and health; bosses (`isBoss = true`) scale
-- their stats but always remain a single boss unit.
local Config = {}

export type DifficultyDef = {
	displayName: string,
	shortName: string,
	description: string,
	color: Color3,
	countMultiplier: number,
	damageMultiplier: number,
	speedMultiplier: number,
	healthMultiplier: number,
}

Config.DEFAULT_DIFFICULTY = "normal"

Config.DIFFICULTY_ORDER = { "easy", "normal", "hard", "deadzone" }

Config.DIFFICULTIES = {
	easy = {
		displayName = "Fácil",
		shortName = "FÁCIL",
		description = "Menos enemigos, más lentos y con daño reducido.",
		color = Color3.fromRGB(68, 227, 123),
		countMultiplier = 0.75,
		damageMultiplier = 0.7,
		speedMultiplier = 0.85,
		healthMultiplier = 0.8,
	},
	normal = {
		displayName = "Normal",
		shortName = "NORMAL",
		description = "Balance estándar de The Complex.",
		color = Color3.fromRGB(245, 196, 0),
		countMultiplier = 1.0,
		damageMultiplier = 1.0,
		speedMultiplier = 1.0,
		healthMultiplier = 1.0,
	},
	hard = {
		displayName = "Difícil",
		shortName = "DIFÍCIL",
		description = "Hordas más densas, rápidos y golpes duros.",
		color = Color3.fromRGB(255, 122, 56),
		countMultiplier = 1.35,
		damageMultiplier = 1.35,
		speedMultiplier = 1.18,
		healthMultiplier = 1.25,
	},
	deadzone = {
		displayName = "Zona Muerta",
		shortName = "ZONA MUERTA",
		description = "Extremo: oleadas masivas, enemigos veloces y daño letal.",
		color = Color3.fromRGB(255, 46, 76),
		countMultiplier = 1.75,
		damageMultiplier = 1.75,
		speedMultiplier = 1.35,
		healthMultiplier = 1.5,
	},
} :: { [string]: DifficultyDef }

-- Co-op scaling by active player count (1..4) per `plans/roadmap.md HS-31`.
-- Wave counts still clamp strictly to `Config.MAX_ACTIVE_ENEMIES` (25), and if a teammate leaves
-- mid-run (`HS-03`), subsequent waves & bosses automatically rescale to the remaining count.
Config.COOP_WAVE_COUNT_SCALE = {
	[1] = 1.0,
	[2] = 1.35,
	[3] = 1.7,
	[4] = 2.0,
}

Config.COOP_BOSS_HEALTH_SCALE = {
	[1] = 1.0,
	[2] = 1.65,
	[3] = 2.25,
	[4] = 2.85,
}

return Config
