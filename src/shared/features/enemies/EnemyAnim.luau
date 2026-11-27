--!strict
--[[
	Pure procedural animation poses for rigged `.rbxmx` enemies (walking, weapon-specific attack
	windup/strike, and death collapse).

	Every pose returns per-joint-group delta CFrames (`torso`, `head`, `leftLeg`, `rightLeg`,
	`leftArm`, `rightArm`) multiplied onto each Motor6D's authored rest `C0` by `EnemyAnimator`
	on `RenderStepped`. Keeping the math pure lets `make test` verify walk cycles, weapon
	variation (`sword`, `dual`, `axe`, `mace`), and death collapse without needing Studio.
]]

local EnemyAnim = {}

export type LimbPose = {
	-- Optional whole-body transform around `Body`'s center (used by dual-blade tornado spin so
	-- the entire warrior spins as one connected body rather than each limb spinning in place).
	root: CFrame?,
	torso: CFrame,
	head: CFrame,
	leftLeg: CFrame,
	rightLeg: CFrame,
	leftArm: CFrame,
	rightArm: CFrame,
}

local GROUPS = { "torso", "head", "leftLeg", "rightLeg", "leftArm", "rightArm" }

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

function EnemyAnim.neutral(): LimbPose
	return {
		root = CFrame.identity,
		torso = CFrame.identity,
		head = CFrame.identity,
		leftLeg = CFrame.identity,
		rightLeg = CFrame.identity,
		leftArm = CFrame.identity,
		rightArm = CFrame.identity,
	}
end

function EnemyAnim.blend(a: LimbPose, b: LimbPose, alpha: number): LimbPose
	local t = clamp01(alpha)
	local rootA = a.root or CFrame.identity
	local rootB = b.root or CFrame.identity
	return {
		root = rootA:Lerp(rootB, t),
		torso = a.torso:Lerp(b.torso, t),
		head = a.head:Lerp(b.head, t),
		leftLeg = a.leftLeg:Lerp(b.leftLeg, t),
		rightLeg = a.rightLeg:Lerp(b.rightLeg, t),
		leftArm = a.leftArm:Lerp(b.leftArm, t),
		rightArm = a.rightArm:Lerp(b.rightArm, t),
	}
end

-- Locomotion pose: adapts stride and stance per enemy kind & weapon (`melee`, `ranged`,
-- `exploder`, `grabber`), transitioning smoothly to mechanical idle breathing when stationary.
-- Head, leftArm, and rightArm inherit `torso` hierarchically in `EnemyAnimator`, so `head` only
-- carries neck rotation (no duplicate torso translation).
function EnemyAnim.walkPose(phase: number, speedFactor: number, weapon: string?, kind: string?): LimbPose
	local s = clamp01(speedFactor)
	local stride = math.sin(phase)
	local bounce = math.abs(math.cos(phase))
	local idleBreath = math.sin(phase * 0.45) * 0.04 * (1 - s)

	if kind == "exploder" then
		-- Frantic, hunched high-tempo sprint carrying strapped C4/TNT.
		local fast = math.sin(phase * 1.45)
		local fastBounce = math.abs(math.cos(phase * 1.45))
		return {
			torso = CFrame.new(0, fastBounce * 0.16 * s + idleBreath, 0) * CFrame.Angles(-0.26 * s, fast * 0.14 * s, -fast * 0.07 * s),
			head = CFrame.Angles(0.22 * s, -fast * 0.1 * s, 0),
			leftLeg = CFrame.Angles(fast * 0.78 * s, 0, 0),
			rightLeg = CFrame.Angles(-fast * 0.78 * s, 0, 0),
			leftArm = CFrame.Angles(-0.35 - fast * 0.52 * s, 0, -0.2),
			rightArm = CFrame.Angles(-0.35 + fast * 0.52 * s, 0, 0.2),
		}
	elseif kind == "grabber" then
		-- Heavy stomping juggernaut gait with wide muscular shoulder sway.
		local stomp = math.sin(phase * 0.75)
		local thud = math.abs(math.cos(phase * 0.75))
		return {
			torso = CFrame.new(0, thud * 0.16 * s + idleBreath, 0) * CFrame.Angles(-0.14 * s, stomp * 0.16 * s, -stomp * 0.08 * s),
			head = CFrame.Angles(0.1 * s, -stomp * 0.12 * s, 0),
			leftLeg = CFrame.Angles(stomp * 0.48 * s, 0, 0),
			rightLeg = CFrame.Angles(-stomp * 0.48 * s, 0, 0),
			leftArm = CFrame.Angles(-stomp * 0.34 * s + 0.12, -0.1, -0.14),
			rightArm = CFrame.Angles(stomp * 0.34 * s + 0.12, 0.1, 0.14),
		}
	elseif kind == "ranged" then
		-- Steady braced aim stance: weapon stays level toward the target while legs march/strafe.
		return {
			torso = CFrame.new(0, bounce * 0.08 * s + idleBreath, 0) * CFrame.Angles(-0.06 * s, -0.12, 0),
			head = CFrame.Angles(0.05 * s, 0.12, 0),
			leftLeg = CFrame.Angles(stride * 0.52 * s, 0, 0),
			rightLeg = CFrame.Angles(-stride * 0.52 * s, 0, 0),
			leftArm = CFrame.Angles(0.06 + bounce * 0.05 * s, 0.08, 0),
			rightArm = CFrame.Angles(0.04 + bounce * 0.04 * s, -0.04, 0),
		}
	elseif kind == "area" then
		-- Heavy braced artillery march: slight forward lean to counterbalance the dorsal mortar tubes.
		local heavy = math.sin(phase * 0.85)
		local thump = math.abs(math.cos(phase * 0.85))
		return {
			torso = CFrame.new(0, thump * 0.1 * s + idleBreath, 0) * CFrame.Angles(-0.12 * s, heavy * 0.08 * s, 0),
			head = CFrame.Angles(0.1 * s, -heavy * 0.06 * s, 0),
			leftLeg = CFrame.Angles(heavy * 0.46 * s, 0, 0),
			rightLeg = CFrame.Angles(-heavy * 0.46 * s, 0, 0),
			leftArm = CFrame.Angles(0.18 + thump * 0.06 * s, 0.12, -0.06),
			rightArm = CFrame.Angles(0.14 - thump * 0.06 * s, -0.1, 0.06),
		}
	elseif kind == "contact" then
		-- Fast crouched electro-sprinter stride with Tesla discharge arms flared out slightly.
		local fast = math.sin(phase * 1.3)
		local zip = math.abs(math.cos(phase * 1.3))
		return {
			torso = CFrame.new(0, zip * 0.14 * s + idleBreath - 0.06, 0) * CFrame.Angles(-0.22 * s, fast * 0.16 * s, -fast * 0.08 * s),
			head = CFrame.Angles(0.18 * s, -fast * 0.12 * s, 0),
			leftLeg = CFrame.Angles(fast * 0.72 * s, 0, 0),
			rightLeg = CFrame.Angles(-fast * 0.72 * s, 0, 0),
			leftArm = CFrame.Angles(0.12 - fast * 0.32 * s, 0.2, -0.26),
			rightArm = CFrame.Angles(0.12 + fast * 0.32 * s, -0.2, 0.26),
		}
	end

	local legAmp = 0.62 * s
	local leftLeg = CFrame.Angles(stride * legAmp, 0, 0)
	local rightLeg = CFrame.Angles(-stride * legAmp, 0, 0)

	local torsoY = bounce * 0.12 * s + idleBreath
	local torsoPitch = -0.1 * s
	local torsoYaw = stride * 0.12 * s
	local torso = CFrame.new(0, torsoY, 0) * CFrame.Angles(torsoPitch, torsoYaw, -stride * 0.04 * s)
	local head = CFrame.Angles(-torsoPitch * 0.6, -torsoYaw * 0.7, 0)

	local leftArm: CFrame
	local rightArm: CFrame
	if weapon == "dual" then
		-- Aggressive twin-blade stance: both blades bob rhythmically in opposition while running.
		leftArm = CFrame.Angles(-stride * 0.34 * s + 0.12, 0.1, -0.12)
		rightArm = CFrame.Angles(stride * 0.34 * s + 0.12, -0.1, 0.12)
	elseif weapon == "axe" or weapon == "mace" then
		-- Heavy right weapon held slightly high and steady; left arm counter-balances strongly.
		leftArm = CFrame.Angles(-stride * 0.45 * s, 0, -0.08)
		rightArm = CFrame.Angles(0.22 + stride * 0.22 * s, -0.08, 0.1)
	else
		-- Sword & buckler: shield arm braced forward, blade arm counter-swings.
		leftArm = CFrame.Angles(0.15 - stride * 0.28 * s, 0.18, -0.06)
		rightArm = CFrame.Angles(stride * 0.32 * s + 0.08, -0.08, 0.06)
	end

	return {
		torso = torso,
		head = head,
		leftLeg = leftLeg,
		rightLeg = rightLeg,
		leftArm = leftArm,
		rightArm = rightArm,
	}
