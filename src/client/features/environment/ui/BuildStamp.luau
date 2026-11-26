local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Build = require(Shared.core.Build)
local Environment = require(Shared.core.Environment)

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Client = script:FindFirstAncestor("Client")

local UI = require(Client.ui.Mount)
local Scaled = require(Client.ui.DesignScale)
local ui = require(Client.ui.theme.Widgets)

--[[
	A label in the corner of every non-production client saying which environment and which
	commit this is.

	It is here because the two experiences look identical from the inside. Without it, "the fix
	did nothing" and "you were in the other universe" are the same screenshot, and a bug report
	from the dev experience gets triaged as a production incident. Thirty lines to never spend
	an afternoon on that again. See docs/environments.md#what-is-live.

	**Never mounted in production** — the client bootstrap is what decides, so this file cannot
	be the reason it leaks into a real player's screen.
]]

local WIDTH = 190
local ROLLED_UP = 0.35

local function BuildStamp()
	local metrics = Scaled.useLayout()

	local label = Build.label()
	if not Environment.isRegistered() then
		label ..= " · unregistered universe"
	end

	return React.createElement(Scaled.Frame, nil, {
		Card = React.createElement(ui.Panel, {
			name = "BuildStamp",
			width = math.min(WIDTH, metrics.room.X - 2 * ui.MARGIN),
			padding = 8,
			transparency = ROLLED_UP,
			accentColor = ui.HAZARD,
			accent = "left",
			-- Bottom left, the one corner a HUD rarely wants. No inset(): IgnoreGuiInset is on
			-- and Roblox's own bar is at the top, so the bottom edge is the bottom edge.
			anchorPoint = Vector2.new(0, 1),
			position = UDim2.fromOffset(ui.MARGIN, metrics.room.Y - ui.MARGIN),
		}, {
			Layout = React.createElement("UIListLayout", {
				Padding = UDim.new(0, 2),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Environment = React.createElement(ui.Title, {
				text = Environment.name():upper(),
				font = ui.DISPLAY_FONT,
				textSize = 13,
				color = ui.HAZARD,
				order = 1,
			}),
			Commit = React.createElement(ui.Title, {
				text = label,
				font = ui.MONO_FONT,
				textSize = 11,
				color = ui.MUTED,
				order = 2,
			}),
		}),
	})
end

local screen = {}

function screen.start()
	-- Above the panels, so the stamp is never the thing hidden by the screen being tested, and
	-- below the cursor layer at 100. It is a Frame, so it sinks no input on the way past.
	return UI.mount("BuildStamp", BuildStamp, { displayOrder = 50 })
end

return screen
