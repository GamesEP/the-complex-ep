local DataStoreService = game:GetService("DataStoreService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Build = require(Shared.core.Build)
local Config = require(Shared.core.Config)
local Environment = require(Shared.core.Environment)

local Telemetry = require(script.Parent.Parent.Parent.core.Net.Telemetry)

--[[
	Somewhere to read a published server's output from, because Roblox gives you nowhere: a
	server's `print` and `warn` reach no player's log, and Creator Hub keeps only the errors that
	raise themselves.

	One DataStore key per server, so a flush is a plain SetAsync with no contention and no
	read-modify-write to lose a race in. Fed by `LogService.MessageOut` and by `record`; read back
	with `make logs`. See docs/telemetry.md.
]]

local LogSink = {}

-- Studio refuses to open a DataStore without API access, exactly as ProfileService documents.
-- A developer without it should still get a playable game and a working console; they just do
-- not get the durable copy.
local store = nil
do
	local ok, opened = pcall(function()
		return DataStoreService:GetDataStore(Config.DIAG_STORE)
	end)
	store = if ok then opened else nil
end

-- This server's key. JobId is empty in Studio, where there is exactly one server and
-- overwriting the same key every run is the useful behaviour.
local function serverKey(): string
	local job = game.JobId
	if job == "" then
		return `{Config.DIAG_KEY_PREFIX}studio`
	end
	return `{Config.DIAG_KEY_PREFIX}{job}`
end

local KEY = serverKey()

-- The tail, newest last, and the distinct causes with their counts. Two structures because
-- they answer different questions: the tail is "what was it doing", the causes are "what is
-- wrong, and how badly".
local tail: { any } = {}
local causes: { [string]: any } = {}
local causeOrder: { string } = {}
local dirty = false
local writes, failures = 0, 0
local started = os.time()

local function clip(text: string?): string
	local s = tostring(text or "")
	if #s <= Config.DIAG_MAX_DETAIL then
		return s
	end
	return s:sub(1, Config.DIAG_MAX_DETAIL - 1) .. "\u{2026}"
end

-- Fields ride as a flat `k=v` string rather than a nested table: a DataStore value has to be
-- JSON-encodable, and a report from a client is untrusted input that must not decide the shape
-- of what gets stored.
local function fieldText(fields: { [string]: any }?): string
	if not fields then
		return ""
	end
	local keys = {}
	for key in pairs(fields) do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, `{key}={tostring(fields[key])}`)
	end
	return table.concat(parts, " ")
end

local function push(entry)
	table.insert(tail, entry)
	while #tail > Config.DIAG_MAX_ENTRIES do
		table.remove(tail, 1)
	end
	dirty = true
	if #tail >= Config.DIAG_FLUSH_AT then
		task.spawn(LogSink.flush)
	end
end

--[[
	One structured fault. `area` says which pipeline, `code` says which way it went wrong, and
	`fields` carries the identifying detail — the instance, the size, the player, the request id —
	that turns "something was wrong" into something you can act on without a repro.

	`count` is how many times this cause has fired since the last report; a client sends its
	own running total rather than one message per occurrence.
]]
function LogSink.record(area: string, code: string, detail: string, fields: { [string]: any }?, count: number?)
	local key = `{area}/{code}`
	local n = math.max(1, math.floor(count or 1))
	local cause = causes[key]
	if not cause then
		cause = {
			area = area,
			code = code,
			detail = clip(detail),
			fields = fieldText(fields),
			count = 0,
			first = os.time(),
		}
		causes[key] = cause
		table.insert(causeOrder, key)
	end
	cause.count += n
	cause.last = os.time()
	-- The newest detail wins: the same code with a different part or a different size is the
	-- more useful of the two, and the first is kept in the tail below anyway.
	cause.detail = clip(detail)
	cause.fields = fieldText(fields)

	push({
		t = os.time(),
		kind = "fault",
		area = area,
		code = code,
		detail = clip(detail),
		fields = fieldText(fields),
		count = n,
	})
end

-- Everything the server prints, whoever printed it. Warnings and errors only: `print` on a
-- busy server is a firehose, and the ring buffer is for what went wrong.
local function onMessage(message: string, kind: Enum.MessageType)
	if kind ~= Enum.MessageType.MessageWarning and kind ~= Enum.MessageType.MessageError then
		return
	end
	push({
		t = os.time(),
		kind = if kind == Enum.MessageType.MessageError then "error" else "warn",
		detail = clip(message),
	})
end

