-- The three enemy kinds of the combat slice (plans/gdd/scope.md) and the waves that fill the room.
-- Every kind exists to force a different movement out of the player: the melee one to dodge,
-- the ranged one to close distance, the exploder to back off or kill it from range.
local Config = {}

export type EnemyVariant = {
	model: string,
	weapon: string,
	-- Optional relative spawn weight (default 1) so rare specialists like minigun appear occasionally.
	weight: number?,
	-- Overrides the kind's health, so a heavier weapon reads as a tougher enemy (see the health
	-- ladder above ENEMY_KINDS).
	health: number?,
	-- Melee dual-blade spin DPS ability.
	canSpin: boolean?,
	spinDuration: number?,
	spinTickEvery: number?,
	spinTickDamage: number?,
	spinRadius: number?,
	spinCooldown: number?,
	spinMoveFactor: number?,
	-- Melee single-sword Paso Fantasma (Phantom Step) multi-dash ambush ability.
	canPhantomStep: boolean?,
	phantomStepCount: number?,
	phantomStepDuration: number?,
	phantomStepRange: number?,
	phantomStepCooldown: number?,
	phantomStepStrikeWindup: number?,
	phantomStepDamage: number?,
	-- Melee mace seismic ground-slam stun ability.
	canSlam: boolean?,
	slamRange: number?,
	slamRadius: number?,
	slamHeight: number?,
	slamWindup: number?,
	slamCooldown: number?,
	slamDamage: number?,
	slamStunDuration: number?,
	-- Melee axe throw ability: hurls axe at mid-range; on miss it embeds in the floor and the
	-- enemy must sprint over to pick it up before fighting with it again.
	canAxeThrow: boolean?,
	axeThrowMinRange: number?,
	axeThrowMaxRange: number?,
	axeThrowWindup: number?,
	axeThrowSpeed: number?,
	axeThrowDamage: number?,
	axeThrowCooldown: number?,
	axeThrowMaxDistance: number?,
	axePickupRadius: number?,
	axeRetrieveSpeedFactor: number?,
	-- Ranged burst / shotgun spread / tracer-line / charged rail-beam fire overrides.
	burstCount: number?,
	burstInterval: number?,
	burstSpreadDeg: number?,
	pelletCount: number?,
	pelletSpreadDeg: number?,
	fireEvery: number?,
	projectileStyle: ("orb" | "tracer")?,
	projectileSpeed: number?,
	projectileDamage: number?,
	-- Set false on rapid-fire tracer specialists (minigun) so Parry cannot deflect their hail.
	canParry: boolean?,
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
	-- The name a player reads (Spanish, as in plans/gdd/content.md). The table keys below (`melee`,
	-- `ranged`, ...) stay as internal ids: they name the role in code, Brain and the waves, and
	-- renaming them would touch every module for no visible change.
	displayName: string,
	bossTitle: string?,
	isBoss: boolean?,
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
	-- Boss Oh heavy titan attacks
	coneRange: number?,
	coneArc: number?,
	coneWindup: number?,
	coneDamage: number?,
	coneStunDuration: number?,
	leapMinRange: number?,
	leapMaxRange: number?,
	leapWindup: number?,
	leapDuration: number?,
	leapArcHeight: number?,
	leapRadius: number?,
	leapHeight: number?,
	leapDamage: number?,
	leapStunDuration: number?,
	leapCooldown: number?,
	novaWindup: number?,
	novaCooldown: number?,
	novaWaves: number?,
	novaOrbCount: number?,
	novaOrbSpeed: number?,
	novaDamage: number?,
	canRush: boolean?,
	rushMinRange: number?,
	rushMaxRange: number?,
	rushWindup: number?,
	rushDuration: number?,
	rushSpeed: number?,
	rushCooldown: number?,
	rushRecover: number?,
	rushDamage: number?,
	rushHitRadius: number?,
	rushHitHeight: number?,
	rushKnockbackSpeed: number?,
	rushKnockbackSeconds: number?,
	rushKnockbackUp: number?,
	rushStunDuration: number?,
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
	-- area (Artillero: ground hazard mortar zones)
	areaMaxRange: number?,
	areaWindup: number?,
	areaTelegraph: number?,
	areaDuration: number?,
	areaTickEvery: number?,
	areaRadius: number?,
	areaHeight: number?,
	areaImpactDamage: number?,
	areaTickDamage: number?,
	areaCooldown: number?,
	-- contact (Voltaico: electrified contact surge aura)
	contactTriggerRange: number?,
	contactWindup: number?,
	contactDuration: number?,
	contactRadius: number?,
	contactHeight: number?,
	contactTickEvery: number?,
	contactDamage: number?,
	contactCooldown: number?,
	contactSpeedFactor: number?,
	passiveContactRadius: number?,
	passiveContactDamage: number?,
	passiveContactTickEvery: number?,
	-- Boss My agile photonic attacks (`HS-16`)
	myDashCount: number?,
	myDashWindup: number?,
	myDashDuration: number?,
	myDashSpeed: number?,
	myDashDamage: number?,
	myDashRadius: number?,
	myDashCooldown: number?,
	mySweepWindup: number?,
	mySweepDuration: number?,
	mySweepRange: number?,
	mySweepArc: number?,
	mySweepHeight: number?,
	mySweepDamage: number?,
	mySweepCooldown: number?,
	myBladesWindup: number?,
	myBladesCount: number?,
	myBladesSpreadDeg: number?,
	myBladeSpeed: number?,
	myBladeDamage: number?,
	myBladesCooldown: number?,
	-- Boss Gon containment & gravity attacks (`HS-18`)
	gonRainWindup: number?,
	gonRainCount: number?,
	gonRainRadius: number?,
	gonRainTelegraph: number?,
	gonRainDuration: number?,
	gonRainImpactDamage: number?,
	gonRainTickDamage: number?,
	gonRainCooldown: number?,
	gonGravityWindup: number?,
	gonGravityDuration: number?,
	gonGravityPullRadius: number?,
	gonGravityCoreRadius: number?,
	gonGravityDamage: number?,
	gonGravityCooldown: number?,
	gonRingsWindup: number?,
	gonRingsCount: number?,
	gonRingMaxRadius: number?,
	gonRingDuration: number?,
	gonRingHeight: number?,
	gonRingDamage: number?,
	gonRingsCooldown: number?,
	-- Boss OhMyGon 2-phase fusion threshold (`HS-20`)
	phase2Threshold: number?,
	phase2Duration: number?,
}