end

-- Telegraph windup pose (`progress` in [0, 1]): raises/opens the enemy's weapon cleanly so players
-- read the incoming strike and weapon style from the isometric camera. Weapons rest pointing
-- forward (`-Z`), so positive X lifts overhead and outward Y opens wide before sweeping forward.
function EnemyAnim.windupPose(progress: number, weapon: string?): LimbPose
	local p = easeOutCubic(progress)
	if weapon == "dual" then
		-- Flare both blades wide out to the sides and raised for a twin forward scissor cross-slash.
		return {
			torso = CFrame.new(0, 0.06 * p, 0) * CFrame.Angles(0.16 * p, 0, 0),
			head = CFrame.Angles(-0.14 * p, 0, 0),
			leftLeg = CFrame.Angles(-0.22 * p, 0, 0),
			rightLeg = CFrame.Angles(0.25 * p, 0, 0),
			leftArm = CFrame.Angles(0.58 * p, 0.72 * p, -0.32 * p),
			rightArm = CFrame.Angles(0.58 * p, -0.72 * p, 0.32 * p),
		}
	elseif weapon == "axe" then
		-- Hoist heavy battle-axe high and wide to the right with a deep torso coil.
		return {
			torso = CFrame.new(0, 0.08 * p, 0) * CFrame.Angles(0.18 * p, -0.52 * p, 0),
			head = CFrame.Angles(-0.14 * p, 0.46 * p, 0),
			leftLeg = CFrame.Angles(0.25 * p, 0, 0),
			rightLeg = CFrame.Angles(-0.32 * p, 0, 0),
			leftArm = CFrame.Angles(0.32 * p, 0.38 * p, -0.2 * p),
			rightArm = CFrame.Angles(1.12 * p, -0.52 * p, 0.28 * p),
		}
	elseif weapon == "mace" then
		-- Lift crusher mace straight overhead for a heavy forward downward smash.
		return {
			torso = CFrame.new(0, 0.1 * p, 0) * CFrame.Angles(0.22 * p, -0.14 * p, 0),
			head = CFrame.Angles(-0.16 * p, 0.12 * p, 0),
			leftLeg = CFrame.Angles(0.2 * p, 0, 0),
			rightLeg = CFrame.Angles(-0.28 * p, 0, 0),
			leftArm = CFrame.Angles(0.8 * p, 0.22 * p, -0.16 * p),
			rightArm = CFrame.Angles(1.38 * p, -0.12 * p, 0.1 * p),
		}
	end

	-- Default `sword`: lift plasma blade high right-side while bracing left buckler.
	return {
		torso = CFrame.new(0, 0.06 * p, 0) * CFrame.Angles(0.14 * p, -0.4 * p, 0),
		head = CFrame.Angles(-0.12 * p, 0.34 * p, 0),
		leftLeg = CFrame.Angles(0.22 * p, 0, 0),
		rightLeg = CFrame.Angles(-0.26 * p, 0, 0),
		leftArm = CFrame.Angles(0.26 * p, 0.36 * p, -0.14 * p),
		rightArm = CFrame.Angles(0.92 * p, -0.48 * p, 0.22 * p),
	}
