--[[
	Every RemoteEvent in the game, created by the server and waited for by the client, so no
	module does `WaitForChild("SomeRemote")` by hand and no two disagree about the name.

	Adding a client->server remote is two lines: one here, one in `Contract.luau`. The second is
	not optional — the Dispatcher will not connect without it. See docs/net-contract.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local function remote(name: string): RemoteEvent
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(name)
		if existing then
			return existing :: RemoteEvent
		end
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = ReplicatedStorage
		return event
	end
	return ReplicatedStorage:WaitForChild(name) :: RemoteEvent
end

return {
	-- The player's kit (docs/combat.md). Each is an *event* — "I swung", "I dashed" — and the
	-- results come back as state: enemy health on the enemy, cooldowns and health as attributes
	-- on the player. None of them waits for a reply.
	Attack = remote("Attack"),
	Dash = remote("Dash"),
	Spin = remote("Spin"),
	GrabEscape = remote("GrabEscape"),

	-- Server -> client combat sound cues (enemy attacks, explosions, hit confirms, co-op swings).
	-- No Contract entry: the contract governs what a client is allowed to send, not server
	-- broadcasts (docs/net-contract.md).
	CombatSfx = remote("CombatSfx"),

	-- Server -> client combat animation cues for co-op teammates (attack, dash, spin). The local
	-- player animates immediately on input; jump is driven from each character's replicated
	-- HumanoidStateType and needs no remote. No Contract entry for the same reason as CombatSfx.
	CombatAnim = remote("CombatAnim"),

	-- Faults a client saw and the server could not. Client -> server, and the one remote whose
	-- payload outlives the session, so it is validated twice — once by the contract and once
	-- field by field in LogSink.
	Diagnostic = remote("Diagnostic"),
}
