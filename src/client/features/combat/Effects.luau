--[[
	The local player's own swing, dash and spin, drawn the instant they press — before the server
	has heard about it. Client-only parts: nobody else sees them, and nothing collides with them.

	Kept apart from CombatInput so the input code reads as decisions and this reads as visuals.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local CombatAudio = require(Shared.features.combat.CombatAudio)
local Classes = require(Shared.features.classes.Classes)

local PlayerAnimator = require(script.Parent.PlayerAnimator)
local SoundPlayer = require(script.Parent.SoundPlayer)

local Effects = {}

local chargeRing: Part? = nil
local chargeOrb: Part? = nil
local chargeConn: RBXScriptConnection? = nil
local chargeSoundStop: (() -> ())? = nil
local activeBolts: { [number]: { model: Model, conn: RBXScriptConnection } } = {}
local lockOuterRing: Part? = nil
local lockInnerRing: Part? = nil

local function ghost(size: Vector3, cframe: CFrame, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.25
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Parent = workspace
	return part
end

-- Plays only the local attack pose (used when a lunge starts so the windup plays during the
-- step-in and the attack audio fires at impact).
function Effects.attackWindup(step: number)
	PlayerAnimator.playLocal("attack", step)
end

-- No placeholder block hitbox visual: the equipped sword and PlayerAnimator combo pose carry
-- the swing visually.
function Effects.slash(_root: BasePart, _direction: Vector3, step: number, animStarted: boolean?)
	-- Local player's own kit plays non-spatially (nil position) so it is always crisp regardless
	-- of camera distance or respawn timing; teammates receive a 3D broadcast from CombatService.
	SoundPlayer.play(CombatAudio.attackCue(step, Config.COMBO_HITS), nil, step)
	if not animStarted then
		PlayerAnimator.playLocal("attack", step)
	end
end

-- Local Support staff ranged cast feedback (the traveling energy orb itself is drawn from the
-- server's `staffBolt` broadcast so caster and teammates see one exact bolt).
function Effects.staffAttack(root: BasePart, direction: Vector3, step: number)
	SoundPlayer.play(CombatAudio.attackCue(step, Config.COMBO_HITS), nil, step)
	PlayerAnimator.playLocal("attack", step)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local muzzle = ghost(
		Vector3.one * (if step >= Config.COMBO_HITS then 1.9 else 1.25),
		CFrame.new(root.Position + dir * 2.2 + Vector3.new(0, 0.2, 0)),
		if step >= Config.COMBO_HITS then Color3.fromRGB(115, 255, 225) else Color3.fromRGB(90, 240, 175),
		Enum.PartType.Ball
	)
	muzzle.Transparency = 0.2
	TweenService:Create(
		muzzle,
		TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * 0.2, Transparency = 1 }
	):Play()
	Debris:AddItem(muzzle, 0.2)
end

function Effects.spin(root: BasePart)
	local diameter = Config.SPIN_RADIUS * 2
	-- A cylinder's axis is X, so it is turned on its side to lie flat as a disc.
	local cframe = CFrame.new(root.Position - Vector3.new(0, 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local part = ghost(Vector3.new(0.4, 4, 4), cframe, Color3.fromRGB(255, 200, 90), Enum.PartType.Cylinder)
	TweenService:Create(part, TweenInfo.new(0.36), { Size = Vector3.new(0.4, diameter, diameter), Transparency = 1 }):Play()
	Debris:AddItem(part, 0.42)
	SoundPlayer.play("playerSpin")
	PlayerAnimator.playLocal("spin")
end

-- Client-only DMC-style ground lock-on indicator beneath the currently locked enemy body.
-- Parented directly to `workspace` (never `World.Enemies`) so target picking never latches onto it.
function Effects.updateLockIndicator(targetBody: BasePart?)
	if not targetBody or not targetBody:IsDescendantOf(workspace) then
		if lockOuterRing then
			lockOuterRing:Destroy()
			lockOuterRing = nil
		end
		if lockInnerRing then
			lockInnerRing:Destroy()
			lockInnerRing = nil
		end
		return
	end

	local outer = lockOuterRing
	if not outer or not outer.Parent then
		outer = ghost(Vector3.new(0.12, 4, 4), CFrame.identity, Color3.fromRGB(255, 90, 90), Enum.PartType.Cylinder)
		outer.Name = "TargetLockOuter"
		lockOuterRing = outer
	end
	local inner = lockInnerRing
	if not inner or not inner.Parent then
		inner = ghost(Vector3.new(0.16, 2.5, 2.5), CFrame.identity, Color3.fromRGB(255, 225, 110), Enum.PartType.Cylinder)
		inner.Name = "TargetLockInner"
		lockInnerRing = inner
	end

	local pos = targetBody.Position
	local baseRadius = math.max(targetBody.Size.X, targetBody.Size.Z) * 0.5
	local pulse = 0.28 * math.sin(os.clock() * 10)
	local outerDiam = baseRadius * 2 + 2.2 + pulse
	local innerDiam = baseRadius * 2 + 0.9 - pulse * 0.5
	local floorY = math.max(pos.Y - targetBody.Size.Y * 0.5 + 0.14, 0.14)
	local flatRot = CFrame.Angles(0, 0, math.rad(90))

	if outer then
		outer.Size = Vector3.new(0.12, outerDiam, outerDiam)
		outer.CFrame = CFrame.new(pos.X, floorY, pos.Z) * flatRot
		outer.Transparency = 0.42
	end
	if inner then
		inner.Size = Vector3.new(0.16, innerDiam, innerDiam)
		inner.CFrame = CFrame.new(pos.X, floorY + 0.04, pos.Z) * flatRot
		inner.Transparency = 0.25
	end
end

-- Spawns a translucent neon silhouette echo of a character's current pose (clean afterimage wake).
local function spawnCharacterEcho(character: Model, tint: Color3, startTransparency: number, fadeSeconds: number)
	local folder = Instance.new("Model")
	folder.Name = "AbilityEcho"
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" and desc.Transparency < 0.9 then
			local copy = Instance.new("Part")
			if desc:IsA("Part") then
				copy.Shape = desc.Shape
			end
			copy.Anchored = true
			copy.CanCollide = false
			copy.CanQuery = false
			copy.CanTouch = false
			copy.CastShadow = false
			copy.Material = Enum.Material.Neon
			copy.Color = tint
			copy.Transparency = startTransparency
			copy.Size = desc.Size
			copy.CFrame = desc.CFrame
			copy.Parent = folder
			TweenService:Create(
				copy,
				TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Transparency = 1 }
			):Play()
		end
	end
	folder.Parent = workspace
	Debris:AddItem(folder, fadeSeconds + 0.05)
end

-- Sleek evasive dash VFX: translucent icy-cyan silhouette echoes + tapered wind ribbon Trail
-- (zero rectangular blocks).
function Effects.dash(root: BasePart)
	local character = root.Parent
	local duration = Config.DASH_DURATION

	if character and character:IsA("Model") then
		spawnCharacterEcho(character, Color3.fromRGB(120, 215, 255), 0.5, 0.22)
		task.delay(duration * 0.48, function()
			if character.Parent then
				spawnCharacterEcho(character, Color3.fromRGB(75, 185, 255), 0.6, 0.2)
			end
		end)
	end

	if root.Parent then
		local topAtt = Instance.new("Attachment")
		topAtt.Position = Vector3.new(0, 1.2, 0)
		topAtt.Parent = root

		local botAtt = Instance.new("Attachment")
		botAtt.Position = Vector3.new(0, -1.2, 0)
		botAtt.Parent = root

		local trail = Instance.new("Trail")
		trail.Attachment0 = topAtt
		trail.Attachment1 = botAtt
		trail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(215, 245, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(115, 205, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(65, 145, 255)),
		})
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9),
			NumberSequenceKeypoint.new(1, 0.05),
		})
		trail.Lifetime = 0.2
		trail.LightEmission = 1
		trail.Parent = root

		task.delay(duration + 0.02, function()
			if trail.Parent then
				trail.Enabled = false
			end
		end)
		Debris:AddItem(trail, duration + 0.26)
		Debris:AddItem(topAtt, duration + 0.26)
		Debris:AddItem(botAtt, duration + 0.26)
	end

	SoundPlayer.play("playerDash")
	PlayerAnimator.playLocal("dash")