end

-- Strike follow-through pose (`progress` in [0, 1]): snaps violently from windup into a forward
-- impact (`0..0.36`, keeping every weapon tip strictly in front `-Z` of the enemy) and settles
-- cleanly back to combat stance (`0.58..1.0`).
function EnemyAnim.strikePose(progress: number, weapon: string?): LimbPose
	local u = clamp01(progress)
	local startPose = EnemyAnim.windupPose(1, weapon)
	local impactPose: LimbPose

	if weapon == "dual" then
		-- Forward twin X-slash crossing sharply in front of the chest.
		impactPose = {
			torso = CFrame.new(0, -0.12, -0.1) * CFrame.Angles(-0.22, 0, 0),
			head = CFrame.Angles(0.18, 0, 0),
			leftLeg = CFrame.Angles(0.32, 0, 0),
			rightLeg = CFrame.Angles(-0.32, 0, 0),
			leftArm = CFrame.Angles(-0.14, -0.68, 0.28),
			rightArm = CFrame.Angles(-0.14, 0.68, -0.28),
		}
	elseif weapon == "axe" then
		-- Heavy forward diagonal cleave sweeping right-to-left across the front.
		impactPose = {
			torso = CFrame.new(0, -0.15, -0.12) * CFrame.Angles(-0.24, 0.56, -0.08),
			head = CFrame.Angles(0.18, -0.46, 0),
			leftLeg = CFrame.Angles(-0.28, 0, 0),
			rightLeg = CFrame.Angles(0.38, 0, 0),
			leftArm = CFrame.Angles(-0.18, -0.26, -0.3),
			rightArm = CFrame.Angles(-0.22, 0.62, -0.32),
		}
	elseif weapon == "mace" then
		-- Crushing forward vertical smash driving the mace head into the floor ahead (`-Z`).
		impactPose = {
			torso = CFrame.new(0, -0.22, -0.15) * CFrame.Angles(-0.34, 0.16, 0),
			head = CFrame.Angles(0.28, -0.14, 0),
			leftLeg = CFrame.Angles(0.36, 0, 0),
			rightLeg = CFrame.Angles(-0.38, 0, 0),
			leftArm = CFrame.Angles(-0.24, -0.16, -0.2),
			rightArm = CFrame.Angles(-0.32, 0.14, -0.08),
		}
	else
		-- Crisp forward slash sweeping right-to-left across the player in front.
		impactPose = {
			torso = CFrame.new(0, -0.12, -0.1) * CFrame.Angles(-0.2, 0.48, -0.06),
			head = CFrame.Angles(0.16, -0.4, 0),
			leftLeg = CFrame.Angles(-0.22, 0, 0),
			rightLeg = CFrame.Angles(0.32, 0, 0),
			leftArm = CFrame.Angles(0.1, -0.24, -0.2),
			rightArm = CFrame.Angles(-0.16, 0.58, -0.2),
		}
	end

	if u < 0.36 then
		return EnemyAnim.blend(startPose, impactPose, easeOutCubic(u / 0.36))
	elseif u < 0.58 then
		return impactPose
	else
		return EnemyAnim.blend(impactPose, EnemyAnim.neutral(), easeInOutQuad((u - 0.58) / 0.42))
	end
end

-- Ultra-fast Paso Fantasma (Phantom Step) dash stance: deep forward aerodynamic lean with
-- plasma sword drawn out to the side ready to slice the instant the final hop lands.
function EnemyAnim.phantomStepPose(): LimbPose
	return {
		torso = CFrame.new(0, -0.26, -0.18) * CFrame.Angles(-0.38, -0.38, 0),
		head = CFrame.Angles(0.32, 0.34, 0),
		leftLeg = CFrame.Angles(0.7, 0, 0),
		rightLeg = CFrame.Angles(-0.82, 0, 0),
		leftArm = CFrame.Angles(0.25, 0.42, -0.3),
		rightArm = CFrame.Angles(0.15, -0.85, 0.3),
	}
end

-- Heavy mace seismic slam windup: lifts the crusher high overhead with both arms trembling
-- slightly at peak charge before bringing it crashing down in front onto the arena floor.
function EnemyAnim.slamWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local tremble = math.sin(clock * 42) * 0.04 * p
	return {
		torso = CFrame.new(0, 0.16 * p, 0) * CFrame.Angles(0.28 * p, tremble, 0),
		head = CFrame.Angles(-0.22 * p, -tremble, 0),
		leftLeg = CFrame.Angles(0.26 * p, 0, 0),
		rightLeg = CFrame.Angles(-0.34 * p, 0, 0),
		leftArm = CFrame.Angles(1.38 * p + tremble, 0.22 * p, -0.18 * p),
		rightArm = CFrame.Angles(1.6 * p - tremble, -0.16 * p, 0.14 * p),
	}
end

