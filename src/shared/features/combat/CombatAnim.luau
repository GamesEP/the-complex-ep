--!strict
--[[
	Pure procedural animation poses and blending rules for the player's kit: 3-hit combo attack,
	dash, 360-degree spin, and jump/landing.

	Every pose returns target CFrame transforms keyed by standard R15 joint name (`Root`, `Waist`,
	`RightShoulder`, `RightElbow`, `LeftShoulder`, `LeftElbow`, `RightHip`, `RightKnee`, `LeftHip`,
	`LeftKnee`, `Neck`) plus an envelope weight in [0, 1]. `PlayerAnimator` applies them on
	`RunService.Stepped` over `AnimationConstraint.Transform` / `Motor6D.Transform`.

	Pure so `make test` asserts priority rules, combo variation, spin rotation and jump curves
	without needing Studio. See docs/combat.md.
]]

local Config = require(script.Parent.Parent.Parent.core.Config)

local CombatAnim = {}

export type Pose = {
	active: boolean,
	weight: number,
	joints: { [string]: CFrame },
}

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function easeOutCubic(t: number): number
	local inv = 1 - clamp01(t)
	return 1 - inv * inv * inv
end

local function easeInOutQuad(t: number): number
	local u = clamp01(t)
	if u < 0.5 then
		return 2 * u * u
	end
	local inv = -2 * u + 2
	return 1 - (inv * inv) / 2
end

local function lerpNumber(a: number, b: number, t: number): number
	return a + (b - a) * clamp01(t)
end

local function envelope(u: number, blendIn: number, blendOut: number): number
	if u <= 0 or u >= 1 then
		return 0
	end
	local w = 1
	if blendIn > 0 and u < blendIn then
		w = math.min(w, easeOutCubic(u / blendIn))
	end
	if blendOut > 0 and u > 1 - blendOut then
		w = math.min(w, easeOutCubic((1 - u) / blendOut))
	end
	return clamp01(w)
end

-- Maps an action name + combo step to its entry in `Config.ANIMATIONS`.
function CombatAnim.specKey(action: string, step: number?): string
	if action == "attack" and (step or 1) >= Config.COMBO_HITS then
		return "attackHeavy"
	end
	return action
end

-- Higher priority actions interrupt lower ones; equal priority interrupts itself (e.g. combo
-- chaining attack 1 -> attack 2 -> attack 3).
function CombatAnim.canInterrupt(currentKey: string?, nextKey: string): boolean
	if not currentKey then
		return true
	end
	local currentSpec = Config.ANIMATIONS[currentKey]
	local nextSpec = Config.ANIMATIONS[nextKey]
	if not nextSpec then
		return false
	end
	if not currentSpec then
		return true
	end
	return nextSpec.priority >= currentSpec.priority
end

-- Two-phase swing curve: snappy windup (0..split) then explosive follow-through (split..1).
local function swingPhase(u: number, split: number): number
	if u < split then
		return -easeInOutQuad(u / split)
	end
	return easeOutCubic((u - split) / (1 - split))
end

