local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.core.Config)
local Remotes = require(Shared.core.Net.Remotes)

--[[
	Where a client-side fault goes so it is never only a shrug.

	**A silent failure path should report, not `return`.** Most of what breaks on a client does
	not throw — a refused allocation is a plain `nil`, an unfinished model just renders as
	whatever was underneath — and each of those is naturally written as an early return that is
	correct, invisible, and broken for the rest of the session.

	Reports go to the console on a curve and to the server in batches. See docs/telemetry.md.
]]

local Diagnostics = {}

type Cause = {
	area: string,
	code: string,
	detail: string,
	fields: string,
	count: number,
	reported: number,
}

local causes: { [string]: Cause } = {}
local order: { string } = {}
local flushing = false

-- Sorted, so the same fault reads the same way twice and a diff between two reports is a real
-- difference rather than a table-order shuffle.
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

-- Whether this occurrence earns a console line. Early ones do, so a new fault is seen
-- immediately; then it thins out, so a per-frame failure cannot drown everything else.
local function speaks(count: number): boolean
	for _, step in ipairs(Config.DIAG_REPEAT_STEPS) do
		if count == step then
			return true
		end
	end
	return count % Config.DIAG_REPEAT_EVERY == 0
end

local function flush()
	local batch = {}
	for _, key in ipairs(order) do
		local cause = causes[key]
		local unsent = cause.count - cause.reported
		if unsent > 0 then
			cause.reported = cause.count
			table.insert(batch, {
				area = cause.area,
				code = cause.code,
				detail = cause.detail,
				fields = cause.fields,
				count = unsent,
			})
			if #batch >= Config.DIAG_CLIENT_BATCH then
				break
			end
		end
	end
	if #batch > 0 then
		Remotes.Diagnostic:FireServer(batch)
	end
end

--[[
	Report a fault. Cheap enough to call from a per-frame path: the work is a table lookup and
	an increment, and everything expensive is on the curve or on the flush.

	  area    which pipeline — "world", "ui", "net"
	  code    how it went wrong, kebab-case and stable, because this is what you grep for
	  detail  a sentence saying what was true, in the terms of the thing that broke
	  fields  the identifying values: instance, index, size, player, request
]]
function Diagnostics.fault(area: string, code: string, detail: string, fields: { [string]: any }?)
	local key = `{area}/{code}`
	local cause = causes[key]
	if not cause then
		cause = { area = area, code = code, detail = detail, fields = "", count = 0, reported = 0 }
		causes[key] = cause
		table.insert(order, key)
	end
	cause.count += 1
	cause.detail = detail
	cause.fields = fieldText(fields)

	if speaks(cause.count) then
		local suffix = if cause.count > 1 then ` (x{cause.count})` else ""
		local where = if cause.fields == "" then "" else `  [{cause.fields}]`
		warn(`{key}: {detail}{where}{suffix}`)
	end

	if not flushing then
		flushing = true
		task.spawn(function()
			while true do
				task.wait(Config.DIAG_CLIENT_FLUSH_SECONDS)
				local ok, err = pcall(flush)
				if not ok then
					-- Never through `fault`: a reporting channel that reports its own failure
					-- through itself is a loop, not a diagnostic.
					warn(`diagnostics: could not report faults upstream: {err}`)
				end
			end
		end)
	end
end

-- Every distinct cause this client has seen, with its count. A copy, so a reader cannot reset
-- the totals by accident.
function Diagnostics.stats(): { [string]: number }
	local out = {}
	for key, cause in pairs(causes) do
		out[key] = cause.count
	end
	return out
end

return Diagnostics