-- Health ladder, starting values to tune by playing. Against the basic combo (40 damage in about
-- 0.9 s) the roles read as: fragile threats die to one or two hits (exploder 15, ranged 22-34),
-- the melee line takes a combo or so and grows with its weapon (30 sword up to 50 mace), and the
-- grabber is the wall of the wave at 100 — it holds a teammate hostage, so killing it has to be
-- a decision the group commits to, not a stray swing. Variants override `health` per weapon.
Config.ENEMY_KINDS = {
	-- Telegraphs every swing with a windup, so a dash during it always works. Spawns across
	-- four rigged `.rbxmx` weapon variants: single-sword units can trigger a Sandevistan 3-dash
	-- ambush, and dual-blade units unleash a high-DPS spin attack.
	melee = {
		displayName = "Centinela",
		model = "EnemyMelee",
		variants = {
			{
				model = "EnemyMelee",
				weapon = "sword",
				canPhantomStep = true,
				phantomStepCount = 3,
				phantomStepDuration = 0.15,
				phantomStepRange = 24,
				phantomStepCooldown = 7.0,
				phantomStepStrikeWindup = 0.38,
				phantomStepDamage = 15,
			},
			{
				model = "EnemyMeleeDual",
				weapon = "dual",
				health = 36,
				canSpin = true,
				spinDuration = 1.6,
				spinTickEvery = 0.25,
				spinTickDamage = 6,
				spinRadius = 8.0,
				spinCooldown = 6.5,
				spinMoveFactor = 0.65,
			},
			{
				model = "EnemyMeleeAxe",
				weapon = "axe",
				health = 42,
				canAxeThrow = true,
				axeThrowMinRange = 13,
				axeThrowMaxRange = 42,
				axeThrowWindup = 0.65,
				axeThrowSpeed = 54,
				axeThrowDamage = 18,
				axeThrowCooldown = 6.5,
				axeThrowMaxDistance = 40,
				axePickupRadius = 4.2,
				axeRetrieveSpeedFactor = 1.28,
			},
			{
				model = "EnemyMeleeMace",
				weapon = "mace",
				health = 50,
				canSlam = true,
				slamRange = 13,
				slamRadius = 15.5,
				slamHeight = 4.2,
				slamWindup = 0.78,
				slamCooldown = 6.5,
				slamDamage = 14,
				slamStunDuration = 1.6,
			},
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
		displayName = "Cazador",
		model = "EnemyRanged",
		variants = {
			{
				model = "EnemyRanged",
				weapon = "rifle",
				health = 22,
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
				health = 26,
				weight = 3,
				burstCount = 1,
				pelletCount = 4,
				pelletSpreadDeg = 36,
				fireEvery = 2.0,
				projectileStyle = "tracer",
				projectileSpeed = 62,
				projectileDamage = 7,
				canParry = true,
			},
			{
				model = "EnemyRangedCarbine",
				weapon = "plasma",
				health = 26,
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
				health = 34,
				weight = 2,
				burstCount = 6,
				burstInterval = 0.11,
				burstSpreadDeg = 5,
				fireEvery = 2.4,
				projectileStyle = "tracer",
				projectileSpeed = 72,
				projectileDamage = 3.5,
				canParry = false,
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
		displayName = "Detonante",
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
		displayName = "Coloso",
		model = "EnemyGrabber",
		health = 100,
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
		-- Rush (embestida): from beyond grab reach it lowers its shoulder (telegraphed) and
		-- bull-charges in a straight line locked at launch, so a sideways dash dodges it. Anyone it
		-- runs into is hurt, flung back about 17 studs and stunned. It is the grabber's answer to a
		-- player who keeps out of grab reach. Blocking halves the fling and the stun; parry does
		-- not apply (it is a body slam, not a weapon).
		canRush = true,
		rushMinRange = 16,
		rushMaxRange = 34,
		rushWindup = 0.7,
		rushDuration = 0.6,
		rushSpeed = 58,
		rushCooldown = 6.5,
		rushRecover = 1.1,
		rushDamage = 12,
		rushHitRadius = 5.2,
		rushHitHeight = 5,
		rushKnockbackSpeed = 55,
		rushKnockbackSeconds = 0.32,
		rushKnockbackUp = 28,
		rushStunDuration = 1.3,
	},
	-- Area-denial artillery unit ("Artillero"): holds mid-range and lobs arcing mortar rounds
	-- that telegraph circular ground zones (1.05 s warning) before detonating into 3.5 s plasma
	-- hazard pools. Jumpable / dashable, and respects grab-exclusion over held players.
	area = {
		displayName = "Artillero",
		model = "EnemyArea",
		health = 28,
		speed = 11,
		size = Vector3.new(3.6, 5.2, 3.6),
		color = Color3.fromRGB(150, 235, 65),
		keepAway = 30,
		areaMaxRange = 48,
		areaWindup = 0.65,
		areaTelegraph = 1.05,
		areaDuration = 3.5,
		areaTickEvery = 0.5,
		areaRadius = 11,
		areaHeight = 3.6,
		areaImpactDamage = 14,
		areaTickDamage = 10,
		areaCooldown = 4.2,
		recover = 0.75,
		damage = 10,
	},
	-- High-voltage contact hazard unit ("Voltaico"): fast spiral chaser with twin Tesla coils
	-- that overcharges a vivid 5.5-stud electric aura dealing automatic contact damage every 0.6 s.
	-- Rewards melee sweet-spot spacing, skills, range, or Dash i-frames instead of hugging it.
	contact = {
		displayName = "Voltaico",
		model = "EnemyContact",
		health = 34,
		speed = 17.5,
		size = Vector3.new(3.8, 4.8, 3.8),
		color = Color3.fromRGB(60, 235, 255),
		contactTriggerRange = 18,
		contactWindup = 0.55,
		contactDuration = 2.8,
		contactRadius = 5.5,
		contactHeight = 4.6,
		contactTickEvery = 0.6,
		contactDamage = 10,
		contactCooldown = 3.2,
		contactSpeedFactor = 1.18,
		passiveContactRadius = 2.9,
		passiveContactDamage = 5,
		passiveContactTickEvery = 0.75,
		recover = 0.65,
		damage = 10,
	},
	-- Boss "Oh" (Oleada 6 — first part of OhMyGon): colossal heavy mechanical titan with three
	-- telegraphed signature attacks: frontal cone smash, seismic meteor leap, and 360-deg plasma nova.
	bossOh = {
		displayName = "Oh",
		bossTitle = "OH — TITÁN DEL SECTOR",
		isBoss = true,
		model = "BossOh",
		health = 650,
		speed = 13.5,
		size = Vector3.new(6.8, 11.0, 6.2),
		color = Color3.fromRGB(165, 42, 48),
		reach = 18,
		recover = 1.25,
		damage = 26,
		coneRange = 24,
		coneArc = 115,
		coneWindup = 0.85,
		coneDamage = 26,
		coneStunDuration = 0.9,
		leapMinRange = 16,
		leapMaxRange = 55,
		leapWindup = 0.65,
		leapDuration = 0.72,
		leapArcHeight = 16,
		leapRadius = 18,
		leapHeight = 5.0,
		leapDamage = 32,
		leapStunDuration = 1.2,
		leapCooldown = 7.5,
		novaWindup = 1.0,
		novaCooldown = 9.0,
		novaWaves = 2,
		novaOrbCount = 10,
		novaOrbSpeed = 34,
		novaDamage = 18,
	},
	-- Boss "My" (Floor 3 Room 5 — second part of OhMyGon, `HS-16`): agile high-speed photonic
	-- assassin chaining lightning dashes, 140-deg sweeping laser beams, and parriable cross blades.
	bossMy = {
		displayName = "My",
		bossTitle = "MY — FILO DEL SECTOR",
		isBoss = true,
		model = "BossMy",
		health = 700,
		speed = 18,
		size = Vector3.new(5.0, 9.0, 4.8),
		color = Color3.fromRGB(162, 74, 245),
		reach = 14,
		recover = 0.95,
		damage = 20,
		myDashCount = 3,
		myDashWindup = 0.65,
		myDashDuration = 0.24,
		myDashSpeed = 82,
		myDashDamage = 20,
		myDashRadius = 5.4,
		myDashCooldown = 5.2,
		mySweepWindup = 0.85,
		mySweepDuration = 1.15,
		mySweepRange = 42,
		mySweepArc = 140,
		mySweepHeight = 3.5,
		mySweepDamage = 18,
		mySweepCooldown = 7.5,
		myBladesWindup = 0.55,
		myBladesCount = 4,
		myBladesSpreadDeg = 54,
		myBladeSpeed = 56,
		myBladeDamage = 16,
		myBladesCooldown = 4.6,
	},
	-- Boss "Gon" (Floor 4 Room 5 — third part of OhMyGon, `HS-18`): area-denial containment
	-- colossus commanding mortar grids, pulling gravity wells, and jumpable dual seismic rings.
	bossGon = {
		displayName = "Gon",
		bossTitle = "GON — NÚCLEO DE CONTENCIÓN",
		isBoss = true,
		model = "BossGon",
		health = 780,
		speed = 12,
		size = Vector3.new(6.6, 10.2, 6.2),
		color = Color3.fromRGB(64, 228, 128),
		reach = 16,
		recover = 1.15,
		damage = 22,
		gonRainWindup = 0.7,
		gonRainCount = 4,
		gonRainRadius = 10,
		gonRainTelegraph = 1.1,
		gonRainDuration = 4.0,
		gonRainImpactDamage = 18,
		gonRainTickDamage = 10,
		gonRainCooldown = 6.8,
		gonGravityWindup = 0.9,
		gonGravityDuration = 2.0,
		gonGravityPullRadius = 24,
		gonGravityCoreRadius = 12,
		gonGravityDamage = 28,
		gonGravityCooldown = 8.5,
		gonRingsWindup = 0.7,
		gonRingsCount = 2,
		gonRingMaxRadius = 46,
		gonRingDuration = 1.25,
		gonRingHeight = 3.2,
		gonRingDamage = 20,
		gonRingsCooldown = 6.2,
	},
	-- Final Boss "OhMyGon" (Floor 5 Room 5 — fused 2-phase encounter, `HS-20`):
	-- Phase 1 recombines learned Oh/My/Gon attacks; Phase 2 (<50% HP) accelerates cadence by 25%
	-- and escalates ring/dash/zone counts without introducing untaught mechanics.
	bossOhMyGon = {
		displayName = "OhMyGon",
		bossTitle = "OHMYGON — FUSIÓN DEL COMPLEJO",
		isBoss = true,
		model = "BossOhMyGon",
		health = 1100,
		speed = 15,
		size = Vector3.new(7.4, 12.2, 6.8),
		color = Color3.fromRGB(220, 48, 68),
		reach = 18,
		recover = 1.1,
		damage = 26,
		phase2Threshold = 0.5,
		phase2Duration = 1.5,
		-- Oh attacks
		coneRange = 25,
		coneArc = 115,
		coneWindup = 0.8,
		coneDamage = 26,
		coneStunDuration = 0.9,
		leapMinRange = 18,
		leapMaxRange = 56,
		leapWindup = 0.62,
		leapDuration = 0.7,
		leapArcHeight = 16,
		leapRadius = 18,
		leapHeight = 5.0,
		leapDamage = 32,
		leapStunDuration = 1.1,
		leapCooldown = 9.0,
		novaWindup = 0.95,
		novaCooldown = 11.5,
		novaWaves = 2,
		novaOrbCount = 10,
		novaOrbSpeed = 36,
		novaDamage = 18,
		-- My attacks
		myDashCount = 3,
		myDashWindup = 0.62,
		myDashDuration = 0.23,
		myDashSpeed = 84,
		myDashDamage = 22,
		myDashRadius = 5.8,
		myDashCooldown = 8.0,
		mySweepWindup = 0.8,
		mySweepDuration = 1.1,
		mySweepRange = 44,
		mySweepArc = 140,
		mySweepHeight = 3.5,
		mySweepDamage = 20,
		mySweepCooldown = 10.5,
		myBladesWindup = 0.52,
		myBladesCount = 4,
		myBladesSpreadDeg = 54,
		myBladeSpeed = 58,
		myBladeDamage = 18,
		myBladesCooldown = 7.5,
		-- Gon attacks
		gonRainWindup = 0.65,
		gonRainCount = 4,
		gonRainRadius = 10,
		gonRainTelegraph = 1.05,
		gonRainDuration = 3.8,
		gonRainImpactDamage = 18,
		gonRainTickDamage = 10,
		gonRainCooldown = 9.5,
		gonGravityWindup = 0.85,
		gonGravityDuration = 1.9,
		gonGravityPullRadius = 24,
		gonGravityCoreRadius = 12,
		gonGravityDamage = 28,
		gonGravityCooldown = 11.0,
		gonRingsWindup = 0.68,
		gonRingsCount = 2,
		gonRingMaxRadius = 46,
		gonRingDuration = 1.2,
		gonRingHeight = 3.2,
		gonRingDamage = 22,
		gonRingsCooldown = 8.8,
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

-- One table per wave: kind -> count. Grabber enters starting on wave 4; Wave 6 is the first
-- boss encounter ("Oh"). Counts of non-boss kinds are scaled by the chosen difficulty.
Config.WAVES = {
	{ melee = 3 },
	{ melee = 3, ranged = 2 },
	{ melee = 2, ranged = 2, exploder = 1, area = 1 },
	{ melee = 3, ranged = 2, exploder = 1, contact = 1, grabber = 1 },
	{ melee = 3, ranged = 2, exploder = 1, area = 2, contact = 2, grabber = 1 },
	{ bossOh = 1 },
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

-- DMC-style hitstun & progressive stagger suppression: every player hit flinches the enemy,
-- interrupts active windups, pushes back its next attack/evade, and stacks a lingering daze
-- slowdown so sustained combos lock targets down without launching them out of melee reach.
Config.ENEMY_HITSTUN_LIGHT = 0.62
Config.ENEMY_HITSTUN_MEDIUM = 0.82
Config.ENEMY_HITSTUN_HEAVY = 1.05
Config.ENEMY_HITSTUN_STACK_BONUS = 0.10
Config.ENEMY_HITSTUN_MAX_STACKS = 4
Config.ENEMY_HIT_ACTION_DELAY = 0.35
Config.ENEMY_DAZE_SECONDS = 1.8
Config.ENEMY_DAZE_SPEED_FACTORS = { 0.60, 0.40, 0.25, 0.15 }
Config.ENEMY_KNOCKBACK_LIGHT = 1.1
Config.ENEMY_KNOCKBACK_MEDIUM = 1.7
Config.ENEMY_KNOCKBACK_HEAVY = 2.4
Config.ENEMY_KNOCKBACK_DURATION = 0.12
-- Dampens crowd separation while an enemy is in hitstun so nearby enemies never shove your
-- combo target sideways out of the sweet spot.
Config.ENEMY_HITSTUN_SEPARATION_SCALE = 0.15

return Config
