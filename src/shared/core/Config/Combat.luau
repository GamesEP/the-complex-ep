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
Config.AIM_ASSIST_CONE = 140
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

-- The dash is a basic move, always available (plans/gdd/systems.md, Combate). Distance over
-- duration is its speed; IFRAMES is how long it ignores damage, slightly longer than the dash
-- itself so dashing *through* an attack is reliable rather than a coin flip.
Config.DASH_DISTANCE = 18
Config.DASH_DURATION = 0.18
Config.DASH_COOLDOWN = 0.7
Config.DASH_IFRAMES = 0.25

-- The slice's one ability (plans/gdd/scope.md): hits everything around the player.
Config.SPIN_DAMAGE = 25
Config.SPIN_RADIUS = 12
Config.SPIN_COOLDOWN = 4

-- Isometric camera: a fixed yaw and pitch, following the player at a fixed distance.
Config.CAMERA_DISTANCE = 70
Config.CAMERA_PITCH = 50
Config.CAMERA_YAW = 45
Config.CAMERA_FOV = 30

return Config
