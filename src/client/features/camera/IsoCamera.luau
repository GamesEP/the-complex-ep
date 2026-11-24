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
	camera.CFrame = CFrame.new(focus)
		* CFrame.fromEulerAnglesYXZ(math.rad(-Config.CAMERA_PITCH), math.rad(Config.CAMERA_YAW), 0)
		* CFrame.new(0, 0, Config.CAMERA_DISTANCE)
end

function IsoCamera.start()
	-- Just after Roblox's own camera step, so this is the last word on the frame.
	RunService:BindToRenderStep("IsoCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return IsoCamera
