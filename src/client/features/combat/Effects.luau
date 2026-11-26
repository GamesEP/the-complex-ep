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

local PlayerAnimator = require(script.Parent.PlayerAnimator)
local SoundPlayer = require(script.Parent.SoundPlayer)

local Effects = {}

local chargeRing: Part? = nil
local chargeConn: RBXScriptConnection? = nil

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

function Effects.spin(root: BasePart)
	local diameter = Config.SPIN_RADIUS * 2
	-- A cylinder's axis is X, so it is turned on its side to lie flat as a disc.
	local cframe = CFrame.new(root.Position - Vector3.new(0, 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local part = ghost(Vector3.new(0.4, 4, 4), cframe, Color3.fromRGB(255, 200, 90), Enum.PartType.Cylinder)
	TweenService:Create(part, TweenInfo.new(0.2), { Size = Vector3.new(0.4, diameter, diameter), Transparency = 1 }):Play()
	Debris:AddItem(part, 0.25)
	SoundPlayer.play("playerSpin")
	PlayerAnimator.playLocal("spin")
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

-- Pulsing golden-orange energy ring at the player's feet while charging the heavy attack (HEAVY_CHARGE_SECONDS).
function Effects.startCharge(root: BasePart)
	Effects.stopCharge()
	local startedAt = os.clock()
	local duration = math.max(Config.HEAVY_CHARGE_SECONDS - Config.HEAVY_CHARGE_DELAY, 0.1)
	local ring = ghost(
		Vector3.new(0.3, 5, 5),
		CFrame.new(root.Position - Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(255, 175, 55),
		Enum.PartType.Cylinder
	)
	ring.Transparency = 0.45
	chargeRing = ring
	SoundPlayer.play("playerHeavyCharge")

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
		ring.Color = Color3.fromRGB(255, math.round(175 - progress * 80), math.round(55 - progress * 25))
		ring.Transparency = 0.55 - progress * 0.35
	end)
end

function Effects.stopCharge()
	if chargeConn then
		chargeConn:Disconnect()
		chargeConn = nil
	end
	if chargeRing then
		chargeRing:Destroy()
		chargeRing = nil
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

-- Massive forward shockwave ring + curved 160-degree horizontal crescent cleave (zero boxes).
function Effects.heavyAttack(root: BasePart, direction: Vector3)
	Effects.stopCharge()
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local origin = root.Position

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

	-- Curved horizontal crescent cleave matching the wide 160-deg front arc (no blocky rectangle).
	local arcModel = Instance.new("Model")
	arcModel.Name = "HeavyCleaveArc"
	arcModel.Parent = workspace

	local halfSpan = math.rad(math.min(Config.HEAVY_ATTACK_ARC * 0.46, 76))
	local segmentCount = 9
	local duration = 0.26
	local startRadius = 3.2
	local endRadius = Config.HEAVY_ATTACK_RANGE * 0.96
	local baseCf = CFrame.lookAt(Vector3.new(origin.X, origin.Y - 0.3, origin.Z), Vector3.new(origin.X + dir.X, origin.Y - 0.3, origin.Z + dir.Z))
	local stepRad = (halfSpan * 2) / math.max(segmentCount - 1, 1)

	type ArcSeg = {
		outer: Part,
		core: Part,
		theta: number,
		taper: number,
	}
	local segs: { ArcSeg } = {}
	for i = 1, segmentCount do
		local frac = (i - 1) / math.max(segmentCount - 1, 1)
		local theta = -halfSpan + frac * (halfSpan * 2)
		local taper = math.max(math.cos(theta * 1.15), 0.16)

		local outer = smoothPart(Vector3.new(1, 0.36, 1), CFrame.identity, Color3.fromRGB(255, 130, 45), 0.16)
		outer.Parent = arcModel
		local core = smoothPart(Vector3.new(1, 0.16, 1), CFrame.identity, Color3.fromRGB(255, 240, 165), 0.04)
		core.Parent = arcModel

		table.insert(segs, {
			outer = outer,
			core = core,
			theta = theta,
			taper = taper,
		})
	end

	local function placeArc(radius: number, fade: number)
		local chord = radius * stepRad * 1.42
		for _, seg in ipairs(segs) do
			local lx = math.sin(seg.theta) * radius
			local lz = -math.cos(seg.theta) * radius
			-- Tangent along the horizontal crescent curve; outer edge bows forward along -Z.
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

	SoundPlayer.play("playerHeavyAttack")
	PlayerAnimator.playLocal("heavyAttack")
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

local function tauntVfx(target: any, radius: number)
	local root = rootOfPlayer(target)
	if not root then
		return
	end
	floorRing(root.Position, radius, Color3.fromRGB(255, 70, 70), 0.45)
	task.delay(0.15, function()
		floorRing(root.Position, radius * 0.7, Color3.fromRGB(255, 120, 90), 0.4)
	end)
end

-- A translucent shield plate held in front of the tank for the whole duration.
local function bulwarkVfx(target: any, seconds: number)
	local root = rootOfPlayer(target)
	if not root then
		return
	end
	local plate = Instance.new("Part")
	plate.Name = "BulwarkVfx"
	plate.Anchored = false
	plate.Massless = true
	plate.CanCollide = false
	plate.CanQuery = false
	plate.CanTouch = false
	plate.CastShadow = false
	plate.Material = Enum.Material.ForceField
	plate.Color = Color3.fromRGB(120, 180, 255)
	plate.Size = Vector3.new(6, 6, 0.4)
	plate.CFrame = root.CFrame * CFrame.new(0, 0.5, -2.6)
	local weldToRoot = Instance.new("WeldConstraint")
	weldToRoot.Part0 = root
	weldToRoot.Part1 = plate
	weldToRoot.Parent = plate
	plate.Parent = root.Parent
	Debris:AddItem(plate, seconds)
end

local function executeVfx(position: Vector3, facing: Vector3)
	local at = position + facing * (Config.EXECUTE_RANGE * 0.55)
	local slash = ghost(
		Vector3.new(Config.EXECUTE_RANGE * 1.1, 0.25, 1.1),
		CFrame.lookAt(at, at + facing) * CFrame.Angles(0, math.rad(90), math.rad(25)),
		Color3.fromRGB(230, 40, 60)
	)
	TweenService:Create(slash, TweenInfo.new(0.22), { Transparency = 1 }):Play()
	Debris:AddItem(slash, 0.25)
end

-- A translucent dome over the field for as long as it protects.
local function protectFieldVfx(position: Vector3, radius: number, seconds: number)
	local dome = ghost(
		Vector3.new(radius * 2, radius * 2, radius * 2),
		CFrame.new(position.X, 0, position.Z),
		Color3.fromRGB(90, 200, 255),
		Enum.PartType.Ball
	)
	dome.Material = Enum.Material.ForceField
	dome.Transparency = 0.2
	floorRing(position, radius, Color3.fromRGB(90, 200, 255), 0.4)
	task.delay(math.max(seconds - 0.4, 0), function()
		if dome.Parent then
			TweenService:Create(dome, TweenInfo.new(0.4), { Transparency = 1 }):Play()
		end
	end)
	Debris:AddItem(dome, seconds)
end

Remotes.CombatVfx.OnClientEvent:Connect(function(kind: string, arg1: any, arg2: any, arg3: any)
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
	elseif kind == "taunt" then
		if type(arg2) == "number" then
			tauntVfx(arg1, arg2)
		end
	elseif kind == "bulwark" then
		if type(arg2) == "number" then
			bulwarkVfx(arg1, arg2)
		end
	elseif kind == "execute" then
		if typeof(arg1) == "Vector3" and typeof(arg2) == "Vector3" then
			executeVfx(arg1, arg2)
		end
	elseif kind == "healPulse" then
		if typeof(arg1) == "Vector3" and type(arg2) == "number" then
			floorRing(arg1, arg2, Color3.fromRGB(90, 230, 130), 0.5)
		end
	elseif kind == "protectField" then
		if typeof(arg1) == "Vector3" and type(arg2) == "number" and type(arg3) == "number" then
			protectFieldVfx(arg1, arg2, arg3)
		end
	elseif kind == "shockwave" then
		if typeof(arg1) == "Vector3" and type(arg2) == "number" then
			floorRing(arg1, arg2, Color3.fromRGB(235, 235, 255), 0.3)
		end
	end
end)

return Effects
