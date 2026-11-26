-- Procedural player animations for the combat slice: 3-hit combo attack, jump/land, dash and
-- 360-degree spin. Driven through `Motor6D.Transform` / `AnimationConstraint.Transform` on
-- `RunService.Stepped`, so they work on any R15 rig (including unpublished local Studio places)
-- without external AnimationId ownership restrictions. See docs/combat.md.
local Config = {}

export type AnimSpec = {
	duration: number,
	-- Seconds elapsed when the active swing ends and the stylish follow-through recovery begins.
	-- Any other attack or ability can cancel the animation once elapsed >= cancelAt (DMC feel).
	cancelAt: number,
	priority: number,
	blendIn: number,
	blendOut: number,
}

Config.ANIMATIONS = {
	-- Light combo swings (steps 1 and 2): deliberate windup + crisp slash + follow-through recovery.
	attack = {
		duration = 0.58,
		cancelAt = 0.36,
		priority = 2,
		blendIn = 0.10,
		blendOut = 0.36,
	},
	-- Heavy 3rd combo hit: overhead windup, heavy downward cleave, and grounded follow-through.
	attackHeavy = {
		duration = 0.82,
		cancelAt = 0.50,
		priority = 2,
		blendIn = 0.12,
		blendOut = 0.36,
	},
	-- Evasive dash: stays snappy while giving a clean settle tail cancelable into attacks/skills.
	dash = {
		duration = 0.32,
		cancelAt = 0.22,
		priority = 3,
		blendIn = 0.12,
		blendOut = 0.34,
	},
	-- Full 360-degree tornado spin slash with recovery settle cancelable into any combo or skill.
	spin = {
		duration = 0.78,
		cancelAt = 0.46,
		priority = 4,
		blendIn = 0.10,
		blendOut = 0.34,
	},
	-- DMC-style Stinger: explosive forward lance thrust holding a low recovery stance until cancelled.
	stinger = {
		duration = 0.72,
		cancelAt = 0.40,
		priority = 4,
		blendIn = 0.08,
		blendOut = 0.36,
	},
	-- DMC-style Over Drive: deliberate 3-slash ranged shockwave barrage (steps 1..3).
	overdriveWave = {
		duration = 0.52,
		cancelAt = 0.30,
		priority = 4,
		blendIn = 0.08,
		blendOut = 0.34,
	},
	-- Charged heavy attack: massive full-body lunge, crushing cleave, and recovery.
	heavyAttack = {
		duration = 0.94,
		cancelAt = 0.56,
		priority = 4,
		blendIn = 0.09,
		blendOut = 0.36,
	},
	-- Crisp outward sword deflect when a Parry lands, cancelable into a counter-combo.
	parry = {
		duration = 0.42,
		cancelAt = 0.22,
		priority = 4,
		blendIn = 0.08,
		blendOut = 0.36,
	},
	-- Short athletic landing squash when touching down from a jump.
	land = {
		duration = 0.22,
		cancelAt = 0.0,
		priority = 1,
		blendIn = 0.18,
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
Config.ENEMY_FIRE_ANIM_SECONDS = 0.36
Config.ENEMY_DEATH_ANIM_SECONDS = 0.65

return Config
