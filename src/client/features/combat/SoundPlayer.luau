--[[
	Client-side combat sound playback: preloads every cue on join, plays 3D spatial sounds on
	short-lived Terrain Attachments, and listens to the server's `CombatSfx` broadcast.

	Playing 3D sounds on Terrain Attachments instead of on an enemy's Body is deliberate: an
	exploder destroys its Model on the same frame it detonates, which would cut off the blast
	tail immediately if the Sound lived inside the Model. See docs/combat.md.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared.core.Assets)
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local CombatAudio = require(Shared.features.combat.CombatAudio)

local SoundPlayer = {}

local function preloadAll()
	local seen: { [number]: boolean } = {}
	local probes: { Sound } = {}
	for _, spec in pairs(Config.SFX) do
		local id = CombatAudio.resolveId(spec, Assets.id(spec.file))
		if id > 0 and not seen[id] then
			seen[id] = true
			local probe = Instance.new("Sound")
			probe.SoundId = `rbxassetid://{id}`
			table.insert(probes, probe)
		end
	end
	if #probes == 0 then
		return
	end
	ContentProvider:PreloadAsync(probes)
	for _, probe in ipairs(probes) do
		probe:Destroy()
	end
end

function SoundPlayer.play(cue: string, position: Vector3?, step: number?)
	if type(cue) ~= "string" then
		return
	end
	local spec = Config.SFX[cue]
	if not spec then
		return
	end
	local assetId = CombatAudio.resolveId(spec, Assets.id(spec.file))
	if assetId == 0 then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = cue
	sound.SoundId = `rbxassetid://{assetId}`
	sound.Volume = spec.volume
	sound.PlaybackSpeed = CombatAudio.playbackSpeed(spec, step, math.random())

	local container: Instance
	local terrain = workspace.Terrain
	if typeof(position) == "Vector3" and terrain then
		local anchor = Instance.new("Attachment")
		anchor.Name = `Sfx_{cue}`
		anchor.WorldPosition = position
		anchor.Parent = terrain

		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = 12
		sound.RollOffMaxDistance = spec.maxDistance or 80
		sound.Parent = anchor
		container = anchor
	else
		sound.Parent = SoundService
		container = sound
	end

	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		container:Destroy()
	end

	sound.Ended:Once(cleanup)
	sound:Play()

	if spec.maxDuration and spec.maxDuration > 0 then
		local fade = Config.SFX_FADE_OUT_SECONDS
		local fadeAt = math.max(spec.maxDuration - fade, 0)
		task.delay(fadeAt, function()
			if cleaned then
				return
			end
			TweenService:Create(sound, TweenInfo.new(fade), { Volume = 0 }):Play()
			task.delay(fade + 0.02, cleanup)
		end)
	end

	-- Safety net: if an asset fails to load, `Ended` never fires and the anchor would stay on
	-- Terrain forever without a bounded lifetime.
	task.delay(Config.SFX_MAX_CLEANUP_SECONDS, cleanup)
end

-- Isometric camera sits ~70 studs away from the character (`Config.CAMERA_DISTANCE`). Measuring
-- 3D distance from the character root while keeping the camera's stereo orientation keeps nearby
-- enemies and hits loud and clear instead of fading out under the camera's height.
local function bindListener()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local function attach(character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 5)
		if root and root:IsA("BasePart") then
			SoundService:SetListener(Enum.ListenerType.ObjectPosition, root)
		end
	end
	player.CharacterAdded:Connect(attach)
	player.CharacterRemoving:Connect(function()
		SoundService:SetListener(Enum.ListenerType.Camera)
	end)
	if player.Character then
		task.spawn(attach, player.Character)
	end
end

function SoundPlayer.start()
	bindListener()
	task.spawn(preloadAll)
	Remotes.CombatSfx.OnClientEvent:Connect(function(cue: string, position: Vector3?, step: number?)
		SoundPlayer.play(cue, position, step)
	end)
end

return SoundPlayer