local function evaluateAttack(step: number, u: number): { [string]: CFrame }
	if step >= Config.COMBO_HITS then
		-- Step 3 (heavy finisher): overhead windup -> violent downward cleave.
		local split = 0.28
		local waistPitch: number
		local waistYaw: number
		local rootDrop: number
		local rShoulderX: number
		local rShoulderZ: number
		local rElbowX: number
		local lShoulderX: number
		local lShoulderZ: number
		if u < split then
			local p = easeInOutQuad(u / split)
			waistPitch = lerpNumber(0, 0.28, p)
			waistYaw = lerpNumber(0, -0.25, p)
			rootDrop = lerpNumber(0, 0.12, p)
			rShoulderX = lerpNumber(0.4, 2.45, p)
			rShoulderZ = lerpNumber(0.2, 0.35, p)
			rElbowX = lerpNumber(0.3, 0.55, p)
			lShoulderX = lerpNumber(0.2, 1.95, p)
			lShoulderZ = lerpNumber(-0.15, -0.3, p)
		else
			local p = easeOutCubic((u - split) / (1 - split))
			waistPitch = lerpNumber(0.28, -0.45, p)
			waistYaw = lerpNumber(-0.25, 0.35, p)
			rootDrop = lerpNumber(0.12, -0.22, p)
			rShoulderX = lerpNumber(2.45, 0.15, p)
			rShoulderZ = lerpNumber(0.35, -0.25, p)
			rElbowX = lerpNumber(0.55, 0.25, p)
			lShoulderX = lerpNumber(1.95, -0.45, p)
			lShoulderZ = lerpNumber(-0.3, -0.55, p)
		end
		return {
			Root = CFrame.new(0, rootDrop, 0) * CFrame.Angles(waistPitch * 0.35, 0, 0),
			Waist = CFrame.Angles(waistPitch, waistYaw, 0),
			Neck = CFrame.Angles(-waistPitch * 0.4, -waistYaw * 0.4, 0),
			RightShoulder = CFrame.Angles(rShoulderX, 0, rShoulderZ),
			RightElbow = CFrame.Angles(rElbowX, 0, 0),
			LeftShoulder = CFrame.Angles(lShoulderX, 0, lShoulderZ),
			LeftElbow = CFrame.Angles(0.45, 0, 0),
		}
	end

	-- Steps 1 and 2 alternate right-to-left and backhand left-to-right horizontal cleaves.
	local dir = if step % 2 == 1 then 1 else -1
	local s = swingPhase(u, 0.22)
	local waistYaw = dir * lerpNumber(-0.65, 0.8, (s + 1) * 0.5)
	local waistPitch = -0.14 - 0.12 * math.max(s, 0)
	local armSweepY = dir * lerpNumber(-0.85, 1.15, (s + 1) * 0.5)
	local rShoulderX = 1.15 + 0.25 * math.max(s, 0)
	local rShoulderZ = if dir > 0 then lerpNumber(1.25, -0.45, (s + 1) * 0.5) else lerpNumber(-0.45, 1.35, (s + 1) * 0.5)
	local lShoulderX = -0.35 * dir * s
	local lShoulderZ = -0.55 - 0.25 * math.abs(s)

	return {
		Waist = CFrame.Angles(waistPitch, waistYaw, -dir * 0.12 * s),
		Neck = CFrame.Angles(-waistPitch * 0.5, -waistYaw * 0.55, 0),
		RightShoulder = CFrame.Angles(rShoulderX, armSweepY, rShoulderZ),
		RightElbow = CFrame.Angles(0.55 + 0.25 * (1 - math.abs(s)), 0, 0),
		LeftShoulder = CFrame.Angles(lShoulderX, -armSweepY * 0.3, lShoulderZ),
		LeftElbow = CFrame.Angles(0.65, 0, 0),
	}
end

local function evaluateDash(u: number): { [string]: CFrame }
	local burst = easeOutCubic(math.min(u / 0.35, 1))
	local lean = -0.58 * burst
	return {
		Root = CFrame.new(0, -0.35 * burst, 0) * CFrame.Angles(lean, 0, 0),
		Waist = CFrame.Angles(-0.22 * burst, 0.28 * burst, 0),
		Neck = CFrame.Angles(0.52 * burst, -0.22 * burst, 0),
		RightShoulder = CFrame.Angles(-0.95 * burst, 0, 0.45 * burst),
		RightElbow = CFrame.Angles(0.55 * burst, 0, 0),
		LeftShoulder = CFrame.Angles(-0.8 * burst, 0, -0.5 * burst),
		LeftElbow = CFrame.Angles(0.65 * burst, 0, 0),
		RightHip = CFrame.Angles(0.75 * burst, 0, 0),
		RightKnee = CFrame.Angles(-0.95 * burst, 0, 0),
		LeftHip = CFrame.Angles(-0.85 * burst, 0, 0),
		LeftKnee = CFrame.Angles(-0.45 * burst, 0, 0),
	}
