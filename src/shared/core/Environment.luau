local Config = require(script.Parent.Config)

--[[
	Which universe this code is running in, and the ids that differ between them.

	Roblox scopes DataStores, passes, products, badges and analytics to a *universe*, and gives
	you nothing smaller — so "development" and "production" are two universes publishing the same
	source, and anything universe-shaped has to be looked up rather than written down. See
	docs/environments.md.

	**Resolved from `game.GameId` at runtime, never baked in at build time.** The same commit is
	published to both places by merging up, so a constant written by the build would be right in
	one of them and quietly wrong in the other — and `git diff main..staging` would show config
	drift on top of the work that has not shipped yet. One artifact, one lookup.
]]

local Environment = {}

Environment.PRODUCTION = Config.ENV_PRODUCTION
Environment.DEVELOPMENT = Config.ENV_DEVELOPMENT
Environment.STUDIO = Config.ENV_STUDIO

export type Name = string

--=============================================================================
-- The rule
--=============================================================================

--[[
	Pure: which environment a universe is, and whether anybody said so.

	Studio wins over the table because Studio is not a universe — it runs against whatever place
	file is open, which may be a scratch build of production — and there is no security boundary
	to hold there anyway: somebody with the place open already has everything.

	The second return is `false` for a published universe nobody registered. That is a
	configuration error rather than a state, and the caller is what turns it into a report.
]]
function Environment.match(gameId: number, isStudio: boolean): (Name, boolean)
	if isStudio then
		return Config.ENV_STUDIO, true
	end
	local named = Config.ENV_UNIVERSES[gameId]
	if named then
		return named, true
	end
	return Config.ENV_DEFAULT, false
end

--=============================================================================
-- This session
--=============================================================================

-- Resolved on first use rather than at require time: a Config part is plain data and this module
-- is required by both realms during boot, so reaching for a service at the top would be one more
-- thing that has to exist before the first `require` — and would put a `game` lookup in the way
-- of loading it offline, where `Environment.match` is asserted.
local resolved: Name? = nil
local recognised = true

local function resolve(): Name
	if resolved then
		return resolved
	end
	local RunService = game:GetService("RunService")
	local name, known = Environment.match(game.GameId, RunService:IsStudio())
	resolved, recognised = name, known
	return name
end

function Environment.name(): Name
	return resolve()
end

-- False when this universe is not in `Config.ENV_UNIVERSES` and fell back to `ENV_DEFAULT`.
-- Something should say so out loud once — the server bootstrap does.
function Environment.isRegistered(): boolean
	resolve()
	return recognised
end

function Environment.is(name: Name): boolean
	return resolve() == name
end

-- The guard for anything dangerous. Written as "is this production" rather than "is this
-- development" so a fourth environment nobody thought about is locked down by default.
function Environment.isProduction(): boolean
	return resolve() == Config.ENV_PRODUCTION
end

function Environment.isStudio(): boolean
	return resolve() == Config.ENV_STUDIO
end

--[[
	A universe-scoped id — a pass, a product, a badge — by the key it is filed under in
	`Config.ENV_IDS`.

	Answers 0 for anything absent, the same "not set up yet" convention `Assets.id` uses: a fresh
	clone of the template has no monetization and should be playable rather than broken. A caller
	that spends one checks for 0 the way it checks an asset id.
]]
function Environment.id(key: string): number
	local name = resolve()
	if name == Config.ENV_STUDIO then
		name = Config.ENV_STUDIO_BORROWS
	end
	local ids = Config.ENV_IDS[name]
	if not ids then
		return 0
	end
	return ids[key] or 0
end

--=============================================================================
-- Self test
--=============================================================================

function Environment.selfTest()
	local STUDIO, PROD = Config.ENV_STUDIO, Config.ENV_PRODUCTION

	-- Studio is Studio whatever universe the open place belongs to. A scratch build of the
	-- production place must not put a developer in the production environment.
	local name, known = Environment.match(0, true)
	assert(name == STUDIO, "Studio must resolve to the studio environment")
	assert(known, "Studio is always recognised — there is no table to be missing from")
	name = Environment.match(123456789, true)
	assert(name == STUDIO, "Studio wins over a registered universe id")

	-- The load-bearing default. Flipping ENV_DEFAULT to a development-shaped environment hands
	-- admin and every dev-only guard to whichever universe nobody has registered yet — which,
	-- for a freshly cloned template with an empty table, is production.
	assert(
		Config.ENV_DEFAULT == PROD,
		"ENV_DEFAULT must be the locked-down environment: an unregistered universe is the one "
			.. "you have not thought about, and it must not be the one with the cheats on"
	)

	name, known = Environment.match(1, false)
	if Config.ENV_UNIVERSES[1] == nil then
		assert(name == Config.ENV_DEFAULT, "an unregistered universe falls back to ENV_DEFAULT")
		assert(not known, "an unregistered universe reports itself as unrecognised")
	end

	-- Every registered universe resolves to itself, and to a name that has an id table. A
	-- universe pointing at an environment with no ids is a `Environment.id` that silently
	-- answers 0 for every key in that whole universe.
	local seen: { [number]: boolean } = {}
	for gameId, envName in pairs(Config.ENV_UNIVERSES) do
		assert(
			type(gameId) == "number" and gameId > 0 and gameId % 1 == 0,
			`ENV_UNIVERSES key {gameId} is not a universe id`
		)
		assert(not seen[gameId], `universe {gameId} is registered twice`)
		seen[gameId] = true
		assert(envName ~= STUDIO, `universe {gameId} is registered as "{STUDIO}", which is not a universe`)
		assert(Config.ENV_IDS[envName] ~= nil, `environment "{envName}" has no row in ENV_IDS`)
		local got, ok = Environment.match(gameId, false)
		assert(got == envName and ok, `universe {gameId} does not resolve to {envName}`)
	end

	-- Studio borrows an environment that exists, or `Environment.id` is 0 for everything in the
	-- one place a developer is most likely to be testing a purchase flow.
	assert(
		Config.ENV_IDS[Config.ENV_STUDIO_BORROWS] ~= nil,
		`ENV_STUDIO_BORROWS names "{Config.ENV_STUDIO_BORROWS}", which has no row in ENV_IDS`
	)

	-- Every id is a number. A string id is the one that survives every offline check and then
	-- fails inside MarketplaceService in front of a player.
	for envName, ids in pairs(Config.ENV_IDS) do
		for key, value in pairs(ids) do
			assert(type(value) == "number", `ENV_IDS.{envName}.{key} is not a number`)
		end
	end
end

return Environment
