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
-- worth more than mashing the first hit. Every attack and ability has an active phase followed by
-- a recovery tail (see Config/Animations.luau `cancelAt`) that any other attack or ability can
-- cancel into, giving DMC-style deliberate rhythm and cancel chains.
Config.COMBO_HITS = 3
Config.COMBO_DAMAGE = { 10, 10, 20 }
Config.COMBO_WINDOW = 1.15
-- Fastest cancelable cadence for light hits (1 & 2) and the heavy combo finisher (hit 3),
-- matching `Config.ANIMATIONS.attack.cancelAt` and `attackHeavy.cancelAt`. The server accepts a
-- little under this (`ATTACK_TOLERANCE`) so network jitter never drops a clean recovery cancel.
Config.ATTACK_INTERVAL = 0.36
Config.ATTACK_FINISHER_INTERVAL = 0.50
Config.ATTACK_TOLERANCE = 0.75
-- Input buffer window (seconds) before an attack or ability reaches its recovery cancel point:
-- pressing the next attack/ability slightly early fires it on the first frame of recovery.
Config.COMBO_INPUT_BUFFER = 0.18
-- Studs in front of the player, and the width of the swing in degrees. Generous on purpose: the
-- server checks against a position ~100 ms old, and a hit that looked clean must land.
Config.ATTACK_RANGE = 8
Config.ATTACK_ARC = 120
-- Forward target-sticking and DMC-style soft lock for basic attacks and skills on every input
-- device (mouse, touch, gamepad): once locked onto an enemy, neutral input or steering in the
-- general direction of the target (`TARGET_LOCK_CONE`) keeps the lock and tracks its small
-- movement; steering in any other direction breaks the lock immediately to switch targets or leave.
Config.AIM_ASSIST_RANGE = 18
Config.AIM_ASSIST_CONE = 120
Config.TARGET_LOCK_CONE = 120
Config.TARGET_LOCK_BREAK_RANGE = 22
Config.TARGET_LOCK_DURATION = 2.4
-- Gentle close-range magnetic follow while locked and active in combo/recovery so a target's
-- slight hitstun recoil never nudges it out of the attack's sweet spot.
Config.TARGET_LOCK_MAGNET_RANGE = 5.5
Config.TARGET_LOCK_MAGNET_SPEED = 24
-- Weight of angular alignment vs distance (0..1) when ranking candidates inside the forward cone.
Config.AIM_ASSIST_ANGLE_WEIGHT = 0.65
-- Attack & skill lunge: closes up to MAX_DISTANCE at SPEED and brakes cleanly at STOP_DISTANCE
-- studs outside the target's radius (right in the middle of melee reach) with zero overshoot.
Config.ATTACK_LUNGE_MAX_DISTANCE = 12
Config.ATTACK_LUNGE_STOP_DISTANCE = 2.5
Config.ATTACK_LUNGE_SPEED = 78
Config.SPIN_LUNGE_MAX_DISTANCE = 11

-- Charged heavy attack: holding Attack continuously for HEAVY_CHARGE_SECONDS (2 s) charges a
-- devastating wide forward cleave that unleashes automatically at full charge. Normal taps still
-- swing immediately on Begin; holding past HEAVY_CHARGE_DELAY enters the visible charge stance.
Config.HEAVY_CHARGE_DELAY = 0.36
Config.HEAVY_CHARGE_SECONDS = 2.0
Config.HEAVY_CHARGE_SLACK = 0.15
Config.HEAVY_CHARGE_MOVE_MULTIPLIER = 0.60
Config.HEAVY_ATTACK_DAMAGE = 55
Config.HEAVY_ATTACK_RANGE = 13
Config.HEAVY_ATTACK_ARC = 160
Config.HEAVY_ATTACK_LUNGE_MAX_DISTANCE = 13
Config.HEAVY_ATTACK_COOLDOWN = 0.6

-- The dash is a basic move, always available (plans/gdd/systems.md, Combate). Distance over
-- duration is its speed; IFRAMES is how long it ignores damage, slightly longer than the dash
-- itself so dashing *through* an attack is reliable rather than a coin flip.
Config.DASH_DISTANCE = 18
Config.DASH_DURATION = 0.20
Config.DASH_COOLDOWN = 0.7
Config.DASH_IFRAMES = 0.26

-- Active ability kit (3 switchable slots via keys 1, 2, 3; cast with E / Y / R1 / touch):
Config.ABILITY_SLOTS = 3

-- Slot 1 — Giro (Spin): 360-degree tornado cleave around the player.
Config.SPIN_DAMAGE = 25
Config.SPIN_RADIUS = 12
Config.SPIN_COOLDOWN = 4

-- Slot 2 — Stinger (DMC-style piercing thrust): explosive forward lunge skewering every enemy
-- along a narrow corridor ahead, stopping right in sweet-spot range before a locked target.
Config.STINGER_DAMAGE = 35
Config.STINGER_DISTANCE = 26
Config.STINGER_DURATION = 0.34
Config.STINGER_STOP_DISTANCE = 2.4
Config.STINGER_WIDTH = 6.5
Config.STINGER_COOLDOWN = 5.5

-- Slot 3 — Over Drive (DMC-style Ultimate): longest cooldown; channels energy into the blade
-- then unleashes 3 devastating piercing crescent slash waves downrange.
Config.OVERDRIVE_COOLDOWN = 14.0
Config.OVERDRIVE_CHARGE_SECONDS = 0.75
Config.OVERDRIVE_CHARGE_MOVE_MULTIPLIER = 0.35
Config.OVERDRIVE_WAVES = 3
Config.OVERDRIVE_WAVE_INTERVAL = 0.34
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
