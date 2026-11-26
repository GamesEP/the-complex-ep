-- The three enemy kinds of the combat slice (plans/gdd/scope.md) and the waves that fill the room.
-- Every kind exists to force a different movement out of the player: the melee one to dodge,
-- the ranged one to close distance, the exploder to back off or kill it from range.
local Config = {}

export type EnemyVariant = {
	model: string,
	weapon: string,
	-- Optional relative spawn weight (default 1) so rare specialists like minigun appear occasionally.
	weight: number?,
	-- Melee dual-blade spin DPS ability.
	canSpin: boolean?,
	spinDuration: number?,
	spinTickEvery: number?,
	spinTickDamage: number?,
	spinRadius: number?,
	spinCooldown: number?,
	spinMoveFactor: number?,
	-- Melee single-sword Sandevistan multi-dash ambush ability.
	canSandevistan: boolean?,
	sandevistanSteps: number?,
	sandevistanStepDuration: number?,
	sandevistanRange: number?,
	sandevistanCooldown: number?,
	sandevistanStrikeWindup: number?,
	sandevistanDamage: number?,
	-- Ranged burst / tracer-line / charged rail-beam fire overrides.
	burstCount: number?,
	burstInterval: number?,
	burstSpreadDeg: number?,
	fireEvery: number?,
	projectileStyle: ("orb" | "tracer")?,
	projectileSpeed: number?,
	projectileDamage: number?,
	canBeam: boolean?,
	beamCharge: number?,
	beamLockTime: number?,
	beamCooldown: number?,
	beamDamage: number?,
	beamRange: number?,
	beamRadius: number?,
	beamHeight: number?,
	beamRecover: number?,
}

export type EnemyKind = {
	model: string?,
	variants: { EnemyVariant }?,
	health: number,
	speed: number,
	size: Vector3,
	color: Color3,
	-- melee / grabber
	reach: number?,
	strikeHeight: number?,
	windup: number?,
	recover: number?,
	damage: number?,
	grabDamagePerSecond: number?,
	lungeDuration: number?,
	lungeSpeed: number?,
	grabRadius: number?,
	-- ranged
	keepAway: number?,
	fireEvery: number?,
	projectileSpeed: number?,
	projectileLife: number?,
	evadeTrigger: number?,
	evadeDuration: number?,
	evadeDistance: number?,
	evadeArcHeight: number?,
	evadeCooldown: number?,
	-- exploder
	trigger: number?,
	fuse: number?,
	blastRadius: number?,
	blastHeight: number?,
	enemyDamage: number?,
}

