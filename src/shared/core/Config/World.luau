-- The combat room: a tracked `.rbxmx` industrial sci-fi arena (`assets/models/ComplexArena.rbxmx`,
-- mounted at `ReplicatedStorage.Models.ComplexArena`) cloned by WorldBuilder on boot.
--
-- Spawns are offsets from the arena's pivot, never hardcoded world coordinates (CLAUDE.md,
-- "Two kinds of world").
local Config = {}

Config.ARENA_MODEL = "ComplexArena"

-- The playable floor footprint in studs (must match ComplexArena.rbxmx's Floor slab).
Config.ROOM_SIZE = Vector2.new(140, 140)
Config.ROOM_WALL_HEIGHT = 18
Config.ROOM_FLOOR_COLOR = Color3.fromRGB(48, 52, 60)
Config.ROOM_WALL_COLOR = Color3.fromRGB(42, 46, 54)
Config.ROOM_FLOOR_MATERIAL = Enum.Material.Concrete

-- Offset from the arena's pivot where players arrive (centre entry elevator pad).
Config.SPAWN_OFFSET = CFrame.new(0, 4, 0)

-- Solid structures and perimeter props in ComplexArena.rbxmx (matching every `addNoClimbHull`
-- and `BunkerCollider` in `scripts/generate-arena.luau`). Shared with Waves, EnemyService,
-- CombatService, and DropService so enemies, lunges, rushes, and projectiles never clip through
-- pillars, bunkers, cryo clusters, crates, consoles, racks, pallets, or barrels.
Config.ARENA_PILLARS = {
	-- 4 quadrant reactor pillars (`PillarHull` = 9.2 x 9.2)
	{ x = -38, z = -38, halfX = 4.6, halfZ = 4.6 },
	{ x = 38, z = -38, halfX = 4.6, halfZ = 4.6 },
	{ x = -38, z = 38, halfX = 4.6, halfZ = 4.6 },
	{ x = 38, z = 38, halfX = 4.6, halfZ = 4.6 },
	-- 5 low tactical cover bunkers (`BunkerCollider` = 6.8 x 3.6, yaw 0 or 90)
	{ x = -22, z = -48, halfX = 3.4, halfZ = 1.8 },
	{ x = 22, z = -48, halfX = 3.4, halfZ = 1.8 },
	{ x = -46, z = 0, halfX = 1.8, halfZ = 3.4 },
	{ x = 46, z = 0, halfX = 1.8, halfZ = 3.4 },
	{ x = 0, z = 44, halfX = 3.4, halfZ = 1.8 },
	-- 3 corner cryo tank clusters (rotated 45 deg, 8.4 x 4.6)
	{ x = -62.5, z = -62.5, halfX = 4.6, halfZ = 4.6 },
	{ x = 62.5, z = -62.5, halfX = 4.6, halfZ = 4.6 },
	{ x = -62.5, z = 62.5, halfX = 4.6, halfZ = 4.6 },
	-- North & West supply crate clusters
	{ x = -54, z = -65.4, halfX = 2.9, halfZ = 2.6 },
	{ x = -48, z = -65.8, halfX = 2.3, halfZ = 2.2 },
	{ x = 52, z = -65.4, halfX = 3.2, halfZ = 2.7 },
	{ x = 45, z = -65.8, halfX = 2.4, halfZ = 2.3 },
	{ x = -65.5, z = -48, halfX = 2.4, halfZ = 2.8 },
	{ x = -65.5, z = 48, halfX = 2.6, halfZ = 3.0 },
	-- Coolant barrel clusters
	{ x = -41, z = -66.0, radius = 1.3 },
	{ x = -38.5, z = -65.8, radius = 1.3 },
	{ x = 39, z = -66.0, radius = 1.3 },
	{ x = 36.4, z = -65.6, radius = 1.3 },
	{ x = -66.0, z = -38, radius = 1.3 },
	{ x = -66.0, z = -35.4, radius = 1.3 },
	{ x = -65.8, z = 56.5, radius = 1.3 },
	{ x = -63.4, z = 58.6, radius = 1.3 },
	-- Control consoles flanking North Blast Door & West Observation Bay
	{ x = -18.5, z = -66.2, halfX = 2.85, halfZ = 1.3 },
	{ x = 18.5, z = -66.2, halfX = 2.85, halfZ = 1.3 },
	{ x = -66.2, z = -19.5, halfX = 1.3, halfZ = 2.85 },
	{ x = -66.2, z = 19.5, halfX = 1.3, halfZ = 2.85 },
	-- Server racks lining North & West walls
	{ x = -33, z = -67.2, halfX = 2.5, halfZ = 1.3 },
	{ x = 33, z = -67.2, halfX = 2.5, halfZ = 1.3 },
	{ x = -67.2, z = -31, halfX = 1.3, halfZ = 2.5 },
	{ x = -67.2, z = 31, halfX = 1.3, halfZ = 2.5 },
	-- Low foreground pallets along South & East curbs
	{ x = -28, z = 65.8, halfX = 2.9, halfZ = 2.2 },
	{ x = 28, z = 65.8, halfX = 2.9, halfZ = 2.2 },
	{ x = 65.8, z = -26, halfX = 2.2, halfZ = 2.9 },
	{ x = 65.8, z = 26, halfX = 2.2, halfZ = 2.9 },
	-- South & East perimeter bollards
	{ x = -42, z = 68.4, radius = 0.9 },
	{ x = -14, z = 68.4, radius = 0.9 },
	{ x = 14, z = 68.4, radius = 0.9 },
	{ x = 42, z = 68.4, radius = 0.9 },
	{ x = 68.4, z = -42, radius = 0.9 },
	{ x = 68.4, z = -14, radius = 0.9 },
	{ x = 68.4, z = 14, radius = 0.9 },
	{ x = 68.4, z = 42, radius = 0.9 },
}

-- Facility lighting applied on server start so Studio Play matches default.project.json even
-- if Rojo patched Lighting late (CLAUDE.md).
Config.LIGHTING_AMBIENT = Color3.fromRGB(70, 78, 92)
Config.LIGHTING_OUTDOOR_AMBIENT = Color3.fromRGB(85, 95, 115)
Config.LIGHTING_BRIGHTNESS = 1.8
Config.LIGHTING_CLOCK_TIME = 14.5

export type WaveTheme = {
	primary: Color3,
	secondary: Color3,
	ambient: Color3,
	outdoorAmbient: Color3,
	shiftTop: Color3,
}

-- Per-wave arena color themes smoothly tweened across neon accents, lights, and facility ambient
-- whenever `World.Wave` advances (`ArenaTheme.luau`).
Config.WAVE_THEME_TRANSITION_SECONDS = 1.05
Config.WAVE_THEMES = {
	-- Wave 1: Cold industrial cyan & amber (standard sector power)
	[1] = {
		primary = Color3.fromRGB(80, 215, 255),
		secondary = Color3.fromRGB(255, 168, 58),
		ambient = Color3.fromRGB(70, 78, 92),
		outdoorAmbient = Color3.fromRGB(85, 95, 115),
		shiftTop = Color3.fromRGB(205, 228, 255),
	},
	-- Wave 2: Bio-containment emerald & acid lime
	[2] = {
		primary = Color3.fromRGB(56, 232, 154),
		secondary = Color3.fromRGB(184, 255, 82),
		ambient = Color3.fromRGB(64, 88, 80),
		outdoorAmbient = Color3.fromRGB(78, 108, 96),
		shiftTop = Color3.fromRGB(190, 255, 220),
	},
	-- Wave 3: Thermal overload amber & furnace orange
	[3] = {
		primary = Color3.fromRGB(255, 176, 46),
		secondary = Color3.fromRGB(255, 104, 38),
		ambient = Color3.fromRGB(92, 76, 64),
		outdoorAmbient = Color3.fromRGB(115, 92, 74),
		shiftTop = Color3.fromRGB(255, 224, 185),
	},
	-- Wave 4: Coloso breach plasma violet & magenta
	[4] = {
		primary = Color3.fromRGB(181, 91, 255),
		secondary = Color3.fromRGB(255, 72, 184),
		ambient = Color3.fromRGB(82, 68, 98),
		outdoorAmbient = Color3.fromRGB(102, 82, 122),
		shiftTop = Color3.fromRGB(232, 198, 255),
	},
	-- Wave 5: Code Red crimson alarm & volcanic orange
	[5] = {
		primary = Color3.fromRGB(255, 56, 76),
		secondary = Color3.fromRGB(255, 124, 48),
		ambient = Color3.fromRGB(96, 62, 66),
		outdoorAmbient = Color3.fromRGB(118, 74, 78),
		shiftTop = Color3.fromRGB(255, 188, 188),
	},
	-- Wave 6: Boss "Oh" molten reactor crimson & incandescent gold
	[6] = {
		primary = Color3.fromRGB(255, 38, 38),
		secondary = Color3.fromRGB(255, 208, 74),
		ambient = Color3.fromRGB(104, 58, 52),
		outdoorAmbient = Color3.fromRGB(126, 72, 62),
		shiftTop = Color3.fromRGB(255, 195, 155),
	},
} :: { [number]: WaveTheme }

Config.CLEARED_THEME = {
	primary = Color3.fromRGB(68, 240, 152),
	secondary = Color3.fromRGB(124, 232, 255),
	ambient = Color3.fromRGB(72, 92, 88),
	outdoorAmbient = Color3.fromRGB(88, 114, 108),
	shiftTop = Color3.fromRGB(205, 255, 235),
} :: WaveTheme

return Config