end

-- Crisp air-ring burst + upward breeze echo when the player triggers the Double Jump passive.
function Effects.doubleJump(root: BasePart)
	local origin = root.Position - Vector3.new(0, 2.2, 0)
	local ring = ghost(
		Vector3.new(0.18, 2.2, 2.2),
		CFrame.new(origin) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(130, 225, 255),
		Enum.PartType.Cylinder
	)
	ring.Transparency = 0.22
	TweenService:Create(
		ring,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.10, 7.6, 7.6), CFrame = CFrame.new(origin - Vector3.new(0, 0.8, 0)) * CFrame.Angles(0, 0, math.rad(90)), Transparency = 1 }
	):Play()
	Debris:AddItem(ring, 0.32)

	local inner = ghost(
		Vector3.new(0.14, 1.4, 1.4),
		CFrame.new(origin + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(230, 250, 255),
		Enum.PartType.Cylinder
	)
	inner.Transparency = 0.15
	TweenService:Create(
		inner,
		TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.08, 4.8, 4.8), Transparency = 1 }
	):Play()
	Debris:AddItem(inner, 0.26)

	SoundPlayer.play("doubleJump")
end

-- Role-tinted energy ring (and arcane orb for Support) while charging Heavy Attack.
function Effects.startCharge(root: BasePart, classId: string?)
	Effects.stopCharge()
	local startedAt = os.clock()
	local duration = math.max(Config.HEAVY_CHARGE_SECONDS - Config.HEAVY_CHARGE_DELAY, 0.1)
	local startColor, endColor = Color3.fromRGB(255, 175, 55), Color3.fromRGB(255, 95, 30)
	if classId == "tank" then
		startColor, endColor = Color3.fromRGB(110, 185, 255), Color3.fromRGB(255, 200, 75)
	elseif classId == "dps" then
		startColor, endColor = Color3.fromRGB(255, 75, 130), Color3.fromRGB(255, 35, 75)
	elseif classId == "support" then
		startColor, endColor = Color3.fromRGB(80, 240, 165), Color3.fromRGB(90, 230, 255)
	end

	local ring = ghost(
		Vector3.new(0.3, 5, 5),
		CFrame.new(root.Position - Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		startColor,
		Enum.PartType.Cylinder
	)
	ring.Transparency = 0.45
	chargeRing = ring

	local orb: Part? = nil
	if classId == "support" then
		orb = ghost(
			Vector3.one * 0.8,
			CFrame.new(root.Position + Vector3.new(0, 3.2, 0)),
			Color3.fromRGB(130, 255, 225),
			Enum.PartType.Ball
		)
		orb.Transparency = 0.25
		chargeOrb = orb
	end
	chargeSoundStop = SoundPlayer.play("playerHeavyCharge")

	chargeConn = RunService.RenderStepped:Connect(function()
		if not ring.Parent or not root.Parent then
			Effects.stopCharge()
			return
		end
		local elapsed = os.clock() - startedAt
		local progress = math.clamp(elapsed / duration, 0, 1)
		local pulse = 0.65 * math.sin(elapsed * (7 + progress * 10))
		local diameter = 4.5 + progress * 4.5 + pulse
		ring.Size = Vector3.new(0.25 + progress * 0.15, diameter, diameter)
		ring.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Color = startColor:Lerp(endColor, progress)
		ring.Transparency = 0.55 - progress * 0.35
		if orb and orb.Parent then
			local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			local dir = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
			local s = 0.8 + progress * 2.0 + math.sin(elapsed * 18) * 0.18
			orb.Size = Vector3.one * s
			orb.Position = root.Position + dir * 2.2 + Vector3.new(0, 1.5 + progress * 0.8, 0)
			orb.Color = startColor:Lerp(Color3.fromRGB(220, 255, 255), progress * 0.6)
			orb.Transparency = 0.35 - progress * 0.25
		end
	end)
end

function Effects.stopCharge()
	if chargeSoundStop then
		chargeSoundStop()
		chargeSoundStop = nil
	end
	if chargeConn then
		chargeConn:Disconnect()
		chargeConn = nil
	end
	if chargeRing then
		chargeRing:Destroy()
		chargeRing = nil
	end
	if chargeOrb then
		chargeOrb:Destroy()
		chargeOrb = nil
	end
end

-- Spawns a smooth tapered ellipsoid part (zero boxy edges) for razor slashes and spear tips.
local function smoothPart(size: Vector3, cframe: CFrame, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Block
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Size = size
	part.CFrame = cframe
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	part.Parent = workspace
	return part
end

-- Helper: curved razor crescent cleave built from smooth tapered ellipsoids (zero boxes).
local function spawnCrescentArc(
	origin: Vector3,
	dir: Vector3,
	rollRad: number,
	range: number,
	arcDeg: number,
	outerColor: Color3,
	coreColor: Color3,
	duration: number
)
	local arcModel = Instance.new("Model")
	arcModel.Name = "HeavyCleaveArc"
	arcModel.Parent = workspace

	local halfSpan = math.rad(math.min(arcDeg * 0.46, 76))
	local segmentCount = 9
	local startRadius = 3.0
	local endRadius = range * 0.96
	local baseCf = CFrame.lookAt(
		Vector3.new(origin.X, origin.Y - 0.25, origin.Z),
		Vector3.new(origin.X + dir.X, origin.Y - 0.25, origin.Z + dir.Z)
	) * CFrame.Angles(0, 0, rollRad)
	local stepRad = (halfSpan * 2) / math.max(segmentCount - 1, 1)

	type ArcSeg = { outer: Part, core: Part, theta: number, taper: number }
	local segs: { ArcSeg } = {}
	for i = 1, segmentCount do
		local frac = (i - 1) / math.max(segmentCount - 1, 1)
		local theta = -halfSpan + frac * (halfSpan * 2)
		local taper = math.max(math.cos(theta * 1.15), 0.16)

		local outer = smoothPart(Vector3.new(1, 0.36, 1), CFrame.identity, outerColor, 0.16)
		outer.Parent = arcModel
		local core = smoothPart(Vector3.new(1, 0.16, 1), CFrame.identity, coreColor, 0.04)
		core.Parent = arcModel

		table.insert(segs, { outer = outer, core = core, theta = theta, taper = taper })
	end

	local function placeArc(radius: number, fade: number)
		local chord = radius * stepRad * 1.42
		for _, seg in ipairs(segs) do
			local lx = math.sin(seg.theta) * radius
			local lz = -math.cos(seg.theta) * radius
			local segCf = baseCf * CFrame.new(lx, 0, lz) * CFrame.Angles(0, -seg.theta, 0)
			seg.outer.Size = Vector3.new(chord, 0.42 * seg.taper + 0.1, 2.35 * seg.taper)
			seg.outer.CFrame = segCf
			seg.outer.Transparency = 0.16 + 0.84 * fade

			seg.core.Size = Vector3.new(chord * 0.94, 0.18 * seg.taper + 0.06, 1.05 * seg.taper)
			seg.core.CFrame = segCf * CFrame.new(0, 0.02, -0.35 * seg.taper)
			seg.core.Transparency = 0.04 + 0.96 * fade
		end
	end

	placeArc(startRadius, 0)

	local startedAt = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = (os.clock() - startedAt) / duration
		if u >= 1 or not arcModel.Parent then
			conn:Disconnect()
			arcModel:Destroy()
			return
		end
		local ease = 1 - (1 - u) * (1 - u)
		local radius = startRadius + (endRadius - startRadius) * ease
		local fade = if u > 0.35 then (u - 0.35) / 0.65 else 0
		placeArc(radius, fade)
	end)
end

-- Role-specific Heavy Attack VFX:
-- - tank: greatsword seismic ground slam (double golden-steel shockwaves + central smash pillar + rock sparks)
-- - dps: dual-dagger X-shaped crimson-magenta twin crescent slashes + afterimage echo
-- - support: staff arcane release flash (the giant flying orb itself comes from `staffBolt` step 4)
-- - default: classic curved golden horizontal crescent cleave
function Effects.heavyAttack(root: BasePart, direction: Vector3, classId: string?, isLocal: boolean?)
	if isLocal ~= false then
		Effects.stopCharge()
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local origin = root.Position

	if classId == "tank" then
		local impact = origin + dir * Config.TANK_HEAVY_OFFSET
		local ground = Vector3.new(impact.X, 0.18, impact.Z)
		local diam = Config.TANK_HEAVY_RADIUS * 2

		local outer = ghost(
			Vector3.new(0.45, 4, 4),
			CFrame.new(ground) * CFrame.Angles(0, 0, math.rad(90)),
			Color3.fromRGB(255, 195, 70),
			Enum.PartType.Cylinder
		)
		outer.Transparency = 0.18
		TweenService:Create(
			outer,
			TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.18, diam, diam), Transparency = 1 }
		):Play()
		Debris:AddItem(outer, 0.4)

		local inner = ghost(
			Vector3.new(0.32, 3, 3),
			CFrame.new(ground + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Color3.fromRGB(115, 195, 255),
			Enum.PartType.Cylinder
		)
		inner.Transparency = 0.22
		TweenService:Create(
			inner,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.14, diam * 0.72, diam * 0.72), Transparency = 1 }
		):Play()
		Debris:AddItem(inner, 0.32)

		local pillar = ghost(
			Vector3.new(6.5, 3.2, 3.2),
			CFrame.new(ground + Vector3.new(0, 3.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Color3.fromRGB(255, 235, 165),
			Enum.PartType.Cylinder
		)
		pillar.Transparency = 0.25
		TweenService:Create(
			pillar,
			TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(9.5, 0.4, 0.4), Transparency = 1 }
		):Play()
		Debris:AddItem(pillar, 0.3)

		-- Radial seismic sparks flying outward from the greatsword slam point.
		for i = 1, 10 do
			local angle = (i / 10) * math.pi * 2 + math.random() * 0.25
			local outDir = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local spark = ghost(
				Vector3.one * 0.85,
				CFrame.new(ground + outDir * 2 + Vector3.new(0, 0.5, 0)),
				if i % 2 == 0 then Color3.fromRGB(255, 200, 80) else Color3.fromRGB(140, 205, 255),
				Enum.PartType.Ball
			)
			spark.Transparency = 0.15
			local dest = ground + outDir * (Config.TANK_HEAVY_RADIUS * 0.88) + Vector3.new(0, 1.8 + math.random() * 1.4, 0)
			TweenService:Create(
				spark,
				TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = dest, Size = Vector3.one * 0.15, Transparency = 1 }
			):Play()
			Debris:AddItem(spark, 0.36)
		end
	elseif classId == "dps" then
		-- Twin crimson-magenta diagonal X-shaped crescent slashes with rapid follow-up echo.
		local character = root.Parent
		if character and character:IsA("Model") then
			spawnCharacterEcho(character, Color3.fromRGB(255, 55, 105), 0.48, 0.26)
		end
		spawnCrescentArc(
			origin,
			dir,
			math.rad(36),
			Config.DPS_HEAVY_RANGE,
			Config.DPS_HEAVY_ARC,
			Color3.fromRGB(255, 45, 95),
			Color3.fromRGB(255, 230, 240),
			0.24
		)
		task.delay(Config.DPS_HEAVY_SECOND_DELAY, function()
			local currentOrigin = if root.Parent then root.Position else origin
			spawnCrescentArc(
				currentOrigin,
				dir,
				math.rad(-36),
				Config.DPS_HEAVY_RANGE * 1.06,
				Config.DPS_HEAVY_ARC,
				Color3.fromRGB(235, 55, 215),
				Color3.fromRGB(255, 240, 255),
				0.26
			)
		end)
	elseif classId == "support" then
		-- Muzzle arcane release flash (the traveling explosive orb is synced from the server).
		local flash = ghost(
			Vector3.one * 3.2,
			CFrame.new(origin + dir * 2.2 + Vector3.new(0, 0.4, 0)),
			Color3.fromRGB(110, 255, 225),
			Enum.PartType.Ball
		)
		flash.Transparency = 0.15
		TweenService:Create(
			flash,
			TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.one * 0.4, Transparency = 1 }
		):Play()
		Debris:AddItem(flash, 0.28)
	else
		local ringDiameter = Config.HEAVY_ATTACK_RANGE * 1.65
		local groundPos = origin - Vector3.new(0, 2.2, 0)
		local ring = ghost(
			Vector3.new(0.32, 5, 5),
			CFrame.new(groundPos) * CFrame.Angles(0, 0, math.rad(90)),
			Color3.fromRGB(255, 115, 45),
			Enum.PartType.Cylinder
		)
		ring.Transparency = 0.22
		TweenService:Create(
			ring,
			TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.22, ringDiameter, ringDiameter), Transparency = 1 }
		):Play()
		Debris:AddItem(ring, 0.32)

		spawnCrescentArc(
			origin,
			dir,
			0,
			Config.HEAVY_ATTACK_RANGE,
			Config.HEAVY_ATTACK_ARC,
			Color3.fromRGB(255, 130, 45),
			Color3.fromRGB(255, 240, 165),
			0.26
		)
	end

	if isLocal ~= false then
		SoundPlayer.play("playerHeavyAttack")
		PlayerAnimator.playLocal("heavyAttack")
	end
