-- The player's kit: how fast they move, how the combo and the dash behave, the spin attack.
-- These are the numbers that decide whether the game feels "de alta velocidad" (plans/gdd/
-- loop.md), so they are the first thing to tune and they are all starting guesses.
local Config = {}

Config.PLAYER_MAX_HEALTH = 100
-- Short: in the slice a death resets the room, and waiting to try again is not the game.
Config.RESPAWN_SECONDS = 3
-- Roblox's default is 16. Movement is half of what makes the game fast, so it starts well above.
Config.MOVE_SPEED = 26
Config.JUMP_POWER = 55

-- The combo. Each press is one hit; a press inside COMBO_WINDOW of the last one continues the
-- chain, anything later starts it again. The last hit is the heavy one, so finishing a combo is
-- worth more than mashing the first hit.
Config.COMBO_HITS = 3
Config.COMBO_DAMAGE = { 10, 10, 20 }
Config.COMBO_WINDOW = 0.6
-- The fastest a client may swing. The server accepts a little under this (ATTACK_TOLERANCE)
-- because two presses that left the client exactly this far apart can arrive closer together.
Config.ATTACK_INTERVAL = 0.22
Config.ATTACK_TOLERANCE = 0.75
-- Studs in front of the player, and the width of the swing in degrees. Generous on purpose: the
-- server checks against a position ~100 ms old, and a hit that looked clean must land.
Config.ATTACK_RANGE = 8
Config.ATTACK_ARC = 120
-- Forward target-sticking for basic attacks on every input device (mouse, touch, gamepad):
-- searches a cone ahead of the player's facing/movement direction, prioritising enemies most
-- aligned with where the player is looking, and closes short gaps so combos stick to them.
Config.AIM_ASSIST_RANGE = 15
Config.AIM_ASSIST_CONE = 120
-- Narrower cone used to keep the previously picked enemy locked across a combo (or after an
-- ability): wide enough for 8-way WASD movement toward a strafing enemy, narrow enough to drop
-- the lock the moment the player steers toward a different one.
Config.TARGET_LOCK_CONE = 110
-- Weight of angular alignment vs distance (0..1) when ranking candidates inside the forward cone.
Config.AIM_ASSIST_ANGLE_WEIGHT = 0.65
-- Attack lunge: closes up to MAX_DISTANCE at SPEED, stopping STOP_DISTANCE studs outside the
-- target's radius so the character sticks right in front of the enemy without overshooting.
Config.ATTACK_LUNGE_MAX_DISTANCE = 8
Config.ATTACK_LUNGE_STOP_DISTANCE = 2.5
Config.ATTACK_LUNGE_SPEED = 90

-- Charged heavy attack: holding Attack continuously for HEAVY_CHARGE_SECONDS (2 s) charges a
-- devastating wide forward cleave that unleashes automatically at full charge. Normal taps still
-- swing immediately on Begin; holding past HEAVY_CHARGE_DELAY enters the visible charge stance.
Config.HEAVY_CHARGE_DELAY = 0.25
Config.HEAVY_CHARGE_SECONDS = 2.0
Config.HEAVY_CHARGE_SLACK = 0.15
Config.HEAVY_CHARGE_MOVE_MULTIPLIER = 0.60
Config.HEAVY_ATTACK_DAMAGE = 55
Config.HEAVY_ATTACK_RANGE = 13
Config.HEAVY_ATTACK_ARC = 160
Config.HEAVY_ATTACK_LUNGE_MAX_DISTANCE = 10
Config.HEAVY_ATTACK_COOLDOWN = 0.6

-- The dash is a basic move, always available (plans/gdd/systems.md, Combate). Distance over
-- duration is its speed; IFRAMES is how long it ignores damage, slightly longer than the dash
-- itself so dashing *through* an attack is reliable rather than a coin flip.
Config.DASH_DISTANCE = 18
Config.DASH_DURATION = 0.18
Config.DASH_COOLDOWN = 0.7
Config.DASH_IFRAMES = 0.25

-- Active ability kit (3 switchable slots via keys 1, 2, 3; cast with E / Y / R1 / touch):
Config.ABILITY_SLOTS = 3

-- Slot 1 — Giro (Spin): 360-degree tornado cleave around the player.
Config.SPIN_DAMAGE = 25
Config.SPIN_RADIUS = 12
Config.SPIN_COOLDOWN = 4

-- Slot 2 — Stinger (DMC-style piercing thrust): explosive forward lunge skewering every enemy
-- along a narrow corridor ahead.
Config.STINGER_DAMAGE = 35
Config.STINGER_DISTANCE = 26
Config.STINGER_DURATION = 0.24
Config.STINGER_WIDTH = 6.5
Config.STINGER_COOLDOWN = 5.5

-- Slot 3 — Over Drive (DMC-style Ultimate): longest cooldown; channels energy into the blade
-- then unleashes 3 devastating piercing crescent slash waves downrange.
Config.OVERDRIVE_COOLDOWN = 14.0
Config.OVERDRIVE_CHARGE_SECONDS = 0.75
Config.OVERDRIVE_CHARGE_MOVE_MULTIPLIER = 0.35
Config.OVERDRIVE_WAVES = 3
Config.OVERDRIVE_WAVE_INTERVAL = 0.22
Config.OVERDRIVE_WAVE_DAMAGE = { 38, 42, 55 }
Config.OVERDRIVE_WAVE_RANGE = 56
Config.OVERDRIVE_WAVE_WIDTH = 9.0

-- Guard & Parry: holding Block cuts incoming damage by BLOCK_DAMAGE_REDUCTION while slowing
-- movement; raising Block right before impact (within PARRY_WINDOW) negates all damage,
-- staggers melee attackers, and reflects ranged projectiles back at enemies.
Config.BLOCK_DAMAGE_REDUCTION = 0.70
Config.BLOCK_MOVE_MULTIPLIER = 0.55
Config.BLOCK_COOLDOWN = 0.45
Config.PARRY_WINDOW = 0.25
Config.PARRY_STUN_SECONDS = 1.4
Config.PARRY_PROJECTILE_SPEED_MULTIPLIER = 1.6
Config.PARRY_PROJECTILE_DAMAGE = 25
Config.PARRY_PROJECTILE_LIFE = 2.0

-- Isometric camera: a fixed yaw and pitch, following the player at a fixed distance.
Config.CAMERA_DISTANCE = 70
Config.CAMERA_PITCH = 50
Config.CAMERA_YAW = 45
Config.CAMERA_FOV = 30

return Config