end

local function evaluateSpin(u: number): { [string]: CFrame }
	-- Full 360-degree tornado rotation with explosive ease-out so the blade sweeps immediately.
	local angle = -math.pi * 2 * Config.ANIM_SPIN_TURNS * easeOutCubic(u)
	local crouch = -0.28
	return {
		Root = CFrame.new(0, crouch, 0) * CFrame.Angles(-0.18, angle, 0),
		Waist = CFrame.Angles(-0.12, -0.35, 0),
		Neck = CFrame.Angles(0.18, 0.25, 0),
		RightShoulder = CFrame.Angles(0.25, 0, 1.48),
		RightElbow = CFrame.Angles(0.22, 0, 0),
		LeftShoulder = CFrame.Angles(-0.2, 0, -1.25),
		LeftElbow = CFrame.Angles(0.55, 0, 0),
		RightHip = CFrame.Angles(0.35, 0, 0.12),
		RightKnee = CFrame.Angles(-0.65, 0, 0),
		LeftHip = CFrame.Angles(0.2, 0, -0.12),
		LeftKnee = CFrame.Angles(-0.55, 0, 0),
	}
end

local function evaluateLand(u: number): { [string]: CFrame }
	-- Quick athletic knee-bend squash on touchdown, then spring back up.
	local squash = math.sin(math.pi * clamp01(u))
	return {
		Root = CFrame.new(0, -0.4 * squash, 0) * CFrame.Angles(-0.16 * squash, 0, 0),
		Waist = CFrame.Angles(-0.2 * squash, 0, 0),
		Neck = CFrame.Angles(0.22 * squash, 0, 0),
		RightShoulder = CFrame.Angles(0.25 * squash, 0, 0.45 * squash),
		RightElbow = CFrame.Angles(0.45 * squash, 0, 0),
		LeftShoulder = CFrame.Angles(0.25 * squash, 0, -0.45 * squash),
		LeftElbow = CFrame.Angles(0.45 * squash, 0, 0),
		RightHip = CFrame.Angles(0.65 * squash, 0, 0),
		RightKnee = CFrame.Angles(-1.15 * squash, 0, 0),
		LeftHip = CFrame.Angles(0.65 * squash, 0, 0),
		LeftKnee = CFrame.Angles(-1.15 * squash, 0, 0),
	}
end

local function evaluateParry(u: number): { [string]: CFrame }
	-- Crisp outward deflect sweep with the sword + firm stance.
	local snap = easeOutCubic(math.min(u / 0.45, 1))
	return {
		Waist = CFrame.Angles(-0.14 * snap, 0.55 * snap, 0),
		Neck = CFrame.Angles(0.1 * snap, -0.4 * snap, 0),
		RightShoulder = CFrame.Angles(1.45 * snap, 0.65 * snap, 0.85 * snap),
		RightElbow = CFrame.Angles(0.35 * snap, 0, 0),
		LeftShoulder = CFrame.Angles(-0.35 * snap, 0, -0.75 * snap),
		LeftElbow = CFrame.Angles(0.65 * snap, 0, 0),
	}
end

