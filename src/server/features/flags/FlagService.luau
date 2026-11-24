local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Environment = require(Shared.core.Environment)
local Flags = require(Shared.core.Flags)

--[[
	The live half of the feature flags: reads the overrides, resolves every flag per player, and
	writes the answers where both realms can see them.

	The rule itself is `shared/core/Flags` and is pure — this is the part that needs a DataStore
	and a player list, which is exactly why the two are separate files. See
	docs/environments.md#feature-flags.

	**Resolved per player, published as an attribute.** Attributes replicate on their own, reach
	every client rather than the one that asked, and cannot get out of sync the way a reply to a
	"what are my flags" remote can — so there is no remote here and nothing in the contract.
]]

local FlagService = {}

type Dependencies = {
	-- Whether a player is staff, for flags with `staff = true`. The server bootstrap passes the
	-- same function the Dispatcher uses, so "admin" means one thing in the whole game.
	isStaff: (Player) -> boolean,
	-- LogSink.record, taken as an argument rather than required by path: a feature that names
	-- another feature is half of a cycle that only gets more expensive to undo.
	record: ((area: string, code: string, detail: string, fields: { [string]: any }?) -> ())?,
}

local deps: Dependencies = {
	isStaff = function()
		return false
	end,
}

-- The overrides as they were last read. Starts empty rather than nil: a server whose first read
-- has not landed yet runs on the catalogue's defaults, which is the same thing it does when
-- nobody has overridden anything.
local overrides: { [string]: any } = {}
local loaded = false
local reads, failures = 0, 0

-- Studio without API access cannot open a DataStore at all, the same as the diagnostics sink.
-- A developer without it still gets a playable game on the defaults.
local store = nil
do
	local ok, opened = pcall(function()
		return DataStoreService:GetDataStore(Config.FLAG_STORE)
	end)
	store = if ok then opened else nil
end

local function context(player: Player?): Flags.Context
	return {
		environment = Environment.name(),
		userId = if player then player.UserId else 0,
		isStaff = if player then deps.isStaff(player) else false,
		override = nil,
	}
end

--=============================================================================
-- Reading
--=============================================================================

--[[
	Whether a flag is on, right now, for this player.

	Resolved from the catalogue and the overrides rather than read back off the attribute, so
	server code never depends on whether the attribute write has landed yet — the attribute is
	how the *client* finds out, not how the server remembers.

	`player` is optional for a decision that is not about anybody in particular. A flag read that
	way must not use `staff` or `rollout`, because there is no user id to bucket: it would simply
	be off for everyone, which is a confusing way to find out.
]]
function FlagService.enabled(name: string, player: Player?): boolean
	local spec = Config.FLAGS[name]
	if not spec then
		return false
	end
	local scoped = context(player)
	scoped.override = overrides[name]
	return Flags.resolve(name, spec, scoped)
end

-- What the service is doing, for anyone deciding whether the silence means "no overrides" or
-- "nothing is being read".
function FlagService.stats(): { [string]: any }
	local names = {}
	for name, value in pairs(overrides) do
		table.insert(names, `{name}={tostring(value)}`)
	end
	table.sort(names)
	return {
		store = store ~= nil,
		loaded = loaded,
		reads = reads,
		failures = failures,
		overrides = table.concat(names, " "),
	}
end

--=============================================================================
-- Publishing
--=============================================================================

local function apply(player: Player)
	local resolved = Flags.all(context(player), overrides)
	for name, value in pairs(resolved) do
		player:SetAttribute(Flags.attribute(name), value)
	end
end

local function applyAll()
	for _, player in ipairs(Players:GetPlayers()) do
		apply(player)
	end
end

--[[
	Pulls the overrides and re-publishes every player's flags.

	Re-publishing *all* of them, not just new joiners, is the whole point: this is what turns an
	edit in the DataStore into a feature going off in every live server inside
	`FLAG_REFRESH_SECONDS`, without a republish and without anybody being kicked.

	A failed read keeps the last good table rather than falling back to the defaults. A
	DataStore blip must not quietly re-enable the thing somebody just turned off.
]]
function FlagService.refresh()
	if not store then
		return
	end

	local ok, result = pcall(function()
		return store:GetAsync(Config.FLAG_KEY)
	end)

	if not ok then
		failures += 1
		if deps.record then
			deps.record("flags", "read-failed", tostring(result), { key = Config.FLAG_KEY, failures = failures })
		end
		return
	end

	reads += 1
	loaded = true
	overrides = if type(result) == "table" then result else {}
	applyAll()
end

function FlagService.start(dependencies: Dependencies)
	deps = dependencies

	-- Connected before the existing players are swept, then swept, so a player who joined while
	-- the server was still booting cannot land in the gap between the two and spend their whole
	-- session with no flags set.
	Players.PlayerAdded:Connect(apply)
	applyAll()

	-- The first read is a yield, so everything above has already run on the defaults. Whoever is
	-- in the server by the time it lands is re-published by `applyAll` inside `refresh`.
	task.spawn(function()
		while true do
			FlagService.refresh()
			task.wait(Config.FLAG_REFRESH_SECONDS)
		end
	end)

	if not store then
		warn("flags: no DataStore — running on the catalogue defaults (enable Studio API access to read overrides)")
	end
end

return FlagService