end

-- DMC-style Stinger piercing thrust: leaves crisp character afterimage echoes, a silky tapered
-- ribbon trail, a slim needle-tip glint ahead of the blade, and faint floor skid marks (no boxes).
function Effects.stinger(root: BasePart, direction: Vector3, isLocal: boolean?)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	local dir = flat.Unit
	local duration = Config.STINGER_DURATION
	local character = root.Parent

	-- Attach a clean, tapered ribbon Trail to the lunging character for the duration of the thrust.
	if root.Parent then
		local topAtt = Instance.new("Attachment")
		topAtt.Position = Vector3.new(0, 1.35, 0)
		topAtt.Parent = root

		local botAtt = Instance.new("Attachment")
		botAtt.Position = Vector3.new(0, -1.35, 0)
		botAtt.Parent = root

		local trail = Instance.new("Trail")
		trail.Attachment0 = topAtt
		trail.Attachment1 = botAtt
		trail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 235, 190)),
			ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 110, 60)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 40, 80)),
		})
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.6, 0.68),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0.05),
		})
		trail.Lifetime = 0.28
		trail.LightEmission = 1
		trail.FaceCamera = false
		trail.Parent = root

		task.delay(duration + 0.02, function()
			if trail.Parent then
				trail.Enabled = false
			end
		end)
		Debris:AddItem(trail, duration + 0.36)
		Debris:AddItem(topAtt, duration + 0.36)
		Debris:AddItem(botAtt, duration + 0.36)
	end

	-- Slim tapered energy needle gliding right at the blade tip during the thrust.
	local needle = smoothPart(
		Vector3.new(0.48, 0.48, 5.2),
		CFrame.lookAt(root.Position + dir * 3.0, root.Position + dir * 10),
		Color3.fromRGB(255, 225, 155),
		0.14
	)
	local halo = smoothPart(
		Vector3.new(1.15, 0.85, 6.2),
		CFrame.lookAt(root.Position + dir * 2.6, root.Position + dir * 10),
		Color3.fromRGB(255, 90, 55),
		0.48
	)

	-- Sample clean translucent silhouette echoes + faint floor skid marks along the thrust path.
	local startedAt = os.clock()
	local lastEchoAt = -1
	local echoIndex = 0
	local echoColors = {
		Color3.fromRGB(255, 145, 70),
		Color3.fromRGB(255, 90, 65),
		Color3.fromRGB(255, 60, 105),
	}

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startedAt
		if elapsed >= duration or not root.Parent then
			conn:Disconnect()
			TweenService:Create(
				needle,
				TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = Vector3.new(0.08, 0.08, 7.5), Transparency = 1 }
			):Play()
			TweenService:Create(
				halo,
				TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = Vector3.new(0.2, 0.2, 8.5), Transparency = 1 }
			):Play()
			Debris:AddItem(needle, 0.18)
			Debris:AddItem(halo, 0.2)
			return
		end

		local curPos = root.Position
		local curDir = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		local aimDir = if curDir.Magnitude > 1e-3 then curDir.Unit else dir
		needle.CFrame = CFrame.lookAt(curPos + aimDir * 3.2, curPos + aimDir * 12)
		halo.CFrame = CFrame.lookAt(curPos + aimDir * 2.8, curPos + aimDir * 12)

		if elapsed - lastEchoAt >= 0.048 then
			lastEchoAt = elapsed
			echoIndex += 1
			local tint = echoColors[((echoIndex - 1) % #echoColors) + 1]
			if character and character:IsA("Model") then
				spawnCharacterEcho(character, tint, 0.52, 0.28)
			end
			-- Faint ground footprint / skid streak left behind the lunge.
			local skid = smoothPart(
				Vector3.new(0.85, 0.06, 2.8),
				CFrame.lookAt(curPos - Vector3.new(0, 2.45, 0), curPos - Vector3.new(0, 2.45, 0) + aimDir),
				tint,
				0.55
			)
			TweenService:Create(
				skid,
				TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = Vector3.new(0.3, 0.04, 3.6), Transparency = 1 }
			):Play()
			Debris:AddItem(skid, 0.36)
		end
	end)

	if isLocal ~= false then
		SoundPlayer.play("playerDash")
		SoundPlayer.play("playerAttackHeavy")
		PlayerAnimator.playLocal("stinger")
	end
