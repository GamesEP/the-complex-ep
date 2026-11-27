--[[
	Which test class each player is (plans/gdd/systems.md, "Clases"), the room's chosen difficulty
	(Fácil, Normal, Difícil, Zona Muerta), and the pause while somebody is still choosing.

	The class is the `Class` attribute on the player (`""` until chosen) and the difficulty is the
	`Difficulty` attribute on `workspace.World` (defaults to `Config.DEFAULT_DIFFICULTY`). Changing
	difficulty is only allowed while paused on the start screen so nobody can drop the difficulty
	mid-fight, and resets the waiting wave so Wave 1 spawns with the chosen tier's counts and stats.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Classes = require(Shared.features.classes.Classes)
local Difficulty = require(Shared.features.enemies.Difficulty)

local ClassService = {}

local applyClass: (Player) -> () = nil :: any
local worldRef: Instance? = nil
local onDifficultyChanged: ((string) -> ())? = nil
local currentDifficulty: string = Config.DEFAULT_DIFFICULTY

local function onPlayer(player: Player)
	if player:GetAttribute("Class") == nil then
		player:SetAttribute("Class", "")
	end
end

function ClassService.start(dependencies: {
	applyClass: (Player) -> (),
	world: Instance?,
	onDifficultyChanged: ((string) -> ())?,
})
	applyClass = dependencies.applyClass
	worldRef = dependencies.world
	onDifficultyChanged = dependencies.onDifficultyChanged
	currentDifficulty = Config.DEFAULT_DIFFICULTY
	if worldRef then
		worldRef:SetAttribute("Difficulty", currentDifficulty)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
end

function ClassService.getDifficulty(): string
	return currentDifficulty
end

-- True while any player in the server has not chosen yet. EnemyService, DropService and
-- CombatService freeze on it while the start screen is open.
function ClassService.isPaused(): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		local current = player:GetAttribute("Class")
		if type(current) ~= "string" or current == "" then
			return true
		end
	end
	return false
end

-- Remote "ChooseDifficulty". Allowed only while paused on the start screen before the fight begins.
function ClassService.chooseDifficulty(_player: Player, diffId: string)
	if not Difficulty.isValid(diffId) or not ClassService.isPaused() then
		return
	end
	if diffId == currentDifficulty then
		return
	end
	currentDifficulty = diffId
	if worldRef then
		worldRef:SetAttribute("Difficulty", currentDifficulty)
	end
	if onDifficultyChanged then
		onDifficultyChanged(currentDifficulty)
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
	if applyClass then
		applyClass(player)
	end
end

return ClassService