Config.ENEMY_KINDS = {
	-- Telegraphs every swing with a windup, so a dash during it always works. Spawns across
	-- four rigged `.rbxmx` weapon variants: single-sword units can trigger a Sandevistan 3-dash
	-- ambush, and dual-blade units unleash a high-DPS spin attack.
	melee = {
		model = "EnemyMelee",
		variants = {
			{
				model = "EnemyMelee",
				weapon = "sword",
				canSandevistan = true,
				sandevistanSteps = 3,
				sandevistanStepDuration = 0.15,
				sandevistanRange = 24,
				sandevistanCooldown = 7.0,
				sandevistanStrikeWindup = 0.38,
				sandevistanDamage = 15,
			},
			{
				model = "EnemyMeleeDual",
				weapon = "dual",
				canSpin = true,
				spinDuration = 1.6,
				spinTickEvery = 0.25,
				spinTickDamage = 6,
				spinRadius = 8.0,
				spinCooldown = 6.5,
				spinMoveFactor = 0.65,
			},
			{ model = "EnemyMeleeAxe", weapon = "axe" },
			{ model = "EnemyMeleeMace", weapon = "mace" },
		},
		health = 30,
		speed = 14,
		size = Vector3.new(4, 5, 4),
		color = Color3.fromRGB(200, 60, 60),
		reach = 6,
		strikeHeight = 4.5,
		windup = 0.45,
		recover = 0.8,
		damage = 10,
	},
	-- Holds its distance and shoots across 4 weapon variants: rifle (can overcharge a devastating
	-- rail-beam), double-burst shotgun & plasma cannon (2 shots per attack), and an occasional
	-- heavy minigun firing rapid ballistic tracer lines. All ranged units backstep-leap away when
	-- a player closes within `evadeTrigger` (at least 5 s cooldown).
	ranged = {
		model = "EnemyRanged",
		variants = {
			{
				model = "EnemyRanged",
				weapon = "rifle",
				weight = 4,
				burstCount = 1,
				projectileStyle = "orb",
				canBeam = true,
				beamCharge = 1.4,
				beamLockTime = 0.4,
				beamCooldown = 5.5,
				beamDamage = 32,
				beamRange = 65,
				beamRadius = 2.6,
				beamHeight = 3.4,
				beamRecover = 1.0,
			},
			{
				model = "EnemyRangedShotgun",
				weapon = "shotgun",
				weight = 3,
				burstCount = 2,
				burstInterval = 0.2,
				burstSpreadDeg = 3,
				projectileStyle = "orb",
			},
			{
				model = "EnemyRangedCarbine",
				weapon = "plasma",
				weight = 2,
				burstCount = 2,
				burstInterval = 0.18,
				burstSpreadDeg = 2,
				projectileStyle = "orb",
				canBeam = true,
				beamCharge = 1.5,
				beamLockTime = 0.4,
				beamCooldown = 6.5,
				beamDamage = 28,
				beamRange = 50,
				beamRadius = 2.6,
				beamHeight = 3.4,
				beamRecover = 1.1,
			},
			{
				model = "EnemyRangedMinigun",
				weapon = "minigun",
				weight = 2,
				burstCount = 6,
				burstInterval = 0.11,
				burstSpreadDeg = 5,
				fireEvery = 2.4,
				projectileStyle = "tracer",
				projectileSpeed = 72,
				projectileDamage = 3.5,
			},
		},
		health = 20,
		speed = 10,
		size = Vector3.new(3, 5, 3),
		color = Color3.fromRGB(70, 120, 220),
		keepAway = 28,
		fireEvery = 1.6,
		projectileSpeed = 45,
		projectileLife = 2.5,
		damage = 8,
		evadeTrigger = 11,
		evadeDuration = 0.34,
		evadeDistance = 20,
		evadeArcHeight = 5.5,
		evadeCooldown = 5.5,
	},
	-- The dangerous one: fast, fragile, and lethal if ignored — carries strapped C4 and TNT sticks.
	-- Its blast is a flattened oval (`blastHeight < blastRadius`) so jumping near the outer rim
	-- clears the dome cleanly, and it also damages nearby enemies (`enemyDamage`).
	exploder = {
		model = "EnemyExploder",
		health = 15,
		speed = 20,
		size = Vector3.new(3.5, 4.0, 3.5),
		color = Color3.fromRGB(240, 150, 40),
		trigger = 6,
		fuse = 0.8,
		blastRadius = 10,
		blastHeight = 7,
		damage = 30,
		enemyDamage = 30,
	},
	-- Huge muscular juggernaut: telegraphs a windup (HUD Dash warning) and then lunges forward
	-- to seize the player, draining 8 HP/s until freed by 10 attack presses or teammates.
	grabber = {
		model = "EnemyGrabber",
		health = 45,
		speed = 13,
		size = Vector3.new(4.8, 6.2, 4.2),
		color = Color3.fromRGB(155, 45, 210),
		reach = 13,
		windup = 0.55,
		lungeDuration = 0.28,
		lungeSpeed = 52,
		grabRadius = 4.6,
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
-- Studs in front of the muscular grabber's chest where the trapped player is clutched.
Config.GRAB_HOLD_DISTANCE = 3.8

-- Height above the floor (Y = 0) where ranged projectiles travel, and their 3D hit ellipsoid so
-- standing players are hit reliably while a jump clears the shot cleanly.
Config.PROJECTILE_HEIGHT = 2
Config.PROJECTILE_HIT_RADIUS = 3
Config.PROJECTILE_HIT_HEIGHT = 2.6

-- Uniform 2D spatial grid cell size (studs) used by EnemyService for local neighborhood queries
-- (exploder blast damage and crowd separation) without scanning every enemy in the room.
Config.ENEMY_GRID_CELL_SIZE = 12

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

-- Enemies keep well apart so waves cannot easily be herded into one tight ball.
Config.ENEMY_SPACING = 9.5
Config.AI_RANGED_SPACING = 16
Config.AI_SEPARATION_WEIGHT = 1.45

-- Roaming motion when every living player is currently grabbed (solo play or full-party grab):
-- enemies keep prowling the room while steering clear of grabbed players instead of freezing.
Config.ENEMY_WANDER_SPEED_FACTOR = 0.65
Config.ENEMY_WANDER_INTERVAL = 2.0
Config.ENEMY_GRAB_AVOID_RADIUS = 12

-- Tactical squad AI: limits simultaneous attackers per player and assigns spread-out 360-degree
-- angular sectors so every enemy approaches from a different angle instead of clumping together.
Config.AI_MAX_MELEE_ATTACKERS = 2
Config.AI_FLANK_RADIUS = 14.5
Config.AI_FLANK_BAND = 2.5
Config.AI_FLANK_SPEED_FACTOR = 0.85
Config.AI_ATTACKER_PINCER_WEIGHT = 0.65
Config.AI_RECOVER_BACKSTEP_FACTOR = 0.42
Config.AI_RANGED_STRAFE_FACTOR = 0.62
Config.AI_RANGED_STAGGER_SECONDS = 0.55
Config.AI_EXPLODER_LEAD_SECONDS = 0.40
Config.AI_EXPLODER_CURVE_WEIGHT = 0.55
Config.AI_GRABBER_FLANK_WEIGHT = 0.65
-- Interval range (seconds) between unpredictable individual flank/sector shifts.
Config.AI_SHIFT_MIN_SECONDS = 2.4
Config.AI_SHIFT_MAX_SECONDS = 5.2
-- Effective distance penalty (studs) per enemy already targeting a player so co-op squads split
-- pressure across teammates instead of forming a single conga line.
Config.AI_COOP_CROWD_PENALTY = 6

return Config