end

-- DMC-style Over Drive channeling aura: sleek converging energy rings around the swordsman.
function Effects.playOverDriveCharge(root: BasePart, duration: number)
	local startedAt = os.clock()
	local dur = math.max(duration, 0.1)
	local ring = ghost(
		Vector3.new(0.2, 6, 6),
		CFrame.new(root.Position - Vector3.new(0, 2.45, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(215, 65, 255),
		Enum.PartType.Cylinder
	)
	ring.Transparency = 0.48

	local innerRing = ghost(
		Vector3.new(0.16, 3.5, 3.5),
		CFrame.new(root.Position - Vector3.new(0, 2.4, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(255, 195, 255),
		Enum.PartType.Cylinder
	)
	innerRing.Transparency = 0.35

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startedAt
		if elapsed >= dur or not root.Parent or not ring.Parent then
			conn:Disconnect()
			ring:Destroy()
			innerRing:Destroy()
			return
		end
		local p = math.clamp(elapsed / dur, 0, 1)
		local diam = 7.5 - p * 3.2 + math.sin(elapsed * 28) * 0.65
		ring.Size = Vector3.new(0.18, diam, diam)
		ring.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.45, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Color = Color3.fromRGB(255, math.round(65 + p * 85), math.round(245 - p * 165))
		ring.Transparency = 0.52 - p * 0.28

		local innerDiam = 2.6 + p * 3.6 + math.cos(elapsed * 32) * 0.35
		innerRing.Size = Vector3.new(0.14, innerDiam, innerDiam)
		innerRing.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.4, 0)) * CFrame.Angles(0, 0, math.rad(90))
		innerRing.Transparency = 0.45 - p * 0.25
	end)
end

-- Curved razor-sharp DMC Over Drive crescent energy slash rocketing downrange (composed of
-- smooth tapered ellipsoid arc segments + silky Trail ribbon — zero rectangular blocks).
function Effects.overDriveWave(origin: Vector3, direction: Vector3, waveIndex: number)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	local dir = flat.Unit
	local range = Config.OVERDRIVE_WAVE_RANGE
	local isFinal = waveIndex >= Config.OVERDRIVE_WAVES
	local scale = if isFinal then 1.32 else (0.94 + waveIndex * 0.08)
	-- Wave 1: diagonal right slash, Wave 2: diagonal left slash, Wave 3: towering vertical cleave.
	local roll = if waveIndex == 1 then math.rad(34) elseif waveIndex == 2 then math.rad(-34) else math.rad(6)
	local primaryColor = if isFinal
		then Color3.fromRGB(255, 65, 95)
		elseif waveIndex == 2 then Color3.fromRGB(255, 75, 200)
		else Color3.fromRGB(185, 70, 255)
	local coreColor = if isFinal then Color3.fromRGB(255, 240, 150) else Color3.fromRGB(255, 225, 255)

	local arcRadius = 4.6 * scale
	local halfSpan = math.rad(58)
	local segmentCount = 7
	local travelTime = 0.46

	local waveModel = Instance.new("Model")
	waveModel.Name = "OverDriveCrescent"
	waveModel.Parent = workspace

	-- Invisible anchor carrier for the crescent's silky ribbon Trail from upper tip to lower tip.
	local carrier = Instance.new("Part")
	carrier.Anchored = true
	carrier.CanCollide = false
	carrier.CanQuery = false
	carrier.CanTouch = false
	carrier.CastShadow = false
	carrier.Transparency = 1
	carrier.Size = Vector3.one * 0.2
	carrier.Parent = waveModel

	local topTip = Instance.new("Attachment")
	topTip.Position = Vector3.new(0, math.sin(halfSpan) * arcRadius * 0.92, (1 - math.cos(halfSpan)) * arcRadius)
	topTip.Parent = carrier

	local botTip = Instance.new("Attachment")
	botTip.Position = Vector3.new(0, -math.sin(halfSpan) * arcRadius * 0.92, (1 - math.cos(halfSpan)) * arcRadius)
	botTip.Parent = carrier

	local trail = Instance.new("Trail")
	trail.Attachment0 = topTip
	trail.Attachment1 = botTip
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, coreColor),
		ColorSequenceKeypoint.new(0.35, primaryColor),
		ColorSequenceKeypoint.new(1, primaryColor),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.65, 0.78),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = 0.16
	trail.LightEmission = 1
	trail.Parent = carrier

	-- Build the smooth curved crescent moon slash: 7 overlapping tapered razor ellipsoids (outer
	-- glow + incandescent leading cutting edge), widest at the bow and needle-sharp at both tips.
	type Segment = {
		outer: Part,
		core: Part,
		localCf: CFrame,
	}
	local segments: { Segment } = {}
	local stepRad = (halfSpan * 2) / math.max(segmentCount - 1, 1)
	local segChord = arcRadius * stepRad * 1.48

	for i = 1, segmentCount do
		local frac = (i - 1) / math.max(segmentCount - 1, 1) -- 0..1
		local theta = -halfSpan + frac * (halfSpan * 2)
		-- Smooth bell taper: full depth in the center of the crescent, razor-thin at both tips.
		local taper = math.max(math.cos(theta * 1.35), 0.18)
		local localY = math.sin(theta) * arcRadius
		local localZ = (1 - math.cos(theta)) * arcRadius
		-- Tilt each segment tangent to the curve in the Y-Z plane (leading bow faces -Z).
		local localCf = CFrame.new(0, localY, localZ) * CFrame.Angles(-theta, 0, 0)

		local outer = smoothPart(
			Vector3.new(0.28 * scale, segChord, 2.3 * scale * taper),
			CFrame.identity,
			primaryColor,
			0.18
		)
		outer.Parent = waveModel

		local core = smoothPart(
			Vector3.new(0.14 * scale, segChord * 0.94, 1.05 * scale * taper),
			CFrame.identity,
			coreColor,
			0.04
		)
		core.Parent = waveModel

		table.insert(segments, {
			outer = outer,
			core = core,
			localCf = localCf,
		})
	end

	-- Position immediately on frame 0 so the Trail never stretches from world origin.
	local function placeAt(distance: number, fade: number)
		local pos = origin + dir * distance + Vector3.new(0, 0.35, 0)
		local baseCf = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(0, 0, roll)
		carrier.CFrame = baseCf
		for _, seg in ipairs(segments) do
			local worldCf = baseCf * seg.localCf
			seg.outer.CFrame = worldCf
			seg.core.CFrame = worldCf * CFrame.new(0, 0, -0.35 * scale)
			if fade > 0 then
				seg.outer.Transparency = 0.18 + 0.82 * fade
				seg.core.Transparency = 0.04 + 0.96 * fade
			end
		end
	end

	placeAt(3.0, 0)

	local startedAt = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = (os.clock() - startedAt) / travelTime
		if u >= 1 or not waveModel.Parent then
			conn:Disconnect()
			trail.Enabled = false
			for _, seg in ipairs(segments) do
				seg.outer.Transparency = 1
				seg.core.Transparency = 1
			end
			Debris:AddItem(waveModel, 0.2)
			return
		end
		-- Explosive initial slash velocity easing smoothly across the arena.
		local ease = 1 - (1 - u) * (1 - u)
		local dist = 3.0 + (range - 3.0) * ease
		local fade = if u > 0.62 then (u - 0.62) / 0.38 else 0
		placeAt(dist, fade)
	end)