local function evaluateHeavyAttack(u: number): { [string]: CFrame }
	-- Coiled overhead-right windup (0..0.22) erupting into a massive full-body diagonal slam
	-- cleave across the entire front arc (0.22..1.0).
	local split = 0.22
	if u < split then
		local p = easeInOutQuad(u / split)
		return {
			Root = CFrame.new(0, lerpNumber(-0.12, 0.16, p), 0) * CFrame.Angles(lerpNumber(0.05, 0.34, p), lerpNumber(-0.3, -0.55, p), 0),
			Waist = CFrame.Angles(lerpNumber(0.12, 0.36, p), lerpNumber(-0.45, -0.75, p), 0),
			Neck = CFrame.Angles(-0.18, 0.55, 0),
			RightShoulder = CFrame.Angles(lerpNumber(2.15, 2.75, p), -0.35, lerpNumber(0.45, 0.72, p)),
			RightElbow = CFrame.Angles(0.65, 0, 0),
			LeftShoulder = CFrame.Angles(lerpNumber(1.65, 2.25, p), 0.25, -0.45),
			LeftElbow = CFrame.Angles(0.55, 0, 0),
		}
	end
	local p = easeOutCubic((u - split) / (1 - split))
	return {
		Root = CFrame.new(0, lerpNumber(0.16, -0.42, p), 0) * CFrame.Angles(lerpNumber(0.34, -0.42, p), lerpNumber(-0.55, 0.65, p), 0),
		Waist = CFrame.Angles(lerpNumber(0.36, -0.52, p), lerpNumber(-0.75, 0.95, p), lerpNumber(0, -0.18, p)),
		Neck = CFrame.Angles(lerpNumber(-0.18, 0.38, p), lerpNumber(0.55, -0.65, p), 0),
		RightShoulder = CFrame.Angles(lerpNumber(2.75, 0.28, p), lerpNumber(-0.35, 1.05, p), lerpNumber(0.72, -0.65, p)),
		RightElbow = CFrame.Angles(lerpNumber(0.65, 0.22, p), 0, 0),
		LeftShoulder = CFrame.Angles(lerpNumber(2.25, -0.65, p), lerpNumber(0.25, -0.45, p), lerpNumber(-0.45, -0.75, p)),
		LeftElbow = CFrame.Angles(0.45, 0, 0),
		RightHip = CFrame.Angles(0.45 * p, 0, 0),
		RightKnee = CFrame.Angles(-0.75 * p, 0, 0),
		LeftHip = CFrame.Angles(-0.35 * p, 0, 0),
		LeftKnee = CFrame.Angles(-0.55 * p, 0, 0),
	}
end

-- Iconic DMC Stinger pose: deep forward thrust lunge with torso twisted right-shoulder-forward,
-- sword arm driven straight ahead like a lance, and left arm swept behind for balance.
local function evaluateStinger(u: number): { [string]: CFrame }
	local burst = easeOutCubic(math.min(u / 0.22, 1))
	local settle = if u > 0.72 then (u - 0.72) / 0.28 else 0
	local thrust = burst * (1 - 0.35 * settle)
	return {
		Root = CFrame.new(0, -0.48 * thrust, 0) * CFrame.Angles(-0.52 * thrust, 0.42 * thrust, 0),
		Waist = CFrame.Angles(-0.26 * thrust, 0.48 * thrust, 0),
		Neck = CFrame.Angles(0.55 * thrust, -0.75 * thrust, 0),
		RightShoulder = CFrame.Angles(1.62 * thrust, -0.22 * thrust, 0.08 * thrust),
		RightElbow = CFrame.Angles(0.08 * thrust, 0, 0),
		LeftShoulder = CFrame.Angles(-1.15 * thrust, 0.25 * thrust, -0.75 * thrust),
		LeftElbow = CFrame.Angles(0.35 * thrust, 0, 0),
		RightHip = CFrame.Angles(1.05 * thrust, 0, 0),
		RightKnee = CFrame.Angles(-1.15 * thrust, 0, 0),
		LeftHip = CFrame.Angles(-1.05 * thrust, 0, 0),
		LeftKnee = CFrame.Angles(-0.28 * thrust, 0, 0),
	}
end

