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
	-- Short athletic landing squash when touching down from a jump.
	land = {
		duration = 0.16,
		priority = 1,
		blendIn = 0.2,
		blendOut = 0.55,
	},
} :: { [string]: AnimSpec }

-- Airborne jump pose blending (driven from HumanoidStateType + root vertical velocity).
Config.ANIM_JUMP_WEIGHT = 0.85
Config.ANIM_JUMP_RISE_VELOCITY = 6
Config.ANIM_JUMP_FALL_VELOCITY = -18
-- Full turns completed during a single spin animation (1 = 360 degrees).
Config.ANIM_SPIN_TURNS = 1

return Config
