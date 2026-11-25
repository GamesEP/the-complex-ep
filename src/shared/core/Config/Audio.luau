-- Combat sound effects for the player and all three slice enemy kinds.
--
-- Each cue names a custom Vorbis file in `assets/` (uploaded by `make sync-assets` into
-- `Assets/AssetIds.json`) and a verified public Creator Store `fallbackId` so local Studio runs
-- are audible before Open Cloud upload is configured. Once `Assets.id(file)` is non-zero, the
-- custom file wins automatically. See docs/combat.md.
local Config = {}

export type SfxSpec = {
	file: string,
	fallbackId: number,
	volume: number,
	pitch: number,
	pitchSpread: number?,
	stepPitch: number?,
	maxDistance: number?,
	-- Cuts long fallback samples cleanly (e.g. a melee windup telegraph) before the strike lands.
	maxDuration: number?,
}

Config.SFX = {
	-- Player basic combo hits 1..2; stepPitch lifts hit 2 slightly before the heavy finisher.
	playerAttack = {
		file = "player-attack.ogg",
		fallbackId = 7118966167,
		volume = 0.55,
		pitch = 1.05,
		pitchSpread = 0.06,
		stepPitch = 0.1,
		maxDistance = 65,
	},
	-- Heavy 3rd hit of the combo.
	playerAttackHeavy = {
		file = "player-attack-heavy.ogg",
		fallbackId = 140277245983305,
		volume = 0.7,
		pitch = 0.95,
		pitchSpread = 0.05,
		maxDistance = 75,
	},
	-- Fast evasive dash burst.
	playerDash = {
		file = "player-dash.ogg",
		fallbackId = 130555831799989,
		volume = 0.7,
		pitch = 1.25,
		pitchSpread = 0.06,
		maxDistance = 65,
	},
	-- 360-degree spin ability.
	playerSpin = {
		file = "player-spin.ogg",
		fallbackId = 74127269441035,
		volume = 0.8,
		pitch = 1.15,
		pitchSpread = 0.05,
		maxDistance = 85,
	},
	-- Confirmation impact when a player swing or spin connects with at least one enemy.
	playerHit = {
		file = "player-hit.ogg",
		fallbackId = 9119072660,
		volume = 0.5,
		pitch = 1.15,
		pitchSpread = 0.08,
		maxDistance = 70,
	},
	-- Melee enemy windup telegraph (paired with Neon material so the player hears when to dash).
	enemyMeleeWindup = {
		file = "enemy-melee-windup.ogg",
		fallbackId = 9118270242,
		volume = 0.4,
		pitch = 1.6,
		pitchSpread = 0.06,
		maxDistance = 75,
		maxDuration = 0.42,
	},
	-- Melee enemy strike release.
	enemyMeleeStrike = {
		file = "enemy-melee-strike.ogg",
		fallbackId = 126976659766267,
		volume = 0.65,
		pitch = 0.95,
		pitchSpread = 0.08,
		maxDistance = 80,
	},
	-- Ranged enemy energy bolt shot.
	enemyRangedFire = {
		file = "enemy-ranged-fire.ogg",
		fallbackId = 71286443122760,
		volume = 0.5,
		pitch = 1.05,
		pitchSpread = 0.08,
		maxDistance = 95,
	},
	-- Exploder fuse warning (length tuned to Config.ENEMY_KINDS.exploder.fuse = 0.8s).
	enemyExploderFuse = {
		file = "enemy-exploder-fuse.ogg",
		fallbackId = 9117060347,
		volume = 0.65,
		pitch = 1.1,
		pitchSpread = 0.05,
		maxDistance = 90,
		maxDuration = 0.8,
	},
	-- Exploder detonation blast.
	enemyExploderBlast = {
		file = "enemy-exploder-blast.ogg",
		fallbackId = 138533090376585,
		volume = 0.85,
		pitch = 1.0,
		pitchSpread = 0.06,
		maxDistance = 120,
	},
	-- Pickup chime for a heal drop.
	dropHeal = {
		file = "drop-heal.ogg",
		fallbackId = 7381723941,
		volume = 0.65,
		pitch = 1.15,
		pitchSpread = 0.05,
		maxDistance = 65,
	},
	-- Pickup surge for a damage or movement-speed buff drop.
	dropBuff = {
		file = "drop-buff.ogg",
		fallbackId = 100288208393628,
		volume = 0.7,
		pitch = 1.05,
		pitchSpread = 0.05,
		maxDistance = 70,
	},
} :: { [string]: SfxSpec }

-- Fallback lifetime for a temporary 3D sound anchor when `Sound.Ended` never fires (e.g. a muted
-- or slow-loading asset). Keeps Terrain from accumulating orphaned Attachments.
Config.SFX_MAX_CLEANUP_SECONDS = 4
Config.SFX_FADE_OUT_SECONDS = 0.08

return Config