-- Continuous tornado spin pose for dual-blade melee units executing their high-DPS spin attack:
-- rotates the ENTIRE warrior cleanly around its vertical center via `root` while holding both
-- blades extended horizontally out to the sides in a braced warrior stance (no detached spinning limbs).
function EnemyAnim.spinPose(clock: number): LimbPose
	local spinAngle = -clock * 15
	local sway = math.sin(clock * 12) * 0.06
	return {
		root = CFrame.new(0, -0.14, 0) * CFrame.Angles(0, spinAngle, 0),
		torso = CFrame.Angles(-0.18, 0, sway),
		head = CFrame.Angles(0.14, 0, -sway * 0.5),
		leftLeg = CFrame.Angles(0.34, 0, -0.22),
		rightLeg = CFrame.Angles(-0.34, 0, 0.22),
		leftArm = CFrame.Angles(0.12, 0.28, -1.28),
		rightArm = CFrame.Angles(0.12, -0.28, 1.28),
	}
end

-- Rifle maximum-power beam charge stance: braced wide footing with rifle held dead level while
-- trembling faster as energy approaches full charge.
function EnemyAnim.beamChargePose(clock: number, progress: number): LimbPose
	local p = clamp01(progress)
	local vib = math.sin(clock * (24 + p * 30)) * (0.012 + p * 0.038)
	return {
		torso = CFrame.new(0, -0.08 * p, 0.12 * p) * CFrame.Angles(0.08 * p, -0.16 + vib, vib * 0.4),
		head = CFrame.Angles(-0.05 * p, 0.16 - vib, 0),
		leftLeg = CFrame.Angles(0.26 * p, 0, -0.14 * p),
		rightLeg = CFrame.Angles(-0.32 * p, 0, 0.14 * p),
		leftArm = CFrame.Angles(0.16 * p + vib, 0.22 * p, 0),
		rightArm = CFrame.Angles(0.1 * p - vib, -0.08 * p, vib),
	}
end

-- Acrobat backstep evade leap for ranged units escaping a close player: pushes off backward,
-- tucks knees mid-air while keeping the weapon trained ahead, then braces for landing.
function EnemyAnim.evadeJumpPose(progress: number): LimbPose
	local u = clamp01(progress)
	local air = math.sin(math.pi * u)
	local leanBack = 0.32 * air
	return {
		torso = CFrame.new(0, 0.1 * air, 0) * CFrame.Angles(leanBack, -0.12 * air, 0),
		head = CFrame.Angles(-leanBack * 0.65, 0.12 * air, 0),
		leftLeg = CFrame.Angles(0.8 * air, 0, -0.12 * air),
		rightLeg = CFrame.Angles(0.52 * air, 0, 0.12 * air),
		leftArm = CFrame.Angles(-0.22 * air, 0.18 * air, -0.3 * air),
		rightArm = CFrame.Angles(-0.16 * air, -0.1 * air, 0.2 * air),
	}
end

-- Ranged weapon recoil pose (`progress` in [0, 1]): crisp, unmistakably visible barrel kick
-- upward & backward on every shot, with heavier punch for shotgun and plasma cannon.
-- Because head and arms inherit `torso`'s backward kick hierarchically, limbs stay cleanly bolted
-- to the shoulders while kicking upward with the barrel.
function EnemyAnim.firePose(progress: number, weapon: string?): LimbPose
	local u = clamp01(progress)
	local kick: number
	if u < 0.18 then
		kick = easeOutCubic(u / 0.18)
	elseif u < 0.36 then
		kick = 1 - 0.12 * ((u - 0.18) / 0.18)
	else
		kick = 0.88 * (1 - easeInOutQuad((u - 0.36) / 0.64))
	end
	local power = if weapon == "shotgun"
		then 1.45
		elseif weapon == "plasma" then 1.32
		elseif weapon == "minigun" then 0.8
		else 1.1
	return {
		torso = CFrame.new(0, -0.05 * kick * power, 0.28 * kick * power) * CFrame.Angles(0.28 * kick * power, -0.18 * kick * power, 0),
		head = CFrame.Angles(-0.2 * kick * power, 0.16 * kick * power, 0),
		leftLeg = CFrame.Angles(0.24 * kick * power, 0, -0.08 * kick),
		rightLeg = CFrame.Angles(-0.3 * kick * power, 0, 0.08 * kick),
		leftArm = CFrame.new(0, 0.04 * kick * power, 0.1 * kick * power) * CFrame.Angles(0.46 * kick * power, 0.14 * kick, -0.04 * kick),
		rightArm = CFrame.new(0, 0.06 * kick * power, 0.14 * kick * power) * CFrame.Angles(0.62 * kick * power, -0.12 * kick, 0.1 * kick),
	}
end

-- Axe throw windup pose (`progress` in [0, 1]): draws the heavy battle-axe far behind the right
-- shoulder while the left hand aims forward at the target.
function EnemyAnim.axeThrowWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local tremble = math.sin(clock * 36) * 0.035 * p
	return {
		torso = CFrame.new(0, 0.08 * p, 0.12 * p) * CFrame.Angles(0.22 * p, -0.68 * p + tremble, 0),
		head = CFrame.Angles(-0.16 * p, 0.62 * p, 0),
		leftLeg = CFrame.Angles(0.32 * p, 0, 0),
		rightLeg = CFrame.Angles(-0.38 * p, 0, 0),
		leftArm = CFrame.Angles(0.55 * p, 0.28 * p, -0.16 * p),
		rightArm = CFrame.Angles(1.48 * p + tremble, -0.65 * p, 0.34 * p),
	}
end

-- Unarmed sprint pose while the axe enemy scrambles across the floor to retrieve its dropped axe.
function EnemyAnim.axeRetrievePose(phase: number): LimbPose
	local fast = math.sin(phase * 1.45)
	local bounce = math.abs(math.cos(phase * 1.45))
	return {
		torso = CFrame.new(0, bounce * 0.14 - 0.12, -0.1) * CFrame.Angles(-0.3, fast * 0.16, -fast * 0.07),
		head = CFrame.Angles(0.24, -fast * 0.12, 0),
		leftLeg = CFrame.Angles(fast * 0.8, 0, 0),
		rightLeg = CFrame.Angles(-fast * 0.8, 0, 0),
		leftArm = CFrame.Angles(-0.42 - fast * 0.6, 0.1, -0.14),
		rightArm = CFrame.Angles(0.32 + fast * 0.52, -0.1, 0.14),
	}
