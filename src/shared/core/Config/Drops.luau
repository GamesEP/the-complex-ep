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
	defense = "DropDefense",
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
-- Periodic map defense pickup: halves incoming damage (50% reduction) for its duration.
Config.BUFF_DEFENSE_REDUCTION = 0.50
Config.BUFF_DEFENSE_DURATION = 12
Config.DEFENSE_SPAWN_INTERVAL = 22
Config.DEFENSE_SPAWN_INSET = 12

-- Test sword model name under ReplicatedStorage.Models, equipped on spawn during the combat slice.
Config.TEST_SWORD_MODEL = "TestSword"
-- Degrees the blade is pitched forward from RightGripAttachment. That attachment's -Z points
-- *down* the forearm, so at the old 25° a relaxed arm planted the tip 2 studs under the floor; at
-- 70° the blade is held out in front, about 13° below horizontal at rest. Every combat pose in
-- CombatAnim (the block guard most of all) is tuned against this angle.
Config.SWORD_GRIP_PITCH = 70

return Config
