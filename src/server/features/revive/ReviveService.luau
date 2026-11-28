--!strict
--[[
	Server-authoritative Co-op Downed & 5 s Ally Revive service (`plans/gdd/systems.md`,
	`plans/roadmap.md HS-29`).

	Intercepts lethal damage via `CombatService`'s `onLethalDamage` callback:
	  - Solo / last standing teammate -> invokes `ReviveRules.resolveWipe` -> `onSquadWipe()`.
	  - Co-op with >= 1 standing teammate -> freezes player in `Downed = true` at 1 HP, replicates
	    `Downed` and `ReviveProgress` (`0..1`) attributes, and steps proximity revive channels on
	    `Heartbeat`. Normal damage on a rescuer does NOT interrupt; leaving the 8-stud ring, getting
	    stunned, grabbed, or downed resets progress cleanly.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunServiceEngine = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)
local ReviveRules = require(Shared.features.revive.ReviveRules)

local ReviveService = {}

local isInRun: (() -> boolean)? = nil
local onSquadWipe: (() -> ())? = nil
local onPlayerDowned: ((Player) -> ())? = nil
local onPlayerRevived: ((Player) -> ())? = nil
local onWipeOffer: (() -> string)? = nil

local downedProgress: { [Player]: number } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function isPlayerStanding(player: Player): boolean
	if not player.Parent then
		return false
	end
	if player:GetAttribute("Downed") == true then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function rootPositionOf(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

function ReviveService.isDowned(player: Player): boolean
	return player:GetAttribute("Downed") == true
end

function ReviveService.isAnyoneStanding(): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		if isPlayerStanding(player) then
			return true
		end
	end
	return false
end

local function triggerSquadWipe()
	local outcome = ReviveRules.resolveWipe(onWipeOffer)
	if outcome == "defeat" and onSquadWipe then
		onSquadWipe()
	end
end

-- Called by `CombatService.hurt` right when incoming damage would reduce `player` to <= 0 HP.
-- Returns `true` if the player entered Downed (caller keeps Humanoid at 1 HP) or `false` if this
-- was a squad wipe (which immediately triggers `onSquadWipe`).
function ReviveService.onLethalDamage(player: Player): boolean
	if isInRun and not isInRun() then
		return false
	end
	if player:GetAttribute("Downed") == true then
		return true
	end

	local standingOthers = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and isPlayerStanding(other) then
			standingOthers += 1
		end
	end

	if not ReviveRules.canEnterDowned(standingOthers) then
		-- Solo or last standing teammate: full squad wipe.
		downedProgress[player] = nil
		player:SetAttribute("Downed", false)
		player:SetAttribute("ReviveProgress", 0)
		triggerSquadWipe()
		return true
	end

	downedProgress[player] = 0
	player:SetAttribute("Downed", true)
	player:SetAttribute("ReviveProgress", 0)
	player:SetAttribute("ReviveHelpers", 0)
	if onPlayerDowned then
		onPlayerDowned(player)
	end
	local pos = rootPositionOf(player)
	if pos then
		Remotes.CombatSfx:FireAllClients("playerDowned", pos)
	end
	return true
end

local function completeRevive(player: Player)
	downedProgress[player] = nil
	player:SetAttribute("Downed", false)
	player:SetAttribute("ReviveProgress", 0)
	player:SetAttribute("ReviveHelpers", 0)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and humanoid and humanoid.Health > 0 then
		humanoid.Health = ReviveRules.reviveHealth(humanoid.MaxHealth)
		character:SetAttribute("InvulnerableUntil", now() + Config.ALLY_REVIVE_IMMUNITY_SECONDS)
	end
	if onPlayerRevived then
		onPlayerRevived(player)
	end
	local pos = rootPositionOf(player)
	if pos then
		Remotes.CombatSfx:FireAllClients("playerRevived", pos)
	end
end

function ReviveService.reviveDownedAll()
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("Downed") == true then
			completeRevive(player)
		end
	end
end

function ReviveService.resetAll()
	table.clear(downedProgress)
	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute("Downed", false)
		player:SetAttribute("ReviveProgress", 0)
		player:SetAttribute("ReviveHelpers", 0)
	end
end

function ReviveService.forget(player: Player)
	downedProgress[player] = nil
	-- If the last standing teammate disconnects mid-run while others remain downed, wipe cleanly.
	if isInRun and isInRun() then
		local statuses: { ReviveRules.MemberStatus } = {}
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player then
				table.insert(statuses, { standing = isPlayerStanding(other) })
			end
		end
		if #statuses > 0 and ReviveRules.isSquadWiped(statuses) then
			triggerSquadWipe()
		end
	end
end

local function step(dt: number)
	if isInRun and not isInRun() then
		return
	end
	if next(downedProgress) == nil then
		return
	end

	local t = now()
	local players = Players:GetPlayers()
	local statuses: { ReviveRules.MemberStatus } = {}
	for _, p in ipairs(players) do
		table.insert(statuses, { standing = isPlayerStanding(p) })
	end
	if ReviveRules.isSquadWiped(statuses) then
		triggerSquadWipe()
		return
	end

	for player, curProg in pairs(downedProgress) do
		if not player.Parent or player:GetAttribute("Downed") ~= true then
			downedProgress[player] = nil
			continue
		end
		local downedPos = rootPositionOf(player)
		if not downedPos then
			downedProgress[player] = 0
			player:SetAttribute("ReviveProgress", 0)
			continue
		end

		local helpers = 0
		for _, candidate in ipairs(players) do
			if candidate ~= player and isPlayerStanding(candidate) then
				local pos = rootPositionOf(candidate)
				if pos then
					local stunnedUntil = candidate:GetAttribute("StunnedUntil")
					local stunned = type(stunnedUntil) == "number" and t < stunnedUntil
					local grabbed = candidate:GetAttribute("Grabbed") == true
					if ReviveRules.isValidRescuer(pos, downedPos, false, stunned, grabbed) then
						helpers += 1
					end
				end
			end
		end

		local nextProg, completed = ReviveRules.stepChannel(curProg, dt, helpers)
		player:SetAttribute("ReviveHelpers", helpers)
		if completed then
			completeRevive(player)
		else
			downedProgress[player] = nextProg
			player:SetAttribute("ReviveProgress", nextProg)
		end
	end
end

function ReviveService.start(deps: {
	isInRun: (() -> boolean)?,
	onSquadWipe: (() -> ())?,
	onPlayerDowned: ((Player) -> ())?,
	onPlayerRevived: ((Player) -> ())?,
	onWipeOffer: (() -> string)?,
})
	isInRun = deps.isInRun
	onSquadWipe = deps.onSquadWipe
	onPlayerDowned = deps.onPlayerDowned
	onPlayerRevived = deps.onPlayerRevived
	onWipeOffer = deps.onWipeOffer

	Players.PlayerAdded:Connect(function(player: Player)
		player:SetAttribute("Downed", false)
		player:SetAttribute("ReviveProgress", 0)
		player:SetAttribute("ReviveHelpers", 0)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute("Downed", false)
		player:SetAttribute("ReviveProgress", 0)
		player:SetAttribute("ReviveHelpers", 0)
	end

	RunServiceEngine.Heartbeat:Connect(step)
end

return ReviveService
