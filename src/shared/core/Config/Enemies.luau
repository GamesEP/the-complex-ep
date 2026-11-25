-- The three enemy kinds of the combat slice (plans/gdd/scope.md) and the waves that fill the room.
-- Every kind exists to force a different movement out of the player: the melee one to dodge,
-- the ranged one to close distance, the exploder to back off or kill it from range.
local Config = {}

export type EnemyKind = {
	model: string?,
	health: number,
	speed: number,
	size: Vector3,
	color: Color3,
	-- melee / grabber
	reach: number?,
	windup: number?,
	recover: number?,
	damage: number?,
	grabDamagePerSecond: number?,
	-- ranged
	keepAway: number?,
	fireEvery: number?,
	projectileSpeed: number?,
	projectileLife: number?,
	-- exploder
	trigger: number?,
	fuse: number?,
	blastRadius: number?,
	enemyDamage: number?,
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
	-- The dangerous one: fast, fragile, and lethal if ignored — but its blast also damages
	-- nearby enemies (`enemyDamage`), letting players kite it into a pack as a tactical tool.
	exploder = {
		health = 15,
		speed = 20,
		size = Vector3.new(3.5, 3.5, 3.5),
		color = Color3.fromRGB(240, 150, 40),
		trigger = 6,
		fuse = 0.8,
		blastRadius = 10,
		damage = 30,
		enemyDamage = 30,
	},
	-- Immobilises a player after a telegraphed windup so Dash can dodge it; drains 8 HP/s until
	-- freed by 10 attack presses or by teammates damaging/killing the grabber.
	grabber = {
		model = "EnemyGrabber",
		health = 45,
		speed = 13,
		size = Vector3.new(4.2, 5.8, 3.6),
		color = Color3.fromRGB(155, 45, 210),
		reach = 7,
		windup = 0.55,
		recover = 1.6,
		damage = 0,
		grabDamagePerSecond = 8,
	},
} :: { [string]: EnemyKind }

-- Grabber escape & damage tuning (plans/gdd/content.md).
Config.GRAB_ESCAPE_PRESSES = 10
Config.GRAB_DAMAGE_TICK_SECONDS = 0.5
-- Each ally hit on the grabber also contributes progress toward freeing the trapped player.
Config.GRAB_ALLY_HIT_PROGRESS = 2
-- Brief immunity after breaking free so two grabbers cannot chain-lock a player on the same frame.
Config.GRAB_IMMUNITY_SECONDS = 1.0
-- Studs in front of the grabber where the trapped player is held.
Config.GRAB_HOLD_DISTANCE = 3.2

-- What the ranged enemy's shot hits with, in studs from the player's root.
Config.PROJECTILE_HIT_RADIUS = 3

-- One table per wave: kind -> count. Grabber enters starting on wave 4. When the last wave is
-- cleared the room is clean, and after ROOM_RESTART_SECONDS it starts over from wave 1.
Config.WAVES = {
	{ melee = 3 },
	{ melee = 3, ranged = 2 },
	{ melee = 3, ranged = 2, exploder = 2 },
	{ melee = 3, ranged = 2, exploder = 1, grabber = 1 },
	{ melee = 4, ranged = 3, exploder = 2, grabber = 2 },
} :: { { [string]: number } }

Config.WAVE_GAP_SECONDS = 2
Config.ROOM_RESTART_SECONDS = 5

-- Enemies keep at least this far from each other, so a wave reads as a crowd and not one block.
Config.ENEMY_SPACING = 5

return Config
