local Config = require(script.Parent.Config)

--[[
	Feature flags: the rule for deciding whether a flag is on, and the one name both realms read
	it under.

	This is the module that makes a second universe *enough*. A private dev experience proves a
	feature is correct; it can never prove it holds at forty players, on the real device mix,
	against real DataStore throughput. A flag is how the untested half ships anyway — dark, then
	staff-only, then a slice of players, then everyone — and how it goes off again in under a
	minute when it does not hold. See docs/environments.md#feature-flags.

	Pure: no service, no instance, no DataStore. The server feature that reads the overrides and
	writes the results is `server/features/flags/FlagService`.
]]

local Flags = {}

export type Spec = {
	default: any,
	staff: boolean?,
	rollout: number?,
}

export type Context = {
	environment: string,
	userId: number?,
	isStaff: boolean?,
	-- The live override for this flag, when one has been written. Anything that is not a
	-- boolean is "no override", which is also what a malformed DataStore value looks like.
	override: any,
}

--=============================================================================
-- Names
--=============================================================================

-- A flag reaches the client as an attribute on the player, so it is read there the way every
-- other piece of server-owned state is read — `hooks.useAttribute(player, Flags.attribute(...))`
-- in a component — and there is no remote, no reply and nothing to get out of sync.
function Flags.attribute(name: string): string
	return Config.FLAG_ATTRIBUTE_PREFIX .. name
end

-- Reads a resolved flag off a player. Works on either realm; the server is what writes it.
--
-- Compared against `true` rather than coerced, because the attribute is nil in the window
-- between a player joining and the server resolving their flags. "Not yet known" and "off" are
-- the same answer here on purpose: a feature that is not known to be on is off.
function Flags.on(player: Instance, name: string): boolean
	return player:GetAttribute(Flags.attribute(name)) == true
end

--=============================================================================
-- The rule
--=============================================================================

--[[
	Which slice of a rollout a player is in, 0..99.

	Stable across servers, sessions and republishes, because it is a hash of the id and nothing
	else: a player who is in the first 10% stays in it, so raising a rollout only ever adds
	people. A random draw per server would put the same player on both sides of the feature
	depending on which server they joined, which is how you get a bug report nobody can reproduce.

	The flag name is in the hash so two flags at 10% do not pick the *same* 10% of players — one
	unlucky cohort getting every experiment at once is both bad for them and useless as a signal.
]]
function Flags.bucket(name: string, userId: number): number
	-- djb2. No bit32: the multiply stays under 2^53 so it is exact in a double, which means the
	-- server, the client and the offline test all compute the same number.
	local text = `{name}:{userId}`
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 4294967296
	end
	return h % 100
end

--[[
	Whether one flag is on for one player.

	The order is override, staff, rollout, default, and the first two lines are the whole reason
	it is written down: **an override beats staff.** A kill switch that leaves the feature running
	for the people handling the incident is not a kill switch, and that is exactly the moment
	nobody wants to discover the precedence by reading the code.
]]
function Flags.resolve(name: string, spec: Spec, context: Context): boolean
	if type(context.override) == "boolean" then
		return context.override
	end

	if spec.staff and context.isStaff then
		return true
	end

	local rollout = spec.rollout or 0
	local userId = context.userId or 0
	if rollout > 0 and userId > 0 and Flags.bucket(name, userId) < rollout then
		return true
	end

	local default = spec.default
	if type(default) == "boolean" then
		return default
	end
	if type(default) == "table" then
		return default[context.environment] == true
	end
	return false
end

-- Every flag in the catalogue, resolved for one context. `overrides` is the table as it came out
-- of the DataStore — a flag it does not mention is simply not overridden, and a flag it mentions
-- that no longer exists is ignored rather than invented.
function Flags.all(context: Context, overrides: { [string]: any }?): { [string]: boolean }
	local out = {}
	for name, spec in pairs(Config.FLAGS) do
		local scoped: Context = {
			environment = context.environment,
			userId = context.userId,
			isStaff = context.isStaff,
			override = overrides and overrides[name],
		}
		out[name] = Flags.resolve(name, spec, scoped)
	end
	return out
end

--=============================================================================
-- Self test
--=============================================================================

local function spec(fields: any): Spec
	return fields
end

