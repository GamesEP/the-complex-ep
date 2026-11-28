--!strict
--[[
	Generates tracked 3D `.rbxmx` model assets under `assets/models/` using Lune (`@lune/roblox`).

	Run whenever a model definition here changes:
		lune run scripts/generate-models.luau

	Models live as `.rbxmx` assets mounted by `default.project.json` and `:Clone()`d at runtime
	rather than constructed part-by-part with `Instance.new` (CLAUDE.md). Every model stamps an
	explicit `PrimaryPart` and `WorldPivot` so placement and attachment are deterministic.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local Color3 = roblox.Color3
local Enum = roblox.Enum

local OUT_DIR = "assets/models"

local function makePart(props: {
	name: string,
	size: any,
	cframe: any,
	color: any,
	material: any?,
	transparency: number?,
	shape: any?,
	anchored: boolean,
	castShadow: boolean?,
}): any
	local part = Instance.new("Part")
	part.Name = props.name
	part.Size = props.size
	part.CFrame = props.cframe
	part.Color = props.color
	part.Material = props.material or Enum.Material.SmoothPlastic
	part.Transparency = props.transparency or 0
	if props.shape then
		part.Shape = props.shape
	end
	part.Anchored = props.anchored
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = not props.anchored
	part.CastShadow = if props.castShadow ~= nil then props.castShadow else false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function weld(part0: any, part1: any)
	local constraint = Instance.new("WeldConstraint")
	constraint.Name = `Weld_{part1.Name}`
	constraint.Part0 = part0
	constraint.Part1 = part1
	constraint.Parent = part0
end

-- Connects a non-anchored enemy limb part to its anchored `Body` root via a Motor6D whose `C0`
-- sits at the anatomical joint pivot (`pivot`, in Body-local space). Modifying `motor.C0` on the
-- client (`restC0 * animDelta`) rotates every part sharing the same `group` rigidly around the
-- shoulder/hip/neck pivot at 60 FPS without Humanoid overhead or server replication jitter.
local function rigJoint(root: any, part: any, pivot: any, group: string)
	local motor = Instance.new("Motor6D")
	motor.Name = `Joint_{part.Name}`
	motor.Part0 = root
	motor.Part1 = part
	motor.C0 = pivot
	motor.C1 = part.CFrame:Inverse() * pivot
	motor:SetAttribute("Group", group)
	motor.Parent = root
end

local function addLight(parent: any, color: any)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 12
	light.Brightness = 1.6
	light.Shadows = false
	light.Parent = parent
end

local function writeModel(fileName: string, model: any)
	if not fs.isDir(OUT_DIR) then
		fs.writeDir(OUT_DIR)
	end
	local xml = roblox.serializeModel({ model }, true)
	local path = `{OUT_DIR}/{fileName}`
	fs.writeFile(path, xml)
	print(`wrote {path} ({#xml} bytes)`)
end

-- Test sword equipped in the player's right hand. Grip sits at the origin with the blade extending
-- along -Z; CombatService mounts it pitched forward by `Config.SWORD_GRIP_PITCH` so the blade is
-- held out in front rather than hanging along the forearm.
--
-- Scaled by SWORD_SCALE as a whole. At full size (5.4 studs) the blade reached 2 studs *under* the
-- floor in idle, because the right hand of an R15 character rests only ~2 studs up; 0.8 together
-- with the grip pitch keeps the tip above the floor through idle, walking and the combo.
local SWORD_SCALE = 0.8

local function buildTestSword(): any
	local model = Instance.new("Model")
	model.Name = "TestSword"

	local function size(x: number, y: number, z: number): any
		return Vector3.new(x, y, z) * SWORD_SCALE
	end
	local function at(z: number): any
		return CFrame.new(0, 0, z * SWORD_SCALE)
	end

	local grip = makePart({
		name = "Grip",
		size = size(0.26, 0.26, 1.15),
		cframe = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(40, 44, 54),
		material = Enum.Material.SmoothPlastic,
		anchored = false,
	})
	grip.Parent = model

	local parts = {
		makePart({
			name = "Pommel",
			size = size(0.42, 0.42, 0.42),
			cframe = at(0.65),
			color = Color3.fromRGB(220, 185, 95),
			material = Enum.Material.Metal,
			shape = Enum.PartType.Ball,
			anchored = false,
		}),
		makePart({
			name = "Guard",
			size = size(1.45, 0.28, 0.34),
			cframe = at(-0.62),
			color = Color3.fromRGB(230, 195, 105),
			material = Enum.Material.Metal,
			anchored = false,
			castShadow = true,
		}),
		makePart({
			name = "Blade",
			size = size(0.42, 0.14, 3.6),
			cframe = at(-2.55),
			color = Color3.fromRGB(215, 225, 240),
			material = Enum.Material.Metal,
			anchored = false,
			castShadow = true,
		}),
		makePart({
			name = "BladeCore",
			size = size(0.16, 0.18, 3.2),
			cframe = at(-2.45),
			color = Color3.fromRGB(115, 210, 255),
			material = Enum.Material.Neon,
			anchored = false,
		}),
		makePart({
			name = "BladeTip",
			size = size(0.32, 0.13, 0.65),
			cframe = at(-4.45) * CFrame.Angles(0, math.rad(45), 0),
			color = Color3.fromRGB(215, 225, 240),
			material = Enum.Material.Metal,
			anchored = false,
			castShadow = true,
		}),
	}

	for _, part in ipairs(parts) do
		part.Parent = model
		weld(grip, part)
	end

	model.PrimaryPart = grip
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Class weapons (plans/gdd/systems.md, "Clases"). Same convention as the test sword: `Grip` at the
-- origin, the weapon extending along -Z. CombatService welds `Grip` to a hand's grip attachment
-- turned by the model's `GripPitch` / `GripYaw` / `GripRoll` attributes (degrees), so each weapon
-- carries the way it is held instead of a table of angles in code.
local function assembleWeapon(name: string, grip: any, parts: { any }, pitch: number, yaw: number?, roll: number?): any
	local model = Instance.new("Model")
	model.Name = name
	grip.Parent = model
	for _, part in ipairs(parts) do
		part.Parent = model
		weld(grip, part)
	end
	model.PrimaryPart = grip
	model.WorldPivot = CFrame.new(0, 0, 0)
	model:SetAttribute("GripPitch", pitch)
	model:SetAttribute("GripYaw", yaw or 0)
	model:SetAttribute("GripRoll", roll or 0)
	return model
end

local STEEL = Color3.fromRGB(205, 214, 228)
local GUNMETAL = Color3.fromRGB(68, 76, 90)
local DARK = Color3.fromRGB(36, 40, 50)
local GOLD = Color3.fromRGB(230, 190, 95)
local HAZARD_YELLOW = Color3.fromRGB(245, 196, 0)
local TANK_BLUE = Color3.fromRGB(85, 195, 255)
local TANK_ARMOR = Color3.fromRGB(58, 82, 132)
local DPS_CRIMSON = Color3.fromRGB(255, 65, 115)
local SUPPORT_MINT = Color3.fromRGB(75, 245, 160)

-- Tank (legacy model kept for reference/fallbacks): heavy greatsword.
local function buildGreatsword(): any
	local grip = makePart({ name = "Grip", size = Vector3.new(0.3, 0.3, 1.1), cframe = CFrame.new(0, 0, 0), color = DARK, anchored = false })
	return assembleWeapon("WeaponGreatsword", grip, {
		makePart({ name = "Pommel", size = Vector3.new(0.42, 0.42, 0.42), cframe = CFrame.new(0, 0, 0.62), color = GOLD, material = Enum.Material.Metal, shape = Enum.PartType.Ball, anchored = false }),
		makePart({ name = "Guard", size = Vector3.new(1.7, 0.32, 0.36), cframe = CFrame.new(0, 0, -0.6), color = GOLD, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "Blade", size = Vector3.new(0.62, 0.18, 2.9), cframe = CFrame.new(0, 0, -2.2), color = STEEL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "BladeCore", size = Vector3.new(0.2, 0.22, 2.5), cframe = CFrame.new(0, 0, -2.1), color = TANK_BLUE, material = Enum.Material.Neon, anchored = false }),
		makePart({ name = "BladeTip", size = Vector3.new(0.44, 0.17, 0.55), cframe = CFrame.new(0, 0, -3.78) * CFrame.Angles(0, math.rad(45), 0), color = STEEL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
	}, 70)
end

-- Tank: heavy industrial spiked war-mace (replaces the greatsword). Keeps total reach ~3.75 studs
-- so it clears the floor at rest and during dashes, with a banded steel haft, flanged armored head,
-- glowing blue kinetic core rings, 8 radial steel spikes, and a heavy crown spike.
local function buildSpikedMace(): any
	local grip = makePart({
		name = "Grip",
		size = Vector3.new(0.28, 0.28, 1.05),
		cframe = CFrame.new(0, 0, 0),
		color = DARK,
		material = Enum.Material.SmoothPlastic,
		anchored = false,
	})
	local parts: { any } = {
		-- Pommel & grip wrap bands.
		makePart({ name = "PommelCap", size = Vector3.new(0.44, 0.44, 0.28), cframe = CFrame.new(0, 0, 0.58), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "PommelSpike", size = Vector3.new(0.22, 0.22, 0.34), cframe = CFrame.new(0, 0, 0.8) * CFrame.Angles(0, 0, math.rad(45)), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "GripBand1", size = Vector3.new(0.32, 0.32, 0.14), cframe = CFrame.new(0, 0, 0.24), color = GUNMETAL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "GripBand2", size = Vector3.new(0.32, 0.32, 0.14), cframe = CFrame.new(0, 0, -0.24), color = GUNMETAL, material = Enum.Material.Metal, anchored = false }),
		-- Guard collar & reinforced heavy shaft.
		makePart({ name = "CollarGuard", size = Vector3.new(0.56, 0.56, 0.24), cframe = CFrame.new(0, 0, -0.58) * CFrame.Angles(0, 0, math.rad(45)), color = GOLD, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "Shaft", size = Vector3.new(0.26, 0.26, 1.9), cframe = CFrame.new(0, 0, -1.55), color = GUNMETAL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "ShaftConduit", size = Vector3.new(0.3, 0.12, 1.55), cframe = CFrame.new(0, 0, -1.55), color = TANK_BLUE, material = Enum.Material.Neon, anchored = false }),
		makePart({ name = "ShaftBrace1", size = Vector3.new(0.36, 0.36, 0.18), cframe = CFrame.new(0, 0, -1.15), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "ShaftBrace2", size = Vector3.new(0.36, 0.36, 0.18), cframe = CFrame.new(0, 0, -1.9), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		-- Heavy multi-layered armored mace head (centered at z = -2.65).
		makePart({ name = "HeadNeck", size = Vector3.new(0.62, 0.62, 0.34), cframe = CFrame.new(0, 0, -2.18) * CFrame.Angles(0, 0, math.rad(45)), color = TANK_ARMOR, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "HeadCoreA", size = Vector3.new(0.98, 0.98, 1.05), cframe = CFrame.new(0, 0, -2.72), color = TANK_ARMOR, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "HeadCoreB", size = Vector3.new(0.98, 0.98, 1.05), cframe = CFrame.new(0, 0, -2.72) * CFrame.Angles(0, 0, math.rad(45)), color = GUNMETAL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "HeadBandRear", size = Vector3.new(1.08, 1.08, 0.18), cframe = CFrame.new(0, 0, -2.32) * CFrame.Angles(0, 0, math.rad(45)), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "HeadBandFront", size = Vector3.new(1.08, 1.08, 0.18), cframe = CFrame.new(0, 0, -3.12) * CFrame.Angles(0, 0, math.rad(45)), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "HeadEnergyCore", size = Vector3.new(1.12, 1.12, 0.24), cframe = CFrame.new(0, 0, -2.72) * CFrame.Angles(0, 0, math.rad(22.5)), color = TANK_BLUE, material = Enum.Material.Neon, anchored = false }),
		makePart({ name = "HeadCrown", size = Vector3.new(0.68, 0.68, 0.22), cframe = CFrame.new(0, 0, -3.28) * CFrame.Angles(0, 0, math.rad(45)), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		-- Heavy forward crown spike.
		makePart({ name = "CrownSpikeBase", size = Vector3.new(0.32, 0.32, 0.3), cframe = CFrame.new(0, 0, -3.48) * CFrame.Angles(0, 0, math.rad(45)), color = STEEL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "CrownSpikeTip", size = Vector3.new(0.16, 0.16, 0.36), cframe = CFrame.new(0, 0, -3.72) * CFrame.Angles(0, 0, math.rad(45)), color = STEEL, material = Enum.Material.Metal, anchored = false }),
	}

	-- 8 staggered radial steel spikes (4 primary mid-ring + 4 angled front-ring).
	for i = 0, 3 do
		local a1 = math.rad(i * 90)
		local r1 = CFrame.new(0, 0, -2.72) * CFrame.Angles(0, 0, a1)
		table.insert(parts, makePart({
			name = `SpikeMidBase_{i + 1}`,
			size = Vector3.new(0.26, 0.34, 0.26),
			cframe = r1 * CFrame.new(0, 0.66, 0) * CFrame.Angles(0, math.rad(45), 0),
			color = STEEL,
			material = Enum.Material.Metal,
			anchored = false,
			castShadow = true,
		}))
		table.insert(parts, makePart({
			name = `SpikeMidTip_{i + 1}`,
			size = Vector3.new(0.14, 0.36, 0.14),
			cframe = r1 * CFrame.new(0, 0.92, 0) * CFrame.Angles(0, math.rad(45), 0),
			color = STEEL,
			material = Enum.Material.Metal,
			anchored = false,
		}))

		local a2 = math.rad(i * 90 + 45)
		local r2 = CFrame.new(0, 0, -3.02) * CFrame.Angles(0, 0, a2)
		table.insert(parts, makePart({
			name = `SpikeFrontBase_{i + 1}`,
			size = Vector3.new(0.22, 0.28, 0.22),
			cframe = r2 * CFrame.new(0, 0.62, -0.08) * CFrame.Angles(math.rad(-22), math.rad(45), 0),
			color = STEEL,
			material = Enum.Material.Metal,
			anchored = false,
		}))
		table.insert(parts, makePart({
			name = `SpikeFrontTip_{i + 1}`,
			size = Vector3.new(0.12, 0.3, 0.12),
			cframe = r2 * CFrame.new(0, 0.84, -0.18) * CFrame.Angles(math.rad(-22), math.rad(45), 0),
			color = STEEL,
			material = Enum.Material.Metal,
			anchored = false,
		}))
	end

	return assembleWeapon("WeaponSpikedMace", grip, parts, 70)
end

-- Tank: detailed industrial armored tower shield for the left forearm (layered steel plates,
-- gold-trimmed perimeter frame, corner rivets, hazard accent, and glowing kinetic emitter core).
local function buildShield(): any
	local grip = makePart({ name = "Grip", size = Vector3.new(0.22, 0.22, 0.72), cframe = CFrame.new(0, 0, 0), color = DARK, anchored = false })
	return assembleWeapon("WeaponShield", grip, {
		-- Forearm strap & rear mounting bracket.
		makePart({ name = "ArmBrace", size = Vector3.new(0.16, 0.95, 0.95), cframe = CFrame.new(-0.14, 0, -0.25), color = GUNMETAL, material = Enum.Material.Metal, anchored = false }),
		-- Main layered armored plates (tapered kite/tower silhouette along Y/Z).
		makePart({ name = "PlateMain", size = Vector3.new(0.22, 2.35, 1.85), cframe = CFrame.new(-0.28, 0.05, -0.35), color = TANK_ARMOR, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "PlateOuter", size = Vector3.new(0.14, 1.85, 1.38), cframe = CFrame.new(-0.4, 0.05, -0.35), color = GUNMETAL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "PlateTip", size = Vector3.new(0.2, 0.95, 0.95), cframe = CFrame.new(-0.28, -1.18, -0.35) * CFrame.Angles(math.rad(45), 0, 0), color = TANK_ARMOR, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		-- Heavy armored perimeter frame.
		makePart({ name = "RimTop", size = Vector3.new(0.3, 0.2, 2.02), cframe = CFrame.new(-0.29, 1.24, -0.35), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RimFront", size = Vector3.new(0.3, 2.42, 0.18), cframe = CFrame.new(-0.29, 0.05, -1.3), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RimBack", size = Vector3.new(0.3, 2.42, 0.18), cframe = CFrame.new(-0.29, 0.05, 0.6), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RimBottomA", size = Vector3.new(0.28, 0.18, 1.05), cframe = CFrame.new(-0.29, -1.36, -0.78) * CFrame.Angles(math.rad(38), 0, 0), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RimBottomB", size = Vector3.new(0.28, 0.18, 1.05), cframe = CFrame.new(-0.29, -1.36, 0.08) * CFrame.Angles(math.rad(-38), 0, 0), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		-- Industrial hazard trim & twin vertical energy conduits.
		makePart({ name = "HazardStripe", size = Vector3.new(0.16, 0.22, 1.5), cframe = CFrame.new(-0.42, 0.92, -0.35), color = HAZARD_YELLOW, material = Enum.Material.SmoothPlastic, anchored = false }),
		makePart({ name = "EnergyBarTop", size = Vector3.new(0.14, 0.52, 0.16), cframe = CFrame.new(-0.46, 0.52, -0.35), color = TANK_BLUE, material = Enum.Material.Neon, anchored = false }),
		makePart({ name = "EnergyBarBot", size = Vector3.new(0.14, 0.62, 0.16), cframe = CFrame.new(-0.46, -0.52, -0.35), color = TANK_BLUE, material = Enum.Material.Neon, anchored = false }),
		-- Central reinforced emitter boss + 4 corner steel rivets.
		makePart({ name = "BossHousing", size = Vector3.new(0.24, 0.72, 0.72), cframe = CFrame.new(-0.46, 0.02, -0.35) * CFrame.Angles(math.rad(45), 0, 0), color = STEEL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "BossCore", size = Vector3.new(0.32, 0.42, 0.42), cframe = CFrame.new(-0.52, 0.02, -0.35), color = TANK_BLUE, material = Enum.Material.Neon, shape = Enum.PartType.Ball, anchored = false }),
		makePart({ name = "RivetTL", size = Vector3.new(0.18, 0.16, 0.16), cframe = CFrame.new(-0.44, 0.82, -1.0), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RivetTR", size = Vector3.new(0.18, 0.16, 0.16), cframe = CFrame.new(-0.44, 0.82, 0.3), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RivetBL", size = Vector3.new(0.18, 0.16, 0.16), cframe = CFrame.new(-0.44, -0.78, -1.0), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RivetBR", size = Vector3.new(0.18, 0.16, 0.16), cframe = CFrame.new(-0.44, -0.78, 0.3), color = STEEL, material = Enum.Material.Metal, anchored = false }),
	}, 70, 0, 0)
end

-- Damage: detailed tactical cyber-dagger (one in each hand) with swept guard wings, pommel ring,
-- dark spine, serrated ridge, razor steel edge, and crimson plasma core.
local function buildDagger(): any
	local grip = makePart({ name = "Grip", size = Vector3.new(0.2, 0.2, 0.72), cframe = CFrame.new(0, 0, 0), color = DARK, anchored = false })
	return assembleWeapon("WeaponDagger", grip, {
		makePart({ name = "PommelRing", size = Vector3.new(0.34, 0.12, 0.34), cframe = CFrame.new(0, 0, 0.46) * CFrame.Angles(0, math.rad(45), 0), color = GUNMETAL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "PommelGem", size = Vector3.new(0.16, 0.16, 0.16), cframe = CFrame.new(0, 0, 0.46), color = DPS_CRIMSON, material = Enum.Material.Neon, shape = Enum.PartType.Ball, anchored = false }),
		makePart({ name = "GuardCenter", size = Vector3.new(0.46, 0.22, 0.22), cframe = CFrame.new(0, 0, -0.4), color = Color3.fromRGB(130, 32, 48), material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "GuardWingL", size = Vector3.new(0.42, 0.14, 0.16), cframe = CFrame.new(-0.32, 0, -0.5) * CFrame.Angles(0, math.rad(-28), 0), color = GUNMETAL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "GuardWingR", size = Vector3.new(0.42, 0.14, 0.16), cframe = CFrame.new(0.32, 0, -0.5) * CFrame.Angles(0, math.rad(28), 0), color = GUNMETAL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "Spine", size = Vector3.new(0.14, 0.14, 1.48), cframe = CFrame.new(0.08, 0, -1.2), color = GUNMETAL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "Blade", size = Vector3.new(0.32, 0.09, 1.55), cframe = CFrame.new(-0.02, 0, -1.24), color = STEEL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "PlasmaEdge", size = Vector3.new(0.11, 0.11, 1.45), cframe = CFrame.new(-0.14, 0, -1.24), color = DPS_CRIMSON, material = Enum.Material.Neon, anchored = false }),
		makePart({ name = "BladeTip", size = Vector3.new(0.24, 0.09, 0.42), cframe = CFrame.new(-0.02, 0, -2.1) * CFrame.Angles(0, math.rad(35), 0), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "TipGlow", size = Vector3.new(0.1, 0.1, 0.28), cframe = CFrame.new(-0.08, 0, -2.14) * CFrame.Angles(0, math.rad(35), 0), color = DPS_CRIMSON, material = Enum.Material.Neon, anchored = false }),
	}, 70)
end

-- Support: detailed sci-fi energy conduit staff held upright (pitched past vertical so the floating
-- plasma emitter orb sits above the head, framed by angled metallic prongs and conduit rings).
local function buildStaff(): any
	local grip = makePart({ name = "Grip", size = Vector3.new(0.26, 0.26, 0.9), cframe = CFrame.new(0, 0, 0), color = DARK, anchored = false })
	return assembleWeapon("WeaponStaff", grip, {
		makePart({ name = "Shaft", size = Vector3.new(0.22, 0.22, 3.65), cframe = CFrame.new(0, 0, -0.88), color = GUNMETAL, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "ConduitVein", size = Vector3.new(0.26, 0.09, 2.5), cframe = CFrame.new(0, 0, -1.35), color = SUPPORT_MINT, material = Enum.Material.Neon, anchored = false }),
		makePart({ name = "BaseCap", size = Vector3.new(0.36, 0.36, 0.28), cframe = CFrame.new(0, 0, 0.98), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "BaseSpike", size = Vector3.new(0.18, 0.18, 0.32), cframe = CFrame.new(0, 0, 1.24) * CFrame.Angles(0, 0, math.rad(45)), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RingLower", size = Vector3.new(0.34, 0.34, 0.14), cframe = CFrame.new(0, 0, -0.58), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "RingUpper", size = Vector3.new(0.38, 0.38, 0.16), cframe = CFrame.new(0, 0, -2.18), color = GOLD, material = Enum.Material.Metal, anchored = false }),
		-- Sculpted emitter crown + 3 angled prongs cradling the floating plasma core.
		makePart({ name = "CrownBase", size = Vector3.new(0.68, 0.68, 0.36), cframe = CFrame.new(0, 0, -2.68) * CFrame.Angles(0, 0, math.rad(45)), color = GOLD, material = Enum.Material.Metal, anchored = false, castShadow = true }),
		makePart({ name = "Prong1", size = Vector3.new(0.14, 0.14, 0.85), cframe = CFrame.new(0, 0.38, -3.14) * CFrame.Angles(math.rad(-18), 0, 0), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "Prong2", size = Vector3.new(0.14, 0.14, 0.85), cframe = CFrame.new(-0.34, -0.22, -3.14) * CFrame.Angles(math.rad(12), math.rad(16), 0), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "Prong3", size = Vector3.new(0.14, 0.14, 0.85), cframe = CFrame.new(0.34, -0.22, -3.14) * CFrame.Angles(math.rad(12), math.rad(-16), 0), color = STEEL, material = Enum.Material.Metal, anchored = false }),
		makePart({ name = "OrbCore", size = Vector3.new(0.62, 0.62, 0.62), cframe = CFrame.new(0, 0, -3.26), color = Color3.fromRGB(220, 255, 240), material = Enum.Material.Neon, shape = Enum.PartType.Ball, anchored = false }),
		makePart({ name = "OrbHalo", size = Vector3.new(0.95, 0.95, 0.95), cframe = CFrame.new(0, 0, -3.26), color = SUPPORT_MINT, material = Enum.Material.ForceField, transparency = 0.25, shape = Enum.PartType.Ball, anchored = false }),
	}, 165)
end

-- Emerald glowing cross: instantly readable as a heal pickup from the isometric camera.
local function buildDropHeal(): any
	local model = Instance.new("Model")
	model.Name = "DropHeal"
	local green = Color3.fromRGB(80, 245, 130)

	local core = makePart({
		name = "Core",
		size = Vector3.new(0.65, 2.0, 0.65),
		cframe = CFrame.new(0, 0, 0),
		color = green,
		material = Enum.Material.Neon,
		anchored = true,
	})
	core.Parent = model
	addLight(core, green)

	local crossBar = makePart({
		name = "CrossBar",
		size = Vector3.new(2.0, 0.65, 0.65),
		cframe = CFrame.new(0, 0, 0),
		color = green,
		material = Enum.Material.Neon,
		anchored = true,
	})
	crossBar.Parent = model

	local aura = makePart({
		name = "Aura",
		size = Vector3.new(2.7, 2.7, 2.7),
		cframe = CFrame.new(0, 0, 0),
		color = green,
		material = Enum.Material.Neon,
		transparency = 0.75,
		shape = Enum.PartType.Ball,
		anchored = true,
	})
	aura.Parent = model

	model.PrimaryPart = core
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Fiery orange-red diamond crystal: damage boost pickup.
local function buildDropDamage(): any
	local model = Instance.new("Model")
	model.Name = "DropDamage"
	local orange = Color3.fromRGB(255, 95, 55)
	local gold = Color3.fromRGB(255, 190, 75)

	local core = makePart({
		name = "Core",
		size = Vector3.new(1.25, 1.25, 1.25),
		cframe = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45)),
		color = orange,
		material = Enum.Material.Neon,
		anchored = true,
	})
	core.Parent = model
	addLight(core, orange)

	local spike = makePart({
		name = "Spike",
		size = Vector3.new(0.55, 2.4, 0.55),
		cframe = CFrame.new(0, 0, 0),
		color = gold,
		material = Enum.Material.Neon,
		anchored = true,
	})
	spike.Parent = model

	local aura = makePart({
		name = "Aura",
		size = Vector3.new(2.7, 2.7, 2.7),
		cframe = CFrame.new(0, 0, 0),
		color = orange,
		material = Enum.Material.Neon,
		transparency = 0.75,
		shape = Enum.PartType.Ball,
		anchored = true,
	})
	aura.Parent = model

	model.PrimaryPart = core
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Electric cyan winged orb: movement speed boost pickup.
local function buildDropSpeed(): any
	local model = Instance.new("Model")
	model.Name = "DropSpeed"
	local cyan = Color3.fromRGB(70, 225, 255)
	local ice = Color3.fromRGB(190, 245, 255)

	local core = makePart({
		name = "Core",
		size = Vector3.new(1.35, 1.35, 1.35),
		cframe = CFrame.new(0, 0, 0),
		color = cyan,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
		anchored = true,
	})
	core.Parent = model
	addLight(core, cyan)

	local wingLeft = makePart({
		name = "WingLeft",
		size = Vector3.new(0.28, 1.35, 0.85),
		cframe = CFrame.new(-0.95, 0.15, 0) * CFrame.Angles(0, 0, math.rad(28)),
		color = ice,
		material = Enum.Material.Neon,
		anchored = true,
	})
	wingLeft.Parent = model

	local wingRight = makePart({
		name = "WingRight",
		size = Vector3.new(0.28, 1.35, 0.85),
		cframe = CFrame.new(0.95, 0.15, 0) * CFrame.Angles(0, 0, math.rad(-28)),
		color = ice,
		material = Enum.Material.Neon,
		anchored = true,
	})
	wingRight.Parent = model

	local aura = makePart({
		name = "Aura",
		size = Vector3.new(2.7, 2.7, 2.7),
		cframe = CFrame.new(0, 0, 0),
		color = cyan,
		material = Enum.Material.Neon,
		transparency = 0.75,
		shape = Enum.PartType.Ball,
		anchored = true,
	})
	aura.Parent = model

	model.PrimaryPart = core
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Royal blue & gold shield emblem: periodic 50% defense buff pickup.
local function buildDropDefense(): any
	local model = Instance.new("Model")
	model.Name = "DropDefense"
	local royal = Color3.fromRGB(75, 145, 255)
	local gold = Color3.fromRGB(255, 215, 95)

	local core = makePart({
		name = "Core",
		size = Vector3.new(1.65, 1.85, 0.45),
		cframe = CFrame.new(0, 0.1, 0),
		color = royal,
		material = Enum.Material.Neon,
		anchored = true,
	})
	core.Parent = model
	addLight(core, royal)

	local bottomTip = makePart({
		name = "BottomTip",
		size = Vector3.new(1.15, 1.15, 0.42),
		cframe = CFrame.new(0, -0.75, 0) * CFrame.Angles(0, 0, math.rad(45)),
		color = royal,
		material = Enum.Material.Neon,
		anchored = true,
	})
	bottomTip.Parent = model

	local trim = makePart({
		name = "Trim",
		size = Vector3.new(0.42, 2.05, 0.56),
		cframe = CFrame.new(0, -0.05, 0),
		color = gold,
		material = Enum.Material.Neon,
		anchored = true,
	})
	trim.Parent = model

	local crossTrim = makePart({
		name = "CrossTrim",
		size = Vector3.new(1.8, 0.38, 0.56),
		cframe = CFrame.new(0, 0.2, 0),
		color = gold,
		material = Enum.Material.Neon,
		anchored = true,
	})
	crossTrim.Parent = model

	local aura = makePart({
		name = "Aura",
		size = Vector3.new(2.9, 2.9, 2.9),
		cframe = CFrame.new(0, 0, 0),
		color = royal,
		material = Enum.Material.Neon,
		transparency = 0.74,
		shape = Enum.PartType.Ball,
		anchored = true,
	})
	aura.Parent = model

	model.PrimaryPart = core
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Shared sculpted industrial plasma battle-axe geometry used by BOTH `EnemyMeleeAxe` (rigged to
-- its right arm, with every part prefixed "Axe" so `EnemyAnimator` hides them while thrown) AND
-- the standalone `EnemyBattleAxe.rbxmx` projectile/dropped-weapon model.
--
-- Local space of `baseCF`: shaft runs along Z (pommel at +1.55, head at -1.25), crescent blade
-- sweeps toward -Y, rear armor-piercing war-pick spikes toward +Y.
local function addBattleAxeParts(
	addPart: (props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		transparency: number?,
		shape: any?,
		castShadow: boolean?,
	}) -> (),
	baseCF: any,
	palette: {
		chassis: any,
		steel: any,
		steelLight: any,
		armorDarkRed: any,
		hazard: any,
		bladeGlow: any,
	}
)
	local function localCF(cf: any): any
		return baseCF * cf
	end

	-- Reinforced cylindrical haft + pommel cap + grip bands + inlaid energy conduit.
	addPart({
		name = "AxeShaft",
		size = Vector3.new(3.65, 0.24, 0.24),
		cframe = localCF(CFrame.new(0, 0, 0.05) * CFrame.Angles(0, math.rad(90), 0)),
		color = palette.chassis,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
		castShadow = true,
	})
	addPart({
		name = "AxePommel",
		size = Vector3.new(0.28, 0.42, 0.42),
		cframe = localCF(CFrame.new(0, 0, 1.88) * CFrame.Angles(0, math.rad(90), 0)),
		color = palette.steel,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
		castShadow = true,
	})
	addPart({
		name = "AxePommelSpike",
		size = Vector3.new(0.22, 0.22, 0.34),
		cframe = localCF(CFrame.new(0, 0, 2.12) * CFrame.Angles(0, 0, math.rad(45))),
		color = palette.steelLight,
		material = Enum.Material.Metal,
	})
	addPart({
		name = "AxeGripBandA",
		size = Vector3.new(0.16, 0.32, 0.32),
		cframe = localCF(CFrame.new(0, 0, 1.15) * CFrame.Angles(0, math.rad(90), 0)),
		color = palette.hazard,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
	})
	addPart({
		name = "AxeGripBandB",
		size = Vector3.new(0.16, 0.32, 0.32),
		cframe = localCF(CFrame.new(0, 0, 0.35) * CFrame.Angles(0, math.rad(90), 0)),
		color = palette.steel,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
	})
	addPart({
		name = "AxeConduit",
		size = Vector3.new(0.28, 0.09, 2.15),
		cframe = localCF(CFrame.new(0, 0, -0.3)),
		color = palette.bladeGlow,
		material = Enum.Material.Neon,
	})

	-- Armored head socket collar + reinforced cheek plates + top cap finial.
	addPart({
		name = "AxeCollar",
		size = Vector3.new(0.46, 0.54, 0.92),
		cframe = localCF(CFrame.new(0, -0.02, -1.2)),
		color = palette.armorDarkRed,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addPart({
		name = "AxeCheekPlate",
		size = Vector3.new(0.52, 0.36, 0.56),
		cframe = localCF(CFrame.new(0, -0.14, -1.2) * CFrame.Angles(math.rad(45), 0, 0)),
		color = palette.steel,
		material = Enum.Material.Metal,
	})
	addPart({
		name = "AxeHeadFinial",
		size = Vector3.new(0.24, 0.24, 0.52),
		cframe = localCF(CFrame.new(0, 0, -1.92) * CFrame.Angles(0, 0, math.rad(45))),
		color = palette.steelLight,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Sculpted 3-part bearded crescent battle-axe head (tapered neck + swept upper horn + hooked beard).
	addPart({
		name = "AxeBladeNeck",
		size = Vector3.new(0.22, 0.85, 0.78),
		cframe = localCF(CFrame.new(0, -0.58, -1.22)),
		color = palette.steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addPart({
		name = "AxeBladeMid",
		size = Vector3.new(0.18, 0.78, 1.38),
		cframe = localCF(CFrame.new(0, -1.04, -1.26)),
		color = palette.steelLight,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addPart({
		name = "AxeBladeUpper",
		size = Vector3.new(0.17, 0.66, 0.88),
		cframe = localCF(CFrame.new(0, -0.88, -1.86) * CFrame.Angles(math.rad(-32), 0, 0)),
		color = palette.steelLight,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addPart({
		name = "AxeBladeBeard",
		size = Vector3.new(0.17, 0.72, 0.96),
		cframe = localCF(CFrame.new(0, -0.96, -0.56) * CFrame.Angles(math.rad(34), 0, 0)),
		color = palette.steelLight,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addPart({
		name = "AxeBladeFuller",
		size = Vector3.new(0.24, 0.22, 0.92),
		cframe = localCF(CFrame.new(0, -0.82, -1.24)),
		color = palette.armorDarkRed,
		material = Enum.Material.Metal,
	})

	-- Curved 3-segment glowing plasma cutting edge tracing the swept crescent arc.
	addPart({
		name = "AxeEdgeMid",
		size = Vector3.new(0.12, 0.24, 1.28),
		cframe = localCF(CFrame.new(0, -1.46, -1.26)),
		color = palette.bladeGlow,
		material = Enum.Material.Neon,
	})
	addPart({
		name = "AxeEdgeUpper",
		size = Vector3.new(0.12, 0.22, 0.98),
		cframe = localCF(CFrame.new(0, -1.2, -2.02) * CFrame.Angles(math.rad(-34), 0, 0)),
		color = palette.bladeGlow,
		material = Enum.Material.Neon,
	})
	addPart({
		name = "AxeEdgeLower",
		size = Vector3.new(0.12, 0.22, 1.02),
		cframe = localCF(CFrame.new(0, -1.26, -0.44) * CFrame.Angles(math.rad(34), 0, 0)),
		color = palette.bladeGlow,
		material = Enum.Material.Neon,
	})

	-- Rear curved armor-piercing war-pick spike with hazard trim.
	addPart({
		name = "AxePickTrim",
		size = Vector3.new(0.32, 0.22, 0.42),
		cframe = localCF(CFrame.new(0, 0.34, -1.16)),
		color = palette.hazard,
		material = Enum.Material.SmoothPlastic,
	})
	addPart({
		name = "AxePickBase",
		size = Vector3.new(0.2, 0.46, 0.42),
		cframe = localCF(CFrame.new(0, 0.58, -1.1) * CFrame.Angles(math.rad(18), 0, 0)),
		color = palette.steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addPart({
		name = "AxePickTip",
		size = Vector3.new(0.14, 0.56, 0.24),
		cframe = localCF(CFrame.new(0, 0.92, -0.94) * CFrame.Angles(math.rad(34), 0, 0)),
		color = palette.steelLight,
		material = Enum.Material.Metal,
	})
end

-- Standalone `.rbxmx` enemy battle-axe cloned by EnemyService when thrown or embedded on the floor.
local function buildEnemyBattleAxe(): any
	local model = Instance.new("Model")
	model.Name = "EnemyBattleAxe"

	local pivot = makePart({
		name = "Pivot",
		size = Vector3.new(0.2, 0.2, 0.2),
		cframe = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(255, 115, 40),
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	pivot.Parent = model

	addBattleAxeParts(function(props)
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			transparency = props.transparency,
			shape = props.shape,
			anchored = true,
			castShadow = props.castShadow,
		})
		p.Parent = model
	end, CFrame.new(0, 0.32, 0.42), {
		chassis = Color3.fromRGB(44, 48, 58),
		steel = Color3.fromRGB(78, 86, 100),
		steelLight = Color3.fromRGB(132, 142, 160),
		armorDarkRed = Color3.fromRGB(132, 30, 36),
		hazard = Color3.fromRGB(230, 178, 42),
		bladeGlow = Color3.fromRGB(255, 115, 40),
	})

	model.PrimaryPart = pivot
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Armored industrial melee striker ("Complex Enforcer") facing -Z (CFrame.lookAt forward).
-- Built in 4 weapon variants (`sword`, `dual`, `axe`, `mace`) sharing the same crimson-and-steel
-- chassis with Motor6D joint pivots (`torso`, `head`, `leftLeg`, `rightLeg`, `leftArm`, `rightArm`)
-- so `EnemyAnimator` animates walking, weapon-specific attacks, and death collapses at 60 FPS
-- without a Humanoid rig.
--
-- Fits inside `Config.ENEMY_KINDS.melee.size` (4x5x4) with feet at local Y = -2.5 (ground y = 0
-- when `Body` is placed at Y = 2.5 in EnemyService).
local function buildEnemyMeleeVariant(modelName: string, weapon: string): any
	local model = Instance.new("Model")
	model.Name = modelName

	local armorRed = Color3.fromRGB(198, 52, 52)
	local armorDarkRed = Color3.fromRGB(132, 30, 36)
	local chassis = Color3.fromRGB(44, 48, 58)
	local steel = Color3.fromRGB(78, 86, 100)
	local steelLight = Color3.fromRGB(115, 124, 140)
	local hazard = Color3.fromRGB(230, 178, 42)
	local visorGlow = Color3.fromRGB(255, 95, 50)
	local bladeGlow = if weapon == "dual"
		then Color3.fromRGB(255, 60, 90)
		elseif weapon == "axe" then Color3.fromRGB(255, 115, 40)
		elseif weapon == "mace" then Color3.fromRGB(255, 155, 38)
		else Color3.fromRGB(255, 70, 55)

	-- Joint pivot locations in Body-local coordinates.
	local PIVOT_TORSO = CFrame.new(0, -0.55, 0)
	local PIVOT_HEAD = CFrame.new(0, 0.9, -0.05)
	local PIVOT_LEFT_LEG = CFrame.new(-0.62, -0.85, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(0.62, -0.85, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-1.58, 0.52, 0)
	local PIVOT_RIGHT_ARM = CFrame.new(1.58, 0.52, 0)

	-- PrimaryPart: invisible anchored root centered at origin (pivoted at Y = 2.5 in EnemyService);
	-- visible TorsoCore is rigged to "torso" so the entire chest rotates/crouches/spins cleanly.
	local body = makePart({
		name = "Body",
		size = Vector3.new(2.25, 1.55, 1.55),
		cframe = CFrame.new(0, 0, 0),
		color = armorRed,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		transparency: number?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			transparency = props.transparency,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(2.25, 1.55, 1.55),
		cframe = CFrame.new(0, 0, 0),
		color = armorRed,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Pelvis & neutral standing legs (planted flush at local Y = -2.5; walk stride is animated).
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(1.75, 0.52, 1.25),
		cframe = CFrame.new(0, -0.82, 0.05),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftLeg",
		size = Vector3.new(0.72, 1.4, 0.8),
		cframe = CFrame.new(-0.62, -1.62, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftKnee",
		size = Vector3.new(0.78, 0.42, 0.35),
		cframe = CFrame.new(-0.62, -1.48, -0.4),
		color = armorDarkRed,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftFoot",
		size = Vector3.new(0.84, 0.38, 1.25),
		cframe = CFrame.new(-0.62, -2.31, -0.15),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightLeg",
		size = Vector3.new(0.72, 1.4, 0.8),
		cframe = CFrame.new(0.62, -1.62, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightKnee",
		size = Vector3.new(0.78, 0.42, 0.35),
		cframe = CFrame.new(0.62, -1.48, -0.4),
		color = armorDarkRed,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightFoot",
		size = Vector3.new(0.84, 0.38, 1.25),
		cframe = CFrame.new(0.62, -2.31, -0.15),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Torso armor, chest core, dorsal reactor pack, and shoulder pauldrons.
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestPlate",
		size = Vector3.new(2.05, 1.05, 0.45),
		cframe = CFrame.new(0, 0.16, -0.72) * CFrame.Angles(math.rad(-10), 0, 0),
		color = armorDarkRed,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestCore",
		size = Vector3.new(0.62, 0.48, 0.22),
		cframe = CFrame.new(0, 0.2, -0.92),
		color = visorGlow,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "BackPack",
		size = Vector3.new(1.55, 1.35, 0.72),
		cframe = CFrame.new(0, 0.22, 0.96),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "BackVent",
		size = Vector3.new(1.05, 0.35, 0.2),
		cframe = CFrame.new(0, 0.45, 1.32),
		color = visorGlow,
		material = Enum.Material.Neon,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftShoulder",
		size = Vector3.new(1.15, 1.05, 1.5),
		cframe = CFrame.new(-1.55, 0.58, 0) * CFrame.Angles(0, 0, math.rad(14)),
		color = armorRed,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftHazardStripe",
		size = Vector3.new(1.18, 0.22, 1.54),
		cframe = CFrame.new(-1.55, 0.88, 0) * CFrame.Angles(0, 0, math.rad(14)),
		color = hazard,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightShoulder",
		size = Vector3.new(1.22, 1.12, 1.55),
		cframe = CFrame.new(1.58, 0.62, -0.05) * CFrame.Angles(0, 0, math.rad(-14)),
		color = armorRed,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Tactical angular helmet + glowing visor facing -Z.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(1.38, 1.15, 1.38),
		cframe = CFrame.new(0, 1.42, -0.08),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "HelmetCrest",
		size = Vector3.new(0.42, 0.42, 1.48),
		cframe = CFrame.new(0, 2.02, -0.04),
		color = armorRed,
		material = Enum.Material.Metal,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(1.18, 0.36, 0.24),
		cframe = CFrame.new(0, 1.44, -0.74),
		color = visorGlow,
		material = Enum.Material.Neon,
	})

	-- Left arm + variant off-hand gear (second tapered plasma blade for `dual`, layered buckler otherwise).
	if weapon == "dual" then
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftArm",
			size = Vector3.new(0.75, 1.3, 0.82),
			cframe = CFrame.new(-1.68, -0.16, -0.52) * CFrame.Angles(math.rad(68), math.rad(10), 0),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		local lBase = CFrame.new(-1.78, -0.34, -1.28) * CFrame.Angles(math.rad(-8), 0, 0)
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladePommel",
			size = Vector3.new(0.28, 0.28, 0.34),
			cframe = lBase * CFrame.new(0, 0, 0.42) * CFrame.Angles(0, 0, math.rad(45)),
			color = steel,
			material = Enum.Material.Metal,
		})
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladeGuard",
			size = Vector3.new(0.32, 0.62, 0.28),
			cframe = lBase * CFrame.new(0, 0, -0.05),
			color = armorDarkRed,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladeGuardWing",
			size = Vector3.new(0.22, 0.42, 0.22),
			cframe = lBase * CFrame.new(0, -0.4, -0.16) * CFrame.Angles(math.rad(-26), 0, 0),
			color = steel,
			material = Enum.Material.Metal,
		})
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladeSpine",
			size = Vector3.new(0.17, 0.26, 2.05),
			cframe = lBase * CFrame.new(0, 0.08, -1.16),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladeBody",
			size = Vector3.new(0.13, 0.34, 2.1),
			cframe = lBase * CFrame.new(0, -0.08, -1.2),
			color = steelLight,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladeEdge",
			size = Vector3.new(0.09, 0.16, 2.18),
			cframe = lBase * CFrame.new(0, -0.26, -1.25),
			color = bladeGlow,
			material = Enum.Material.Neon,
		})
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladeTip",
			size = Vector3.new(0.12, 0.34, 0.56),
			cframe = lBase * CFrame.new(0, -0.04, -2.42) * CFrame.Angles(math.rad(-32), 0, 0),
			color = steelLight,
			material = Enum.Material.Metal,
		})
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftBladeTipEdge",
			size = Vector3.new(0.09, 0.16, 0.48),
			cframe = lBase * CFrame.new(0, -0.14, -2.5) * CFrame.Angles(math.rad(-32), 0, 0),
			color = bladeGlow,
			material = Enum.Material.Neon,
		})
	else
		addLimb("leftArm", PIVOT_LEFT_ARM, {
			name = "LeftArm",
			size = Vector3.new(0.72, 1.25, 0.78),
			cframe = CFrame.new(-1.62, -0.22, -0.35) * CFrame.Angles(math.rad(38), math.rad(14), 0),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		if weapon == "sword" then
			local shCF = CFrame.new(-2.0, -0.35, -0.78) * CFrame.Angles(math.rad(22), math.rad(20), 0)
			addLimb("leftArm", PIVOT_LEFT_ARM, {
				name = "LeftGuard",
				size = Vector3.new(0.24, 1.38, 1.18),
				cframe = shCF,
				color = armorDarkRed,
				material = Enum.Material.Metal,
				castShadow = true,
			})
			addLimb("leftArm", PIVOT_LEFT_ARM, {
				name = "LeftGuardTip",
				size = Vector3.new(0.22, 0.72, 0.72),
				cframe = shCF * CFrame.new(0, -0.72, 0) * CFrame.Angles(math.rad(45), 0, 0),
				color = armorDarkRed,
				material = Enum.Material.Metal,
				castShadow = true,
			})
			addLimb("leftArm", PIVOT_LEFT_ARM, {
				name = "LeftGuardPlate",
				size = Vector3.new(0.18, 0.96, 0.82),
				cframe = shCF * CFrame.new(-0.1, 0.04, 0),
				color = steel,
				material = Enum.Material.Metal,
			})
			addLimb("leftArm", PIVOT_LEFT_ARM, {
				name = "LeftGuardHazard",
				size = Vector3.new(0.2, 0.18, 0.98),
				cframe = shCF * CFrame.new(-0.11, 0.52, 0),
				color = hazard,
				material = Enum.Material.SmoothPlastic,
			})
			addLimb("leftArm", PIVOT_LEFT_ARM, {
				name = "LeftGuardCore",
				size = Vector3.new(0.24, 0.34, 0.34),
				cframe = shCF * CFrame.new(-0.14, -0.04, 0),
				color = bladeGlow,
				material = Enum.Material.Neon,
				shape = Enum.PartType.Ball,
			})
		else
			-- Reinforced gauntlet brace for heavy axe/mace units.
			addLimb("leftArm", PIVOT_LEFT_ARM, {
				name = "LeftBracer",
				size = Vector3.new(0.86, 0.72, 0.92),
				cframe = CFrame.new(-1.7, -0.52, -0.78) * CFrame.Angles(math.rad(38), math.rad(14), 0),
				color = steel,
				material = Enum.Material.Metal,
				castShadow = true,
			})
		end
	end

	-- Right arm + main melee weapon (`sword`, `dual`, `axe`, `mace`).
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightArm",
		size = Vector3.new(0.78, 1.3, 0.85),
		cframe = CFrame.new(1.68, -0.16, -0.52) * CFrame.Angles(math.rad(68), math.rad(-10), 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	if weapon == "axe" then
		-- Heavy sculpted industrial plasma bearded battle-axe (shared geometry with EnemyBattleAxe.rbxmx).
		addBattleAxeParts(function(props)
			addLimb("rightArm", PIVOT_RIGHT_ARM, props)
		end, CFrame.new(1.78, -0.45, -2.28) * CFrame.Angles(math.rad(-12), 0, 0), {
			chassis = chassis,
			steel = steel,
			steelLight = steelLight,
			armorDarkRed = armorDarkRed,
			hazard = hazard,
			bladeGlow = bladeGlow,
		})
	elseif weapon == "mace" then
		-- Heavy sculpted seismic crusher mace: cylindrical banded haft + octagonal spiked head + molten core.
		local mBase = CFrame.new(1.78, -0.36, -2.05) * CFrame.Angles(math.rad(-10), 0, 0)
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceShaft",
			size = Vector3.new(3.55, 0.26, 0.26),
			cframe = mBase * CFrame.Angles(0, math.rad(90), 0),
			color = chassis,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MacePommel",
			size = Vector3.new(0.32, 0.44, 0.44),
			cframe = mBase * CFrame.new(0, 0, 1.82) * CFrame.Angles(0, math.rad(90), 0),
			color = steel,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceCollar",
			size = Vector3.new(0.64, 0.64, 0.34),
			cframe = mBase * CFrame.new(0, 0, -0.82) * CFrame.Angles(0, 0, math.rad(45)),
			color = armorDarkRed,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceHeadA",
			size = Vector3.new(1.18, 1.18, 1.45),
			cframe = mBase * CFrame.new(0, 0, -1.55),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceHeadB",
			size = Vector3.new(1.18, 1.18, 1.45),
			cframe = mBase * CFrame.new(0, 0, -1.55) * CFrame.Angles(0, 0, math.rad(45)),
			color = armorDarkRed,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceBandRear",
			size = Vector3.new(1.32, 1.32, 0.22),
			cframe = mBase * CFrame.new(0, 0, -1.04) * CFrame.Angles(0, 0, math.rad(45)),
			color = hazard,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceBandFront",
			size = Vector3.new(1.32, 1.32, 0.22),
			cframe = mBase * CFrame.new(0, 0, -2.06) * CFrame.Angles(0, 0, math.rad(45)),
			color = hazard,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceCore",
			size = Vector3.new(1.38, 1.38, 0.32),
			cframe = mBase * CFrame.new(0, 0, -1.55) * CFrame.Angles(0, 0, math.rad(22.5)),
			color = bladeGlow,
			material = Enum.Material.Neon,
		})
		for s = 0, 3 do
			local rot = mBase * CFrame.new(0, 0, -1.55) * CFrame.Angles(0, 0, math.rad(s * 90))
			addLimb("rightArm", PIVOT_RIGHT_ARM, {
				name = `MaceSpikeBase_{s + 1}`,
				size = Vector3.new(0.32, 0.36, 0.32),
				cframe = rot * CFrame.new(0, 0.78, 0) * CFrame.Angles(0, math.rad(45), 0),
				color = steelLight,
				material = Enum.Material.Metal,
			})
			addLimb("rightArm", PIVOT_RIGHT_ARM, {
				name = `MaceSpikeTip_{s + 1}`,
				size = Vector3.new(0.16, 0.38, 0.16),
				cframe = rot * CFrame.new(0, 1.06, 0) * CFrame.Angles(0, math.rad(45), 0),
				color = steelLight,
				material = Enum.Material.Metal,
			})
		end
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceTipBase",
			size = Vector3.new(0.46, 0.46, 0.38),
			cframe = mBase * CFrame.new(0, 0, -2.42) * CFrame.Angles(0, 0, math.rad(45)),
			color = steelLight,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MaceTip",
			size = Vector3.new(0.24, 0.24, 0.44),
			cframe = mBase * CFrame.new(0, 0, -2.74) * CFrame.Angles(0, 0, math.rad(45)),
			color = bladeGlow,
			material = Enum.Material.Neon,
		})
	else
		-- `sword` and `dual` right-hand tapered cyber-cleaver blade with swept guard & pointed tip.
		local bladeLen = if weapon == "dual" then 2.05 else 2.25
		local rBase = CFrame.new(1.78, -0.34, -1.28) * CFrame.Angles(math.rad(-8), 0, 0)
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladePommel",
			size = Vector3.new(0.3, 0.3, 0.36),
			cframe = rBase * CFrame.new(0, 0, 0.44) * CFrame.Angles(0, 0, math.rad(45)),
			color = steel,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeGuard",
			size = Vector3.new(0.36, 0.68, 0.3),
			cframe = rBase * CFrame.new(0, 0, -0.05),
			color = armorDarkRed,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeGuardWingUp",
			size = Vector3.new(0.22, 0.42, 0.24),
			cframe = rBase * CFrame.new(0, 0.44, -0.18) * CFrame.Angles(math.rad(28), 0, 0),
			color = steel,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeGuardWingDown",
			size = Vector3.new(0.22, 0.46, 0.24),
			cframe = rBase * CFrame.new(0, -0.44, -0.18) * CFrame.Angles(math.rad(-28), 0, 0),
			color = steel,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeSpine",
			size = Vector3.new(0.19, 0.28, bladeLen),
			cframe = rBase * CFrame.new(0, 0.1, -(0.18 + bladeLen / 2)),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeBody",
			size = Vector3.new(0.14, 0.38, bladeLen + 0.08),
			cframe = rBase * CFrame.new(0, -0.08, -(0.2 + bladeLen / 2)),
			color = steelLight,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeEdge",
			size = Vector3.new(0.1, 0.18, bladeLen + 0.14),
			cframe = rBase * CFrame.new(0, -0.28, -(0.22 + bladeLen / 2)),
			color = bladeGlow,
			material = Enum.Material.Neon,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeTip",
			size = Vector3.new(0.13, 0.38, 0.62),
			cframe = rBase * CFrame.new(0, -0.04, -(bladeLen + 0.42)) * CFrame.Angles(math.rad(-32), 0, 0),
			color = steelLight,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BladeTipEdge",
			size = Vector3.new(0.1, 0.18, 0.54),
			cframe = rBase * CFrame.new(0, -0.16, -(bladeLen + 0.5)) * CFrame.Angles(math.rad(-32), 0, 0),
			color = bladeGlow,
			material = Enum.Material.Neon,
		})
	end

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Rigged cobalt-and-steel ranged trooper in 3 energy weapon variants (`rifle`, `shotgun`, `plasma`).
-- Fits inside `Config.ENEMY_KINDS.ranged.size` (3x5x3) with feet flush at local Y = -2.5 (ground y = 0
-- when `Body` sits at Y = 2.5). Uses the same `Group`-tagged Motor6D pivots so `EnemyAnimator` drives
-- walking/strafing, weapon recoil on fire, and death collapses cleanly.
local function buildEnemyRangedVariant(modelName: string, weapon: string): any
	local model = Instance.new("Model")
	model.Name = modelName

	local armorBlue = Color3.fromRGB(58, 118, 218)
	local armorDarkBlue = Color3.fromRGB(34, 68, 138)
	local chassis = Color3.fromRGB(38, 44, 56)
	local steel = Color3.fromRGB(82, 92, 110)
	local steelLight = Color3.fromRGB(132, 146, 168)
	local cyanGlow = if weapon == "shotgun"
		then Color3.fromRGB(95, 240, 255)
		elseif weapon == "plasma" then Color3.fromRGB(120, 195, 255)
		elseif weapon == "minigun" then Color3.fromRGB(255, 195, 55)
		else Color3.fromRGB(70, 220, 255)

	local PIVOT_TORSO = CFrame.new(0, -0.5, 0)
	local PIVOT_HEAD = CFrame.new(0, 0.92, -0.04)
	local PIVOT_LEFT_LEG = CFrame.new(-0.5, -0.82, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(0.5, -0.82, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-1.26, 0.48, -0.05)
	local PIVOT_RIGHT_ARM = CFrame.new(1.26, 0.48, -0.05)

	local body = makePart({
		name = "Body",
		size = Vector3.new(1.85, 1.5, 1.3),
		cframe = CFrame.new(0, 0, 0),
		color = armorBlue,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(1.85, 1.5, 1.3),
		cframe = CFrame.new(0, 0, 0),
		color = armorBlue,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Sleek tactical legs (feet flush at local Y = -2.5).
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(1.48, 0.48, 1.08),
		cframe = CFrame.new(0, -0.8, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftLeg",
		size = Vector3.new(0.58, 1.44, 0.68),
		cframe = CFrame.new(-0.5, -1.62, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftFoot",
		size = Vector3.new(0.68, 0.34, 1.12),
		cframe = CFrame.new(-0.5, -2.33, -0.14),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightLeg",
		size = Vector3.new(0.58, 1.44, 0.68),
		cframe = CFrame.new(0.5, -1.62, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightFoot",
		size = Vector3.new(0.68, 0.34, 1.12),
		cframe = CFrame.new(0.5, -2.33, -0.14),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Torso armor + dorsal energy capacitor cell + shoulder pads.
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestPlate",
		size = Vector3.new(1.72, 0.96, 0.38),
		cframe = CFrame.new(0, 0.16, -0.62),
		color = armorDarkBlue,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestCore",
		size = Vector3.new(0.42, 0.42, 0.18),
		cframe = CFrame.new(0, 0.18, -0.8),
		color = cyanGlow,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "EnergyPack",
		size = Vector3.new(1.25, 1.35, 0.68),
		cframe = CFrame.new(0, 0.2, 0.85),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "PackCoil",
		size = Vector3.new(0.52, 0.95, 0.24),
		cframe = CFrame.new(0, 0.22, 1.22),
		color = cyanGlow,
		material = Enum.Material.Neon,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftShoulder",
		size = Vector3.new(0.78, 0.78, 1.15),
		cframe = CFrame.new(-1.25, 0.54, 0) * CFrame.Angles(0, 0, math.rad(12)),
		color = armorBlue,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightShoulder",
		size = Vector3.new(0.82, 0.82, 1.18),
		cframe = CFrame.new(1.25, 0.54, 0) * CFrame.Angles(0, 0, math.rad(-12)),
		color = armorBlue,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Recon/sniper helmet with glowing cyan optic visor & comms antenna.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(1.18, 1.1, 1.28),
		cframe = CFrame.new(0, 1.4, -0.06),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "HelmetTop",
		size = Vector3.new(0.95, 0.26, 1.32),
		cframe = CFrame.new(0, 1.98, -0.02),
		color = armorBlue,
		material = Enum.Material.Metal,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(1.02, 0.34, 0.22),
		cframe = CFrame.new(0, 1.42, -0.68),
		color = cyanGlow,
		material = Enum.Material.Neon,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Antenna",
		size = Vector3.new(0.12, 0.88, 0.12),
		cframe = CFrame.new(-0.56, 2.08, 0.28),
		color = steelLight,
		material = Enum.Material.Metal,
	})

	-- Left support arm angled toward the weapon foregrip.
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftArm",
		size = Vector3.new(0.56, 1.15, 0.62),
		cframe = CFrame.new(-1.12, -0.06, -0.65) * CFrame.Angles(math.rad(72), math.rad(28), 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Right firing arm + variant energy firearm extending forward along -Z.
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightArm",
		size = Vector3.new(0.6, 1.18, 0.66),
		cframe = CFrame.new(1.18, -0.04, -0.58) * CFrame.Angles(math.rad(78), math.rad(-10), 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	if weapon == "minigun" then
		-- Heavy rotary machine gun: armored housing, top carry handle, cylindrical ammo drum,
		-- 4 cylindrical rotary barrels with dual clamp rings, and glowing muzzle flash cage.
		local ammoYellow = Color3.fromRGB(235, 182, 42)
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "GunHousing",
			size = Vector3.new(0.74, 0.72, 1.95),
			cframe = CFrame.new(1.02, -0.18, -1.72),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "CarryHandle",
			size = Vector3.new(0.16, 0.14, 1.15),
			cframe = CFrame.new(1.02, 0.36, -1.7),
			color = steel,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "AmmoDrum",
			size = Vector3.new(0.72, 0.92, 0.92),
			cframe = CFrame.new(1.5, -0.46, -1.65) * CFrame.Angles(0, math.rad(90), 0),
			color = ammoYellow,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		-- 4 cylindrical rotary barrels with mid & front cooling clamp rings.
		for i, off in ipairs({ { -0.16, 0.16 }, { 0.16, 0.16 }, { -0.16, -0.16 }, { 0.16, -0.16 } }) do
			addLimb("rightArm", PIVOT_RIGHT_ARM, {
				name = `MinigunBarrel{i}`,
				size = Vector3.new(2.35, 0.16, 0.16),
				cframe = CFrame.new(1.02 + off[1], -0.16 + off[2], -3.72) * CFrame.Angles(0, math.rad(90), 0),
				color = steelLight,
				material = Enum.Material.Metal,
				shape = Enum.PartType.Cylinder,
				castShadow = true,
			})
		end
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BarrelClampMid",
			size = Vector3.new(0.24, 0.64, 0.64),
			cframe = CFrame.new(1.02, -0.16, -3.35) * CFrame.Angles(0, math.rad(90), 0),
			color = armorDarkBlue,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BarrelClampFront",
			size = Vector3.new(0.28, 0.68, 0.68),
			cframe = CFrame.new(1.02, -0.16, -4.38) * CFrame.Angles(0, math.rad(90), 0),
			color = armorDarkBlue,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MuzzleFlashPort",
			size = Vector3.new(0.2, 0.56, 0.56),
			cframe = CFrame.new(1.02, -0.16, -4.92) * CFrame.Angles(0, math.rad(90), 0),
			color = cyanGlow,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
		})
	elseif weapon == "shotgun" then
		-- Sculpted twin-barrel energy scattergun: heavy stock, contoured receiver, twin cylindrical
		-- barrels, glowing pump grip, and wide slotted energy muzzle choke.
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "GunStock",
			size = Vector3.new(0.42, 0.48, 0.95),
			cframe = CFrame.new(0.92, -0.16, -0.68),
			color = chassis,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "GunBody",
			size = Vector3.new(0.64, 0.56, 1.95),
			cframe = CFrame.new(0.92, -0.08, -1.9),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "GunTopRail",
			size = Vector3.new(0.32, 0.14, 1.65),
			cframe = CFrame.new(0.92, 0.24, -1.95),
			color = armorDarkBlue,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BarrelLeft",
			size = Vector3.new(1.55, 0.24, 0.24),
			cframe = CFrame.new(0.75, 0.04, -3.22) * CFrame.Angles(0, math.rad(90), 0),
			color = chassis,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "BarrelRight",
			size = Vector3.new(1.55, 0.24, 0.24),
			cframe = CFrame.new(1.09, 0.04, -3.22) * CFrame.Angles(0, math.rad(90), 0),
			color = chassis,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "PumpGlow",
			size = Vector3.new(0.68, 0.26, 0.98),
			cframe = CFrame.new(0.92, -0.24, -2.65),
			color = cyanGlow,
			material = Enum.Material.Neon,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MuzzleChoke",
			size = Vector3.new(0.72, 0.34, 0.28),
			cframe = CFrame.new(0.92, 0.04, -3.96),
			color = armorDarkBlue,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MuzzleGlow",
			size = Vector3.new(0.6, 0.2, 0.16),
			cframe = CFrame.new(0.92, 0.04, -4.12),
			color = cyanGlow,
			material = Enum.Material.Neon,
		})
	elseif weapon == "plasma" then
		-- Sculpted heavy plasma cannon: contoured chassis, 3 cooling radiator fins, cylindrical
		-- accelerator shroud, glowing core chamber, and suspended plasma muzzle orb.
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "GunBody",
			size = Vector3.new(0.76, 0.78, 2.35),
			cframe = CFrame.new(1.02, -0.06, -1.92),
			color = armorDarkBlue,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "PlasmaCore",
			size = Vector3.new(0.86, 0.34, 1.4),
			cframe = CFrame.new(1.02, 0.02, -2.02),
			color = cyanGlow,
			material = Enum.Material.Neon,
		})
		for f = 1, 3 do
			addLimb("rightArm", PIVOT_RIGHT_ARM, {
				name = `PlasmaFin{f}`,
				size = Vector3.new(0.96, 0.56, 0.16),
				cframe = CFrame.new(1.02, 0.02, -1.42 - f * 0.42),
				color = steel,
				material = Enum.Material.Metal,
			})
		end
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "PlasmaShroud",
			size = Vector3.new(1.05, 0.58, 0.58),
			cframe = CFrame.new(1.02, -0.02, -3.38) * CFrame.Angles(0, math.rad(90), 0),
			color = steelLight,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MuzzleOrb",
			size = Vector3.new(0.5, 0.5, 0.5),
			cframe = CFrame.new(1.02, -0.02, -3.96),
			color = cyanGlow,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Ball,
		})
	else
		-- Default `rifle`: precision plasma rail-rifle with stock, angled cell mag, twin rail
		-- prongs, cylindrical barrel, cylindrical sniper optic scope, and muzzle brake.
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "RifleStock",
			size = Vector3.new(0.32, 0.42, 0.85),
			cframe = CFrame.new(0.92, -0.14, -0.62),
			color = chassis,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "GunBody",
			size = Vector3.new(0.42, 0.48, 2.35),
			cframe = CFrame.new(0.92, -0.08, -2.02),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "RifleMag",
			size = Vector3.new(0.24, 0.62, 0.34),
			cframe = CFrame.new(0.92, -0.46, -1.92) * CFrame.Angles(math.rad(14), 0, 0),
			color = armorDarkBlue,
			material = Enum.Material.Metal,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "RifleBarrel",
			size = Vector3.new(1.95, 0.2, 0.2),
			cframe = CFrame.new(0.92, 0.02, -3.9) * CFrame.Angles(0, math.rad(90), 0),
			color = chassis,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "RifleRail",
			size = Vector3.new(0.14, 0.14, 3.35),
			cframe = CFrame.new(0.92, 0.15, -2.92),
			color = cyanGlow,
			material = Enum.Material.Neon,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "RifleScope",
			size = Vector3.new(1.12, 0.26, 0.26),
			cframe = CFrame.new(0.92, 0.38, -1.78) * CFrame.Angles(0, math.rad(90), 0),
			color = armorDarkBlue,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "ScopeLens",
			size = Vector3.new(0.12, 0.22, 0.22),
			cframe = CFrame.new(0.92, 0.38, -2.36) * CFrame.Angles(0, math.rad(90), 0),
			color = cyanGlow,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
		})
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = "MuzzleTip",
			size = Vector3.new(0.32, 0.32, 0.32),
			cframe = CFrame.new(0.92, 0.02, -4.92),
			color = cyanGlow,
			material = Enum.Material.Neon,
		})
	end

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Compact, frenetic explosive runner with strapped C4 satchel, red TNT bundle, wiring, and
-- flashing detonator beacon. Fits inside `Config.ENEMY_KINDS.exploder.size` (3.5x4.0x3.5) with
-- feet flush at local Y = -2.0 (ground y = 0 when `Body` sits at Y = 2.0).
local function buildEnemyExploder(): any
	local model = Instance.new("Model")
	model.Name = "EnemyExploder"

	local armorOrange = Color3.fromRGB(235, 138, 32)
	local chassis = Color3.fromRGB(42, 44, 52)
	local steel = Color3.fromRGB(82, 86, 98)
	local tntRed = Color3.fromRGB(215, 42, 36)
	local c4Tan = Color3.fromRGB(196, 178, 128)
	local strapDark = Color3.fromRGB(26, 28, 34)
	local fuseGlow = Color3.fromRGB(255, 190, 48)
	local blinkRed = Color3.fromRGB(255, 55, 35)

	local PIVOT_TORSO = CFrame.new(0, -0.35, 0)
	local PIVOT_HEAD = CFrame.new(0, 0.85, -0.08)
	local PIVOT_LEFT_LEG = CFrame.new(-0.52, -0.62, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(0.52, -0.62, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-1.18, 0.35, 0)
	local PIVOT_RIGHT_ARM = CFrame.new(1.18, 0.35, 0)

	local body = makePart({
		name = "Body",
		size = Vector3.new(1.75, 1.35, 1.35),
		cframe = CFrame.new(0, 0, 0),
		color = armorOrange,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(1.75, 1.35, 1.35),
		cframe = CFrame.new(0, 0, 0),
		color = armorOrange,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Fast runner legs (feet flush at local Y = -2.0).
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(1.42, 0.42, 1.05),
		cframe = CFrame.new(0, -0.66, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftLeg",
		size = Vector3.new(0.54, 1.1, 0.62),
		cframe = CFrame.new(-0.52, -1.28, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftFoot",
		size = Vector3.new(0.64, 0.3, 1.02),
		cframe = CFrame.new(-0.52, -1.85, -0.14),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightLeg",
		size = Vector3.new(0.54, 1.1, 0.62),
		cframe = CFrame.new(0.52, -1.28, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightFoot",
		size = Vector3.new(0.64, 0.3, 1.02),
		cframe = CFrame.new(0.52, -1.85, -0.14),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Front strapped C4 brick + timer screen + blinking detonator LED + harness straps.
	addLimb("torso", PIVOT_TORSO, {
		name = "HarnessStrap",
		size = Vector3.new(1.88, 0.28, 1.56),
		cframe = CFrame.new(0, 0.05, 0),
		color = strapDark,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "C4Block",
		size = Vector3.new(1.38, 0.88, 0.42),
		cframe = CFrame.new(0, 0.08, -0.82),
		color = c4Tan,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "C4Keypad",
		size = Vector3.new(0.62, 0.44, 0.14),
		cframe = CFrame.new(-0.22, 0.1, -1.04),
		color = strapDark,
		material = Enum.Material.Metal,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "C4TimerGlow",
		size = Vector3.new(0.46, 0.2, 0.16),
		cframe = CFrame.new(-0.22, 0.16, -1.07),
		color = fuseGlow,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "C4Beacon",
		size = Vector3.new(0.28, 0.28, 0.22),
		cframe = CFrame.new(0.38, 0.14, -1.05),
		color = blinkRed,
		material = Enum.Material.Neon,
	})

	-- Back bundle of 3 red TNT dynamite sticks strapped tightly across the spine (super readable from behind/iso).
	for i, xOff in ipairs({ -0.46, 0, 0.46 }) do
		addLimb("torso", PIVOT_TORSO, {
			name = `TntStick{i}`,
			size = Vector3.new(0.42, 1.48, 0.42),
			cframe = CFrame.new(xOff, 0.16, 0.88),
			color = tntRed,
			material = Enum.Material.SmoothPlastic,
			castShadow = true,
		})
	end
	addLimb("torso", PIVOT_TORSO, {
		name = "TntBandTop",
		size = Vector3.new(1.46, 0.18, 0.52),
		cframe = CFrame.new(0, 0.52, 0.88),
		color = strapDark,
		material = Enum.Material.Metal,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "TntBandBot",
		size = Vector3.new(1.46, 0.18, 0.52),
		cframe = CFrame.new(0, -0.2, 0.88),
		color = strapDark,
		material = Enum.Material.Metal,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "TntSpark",
		size = Vector3.new(0.42, 0.42, 0.42),
		cframe = CFrame.new(0, 1.02, 0.88),
		color = fuseGlow,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
	})

	-- Head with hazard dome + flashing beacon antenna.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(1.12, 0.96, 1.12),
		cframe = CFrame.new(0, 1.24, -0.08),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(0.92, 0.34, 0.2),
		cframe = CFrame.new(0, 1.24, -0.62),
		color = fuseGlow,
		material = Enum.Material.Neon,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "HazardBeacon",
		size = Vector3.new(0.46, 0.38, 0.46),
		cframe = CFrame.new(0, 1.88, -0.08),
		color = blinkRed,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
	})

	-- Arms clutching / flailing forward in frantic sprint stance.
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftArm",
		size = Vector3.new(0.52, 1.12, 0.56),
		cframe = CFrame.new(-1.18, -0.1, -0.25) * CFrame.Angles(math.rad(28), 0, math.rad(14)),
		color = armorOrange,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightArm",
		size = Vector3.new(0.52, 1.12, 0.56),
		cframe = CFrame.new(1.18, -0.1, -0.25) * CFrame.Angles(math.rad(28), 0, math.rad(-14)),
		color = armorOrange,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Huge muscular biomechanical juggernaut grabber facing -Z (CFrame.lookAt forward).
-- Fits inside `Config.ENEMY_KINDS.grabber.size` (4.8x6.2x4.2) with feet flush at local Y = -3.1
-- (ground y = 0 when `Body` sits at Y = 3.1). Rigged with Motor6D joints so `EnemyAnimator` drives
-- heavy stomping walk, lunge charge, rhythmic player-squeezing hold, and colossal death collapse.
local function buildEnemyGrabber(): any
	local model = Instance.new("Model")
	model.Name = "EnemyGrabber"

	local musclePurple = Color3.fromRGB(142, 42, 195)
	local muscleDark = Color3.fromRGB(88, 24, 130)
	local armorDark = Color3.fromRGB(36, 30, 48)
	local steel = Color3.fromRGB(72, 68, 88)
	local glowMagenta = Color3.fromRGB(255, 80, 230)

	local PIVOT_TORSO = CFrame.new(0, -0.65, 0)
	local PIVOT_HEAD = CFrame.new(0, 1.38, -0.35)
	local PIVOT_LEFT_LEG = CFrame.new(-0.88, -1.05, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(0.88, -1.05, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-2.15, 0.92, -0.1)
	local PIVOT_RIGHT_ARM = CFrame.new(2.15, 0.92, -0.1)

	-- Invisible anchored root centered at origin (pivoted at Y = 3.1 in EnemyService); visible
	-- muscular TorsoCore is rigged to "torso" so pecs, traps, and arms move together as one body.
	local body = makePart({
		name = "Body",
		size = Vector3.new(3.25, 2.2, 2.25),
		cframe = CFrame.new(0, 0, 0),
		color = musclePurple,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(3.25, 2.2, 2.25),
		cframe = CFrame.new(0, 0, 0),
		color = musclePurple,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})

	-- Sculpted muscular pecs, bulging traps, dorsal mutagen canisters, and heavy waist.
	addLimb("torso", PIVOT_TORSO, {
		name = "PecLeft",
		size = Vector3.new(1.48, 1.15, 0.72),
		cframe = CFrame.new(-0.82, 0.35, -1.02) * CFrame.Angles(math.rad(-8), math.rad(10), 0),
		color = muscleDark,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "PecRight",
		size = Vector3.new(1.48, 1.15, 0.72),
		cframe = CFrame.new(0.82, 0.35, -1.02) * CFrame.Angles(math.rad(-8), math.rad(-10), 0),
		color = muscleDark,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestVein",
		size = Vector3.new(0.55, 1.15, 0.25),
		cframe = CFrame.new(0, 0.28, -1.28),
		color = glowMagenta,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "Traps",
		size = Vector3.new(2.75, 0.85, 1.75),
		cframe = CFrame.new(0, 1.32, 0.18) * CFrame.Angles(math.rad(12), 0, 0),
		color = musclePurple,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "BackTankLeft",
		size = Vector3.new(0.75, 1.65, 0.75),
		cframe = CFrame.new(-0.68, 0.45, 1.35),
		color = glowMagenta,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "BackTankRight",
		size = Vector3.new(0.75, 1.65, 0.75),
		cframe = CFrame.new(0.68, 0.45, 1.35),
		color = glowMagenta,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "WaistBelt",
		size = Vector3.new(2.45, 0.72, 1.75),
		cframe = CFrame.new(0, -1.12, 0.05),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Hulking tree-trunk legs (feet planted flush at local Y = -3.1).
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftThigh",
		size = Vector3.new(1.12, 1.65, 1.18),
		cframe = CFrame.new(-0.88, -1.92, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftLeg", PIVOT_LEFT_LEG, {
		name = "LeftFoot",
		size = Vector3.new(1.22, 0.56, 1.72),
		cframe = CFrame.new(-0.88, -2.82, -0.22),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightThigh",
		size = Vector3.new(1.12, 1.65, 1.18),
		cframe = CFrame.new(0.88, -1.92, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightLeg", PIVOT_RIGHT_LEG, {
		name = "RightFoot",
		size = Vector3.new(1.22, 0.56, 1.72),
		cframe = CFrame.new(0.88, -2.82, -0.22),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Low-set juggernaut head tucked forward between massive traps, glowing angry magenta visor.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(1.42, 1.28, 1.48),
		cframe = CFrame.new(0, 1.62, -0.58),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(1.22, 0.42, 0.28),
		cframe = CFrame.new(0, 1.64, -1.28),
		color = glowMagenta,
		material = Enum.Material.Neon,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "JawPlate",
		size = Vector3.new(1.28, 0.44, 0.42),
		cframe = CFrame.new(0, 1.16, -1.22),
		color = steel,
		material = Enum.Material.Metal,
	})

	-- Colossal muscular arms (huge deltoid boulders + thick biceps + oversized grasping forearms & claws).
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftDeltoid",
		size = Vector3.new(1.65, 1.55, 1.75),
		cframe = CFrame.new(-2.22, 0.92, -0.05) * CFrame.Angles(0, 0, math.rad(16)),
		color = musclePurple,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftBicep",
		size = Vector3.new(1.25, 1.5, 1.32),
		cframe = CFrame.new(-2.45, -0.15, -0.45) * CFrame.Angles(math.rad(32), 0, math.rad(8)),
		color = muscleDark,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftArm",
		size = Vector3.new(1.38, 1.38, 2.25),
		cframe = CFrame.new(-2.35, -0.68, -1.78) * CFrame.Angles(math.rad(10), math.rad(-10), 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftClaw",
		size = Vector3.new(0.95, 1.15, 1.35),
		cframe = CFrame.new(-1.95, -0.68, -3.15) * CFrame.Angles(0, math.rad(-28), 0),
		color = glowMagenta,
		material = Enum.Material.Neon,
	})

	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightDeltoid",
		size = Vector3.new(1.65, 1.55, 1.75),
		cframe = CFrame.new(2.22, 0.92, -0.05) * CFrame.Angles(0, 0, math.rad(-16)),
		color = musclePurple,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightBicep",
		size = Vector3.new(1.25, 1.5, 1.32),
		cframe = CFrame.new(2.45, -0.15, -0.45) * CFrame.Angles(math.rad(32), 0, math.rad(-8)),
		color = muscleDark,
		material = Enum.Material.SmoothPlastic,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightArm",
		size = Vector3.new(1.38, 1.38, 2.25),
		cframe = CFrame.new(2.35, -0.68, -1.78) * CFrame.Angles(math.rad(10), math.rad(10), 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightClaw",
		size = Vector3.new(0.95, 1.15, 1.35),
		cframe = CFrame.new(1.95, -0.68, -3.15) * CFrame.Angles(0, math.rad(28), 0),
		color = glowMagenta,
		material = Enum.Material.Neon,
	})

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Boss "Oh" (Oleada 6 — first part of OhMyGon): colossal heavy mechanical titan (~11 studs tall),
-- rigged with Group-tagged Motor6Ds so EnemyAnimator drives its stomp, cone smash, leap slam,
-- and 360-deg plasma nova animations at 60 FPS.
local function buildBossOh(): any
	local model = Instance.new("Model")
	model.Name = "BossOh"

	local armorDark = Color3.fromRGB(30, 34, 44)
	local armorCrimson = Color3.fromRGB(132, 34, 42)
	local steel = Color3.fromRGB(94, 104, 122)
	local steelLight = Color3.fromRGB(178, 188, 204)
	local hazard = Color3.fromRGB(238, 184, 38)
	local coreGlow = Color3.fromRGB(255, 96, 36)
	local reactorHot = Color3.fromRGB(255, 210, 95)

	local body = makePart({
		name = "Body",
		size = Vector3.new(6.8, 11.0, 6.2),
		cframe = CFrame.new(0, 0, 0),
		color = armorDark,
		transparency = 1,
		anchored = true,
	})
	body.Parent = model

	local PIVOT_TORSO = CFrame.new(0, -0.4, 0)
	local PIVOT_HEAD = CFrame.new(0, 3.1, -0.25)
	local PIVOT_LEFT_LEG = CFrame.new(-1.55, -1.6, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(1.55, -1.6, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-3.2, 2.25, 0)
	local PIVOT_RIGHT_ARM = CFrame.new(3.2, 2.25, 0)

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	}): any
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
		return p
	end

	-- Heavy armored hydraulic legs (feet planted flush at local Y = -5.5).
	for _, side in ipairs({ { "Left", -1, "leftLeg", PIVOT_LEFT_LEG }, { "Right", 1, "rightLeg", PIVOT_RIGHT_LEG } }) do
		local prefix, sx, group, pivot = side[1], side[2], side[3], side[4]
		addLimb(group, pivot, {
			name = `{prefix}Thigh`,
			size = Vector3.new(1.75, 2.2, 1.85),
			cframe = CFrame.new(sx * 1.55, -2.55, 0),
			color = armorDark,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(group, pivot, {
			name = `{prefix}KneeGuard`,
			size = Vector3.new(1.9, 0.95, 1.15),
			cframe = CFrame.new(sx * 1.55, -3.55, -0.75),
			color = hazard,
			material = Enum.Material.SmoothPlastic,
			castShadow = true,
		})
		addLimb(group, pivot, {
			name = `{prefix}Shin`,
			size = Vector3.new(1.65, 1.75, 1.75),
			cframe = CFrame.new(sx * 1.55, -4.35, 0.05),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(group, pivot, {
			name = `{prefix}Foot`,
			size = Vector3.new(2.15, 0.75, 2.85),
			cframe = CFrame.new(sx * 1.55, -5.125, -0.35),
			color = armorDark,
			material = Enum.Material.DiamondPlate,
			castShadow = true,
		})
	end

	-- Colossal dreadnought torso, molten chest reactor, and dorsal exhaust stacks.
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(4.3, 1.35, 2.95),
		cframe = CFrame.new(0, -1.1, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "WaistHazard",
		size = Vector3.new(4.45, 0.45, 3.1),
		cframe = CFrame.new(0, -0.5, 0),
		color = hazard,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestMain",
		size = Vector3.new(5.1, 3.2, 3.5),
		cframe = CFrame.new(0, 1.25, -0.1),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestArmorPlate",
		size = Vector3.new(4.4, 2.4, 0.9),
		cframe = CFrame.new(0, 1.35, -1.8) * CFrame.Angles(math.rad(-8), 0, 0),
		color = armorDark,
		material = Enum.Material.DiamondPlate,
		castShadow = true,
	})
	local reactor = addLimb("torso", PIVOT_TORSO, {
		name = "ChestReactor",
		size = Vector3.new(1.65, 1.65, 0.7),
		cframe = CFrame.new(0, 1.45, -2.18) * CFrame.Angles(0, 0, math.rad(45)),
		color = coreGlow,
		material = Enum.Material.Neon,
	})
	addLight(reactor, coreGlow)
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestReactorCore",
		size = Vector3.new(0.85, 0.85, 0.85),
		cframe = CFrame.new(0, 1.45, -2.26),
		color = reactorHot,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
	})
	-- Twin dorsal power stacks.
	for _, sx in ipairs({ -1.35, 1.35 }) do
		addLimb("torso", PIVOT_TORSO, {
			name = `BackStack_{sx}`,
			size = Vector3.new(1.15, 2.9, 1.15),
			cframe = CFrame.new(sx, 2.35, 2.05) * CFrame.Angles(math.rad(14), 0, 0),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `BackVent_{sx}`,
			size = Vector3.new(0.82, 0.45, 0.82),
			cframe = CFrame.new(sx, 3.78, 2.42) * CFrame.Angles(math.rad(14), 0, 0),
			color = coreGlow,
			material = Enum.Material.Neon,
		})
	end

	-- Dreadnought helmet + cyclopean glowing visor + twin crest horns.
	addLimb("head", PIVOT_HEAD, {
		name = "HeadHull",
		size = Vector3.new(2.25, 1.95, 2.35),
		cframe = CFrame.new(0, 3.65, -0.35),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "HeadCrest",
		size = Vector3.new(0.65, 0.85, 2.55),
		cframe = CFrame.new(0, 4.78, -0.25),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(1.9, 0.62, 0.35),
		cframe = CFrame.new(0, 3.7, -1.48),
		color = reactorHot,
		material = Enum.Material.Neon,
	})
	for _, sx in ipairs({ -1, 1 }) do
		addLimb("head", PIVOT_HEAD, {
			name = `Horn_{sx}`,
			size = Vector3.new(0.45, 1.35, 0.55),
			cframe = CFrame.new(sx * 1.18, 4.6, -0.65) * CFrame.Angles(math.rad(-25), 0, math.rad(-sx * 24)),
			color = steelLight,
			material = Enum.Material.Metal,
		})
	end

	-- Left arm: colossal pauldron + hydraulic piston arm + glowing crushing gauntlet.
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftPauldron",
		size = Vector3.new(2.45, 2.25, 2.85),
		cframe = CFrame.new(-3.45, 2.45, 0) * CFrame.Angles(0, 0, math.rad(14)),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftPauldronHazard",
		size = Vector3.new(2.5, 0.42, 2.9),
		cframe = CFrame.new(-3.45, 3.15, 0) * CFrame.Angles(0, 0, math.rad(14)),
		color = hazard,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftUpperArm",
		size = Vector3.new(1.5, 2.35, 1.55),
		cframe = CFrame.new(-3.65, 0.55, -0.35) * CFrame.Angles(math.rad(28), 0, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftGauntlet",
		size = Vector3.new(1.95, 1.95, 2.45),
		cframe = CFrame.new(-3.6, -0.85, -1.45) * CFrame.Angles(math.rad(16), 0, 0),
		color = steel,
		material = Enum.Material.DiamondPlate,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftKnuckleGlow",
		size = Vector3.new(1.65, 0.65, 0.45),
		cframe = CFrame.new(-3.6, -1.0, -2.72),
		color = coreGlow,
		material = Enum.Material.Neon,
	})

	-- Right arm: colossal pauldron + actuator arm + Titanic Seismic Maul extending along -Z.
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightPauldron",
		size = Vector3.new(2.55, 2.35, 2.95),
		cframe = CFrame.new(3.5, 2.45, 0) * CFrame.Angles(0, 0, math.rad(-14)),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightPauldronHazard",
		size = Vector3.new(2.6, 0.42, 3.0),
		cframe = CFrame.new(3.5, 3.18, 0) * CFrame.Angles(0, 0, math.rad(-14)),
		color = hazard,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightUpperArm",
		size = Vector3.new(1.55, 2.35, 1.6),
		cframe = CFrame.new(3.7, 0.55, -0.55) * CFrame.Angles(math.rad(48), 0, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightForearm",
		size = Vector3.new(1.65, 1.65, 2.15),
		cframe = CFrame.new(3.7, -0.55, -1.75),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	-- Titanic Seismic Maul (cylindrical banded shaft + armored collar + octagonal spiked head + plasma core).
	local maulBase = CFrame.new(3.75, -0.65, -4.55) * CFrame.Angles(math.rad(-8), 0, 0)
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulShaft",
		size = Vector3.new(6.9, 0.56, 0.56),
		cframe = maulBase * CFrame.Angles(0, math.rad(90), 0),
		color = steel,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulPommel",
		size = Vector3.new(0.62, 0.92, 0.92),
		cframe = maulBase * CFrame.new(0, 0, 3.45) * CFrame.Angles(0, math.rad(90), 0),
		color = armorDark,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulCollar",
		size = Vector3.new(1.35, 1.35, 0.72),
		cframe = maulBase * CFrame.new(0, 0, -1.35) * CFrame.Angles(0, 0, math.rad(45)),
		color = hazard,
		material = Enum.Material.Metal,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulHeadA",
		size = Vector3.new(2.35, 2.35, 3.05),
		cframe = maulBase * CFrame.new(0, 0, -2.75),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulHeadB",
		size = Vector3.new(2.35, 2.35, 3.05),
		cframe = maulBase * CFrame.new(0, 0, -2.75) * CFrame.Angles(0, 0, math.rad(45)),
		color = armorDark,
		material = Enum.Material.DiamondPlate,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulPlasmaBand",
		size = Vector3.new(2.68, 2.68, 0.72),
		cframe = maulBase * CFrame.new(0, 0, -2.75) * CFrame.Angles(0, 0, math.rad(22.5)),
		color = coreGlow,
		material = Enum.Material.Neon,
	})
	for s = 0, 3 do
		local rot = maulBase * CFrame.new(0, 0, -2.75) * CFrame.Angles(0, 0, math.rad(s * 90))
		addLimb("rightArm", PIVOT_RIGHT_ARM, {
			name = `MaulSideSpike_{s + 1}`,
			size = Vector3.new(0.55, 0.92, 0.55),
			cframe = rot * CFrame.new(0, 1.56, 0) * CFrame.Angles(0, math.rad(45), 0),
			color = steelLight,
			material = Enum.Material.Metal,
		})
	end
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulFrontPlate",
		size = Vector3.new(2.1, 2.1, 0.52),
		cframe = maulBase * CFrame.new(0, 0, -4.35) * CFrame.Angles(0, 0, math.rad(45)),
		color = steelLight,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "MaulCrownSpike",
		size = Vector3.new(0.82, 0.82, 1.38),
		cframe = maulBase * CFrame.new(0, 0, -5.08) * CFrame.Angles(0, 0, math.rad(45)),
		color = reactorHot,
		material = Enum.Material.Neon,
	})

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Rigged artillery area-denial specialist ("Artillero", `area`): olive-slate & dark bronze
-- tactical chassis carrying a twin-tube dorsal plasma mortar backpack and amber-lime hazard optics.
-- Fits inside `Config.ENEMY_KINDS.area.size` (3.6 x 5.2 x 3.6) with feet planted at local Y = -2.6.
local function buildEnemyArea(): any
	local model = Instance.new("Model")
	model.Name = "EnemyArea"

	local armorOlive = Color3.fromRGB(76, 94, 62)
	local armorDark = Color3.fromRGB(46, 56, 42)
	local chassis = Color3.fromRGB(36, 40, 46)
	local steel = Color3.fromRGB(92, 98, 108)
	local hazard = Color3.fromRGB(235, 185, 42)
	local limeGlow = Color3.fromRGB(145, 255, 65)
	local amberGlow = Color3.fromRGB(255, 170, 42)

	local PIVOT_TORSO = CFrame.new(0, -0.5, 0)
	local PIVOT_HEAD = CFrame.new(0, 1.0, -0.06)
	local PIVOT_LEFT_LEG = CFrame.new(-0.62, -0.84, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(0.62, -0.84, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-1.42, 0.45, -0.04)
	local PIVOT_RIGHT_ARM = CFrame.new(1.42, 0.45, -0.04)

	local body = makePart({
		name = "Body",
		size = Vector3.new(2.1, 1.6, 1.5),
		cframe = CFrame.new(0, 0, 0),
		color = armorOlive,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	-- Core torso & reinforced stabilizer hips.
	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(2.05, 1.55, 1.48),
		cframe = CFrame.new(0, 0, 0),
		color = armorOlive,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestPlate",
		size = Vector3.new(1.88, 1.02, 0.46),
		cframe = CFrame.new(0, 0.14, -0.7) * CFrame.Angles(math.rad(-10), 0, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestHazard",
		size = Vector3.new(1.72, 0.24, 0.5),
		cframe = CFrame.new(0, -0.28, -0.68),
		color = hazard,
		material = Enum.Material.SmoothPlastic,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestCore",
		size = Vector3.new(0.54, 0.42, 0.2),
		cframe = CFrame.new(0, 0.2, -0.9),
		color = limeGlow,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(1.75, 0.54, 1.24),
		cframe = CFrame.new(0, -0.82, 0.04),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Dorsal Twin Mortar Launcher Pack (unmistakable artillery silhouette from isometric camera).
	addLimb("torso", PIVOT_TORSO, {
		name = "MortarPack",
		size = Vector3.new(1.92, 1.62, 1.02),
		cframe = CFrame.new(0, 0.34, 1.08),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "MortarCanister",
		size = Vector3.new(1.45, 0.62, 0.62),
		cframe = CFrame.new(0, -0.24, 1.56),
		color = limeGlow,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Cylinder,
	})
	for side = -1, 1, 2 do
		local tag = if side < 0 then "Left" else "Right"
		local tubeCF = CFrame.new(side * 0.62, 1.48, 0.88) * CFrame.Angles(math.rad(-26), 0, math.rad(side * -8))
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}MortarTube`,
			size = Vector3.new(2.05, 0.62, 0.62),
			cframe = tubeCF * CFrame.Angles(0, 0, math.rad(90)),
			color = steel,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}MortarCollar`,
			size = Vector3.new(0.28, 0.78, 0.78),
			cframe = tubeCF * CFrame.new(0, 0.72, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = hazard,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}MortarMuzzle`,
			size = Vector3.new(0.22, 0.54, 0.54),
			cframe = tubeCF * CFrame.new(0, 0.98, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = limeGlow,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
		})
	end

	-- Braced wide artillery legs & heavy recoil boots (planted flush at local Y = -2.6).
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftLeg" else "rightLeg"
		local pvt = if side < 0 then PIVOT_LEFT_LEG else PIVOT_RIGHT_LEG
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Leg`,
			size = Vector3.new(0.74, 1.48, 0.82),
			cframe = CFrame.new(side * 0.64, -1.66, 0),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}KneeGuard`,
			size = Vector3.new(0.8, 0.44, 0.36),
			cframe = CFrame.new(side * 0.64, -1.5, -0.42),
			color = armorOlive,
			material = Enum.Material.Metal,
		})
		addLimb(grp, pvt, {
			name = `{tag}Foot`,
			size = Vector3.new(0.92, 0.4, 1.38),
			cframe = CFrame.new(side * 0.64, -2.4, -0.18),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
	end

	-- Armored dome sensor head with bright amber-lime rangefinder optic.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(1.36, 1.08, 1.36),
		cframe = CFrame.new(0, 1.46, -0.1),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "SensorAntenna",
		size = Vector3.new(0.14, 0.72, 0.14),
		cframe = CFrame.new(-0.56, 2.24, 0.08),
		color = steel,
		material = Enum.Material.Metal,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "VisorBand",
		size = Vector3.new(1.16, 0.32, 0.24),
		cframe = CFrame.new(0, 1.48, -0.74),
		color = amberGlow,
		material = Enum.Material.Neon,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "RangefinderLens",
		size = Vector3.new(0.38, 0.38, 0.28),
		cframe = CFrame.new(0.32, 1.5, -0.82),
		color = limeGlow,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
	})

	-- Arms: left targeting console gauntlet, right plasma mortar controller pod.
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftShoulder",
		size = Vector3.new(1.04, 0.96, 1.36),
		cframe = CFrame.new(-1.48, 0.56, 0) * CFrame.Angles(0, 0, math.rad(12)),
		color = armorOlive,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftArm",
		size = Vector3.new(0.7, 1.24, 0.76),
		cframe = CFrame.new(-1.58, -0.2, -0.45) * CFrame.Angles(math.rad(55), math.rad(14), 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftHoloPad",
		size = Vector3.new(0.52, 0.14, 0.72),
		cframe = CFrame.new(-1.52, -0.34, -1.04) * CFrame.Angles(math.rad(12), math.rad(14), 0),
		color = limeGlow,
		material = Enum.Material.Neon,
	})

	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightShoulder",
		size = Vector3.new(1.04, 0.96, 1.36),
		cframe = CFrame.new(1.48, 0.56, 0) * CFrame.Angles(0, 0, math.rad(-12)),
		color = armorOlive,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightArm",
		size = Vector3.new(0.7, 1.24, 0.76),
		cframe = CFrame.new(1.58, -0.2, -0.45) * CFrame.Angles(math.rad(55), math.rad(-14), 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightStabilizer",
		size = Vector3.new(0.48, 0.48, 1.15),
		cframe = CFrame.new(1.62, -0.38, -1.16),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightStabilizerGlow",
		size = Vector3.new(0.28, 0.28, 0.24),
		cframe = CFrame.new(1.62, -0.38, -1.74),
		color = amberGlow,
		material = Enum.Material.Neon,
	})

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Rigged high-voltage contact hazard unit ("Voltaico", `contact`): sleek dark-titanium & indigo
-- chassis armed with twin shoulder Tesla arc pylons, glowing chest dynamo, and forearm discharge prongs.
-- Fits inside `Config.ENEMY_KINDS.contact.size` (3.8 x 4.8 x 3.8) with feet planted at local Y = -2.4.
local function buildEnemyContact(): any
	local model = Instance.new("Model")
	model.Name = "EnemyContact"

	local armorIndigo = Color3.fromRGB(48, 54, 96)
	local armorDark = Color3.fromRGB(28, 32, 54)
	local chassis = Color3.fromRGB(34, 38, 48)
	local copper = Color3.fromRGB(178, 118, 56)
	local steel = Color3.fromRGB(108, 120, 140)
	local voltCyan = Color3.fromRGB(55, 240, 255)
	local voltYellow = Color3.fromRGB(255, 232, 78)

	local PIVOT_TORSO = CFrame.new(0, -0.45, 0)
	local PIVOT_HEAD = CFrame.new(0, 0.92, -0.1)
	local PIVOT_LEFT_LEG = CFrame.new(-0.58, -0.78, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(0.58, -0.78, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-1.38, 0.46, -0.05)
	local PIVOT_RIGHT_ARM = CFrame.new(1.38, 0.46, -0.05)

	local body = makePart({
		name = "Body",
		size = Vector3.new(2.0, 1.5, 1.4),
		cframe = CFrame.new(0, 0, 0),
		color = armorIndigo,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	-- Sleek dynamo torso & glowing chest arc sphere.
	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(1.96, 1.48, 1.38),
		cframe = CFrame.new(0, 0, 0),
		color = armorIndigo,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestCowl",
		size = Vector3.new(1.76, 0.96, 0.42),
		cframe = CFrame.new(0, 0.12, -0.64),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestArcCore",
		size = Vector3.new(0.76, 0.76, 0.76),
		cframe = CFrame.new(0, 0.14, -0.78),
		color = voltCyan,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "BackDynamo",
		size = Vector3.new(1.42, 1.32, 0.76),
		cframe = CFrame.new(0, 0.24, 0.92),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "BackDynamoRing",
		size = Vector3.new(0.32, 1.18, 1.18),
		cframe = CFrame.new(0, 0.26, 1.32) * CFrame.Angles(0, math.rad(90), 0),
		color = voltYellow,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Cylinder,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(1.56, 0.48, 1.12),
		cframe = CFrame.new(0, -0.76, 0),
		color = chassis,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Twin angled dorsal Tesla coil pylons (signature high-voltage silhouette from above).
	for side = -1, 1, 2 do
		local tag = if side < 0 then "Left" else "Right"
		local pylonCF = CFrame.new(side * 1.08, 1.42, 0.44) * CFrame.Angles(math.rad(-14), 0, math.rad(side * -26))
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}TeslaRod`,
			size = Vector3.new(1.85, 0.34, 0.34),
			cframe = pylonCF * CFrame.Angles(0, 0, math.rad(90)),
			color = copper,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		for r = 1, 3 do
			addLimb("torso", PIVOT_TORSO, {
				name = `{tag}TeslaRing_{r}`,
				size = Vector3.new(0.16, 0.68 - r * 0.06, 0.68 - r * 0.06),
				cframe = pylonCF * CFrame.new(0, -0.45 + r * 0.42, 0) * CFrame.Angles(0, 0, math.rad(90)),
				color = if r == 2 then voltYellow else voltCyan,
				material = Enum.Material.Neon,
				shape = Enum.PartType.Cylinder,
			})
		end
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}TeslaOrb`,
			size = Vector3.new(0.56, 0.56, 0.56),
			cframe = pylonCF * CFrame.new(0, 1.04, 0),
			color = voltCyan,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Ball,
		})
	end

	-- Agile sprinter legs (feet planted flush at local Y = -2.4).
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftLeg" else "rightLeg"
		local pvt = if side < 0 then PIVOT_LEFT_LEG else PIVOT_RIGHT_LEG
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Leg`,
			size = Vector3.new(0.62, 1.38, 0.72),
			cframe = CFrame.new(side * 0.58, -1.56, 0),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}ShinSpark`,
			size = Vector3.new(0.24, 0.85, 0.24),
			cframe = CFrame.new(side * 0.66, -1.6, -0.34),
			color = voltCyan,
			material = Enum.Material.Neon,
		})
		addLimb(grp, pvt, {
			name = `{tag}Foot`,
			size = Vector3.new(0.74, 0.34, 1.24),
			cframe = CFrame.new(side * 0.58, -2.23, -0.16),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
	end

	-- Angular visor-mask head with glowing electric eye chevron.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(1.24, 1.04, 1.28),
		cframe = CFrame.new(0, 1.36, -0.12),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "HeadFin",
		size = Vector3.new(0.22, 0.44, 1.36),
		cframe = CFrame.new(0, 1.96, -0.06),
		color = voltCyan,
		material = Enum.Material.Neon,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(1.06, 0.32, 0.24),
		cframe = CFrame.new(0, 1.38, -0.74),
		color = voltYellow,
		material = Enum.Material.Neon,
	})

	-- Arms with twin forearm arc discharge prongs.
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftArm" else "rightArm"
		local pvt = if side < 0 then PIVOT_LEFT_ARM else PIVOT_RIGHT_ARM
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Shoulder`,
			size = Vector3.new(0.96, 0.88, 1.24),
			cframe = CFrame.new(side * 1.44, 0.52, -0.04) * CFrame.Angles(0, 0, math.rad(side * -16)),
			color = armorIndigo,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}Arm`,
			size = Vector3.new(0.64, 1.2, 0.72),
			cframe = CFrame.new(side * 1.62, -0.2, -0.44) * CFrame.Angles(math.rad(62), math.rad(side * -14), 0),
			color = chassis,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}ArcProngTop`,
			size = Vector3.new(0.16, 0.16, 1.38),
			cframe = CFrame.new(side * 1.72, -0.22, -1.48),
			color = voltCyan,
			material = Enum.Material.Neon,
		})
		addLimb(grp, pvt, {
			name = `{tag}ArcProngBot`,
			size = Vector3.new(0.14, 0.14, 1.12),
			cframe = CFrame.new(side * 1.72, -0.5, -1.36),
			color = voltYellow,
			material = Enum.Material.Neon,
		})
	end

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Boss "My" (Floor 3 Room 5, `HS-15`): agile violet/indigo & electric-cyan photonic blade titan
-- (`size = 5.0 x 9.0 x 4.8`, feet planted at local Y = -4.5) with twin dorsal thruster wings
-- and twin oversized forearm photonic scythe-blades.
local function buildBossMy(): any
	local model = Instance.new("Model")
	model.Name = "BossMy"

	local armorViolet = Color3.fromRGB(76, 42, 138)
	local armorDark = Color3.fromRGB(28, 24, 46)
	local steel = Color3.fromRGB(96, 106, 130)
	local cyanGlow = Color3.fromRGB(70, 242, 255)
	local magentaGlow = Color3.fromRGB(224, 78, 255)

	local PIVOT_TORSO = CFrame.new(0, -0.7, 0)
	local PIVOT_HEAD = CFrame.new(0, 2.0, -0.15)
	local PIVOT_LEFT_LEG = CFrame.new(-0.9, -1.25, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(0.9, -1.25, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-2.05, 1.15, -0.1)
	local PIVOT_RIGHT_ARM = CFrame.new(2.05, 1.15, -0.1)

	local body = makePart({
		name = "Body",
		size = Vector3.new(3.2, 2.8, 2.2),
		cframe = CFrame.new(0, 0, 0),
		color = armorViolet,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	-- Sleek agile armored torso + photonic core chevron.
	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(3.0, 2.7, 2.0),
		cframe = CFrame.new(0, 0.25, 0),
		color = armorViolet,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestPlate",
		size = Vector3.new(2.6, 1.8, 0.6),
		cframe = CFrame.new(0, 0.4, -1.0) * CFrame.Angles(math.rad(-10), 0, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "ChestCore",
		size = Vector3.new(1.0, 1.0, 0.35),
		cframe = CFrame.new(0, 0.5, -1.28) * CFrame.Angles(0, 0, math.rad(45)),
		color = cyanGlow,
		material = Enum.Material.Neon,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(2.3, 0.85, 1.7),
		cframe = CFrame.new(0, -1.15, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Twin swept dorsal photonic thruster wings (signature silhouette from isometric camera).
	for side = -1, 1, 2 do
		local tag = if side < 0 then "Left" else "Right"
		local wingCF = CFrame.new(side * 2.3, 1.35, 1.35) * CFrame.Angles(math.rad(-18), math.rad(side * -24), math.rad(side * -22))
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}WingFrame`,
			size = Vector3.new(3.6, 0.55, 1.25),
			cframe = wingCF,
			color = armorDark,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}WingBlade`,
			size = Vector3.new(4.2, 0.22, 0.72),
			cframe = wingCF * CFrame.new(side * 0.4, 0.12, 0.65),
			color = magentaGlow,
			material = Enum.Material.Neon,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}WingJet`,
			size = Vector3.new(1.2, 0.42, 0.42),
			cframe = wingCF * CFrame.new(side * -0.9, -0.32, 0.35),
			color = cyanGlow,
			material = Enum.Material.Neon,
		})
	end

	-- Long sleek runner legs (feet planted flush at local Y = -4.5).
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftLeg" else "rightLeg"
		local pvt = if side < 0 then PIVOT_LEFT_LEG else PIVOT_RIGHT_LEG
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Thigh`,
			size = Vector3.new(0.96, 1.75, 1.05),
			cframe = CFrame.new(side * 0.9, -2.1, -0.1),
			color = armorDark,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}Shin`,
			size = Vector3.new(0.84, 1.65, 0.96),
			cframe = CFrame.new(side * 0.9, -3.45, 0.08),
			color = armorViolet,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}Boot`,
			size = Vector3.new(1.02, 0.55, 1.85),
			cframe = CFrame.new(side * 0.9, -4.22, -0.25),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
	end

	-- Narrow aerodynamic blade-helm with bright cyan visor crest.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(1.75, 1.65, 1.95),
		cframe = CFrame.new(0, 2.55, -0.15),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "HeadCrest",
		size = Vector3.new(0.32, 1.05, 2.65),
		cframe = CFrame.new(0, 3.55, 0.25) * CFrame.Angles(math.rad(-22), 0, 0),
		color = magentaGlow,
		material = Enum.Material.Neon,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(1.55, 0.42, 0.32),
		cframe = CFrame.new(0, 2.58, -1.08),
		color = cyanGlow,
		material = Enum.Material.Neon,
	})

	-- Arms carrying twin oversized forearm photonic energy blades.
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftArm" else "rightArm"
		local pvt = if side < 0 then PIVOT_LEFT_ARM else PIVOT_RIGHT_ARM
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Shoulder`,
			size = Vector3.new(1.55, 1.25, 1.95),
			cframe = CFrame.new(side * 2.1, 1.3, -0.05) * CFrame.Angles(0, 0, math.rad(side * -18)),
			color = armorViolet,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}Arm`,
			size = Vector3.new(0.95, 1.9, 1.02),
			cframe = CFrame.new(side * 2.35, 0.15, -0.65) * CFrame.Angles(math.rad(64), math.rad(side * -10), 0),
			color = armorDark,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}BladeSpine`,
			size = Vector3.new(0.24, 0.45, 5.2),
			cframe = CFrame.new(side * 2.52, -0.25, -3.55),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}BladeEdge`,
			size = Vector3.new(0.16, 0.32, 5.55),
			cframe = CFrame.new(side * 2.52, -0.58, -3.72),
			color = if side < 0 then cyanGlow else magentaGlow,
			material = Enum.Material.Neon,
		})
	end

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Boss "Gon" (Floor 4 Room 5, `HS-17`): heavy emerald-slate & bio-gold containment colossus
-- (`size = 6.6 x 10.2 x 6.2`, feet planted at local Y = -5.1) with chest gravity core,
-- twin dorsal containment mortar pylons, and heavy forearm emitter cannons.
local function buildBossGon(): any
	local model = Instance.new("Model")
	model.Name = "BossGon"

	local armorEmerald = Color3.fromRGB(36, 98, 72)
	local armorDark = Color3.fromRGB(26, 38, 36)
	local steel = Color3.fromRGB(84, 96, 98)
	local hazard = Color3.fromRGB(235, 188, 42)
	local emeraldGlow = Color3.fromRGB(72, 255, 138)
	local limeGlow = Color3.fromRGB(185, 255, 65)

	local PIVOT_TORSO = CFrame.new(0, -0.7, 0)
	local PIVOT_HEAD = CFrame.new(0, 2.35, -0.15)
	local PIVOT_LEFT_LEG = CFrame.new(-1.35, -1.45, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(1.35, -1.45, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-2.95, 1.3, 0)
	local PIVOT_RIGHT_ARM = CFrame.new(2.95, 1.3, 0)

	local body = makePart({
		name = "Body",
		size = Vector3.new(4.4, 3.3, 3.2),
		cframe = CFrame.new(0, 0, 0),
		color = armorEmerald,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	-- Massive armored containment torso + exposed glowing gravity core orb.
	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(4.3, 3.2, 3.0),
		cframe = CFrame.new(0, 0.35, 0),
		color = armorEmerald,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "GravityOrb",
		size = Vector3.new(1.85, 1.85, 1.85),
		cframe = CFrame.new(0, 0.45, -1.25),
		color = emeraldGlow,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "GravityRing",
		size = Vector3.new(0.35, 2.6, 2.6),
		cframe = CFrame.new(0, 0.45, -1.45) * CFrame.Angles(0, math.rad(90), 0),
		color = hazard,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(3.5, 1.05, 2.4),
		cframe = CFrame.new(0, -1.35, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- Twin dorsal containment mortar/gravity generator pylons.
	for side = -1, 1, 2 do
		local tag = if side < 0 then "Left" else "Right"
		local pylonCF = CFrame.new(side * 1.65, 2.65, 1.45) * CFrame.Angles(math.rad(-20), 0, math.rad(side * -12))
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}ContainmentTube`,
			size = Vector3.new(3.6, 1.15, 1.15),
			cframe = pylonCF * CFrame.Angles(0, 0, math.rad(90)),
			color = steel,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}ContainmentGlow`,
			size = Vector3.new(0.55, 1.42, 1.42),
			cframe = pylonCF * CFrame.new(0, 1.15, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = limeGlow,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
		})
	end

	-- Wide seismic legs (feet planted flush at local Y = -5.1).
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftLeg" else "rightLeg"
		local pvt = if side < 0 then PIVOT_LEFT_LEG else PIVOT_RIGHT_LEG
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Leg`,
			size = Vector3.new(1.55, 2.75, 1.75),
			cframe = CFrame.new(side * 1.4, -2.95, 0),
			color = armorDark,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}KneeHazard`,
			size = Vector3.new(1.65, 0.55, 0.55),
			cframe = CFrame.new(side * 1.4, -2.65, -0.9),
			color = hazard,
			material = Enum.Material.SmoothPlastic,
		})
		addLimb(grp, pvt, {
			name = `{tag}Foot`,
			size = Vector3.new(1.9, 0.82, 2.75),
			cframe = CFrame.new(side * 1.4, -4.69, -0.35),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
	end

	-- Armored containment dome helm with glowing triple-optic bar.
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(2.25, 1.85, 2.25),
		cframe = CFrame.new(0, 2.75, -0.15),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "Visor",
		size = Vector3.new(1.85, 0.52, 0.36),
		cframe = CFrame.new(0, 2.78, -1.25),
		color = emeraldGlow,
		material = Enum.Material.Neon,
	})

	-- Heavy emitter arms firing containment zones & gravity pulses.
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftArm" else "rightArm"
		local pvt = if side < 0 then PIVOT_LEFT_ARM else PIVOT_RIGHT_ARM
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Shoulder`,
			size = Vector3.new(2.1, 1.85, 2.45),
			cframe = CFrame.new(side * 3.05, 1.45, 0),
			color = armorEmerald,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}Cannon`,
			size = Vector3.new(3.4, 1.35, 1.35),
			cframe = CFrame.new(side * 3.35, -0.35, -1.65) * CFrame.Angles(0, math.rad(90), 0),
			color = armorDark,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}EmitterRing`,
			size = Vector3.new(0.42, 1.58, 1.58),
			cframe = CFrame.new(side * 3.35, -0.35, -3.15) * CFrame.Angles(0, math.rad(90), 0),
			color = limeGlow,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
		})
	end

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Final Fused Boss "OhMyGon" (Floor 5 Room 5, `HS-19`): colossal 12.2-stud fusion visibly
-- combining Oh's crimson titan armor + right-hand Seismic Maul, My's violet-cyan dorsal wings
-- + left-hand Photonic Blade, and Gon's emerald-gold gravity halo & shoulder pylons.
-- Feet planted flush at local Y = -6.1.
local function buildBossOhMyGon(): any
	local model = Instance.new("Model")
	model.Name = "BossOhMyGon"

	local armorCrimson = Color3.fromRGB(168, 34, 46)
	local armorDark = Color3.fromRGB(28, 28, 38)
	local steel = Color3.fromRGB(98, 106, 120)
	local goldGlow = Color3.fromRGB(255, 212, 72)
	local cyanGlow = Color3.fromRGB(70, 242, 255)
	local emeraldGlow = Color3.fromRGB(85, 255, 138)
	local coreRed = Color3.fromRGB(255, 62, 54)

	local PIVOT_TORSO = CFrame.new(0, -0.8, 0)
	local PIVOT_HEAD = CFrame.new(0, 2.95, -0.15)
	local PIVOT_LEFT_LEG = CFrame.new(-1.55, -1.75, 0)
	local PIVOT_RIGHT_LEG = CFrame.new(1.55, -1.75, 0)
	local PIVOT_LEFT_ARM = CFrame.new(-3.45, 1.75, 0)
	local PIVOT_RIGHT_ARM = CFrame.new(3.45, 1.75, 0)

	local body = makePart({
		name = "Body",
		size = Vector3.new(4.9, 3.8, 3.4),
		cframe = CFrame.new(0, 0, 0),
		color = armorCrimson,
		transparency = 1,
		anchored = true,
		castShadow = false,
	})
	body.Parent = model

	local function addLimb(group: string, pivot: any, props: {
		name: string,
		size: any,
		cframe: any,
		color: any,
		material: any?,
		shape: any?,
		castShadow: boolean?,
	})
		local p = makePart({
			name = props.name,
			size = props.size,
			cframe = props.cframe,
			color = props.color,
			material = props.material,
			shape = props.shape,
			anchored = false,
			castShadow = props.castShadow,
		})
		p.Parent = model
		rigJoint(body, p, pivot, group)
	end

	-- Fused Titan Torso: Oh's crimson reactor + Gon's emerald containment ring + gold crown trim.
	addLimb("torso", PIVOT_TORSO, {
		name = "TorsoCore",
		size = Vector3.new(4.8, 3.7, 3.2),
		cframe = CFrame.new(0, 0.55, 0),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "TriCoreCenter",
		size = Vector3.new(1.9, 1.9, 1.9),
		cframe = CFrame.new(0, 0.7, -1.35),
		color = goldGlow,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "TriCoreHalo",
		size = Vector3.new(0.4, 3.4, 3.4),
		cframe = CFrame.new(0, 0.7, 1.95) * CFrame.Angles(0, math.rad(90), 0),
		color = emeraldGlow,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Cylinder,
	})
	addLimb("torso", PIVOT_TORSO, {
		name = "Pelvis",
		size = Vector3.new(3.8, 1.2, 2.6),
		cframe = CFrame.new(0, -1.55, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})

	-- My's twin photonic wings + Gon's twin dorsal gravity pylons fused on the back.
	for side = -1, 1, 2 do
		local tag = if side < 0 then "Left" else "Right"
		local wingCF = CFrame.new(side * 3.2, 2.35, 1.65) * CFrame.Angles(math.rad(-16), math.rad(side * -22), math.rad(side * -18))
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}FusionWing`,
			size = Vector3.new(4.8, 0.65, 1.4),
			cframe = wingCF,
			color = armorDark,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}FusionWingGlow`,
			size = Vector3.new(5.4, 0.28, 0.8),
			cframe = wingCF * CFrame.new(side * 0.45, 0.14, 0.72),
			color = cyanGlow,
			material = Enum.Material.Neon,
		})
		local pylonCF = CFrame.new(side * 1.95, 3.5, 1.35) * CFrame.Angles(math.rad(-18), 0, math.rad(side * -14))
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}FusionPylon`,
			size = Vector3.new(3.2, 0.95, 0.95),
			cframe = pylonCF * CFrame.Angles(0, 0, math.rad(90)),
			color = steel,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			castShadow = true,
		})
		addLimb("torso", PIVOT_TORSO, {
			name = `{tag}FusionPylonGlow`,
			size = Vector3.new(0.45, 1.25, 1.25),
			cframe = pylonCF * CFrame.new(0, 1.0, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = emeraldGlow,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Cylinder,
		})
	end

	-- Titan Legs (feet planted flush at local Y = -6.1).
	for side = -1, 1, 2 do
		local grp = if side < 0 then "leftLeg" else "rightLeg"
		local pvt = if side < 0 then PIVOT_LEFT_LEG else PIVOT_RIGHT_LEG
		local tag = if side < 0 then "Left" else "Right"
		addLimb(grp, pvt, {
			name = `{tag}Leg`,
			size = Vector3.new(1.75, 3.45, 1.9),
			cframe = CFrame.new(side * 1.55, -3.55, 0),
			color = armorDark,
			material = Enum.Material.Metal,
			castShadow = true,
		})
		addLimb(grp, pvt, {
			name = `{tag}KneeGlow`,
			size = Vector3.new(1.85, 0.45, 0.45),
			cframe = CFrame.new(side * 1.55, -3.15, -0.95),
			color = goldGlow,
			material = Enum.Material.Neon,
		})
		addLimb(grp, pvt, {
			name = `{tag}Foot`,
			size = Vector3.new(2.15, 0.92, 3.1),
			cframe = CFrame.new(side * 1.55, -5.64, -0.4),
			color = steel,
			material = Enum.Material.Metal,
			castShadow = true,
		})
	end

	-- Fused Triad Crown Head (crimson/cyan/emerald triad visor).
	addLimb("head", PIVOT_HEAD, {
		name = "Head",
		size = Vector3.new(2.35, 2.05, 2.35),
		cframe = CFrame.new(0, 3.45, -0.15),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "CrownCrest",
		size = Vector3.new(0.45, 1.4, 2.7),
		cframe = CFrame.new(0, 4.75, 0.15) * CFrame.Angles(math.rad(-18), 0, 0),
		color = goldGlow,
		material = Enum.Material.Neon,
	})
	addLimb("head", PIVOT_HEAD, {
		name = "VisorCenter",
		size = Vector3.new(1.95, 0.54, 0.36),
		cframe = CFrame.new(0, 3.48, -1.3),
		color = coreRed,
		material = Enum.Material.Neon,
	})

	-- Left Arm: My's Oversized Photonic Energy Blade.
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftShoulder",
		size = Vector3.new(2.25, 2.0, 2.55),
		cframe = CFrame.new(-3.55, 1.95, 0),
		color = Color3.fromRGB(76, 42, 138),
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftArm",
		size = Vector3.new(1.45, 2.4, 1.5),
		cframe = CFrame.new(-3.8, 0.35, -0.8) * CFrame.Angles(math.rad(58), 0, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftFusionBladeSpine",
		size = Vector3.new(0.32, 0.62, 6.2),
		cframe = CFrame.new(-3.95, -0.3, -4.35),
		color = steel,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("leftArm", PIVOT_LEFT_ARM, {
		name = "LeftFusionBladeEdge",
		size = Vector3.new(0.22, 0.44, 6.6),
		cframe = CFrame.new(-3.95, -0.75, -4.55),
		color = cyanGlow,
		material = Enum.Material.Neon,
	})

	-- Right Arm: Oh's Titanic Seismic Maul + Emerald Reactor Core.
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightShoulder",
		size = Vector3.new(2.35, 2.1, 2.6),
		cframe = CFrame.new(3.55, 1.95, 0),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "RightArm",
		size = Vector3.new(1.55, 2.45, 1.6),
		cframe = CFrame.new(3.85, 0.35, -0.8) * CFrame.Angles(math.rad(55), 0, 0),
		color = armorDark,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	local mBase = CFrame.new(3.95, -0.45, -4.85) * CFrame.Angles(math.rad(-8), 0, 0)
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "FusionMaulShaft",
		size = Vector3.new(7.4, 0.6, 0.6),
		cframe = mBase * CFrame.Angles(0, math.rad(90), 0),
		color = steel,
		material = Enum.Material.Metal,
		shape = Enum.PartType.Cylinder,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "FusionMaulHeadA",
		size = Vector3.new(2.55, 2.55, 3.25),
		cframe = mBase * CFrame.new(0, 0, -2.9),
		color = armorCrimson,
		material = Enum.Material.Metal,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "FusionMaulHeadB",
		size = Vector3.new(2.55, 2.55, 3.25),
		cframe = mBase * CFrame.new(0, 0, -2.9) * CFrame.Angles(0, 0, math.rad(45)),
		color = armorDark,
		material = Enum.Material.DiamondPlate,
		castShadow = true,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "FusionMaulCore",
		size = Vector3.new(2.9, 2.9, 0.8),
		cframe = mBase * CFrame.new(0, 0, -2.9) * CFrame.Angles(0, 0, math.rad(22.5)),
		color = goldGlow,
		material = Enum.Material.Neon,
	})
	addLimb("rightArm", PIVOT_RIGHT_ARM, {
		name = "FusionMaulTip",
		size = Vector3.new(0.95, 0.95, 1.55),
		cframe = mBase * CFrame.new(0, 0, -5.25) * CFrame.Angles(0, 0, math.rad(45)),
		color = coreRed,
		material = Enum.Material.Neon,
	})

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

writeModel("TestSword.rbxmx", buildTestSword())
writeModel("WeaponGreatsword.rbxmx", buildGreatsword())
writeModel("WeaponSpikedMace.rbxmx", buildSpikedMace())
writeModel("WeaponShield.rbxmx", buildShield())
writeModel("WeaponDagger.rbxmx", buildDagger())
writeModel("WeaponStaff.rbxmx", buildStaff())
writeModel("DropHeal.rbxmx", buildDropHeal())
writeModel("DropDamage.rbxmx", buildDropDamage())
writeModel("DropSpeed.rbxmx", buildDropSpeed())
writeModel("DropDefense.rbxmx", buildDropDefense())
writeModel("EnemyMelee.rbxmx", buildEnemyMeleeVariant("EnemyMelee", "sword"))
writeModel("EnemyMeleeDual.rbxmx", buildEnemyMeleeVariant("EnemyMeleeDual", "dual"))
writeModel("EnemyMeleeAxe.rbxmx", buildEnemyMeleeVariant("EnemyMeleeAxe", "axe"))
writeModel("EnemyBattleAxe.rbxmx", buildEnemyBattleAxe())
writeModel("EnemyMeleeMace.rbxmx", buildEnemyMeleeVariant("EnemyMeleeMace", "mace"))
writeModel("EnemyRanged.rbxmx", buildEnemyRangedVariant("EnemyRanged", "rifle"))
writeModel("EnemyRangedShotgun.rbxmx", buildEnemyRangedVariant("EnemyRangedShotgun", "shotgun"))
writeModel("EnemyRangedCarbine.rbxmx", buildEnemyRangedVariant("EnemyRangedCarbine", "plasma"))
writeModel("EnemyRangedMinigun.rbxmx", buildEnemyRangedVariant("EnemyRangedMinigun", "minigun"))
writeModel("EnemyExploder.rbxmx", buildEnemyExploder())
writeModel("EnemyGrabber.rbxmx", buildEnemyGrabber())
writeModel("EnemyArea.rbxmx", buildEnemyArea())
writeModel("EnemyContact.rbxmx", buildEnemyContact())
writeModel("BossOh.rbxmx", buildBossOh())
writeModel("BossMy.rbxmx", buildBossMy())
writeModel("BossGon.rbxmx", buildBossGon())
writeModel("BossOhMyGon.rbxmx", buildBossOhMyGon())
