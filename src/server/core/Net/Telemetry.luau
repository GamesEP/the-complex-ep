local Players = game:GetService("Players")

--[[
	One place that records a refused action, so an exploit shows up as a count instead of as
	a bug report. Refusals are silent to the client on purpose — a cheat learns nothing from
	being told which check said no — and quiet in the log too: one warn per player per reason,
	with the totals kept for whoever asks.
]]

local Telemetry = {}

local counts: { [Player]: { [string]: number } } = {}

function Telemetry.reject(player: Player, channel: string, reason: string)
	local key = `{channel}:{reason}`
	local mine = counts[player]
	if not mine then
		mine = {}
		counts[player] = mine
	end
	mine[key] = (mine[key] or 0) + 1
	-- The first of a kind is worth a line; the ten-thousandth is only worth its count.
	if mine[key] == 1 then
		warn(`rejected {channel} from {player.Name}: {reason}`)
	end
end

Players.PlayerRemoving:Connect(function(player)
	local mine = counts[player]
	if mine and next(mine) then
		local parts = {}
		for key, count in pairs(mine) do
			table.insert(parts, `{key}={count}`)
		end
		warn(`{player.Name} left with rejections: {table.concat(parts, " ")}`)
	end
	counts[player] = nil
end)

return Telemetry