end

-- Exploder fuse pose: hunched vibrating detonation crouch with arms thrown high as C4/TNT primes.
function EnemyAnim.fusePose(clock: number, progress: number): LimbPose
	local p = clamp01(progress)
	local shake = math.sin(clock * (28 + p * 26)) * (0.07 + p * 0.12)
	return {
		torso = CFrame.new(shake * 0.4, -0.2 * p, 0) * CFrame.Angles(-0.26 * p, shake, shake * 0.6),
		head = CFrame.Angles(0.22 * p, -shake, 0),
		leftLeg = CFrame.Angles(0.26 * p, 0, -0.14 * p),
		rightLeg = CFrame.Angles(0.26 * p, 0, 0.14 * p),
		leftArm = CFrame.Angles(1.3 * p + shake, 0, -0.6 * p),
		rightArm = CFrame.Angles(1.3 * p - shake, 0, 0.6 * p),
	}
end

-- Grabber windup pose (`progress` in [0, 1]): muscular crouch coiling both massive arms back
-- before lunging forward.
function EnemyAnim.grabWindupPose(progress: number): LimbPose
	local p = easeOutCubic(progress)
	return {
		torso = CFrame.new(0, -0.22 * p, 0.18 * p) * CFrame.Angles(0.2 * p, 0, 0),
		head = CFrame.Angles(-0.18 * p, 0, 0),
		leftLeg = CFrame.Angles(0.36 * p, 0, -0.12 * p),
		rightLeg = CFrame.Angles(-0.4 * p, 0, 0.12 * p),
		leftArm = CFrame.Angles(0.6 * p, 0.56 * p, -0.52 * p),
		rightArm = CFrame.Angles(0.6 * p, -0.56 * p, 0.52 * p),
	}
end

-- Grabber lunge pose: aggressive bull-rush lean with both massive arms reaching forward to catch.
function EnemyAnim.grabLungePose(): LimbPose
	return {
		torso = CFrame.new(0, -0.2, -0.28) * CFrame.Angles(-0.34, 0, 0),
		head = CFrame.Angles(0.24, 0, 0),
		leftLeg = CFrame.Angles(-0.62, 0, 0),
		rightLeg = CFrame.Angles(0.52, 0, 0),
		leftArm = CFrame.Angles(0.7, -0.32, -0.22),
		rightArm = CFrame.Angles(0.7, 0.32, 0.22),
	}
end

-- Grabber rush windup (`progress` in [0, 1]): drops low and lowers its right shoulder like a bull,
-- one foot scraping the floor. Deliberately unlike the grab windup (which coils the arms back to
-- reach), so the two attacks — answered differently — are told apart at a glance.
function EnemyAnim.rushWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local scrape = math.sin(clock * 14) * 0.35 * p
	return {
		torso = CFrame.new(0, -0.38 * p, 0.06 * p) * CFrame.Angles(-0.3 * p, 0.26 * p, 0),
		head = CFrame.Angles(0.28 * p, -0.2 * p, 0),
		leftLeg = CFrame.Angles(0.42 * p, 0, -0.1 * p),
		rightLeg = CFrame.Angles(-0.32 * p + scrape, 0, 0.1 * p),
		leftArm = CFrame.Angles(0.32 * p, 0.2 * p, -0.28 * p),
		rightArm = CFrame.Angles(0.52 * p, -0.22 * p, 0.18 * p),
	}
end

-- Grabber rush: shoulder-first charge, arms tucked and legs driving on a fast stride.
function EnemyAnim.rushPose(clock: number): LimbPose
	local stride = math.sin(clock * 22)
	return {
		torso = CFrame.new(0, -0.26, -0.2) * CFrame.Angles(-0.44, 0.3, 0),
		head = CFrame.Angles(0.36, -0.24, 0),
		leftLeg = CFrame.Angles(0.72 * stride, 0, 0),
		rightLeg = CFrame.Angles(-0.72 * stride, 0, 0),
		leftArm = CFrame.Angles(0.42, 0.3, -0.18),
		rightArm = CFrame.Angles(0.78, -0.26, 0.14),
	}
end

-- Continuous squeezing pose while the muscular grabber holds a trapped player in its front claws.
function EnemyAnim.grabHoldPose(clock: number): LimbPose
	local squeeze = 0.5 + 0.5 * math.sin(clock * 8.5)
	local tremble = math.sin(clock * 22) * 0.04
	return {
		torso = CFrame.new(0, -0.12 - squeeze * 0.08, 0) * CFrame.Angles(-0.2 - squeeze * 0.1, tremble, 0),
		head = CFrame.Angles(0.18 + squeeze * 0.08, -tremble * 1.5, 0),
		leftLeg = CFrame.Angles(0.25, 0, -0.14),
		rightLeg = CFrame.Angles(-0.22, 0, 0.14),
		-- Pull both huge arms inward to wrap and crush the player in front of the chest.
		leftArm = CFrame.Angles(0.38 + squeeze * 0.18, -0.62 - squeeze * 0.22, 0.28 + squeeze * 0.15),
		rightArm = CFrame.Angles(0.38 + squeeze * 0.18, 0.62 + squeeze * 0.22, -0.28 - squeeze * 0.15),
	}
end

-- Boss Oh frontal cone smash windup: coils right and hoists the Titanic Maul overhead.
function EnemyAnim.bossConeWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local quake = math.sin(clock * 24) * 0.04 * p
	return {
		torso = CFrame.new(0, 0.25 * p, 0.22 * p) * CFrame.Angles(0.24 * p, -0.58 * p + quake, 0),
		head = CFrame.Angles(-0.18 * p, 0.45 * p, 0),
		leftLeg = CFrame.Angles(0.35 * p, 0, -0.14 * p),
		rightLeg = CFrame.Angles(-0.4 * p, 0, 0.14 * p),
		leftArm = CFrame.Angles(0.55 * p, -0.35 * p, -0.45 * p),
		rightArm = CFrame.Angles(1.38 * p + quake, -0.25 * p, 0.35 * p),
	}
