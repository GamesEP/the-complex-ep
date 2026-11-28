-- Which universe is which, and what each one is allowed to do.
--
-- Roblox has no staging slot, so an environment here *is* a universe: DataStores, badges,
-- passes, products and analytics are all scoped to one, and nothing else on the platform
-- isolates them. See docs/environments.md.
local Config = {}

-- The three the template ships with. A game that wants a fourth (a soak universe, a per-team
-- sandbox) adds its name here and a row in ENV_IDS; nothing else knows the list is fixed.
Config.ENV_PRODUCTION = "production"
Config.ENV_DEVELOPMENT = "development"
Config.ENV_STUDIO = "studio"

--[[
	`game.GameId` -> environment name. The universe id, **not** the place id: a universe can hold
	several places and they all share its data, so the place is the wrong thing to key on.

	Find it on the experience's Creator Hub page, or print `game.GameId` from a published server.
]]
Config.ENV_UNIVERSES = {
	-- [1234567890] = Config.ENV_PRODUCTION,
	[10779446885] = Config.ENV_DEVELOPMENT,
} :: { [number]: string }

--[[
	What a published universe that is not in the table above is treated as.

	**Production, deliberately, and `Environment.selfTest` fails if this is changed to anything
	else.** The fallback is what a fresh clone runs under, and the two directions are not
	symmetric: guessing "development" hands everyone admin and dev-only cheats in a universe
	nobody registered — including the real production universe before somebody fills the table
	in. Guessing "production" costs a wrong monetization id, which fails loudly and harms nobody.

	An unrecognised universe is still a configuration error, so `Environment` reports one fault
	the first time it resolves. It shows up in `make logs` rather than in nothing at all.
]]
Config.ENV_DEFAULT = Config.ENV_PRODUCTION

--[[
	The ids that differ per universe, because Roblox scopes them per universe: game passes,
	developer products, badges. A place published to two universes is the same source with two
	sets of these, which is why they cannot be a plain number next to the code that spends them.

	Read through `Environment.id("KEY")`, which answers 0 for anything absent — the same "not
	uploaded yet" convention `Assets.id` uses, so a fresh clone is inert rather than broken.

	Studio has no row: purchases in Studio are simulated and free, so it borrows development's.
]]
Config.ENV_IDS = {
	[Config.ENV_PRODUCTION] = {
		-- GAMEPASS_VIP = 0,
		-- PRODUCT_1000_COINS = 0,
		-- BADGE_FIRST_WIN = 0,
	},
	[Config.ENV_DEVELOPMENT] = {
		-- GAMEPASS_VIP = 0,
	},
} :: { [string]: { [string]: number } }

-- Which environment Studio borrows its ids from. Studio is not a universe — it runs against
-- whatever place file is open — so it has no id table of its own.
Config.ENV_STUDIO_BORROWS = Config.ENV_DEVELOPMENT

return Config