end

--=============================================================================
-- Class abilities (plans/gdd/systems.md, "Clases")
--
-- Drawn from the server's CombatVfx broadcast, the caster included, so every player sees the same
-- thing and the caster never sees it twice. The caster's own pose is the one local part.
--=============================================================================

function Effects.classAbilityLocal(abilityId: string)
	if abilityId == "execute" then
		PlayerAnimator.playLocal("attack", Config.COMBO_HITS)
	elseif
		abilityId == "taunt"
		or abilityId == "bulwark"
		or abilityId == "healPulse"
		or abilityId == "protectField"
		or abilityId == "shockwave"
	then
		PlayerAnimator.playLocal(abilityId)
	end
end

local function rootOfPlayer(target: any): BasePart?
	if typeof(target) ~= "Instance" or not target:IsA("Player") then
		return nil
	end
	local character = target.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- A flat disc on the floor growing from nothing to `radius` and fading: the shape every area
-- ability here is read by.
local function floorRing(position: Vector3, radius: number, color: Color3, seconds: number)
	local cframe = CFrame.new(position.X, 0.15, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	local part = ghost(Vector3.new(0.2, 2, 2), cframe, color, Enum.PartType.Cylinder)
	part.Transparency = 0.35
	TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(part, seconds + 0.05)
end

-- Tank War Cry: triple expanding golden-amber & crimson sonic roar rings + rising shock halo.
local function tauntVfx(target: any, radius: number)
	local root = rootOfPlayer(target)
	if not root then
		return
	end
	local origin = root.Position
	floorRing(origin, radius, Color3.fromRGB(255, 175, 55), 0.45)
	task.delay(0.09, function()
		floorRing(origin, radius * 0.88, Color3.fromRGB(255, 85, 65), 0.42)
	end)
	task.delay(0.18, function()
		floorRing(origin, radius * 0.65, Color3.fromRGB(255, 235, 130), 0.38)
	end)
	local pulse = ghost(
		Vector3.one * 3.5,
		CFrame.new(origin),
		Color3.fromRGB(255, 200, 80),
		Enum.PartType.Ball
	)
	pulse.Material = Enum.Material.ForceField
	pulse.Transparency = 0.25
	TweenService:Create(
		pulse,
		TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * (radius * 1.4), Transparency = 1 }
	):Play()
	Debris:AddItem(pulse, 0.42)
