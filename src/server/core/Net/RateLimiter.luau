local Players = game:GetService("Players")

--[[
	One counter per player per channel per second. Everything a client can ask the server for
	is metered — the ones that end in a DataStore write above all, or one client looping a
	remote at frame rate decides whether anybody else's session gets saved.
]]

local RateLimiter = {}

local actions: { [Player]: { [string]: { n: number, t: number } } } = {}

function RateLimiter.allow(player: Player, channel: string, perSecond: number): boolean
	local channels = actions[player]
	if not channels then
		-- Created on first use rather than on join, so a remote fired in the joining window
		-- is metered instead of dropped — the bucket is the defence, not the registration.
		channels = {}
		actions[player] = channels
	end
	local now = os.clock()
	local bucket = channels[channel]
	if not bucket or now - bucket.t >= 1 then
		bucket = { n = 0, t = now }
		channels[channel] = bucket
	end
	bucket.n += 1
	return bucket.n <= perSecond
end

Players.PlayerRemoving:Connect(function(player)
	actions[player] = nil
end)

return RateLimiter
