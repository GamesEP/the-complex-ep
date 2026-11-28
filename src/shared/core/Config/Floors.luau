-- Five-floor randomized room encounter pools for the Horizontal Slice (plans/gdd/content.md,
-- plans/roadmap.md HS-12). Floor 1 is a 5-room warm-up with no boss; Floors 2..5 draw 4 random
-- rooms from their floor pool (zero back-to-back repeats) and lock Room 5 to Oh, My, Gon, and
-- 2-phase OhMyGon respectively.
local Config = {}

export type RoomPoolEntry = {
	id: string,
	name: string,
	arena: string,
	isBossRoom: boolean?,
	bossKind: string?,
	waves: { { [string]: number } },
}

export type FloorDef = {
	floor: number,
	name: string,
	pool: { RoomPoolEntry },
	bossRoom: RoomPoolEntry?,
}

Config.MAX_ACTIVE_ENEMIES = 25

Config.FLOORS = {
	-- Floor 1: Warm-up intake sector (5 normal rooms, no boss). Introduces all 6 archetypes gradually.
	[1] = {
		floor = 1,
		name = "SECTOR DE INGRESO",
		pool = {
			{
				id = "f1_intake",
				name = "ACCESO NORTE",
				arena = "ComplexArena",
				waves = {
					{ melee = 3 },
					{ melee = 3, ranged = 2 },
				},
			},
			{
				id = "f1_coolant",
				name = "PLANTA DE REFRIGERACIÓN",
				arena = "ComplexArenaCross",
				waves = {
					{ melee = 2, ranged = 2, exploder = 1 },
					{ melee = 3, ranged = 2, area = 1 },
				},
			},
			{
				id = "f1_conduit",
				name = "GALERÍA DE CONDUCTOS",
				arena = "ComplexArenaCorridor",
				waves = {
					{ melee = 3, ranged = 2 },
					{ melee = 2, ranged = 2, contact = 1 },
				},
			},
			{
				id = "f1_turbine",
				name = "SALA DE TURBINAS",
				arena = "ComplexArenaReactor",
				waves = {
					{ melee = 3, exploder = 2 },
					{ melee = 2, ranged = 2, area = 1, contact = 1 },
				},
			},
			{
				id = "f1_staging",
				name = "BAHÍA DE CARGA",
				arena = "ComplexArena",
				waves = {
					{ melee = 3, ranged = 2, exploder = 1 },
					{ melee = 3, ranged = 2, area = 1, contact = 1 },
				},
			},
			{
				id = "f1_relay",
				name = "NODO DE ENLACE",
				arena = "ComplexArenaCross",
				waves = {
					{ melee = 2, ranged = 3, contact = 1 },
					{ melee = 3, ranged = 2, exploder = 2, area = 1 },
				},
			},
		},
	},
	-- Floor 2: Foundry sector — introduces Coloso pressure and ends with Boss Oh in Room 5.
	[2] = {
		floor = 2,
		name = "FUNDICIÓN DE OH",
		pool = {
			{
				id = "f2_smelter",
				name = "HORNOS DE FUNDICIÓN",
				arena = "ComplexArenaReactor",
				waves = {
					{ melee = 3, ranged = 2, area = 1, exploder = 1 },
					{ melee = 3, ranged = 2, grabber = 1, contact = 1 },
				},
			},
			{
				id = "f2_press",
				name = "PRENSA HIDRÁULICA",
				arena = "ComplexArenaCorridor",
				waves = {
					{ melee = 4, ranged = 2, contact = 1 },
					{ melee = 3, ranged = 2, area = 2, grabber = 1 },
				},
			},
			{
				id = "f2_forge",
				name = "CRISOL INDUSTRIAL",
				arena = "ComplexArena",
				waves = {
					{ melee = 3, ranged = 3, exploder = 2 },
					{ melee = 3, ranged = 2, area = 1, contact = 2, grabber = 1 },
				},
			},
			{
				id = "f2_slag",
				name = "DESCARGA TÉRMICA",
				arena = "ComplexArenaCross",
				waves = {
					{ melee = 3, area = 2, contact = 1, exploder = 1 },
					{ melee = 4, ranged = 2, exploder = 1, grabber = 1 },
				},
			},
			{
				id = "f2_anvil",
				name = "ANTESALA DE OH",
				arena = "ComplexArena",
				waves = {
					{ melee = 3, ranged = 2, exploder = 1, area = 1, contact = 1, grabber = 1 },
					{ melee = 4, ranged = 2, area = 1, contact = 2, grabber = 1 },
				},
			},
		},
		bossRoom = {
			id = "f2_boss_oh",
			name = "CÁMARA DE OH",
			arena = "ComplexArenaVault",
			isBossRoom = true,
			bossKind = "bossOh",
			waves = {
				{ bossOh = 1 },
			},
		},
	},
	-- Floor 3: High-speed Cryo-Volt sector — agile Voltaicos & Cazadores ending with Boss My.
	[3] = {
		floor = 3,
		name = "SECTOR CRIO-VOLT",
		pool = {
			{
				id = "f3_coil",
				name = "BOBINAS DE ARCO",
				arena = "ComplexArenaCross",
				waves = {
					{ melee = 3, ranged = 3, contact = 2 },
					{ melee = 3, ranged = 3, contact = 2, area = 1 },
				},
			},
			{
				id = "f3_cryo",
				name = "DEPÓSITO CRIOGÉNICO",
				arena = "ComplexArenaCorridor",
				waves = {
					{ melee = 4, ranged = 3, exploder = 2 },
					{ melee = 3, ranged = 3, contact = 2, grabber = 1 },
				},
			},
			{
				id = "f3_capacitor",
				name = "CONDENSADOR CENTRAL",
				arena = "ComplexArenaReactor",
				waves = {
					{ melee = 3, area = 2, contact = 2, exploder = 1 },
					{ melee = 4, ranged = 3, area = 1, contact = 2, grabber = 1 },
				},
			},
			{
				id = "f3_switchyard",
				name = "SUBESTACIÓN VOLT",
				arena = "ComplexArena",
				waves = {
					{ melee = 4, ranged = 2, contact = 2, exploder = 2 },
					{ melee = 3, ranged = 3, area = 2, contact = 2, grabber = 1 },
				},
			},
			{
				id = "f3_prism",
				name = "CORREDOR FOTÓNICO",
				arena = "ComplexArenaCross",
				waves = {
					{ melee = 3, ranged = 4, contact = 2 },
					{ melee = 4, ranged = 3, exploder = 2, area = 1, grabber = 1 },
				},
			},
		},
		bossRoom = {
			id = "f3_boss_my",
			name = "CÁMARA DE MY",
			arena = "ComplexArenaCross",
			isBossRoom = true,
			bossKind = "bossMy",
			waves = {
				{ bossMy = 1 },
			},
		},
	},
	-- Floor 4: Bio-Containment sector — Artilleros, Colosos & area denial ending with Boss Gon.
	[4] = {
		floor = 4,
		name = "CONTENCIÓN BIO-TÉRMICA",
		pool = {
			{
				id = "f4_vat",
				name = "TANQUES DE CONTENCIÓN",
				arena = "ComplexArenaReactor",
				waves = {
					{ melee = 4, ranged = 2, area = 2, exploder = 2 },
					{ melee = 3, ranged = 3, area = 2, contact = 2, grabber = 1 },
				},
			},
			{
				id = "f4_silo",
				name = "SILO DE PRESIÓN",
				arena = "ComplexArena",
				waves = {
					{ melee = 4, area = 2, contact = 2, grabber = 1 },
					{ melee = 4, ranged = 3, area = 2, exploder = 2, grabber = 2 },
				},
			},
			{
				id = "f4_quarantine",
				name = "ALA DE CUARENTENA",
				arena = "ComplexArenaCorridor",
				waves = {
					{ melee = 4, ranged = 3, area = 2, contact = 1 },
					{ melee = 4, ranged = 3, exploder = 2, area = 2, grabber = 1 },
				},
			},
			{
				id = "f4_purge",
				name = "CÁMARA DE PURGA",
				arena = "ComplexArenaCross",
				waves = {
					{ melee = 3, ranged = 3, exploder = 2, area = 2, contact = 2 },
					{ melee = 4, ranged = 2, area = 2, contact = 2, grabber = 2 },
				},
			},
			{
				id = "f4_lock",
				name = "ESCLUSA DE GON",
				arena = "ComplexArenaVault",
				waves = {
					{ melee = 4, ranged = 3, area = 2, contact = 2, grabber = 1 },
					{ melee = 4, ranged = 3, exploder = 2, area = 2, contact = 2, grabber = 2 },
				},
			},
		},
		bossRoom = {
			id = "f4_boss_gon",
			name = "CÁMARA DE GON",
			arena = "ComplexArenaReactor",
			isBossRoom = true,
			bossKind = "bossGon",
			waves = {
				{ bossGon = 1 },
			},
		},
	},
	-- Floor 5: Final Complex Core — full-roster gauntlets ending with 2-phase OhMyGon in Room 5.
	[5] = {
		floor = 5,
		name = "NÚCLEO DEL COMPLEJO",
		pool = {
			{
				id = "f5_breach",
				name = "BRECHA DEL NÚCLEO",
				arena = "ComplexArena",
				waves = {
					{ melee = 4, ranged = 3, area = 2, contact = 2, grabber = 1 },
					{ melee = 4, ranged = 3, exploder = 2, area = 2, contact = 2, grabber = 2 },
				},
			},
			{
				id = "f5_nexus",
				name = "NEXO DE ENERGÍA",
				arena = "ComplexArenaCross",
				waves = {
					{ melee = 4, ranged = 4, contact = 2, area = 2 },
					{ melee = 4, ranged = 3, exploder = 2, area = 2, contact = 2, grabber = 2 },
				},
			},
			{
				id = "f5_gauntlet",
				name = "PASILLO DE FUSIÓN",
				arena = "ComplexArenaCorridor",
				waves = {
					{ melee = 5, ranged = 3, exploder = 2, contact = 2 },
					{ melee = 4, ranged = 3, area = 2, contact = 2, grabber = 2 },
				},
			},
			{
				id = "f5_overdrive",
				name = "REACTOR CRÍTICO",
				arena = "ComplexArenaReactor",
				waves = {
					{ melee = 4, ranged = 3, exploder = 2, area = 2, grabber = 2 },
					{ melee = 4, ranged = 4, exploder = 2, area = 2, contact = 2, grabber = 1 },
				},
			},
			{
				id = "f5_sanctum",
				name = "UMBRAL DE OHMYGON",
				arena = "ComplexArenaVault",
				waves = {
					{ melee = 4, ranged = 3, exploder = 2, area = 2, contact = 2, grabber = 2 },
					{ melee = 5, ranged = 3, exploder = 2, area = 2, contact = 2, grabber = 2 },
				},
			},
		},
		bossRoom = {
			id = "f5_boss_ohmygon",
			name = "NÚCLEO OHMYGON",
			arena = "ComplexArenaVault",
			isBossRoom = true,
			bossKind = "bossOhMyGon",
			waves = {
				{ bossOhMyGon = 1 },
			},
		},
	},
} :: { [number]: FloorDef }

return Config