end

-- Tank Muralla (-75% all incoming damage): sleek pulsing armored ForceField shell hugging the Tank.
local function bulwarkVfx(target: any, seconds: number)
	local root = rootOfPlayer(target)
	if not root then
		return
	end
	floorRing(root.Position, 7.5, Color3.fromRGB(115, 190, 255), 0.36)
	local shell = Instance.new("Part")
	shell.Name = "BulwarkAura"
	shell.Shape = Enum.PartType.Ball
	shell.Anchored = false
	shell.Massless = true
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CanTouch = false
	shell.CastShadow = false
	shell.Material = Enum.Material.ForceField
	shell.Color = Color3.fromRGB(125, 200, 255)
	shell.Transparency = 0.18
	shell.Size = Vector3.one * 7.2
	shell.CFrame = root.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = shell
	weld.Parent = shell
	shell.Parent = root.Parent
	task.delay(math.max(seconds - 0.35, 0), function()
		if shell.Parent then
			TweenService:Create(shell, TweenInfo.new(0.35), { Transparency = 1 }):Play()
		end
	end)
	Debris:AddItem(shell, seconds)
end

-- Damage Boomerang Daggers: twin spinning glowing blades flying out and curving back to the caster.
local function boomerangVfx(caster: any, startPos: Vector3, apexPos: Vector3)
	local model = Instance.new("Model")
	model.Name = "BoomerangDaggers"
	model.Parent = workspace

	local hub = Instance.new("Part")
	hub.Anchored = true
	hub.CanCollide = false
	hub.CanQuery = false
	hub.CanTouch = false
	hub.CastShadow = false
	hub.Transparency = 1
	hub.Size = Vector3.one * 0.2
	hub.CFrame = CFrame.new(startPos)
	hub.Parent = model

	local bladeA = smoothPart(Vector3.new(0.38, 0.2, 4.4), CFrame.new(startPos), Color3.fromRGB(255, 65, 110), 0.08)
	bladeA.Parent = model
	local bladeB = smoothPart(Vector3.new(4.4, 0.2, 0.38), CFrame.new(startPos), Color3.fromRGB(255, 195, 225), 0.08)
	bladeB.Parent = model
	local ring = ghost(
		Vector3.new(0.14, 5.2, 5.2),
		CFrame.new(startPos) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(255, 70, 125),
		Enum.PartType.Cylinder
	)
	ring.Transparency = 0.45
	ring.Parent = model

	local att0 = Instance.new("Attachment")
	att0.Position = Vector3.new(-1.8, 0, 0)
	att0.Parent = hub
	local att1 = Instance.new("Attachment")
	att1.Position = Vector3.new(1.8, 0, 0)
	att1.Parent = hub
	local trail = Instance.new("Trail")
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 235)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 55, 110)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(165, 30, 145)),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = 0.22
	trail.LightEmission = 1
	trail.Parent = hub

	local startedAt = os.clock()
	local outSec = Config.BOOMERANG_OUT_SECONDS
	local retSec = Config.BOOMERANG_RETURN_SECONDS
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startedAt
		local progress = if elapsed <= outSec
			then elapsed / math.max(outSec, 0.05)
			else 1 + (elapsed - outSec) / math.max(retSec, 0.05)
		if progress >= 2 or not model.Parent then
			conn:Disconnect()
			trail.Enabled = false
			bladeA.Transparency = 1
			bladeB.Transparency = 1
			ring.Transparency = 1
			Debris:AddItem(model, 0.24)
			return
		end
		local casterRoot = rootOfPlayer(caster)
		local livePos = if casterRoot
			then Vector3.new(casterRoot.Position.X, 2.4, casterRoot.Position.Z)
			else startPos
		local pos = Classes.boomerangPosition(startPos, apexPos, livePos, progress)
		local spinAngle = elapsed * 26
		hub.CFrame = CFrame.new(pos) * CFrame.Angles(0, spinAngle, 0)
		bladeA.CFrame = CFrame.new(pos) * CFrame.Angles(0, spinAngle, 0)
		bladeB.CFrame = CFrame.new(pos) * CFrame.Angles(0, spinAngle, 0)
		ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, spinAngle, math.rad(90))
	end)
