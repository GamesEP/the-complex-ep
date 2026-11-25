-- Combat drops left by defeated enemies and the temporary buffs they grant.
-- Models live as `.rbxmx` assets under `assets/models/` mounted at `ReplicatedStorage.Models`.
-- See docs/combat.md and plans/gdd/systems.md.
local Config = {}

-- Probability that a defeated enemy drops an item (30%).
Config.DROP_CHANCE = 0.30

-- Relative weights across the three drop kinds when a drop rolls.
Config.DROP_WEIGHTS = {
	heal = 40,
	damage = 30,
	speed = 30,
}

-- Model names under ReplicatedStorage.Models for each drop kind.
Config.DROP_MODELS = {
	heal = "DropHeal",
	damage = "DropDamage",
	speed = "DropSpeed",
}

-- Pickup geometry and lifetime in the room.
Config.DROP_HEIGHT = 2.2
Config.DROP_PICKUP_RADIUS = 4.5
Config.DROP_LIFETIME_SECONDS = 20

-- Effects granted on pickup.
Config.DROP_HEAL_AMOUNT = 25
Config.BUFF_DAMAGE_MULTIPLIER = 1.5
Config.BUFF_DAMAGE_DURATION = 10
Config.BUFF_SPEED_MULTIPLIER = 1.35
Config.BUFF_SPEED_DURATION = 10

-- Test sword model name under ReplicatedStorage.Models, equipped on spawn during the combat slice.
Config.TEST_SWORD_MODEL = "TestSword"

return Config
