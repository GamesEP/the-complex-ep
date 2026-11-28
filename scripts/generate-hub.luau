--!strict
--[[
	Generates the tracked 3D Hub model `assets/models/ComplexHub.rbxmx` using Lune (`@lune/roblox`).

	Run whenever the Hub geometry changes:
		lune run scripts/generate-hub.luau

	Visual theme: industrial staging bay ("El Complejo — Vestíbulo de Despliegue") designed for the
	fixed isometric camera (`CAMERA_YAW = 45`, `CAMERA_PITCH = 50`):
	  - 80x80 floor slab with top face at y = 0 (`PrimaryPart = Floor`, `WorldPivot = origin`).
	  - North (-Z) and West (-X) hero backdrop walls with an armored Sector Elevator Bay, status
	    screens, overhead coolant pipes, and cyan/amber industrial accents.
	  - South (+Z) and East (+X) low cutaway curbs with invisible full-height containment hulls so
	    the isometric camera stays completely unobstructed while avatars cannot leave the bay.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local Color3 = roblox.Color3
local Enum = roblox.Enum

local OUT_DIR = "assets/models"
local ROOM = 80
local HALF = ROOM / 2 -- 40
local WALL_T = 3
local BACK_WALL_H = 18
local FRONT_CURB_H = 2.4
local NO_CLIMB_H = 36

local C_CONCRETE = Color3.fromRGB(44, 50, 60)
local C_CONCRETE_DARK = Color3.fromRGB(32, 36, 44)
local C_WALL = Color3.fromRGB(38, 44, 54)
local C_STEEL = Color3.fromRGB(56, 64, 78)
local C_STEEL_DARK = Color3.fromRGB(28, 32, 40)
local C_STEEL_LIGHT = Color3.fromRGB(96, 108, 126)
local C_HAZARD = Color3.fromRGB(235, 178, 42)
local C_CYAN = Color3.fromRGB(72, 220, 255)
local C_AMBER = Color3.fromRGB(255, 168, 58)
local C_GLASS = Color3.fromRGB(95, 165, 210)

local function folder(name: string, parent: any): any
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function part(props: {
	name: string,
	size: any,
	cframe: any,
	color: any,
	material: any?,
	transparency: number?,
	shape: any?,
	canCollide: boolean?,
	castShadow: boolean?,
	parent: any,
}): any
	local p = Instance.new("Part")
	p.Name = props.name
	p.Size = props.size
	p.CFrame = props.cframe
	p.Color = props.color
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	if props.shape then
		p.Shape = props.shape
	end
	p.Anchored = true
	local collide = if props.canCollide ~= nil then props.canCollide else true
	p.CanCollide = collide
	p.CanQuery = collide
	p.CanTouch = collide
	p.CastShadow = if props.castShadow ~= nil then props.castShadow else collide
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = props.parent
	return p
end

local function addLight(parent: any, color: any, range: number, brightness: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Shadows = false
	light.Parent = parent
end

local function addNoClimbHull(name: string, sx: number, sz: number, cf: any, parent: any): any
	return part({
		name = name,
		size = Vector3.new(sx, NO_CLIMB_H, sz),
		cframe = cf * CFrame.new(0, NO_CLIMB_H / 2, 0),
		color = C_WALL,
		transparency = 1,
		canCollide = true,
		castShadow = false,
		parent = parent,
	})
end

local function buildComplexHub(): any
	local model = Instance.new("Model")
	model.Name = "ComplexHub"

	-- Primary floor slab: top face sits flush at y = 0.
	local floor = part({
		name = "Floor",
		size = Vector3.new(ROOM, 4, ROOM),
		cframe = CFrame.new(0, -2, 0),
		color = C_CONCRETE,
		material = Enum.Material.Concrete,
		parent = model,
	})

	local floorDetail = folder("FloorDetail", model)
	-- Central deployment staging pad (non-colliding so avatars walk smoothly over it).
	part({
		name = "StagingPadBase",
		size = Vector3.new(26, 0.16, 26),
		cframe = CFrame.new(0, 0.08, 2),
		color = C_CONCRETE_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		castShadow = false,
		parent = floorDetail,
	})
	local ringColor = C_CYAN
	local ringParts = {
		{ Vector3.new(26.4, 0.18, 0.6), CFrame.new(0, 0.09, -11) },
		{ Vector3.new(26.4, 0.18, 0.6), CFrame.new(0, 0.09, 15) },
		{ Vector3.new(0.6, 0.18, 26.4), CFrame.new(-13, 0.09, 2) },
		{ Vector3.new(0.6, 0.18, 26.4), CFrame.new(13, 0.09, 2) },
	}
	for i, spec in ipairs(ringParts) do
		local strip = part({
			name = `AccentStrip_Pad{i}`,
			size = spec[1],
			cframe = spec[2],
			color = ringColor,
			material = Enum.Material.Neon,
			canCollide = false,
			castShadow = false,
			parent = floorDetail,
		})
		if i == 1 then
			addLight(strip, C_CYAN, 36, 1.4)
		end
	end

	-- Runway chevron strips leading from spawn (+Z) to the North elevator bay (-Z).
	for idx = -1, 1, 2 do
		part({
			name = `HazardLine_{idx}`,
			size = Vector3.new(0.8, 0.12, 22),
			cframe = CFrame.new(idx * 9, 0.06, -24),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			castShadow = false,
			parent = floorDetail,
		})
	end

	-- Perimeter walls: North & West tall hero backdrops; South & East low cutaway curbs + invisible hulls.
	local walls = folder("Walls", model)
	part({
		name = "WallNorth",
		size = Vector3.new(ROOM + 2 * WALL_T, BACK_WALL_H, WALL_T),
		cframe = CFrame.new(0, BACK_WALL_H / 2, -(HALF + WALL_T / 2)),
		color = C_WALL,
		material = Enum.Material.Concrete,
		parent = walls,
	})
	part({
		name = "WallWest",
		size = Vector3.new(WALL_T, BACK_WALL_H, ROOM),
		cframe = CFrame.new(-(HALF + WALL_T / 2), BACK_WALL_H / 2, 0),
		color = C_WALL,
		material = Enum.Material.Concrete,
		parent = walls,
	})
	part({
		name = "CurbSouth",
		size = Vector3.new(ROOM + 2 * WALL_T, FRONT_CURB_H, WALL_T),
		cframe = CFrame.new(0, FRONT_CURB_H / 2, HALF + WALL_T / 2),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		parent = walls,
	})
	part({
		name = "CurbEast",
		size = Vector3.new(WALL_T, FRONT_CURB_H, ROOM),
		cframe = CFrame.new(HALF + WALL_T / 2, FRONT_CURB_H / 2, 0),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		parent = walls,
	})
	addNoClimbHull("BarrierNorth", ROOM + 2 * WALL_T, WALL_T, CFrame.new(0, 0, -(HALF + WALL_T / 2)), walls)
	addNoClimbHull("BarrierWest", WALL_T, ROOM, CFrame.new(-(HALF + WALL_T / 2), 0, 0), walls)
	addNoClimbHull("BarrierSouth", ROOM + 2 * WALL_T, WALL_T, CFrame.new(0, 0, HALF + WALL_T / 2), walls)
	addNoClimbHull("BarrierEast", WALL_T, ROOM, CFrame.new(HALF + WALL_T / 2, 0, 0), walls)

	-- North Hero Landmark: Sector Elevator Bay (where squads deploy into Floor 1).
	local elevator = folder("SectorElevator", model)
	local bayZ = -(HALF - 1.2)
	part({
		name = "FrameTop",
		size = Vector3.new(24, 3.2, 3.4),
		cframe = CFrame.new(0, 15.2, bayZ),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		parent = elevator,
	})
	for _, side in ipairs({ -1, 1 }) do
		part({
			name = if side < 0 then "FrameLeft" else "FrameRight",
			size = Vector3.new(3.4, 15, 3.4),
			cframe = CFrame.new(side * 10.6, 7.5, bayZ),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			parent = elevator,
		})
		part({
			name = if side < 0 then "DoorLeft" else "DoorRight",
			size = Vector3.new(8.6, 13.4, 1.2),
			cframe = CFrame.new(side * 4.4, 6.7, bayZ - 0.2),
			color = C_STEEL,
			material = Enum.Material.DiamondPlate,
			parent = elevator,
		})
		part({
			name = `AccentStrip_Elevator{side}`,
			size = Vector3.new(0.45, 13, 0.45),
			cframe = CFrame.new(side * 9.0, 6.8, bayZ + 1.5),
			color = C_AMBER,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = elevator,
		})
	end
	local statusBar = part({
		name = "ElevatorStatusBar",
		size = Vector3.new(18, 0.85, 0.6),
		cframe = CFrame.new(0, 14.3, bayZ + 1.7),
		color = C_CYAN,
		material = Enum.Material.Neon,
		canCollide = false,
		parent = elevator,
	})
	addLight(statusBar, C_CYAN, 42, 2.0)

	-- West Wall Hero Landmark: Tactical Observation Window & Staging Consoles.
	local props = folder("HubProps", model)
	local westX = -(HALF - 1.0)
	part({
		name = "ObsFrame",
		size = Vector3.new(1.8, 7.2, 26),
		cframe = CFrame.new(westX, 10.2, -2),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		parent = props,
	})
	local obsGlass = part({
		name = "ObsGlass",
		size = Vector3.new(0.5, 5.4, 23.6),
		cframe = CFrame.new(westX + 0.5, 10.2, -2),
		color = C_GLASS,
		material = Enum.Material.Glass,
		transparency = 0.35,
		canCollide = false,
		parent = props,
	})
	addLight(obsGlass, C_CYAN, 30, 1.2)

	-- Terminal consoles along the West wall (solid + anti-climb hulls).
	for idx, zPos in ipairs({ -16, 12 }) do
		local cf = CFrame.new(-(HALF - 4.2), 0, zPos)
		part({
			name = `ConsoleBase_{idx}`,
			size = Vector3.new(4.2, 3.6, 8.0),
			cframe = cf * CFrame.new(0, 1.8, 0),
			color = C_STEEL,
			material = Enum.Material.Metal,
			parent = props,
		})
		local screen = part({
			name = `ConsoleScreen_{idx}`,
			size = Vector3.new(0.4, 2.4, 6.4),
			cframe = cf * CFrame.new(1.9, 4.6, 0) * CFrame.Angles(0, 0, math.rad(-14)),
			color = C_CYAN,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = props,
		})
		addLight(screen, C_CYAN, 18, 1.0)
		addNoClimbHull(`ConsoleHull_{idx}`, 4.6, 8.4, cf, props)
	end

	-- Four decorative structural corner columns framing the Hub bay.
	local cornerPositions = {
		{ -HALF + 4, -HALF + 4 },
		{ HALF - 4, -HALF + 4 },
		{ -HALF + 4, HALF - 4 },
	}
	for idx, cp in ipairs(cornerPositions) do
		local cf = CFrame.new(cp[1], 0, cp[2])
		part({
			name = `Column_{idx}`,
			size = Vector3.new(4.5, BACK_WALL_H, 4.5),
			cframe = cf * CFrame.new(0, BACK_WALL_H / 2, 0),
			color = C_STEEL_LIGHT,
			material = Enum.Material.Metal,
			parent = props,
		})
		part({
			name = `AccentStrip_Col{idx}`,
			size = Vector3.new(4.7, 0.5, 4.7),
			cframe = cf * CFrame.new(0, 12.5, 0),
			color = C_AMBER,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = props,
		})
		addNoClimbHull(`ColumnHull_{idx}`, 4.8, 4.8, cf, props)
	end

	model.PrimaryPart = floor
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end

local hubModel = buildComplexHub()
local xml = roblox.serializeModel({ hubModel }, true)
local outPath = `{OUT_DIR}/ComplexHub.rbxmx`
fs.writeFile(outPath, xml)
print(`wrote {outPath} ({#xml} bytes)`)
