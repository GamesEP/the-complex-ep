--[[
	Wiring only. Everything with behaviour lives in a feature; this decides what starts, and in
	what order — and the order is load-bearing where a comment says so.

	The same two rules as the server bootstrap: no behaviour in this file, and any ordering
	that matters is a comment on the line that depends on it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Environment = require(ReplicatedStorage:WaitForChild("Shared").core.Environment)

local Client = script.Parent

local Layout = require(Client.ui.ScreenMetrics)

local BuildStamp = require(Client.features.environment.ui.BuildStamp)
local CombatHud = require(Client.features.combat.ui.CombatHud)
local CombatInput = require(Client.features.combat.CombatInput)
local DropVisuals = require(Client.features.drops.DropVisuals)
local EnemyAnimator = require(Client.features.enemies.EnemyAnimator)
local IsoCamera = require(Client.features.camera.IsoCamera)
local PlayerAnimator = require(Client.features.combat.PlayerAnimator)
local SoundPlayer = require(Client.features.combat.SoundPlayer)

-- Before anything builds a ScreenGui: every panel asks Layout how much room it has and mounts
-- inside the UIScale it hands out, so it has to know the screen first.
Layout.start()

IsoCamera.start()
DropVisuals.start()
EnemyAnimator.start()
PlayerAnimator.start()
SoundPlayer.start()
CombatInput.start()

-- Everywhere but production, so a screenshot always says which experience it came from. The
-- decision is here rather than inside the screen: a watermark that can decide for itself to be
-- visible is one bad boolean away from being visible to players.
if not Environment.isProduction() then
	BuildStamp.start()
end

-- Last: it waits for the server to have built the room, and nothing above should wait with it.
CombatHud.start()
