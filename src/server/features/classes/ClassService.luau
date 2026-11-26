--[[
	Which test class each player is (plans/gdd/systems.md, "Clases"), and the pause while somebody
	is still choosing.

	The class is the `Class` attribute on the player: "" until chosen, then a key of
	Config.CLASSES. An attribute rather than a reply, so the selection screen, the HUD and every
	other client read it the same way, and a player who joins late sees everyone's class.

	The class survives respawns (it is on the Player, not the character). It is chosen once per
	session for now; whether it may be changed mid-room is an open question in the GDD.

	Applying a class — health, speed, weapon — is CombatService's, passed in as `applyClass`, so
	this module never reaches into another feature. See docs/combat.md.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Classes = require(ReplicatedStorage:WaitForChild("Shared").features.classes.Classes)

local ClassService = {}

local applyClass: (Player) -> () = nil :: any

local function onPlayer(player: Player)
	if player:GetAttribute("Class") == nil then
		player:SetAttribute("Class", "")
	end
end

function ClassService.start(dependencies: { applyClass: (Player) -> () })
	applyClass = dependencies.applyClass
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
end

-- Remote "ChooseClass". The contract checked it is a string; this checks it names a class.
function ClassService.choose(player: Player, classId: string)
	if not Classes.isValid(classId) then
		return
	end
	-- Once per session. A second choice would hand a player mid-fight full health and fresh
	-- cooldowns for free.
	local current = player:GetAttribute("Class")
	if type(current) == "string" and current ~= "" then
		return
	end
	player:SetAttribute("Class", classId)
	applyClass(player)
end

-- True while any player in the server has not chosen yet. EnemyService freezes on it (plans/gdd/
-- systems.md: the enemies wait while somebody is choosing).
function ClassService.isPaused(): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		local current = player:GetAttribute("Class")
		if type(current) ~= "string" or current == "" then
			return true
		end
	end
	return false
end

return ClassService