-- DMC Over Drive 3-wave ranged slash cadence: alternating wide crescent arcs (steps 1 & 2)
-- finishing with a devastating two-handed vertical-diagonal energy cleave (step 3).
local function evaluateOverDriveWave(step: number, u: number): { [string]: CFrame }
	if step >= 3 then
		local s = swingPhase(u, 0.24)
		local p = (s + 1) * 0.5
		return {
			Root = CFrame.new(0, lerpNumber(0.14, -0.34, p), 0) * CFrame.Angles(lerpNumber(0.24, -0.36, p), lerpNumber(-0.42, 0.52, p), 0),
			Waist = CFrame.Angles(lerpNumber(0.28, -0.46, p), lerpNumber(-0.55, 0.85, p), 0),
			Neck = CFrame.Angles(lerpNumber(-0.18, 0.32, p), lerpNumber(0.45, -0.55, p), 0),
			RightShoulder = CFrame.Angles(lerpNumber(2.55, 0.32, p), lerpNumber(-0.25, 0.85, p), lerpNumber(0.55, -0.55, p)),
			RightElbow = CFrame.Angles(0.28, 0, 0),
			LeftShoulder = CFrame.Angles(lerpNumber(2.15, -0.45, p), lerpNumber(0.2, -0.35, p), -0.45),
			LeftElbow = CFrame.Angles(0.45, 0, 0),
		}
	end
	local dir = if step % 2 == 1 then 1 else -1
	local s = swingPhase(u, 0.2)
	local p = (s + 1) * 0.5
	local waistYaw = dir * lerpNumber(-0.85, 1.05, p)
	local armSweepY = dir * lerpNumber(-1.05, 1.35, p)
	return {
		Root = CFrame.new(0, -0.18, 0) * CFrame.Angles(-0.16, waistYaw * 0.3, 0),
		Waist = CFrame.Angles(-0.22, waistYaw, -dir * 0.16 * s),
		Neck = CFrame.Angles(0.2, -waistYaw * 0.6, 0),
		RightShoulder = CFrame.Angles(1.32, armSweepY, if dir > 0 then lerpNumber(1.35, -0.65, p) else lerpNumber(-0.65, 1.45, p)),
		RightElbow = CFrame.Angles(0.3, 0, 0),
		LeftShoulder = CFrame.Angles(-0.45 * dir * s, -armSweepY * 0.35, -0.75),
		LeftElbow = CFrame.Angles(0.55, 0, 0),
	}
end

-- Evaluates an active one-shot action (`attack`, `heavyAttack`, `dash`, `spin`, `stinger`,
-- `overdriveWave`, `parry`, `land`) at `elapsed` seconds.
function CombatAnim.evaluate(action: string, step: number?, elapsed: number): Pose
	local key = CombatAnim.specKey(action, step)
	local spec = Config.ANIMATIONS[key]
	if not spec or elapsed < 0 or elapsed >= spec.duration then
		return { active = false, weight = 0, joints = {} }
	end

	local u = elapsed / spec.duration
	local weight = envelope(u, spec.blendIn, spec.blendOut)
	local joints: { [string]: CFrame }
	if action == "attack" then
		joints = evaluateAttack(step or 1, u)
	elseif action == "heavyAttack" then
		joints = evaluateHeavyAttack(u)
	elseif action == "dash" then
		joints = evaluateDash(u)
	elseif action == "spin" then
		joints = evaluateSpin(u)
	elseif action == "stinger" then
		joints = evaluateStinger(u)
	elseif action == "overdriveWave" then
		joints = evaluateOverDriveWave(step or 1, u)
	elseif action == "parry" then
		joints = evaluateParry(u)
	elseif action == "land" then
		joints = evaluateLand(u)
	else
		return { active = false, weight = 0, joints = {} }
	end

	return {
		active = true,
		weight = weight,
		joints = joints,
	}
end

