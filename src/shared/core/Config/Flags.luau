-- Feature flags: what can be turned on, for whom, and how the server finds out.
--
-- A flag exists so code can ship to production dark and be switched on without a republish —
-- and, more importantly, switched *off* without one. See docs/environments.md#feature-flags.

-- A part names a sibling part to read its values: every part builds its own local table, so
-- `Config.ENV_PRODUCTION` is not in scope here — `init.luau` is what merges them into one.

local Config = {}

-- Overrides live in their own DataStore, like the diagnostics buffer, so a flag write can never
-- touch a profile. One key holding one flat table: the whole set is small, it is read far more
-- often than it is written, and a single key means a server's view of the flags is never half
-- of one edit and half of another.
Config.FLAG_STORE = "Flags"
Config.FLAG_KEY = "overrides"

-- How long a running server takes to notice an override. This is the number that decides how
-- fast a kill switch is: at 60s a bad feature is off everywhere inside a minute without a
-- republish, which is the whole point. Lower costs a DataStore read per server per interval.
Config.FLAG_REFRESH_SECONDS = 60

-- Resolved per player and written as an attribute, so the client reads flags the same way it
-- reads every other piece of server-owned state and no remote is involved.
Config.FLAG_ATTRIBUTE_PREFIX = "Flag_"

--[[
	The catalogue. Every flag the game has, with what it does when nobody has overridden it.

	  default   per environment, or a plain boolean for "the same everywhere"
	  staff     true = on for Config.ADMIN_USER_IDS regardless of default
	  rollout   percent of everybody else, 0..100, bucketed by a stable hash of the user id

	Resolution order is override, staff, rollout, default — and the override wins over staff on
	purpose, because a kill switch that leaves the feature on for the people running the
	incident is not a kill switch. `Flags.selfTest` asserts that order.

	A flag name is an attribute name, so it is `[A-Z][A-Z0-9_]*` and the self test says so.

	**Delete a flag once the feature is on everywhere.** A flag that has been true in production
	for a month is a branch in the code that nothing exercises the other side of.
]]
--
-- The shape of an entry, for the first real one (with `local Environments =
-- require(script.Parent.Environments)` back at the top):
--
--   SOME_FEATURE = {
--   	default = { [Environments.ENV_PRODUCTION] = false, [Environments.ENV_STUDIO] = true },
--   	staff = true,
--   	rollout = 0,
--   },
Config.FLAGS = {} :: { [string]: { default: any, staff: boolean?, rollout: number? } }

return Config