function Flags.selfTest()
	local ENV = "development"
	local OTHER = "production"

	--- Names ---------------------------------------------------------------
	-- A flag name becomes an attribute name, and SetAttribute throws on anything outside
	-- [A-Za-z0-9_]. Caught here rather than on the first player to join a real server.
	for name, entry in pairs(Config.FLAGS) do
		assert(
			name:match("^[A-Z][A-Z0-9_]*$") ~= nil,
			`flag "{name}" is not [A-Z][A-Z0-9_]* — it cannot be an attribute name`
		)
		assert(
			type(entry.default) == "boolean" or type(entry.default) == "table",
			`flag "{name}" has no usable default`
		)
		local rollout = entry.rollout or 0
		assert(rollout >= 0 and rollout <= 100, `flag "{name}" has a rollout outside 0..100`)
	end

	--- Precedence ----------------------------------------------------------
	local everything = spec({ default = { [ENV] = true }, staff = true, rollout = 100 })

	assert(
		Flags.resolve("X", everything, { environment = ENV, userId = 1, isStaff = true, override = false }) == false,
		"an override must beat staff, the rollout and the default — otherwise it is not a kill switch"
	)
	assert(
		Flags.resolve("X", spec({ default = false }), { environment = ENV, userId = 1, override = true }) == true,
		"an override turns a flag on as well as off"
	)
	assert(
		Flags.resolve(
			"X",
			spec({ default = false, staff = true }),
			{ environment = ENV, userId = 1, isStaff = true, override = nil }
		) == true,
		"staff beats the default"
	)
	assert(
		Flags.resolve("X", spec({ default = false, staff = true }), { environment = ENV, userId = 1, isStaff = false })
			== false,
		"staff is not everyone"
	)
	assert(
		Flags.resolve("X", spec({ default = false, staff = false }), { environment = ENV, userId = 1, isStaff = true })
			== false,
		"a flag that is not staff-enabled stays off for staff"
	)

	--- Overrides that are not booleans -------------------------------------
	-- The overrides table comes back from a DataStore, where a fat-fingered edit is a string.
	-- Anything that is not a boolean has to mean "not overridden", or one bad key takes the
	-- whole catalogue with it.
	for _, junk in ipairs({ "true", 1, {}, "" } :: { any }) do
		assert(
			Flags.resolve("X", spec({ default = true }), { environment = ENV, userId = 1, override = junk }) == true,
			"a non-boolean override must be ignored, not treated as false"
		)
	end

	--- Environment defaults ------------------------------------------------
	local perEnv = spec({ default = { [ENV] = true, [OTHER] = false } })
	assert(Flags.resolve("X", perEnv, { environment = ENV, userId = 1 }) == true)
	assert(Flags.resolve("X", perEnv, { environment = OTHER, userId = 1 }) == false)
	assert(
		Flags.resolve("X", perEnv, { environment = "qa", userId = 1 }) == false,
		"an environment the flag says nothing about is off — a new environment must not inherit a feature by accident"
	)

	--- Rollout -------------------------------------------------------------
	local tenth = spec({ default = false, rollout = 10 })
	assert(Flags.resolve("X", tenth, { environment = ENV, userId = 0 }) == false, "a rollout needs a real user id")
	assert(
		Flags.resolve("X", spec({ default = false, rollout = 100 }), { environment = ENV, userId = 7 }) == true,
		"100% is everybody"
	)
	assert(
		Flags.resolve("X", spec({ default = false, rollout = 0 }), { environment = ENV, userId = 7 }) == false,
		"0% is nobody"
	)

	--- The hash ------------------------------------------------------------
	assert(
		Flags.bucket("X", 12345) == Flags.bucket("X", 12345),
		"the bucket must be stable, or a player flickers in and out of a feature"
	)
	for _, id in ipairs({ 1, 2, 999, 1234567, 4294967295 }) do
		local b = Flags.bucket("X", id)
		assert(b >= 0 and b < 100 and b % 1 == 0, `bucket for {id} is {b}, outside 0..99`)
	end

	-- Two flags at the same percentage must not pick the same players, or one cohort gets every
	-- experiment at once and none of the results mean anything.
	local sameAsX = 0
	for id = 1, 400 do
		if Flags.bucket("X", id) == Flags.bucket("Y", id) then
			sameAsX += 1
		end
	end
	assert(sameAsX < 40, `two flag names bucket {sameAsX}/400 ids identically — the name is not reaching the hash`)

	-- Roughly even, over ids shaped like real ones (sequential, and large). Loose on purpose:
	-- this is asserting "not obviously lumpy", not a statistical property.
	local SAMPLE = 2000
	local deciles = table.create(10, 0)
	for i = 1, SAMPLE do
		local decile = Flags.bucket("ROLLOUT", 1_000_000 + i * 7) // 10
		deciles[decile + 1] += 1
	end
	for i, count in ipairs(deciles) do
		assert(
			count > SAMPLE * 0.05 and count < SAMPLE * 0.2,
			`decile {i - 1} holds {count} of {SAMPLE} ids — the rollout hash is not spreading players evenly`
		)
	end

	--- The catalogue -------------------------------------------------------
	local resolved = Flags.all({ environment = ENV, userId = 1 }, { EXAMPLE_TOAST = false })
	for name in pairs(Config.FLAGS) do
		assert(type(resolved[name]) == "boolean", `Flags.all left "{name}" unresolved`)
	end
	assert(resolved.NOT_A_FLAG == nil, "Flags.all must not invent a flag an override mentions")
end

return Flags
