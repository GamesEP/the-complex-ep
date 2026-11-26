-- Procedural player animations for the combat slice: 3-hit combo attack, jump/land, dash and
-- 360-degree spin. Driven through `Motor6D.Transform` / `AnimationConstraint.Transform` on
-- `RunService.Stepped`, so they work on any R15 rig (including unpublished local Studio places)
-- without external AnimationId ownership restrictions. See docs/combat.md.
local Config = {}

export type AnimSpec = {
	duration: number,
	priority: number,
	blendIn: number,
	blendOut: number,
}

Config.ANIMATIONS = {
	-- Light combo swings (steps 1 and 2): fast upper-body slash while legs keep running.
	attack = {
		duration = 0.24,
		priority = 2,
		blendIn = 0.16,
		blendOut = 0.34,
	},
	-- Heavy 3rd combo hit: longer windup and downward cleave follow-through.
	attackHeavy = {
		duration = 0.36,
		priority = 2,
		blendIn = 0.18,
		blendOut = 0.35,
	},
	-- Evasive dash: tuned slightly longer than Config.DASH_DURATION (0.18s) so the lean settles smoothly.
	dash = {
		duration = 0.23,
		priority = 3,
		blendIn = 0.15,
		blendOut = 0.32,
	},
	-- Full 360-degree tornado spin slash.
	spin = {
		duration = 0.42,
		priority = 4,
		blendIn = 0.12,
		blendOut = 0.28,
	},
	-- DMC-style Stinger: explosive forward lance thrust with sword extended straight ahead.
	stinger = {
		duration = 0.36,
		priority = 4,
		blendIn = 0.08,
		blendOut = 0.3,
	},
	-- DMC-style Over Drive: rapid 3-slash ranged shockwave barrage (steps 1..3).
	overdriveWave = {
		duration = 0.24,
		priority = 4,
		blendIn = 0.08,
		blendOut = 0.28,
	},
	-- Charged 3-second heavy attack: massive full-body lunge and crushing cleave.
	heavyAttack = {
		duration = 0.52,
		priority = 4,
		blendIn = 0.1,
		blendOut = 0.34,
	},
	-- Crisp outward sword deflect when a Parry lands.
	parry = {
		duration = 0.26,
		priority = 4,
		blendIn = 0.1,
		blendOut = 0.35,
	},
	-- Short athletic landing squash when touching down from a jump.
	land = {
		duration = 0.16,
		priority = 1,
		blendIn = 0.2,
		blendOut = 0.55,
	},
} :: { [string]: AnimSpec }

-- Continuous defensive guard pose weight while holding Block.
Config.ANIM_BLOCK_WEIGHT = 0.9
-- Continuous charged heavy windup pose weight while holding Attack to charge.
Config.ANIM_CHARGE_WEIGHT = 0.92
-- Continuous Over Drive energy-channeling stance weight before unleashing the 3 waves.
Config.ANIM_OVERDRIVE_CHARGE_WEIGHT = 0.95

-- Airborne jump pose blending (driven from HumanoidStateType + root vertical velocity).
Config.ANIM_JUMP_WEIGHT = 0.85
Config.ANIM_JUMP_RISE_VELOCITY = 6
Config.ANIM_JUMP_FALL_VELOCITY = -18
-- Full turns completed during a single spin animation (1 = 360 degrees).
Config.ANIM_SPIN_TURNS = 1

-- Procedural client-side animations for rigged `.rbxmx` enemies (walking, attacks, fire recoil, death).
Config.ENEMY_WALK_CYCLE_HZ = 1.65
Config.ENEMY_STRIKE_ANIM_SECONDS = 0.34
Config.ENEMY_FIRE_ANIM_SECONDS = 0.24
Config.ENEMY_DEATH_ANIM_SECONDS = 0.65

return Config
