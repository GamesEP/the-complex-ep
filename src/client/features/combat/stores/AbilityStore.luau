--!strict
--[[
	Client-owned active ability slot selection (1 = Giro, 2 = Stinger, 3 = Over Drive).

	Plain Luau Charm atom so `CombatInput` (keys 1/2/3 & gamepad cycling) and `CombatHud` (icon
	selection highlight & tap-to-select) stay in sync without touching any Roblox service — which
	lets `make test ONLY=ui` assert slot clamping and wrap-around offline. See docs/ui-architecture.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage:WaitForChild("Packages").charm)
local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

local AbilityStore = {}

local MAX_SLOTS = math.max(Config.ABILITY_SLOTS or 3, 1)

AbilityStore.slot = Charm.atom(1)

function AbilityStore.current(): number
	return AbilityStore.slot()
end

function AbilityStore.select(index: number): number
	local clamped = math.clamp(math.floor(index), 1, MAX_SLOTS)
	AbilityStore.slot(clamped)
	return clamped
end

function AbilityStore.cycle(delta: number): number
	local cur = AbilityStore.slot()
	local nextSlot = ((cur - 1 + delta) % MAX_SLOTS) + 1
	AbilityStore.slot(nextSlot)
	return nextSlot
end

function AbilityStore.reset()
	AbilityStore.slot(1)
end

function AbilityStore.selfTest()
	AbilityStore.reset()
	assert(AbilityStore.current() == 1, "starts on slot 1 (Giro)")
	assert(AbilityStore.select(2) == 2 and AbilityStore.current() == 2, "switches to slot 2 (Stinger)")
	assert(AbilityStore.select(3) == 3 and AbilityStore.current() == 3, "switches to slot 3 (Over Drive)")
	assert(AbilityStore.select(99) == MAX_SLOTS, "clamps above max slots")
	assert(AbilityStore.select(0) == 1, "clamps below slot 1")
	assert(AbilityStore.cycle(-1) == MAX_SLOTS, "cycling backward from 1 wraps to last slot")
	assert(AbilityStore.cycle(1) == 1, "cycling forward from last wraps to 1")
	AbilityStore.reset()
end

return AbilityStore
