local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Contract = require(Shared.core.Net.Contract)
local Remotes = require(Shared.core.Net.Remotes)

local Telemetry = require(script.Parent.Telemetry)

local RateLimiter = require(script.Parent.RateLimiter)

--[[
	The one place a client->server remote is connected. Rate, role, phase and argument shapes are
	enforced from the contract before the handler runs, and **a remote with no contract entry
	refuses to connect at all** — a new remote cannot forget its rate limit, because this will not
	wire one without it.

	Refusals are silent to the sender and recorded by Telemetry. See docs/net-contract.md.
]]

local Dispatcher = {}

-- The round owns roles and phases, and the admin list is the admin feature's. Injected, so
-- the core does not require features.
local deps = nil :: any

function Dispatcher.init(dependencies: { Round: any, isAdmin: (Player) -> boolean })
	deps = dependencies
end

function Dispatcher.connect(name: string, handler: (Player, ...any) -> ())
	local contract = Contract[name]
	if not contract then
		error(`remote {name} has no entry in the net contract — add one before connecting it`)
	end
	local remote = Remotes[name]
	if not remote then
		error(`remote {name} does not exist in Remotes`)
	end
	assert(deps, "Dispatcher.init must run before anything connects")

	remote.OnServerEvent:Connect(function(player: Player, ...)
		if contract.admin and not deps.isAdmin(player) then
			return Telemetry.reject(player, name, "not admin")
		end
		if type(contract.rate) == "number" and not RateLimiter.allow(player, name, contract.rate) then
			return Telemetry.reject(player, name, "rate")
		end
		if contract.role and deps.Round.getRole(player) ~= contract.role then
			return Telemetry.reject(player, name, "role")
		end
		if contract.phase == "playing" and not deps.Round.isPlaying() then
			return Telemetry.reject(player, name, "phase")
		end
		if contract.phase == "inRound" and not deps.Round.inRound() then
			return Telemetry.reject(player, name, "phase")
		end
		if contract.args then
			-- `select` reads the varargs in place. Packing them into a table just to index
			-- positionally would allocate once per event on the channels that fire hardest,
			-- which are exactly the ones a rate limit is protecting.
			for index, check in ipairs(contract.args) do
				if not check((select(index, ...))) then
					return Telemetry.reject(player, name, `arg {index}`)
				end
			end
		end
		handler(player, ...)
	end)
end

return Dispatcher