end

-- Boss Oh seismic leap windup: deep coiled hydraulic crouch bracing both legs before launch.
function EnemyAnim.bossLeapWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local hum = math.sin(clock * 28) * 0.04 * p
	return {
		torso = CFrame.new(0, -0.78 * p, 0.2 * p) * CFrame.Angles(-0.38 * p, hum, 0),
		head = CFrame.Angles(0.32 * p, -hum, 0),
		leftLeg = CFrame.Angles(0.62 * p, 0, -0.18 * p),
		rightLeg = CFrame.Angles(0.62 * p, 0, 0.18 * p),
		leftArm = CFrame.Angles(-0.42 * p, 0, -0.5 * p),
		rightArm = CFrame.Angles(-0.32 * p, 0, 0.5 * p),
	}
end

-- Boss Oh airborne meteor leap: raises Titanic Maul high while ascending, plunges forward on descent.
function EnemyAnim.bossLeapAirPose(progress: number): LimbPose
	local u = clamp01(progress)
	local slam = easeInOutQuad(math.max((u - 0.55) / 0.45, 0))
	return {
		torso = CFrame.new(0, 0.25 * (1 - slam), -0.35 * slam) * CFrame.Angles(lerpNumber(0.32, -0.52, slam), 0, 0),
		head = CFrame.Angles(lerpNumber(-0.22, 0.35, slam), 0, 0),
		leftLeg = CFrame.Angles(lerpNumber(0.58, -0.35, slam), 0, -0.15),
		rightLeg = CFrame.Angles(lerpNumber(-0.45, 0.45, slam), 0, 0.15),
		leftArm = CFrame.Angles(lerpNumber(1.05, 0.35, slam), 0, -0.45),
		rightArm = CFrame.Angles(lerpNumber(1.45, -0.32, slam), 0, 0.2),
	}
end

-- Boss Oh 360-deg plasma nova charge: plants wide and throws both arms out exposing the chest reactor.
function EnemyAnim.bossNovaWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local vibe = math.sin(clock * 38) * 0.06 * p
	return {
		torso = CFrame.new(vibe, -0.18 * p, 0.15 * p) * CFrame.Angles(0.28 * p, vibe, 0),
		head = CFrame.Angles(-0.32 * p, -vibe, 0),
		leftLeg = CFrame.Angles(0.28 * p, 0, -0.24 * p),
		rightLeg = CFrame.Angles(0.28 * p, 0, 0.24 * p),
		leftArm = CFrame.Angles(0.35 * p, 0.55 * p, -1.25 * p),
		rightArm = CFrame.Angles(0.35 * p, -0.55 * p, 1.25 * p),
	}
end

-- Artillero (`area`) mortar launch windup: drops into a braced artillery crouch tilting dorsal
-- mortar tubes skyward while targeting on its left holo-gauntlet.
function EnemyAnim.areaWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local hum = math.sin(clock * 30) * 0.035 * p
	return {
		torso = CFrame.new(0, -0.22 * p, 0.1 * p) * CFrame.Angles(-0.22 * p, hum, 0),
		head = CFrame.Angles(0.18 * p, -hum, 0),
		leftLeg = CFrame.Angles(0.34 * p, 0, -0.14 * p),
		rightLeg = CFrame.Angles(-0.28 * p, 0, 0.14 * p),
		leftArm = CFrame.Angles(0.55 * p, 0.35 * p, -0.18 * p),
		rightArm = CFrame.Angles(0.25 * p, -0.18 * p, 0.28 * p),
	}
end

-- Voltaico (`contact`) electric surge windup: hunches tightly while flaring both Tesla arms out
-- and vibrating rapidly as voltage builds around its coils.
function EnemyAnim.contactWindupPose(progress: number, clock: number): LimbPose
	local p = easeOutCubic(progress)
	local buzz = math.sin(clock * 46) * 0.06 * p
	return {
		torso = CFrame.new(buzz * 0.4, -0.26 * p, 0) * CFrame.Angles(-0.18 * p, buzz, buzz * 0.5),
		head = CFrame.Angles(0.16 * p, -buzz, 0),
		leftLeg = CFrame.Angles(0.32 * p, 0, -0.18 * p),
		rightLeg = CFrame.Angles(0.32 * p, 0, 0.18 * p),
		leftArm = CFrame.Angles(0.22 * p + buzz, 0.48 * p, -0.95 * p),
		rightArm = CFrame.Angles(0.22 * p - buzz, -0.48 * p, 0.95 * p),
	}
end

-- Voltaico (`contact`) active high-voltage surge: aggressive crackling charge stride with arms
-- spread wide emitting live arcs.
function EnemyAnim.contactActivePose(phase: number, clock: number): LimbPose
	local stride = math.sin(phase * 1.55)
	local buzz = math.sin(clock * 42) * 0.05
	return {
		torso = CFrame.new(buzz * 0.35, -0.16, -0.14) * CFrame.Angles(-0.3, stride * 0.14 + buzz, -stride * 0.07),
		head = CFrame.Angles(0.24, -stride * 0.1 - buzz, 0),
		leftLeg = CFrame.Angles(stride * 0.78, 0, -0.1),
		rightLeg = CFrame.Angles(-stride * 0.78, 0, 0.1),
		leftArm = CFrame.Angles(0.18 + buzz, 0.36, -0.92),
		rightArm = CFrame.Angles(0.18 - buzz, -0.36, 0.92),
	}
end

