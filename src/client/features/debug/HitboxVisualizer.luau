--[[
	Client-side Hitbox, Aim-Assist & Arena Zone wireframe visualizer (plain Luau, pooled).

	Driven by `DebugStore.overlays().hitboxes`. Creates local-only adornments under
	`workspace.CurrentCamera` (never replicated) and disconnects `RenderStepped` completely
	when toggled OFF so idle cost is zero.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Charm = require(Packages.charm)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)

local DebugStore = require(script.Parent.stores.DebugStore)

local HitboxVisualizer = {}

local MAX_ENEMY_RINGS = 32
local ARC_SEGMENTS = 8
local HIDDEN_CF = CFrame.new(0, -500, 0)
local DOOR_VISIBLE_TRANSPARENCY = 0.72
local PILLAR_VISIBLE_TRANSPARENCY = 0.78

local enabled = false
local started = false
local overlayFolder: Folder? = nil
local stepConn: RBXScriptConnection? = nil

type ActiveAttackVisual = {
	owner: Player,
	shape: string,
	origin: Vector3,
	facing: Vector3,
	range: number,
	param: number, -- arc degrees for "arc", halfWidth for "corridor"
	fixedOrigin: boolean,
	endsAt: number,
	hitConnected: boolean,
}

local activeAttack: ActiveAttackVisual? = nil

local aimLeftPart: Part? = nil
local aimRightPart: Part? = nil
local aimArcPart: Part? = nil
local lockLinePart: Part? = nil
local atkLeftPart: Part? = nil
local atkRightPart: Part? = nil
local atkFillPart: Part? = nil
local atkCorridorPart: Part? = nil
local atkArcSegments: { Part } = {}
local doorZonePart: Part? = nil
local pillarParts: { Part } = {}
local enemyRings: { Part } = {}

local function makeWirePart(name: string, color: Color3, transparency: number, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	if shape then
		p.Shape = shape
	end
	return p
end

local function makeCylinderDisk(name: string, color: Color3, transparency: number): Part
	-- Roblox cylinders have their circular axis along X, so rotate Z by 90 deg when positioning flat.
	return makeWirePart(name, color, transparency, Enum.PartType.Cylinder)
end

local function teardown()
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	if overlayFolder then
		overlayFolder:Destroy()
		overlayFolder = nil
	end
	aimLeftPart = nil
	aimRightPart = nil
	aimArcPart = nil
	lockLinePart = nil
	activeAttack = nil
	atkLeftPart = nil
	atkRightPart = nil
	atkFillPart = nil
	atkCorridorPart = nil
	table.clear(atkArcSegments)
	doorZonePart = nil
	table.clear(pillarParts)
	table.clear(enemyRings)
end

local function hideAttackParts()
	if atkLeftPart then
		atkLeftPart.CFrame = HIDDEN_CF
	end
	if atkRightPart then
		atkRightPart.CFrame = HIDDEN_CF
	end
	if atkFillPart then
		atkFillPart.CFrame = HIDDEN_CF
	end
	if atkCorridorPart then
		atkCorridorPart.CFrame = HIDDEN_CF
	end
	for _, seg in ipairs(atkArcSegments) do
		seg.CFrame = HIDDEN_CF
	end
end

local function applyStaticLayerVisibility(layers: DebugStore.HitboxLayers)
	if doorZonePart then
		doorZonePart.Transparency = if layers.doorZone then DOOR_VISIBLE_TRANSPARENCY else 1
	end
	local pillarTrans = if layers.pillars then PILLAR_VISIBLE_TRANSPARENCY else 1
	for _, cyl in ipairs(pillarParts) do
		cyl.Transparency = pillarTrans
	end
end

local function positionBeam(part: Part, fromPos: Vector3, toPos: Vector3, thickness: number)
	local delta = toPos - fromPos
	local len = delta.Magnitude
	if len < 0.05 then
		part.CFrame = CFrame.new(0, -500, 0)
		return
	end
	part.Size = Vector3.new(thickness, thickness, len)
	part.CFrame = CFrame.lookAt(fromPos + delta * 0.5, toPos)
end

local function positionFlatRing(part: Part, center: Vector3, radius: number, height: number)
	part.Size = Vector3.new(height, radius * 2, radius * 2)
	part.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
end

local function buildStaticGuides(folder: Folder)
	local colors = Config.DEBUG_OVERLAY_COLORS
	local world = workspace:FindFirstChild("World")
	local arena = world and world:FindFirstChild(Config.ARENA_MODEL)
	local pivot = if arena and arena:IsA("Model") then arena:GetPivot() else CFrame.identity

	-- North Blast Door trigger zone (`Z <= BLAST_DOOR_TRIGGER_Z, |X| <= BLAST_DOOR_TRIGGER_HALF_X`).
	local halfZ = Config.ROOM_SIZE.Y / 2
	local depth = math.max(halfZ - math.abs(Config.BLAST_DOOR_TRIGGER_Z), 4)
	local zoneCenterZ = Config.BLAST_DOOR_TRIGGER_Z - depth * 0.5
	local doorZone = makeWirePart("DoorTriggerZone", colors.doorZone, DOOR_VISIBLE_TRANSPARENCY)
	doorZone.Size = Vector3.new(Config.BLAST_DOOR_TRIGGER_HALF_X * 2, 0.4, depth)
	doorZone.CFrame = pivot * CFrame.new(0, 0.35, zoneCenterZ)
	doorZone.Parent = folder
	doorZonePart = doorZone

	-- Arena pillar & bunker collision hulls (`Config.ARENA_PILLARS`).
	for i, pillar in ipairs(Config.ARENA_PILLARS) do
		local cyl = makeCylinderDisk(`PillarHull_{i}`, colors.pillarHull, PILLAR_VISIBLE_TRANSPARENCY)
		local worldPos = (pivot * CFrame.new(pillar.x, 0.5, pillar.z)).Position
		positionFlatRing(cyl, worldPos, pillar.radius, 0.6)
		cyl.Parent = folder
		table.insert(pillarParts, cyl)
	end

	applyStaticLayerVisibility(DebugStore.hitboxLayers())
end

local function stepDynamic()
	if not overlayFolder then
		return
	end
	local layers = DebugStore.hitboxLayers()
	local player = Players.LocalPlayer
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if aimLeftPart and aimRightPart and aimArcPart and lockLinePart then
		if layers.playerAim and root and root:IsA("BasePart") then
			local origin = Vector3.new(root.Position.X, 0.6, root.Position.Z)
			local lookFlat = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			local forward = if lookFlat.Magnitude > 1e-3 then lookFlat.Unit else Vector3.new(0, 0, -1)
			local range = Config.AIM_ASSIST_RANGE or 18
			local halfConeRad = math.rad((Config.AIM_ASSIST_CONE or 120) * 0.5)

			local leftDir = (CFrame.Angles(0, halfConeRad, 0):VectorToWorldSpace(forward)).Unit
			local rightDir = (CFrame.Angles(0, -halfConeRad, 0):VectorToWorldSpace(forward)).Unit
			positionBeam(aimLeftPart, origin, origin + leftDir * range, 0.22)
			positionBeam(aimRightPart, origin, origin + rightDir * range, 0.22)
			positionFlatRing(aimArcPart, Vector3.new(origin.X, 0.15, origin.Z), range, 0.08)

			-- Highlight nearest enemy inside aim-assist cone.
			local bestPos: Vector3? = nil
			local bestDist = range
			local world = workspace:FindFirstChild("World")
			local enemiesFolder = world and world:FindFirstChild("Enemies")
			if enemiesFolder then
				local cosLimit = math.cos(halfConeRad)
				for _, model in ipairs(enemiesFolder:GetChildren()) do
					if model:IsA("Model") then
						local body = model.PrimaryPart or model:FindFirstChild("Body")
						if body and body:IsA("BasePart") then
							local toEnemy = Vector3.new(body.Position.X - origin.X, 0, body.Position.Z - origin.Z)
							local dist = toEnemy.Magnitude
							if dist > 1e-3 and dist <= bestDist and (toEnemy.Unit):Dot(forward) >= cosLimit then
								bestDist = dist
								bestPos = Vector3.new(body.Position.X, 1.2, body.Position.Z)
							end
						end
					end
				end
			end
			if bestPos then
				positionBeam(lockLinePart, Vector3.new(origin.X, 1.2, origin.Z), bestPos, 0.26)
			else
				lockLinePart.CFrame = HIDDEN_CF
			end
		else
			aimLeftPart.CFrame = HIDDEN_CF
			aimRightPart.CFrame = HIDDEN_CF
			aimArcPart.CFrame = HIDDEN_CF
			lockLinePart.CFrame = HIDDEN_CF
		end
	end

	-- Live lingering melee attack hitbox (shown even when swinging into empty air; flashes green
	-- when the server confirms an enemy was hit).
	local colors = Config.DEBUG_OVERLAY_COLORS
	local atk = activeAttack
	if atk and os.clock() >= atk.endsAt then
		activeAttack = nil
		atk = nil
	end
	if layers.attackHitbox and atk and atkLeftPart and atkRightPart and atkFillPart and atkCorridorPart then
		local originPos = atk.origin
		if not atk.fixedOrigin and atk.owner.Character then
			local ownerRoot = atk.owner.Character:FindFirstChild("HumanoidRootPart")
			if ownerRoot and ownerRoot:IsA("BasePart") then
				originPos = ownerRoot.Position
			end
		end
		local origin = Vector3.new(originPos.X, 0.85, originPos.Z)
		local color = if atk.hitConnected then colors.attackHitConfirm else colors.attackHitbox
		local flat = Vector3.new(atk.facing.X, 0, atk.facing.Z)
		local forward = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)

		if atk.shape == "radius" then
			atkLeftPart.CFrame = HIDDEN_CF
			atkRightPart.CFrame = HIDDEN_CF
			atkCorridorPart.CFrame = HIDDEN_CF
			for _, seg in ipairs(atkArcSegments) do
				seg.CFrame = HIDDEN_CF
			end
			atkFillPart.Color = color
			atkFillPart.Transparency = 0.62
			positionFlatRing(atkFillPart, Vector3.new(origin.X, 0.45, origin.Z), atk.range, 0.25)
		elseif atk.shape == "corridor" then
			atkLeftPart.CFrame = HIDDEN_CF
			atkRightPart.CFrame = HIDDEN_CF
			atkFillPart.CFrame = HIDDEN_CF
			for _, seg in ipairs(atkArcSegments) do
				seg.CFrame = HIDDEN_CF
			end
			local width = math.max(atk.param * 2, 1)
			local center = origin + forward * (atk.range * 0.5)
			atkCorridorPart.Color = color
			atkCorridorPart.Transparency = 0.58
			atkCorridorPart.Size = Vector3.new(width, 0.4, atk.range)
			atkCorridorPart.CFrame = CFrame.lookAt(center, center + forward)
		else
			-- Arc sector: left/right radial edges + curved chord segments along `range` + center disc.
			atkCorridorPart.CFrame = HIDDEN_CF
			local halfRad = math.rad(math.clamp(atk.param, 10, 360) * 0.5)
			local leftDir = (CFrame.Angles(0, halfRad, 0):VectorToWorldSpace(forward)).Unit
			local rightDir = (CFrame.Angles(0, -halfRad, 0):VectorToWorldSpace(forward)).Unit
			atkLeftPart.Color = color
			atkRightPart.Color = color
			positionBeam(atkLeftPart, origin, origin + leftDir * atk.range, 0.28)
			positionBeam(atkRightPart, origin, origin + rightDir * atk.range, 0.28)

			local segCount = #atkArcSegments
			for i = 1, segCount do
				local a0 = halfRad - ((i - 1) / segCount) * (halfRad * 2)
				local a1 = halfRad - (i / segCount) * (halfRad * 2)
				local p0 = origin + (CFrame.Angles(0, a0, 0):VectorToWorldSpace(forward)).Unit * atk.range
				local p1 = origin + (CFrame.Angles(0, a1, 0):VectorToWorldSpace(forward)).Unit * atk.range
				local seg = atkArcSegments[i]
				seg.Color = color
				positionBeam(seg, p0, p1, 0.26)
			end
			atkFillPart.Color = color
			atkFillPart.Transparency = 0.82
			positionFlatRing(atkFillPart, Vector3.new(origin.X, 0.22, origin.Z), atk.range, 0.1)
		end
	else
		hideAttackParts()
	end

	-- Enemy reach / hazard rings (pooled up to MAX_ENEMY_RINGS).
	local world = workspace:FindFirstChild("World")
	local enemiesFolder = world and world:FindFirstChild("Enemies")
	local used = 0
	if layers.enemyReach and enemiesFolder then
		for _, model in ipairs(enemiesFolder:GetChildren()) do
			if used >= MAX_ENEMY_RINGS then
				break
			end
			if model:IsA("Model") then
				local body = model.PrimaryPart or model:FindFirstChild("Body")
				if body and body:IsA("BasePart") then
					local kind = tostring(model:GetAttribute("Kind") or model.Name)
					local spec = Config.ENEMY_KINDS[kind]
					local radius = 5
					local color = colors.enemyReach
					if kind == "exploder" and spec then
						radius = spec.blastRadius or 10
						color = colors.blastOval
					elseif kind == "bossOh" and spec then
						local phase = model:GetAttribute("Phase")
						radius = if phase == "bossLeapWindup" or phase == "bossLeap"
							then (spec.leapRadius or 18)
							else (spec.coneRange or 24)
						color = colors.bossHazard
					elseif spec and spec.reach then
						radius = spec.reach
					elseif spec and spec.keepAway then
						radius = 4.5
					end
					used += 1
					local ring = enemyRings[used]
					ring.Color = color
					positionFlatRing(ring, Vector3.new(body.Position.X, 0.25, body.Position.Z), radius, 0.14)
				end
			end
		end
	end
	for i = used + 1, #enemyRings do
		enemyRings[i].CFrame = HIDDEN_CF
	end
end

local function enable()
	teardown()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local colors = Config.DEBUG_OVERLAY_COLORS
	local folder = Instance.new("Folder")
	folder.Name = "DebugHitboxOverlay"
	folder.Parent = camera
	overlayFolder = folder

	buildStaticGuides(folder)

	aimLeftPart = makeWirePart("AimConeLeft", colors.aimCone, 0.35)
	aimLeftPart.Parent = folder
	aimRightPart = makeWirePart("AimConeRight", colors.aimCone, 0.35)
	aimRightPart.Parent = folder
	aimArcPart = makeCylinderDisk("AimRangeDisk", colors.aimCone, 0.90)
	aimArcPart.Parent = folder
	lockLinePart = makeWirePart("SoftLockLine", colors.lockLine, 0.2)
	lockLinePart.Parent = folder

	atkLeftPart = makeWirePart("AttackHitboxLeft", colors.attackHitbox, 0.22)
	atkLeftPart.CFrame = HIDDEN_CF
	atkLeftPart.Parent = folder
	atkRightPart = makeWirePart("AttackHitboxRight", colors.attackHitbox, 0.22)
	atkRightPart.CFrame = HIDDEN_CF
	atkRightPart.Parent = folder
	atkFillPart = makeCylinderDisk("AttackHitboxFill", colors.attackHitbox, 0.78)
	atkFillPart.CFrame = HIDDEN_CF
	atkFillPart.Parent = folder
	atkCorridorPart = makeWirePart("AttackHitboxCorridor", colors.attackHitbox, 0.58)
	atkCorridorPart.CFrame = HIDDEN_CF
	atkCorridorPart.Parent = folder
	for i = 1, ARC_SEGMENTS do
		local seg = makeWirePart(`AttackHitboxArc_{i}`, colors.attackHitbox, 0.22)
		seg.CFrame = HIDDEN_CF
		seg.Parent = folder
		table.insert(atkArcSegments, seg)
	end

	for i = 1, MAX_ENEMY_RINGS do
		local ring = makeCylinderDisk(`EnemyReach_{i}`, colors.enemyReach, 0.80)
		ring.CFrame = CFrame.new(0, -500, 0)
		ring.Parent = folder
		table.insert(enemyRings, ring)
	end

	stepConn = RunService.RenderStepped:Connect(stepDynamic)
end

function HitboxVisualizer.start()
	if started then
		return
	end
	started = true

	local function sync(overlays: DebugStore.OverlayFlags)
		local want = overlays.hitboxes == true
		if want == enabled then
			return
		end
		enabled = want
		if enabled then
			enable()
		else
			teardown()
		end
	end

	sync(DebugStore.overlays())
	Charm.subscribe(DebugStore.overlays, sync)
	Charm.subscribe(DebugStore.hitboxLayers, function(layers: DebugStore.HitboxLayers)
		if enabled then
			applyStaticLayerVisibility(layers)
		end
	end)

	-- Track server-authoritative lingering active hitboxes (arc / radius / corridor) so the debug
	-- overlay visualizes every swing live, including air swings and multi-frame hit confirms.
	Remotes.CombatVfx.OnClientEvent:Connect(
		function(kind: string, a1: any, a2: any, a3: any, a4: any, a5: any, a6: any, a7: any, a8: any)
			if not enabled then
				return
			end
			if kind == "hitboxActive" then
				if
					typeof(a1) == "Instance"
					and a1 == Players.LocalPlayer
					and type(a2) == "string"
					and typeof(a3) == "Vector3"
					and typeof(a4) == "Vector3"
					and type(a5) == "number"
					and type(a6) == "number"
					and type(a7) == "number"
				then
					activeAttack = {
						owner = a1 :: Player,
						shape = a2,
						origin = a3,
						facing = a4,
						range = a5,
						param = a6,
						fixedOrigin = a8 == true,
						endsAt = os.clock() + math.max(a7, 0.04),
						hitConnected = false,
					}
				end
			elseif kind == "hitboxEnd" then
				if activeAttack and typeof(a1) == "Instance" and a1 == activeAttack.owner then
					activeAttack = nil
				end
			elseif kind == "hitConfirm" then
				if activeAttack then
					activeAttack.hitConnected = true
				end
			end
		end
	)
end

return HitboxVisualizer
