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
-- How far the client turns the player to the nearest enemy when attacking without a mouse
-- (touch, gamepad). Past this there is nothing worth turning for.
Config.AIM_ASSIST_RANGE = 16

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