-- Dazed stagger pose while stunned (Tank war cry, Support shockwave, heavy slams).
function EnemyAnim.stunPose(clock: number): LimbPose
	local sway = math.sin(clock * 5.2)
	local wobble = math.cos(clock * 7.4)
	return {
		torso = CFrame.new(sway * 0.12, -0.22, 0.1) * CFrame.Angles(-0.24 + wobble * 0.06, sway * 0.14, sway * 0.12),
		head = CFrame.Angles(-0.28 + wobble * 0.1, -sway * 0.28, sway * 0.18),
		leftLeg = CFrame.Angles(0.24, 0, -0.14),
		rightLeg = CFrame.Angles(-0.22, 0, 0.14),
		leftArm = CFrame.Angles(-0.22 + wobble * 0.14, 0, -0.3 - sway * 0.12),
		rightArm = CFrame.Angles(-0.22 - wobble * 0.14, 0, 0.3 - sway * 0.12),
	}
end

-- Flinch / stagger pose while an enemy is in `hitstun`: snaps violently backward on impact with
-- arms flung wide and head recoiling, alternating twist direction per hit (`hitSeed`), then
-- trembles and slowly recovers upright.
function EnemyAnim.hitstunPose(progress: number, hitSeed: number?): LimbPose
	local u = clamp01(progress)
	local snap = if u < 0.22 then easeOutCubic(u / 0.22) else 1 - easeInOutQuad((u - 0.22) / 0.78) * 0.72
	local dir = if ((hitSeed or 1) % 2 == 1) then 1 else -1
	local shiver = math.sin(u * math.pi * 6) * 0.06 * (1 - u)
	return {
		torso = CFrame.new(0, -0.14 * snap, 0.26 * snap) * CFrame.Angles(0.36 * snap, dir * 0.34 * snap + shiver, dir * 0.12 * snap),
		head = CFrame.new(0, -0.10 * snap, 0.18 * snap) * CFrame.Angles(0.32 * snap, -dir * 0.28 * snap, -dir * 0.14 * snap),
		leftLeg = CFrame.Angles(0.26 * snap, 0, -0.14 * snap),
		rightLeg = CFrame.Angles(-0.32 * snap, 0, 0.14 * snap),
		leftArm = CFrame.Angles(0.45 * snap, 0.55 * snap, -0.58 * snap),
		rightArm = CFrame.Angles(0.45 * snap, -0.55 * snap, 0.58 * snap),
	}
end

-- Death collapse pose (`progress` in [0, 1]): returns `(rootDelta, limbPose, fadeAlpha)`.
-- Knocks the unit backward onto the floor with splayed limbs, then fades out cleanly.
function EnemyAnim.deathPose(progress: number): (CFrame, LimbPose, number)
	local u = clamp01(progress)
	local fall = easeOutCubic(math.min(u / 0.62, 1))
	local rootDelta = CFrame.new(0, lerpNumber(0, -1.55, fall), lerpNumber(0, 1.75, fall))
		* CFrame.Angles(lerpNumber(0, 1.45, fall), 0, lerpNumber(0, 0.22, fall))

	local limbs: LimbPose = {
		torso = CFrame.Angles(0.15 * fall, 0, 0),
		head = CFrame.Angles(0.42 * fall, 0.18 * fall, 0),
		leftLeg = CFrame.Angles(-0.42 * fall, 0, -0.16 * fall),
		rightLeg = CFrame.Angles(-0.18 * fall, 0, 0.2 * fall),
		leftArm = CFrame.Angles(0.95 * fall, 0, -0.68 * fall),
		rightArm = CFrame.Angles(1.15 * fall, 0, 0.68 * fall),
	}

	local fadeAlpha = if u <= 0.55 then 0 elseif u >= 1 then 1 else clamp01((u - 0.55) / 0.45)
	return rootDelta, limbs, fadeAlpha
end

--=============================================================================
-- Self test
--=============================================================================

