--!strict
--[[
	Generates the tracked 3D arena model `assets/models/ComplexArena.rbxmx` using Lune
	(`@lune/roblox`).

	Run whenever the arena geometry changes:
		lune run scripts/generate-arena.luau

	Visual theme: industrial sci-fi facility ("The Complex") designed for the fixed isometric
	camera (`CAMERA_YAW = 45`, `CAMERA_PITCH = 50`, positioned at +X/+Z looking toward -X/-Z):
	  - North (-Z) and West (-X) are tall, detailed hero backdrop walls (structural columns,
	    armored sector blast door, observation bay window, overhead pipes, amber/cyan lighting).
	  - South (+Z) and East (+X) are low cutaway curbs with industrial railings plus invisible
	    containment walls so the camera never gets blocked while players stay inside the room.
	  - Floor footprint is 140x140 studs with top face at y = 0 and all decorative floor plates
	    non-colliding so high-speed dashes and lunges never snag.

	Stamps explicit `PrimaryPart` (`Floor`) and `WorldPivot` at the origin (CLAUDE.md).
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local Color3 = roblox.Color3
local Enum = roblox.Enum

local OUT_DIR = "assets/models"
local ROOM = 140
local HALF = ROOM / 2 -- 70
local WALL_T = 3
local BACK_WALL_H = 18
local FRONT_CURB_H = 2.6
-- Invisible full-height anti-climb barrier height: stops jumping or double-jumping onto any
-- pillar, cover bunker, crate, tank, console, or perimeter curb while keeping sightlines clear.
local NO_CLIMB_H = 36

-- Industrial sci-fi palette: dark slate concrete, gunmetal steel, hazard yellow, cyan & amber glow.
local C_CONCRETE = Color3.fromRGB(48, 52, 60)
local C_CONCRETE_DARK = Color3.fromRGB(36, 40, 48)
local C_WALL = Color3.fromRGB(42, 46, 54)
local C_STEEL = Color3.fromRGB(58, 64, 76)
local C_STEEL_DARK = Color3.fromRGB(30, 34, 42)
local C_STEEL_LIGHT = Color3.fromRGB(92, 100, 114)
local C_HAZARD = Color3.fromRGB(220, 172, 40)
local C_CYAN = Color3.fromRGB(80, 215, 255)
local C_AMBER = Color3.fromRGB(255, 168, 58)
local C_GLASS = Color3.fromRGB(110, 165, 200)

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

-- Invisible full-height collision column (`Y = 0..NO_CLIMB_H`) placed over solid structures and
-- props so players cannot walk through them OR jump/double-jump on top of them. `CanQuery = true`
-- lets client dash/lunge wall-stop spherecasts detect every obstacle cleanly.
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

--=============================================================================
-- Floor & Flush Industrial Decking (all decorative plates CanCollide = false)
--=============================================================================

local function buildFloorDetails(root: any)
	local f = folder("FloorDetails", root)

	-- Central entry elevator pad (24x24) where players spawn.
	part({
		name = "CenterPadBase",
		size = Vector3.new(24, 0.08, 24),
		cframe = CFrame.new(0, 0.02, 0),
		color = C_STEEL_DARK,
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = f,
	})
	part({
		name = "CenterPadInner",
		size = Vector3.new(18, 0.1, 18),
		cframe = CFrame.new(0, 0.03, 0),
		color = C_CONCRETE_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = f,
	})

	-- Glowing cyan frame bars around the spawn elevator pad.
	local padEdge = 11.4
	for _, spec in ipairs({
		{ "PadGlowN", Vector3.new(16, 0.12, 0.45), CFrame.new(0, 0.03, -padEdge) },
		{ "PadGlowS", Vector3.new(16, 0.12, 0.45), CFrame.new(0, 0.03, padEdge) },
		{ "PadGlowW", Vector3.new(0.45, 0.12, 16), CFrame.new(-padEdge, 0.03, 0) },
		{ "PadGlowE", Vector3.new(0.45, 0.12, 16), CFrame.new(padEdge, 0.03, 0) },
	}) do
		part({
			name = spec[1],
			size = spec[2],
			cframe = spec[3],
			color = C_CYAN,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = f,
		})
	end

	-- Four amber corner brackets on the elevator pad.
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			part({
				name = `PadCorner_{sx}_{sz}`,
				size = Vector3.new(3.2, 0.12, 3.2),
				cframe = CFrame.new(sx * 10.6, 0.03, sz * 10.6),
				color = C_HAZARD,
				material = Enum.Material.Metal,
				canCollide = false,
				parent = f,
			})
		end
	end

	-- Main leading walkways: North toward Blast Door, West toward Observation Bay, plus subtle East/South lanes.
	part({
		name = "WalkwayNorth",
		size = Vector3.new(14, 0.06, HALF - 14),
		cframe = CFrame.new(0, 0.01, -(12 + (HALF - 14) / 2)),
		color = C_CONCRETE_DARK,
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = f,
	})
	part({
		name = "WalkwayWest",
		size = Vector3.new(HALF - 14, 0.06, 14),
		cframe = CFrame.new(-(12 + (HALF - 14) / 2), 0.01, 0),
		color = C_CONCRETE_DARK,
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = f,
	})
	part({
		name = "WalkwaySouth",
		size = Vector3.new(10, 0.06, HALF - 16),
		cframe = CFrame.new(0, 0.01, 12 + (HALF - 16) / 2),
		color = C_CONCRETE_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = f,
	})
	part({
		name = "WalkwayEast",
		size = Vector3.new(HALF - 16, 0.06, 10),
		cframe = CFrame.new(12 + (HALF - 16) / 2, 0.01, 0),
		color = C_CONCRETE_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = f,
	})

	-- Yellow industrial safety lines flanking the North and West corridors.
	for _, side in ipairs({ -7.4, 7.4 }) do
		part({
			name = `LaneLineN_{side}`,
			size = Vector3.new(0.45, 0.08, HALF - 16),
			cframe = CFrame.new(side, 0.02, -(13 + (HALF - 16) / 2)),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = f,
		})
		part({
			name = `LaneLineW_{side}`,
			size = Vector3.new(HALF - 16, 0.08, 0.45),
			cframe = CFrame.new(-(13 + (HALF - 16) / 2), 0.02, side),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = f,
		})
	end

	-- Recessed steel floor expansion seams creating crisp industrial bays.
	for _, offset in ipairs({ -44, -22, 22, 44 }) do
		part({
			name = `SeamX_{offset}`,
			size = Vector3.new(ROOM - 8, 0.04, 0.4),
			cframe = CFrame.new(0, 0.005, offset),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = f,
		})
		part({
			name = `SeamZ_{offset}`,
			size = Vector3.new(0.4, 0.04, ROOM - 8),
			cframe = CFrame.new(offset, 0.005, 0),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = f,
		})
	end

	-- Perimeter steel grate drainage strips hugging all four edges.
	local grateInset = HALF - 3
	for _, spec in ipairs({
		{ "GrateN", Vector3.new(ROOM - 4, 0.06, 4.5), CFrame.new(0, 0.01, -grateInset) },
		{ "GrateS", Vector3.new(ROOM - 4, 0.06, 4.5), CFrame.new(0, 0.01, grateInset) },
		{ "GrateW", Vector3.new(4.5, 0.06, ROOM - 12), CFrame.new(-grateInset, 0.01, 0) },
		{ "GrateE", Vector3.new(4.5, 0.06, ROOM - 12), CFrame.new(grateInset, 0.01, 0) },
	}) do
		part({
			name = spec[1],
			size = spec[2],
			cframe = spec[3],
			color = C_STEEL_DARK,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			parent = f,
		})
	end

	-- Four tactical sector floor plates in the outer quadrants for spatial landmarks.
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local cx, cz = sx * 38, sz * 38
			part({
				name = `QuadPlate_{sx}_{sz}`,
				size = Vector3.new(16, 0.06, 16),
				cframe = CFrame.new(cx, 0.015, cz),
				color = C_CONCRETE_DARK,
				material = Enum.Material.Metal,
				canCollide = false,
				parent = f,
			})
			part({
				name = `QuadTrim_{sx}_{sz}`,
				size = Vector3.new(12, 0.08, 0.5),
				cframe = CFrame.new(cx, 0.02, cz - sz * 6.5),
				color = C_HAZARD,
				material = Enum.Material.SmoothPlastic,
				canCollide = false,
				parent = f,
			})
		end
	end

	-- Four flush recessed industrial turbine vents in the mid-arena diagonals (±21, ±21).
	-- All parts stay flush (`CanCollide = false`) so movement and dashes glide over cleanly.
	for idx, spec in ipairs({
		{ -21, -21, C_AMBER },
		{ 21, -21, C_CYAN },
		{ -21, 21, C_CYAN },
		{ 21, 21, C_AMBER },
	}) do
		local vx, vz, vglow = spec[1], spec[2], spec[3]
		part({
			name = `FloorVentRim_{idx}`,
			size = Vector3.new(9.2, 0.06, 9.2),
			cframe = CFrame.new(vx, 0.012, vz),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = f,
		})
		part({
			name = `FloorVentGlow_{idx}`,
			size = Vector3.new(7.4, 0.07, 7.4),
			cframe = CFrame.new(vx, 0.018, vz),
			color = vglow,
			material = Enum.Material.Neon,
			transparency = 0.55,
			canCollide = false,
			parent = f,
		})
		for slat = -2, 2 do
			part({
				name = `FloorVentSlat_{idx}_{slat}`,
				size = Vector3.new(8.2, 0.085, 0.72),
				cframe = CFrame.new(vx, 0.026, vz + slat * 1.45),
				color = C_STEEL,
				material = Enum.Material.DiamondPlate,
				canCollide = false,
				parent = f,
			})
		end
	end

	-- Flush yellow/cyan directional floor chevrons guiding eyes along the 4 main lanes.
	for _, dist in ipairs({ 17, 29 }) do
		part({
			name = `ChevronN_{dist}`,
			size = Vector3.new(5.5, 0.07, 0.65),
			cframe = CFrame.new(0, 0.02, -dist),
			color = C_CYAN,
			material = Enum.Material.Neon,
			transparency = 0.35,
			canCollide = false,
			parent = f,
		})
		part({
			name = `ChevronW_{dist}`,
			size = Vector3.new(0.65, 0.07, 5.5),
			cframe = CFrame.new(-dist, 0.02, 0),
			color = C_AMBER,
			material = Enum.Material.Neon,
			transparency = 0.35,
			canCollide = false,
			parent = f,
		})
	end
end

--=============================================================================
-- Hero Backdrop Walls: North (-Z) & West (-X)
--=============================================================================

local function buildHeroWalls(root: any)
	local north = folder("NorthWall", root)
	local west = folder("WestWall", root)

	-- Main reinforced concrete wall slabs.
	part({
		name = "NorthSlab",
		size = Vector3.new(ROOM + WALL_T * 2, BACK_WALL_H, WALL_T),
		cframe = CFrame.new(0, BACK_WALL_H / 2, -(HALF + WALL_T / 2)),
		color = C_WALL,
		material = Enum.Material.Concrete,
		parent = north,
	})
	part({
		name = "WestSlab",
		size = Vector3.new(WALL_T, BACK_WALL_H, ROOM + WALL_T * 2),
		cframe = CFrame.new(-(HALF + WALL_T / 2), BACK_WALL_H / 2, 0),
		color = C_WALL,
		material = Enum.Material.Concrete,
		parent = west,
	})

	-- Upper steel crown cornice along both hero walls.
	part({
		name = "NorthCrown",
		size = Vector3.new(ROOM + WALL_T * 2 + 2, 2.2, WALL_T + 2),
		cframe = CFrame.new(0, BACK_WALL_H + 0.6, -(HALF + WALL_T / 2)),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		parent = north,
	})
	part({
		name = "WestCrown",
		size = Vector3.new(WALL_T + 2, 2.2, ROOM + WALL_T * 2 + 2),
		cframe = CFrame.new(-(HALF + WALL_T / 2), BACK_WALL_H + 0.6, 0),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		parent = west,
	})

	-- Lower steel dado + hazard stripe running along both walls (skipping the blast door gap on North).
	for _, xSpan in ipairs({ { -44, 52 }, { 44, 52 } }) do
		part({
			name = `NorthDado_{xSpan[1]}`,
			size = Vector3.new(xSpan[2], 3.4, 0.8),
			cframe = CFrame.new(xSpan[1], 1.7, -HALF + 0.35),
			color = C_STEEL_DARK,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			parent = north,
		})
		part({
			name = `NorthHazard_{xSpan[1]}`,
			size = Vector3.new(xSpan[2], 0.55, 0.88),
			cframe = CFrame.new(xSpan[1], 3.55, -HALF + 0.36),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = north,
		})
	end

	part({
		name = "WestDado",
		size = Vector3.new(0.8, 3.4, ROOM - 4),
		cframe = CFrame.new(-HALF + 0.35, 1.7, 0),
		color = C_STEEL_DARK,
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = west,
	})
	part({
		name = "WestHazard",
		size = Vector3.new(0.88, 0.55, ROOM - 4),
		cframe = CFrame.new(-HALF + 0.36, 3.55, 0),
		color = C_HAZARD,
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = west,
	})

	-- Structural steel buttress ribs + wall light sconces spaced along both hero walls.
	local ribPositions = { -56, -28, 28, 56 }
	for i, pos in ipairs(ribPositions) do
		local lightColor = if i % 2 == 1 then C_CYAN else C_AMBER

		-- North rib + sconce.
		part({
			name = `NorthRib_{i}`,
			size = Vector3.new(3.2, BACK_WALL_H, 2.6),
			cframe = CFrame.new(pos, BACK_WALL_H / 2, -HALF + 0.8),
			color = C_STEEL,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = north,
		})
		local nLamp = part({
			name = `NorthLamp_{i}`,
			size = Vector3.new(1.2, 4.5, 0.45),
			cframe = CFrame.new(pos, 11.5, -HALF + 2.15),
			color = lightColor,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = north,
		})
		addLight(nLamp, lightColor, 34, 0.9)

		-- West rib + sconce.
		part({
			name = `WestRib_{i}`,
			size = Vector3.new(2.6, BACK_WALL_H, 3.2),
			cframe = CFrame.new(-HALF + 0.8, BACK_WALL_H / 2, pos),
			color = C_STEEL,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = west,
		})
		local wLamp = part({
			name = `WestLamp_{i}`,
			size = Vector3.new(0.45, 4.5, 1.2),
			cframe = CFrame.new(-HALF + 2.15, 11.5, pos),
			color = lightColor,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = west,
		})
		addLight(wLamp, lightColor, 34, 0.9)
	end

	-- Overhead industrial conduit pipes running along the upper walls.
	local pipes = folder("OverheadPipes", root)
	for idx, py in ipairs({ 14.5, 16.2 }) do
		part({
			name = `NorthPipe_{idx}`,
			size = Vector3.new(ROOM - 8, 0.9, 0.9),
			cframe = CFrame.new(0, py, -HALF + 1.4),
			color = if idx == 1 then C_STEEL_LIGHT else C_STEEL_DARK,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			canCollide = false,
			parent = pipes,
		})
		part({
			name = `WestPipe_{idx}`,
			size = Vector3.new(ROOM - 8, 0.9, 0.9),
			cframe = CFrame.new(-HALF + 1.4, py, 0) * CFrame.Angles(0, math.rad(90), 0),
			color = if idx == 1 then C_STEEL_LIGHT else C_STEEL_DARK,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			canCollide = false,
			parent = pipes,
		})
	end
end

--=============================================================================
-- Hero Landmarks: North Sector Blast Door & West Observation Bay
--=============================================================================

local function buildLandmarks(root: any)
	-- North Sector Blast Door (visual exit gate to next room/floor).
	local door = folder("BlastDoor", root)
	part({
		name = "FrameLeft",
		size = Vector3.new(3.2, 15, 3.6),
		cframe = CFrame.new(-10.5, 7.5, -HALF + 1.1),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = door,
	})
	part({
		name = "FrameRight",
		size = Vector3.new(3.2, 15, 3.6),
		cframe = CFrame.new(10.5, 7.5, -HALF + 1.1),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = door,
	})
	part({
		name = "FrameHeader",
		size = Vector3.new(25, 3.4, 4.0),
		cframe = CFrame.new(0, 15.2, -HALF + 1.2),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = door,
	})
	-- Split armored blast leaves with central seam.
	part({
		name = "DoorLeft",
		size = Vector3.new(8.6, 13.4, 1.4),
		cframe = CFrame.new(-4.5, 6.7, -HALF + 0.5),
		color = C_STEEL,
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = door,
	})
	part({
		name = "DoorRight",
		size = Vector3.new(8.6, 13.4, 1.4),
		cframe = CFrame.new(4.5, 6.7, -HALF + 0.5),
		color = C_STEEL,
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = door,
	})
	-- Hazard chevrons on door frame pillars.
	for _, sx in ipairs({ -10.5, 10.5 }) do
		part({
			name = `DoorHazard_{sx}`,
			size = Vector3.new(1.1, 10, 0.35),
			cframe = CFrame.new(sx, 5.5, -HALF + 2.95),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = door,
		})
	end
	-- Overhead glowing cyan sector lock bar.
	local headerGlow = part({
		name = "DoorStatusBar",
		size = Vector3.new(17, 1.0, 0.5),
		cframe = CFrame.new(0, 15.2, -HALF + 3.25),
		color = C_CYAN,
		material = Enum.Material.Neon,
		canCollide = false,
		parent = door,
	})
	addLight(headerGlow, C_CYAN, 42, 1.5)

	-- West Observation Bay (tinted control room window overlooking the arena).
	local bay = folder("ObservationBay", root)
	part({
		name = "BayFrameBottom",
		size = Vector3.new(3.2, 2.2, 28),
		cframe = CFrame.new(-HALF + 1.0, 5.6, 0),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = bay,
	})
	part({
		name = "BayFrameTop",
		size = Vector3.new(3.2, 2.2, 28),
		cframe = CFrame.new(-HALF + 1.0, 13.6, 0),
		color = C_STEEL_DARK,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = bay,
	})
	for _, zPos in ipairs({ -13.2, -4.4, 4.4, 13.2 }) do
		part({
			name = `BayMullion_{zPos}`,
			size = Vector3.new(2.8, 8.2, 1.4),
			cframe = CFrame.new(-HALF + 1.0, 9.6, zPos),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = bay,
		})
	end
	-- Recessed dark control booth backing + glowing console strip + smoky glass pane.
	part({
		name = "BayInteriorBack",
		size = Vector3.new(0.6, 6.2, 25.5),
		cframe = CFrame.new(-HALF + 0.1, 9.6, 0),
		color = Color3.fromRGB(16, 22, 32),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = bay,
	})
	local bayConsole = part({
		name = "BayConsoleGlow",
		size = Vector3.new(0.4, 1.1, 22),
		cframe = CFrame.new(-HALF + 0.5, 7.6, 0),
		color = C_AMBER,
		material = Enum.Material.Neon,
		canCollide = false,
		parent = bay,
	})
	addLight(bayConsole, C_AMBER, 36, 1.2)
	part({
		name = "BayGlass",
		size = Vector3.new(0.4, 6.4, 25.5),
		cframe = CFrame.new(-HALF + 1.5, 9.6, 0),
		color = C_GLASS,
		material = Enum.Material.Glass,
		transparency = 0.45,
		canCollide = false,
		parent = bay,
	})
end

--=============================================================================
-- Cutaway Front Edges (South +Z & East +X) + Invisible Containment + Corners
--=============================================================================

local function buildCutawayAndCorners(root: any)
	local front = folder("CutawayEdges", root)
	local bounds = folder("Bounds", root)

	-- Low concrete curbs so the isometric camera at (+X, +Z) has an unobstructed view.
	part({
		name = "SouthCurb",
		size = Vector3.new(ROOM + WALL_T * 2, FRONT_CURB_H, WALL_T),
		cframe = CFrame.new(0, FRONT_CURB_H / 2, HALF + WALL_T / 2),
		color = C_STEEL_DARK,
		material = Enum.Material.Concrete,
		parent = front,
	})
	part({
		name = "EastCurb",
		size = Vector3.new(WALL_T, FRONT_CURB_H, ROOM + WALL_T * 2),
		cframe = CFrame.new(HALF + WALL_T / 2, FRONT_CURB_H / 2, 0),
		color = C_STEEL_DARK,
		material = Enum.Material.Concrete,
		parent = front,
	})

	-- Sleek cyan safety light rail topping the cutaway curbs.
	part({
		name = "SouthEdgeGlow",
		size = Vector3.new(ROOM - 4, 0.3, 0.45),
		cframe = CFrame.new(0, FRONT_CURB_H + 0.15, HALF + 0.6),
		color = C_CYAN,
		material = Enum.Material.Neon,
		canCollide = false,
		parent = front,
	})
	part({
		name = "EastEdgeGlow",
		size = Vector3.new(0.45, 0.3, ROOM - 4),
		cframe = CFrame.new(HALF + 0.6, FRONT_CURB_H + 0.15, 0),
		color = C_CYAN,
		material = Enum.Material.Neon,
		canCollide = false,
		parent = front,
	})

	-- Low steel rail posts along South and East curbs.
	for _, offset in ipairs({ -56, -28, 0, 28, 56 }) do
		part({
			name = `SouthPost_{offset}`,
			size = Vector3.new(1.4, FRONT_CURB_H + 1.2, 1.6),
			cframe = CFrame.new(offset, (FRONT_CURB_H + 1.2) / 2, HALF + 1.2),
			color = C_STEEL,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = front,
		})
		part({
			name = `EastPost_{offset}`,
			size = Vector3.new(1.6, FRONT_CURB_H + 1.2, 1.4),
			cframe = CFrame.new(HALF + 1.2, (FRONT_CURB_H + 1.2) / 2, offset),
			color = C_STEEL,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = front,
		})
	end

	-- Invisible full-height containment shell (all 4 walls + ceiling at Y = NO_CLIMB_H) so no
	-- player can ever climb onto a curb/wall or get flung out of the arena.
	local boundT = 4
	part({
		name = "NorthBound",
		size = Vector3.new(ROOM + boundT * 2, NO_CLIMB_H, boundT),
		cframe = CFrame.new(0, NO_CLIMB_H / 2, -(HALF + boundT / 2 - 0.5)),
		color = C_WALL,
		transparency = 1,
		canCollide = true,
		castShadow = false,
		parent = bounds,
	})
	part({
		name = "WestBound",
		size = Vector3.new(boundT, NO_CLIMB_H, ROOM + boundT * 2),
		cframe = CFrame.new(-(HALF + boundT / 2 - 0.5), NO_CLIMB_H / 2, 0),
		color = C_WALL,
		transparency = 1,
		canCollide = true,
		castShadow = false,
		parent = bounds,
	})
	part({
		name = "SouthBound",
		size = Vector3.new(ROOM + boundT * 2, NO_CLIMB_H, boundT),
		cframe = CFrame.new(0, NO_CLIMB_H / 2, HALF + boundT / 2 - 0.5),
		color = C_WALL,
		transparency = 1,
		canCollide = true,
		castShadow = false,
		parent = bounds,
	})
	part({
		name = "EastBound",
		size = Vector3.new(boundT, NO_CLIMB_H, ROOM + boundT * 2),
		cframe = CFrame.new(HALF + boundT / 2 - 0.5, NO_CLIMB_H / 2, 0),
		color = C_WALL,
		transparency = 1,
		canCollide = true,
		castShadow = false,
		parent = bounds,
	})
	part({
		name = "CeilingBound",
		size = Vector3.new(ROOM + boundT * 2, 4, ROOM + boundT * 2),
		cframe = CFrame.new(0, NO_CLIMB_H + 2, 0),
		color = C_WALL,
		transparency = 1,
		canCollide = true,
		castShadow = false,
		parent = bounds,
	})

	-- Heavy corner pylons on NW, NE, and SW corners (SE stays low to keep the camera corner open).
	local corners = folder("CornerPylons", root)
	for _, spec in ipairs({
		{ "NW", -HALF - 0.5, -HALF - 0.5, BACK_WALL_H + 2.5, C_AMBER },
		{ "NE", HALF + 0.5, -HALF - 0.5, BACK_WALL_H + 1.0, C_CYAN },
		{ "SW", -HALF - 0.5, HALF + 0.5, BACK_WALL_H + 1.0, C_CYAN },
		{ "SE", HALF + 0.8, HALF + 0.8, FRONT_CURB_H + 1.8, C_AMBER },
	}) do
		local name, x, z, h, glow = spec[1], spec[2], spec[3], spec[4], spec[5]
		part({
			name = `Pylon_{name}`,
			size = Vector3.new(6.5, h, 6.5),
			cframe = CFrame.new(x, h / 2, z),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = corners,
		})
		part({
			name = `Beacon_{name}`,
			size = Vector3.new(4.2, 0.7, 4.2),
			cframe = CFrame.new(x, h + 0.35, z),
			color = glow,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = corners,
		})
	end
end

--=============================================================================
-- Interior Cover Structures (4 Quadrant Reactor Pillars) & Industrial Decor
--=============================================================================

local function buildInteriorStructures(root: any)
	local structures = folder("ArenaStructures", root)

	-- 4 solid tactical reactor pillars at `(±38, ±38)` matching `Config.ARENA_PILLARS` (radius 5.6).
	-- The SE (+38, +38) reactor is kept shorter (8.5 studs) so the isometric camera at (+X, +Z)
	-- always has a clean sightline into the center arena.
	local pillars = {
		{ name = "NW", x = -38, z = -38, h = 13.5, glow = C_AMBER },
		{ name = "NE", x = 38, z = -38, h = 13.5, glow = C_CYAN },
		{ name = "SW", x = -38, z = 38, h = 12.5, glow = C_CYAN },
		{ name = "SE", x = 38, z = 38, h = 8.5, glow = C_AMBER },
	}

	for _, p in ipairs(pillars) do
		local g = folder(`ReactorPillar_{p.name}`, structures)
		-- Solid core collision body + full-height anti-climb hull covering plinth & ribs so
		-- players cannot walk through the plinth or jump/double-jump onto the pillar.
		part({
			name = "CoreColumn",
			size = Vector3.new(7.4, p.h, 7.4),
			cframe = CFrame.new(p.x, p.h / 2, p.z),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			castShadow = true,
			parent = g,
		})
		addNoClimbHull(`PillarHull_{p.name}`, 9.2, 9.2, CFrame.new(p.x, 0, p.z), g)
		-- Heavy beveled concrete plinth base + yellow hazard bumper band.
		part({
			name = "PlinthBase",
			size = Vector3.new(9.2, 1.6, 9.2),
			cframe = CFrame.new(p.x, 0.8, p.z),
			color = C_CONCRETE_DARK,
			material = Enum.Material.Concrete,
			canCollide = false,
			castShadow = true,
			parent = g,
		})
		part({
			name = "HazardCollar",
			size = Vector3.new(9.4, 0.45, 9.4),
			cframe = CFrame.new(p.x, 1.72, p.z),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = g,
		})
		-- Glowing reactor core chamber + 4 corner armored ribs.
		local coreH = math.max(p.h - 4.6, 2.8)
		local coreY = 2.4 + coreH / 2
		local reactorCore = part({
			name = "EnergyChamber",
			size = Vector3.new(5.6, coreH, 5.6),
			cframe = CFrame.new(p.x, coreY, p.z) * CFrame.Angles(0, math.rad(45), 0),
			color = p.glow,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = g,
		})
		addLight(reactorCore, p.glow, 28, 0.9)

		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				part({
					name = `Rib_{sx}_{sz}`,
					size = Vector3.new(1.5, p.h - 1.2, 1.5),
					cframe = CFrame.new(p.x + sx * 3.5, (p.h + 1.0) / 2, p.z + sz * 3.5),
					color = C_STEEL,
					material = Enum.Material.Metal,
					canCollide = false,
					castShadow = true,
					parent = g,
				})
			end
		end

		-- Upper armored exhaust cap + beacon light.
		part({
			name = "CapPlate",
			size = Vector3.new(8.8, 1.5, 8.8),
			cframe = CFrame.new(p.x, p.h + 0.45, p.z),
			color = C_STEEL,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			castShadow = true,
			parent = g,
		})
		part({
			name = "CapBeacon",
			size = Vector3.new(4.2, 0.45, 4.2),
			cframe = CFrame.new(p.x, p.h + 1.38, p.z),
			color = p.glow,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = g,
		})
	end

	-- Perimeter industrial decorations (cargo crate clusters, coolant barrels, security consoles,
	-- and server racks tucked cleanly near the walls so the combat lanes stay wide and fast).
	local decor = folder("DecorProps", structures)

	local function addCrate(name: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, yawDeg: number, accent: any)
		local cf = CFrame.new(x, y + sy / 2, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
		part({
			name = name,
			size = Vector3.new(sx, sy, sz),
			cframe = cf,
			color = C_STEEL,
			material = Enum.Material.Metal,
			canCollide = false,
			castShadow = true,
			parent = decor,
		})
		if y <= 0.1 then
			-- Solid full-height hull on floor-level crates so players cannot pass through or climb them.
			addNoClimbHull(`{name}_Hull`, sx + 0.2, sz + 0.2, CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0), decor)
		end
		part({
			name = `{name}_Stripe`,
			size = Vector3.new(sx + 0.12, 0.32, sz + 0.12),
			cframe = cf * CFrame.new(0, sy * 0.25, 0),
			color = accent,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = decor,
		})
		part({
			name = `{name}_Lid`,
			size = Vector3.new(sx + 0.2, 0.24, sz + 0.2),
			cframe = cf * CFrame.new(0, sy / 2, 0),
			color = C_STEEL_DARK,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			parent = decor,
		})
	end

	local function addBarrel(name: string, x: number, z: number, color: any)
		part({
			name = name,
			size = Vector3.new(3.4, 2.1, 2.1),
			cframe = CFrame.new(x, 1.7, z) * CFrame.Angles(0, 0, math.rad(90)),
			color = color,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			canCollide = false,
			castShadow = true,
			parent = decor,
		})
		addNoClimbHull(`{name}_Hull`, 2.2, 2.2, CFrame.new(x, 0, z), decor)
		part({
			name = `{name}_Band`,
			size = Vector3.new(0.4, 2.18, 2.18),
			cframe = CFrame.new(x, 1.7, z) * CFrame.Angles(0, 0, math.rad(90)),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			shape = Enum.PartType.Cylinder,
			canCollide = false,
			parent = decor,
		})
	end

	local function addConsole(name: string, x: number, z: number, yawDeg: number, screenColor: any)
		local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
		part({
			name = `{name}_Desk`,
			size = Vector3.new(5.5, 3.2, 2.4),
			cframe = cf * CFrame.new(0, 1.6, 0),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			castShadow = true,
			parent = decor,
		})
		addNoClimbHull(`{name}_Hull`, 5.7, 2.6, cf, decor)
		local screen = part({
			name = `{name}_Screen`,
			size = Vector3.new(4.6, 1.6, 0.22),
			cframe = cf * CFrame.new(0, 3.6, -0.5) * CFrame.Angles(math.rad(-22), 0, 0),
			color = screenColor,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = decor,
		})
		addLight(screen, screenColor, 18, 0.7)
	end

	-- North-West & North-East supply crate stacks hugging the hero wall.
	addCrate("CrateNW_A", -54, 0, -65.4, 5.2, 4.2, 4.4, 8, C_HAZARD)
	addCrate("CrateNW_B", -48, 0, -65.8, 4.2, 3.4, 4.0, -5, C_STEEL_LIGHT)
	addCrate("CrateNW_Top", -53, 4.2, -65.4, 3.4, 2.8, 3.2, 18, C_HAZARD)

	addCrate("CrateNE_A", 52, 0, -65.4, 5.6, 4.4, 4.6, -10, C_HAZARD)
	addCrate("CrateNE_B", 45, 0, -65.8, 4.0, 3.2, 3.8, 12, C_STEEL_LIGHT)
	addCrate("CrateNE_Top", 52.5, 4.4, -65.4, 3.2, 2.6, 3.0, 6, C_HAZARD)

	-- West wall supply crates & server racks flanking the Observation Bay.
	addCrate("CrateW_A", -65.5, 0, -48, 4.4, 3.8, 5.2, 4, C_HAZARD)
	addCrate("CrateW_B", -65.5, 0, 48, 4.6, 4.2, 5.4, -8, C_HAZARD)
	addCrate("CrateW_BTop", -65.5, 4.2, 48.2, 3.0, 2.6, 3.4, 15, C_STEEL_LIGHT)

	-- Coolant barrel clusters near walls and corners.
	addBarrel("BarrelNW1", -41, -66.0, Color3.fromRGB(48, 95, 138))
	addBarrel("BarrelNW2", -38.5, -65.8, Color3.fromRGB(165, 72, 42))
	addBarrel("BarrelNE1", 39, -66.0, Color3.fromRGB(48, 95, 138))
	addBarrel("BarrelNE2", 36.4, -65.6, Color3.fromRGB(48, 95, 138))
	addBarrel("BarrelW1", -66.0, -38, Color3.fromRGB(165, 72, 42))
	addBarrel("BarrelW2", -66.0, -35.4, Color3.fromRGB(48, 95, 138))
	addBarrel("BarrelSW1", -65.8, 56.5, Color3.fromRGB(48, 95, 138))
	addBarrel("BarrelSW2", -63.4, 58.6, Color3.fromRGB(165, 72, 42))

	-- Illuminated tactical control consoles flanking the North Blast Door and West Observation Bay.
	addConsole("ConsoleDoorW", -18.5, -66.2, 0, C_CYAN)
	addConsole("ConsoleDoorE", 18.5, -66.2, 0, C_AMBER)
	addConsole("ConsoleBayN", -66.2, -19.5, 90, C_AMBER)
	addConsole("ConsoleBayS", -66.2, 19.5, 90, C_CYAN)

	-- Low industrial bumper bollards along South & East perimeter curbs for visual framing.
	for _, offset in ipairs({ -42, -14, 14, 42 }) do
		part({
			name = `BollardS_{offset}`,
			size = Vector3.new(2.2, 1.3, 1.3),
			cframe = CFrame.new(offset, 1.1, HALF - 1.6) * CFrame.Angles(0, 0, math.rad(90)),
			color = C_HAZARD,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			canCollide = false,
			parent = decor,
		})
		addNoClimbHull(`BollardS_{offset}_Hull`, 1.5, 1.5, CFrame.new(offset, 0, HALF - 1.6), decor)
		part({
			name = `BollardE_{offset}`,
			size = Vector3.new(2.2, 1.3, 1.3),
			cframe = CFrame.new(HALF - 1.6, 1.1, offset) * CFrame.Angles(0, 0, math.rad(90)),
			color = C_HAZARD,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			canCollide = false,
			parent = decor,
		})
		addNoClimbHull(`BollardE_{offset}_Hull`, 1.5, 1.5, CFrame.new(HALF - 1.6, 0, offset), decor)
	end

	-- 5 Solid Chest-High Tactical Cover Bunkers matching the 5 flank entries in `Config.ARENA_PILLARS`.
	-- These are the ONLY climbable structures in the arena: solid collider matches their actual
	-- top height (`spec.h + 0.35`) so players can take cover behind them OR jump on top of them.
	local bunkers = folder("CoverBunkers", structures)
	for _, spec in ipairs({
		{ name = "NW", x = -22, z = -48, yaw = 0, h = 3.6, glow = C_CYAN },
		{ name = "NE", x = 22, z = -48, yaw = 0, h = 3.6, glow = C_CYAN },
		{ name = "W", x = -46, z = 0, yaw = 90, h = 3.6, glow = C_AMBER },
		{ name = "E", x = 46, z = 0, yaw = 90, h = 3.2, glow = C_AMBER },
		{ name = "S", x = 0, z = 44, yaw = 0, h = 3.2, glow = C_CYAN },
	}) do
		local b = folder(`CoverBunker_{spec.name}`, bunkers)
		local cf = CFrame.new(spec.x, 0, spec.z) * CFrame.Angles(0, math.rad(spec.yaw), 0)
		local solidH = spec.h + 0.35
		-- Visual concrete core + matching-height solid collider (climbable flat top, solid sides).
		part({
			name = "WallCore",
			size = Vector3.new(6.2, spec.h, 2.8),
			cframe = cf * CFrame.new(0, spec.h / 2, 0),
			color = C_CONCRETE_DARK,
			material = Enum.Material.Concrete,
			canCollide = false,
			castShadow = true,
			parent = b,
		})
		part({
			name = `BunkerCollider_{spec.name}`,
			size = Vector3.new(6.8, solidH, 3.6),
			cframe = cf * CFrame.new(0, solidH / 2, 0),
			color = C_WALL,
			transparency = 1,
			canCollide = true,
			castShadow = false,
			parent = b,
		})
		-- Armored sloped front blast plate & top cap rail.
		part({
			name = "ArmorPlate",
			size = Vector3.new(5.4, spec.h - 0.6, 3.2),
			cframe = cf * CFrame.new(0, spec.h / 2 - 0.1, 0),
			color = C_STEEL,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			castShadow = true,
			parent = b,
		})
		part({
			name = "HazardTop",
			size = Vector3.new(6.4, 0.35, 3.0),
			cframe = cf * CFrame.new(0, spec.h + 0.12, 0),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = b,
		})
		-- Side steel buttress stanchions + recessed tactical status strip.
		for _, sx in ipairs({ -3.0, 3.0 }) do
			part({
				name = `Stanchion_{sx}`,
				size = Vector3.new(0.8, spec.h + 0.35, 3.5),
				cframe = cf * CFrame.new(sx, (spec.h + 0.35) / 2, 0),
				color = C_STEEL_DARK,
				material = Enum.Material.Metal,
				canCollide = false,
				castShadow = true,
				parent = b,
			})
		end
		part({
			name = "StatusStrip",
			size = Vector3.new(4.4, 0.32, 3.3),
			cframe = cf * CFrame.new(0, spec.h * 0.65, 0),
			color = spec.glow,
			material = Enum.Material.Neon,
			canCollide = false,
			parent = b,
		})
	end

	-- Overhead Power Conduit Bridges & Hero Wall Gantry Beams (non-colliding high backdrop).
	-- Wires the NW, NE, and SW reactor pillars directly into the facility's North & West walls.
	local rigging = folder("OverheadRigging", structures)
	for _, spec in ipairs({
		-- North wall bridges from NW & NE pillars into North wall (-Z = -70)
		{ "BridgeNW_N", Vector3.new(1.6, 1.4, 30), CFrame.new(-38, 13.6, -54), C_STEEL },
		{ "PipeNW_N", Vector3.new(0.45, 0.45, 30), CFrame.new(-38, 14.5, -54), C_AMBER },
		{ "BridgeNE_N", Vector3.new(1.6, 1.4, 30), CFrame.new(38, 13.6, -54), C_STEEL },
		{ "PipeNE_N", Vector3.new(0.45, 0.45, 30), CFrame.new(38, 14.5, -54), C_CYAN },
		-- West wall bridges from NW & SW pillars into West wall (-X = -70)
		{ "BridgeNW_W", Vector3.new(30, 1.4, 1.6), CFrame.new(-54, 13.6, -38), C_STEEL },
		{ "PipeNW_W", Vector3.new(30, 0.45, 0.45), CFrame.new(-54, 14.5, -38), C_AMBER },
		{ "BridgeSW_W", Vector3.new(30, 1.4, 1.6), CFrame.new(-54, 12.6, 38), C_STEEL },
		{ "PipeSW_W", Vector3.new(30, 0.45, 0.45), CFrame.new(-54, 13.5, 38), C_CYAN },
		-- Overhead industrial gantry crane tracks hugging North & West hero walls
		{ "GantryBeamN", Vector3.new(ROOM - 10, 1.8, 2.4), CFrame.new(0, 17.0, -HALF + 4.2), C_STEEL_DARK },
		{ "GantryTrimN", Vector3.new(ROOM - 12, 0.35, 2.6), CFrame.new(0, 16.0, -HALF + 4.2), C_HAZARD },
		{ "GantryBeamW", Vector3.new(2.4, 1.8, ROOM - 10), CFrame.new(-HALF + 4.2, 17.0, 0), C_STEEL_DARK },
		{ "GantryTrimW", Vector3.new(2.6, 0.35, ROOM - 12), CFrame.new(-HALF + 4.2, 16.0, 0), C_HAZARD },
	}) do
		local isGlow = spec[4] == C_CYAN or spec[4] == C_AMBER
		part({
			name = spec[1],
			size = spec[2],
			cframe = spec[3],
			color = spec[4],
			material = if isGlow then Enum.Material.Neon else Enum.Material.Metal,
			canCollide = false,
			castShadow = not isGlow,
			parent = rigging,
		})
	end

	-- Cryo / Coolant Pressurized Tank Clusters tucked into NW, NE, and SW corners.
	local function addCryoCluster(prefix: string, x: number, z: number, yawDeg: number, fluidColor: any)
		local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
		part({
			name = `{prefix}_Base`,
			size = Vector3.new(8.2, 1.0, 4.4),
			cframe = cf * CFrame.new(0, 0.5, 0),
			color = C_STEEL_DARK,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			castShadow = true,
			parent = decor,
		})
		addNoClimbHull(`{prefix}_Hull`, 8.4, 4.6, cf, decor)
		for _, ox in ipairs({ -2.1, 2.1 }) do
			part({
				name = `{prefix}_Tank_{ox}`,
				size = Vector3.new(8.8, 3.2, 3.2),
				cframe = cf * CFrame.new(ox, 5.2, 0) * CFrame.Angles(0, 0, math.rad(90)),
				color = C_STEEL,
				material = Enum.Material.Metal,
				shape = Enum.PartType.Cylinder,
				canCollide = false,
				castShadow = true,
				parent = decor,
			})
			part({
				name = `{prefix}_Gauge_{ox}`,
				size = Vector3.new(5.4, 0.45, 0.45),
				cframe = cf * CFrame.new(ox, 5.2, 1.58) * CFrame.Angles(0, 0, math.rad(90)),
				color = fluidColor,
				material = Enum.Material.Neon,
				canCollide = false,
				parent = decor,
			})
			part({
				name = `{prefix}_Cap_{ox}`,
				size = Vector3.new(0.8, 3.5, 3.5),
				cframe = cf * CFrame.new(ox, 9.7, 0) * CFrame.Angles(0, 0, math.rad(90)),
				color = C_HAZARD,
				material = Enum.Material.Metal,
				shape = Enum.PartType.Cylinder,
				canCollide = false,
				parent = decor,
			})
		end
		-- Top manifold connecting both tanks.
		part({
			name = `{prefix}_Manifold`,
			size = Vector3.new(5.2, 0.75, 0.75),
			cframe = cf * CFrame.new(0, 10.4, 0),
			color = C_STEEL_LIGHT,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Cylinder,
			canCollide = false,
			parent = decor,
		})
	end

	addCryoCluster("CryoNW", -62.5, -62.5, 45, C_CYAN)
	addCryoCluster("CryoNE", 62.5, -62.5, -45, C_AMBER)
	addCryoCluster("CryoSW", -62.5, 62.5, 135, C_CYAN)

	-- Industrial Server & Power Relay Cabinets lining the North and West walls.
	local function addServerRack(name: string, x: number, z: number, yawDeg: number, ledColor: any)
		local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
		part({
			name = `{name}_Chassis`,
			size = Vector3.new(4.8, 7.6, 2.4),
			cframe = cf * CFrame.new(0, 3.8, 0),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			castShadow = true,
			parent = decor,
		})
		addNoClimbHull(`{name}_Hull`, 5.0, 2.6, cf, decor)
		for row = 1, 3 do
			part({
				name = `{name}_Led_{row}`,
				size = Vector3.new(3.6, 0.34, 0.2),
				cframe = cf * CFrame.new(0, 1.8 + row * 1.65, 1.24),
				color = ledColor,
				material = Enum.Material.Neon,
				canCollide = false,
				parent = decor,
			})
		end
	end

	addServerRack("ServerN_W", -33, -67.2, 0, C_CYAN)
	addServerRack("ServerN_E", 33, -67.2, 0, C_AMBER)
	addServerRack("ServerW_N", -67.2, -31, 90, C_AMBER)
	addServerRack("ServerW_S", -67.2, 31, 90, C_CYAN)

	-- Twin Glowing Wall Holo-Status Boards flanking the North Blast Door.
	for _, spec in ipairs({
		{ "HoloDoorW", -16.5, C_CYAN },
		{ "HoloDoorE", 16.5, C_AMBER },
	}) do
		local hScreen = part({
			name = spec[1],
			size = Vector3.new(6.2, 3.4, 0.25),
			cframe = CFrame.new(spec[2], 9.4, -HALF + 1.35),
			color = spec[3],
			material = Enum.Material.Neon,
			transparency = 0.22,
			canCollide = false,
			parent = decor,
		})
		addLight(hScreen, spec[3], 20, 0.75)
		part({
			name = `{spec[1]}_Frame`,
			size = Vector3.new(6.8, 4.0, 0.45),
			cframe = CFrame.new(spec[2], 9.4, -HALF + 1.05),
			color = C_STEEL_DARK,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = decor,
		})
	end

	-- Low foreground industrial supply pallets & cable ramps hugging South & East curbs
	-- (kept <= 2.3 studs tall visually so the isometric camera at +X/+Z is never obstructed,
	-- with full-height invisible anti-climb hulls so players cannot walk through or stand on them).
	local function addLowPallet(name: string, x: number, z: number, yawDeg: number)
		local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
		part({
			name = `{name}_Deck`,
			size = Vector3.new(5.2, 0.55, 3.8),
			cframe = cf * CFrame.new(0, 0.275, 0),
			color = C_STEEL_DARK,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			parent = decor,
		})
		addNoClimbHull(`{name}_Hull`, 5.4, 4.0, cf, decor)
		part({
			name = `{name}_BoxA`,
			size = Vector3.new(2.2, 1.5, 2.6),
			cframe = cf * CFrame.new(-1.1, 1.3, 0.2),
			color = C_STEEL,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = decor,
		})
		part({
			name = `{name}_BoxB`,
			size = Vector3.new(2.0, 1.15, 2.2),
			cframe = cf * CFrame.new(1.2, 1.12, -0.2),
			color = C_HAZARD,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = decor,
		})
	end

	addLowPallet("PalletS_W", -28, 65.8, 6)
	addLowPallet("PalletS_E", 28, 65.8, -8)
	addLowPallet("PalletE_N", 65.8, -26, 84)
	addLowPallet("PalletE_S", 65.8, 26, 96)

	-- Low cable-bridge speed ramps across the outer perimeter walkways.
	for _, spec in ipairs({
		{ "CableRampN", Vector3.new(14.5, 0.22, 1.8), CFrame.new(0, 0.11, -35) },
		{ "CableRampW", Vector3.new(1.8, 0.22, 14.5), CFrame.new(-35, 0.11, 0) },
		{ "CableRampS", Vector3.new(10.5, 0.22, 1.8), CFrame.new(0, 0.11, 28) },
		{ "CableRampE", Vector3.new(1.8, 0.22, 10.5), CFrame.new(28, 0.11, 0) },
	}) do
		part({
			name = spec[1],
			size = spec[2],
			cframe = spec[3],
			color = C_HAZARD,
			material = Enum.Material.DiamondPlate,
			canCollide = false,
			parent = decor,
		})
	end
end

local function buildComplexArena(): any
	local model = Instance.new("Model")
	model.Name = "ComplexArena"

	-- PrimaryPart: base concrete floor slab with top face at y = 0.
	-- PivotOffset lifts the PrimaryPart pivot onto the top face so `model:GetPivot()` sits at
	-- (0, 0, 0) instead of (0, -2, 0) when Roblox resolves a Model's pivot through PrimaryPart.
	local floor = part({
		name = "Floor",
		size = Vector3.new(ROOM, 4, ROOM),
		cframe = CFrame.new(0, -2, 0),
		color = C_CONCRETE,
		material = Enum.Material.Concrete,
		parent = model,
	})
	floor.PivotOffset = CFrame.new(0, 2, 0)

	buildFloorDetails(model)
	buildHeroWalls(model)
	buildLandmarks(model)
	buildCutawayAndCorners(model)
	buildInteriorStructures(model)

	model.PrimaryPart = floor
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

if not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end
local arena = buildComplexArena()
local xml = roblox.serializeModel({ arena }, true)
local outPath = `{OUT_DIR}/ComplexArena.rbxmx`
fs.writeFile(outPath, xml)
print(`wrote {outPath} ({#xml} bytes)`)
