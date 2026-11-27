-- Single-floor Vertical Slice run loop (plans/gdd/loop.md, plans/roadmap.md VS-10..VS-14).
-- Five authored rooms on Floor 1 ending with Boss "Oh" in Room 5; clearing Rooms 1..4 opens the
-- North Blast Door so the player steps through manually into the next room.
local Config = {}

Config.ROOMS_PER_FLOOR = 5
-- Vertical Slice ships 1 complete floor (5 rooms + Boss Oh). Phase 2 expands this to 5 floors.
Config.FLOORS_PER_RUN = 1

-- North Blast Door doorway trigger zone (arena-local coordinates in ComplexArena.rbxmx).
Config.BLAST_DOOR_TRIGGER_Z = -60
Config.BLAST_DOOR_TRIGGER_HALF_X = 12
Config.BLAST_DOOR_SLIDE_DISTANCE = 8.4
Config.BLAST_DOOR_ANIM_SECONDS = 0.7

-- Authored 5-room progression for Floor 1 (Vertical Slice). Each room holds 1..2 waves; non-boss
-- enemy counts scale with the active Difficulty tier (`Config.DIFFICULTIES`).
Config.FLOOR_ROOMS = {
	-- Room 1: Warm-up corridor — melee Centinelas then crossfire Cazadores.
	{
		name = "ACCESO NORTE",
		waves = {
			{ melee = 3 },
			{ melee = 3, ranged = 2 },
		},
	},
	-- Room 2: Crossfire, Detonantes & Artillero/Voltaico intro.
	{
		name = "PLANTA DE REFRIGERACIÓN",
		waves = {
			{ melee = 2, ranged = 2, exploder = 1, area = 1 },
			{ melee = 3, ranged = 2, contact = 1, area = 1 },
		},
	},
	-- Room 3: Heavy breach — introduces the Coloso alongside Voltaico & Artillero pressure.
	{
		name = "BAHÍA DE CONTENCIÓN",
		waves = {
			{ melee = 3, ranged = 2, exploder = 1, contact = 2 },
			{ melee = 2, ranged = 2, area = 1, grabber = 1 },
		},
	},
	-- Room 4: Pre-boss gauntlet — all 6 enemy archetypes active together before Oh's chamber.
	{
		name = "ANTESALA DEL NÚCLEO",
		waves = {
			{ melee = 3, ranged = 2, exploder = 1, area = 2, contact = 1, grabber = 1 },
			{ melee = 3, ranged = 2, exploder = 1, area = 1, contact = 2, grabber = 1 },
		},
	},
	-- Room 5: Floor Boss — Oh (first part of OhMyGon).
	{
		name = "CÁMARA DE OH",
		isBossRoom = true,
		waves = {
			{ bossOh = 1 },
		},
	},
} :: { { name: string, isBossRoom: boolean?, waves: { { [string]: number } } } }

return Config