-- Continuous power-channeling stance while charging the DMC Over Drive ultimate: deep planted
-- stance with blade drawn low-back, coiling intensely as `progress` rises 0..1.
function CombatAnim.overdriveChargePose(progress: number): Pose
	local p = easeOutCubic(clamp01(progress))
	return {
		active = true,
		weight = Config.ANIM_OVERDRIVE_CHARGE_WEIGHT,
		joints = {
			Root = CFrame.new(0, lerpNumber(-0.18, -0.36, p), 0) * CFrame.Angles(lerpNumber(-0.08, -0.22, p), lerpNumber(-0.4, -0.82, p), 0),
			Waist = CFrame.Angles(lerpNumber(-0.05, 0.14, p), lerpNumber(-0.45, -0.92, p), 0),
			Neck = CFrame.Angles(lerpNumber(0.08, 0.18, p), lerpNumber(0.65, 1.15, p), 0),
			RightShoulder = CFrame.Angles(lerpNumber(0.85, 1.85, p), lerpNumber(-0.55, -0.95, p), lerpNumber(0.65, 1.05, p)),
			RightElbow = CFrame.Angles(lerpNumber(0.65, 0.42, p), 0, 0),
			LeftShoulder = CFrame.Angles(lerpNumber(1.15, 1.55, p), lerpNumber(0.4, 0.65, p), lerpNumber(-0.25, -0.45, p)),
			LeftElbow = CFrame.Angles(0.85, 0, 0),
			RightHip = CFrame.Angles(lerpNumber(0.32, 0.58, p), 0, 0.12),
			RightKnee = CFrame.Angles(lerpNumber(-0.55, -0.92, p), 0, 0),
			LeftHip = CFrame.Angles(lerpNumber(-0.28, -0.48, p), 0, -0.12),
			LeftKnee = CFrame.Angles(lerpNumber(-0.35, -0.58, p), 0, 0),
		},
	}
end

-- Continuous power-charge stance while holding Attack toward the 3-second heavy attack. Pulls
-- the sword further back over the shoulder as `progress` rises from 0 to 1.
function CombatAnim.chargePose(progress: number): Pose
	local p = easeOutCubic(clamp01(progress))
	return {
		active = true,
		weight = Config.ANIM_CHARGE_WEIGHT,
		joints = {
			Waist = CFrame.Angles(lerpNumber(0.05, 0.24, p), lerpNumber(-0.35, -0.72, p), 0),
			Neck = CFrame.Angles(lerpNumber(-0.04, -0.14, p), lerpNumber(0.28, 0.58, p), 0),
			RightShoulder = CFrame.Angles(lerpNumber(1.45, 2.38, p), lerpNumber(-0.2, -0.45, p), lerpNumber(0.35, 0.65, p)),
			RightElbow = CFrame.Angles(lerpNumber(0.75, 0.55, p), 0, 0),
			LeftShoulder = CFrame.Angles(lerpNumber(0.95, 1.75, p), lerpNumber(0.25, 0.35, p), lerpNumber(-0.2, -0.35, p)),
			LeftElbow = CFrame.Angles(0.7, 0, 0),
		},
	}
end

-- Continuous defensive sword-guard pose while the player holds Block (upper body + slight brace,
-- leaving legs free to strafe slowly).
function CombatAnim.blockPose(): Pose
	return {
		active = true,
		weight = Config.ANIM_BLOCK_WEIGHT,
		joints = {
			Waist = CFrame.Angles(-0.12, -0.35, 0),
			Neck = CFrame.Angles(0.1, 0.3, 0),
			RightShoulder = CFrame.Angles(1.25, -0.85, -0.45),
			RightElbow = CFrame.Angles(1.15, 0, 0),
			LeftShoulder = CFrame.Angles(0.85, 0.45, 0.25),
			LeftElbow = CFrame.Angles(1.1, 0, 0),
		},
	}
end

