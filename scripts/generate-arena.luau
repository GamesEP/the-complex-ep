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

	-- Invisible full-height containment along the cutaway edges so players cannot jump/dash out.
	part({
		name = "SouthBound",
		size = Vector3.new(ROOM + WALL_T * 2, BACK_WALL_H, WALL_T),
		cframe = CFrame.new(0, BACK_WALL_H / 2, HALF + WALL_T / 2),
		color = C_WALL,
		transparency = 1,
		canCollide = true,
		castShadow = false,
		parent = bounds,
	})
	part({
		name = "EastBound",
		size = Vector3.new(WALL_T, BACK_WALL_H, ROOM + WALL_T * 2),
		cframe = CFrame.new(HALF + WALL_T / 2, BACK_WALL_H / 2, 0),
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
