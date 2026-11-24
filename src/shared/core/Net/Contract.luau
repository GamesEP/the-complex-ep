local Config = require(script.Parent.Parent.Config)
local Validate = require(script.Parent.Validate)

--[[
	One declaration per client->server remote: how often it may fire, who may fire it, in which
	phase, and what shape its arguments take. **The Dispatcher refuses to connect a remote that
	has no entry here**, which is what makes forgetting a rate limit impossible rather than merely
	unlikely.

	  rate    calls per second, or "custom" when the handler meters itself
	  role    the only role the remote means anything from
	  phase   "playing" or "inRound"
	  admin   Studio, or a user id in Config.ADMIN_USER_IDS
	  args    positional shape guards from Validate

	`args` is a shape check and nothing more — what a value *means* is the handler's, because the
	handler is the only thing that knows. See docs/net-contract.md.
]]

return {
	-- The player's kit. Metered at the shared action rate, which no human pressing a button can
	-- beat; the *game* cooldowns (attack interval, dash, spin) are the handlers' — the contract
	-- only stops a script flooding the channel. The aim is shape-checked here and normalised in
	-- CombatService, because only the handler knows what a direction means.
	Attack = { rate = Config.ACTION_RATE, args = { Validate.vector3 } },
	Dash = { rate = Config.ACTION_RATE },
	Spin = { rate = Config.ACTION_RATE },

	-- A client saying what broke on it. Metered hard and shape-checked twice — once here as a
	-- table, once field by field in LogSink — because unlike every other remote in this file it
	-- ends up in persistent storage, and a channel a client can write to a DataStore through is
	-- one an exploiter will try to fill.
	Diagnostic = { rate = Config.DIAG_CLIENT_RATE, args = { Validate.table } },
}
