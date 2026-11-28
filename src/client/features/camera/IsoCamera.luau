--[[
	The isometric camera (plans/gdd/technical.md): fixed yaw and pitch, following the player.

	A plain module bound to the render step, not a component — it runs every frame and React has
	nothing to offer it (CLAUDE.md). Movement stays Roblox's own: the default controls move the
	character relative to the camera, so WASD, the thumbstick and the gamepad stick all mean
	"up the screen" without any code here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

local IsoCamera = {}

local shakeAmplitude = 0
local shakeStartedAt = 0
local shakeDuration = 0

-- Brief decaying camera impact kick (used by hitstop / parry feedback). Never stacks infinitely;
-- a stronger shake overrides a weaker one while an ongoing stronger kick finishes smoothly.
function IsoCamera.shake(amplitude: number, duration: number)
	if amplitude <= 0 or duration <= 0 then
		return
	end
	local clock = os.clock()
	local remaining = if shakeDuration > 0 then math.max(1 - (clock - shakeStartedAt) / shakeDuration, 0) else 0
	if amplitude >= shakeAmplitude * remaining then
		shakeAmplitude = amplitude
		shakeStartedAt = clock
		shakeDuration = duration
	end
end

local function update()
	local camera = workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not camera or not root then
		return
	end
	-- Every frame rather than once: Roblox puts the camera back to Custom on respawn, and a
	-- one-time setting loses that race on a slow client.
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = Config.CAMERA_FOV

	-- Above and behind the focus: rotate by pitch, then yaw, then back off along the camera's Z.
	local focus = root.Position
	if shakeDuration > 0 then
		local elapsed = os.clock() - shakeStartedAt
		if elapsed < shakeDuration then
			local decay = 1 - elapsed / shakeDuration
			local mag = shakeAmplitude * decay * decay
			focus += Vector3.new(
				math.sin(elapsed * 190) * mag,
				math.cos(elapsed * 150) * mag * 0.6,
				math.cos(elapsed * 210) * mag
			)
		else
			shakeDuration = 0
			shakeAmplitude = 0
		end
	end
	camera.CFrame = CFrame.new(focus)
		* CFrame.fromEulerAnglesYXZ(math.rad(-Config.CAMERA_PITCH), math.rad(Config.CAMERA_YAW), 0)
		* CFrame.new(0, 0, Config.CAMERA_DISTANCE)
end

function IsoCamera.start()
	-- Just after Roblox's own camera step, so this is the last word on the frame.
	RunService:BindToRenderStep("IsoCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return IsoCamera