--[[
	Writes the buffer out. Safe to call at any time and cheap when nothing has changed.

	SetAsync rather than UpdateAsync because this key belongs to this server alone: there is no
	other writer to merge with, and a transform would only add a read to every write.
]]
function LogSink.flush()
	if not store or not dirty then
		return
	end
	dirty = false

	local list = {}
	for _, key in ipairs(causeOrder) do
		local c = causes[key]
		table.insert(list, {
			key = key,
			count = c.count,
			first = c.first,
			last = c.last,
			detail = c.detail,
			fields = c.fields,
		})
	end

	local payload = {
		place = game.PlaceId,
		version = game.PlaceVersion,
		job = game.JobId,
		studio = RunService:IsStudio(),
		-- Which universe and which commit. `version` is Roblox's publish counter and maps to no
		-- source you can check out, so on its own it cannot answer "is the fix in?" — these two
		-- are what tie a fault to a diff. See docs/environments.md#what-is-live.
		environment = Environment.name(),
		commit = Build.SHORT,
		branch = Build.BRANCH,
		started = started,
		wrote = os.time(),
		players = #Players:GetPlayers(),
		causes = list,
		tail = tail,
	}

	local ok, err = pcall(function()
		store:SetAsync(KEY, payload)
	end)
	if ok then
		writes += 1
	else
		failures += 1
		dirty = true
		-- Deliberately not routed through `record`: a failing sink reporting its own failure
		-- into itself is how you turn one broken write into a loop of them.
		if failures == 1 then
			warn(`diagnostics: could not write {KEY}: {err}`)
		end
	end
end

-- What the sink itself has been doing, for anyone who wants to know whether the silence means
-- "nothing broke" or "nothing is being recorded".
function LogSink.stats(): { [string]: any }
	return {
		store = store ~= nil,
		key = KEY,
		causes = #causeOrder,
		tail = #tail,
		writes = writes,
		failures = failures,
	}
end

--[[
	A client's batch of faults, arriving over the Diagnostic remote.

	This is untrusted input that ends up in persistent storage, so nothing here trusts a shape:
	every field is re-read and re-clipped, the batch is capped, and anything malformed is a
	refusal counted like any other rather than a partial write of somebody's junk. The client's
	own identity is stamped here rather than taken from the payload — a client does not get to
	say who it is.
]]
function LogSink.onClientReport(player: Player, batch: any)
	if type(batch) ~= "table" then
		return Telemetry.reject(player, "Diagnostic", "not a list")
	end
	local taken = 0
	for _, item in ipairs(batch) do
		if taken >= Config.DIAG_CLIENT_BATCH then
			break
		end
		if type(item) ~= "table" then
			return Telemetry.reject(player, "Diagnostic", "entry not a table")
		end
		local area, code = item.area, item.code
		if type(area) ~= "string" or type(code) ~= "string" or #area > 24 or #code > 48 then
			return Telemetry.reject(player, "Diagnostic", "bad area/code")
		end
		local count = tonumber(item.count) or 1
		if count ~= count or count < 1 or count > 1e9 then
			return Telemetry.reject(player, "Diagnostic", "bad count")
		end
		local fields = if type(item.fields) == "string" then item.fields:sub(1, Config.DIAG_MAX_DETAIL) else ""
		LogSink.record(
			`client.{area}`,
			code,
			if type(item.detail) == "string" then item.detail else "",
			{ player = player.Name, userId = player.UserId, from = fields },
			math.floor(count)
		)
		taken += 1
	end
end

function LogSink.start()
	LogService.MessageOut:Connect(onMessage)

	-- The line every other line in this buffer is read against, printed rather than recorded: it
	-- is not a fault, and F9 in a live server should open on it.
	print(`{Environment.name()} — {Build.label()}`)

	-- A published universe in no row of `Config.ENV_UNIVERSES` fell back to `ENV_DEFAULT`, which
	-- is deliberately the locked-down one. A safe guess is still a misconfiguration, and this is
	-- the one place that both knows and is read afterwards.
	if not Environment.isRegistered() then
		LogSink.record(
			"environment",
			"unregistered-universe",
			"this universe is in no row of Config.ENV_UNIVERSES — treating it as the default",
			{ gameId = game.GameId, assumed = Environment.name() }
		)
	end

	task.spawn(function()
		while true do
			task.wait(Config.DIAG_FLUSH_SECONDS)
			LogSink.flush()
		end
	end)

	-- The last write, and the one that matters most: a server shutting down is a server whose
	-- final minute nobody else saw. BindToClose is given up to 30 seconds by the engine.
	game:BindToClose(function()
		LogSink.flush()
	end)

	if not store then
		warn("diagnostics: no DataStore — faults go to the console only (enable Studio API access to persist)")
	end
end

return LogSink