-- Continuous airborne pose blended from vertical velocity: athletic tucked leap while rising,
-- braced drop while falling.
function CombatAnim.jumpPose(verticalSpeed: number): Pose
	local rise = Config.ANIM_JUMP_RISE_VELOCITY
	local fall = Config.ANIM_JUMP_FALL_VELOCITY
	-- 1 = rising fast, 0 = falling fast.
	local t = clamp01((verticalSpeed - fall) / math.max(rise - fall, 1e-3))

	local rootPitch = lerpNumber(-0.18, 0.14, t)
	local waistPitch = lerpNumber(-0.14, 0.12, t)
	local rShoulderX = lerpNumber(0.55, 1.35, t)
	local rShoulderZ = lerpNumber(0.85, 0.45, t)
	local lShoulderX = lerpNumber(0.45, 0.95, t)
	local lShoulderZ = lerpNumber(-0.85, -0.45, t)
	-- Right knee tucks high during ascent, legs extend down as the player falls.
	local rHipX = lerpNumber(0.28, 1.05, t)
	local rKneeX = lerpNumber(-0.45, -1.45, t)
	local lHipX = lerpNumber(0.15, -0.32, t)
	local lKneeX = lerpNumber(-0.3, -0.55, t)

	return {
		active = true,
		weight = Config.ANIM_JUMP_WEIGHT,
		joints = {
			Root = CFrame.Angles(rootPitch, 0, 0),
			Waist = CFrame.Angles(waistPitch, 0, 0),
			Neck = CFrame.Angles(-waistPitch * 0.6, 0, 0),
			RightShoulder = CFrame.Angles(rShoulderX, 0, rShoulderZ),
			RightElbow = CFrame.Angles(lerpNumber(0.35, 0.75, t), 0, 0),
			LeftShoulder = CFrame.Angles(lShoulderX, 0, lShoulderZ),
			LeftElbow = CFrame.Angles(lerpNumber(0.35, 0.65, t), 0, 0),
			RightHip = CFrame.Angles(rHipX, 0, 0),
			RightKnee = CFrame.Angles(rKneeX, 0, 0),
			LeftHip = CFrame.Angles(lHipX, 0, 0),
			LeftKnee = CFrame.Angles(lKneeX, 0, 0),
		},
	}
end

--=============================================================================
-- Self test
--=============================================================================

