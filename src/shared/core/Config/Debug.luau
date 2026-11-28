-- In-game admin dev/debug toolset tunables (docs/debug-tools.md).
-- Every command is locked behind `Contract.AdminCommand` (`admin = true`) on the server and
-- additionally blocked in production unless `DEBUG_ALLOW_IN_PRODUCTION` is explicitly flipped on.
local Config = {}

-- Production kill switch: even user ids in `Config.ADMIN_USER_IDS` cannot invoke debug commands
-- or mount the Dev Panel in the production universe while this is false.
Config.DEBUG_ALLOW_IN_PRODUCTION = false

-- Rate limit (calls/sec) enforced by Dispatcher on `Remotes.AdminCommand`.
Config.DEBUG_ADMIN_RATE = 15

-- Non-conflicting PC toggle key for the Dev Panel (avoids WASD, Space, Shift, 1..3, Q/E/F, and F9).
Config.DEBUG_TOGGLE_KEY = Enum.KeyCode.F4

-- Quick-select multipliers and spawn batch sizes shown in the Dev Panel.
Config.DEBUG_DAMAGE_MULTS = { 1, 5, 100 }
Config.DEBUG_SPAWN_COUNTS = { 1, 5, 10, 25 }
Config.DEBUG_MAX_SPAWN_COUNT = 25

-- High-HP passive training dummy health for combo / DPS / hitstop testing.
Config.DEBUG_DUMMY_HEALTH = 9999

-- Rolling combat math log capacity (store cap vs. visible lines in the overlay).
Config.DEBUG_LOG_MAX_ENTRIES = 30
Config.DEBUG_LOG_VISIBLE_ENTRIES = 12

-- Translucent wireframe colors for the client-side HitboxVisualizer overlay.
Config.DEBUG_OVERLAY_COLORS = {
	aimCone = Color3.fromRGB(56, 212, 255),
	lockLine = Color3.fromRGB(245, 196, 0),
	doorZone = Color3.fromRGB(68, 240, 152),
	pillarHull = Color3.fromRGB(160, 175, 195),
	enemyReach = Color3.fromRGB(255, 122, 56),
	blastOval = Color3.fromRGB(255, 165, 45),
	bossHazard = Color3.fromRGB(255, 46, 76),
	attackHitbox = Color3.fromRGB(255, 178, 48),
	attackHitConfirm = Color3.fromRGB(78, 255, 152),
}

return Config