end

-- Support persistent 10 s Healing Zone: glowing emerald ground circle + rising heal orbs.
local function healZoneVfx(position: Vector3, radius: number, seconds: number)
	floorRing(position, radius, Color3.fromRGB(85, 245, 145), 0.45)

	local disc = ghost(
		Vector3.new(0.14, radius * 2, radius * 2),
		CFrame.new(position.X, 0.1, position.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(70, 235, 130),
		Enum.PartType.Cylinder
	)
	disc.Transparency = 0.72

	local rim = ghost(
		Vector3.new(0.24, radius * 2 + 0.5, radius * 2 + 0.5),
		CFrame.new(position.X, 0.14, position.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(145, 255, 185),
		Enum.PartType.Cylinder
	)
	rim.Material = Enum.Material.ForceField
	rim.Transparency = 0.2

	local startedAt = os.clock()
	local lastParticleAt = -1
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startedAt
		if elapsed >= seconds or not disc.Parent then
			conn:Disconnect()
			if disc.Parent then
				TweenService:Create(disc, TweenInfo.new(0.35), { Transparency = 1 }):Play()
			end
			if rim.Parent then
				TweenService:Create(rim, TweenInfo.new(0.35), { Transparency = 1 }):Play()
			end
			Debris:AddItem(disc, 0.4)
			Debris:AddItem(rim, 0.4)
			return
		end
		local pulse = 0.5 + 0.5 * math.sin(elapsed * 5.5)
		disc.Transparency = 0.68 + 0.12 * pulse
		local diam = radius * 2 + math.sin(elapsed * 4.5) * 0.35
		rim.Size = Vector3.new(0.24, diam, diam)

		if elapsed - lastParticleAt >= 0.22 then
			lastParticleAt = elapsed
			local angle = math.random() * math.pi * 2
			local dist = math.sqrt(math.random()) * (radius * 0.85)
			local startP = Vector3.new(position.X + math.cos(angle) * dist, 0.5, position.Z + math.sin(angle) * dist)
			local mote = ghost(
				Vector3.one * (0.45 + math.random() * 0.3),
				CFrame.new(startP),
				Color3.fromRGB(130, 255, 175),
				Enum.PartType.Ball
			)
			mote.Transparency = 0.2
			TweenService:Create(
				mote,
				TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = startP + Vector3.new(0, 4.2 + math.random() * 1.6, 0), Size = Vector3.one * 0.1, Transparency = 1 }
			):Play()
			Debris:AddItem(mote, 0.9)
		end
	end)
end

-- Support Squad Shield: expanding cyan aura + protective ForceField bubble on EVERY living player.
local function protectBuffVfx(seconds: number)
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local root = rootOfPlayer(targetPlayer)
		if root then
			floorRing(root.Position, 8, Color3.fromRGB(90, 215, 255), 0.42)
			local aura = Instance.new("Part")
			aura.Name = "SquadProtectAura"
			aura.Shape = Enum.PartType.Ball
			aura.Anchored = false
			aura.Massless = true
			aura.CanCollide = false
			aura.CanQuery = false
			aura.CanTouch = false
			aura.CastShadow = false
			aura.Material = Enum.Material.ForceField
			aura.Color = Color3.fromRGB(90, 215, 255)
			aura.Transparency = 0.38
			aura.Size = Vector3.one * 6.8
			aura.CFrame = root.CFrame
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = aura
			weld.Parent = aura
			aura.Parent = root.Parent
			task.delay(math.max(seconds - 0.35, 0), function()
				if aura.Parent then
					TweenService:Create(aura, TweenInfo.new(0.35), { Transparency = 1 }):Play()
				end
			end)
			Debris:AddItem(aura, seconds)
		end
	end
end

-- Support Shockwave (stun + push): twin violet-white shock rings + expanding translucent dome.
local function shockwaveVfx(position: Vector3, radius: number)
	floorRing(position, radius, Color3.fromRGB(205, 170, 255), 0.34)
	task.delay(0.08, function()
		floorRing(position, radius * 0.85, Color3.fromRGB(240, 240, 255), 0.32)
	end)
	local dome = ghost(
		Vector3.one * 4,
		CFrame.new(position.X, 1.5, position.Z),
		Color3.fromRGB(190, 160, 255),
		Enum.PartType.Ball
	)
	dome.Material = Enum.Material.ForceField
	dome.Transparency = 0.2
	TweenService:Create(
		dome,
		TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * (radius * 2), Transparency = 1 }
	):Play()
	Debris:AddItem(dome, 0.4)
end

