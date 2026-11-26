--[[
	Wiring only: build the world, wire every remote through the Dispatcher's contract, start
	the services, connect the player lifecycle. Everything with behaviour lives in a feature.

	Two rules keep this file readable as the game grows:

	  1. **No behaviour here.** If a line does something other than name a module, call its
	     `start`, or connect a lifecycle event, it belongs in a feature. This file is the one
	     place a reader can see the whole game's shape at once, and that is only true while
	     nothing is hiding in it.
	  2. **Order is only load-bearing where a comment says so.** Anywhere a `start` has to
	     come before another, say why on the line. Silent ordering is the failure that
	     reproduces once a month on a slow client.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Environment = require(Shared.core.Environment)
local CombatAnim = require(Shared.features.combat.CombatAnim)
local CombatAudio = require(Shared.features.combat.CombatAudio)
local Defense = require(Shared.features.combat.Defense)
local Drops = require(Shared.features.drops.Drops)
local Melee = require(Shared.features.combat.Melee)
local Brain = require(Shared.features.enemies.Brain)
local Classes = require(Shared.features.classes.Classes)
local Difficulty = require(Shared.features.enemies.Difficulty)
local EnemyAnim = require(Shared.features.enemies.EnemyAnim)
local Tactics = require(Shared.features.enemies.Tactics)
local Tonemapper = require(Shared.features.tonemapping.Tonemapper)
local Waves = require(Shared.features.enemies.Waves)

local Server = script.Parent

local Dispatcher = require(Server.core.Net.Dispatcher)

local ClassService = require(Server.features.classes.ClassService)
local CombatService = require(Server.features.combat.CombatService)
local DropService = require(Server.features.drops.DropService)
local EnemyService = require(Server.features.enemies.EnemyService)
local FlagService = require(Server.features.flags.FlagService)
local LogSink = require(Server.features.telemetry.LogSink)
local WaveDirector = require(Server.features.enemies.WaveDirector)
local WorldBuilder = require(Server.features.world.WorldBuilder)

-- First, so everything below is inside the recording: a warning raised while the world is
-- still being built is exactly the one nobody is in the game to see. It announces the
-- environment and the build on the way up, which is the line every other line is read against.
LogSink.start()

-- Pure self tests, on the way up, in Studio only. They cost microseconds and they run at the
-- moment somebody is about to find out they broke something. The same assertions run offline
-- under `make test`, which is where they are cheap enough to run on every save.
if RunService:IsStudio() then
	CombatAnim.selfTest()
	CombatAudio.selfTest()
	Defense.selfTest()
	Drops.selfTest()
	Melee.selfTest()
	Brain.selfTest()
	Classes.selfTest()
	Difficulty.selfTest()
	EnemyAnim.selfTest()
	Tactics.selfTest()
	Tonemapper.selfTest()
	Waves.selfTest()
end

-- Anything the project file sets on Lighting is worth re-asserting here if the game depends on
-- it. Rojo patches Lighting when the plugin connects, and a Play pressed before that patch
-- lands clones the *old* values — so a setting that only exists in default.project.json can be
-- silently wrong for a whole Studio session. The server's Lighting replicates, so a line here
-- is self-healing where the project file alone is not.
Lighting.GlobalShadows = true
Lighting.Ambient = Config.LIGHTING_AMBIENT
Lighting.OutdoorAmbient = Config.LIGHTING_OUTDOOR_AMBIENT
Lighting.Brightness = Config.LIGHTING_BRIGHTNESS
Lighting.ClockTime = Config.LIGHTING_CLOCK_TIME

local world = WorldBuilder.build()

-- Before anybody joins: every player starts with `Class = ""` and the board waits on it.
ClassService.start({
	applyClass = CombatService.applyClass,
	world = world,
	onDifficultyChanged = function()
		WaveDirector.reset()
	end,
})
-- Each takes the other through its `start` rather than by path (CLAUDE.md): enemies hurt players
-- only through CombatService.hurt, so the dash's invulnerability covers every source of damage.
CombatService.start({ enemies = EnemyService, isPaused = ClassService.isPaused })
CombatService.startSupportTick()
DropService.start({ world = world, onPickup = CombatService.applyDrop, isPaused = ClassService.isPaused })
EnemyService.start({
	hurt = CombatService.hurt,
	world = world,
	onKill = DropService.maybeSpawn,
	canGrab = CombatService.canGrab,
	setGrabbed = CombatService.setGrabbed,
	warnGrab = CombatService.warnGrab,
	warnParry = CombatService.warnParry,
	stun = CombatService.stun,
	isPaused = ClassService.isPaused,
})
-- After EnemyService, DropService and CombatService, whose state it resets on room wipe.
WaveDirector.start({
	world = world,
	getDifficulty = ClassService.getDifficulty,
	onReset = function()
		DropService.clear()
		CombatService.clear()
	end,
})

-- Staff, in one place, so the flags and the admin-only remotes cannot disagree about who counts.
--
-- `Environment.isStudio()` rather than `RunService:IsStudio()`: they are the same test today, and
-- they stop being the same the moment somebody wants a universe where the team has admin. The
-- guard is written against the environment so that change is one row in Config rather than a
-- grep for IsStudio.
local function isAdmin(player: Player): boolean
	return Environment.isStudio() or table.find(Config.ADMIN_USER_IDS, player.UserId) ~= nil
end

-- Before anybody joins, so a player never spends their first frames with no flags resolved.
FlagService.start({
	isStaff = isAdmin,
	record = LogSink.record,
})

-- Every client->server remote, through the contract. The Dispatcher refuses a remote with no
-- contract entry, so this list cannot quietly grow an unmetered channel.
--
-- `init` is where the cross-cutting checks get their answers from. A game with rounds and
-- roles passes its round service here; this one has neither, so the checks the contract can
-- ask for are simply never satisfied by any entry.
Dispatcher.init({
	Round = {
		getRole = function(): string?
			return nil
		end,
		isPlaying = function(): boolean
			return true
		end,
		inRound = function(): boolean
			return true
		end,
	},
	isAdmin = isAdmin,
})

Dispatcher.connect("Attack", CombatService.attack)
Dispatcher.connect("HeavyCharge", CombatService.heavyCharge)
Dispatcher.connect("HeavyAttack", CombatService.heavyAttack)
Dispatcher.connect("Dash", CombatService.dash)
Dispatcher.connect("Spin", CombatService.spin)
Dispatcher.connect("Stinger", CombatService.stinger)
Dispatcher.connect("OverDrive", CombatService.overDrive)
Dispatcher.connect("Block", CombatService.block)
Dispatcher.connect("GrabEscape", EnemyService.onGrabEscape)
Dispatcher.connect("ChooseClass", ClassService.choose)
Dispatcher.connect("ChooseDifficulty", ClassService.chooseDifficulty)
Dispatcher.connect("UseAbility", CombatService.useAbility)
Dispatcher.connect("Diagnostic", LogSink.onClientReport)

local function onPlayerRemoving(player: Player)
	-- Every feature holding per-player state forgets it here. One line per feature, in the
	-- same file as the joins, so "what leaks when somebody leaves" is answerable by reading
	-- rather than by grepping for PlayerRemoving.
	CombatService.forget(player)
	EnemyService.forget(player)
end

Players.PlayerRemoving:Connect(onPlayerRemoving)

print(`world ready: {world:GetFullName()}`)
