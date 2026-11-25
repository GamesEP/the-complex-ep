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
-- along -Z (matching RightGripAttachment's forward direction when welded to RightHand).
local function buildTestSword(): any
	local model = Instance.new("Model")
	model.Name = "TestSword"

	local grip = makePart({
		name = "Grip",
		size = Vector3.new(0.26, 0.26, 1.15),
		cframe = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(40, 44, 54),
		material = Enum.Material.SmoothPlastic,
		anchored = false,
	})
	grip.Parent = model

	local parts = {
		makePart({
			name = "Pommel",
			size = Vector3.new(0.42, 0.42, 0.42),
			cframe = CFrame.new(0, 0, 0.65),
			color = Color3.fromRGB(220, 185, 95),
			material = Enum.Material.Metal,
			shape = Enum.PartType.Ball,
			anchored = false,
		}),
		makePart({
			name = "Guard",
			size = Vector3.new(1.45, 0.28, 0.34),
			cframe = CFrame.new(0, 0, -0.62),
			color = Color3.fromRGB(230, 195, 105),
			material = Enum.Material.Metal,
			anchored = false,
			castShadow = true,
		}),
		makePart({
			name = "Blade",
			size = Vector3.new(0.42, 0.14, 3.6),
			cframe = CFrame.new(0, 0, -2.55),
			color = Color3.fromRGB(215, 225, 240),
			material = Enum.Material.Metal,
			anchored = false,
			castShadow = true,
		}),
		makePart({
			name = "BladeCore",
			size = Vector3.new(0.16, 0.18, 3.2),
			cframe = CFrame.new(0, 0, -2.45),
			color = Color3.fromRGB(115, 210, 255),
			material = Enum.Material.Neon,
			anchored = false,
		}),
		makePart({
			name = "BladeTip",
			size = Vector3.new(0.32, 0.13, 0.65),
			cframe = CFrame.new(0, 0, -4.45) * CFrame.Angles(0, math.rad(45), 0),
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

-- Tall violet grabber enemy with outstretched glowing claws facing -Z (CFrame.lookAt forward).
local function buildEnemyGrabber(): any
	local model = Instance.new("Model")
	model.Name = "EnemyGrabber"
	local bodyColor = Color3.fromRGB(155, 45, 210)
	local armColor = Color3.fromRGB(115, 30, 165)
	local glowColor = Color3.fromRGB(255, 85, 225)

	local body = makePart({
		name = "Body",
		size = Vector3.new(4.2, 5.8, 3.6),
		cframe = CFrame.new(0, 0, 0),
		color = bodyColor,
		material = Enum.Material.SmoothPlastic,
		anchored = true,
		castShadow = true,
	})
	body.Parent = model

	local parts = {
		makePart({
			name = "Visor",
			size = Vector3.new(2.5, 1.0, 0.35),
			cframe = CFrame.new(0, 1.35, -1.75),
			color = glowColor,
			material = Enum.Material.Neon,
			anchored = true,
		}),
		makePart({
			name = "LeftArm",
			size = Vector3.new(0.95, 1.1, 3.1),
			cframe = CFrame.new(-2.35, 0.35, -1.65),
			color = armColor,
			material = Enum.Material.SmoothPlastic,
			anchored = true,
			castShadow = true,
		}),
		makePart({
			name = "RightArm",
			size = Vector3.new(0.95, 1.1, 3.1),
			cframe = CFrame.new(2.35, 0.35, -1.65),
			color = armColor,
			material = Enum.Material.SmoothPlastic,
			anchored = true,
			castShadow = true,
		}),
		makePart({
			name = "LeftClaw",
			size = Vector3.new(0.75, 0.9, 1.55),
			cframe = CFrame.new(-1.85, 0.35, -3.45) * CFrame.Angles(0, math.rad(-28), 0),
			color = glowColor,
			material = Enum.Material.Neon,
			anchored = true,
		}),
		makePart({
			name = "RightClaw",
			size = Vector3.new(0.75, 0.9, 1.55),
			cframe = CFrame.new(1.85, 0.35, -3.45) * CFrame.Angles(0, math.rad(28), 0),
			color = glowColor,
			material = Enum.Material.Neon,
			anchored = true,
		}),
	}

	for _, part in ipairs(parts) do
		part.Parent = model
	end

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

writeModel("TestSword.rbxmx", buildTestSword())
writeModel("DropHeal.rbxmx", buildDropHeal())
writeModel("DropDamage.rbxmx", buildDropDamage())
writeModel("DropSpeed.rbxmx", buildDropSpeed())
writeModel("EnemyGrabber.rbxmx", buildEnemyGrabber())
