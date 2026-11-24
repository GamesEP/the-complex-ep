-- The three enemy kinds of the combat slice (plans/gdd/scope.md) and the waves that fill the room.
-- Every kind exists to force a different movement out of the player: the melee one to dodge,
-- the ranged one to close distance, the exploder to back off or kill it from range.
local Config = {}

export type EnemyKind = {
	health: number,
	speed: number,
	size: Vector3,
	color: Color3,
	-- melee
	reach: number?,
	windup: number?,
	recover: number?,
	damage: number?,
	-- ranged
	keepAway: number?,
	fireEvery: number?,
	projectileSpeed: number?,
	projectileLife: number?,
	-- exploder
	trigger: number?,
	fuse: number?,
	blastRadius: number?,
}

Config.ENEMY_KINDS = {
	-- Telegraphs every swing with a windup, so a dash during it always works.
	melee = {
		health = 30,
		speed = 14,
		size = Vector3.new(4, 5, 4),
		color = Color3.fromRGB(200, 60, 60),
		reach = 6,
		windup = 0.45,
		recover = 0.8,
		damage = 10,
	},
	-- Holds its distance and shoots; slow projectiles, so a moving player is never hit by accident.
	ranged = {
		health = 20,
		speed = 10,
		size = Vector3.new(3, 5, 3),
		color = Color3.fromRGB(70, 120, 220),
		keepAway = 28,
		fireEvery = 1.6,
		projectileSpeed = 45,
		projectileLife = 2.5,
		damage = 8,
	},
	-- The dangerous one: fast, fragile, and lethal if ignored.
	exploder = {
		health = 15,
		speed = 20,
		size = Vector3.new(3.5, 3.5, 3.5),
		color = Color3.fromRGB(240, 150, 40),
		trigger = 6,
		fuse = 0.8,
		blastRadius = 10,
		damage = 30,
	},
} :: { [string]: EnemyKind }

-- What the ranged enemy's shot hits with, in studs from the player's root.
Config.PROJECTILE_HIT_RADIUS = 3

-- One table per wave: kind -> count. When the last wave is cleared the room is clean, and after
-- ROOM_RESTART_SECONDS it starts over from wave 1 — the slice is for playing the fight again and
-- again, not for finishing it.
Config.WAVES = {
	{ melee = 3 },
	{ melee = 3, ranged = 2 },
	{ melee = 3, ranged = 2, exploder = 2 },
} :: { { [string]: number } }

Config.WAVE_GAP_SECONDS = 2
Config.ROOM_RESTART_SECONDS = 5

-- Enemies keep at least this far from each other, so a wave reads as a crowd and not one block.
Config.ENEMY_SPACING = 5

return Config