function EnemyAnim.selfTest()
	-- Walk cycle drives opposite legs cleanly and differs from idle.
	local walkA = EnemyAnim.walkPose(math.pi * 0.5, 1, "sword")
	local walkB = EnemyAnim.walkPose(math.pi * 1.5, 1, "sword")
	assert(walkA.leftLeg ~= walkA.rightLeg, "walk stride separates left and right legs")
	assert(walkA.leftLeg ~= walkB.leftLeg, "walk cycle oscillates across phase")

	-- Every weapon variant produces a distinct attack windup and follow-through.
	local wSword = EnemyAnim.windupPose(1, "sword")
	local wDual = EnemyAnim.windupPose(1, "dual")
	local wAxe = EnemyAnim.windupPose(1, "axe")
	local wMace = EnemyAnim.windupPose(1, "mace")
	assert(wSword.leftArm ~= wDual.leftArm, "dual blades raise off-hand weapon differently from sword")
	assert(wSword.rightArm ~= wAxe.rightArm, "axe windup differs from sword")
	assert(wAxe.rightArm ~= wMace.rightArm, "mace overhead windup differs from axe")

	local sStart = EnemyAnim.strikePose(0, "mace")
	local sImpact = EnemyAnim.strikePose(0.45, "mace")
	assert(sStart.rightArm ~= sImpact.rightArm, "strike sweeps weapon from windup to impact")

	-- Every melee weapon strike must drive the weapon tip strictly FORWARD (`-Z`), never backward behind the body.
	local restTip = Vector3.new(0.3, -1.2, -4.0)
	for _, w in ipairs({ "sword", "dual", "axe", "mace" }) do
		local hitPose = EnemyAnim.strikePose(0.45, w)
		local tip = hitPose.rightArm:PointToWorldSpace(restTip)
		assert(tip.Z < -1.5, `strikePose({w}) must strike forward (-Z), got Z={tip.Z}`)
	end

	-- Death collapses downward/backward and fades to 1 at the end.
	local root0, _, fade0 = EnemyAnim.deathPose(0)
	local root1, limbs1, fade1 = EnemyAnim.deathPose(1)
	assert(root1.Position.Y < root0.Position.Y - 1, "death collapse drops body toward floor")
	assert(root1.Position.Z > root0.Position.Z + 1, "death collapse knocks body backward")
	assert(limbs1.rightArm ~= CFrame.identity and fade0 == 0 and fade1 == 1, "death splays limbs and fades out")

	-- Dual-blade tornado spin rotates the whole body cleanly via `root` rather than spinning
	-- each limb independently around its own shoulder/hip pivot.
	local spA = EnemyAnim.spinPose(0)
	local spB = EnemyAnim.spinPose(0.1)
	assert(spA.root ~= nil and spB.root ~= nil and spA.root ~= spB.root, "dual spin rotates whole body via root")
	assert(spA.leftLeg == spB.leftLeg and spA.rightLeg == spB.rightLeg, "dual spin keeps legs braced instead of spinning in place")
	assert(spA.leftArm == spB.leftArm and spA.rightArm == spB.rightArm, "dual spin holds blades wide instead of helicoptering arms")
	local ps = EnemyAnim.phantomStepPose()
	assert(ps.torso.Position.Y < -0.2 and ps.rightArm ~= CFrame.identity, "phantom step leans forward in dash pose")
	local slm = EnemyAnim.slamWindupPose(0.9, 1.0)
	assert(slm.torso.Position.Y > 0.1 and slm.rightArm ~= CFrame.identity and slm.leftArm ~= CFrame.identity, "mace slam windup hoists arms high overhead")
	local bm = EnemyAnim.beamChargePose(1.2, 0.9)
	assert(bm.leftLeg ~= CFrame.identity and bm.torso.Position.Z > 0.05, "beam charge braces torso and legs")
	local ev = EnemyAnim.evadeJumpPose(0.5)
	assert(ev.leftLeg ~= CFrame.identity and ev.torso ~= CFrame.identity, "evade jump tucks legs and leans back mid-air")
	local rKick = EnemyAnim.firePose(0.2, "shotgun")
	assert(rKick.rightArm ~= CFrame.identity and rKick.torso.Position.Z > 0.2, "ranged fire kicks weapon and torso back strongly")
	local axeWind = EnemyAnim.axeThrowWindupPose(1, 0.5)
	local axeRet = EnemyAnim.axeRetrievePose(1.2)
	assert(axeWind.rightArm ~= CFrame.identity and axeRet.leftLeg ~= axeRet.rightLeg, "axe throw windup and unarmed retrieve poses work")
	local fPose = EnemyAnim.fusePose(1.5, 0.8)
	assert(fPose.leftArm ~= CFrame.identity and fPose.rightArm ~= CFrame.identity, "exploder fuse raises arms while trembling")
	local gWind = EnemyAnim.grabWindupPose(1)
	local gLunge = EnemyAnim.grabLungePose()
	local gHoldA = EnemyAnim.grabHoldPose(0)
	local gHoldB = EnemyAnim.grabHoldPose(0.2)
	assert(gWind.leftArm ~= gLunge.leftArm and gLunge.torso.Position.Z < -0.1, "grabber lunge leans forward reaching out")
	local rWind = EnemyAnim.rushWindupPose(1, 0)
	assert(rWind.torso.Position.Y < -0.3, "rush windup drops low")
	assert(rWind.torso ~= gWind.torso and rWind.leftArm ~= gWind.leftArm, "rush windup reads differently from the grab windup")
	assert(EnemyAnim.rushPose(0).torso.Position.Z < -0.1, "the rush leans into the charge")
	assert(EnemyAnim.rushPose(0).leftLeg ~= EnemyAnim.rushPose(0.07).leftLeg, "the rush legs keep striding")
	assert(gHoldA.leftArm ~= gHoldB.leftArm, "grabber hold pulses squeezing arms continuously")
	local stA = EnemyAnim.stunPose(0)
	local stB = EnemyAnim.stunPose(0.25)
	assert(stA.head ~= stB.head and stA.torso.Position.Y < -0.1, "stun pose hunches and sways dazedly")
	assert(EnemyAnim.bossConeWindupPose(1, 0).rightArm ~= CFrame.identity, "boss cone windup hoists maul")
	assert(EnemyAnim.bossLeapWindupPose(1, 0).torso.Position.Y < -0.5, "boss leap windup crouches low")
	assert(EnemyAnim.bossLeapAirPose(0.2).rightArm ~= EnemyAnim.bossLeapAirPose(0.95).rightArm, "boss leap air transitions to slam")
	assert(EnemyAnim.bossNovaWindupPose(1, 0).leftArm ~= CFrame.identity, "boss nova spreads arms wide")
	assert(EnemyAnim.areaWindupPose(1, 0.2).torso.Position.Y < -0.1, "area mortar windup braces low")
	assert(EnemyAnim.contactWindupPose(1, 0.2).leftArm ~= CFrame.identity, "contact surge windup flares Tesla arms")
	local caA = EnemyAnim.contactActivePose(0, 0)
	local caB = EnemyAnim.contactActivePose(1.0, 0.2)
	assert(caA.leftLeg ~= caB.leftLeg and caA.torso.Position.Z < -0.05, "contact active surge strides forward aggressively")

	local hs1 = EnemyAnim.hitstunPose(0.2, 1)
	local hs2 = EnemyAnim.hitstunPose(0.2, 2)
	assert(hs1.torso.Position.Z > 0.1 and hs1.torso ~= hs2.torso, "hitstun reels enemy backward and alternates twist per hit")

	for _, name in ipairs(GROUPS) do
		assert((walkA :: any)[name] ~= nil, `walk pose must include {name}`)
	end
end

return EnemyAnim