function CombatAnim.selfTest()
	-- Spec keys & priority ordering: spin > dash > attack > land.
	assert(CombatAnim.specKey("attack", 1) == "attack", "step 1 uses light attack spec")
	assert(CombatAnim.specKey("attack", 3) == "attackHeavy", "step 3 uses heavy attack spec")
	assert(CombatAnim.canInterrupt("attack", "dash"), "dash interrupts an attack")
	assert(CombatAnim.canInterrupt("dash", "spin"), "spin interrupts a dash")
	assert(not CombatAnim.canInterrupt("spin", "attack"), "attack cannot cancel a spin")
	assert(CombatAnim.canInterrupt("attack", "attack"), "combo chain interrupts previous swing")
	assert(CombatAnim.canInterrupt("land", "attack"), "attack interrupts landing squash")

	-- Combo steps 1 and 2 swing in opposite directions; step 3 uses an overhead cleave.
	local a1 = CombatAnim.evaluate("attack", 1, 0.12)
	local a2 = CombatAnim.evaluate("attack", 2, 0.12)
	local a3 = CombatAnim.evaluate("attack", 3, 0.06)
	assert(a1.active and a1.weight > 0.5, "attack step 1 is active mid-swing")
	assert(a2.active and a1.joints.Waist ~= a2.joints.Waist, "combo steps 1 and 2 mirror their swing")
	assert(a3.active and a3.joints.Root ~= nil, "heavy step 3 drives full-body cleave")
	assert(not CombatAnim.evaluate("attack", 1, 1.0).active, "expired attack returns inactive")

	-- Dash leans forward and bends legs.
	local d = CombatAnim.evaluate("dash", nil, 0.1)
	assert(d.active and d.joints.Root ~= nil and d.joints.RightHip ~= nil, "dash drives full-body lean")

	-- Spin completes a full 360-degree turn across its duration.
	local spinMid = CombatAnim.evaluate("spin", nil, Config.ANIMATIONS.spin.duration * 0.25)
	assert(spinMid.active and spinMid.joints.Root ~= nil and spinMid.joints.RightShoulder ~= nil, "spin rotates root and extends arm")
	local spinEnd = CombatAnim.evaluate("spin", nil, Config.ANIMATIONS.spin.duration + 0.01)
	assert(not spinEnd.active, "spin ends cleanly after duration")

	-- Jump rises with tucked leg, falls with extended legs, and landing squashes root downward.
	local rise = CombatAnim.jumpPose(25)
	local fall = CombatAnim.jumpPose(-25)
	assert(rise.active and fall.active, "jump poses are active")
	assert(rise.joints.RightHip ~= fall.joints.RightHip, "rising and falling jump poses differ")
	local land = CombatAnim.evaluate("land", nil, Config.ANIMATIONS.land.duration * 0.5)
	assert(land.active and land.joints.Root.Position.Y < -0.1, "landing squashes root downward")

	-- Block, Parry, and Heavy Charge/Attack poses.
	local blk = CombatAnim.blockPose()
	assert(blk.active and blk.joints.RightShoulder ~= nil and blk.joints.RightElbow ~= nil, "block pose raises sword guard")
	local pry = CombatAnim.evaluate("parry", nil, Config.ANIMATIONS.parry.duration * 0.4)
	assert(pry.active and pry.joints.RightShoulder ~= nil, "parry animates deflect sweep")
	local chg0 = CombatAnim.chargePose(0)
	local chg1 = CombatAnim.chargePose(1)
	assert(chg0.active and chg1.active and chg0.joints.RightShoulder ~= chg1.joints.RightShoulder, "charge pose coils further as progress rises")
	local hvy = CombatAnim.evaluate("heavyAttack", nil, Config.ANIMATIONS.heavyAttack.duration * 0.5)
	assert(hvy.active and hvy.joints.Root ~= nil and hvy.joints.RightShoulder ~= nil, "heavyAttack drives full-body slam cleave")

	-- Stinger thrust and Over Drive charge/waves.
	local stg = CombatAnim.evaluate("stinger", nil, Config.ANIMATIONS.stinger.duration * 0.35)
	assert(stg.active and stg.joints.Root ~= nil and stg.joints.RightShoulder ~= nil, "stinger drives forward lance thrust")
	local odChg0 = CombatAnim.overdriveChargePose(0)
	local odChg1 = CombatAnim.overdriveChargePose(1)
	assert(odChg0.active and odChg1.active and odChg0.joints.Waist ~= odChg1.joints.Waist, "overdrive charge pose coils deeper")
	local odW1 = CombatAnim.evaluate("overdriveWave", 1, Config.ANIMATIONS.overdriveWave.duration * 0.4)
	local odW2 = CombatAnim.evaluate("overdriveWave", 2, Config.ANIMATIONS.overdriveWave.duration * 0.4)
	local odW3 = CombatAnim.evaluate("overdriveWave", 3, Config.ANIMATIONS.overdriveWave.duration * 0.4)
	assert(odW1.active and odW2.active and odW3.active, "all 3 overdrive wave animations are active")
	assert(odW1.joints.Waist ~= odW2.joints.Waist, "overdrive waves 1 and 2 alternate sweep direction")

	-- Every required action spec exists with valid positive duration.
	for _, key in ipairs({ "attack", "attackHeavy", "heavyAttack", "dash", "spin", "stinger", "overdriveWave", "parry", "land" }) do
		local spec = Config.ANIMATIONS[key]
		assert(spec ~= nil and spec.duration > 0, `Config.ANIMATIONS.{key} must exist with positive duration`)
	end
end

return CombatAnim