-- Support ranged staff energy bolt (steps 1..3) and Heavy Arcane Orb (step 4).
local function spawnStaffBoltVfx(boltId: number, origin: Vector3, direction: Vector3, step: number)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local isHeavy = step >= 4
	local isFinisher = step == Config.COMBO_HITS
	local speed = if isHeavy then Config.SUPPORT_HEAVY_SPEED else Config.STAFF_BOLT_SPEED
	local range = if isHeavy then Config.SUPPORT_HEAVY_RANGE else Config.STAFF_BOLT_RANGE
	local maxLife = math.max(range / math.max(speed, 1), 0.15) + 0.08
	local outerSize = if isHeavy then 3.2 elseif isFinisher then 1.85 else 1.25
	local outerColor = if isHeavy
		then Color3.fromRGB(80, 235, 255)
		elseif isFinisher then Color3.fromRGB(95, 255, 220)
		else Color3.fromRGB(85, 240, 165)

	local model = Instance.new("Model")
	model.Name = if isHeavy then "SupportArcaneOrb" else "SupportStaffBolt"
	model.Parent = workspace

	local orb = ghost(Vector3.one * outerSize, CFrame.new(origin), outerColor, Enum.PartType.Ball)
	orb.Transparency = 0.18
	orb.Parent = model

	local core = ghost(Vector3.one * (outerSize * 0.55), CFrame.new(origin), Color3.fromRGB(235, 255, 255), Enum.PartType.Ball)
	core.Transparency = 0.02
	core.Parent = model

	local att0 = Instance.new("Attachment")
	att0.Position = Vector3.new(0, outerSize * 0.35, 0)
	att0.Parent = orb
	local att1 = Instance.new("Attachment")
	att1.Position = Vector3.new(0, -outerSize * 0.35, 0)
	att1.Parent = orb
	local trail = Instance.new("Trail")
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(235, 255, 255)),
		ColorSequenceKeypoint.new(0.4, outerColor),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(50, 185, 255)),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = if isHeavy then 0.28 else 0.16
	trail.LightEmission = 1
	trail.Parent = orb

	local startedAt = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startedAt
		if elapsed >= maxLife or not model.Parent then
			conn:Disconnect()
			activeBolts[boltId] = nil
			if model.Parent then
				model:Destroy()
			end
			return
		end
		local pos = origin + dir * (speed * elapsed)
		orb.Position = pos
		core.Position = pos
		if isHeavy then
			local pulse = outerSize + math.sin(elapsed * 22) * 0.28
			orb.Size = Vector3.one * pulse
		end
	end)
	activeBolts[boltId] = { model = model, conn = conn }
end

local function boltImpactVfx(boltId: number, position: Vector3, boltKind: string, splashRadius: number)
	local active = activeBolts[boltId]
	if active then
		active.conn:Disconnect()
		activeBolts[boltId] = nil
		if active.model.Parent then
			active.model:Destroy()
		end
	end
	if boltKind == "cancel" then
		return
	end
	if boltKind == "supportHeavy" then
		local r = if splashRadius > 0 then splashRadius else Config.SUPPORT_HEAVY_BLAST_RADIUS
		floorRing(position, r, Color3.fromRGB(85, 235, 255), 0.38)
		floorRing(position, r * 0.72, Color3.fromRGB(120, 255, 195), 0.3)
		local burst = ghost(Vector3.one * 3.5, CFrame.new(position), Color3.fromRGB(100, 245, 255), Enum.PartType.Ball)
		burst.Material = Enum.Material.ForceField
		burst.Transparency = 0.15
		TweenService:Create(
			burst,
			TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.one * (r * 2), Transparency = 1 }
		):Play()
		Debris:AddItem(burst, 0.4)
	elseif boltKind == "staffFinisher" then
		local r = if splashRadius > 0 then splashRadius else Config.STAFF_BOLT_FINISHER_SPLASH
		floorRing(position, r, Color3.fromRGB(95, 255, 215), 0.26)
		local pop = ghost(Vector3.one * 2.2, CFrame.new(position), Color3.fromRGB(130, 255, 225), Enum.PartType.Ball)
		TweenService:Create(
			pop,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.one * (r * 1.4), Transparency = 1 }
		):Play()
		Debris:AddItem(pop, 0.25)
	else
		local pop = ghost(Vector3.one * 1.4, CFrame.new(position), Color3.fromRGB(115, 255, 185), Enum.PartType.Ball)
		TweenService:Create(
			pop,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.one * 3.4, Transparency = 1 }
		):Play()
		Debris:AddItem(pop, 0.2)
	end
end

Remotes.CombatVfx.OnClientEvent:Connect(function(kind: string, arg1: any, arg2: any, arg3: any, arg4: any)
	if kind == "stinger" then
		-- Local player already predicted their own Stinger trail & echoes immediately on input.
		if typeof(arg1) == "Instance" and arg1 == Players.LocalPlayer then
			return
		end
		if typeof(arg1) == "Instance" and arg1:IsA("Player") and typeof(arg3) == "Vector3" then
			local char = arg1.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				Effects.stinger(root, arg3, false)
			end
		end
	elseif kind == "heavyAttack" then
		if typeof(arg1) == "Instance" and arg1 == Players.LocalPlayer then
			return
		end
		if typeof(arg1) == "Instance" and arg1:IsA("Player") and typeof(arg3) == "Vector3" then
			local root = rootOfPlayer(arg1)
			if root then
				Effects.heavyAttack(root, arg3, if type(arg4) == "string" then arg4 else nil, false)
			end
		end
	elseif kind == "overdriveCharge" then
		if typeof(arg1) == "Instance" and arg1:IsA("Player") and type(arg2) == "number" then
			local char = arg1.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				Effects.playOverDriveCharge(root, arg2)
			end
		end
	elseif kind == "overdriveWave" then
		if typeof(arg1) == "Vector3" and typeof(arg2) == "Vector3" and type(arg3) == "number" then
			Effects.overDriveWave(arg1, arg2, arg3)
		end
	elseif kind == "staffBolt" then
		if type(arg1) == "number" and typeof(arg2) == "Vector3" and typeof(arg3) == "Vector3" and type(arg4) == "number" then
			spawnStaffBoltVfx(arg1, arg2, arg3, arg4)
		end
	elseif kind == "boltImpact" then
		if type(arg1) == "number" and typeof(arg2) == "Vector3" and type(arg3) == "string" and type(arg4) == "number" then
			boltImpactVfx(arg1, arg2, arg3, arg4)
		end
	elseif kind == "taunt" then
		if type(arg2) == "number" then
			tauntVfx(arg1, arg2)
		end
	elseif kind == "bulwark" then
		if type(arg2) == "number" then
			bulwarkVfx(arg1, arg2)
		end
	elseif kind == "boomerang" then
		if typeof(arg2) == "Vector3" and typeof(arg3) == "Vector3" then
			boomerangVfx(arg1, arg2, arg3)
		end
	elseif kind == "healZone" then
		if typeof(arg1) == "Vector3" and type(arg2) == "number" and type(arg3) == "number" then
			healZoneVfx(arg1, arg2, arg3)
		end
	elseif kind == "protectBuff" then
		if type(arg1) == "number" then
			protectBuffVfx(arg1)
		end
	elseif kind == "shockwave" then
		if typeof(arg1) == "Vector3" and type(arg2) == "number" then
			shockwaveVfx(arg1, arg2)
		end
	end
end)

return Effects
