--[[
	How a screen gets on screen: one React root per ScreenGui, wrapped in the layout provider.

	See docs/ui-architecture.md for why the container is the ScreenGui itself, why the provider
	sits above it, and what IgnoreGuiInset buys.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages.react)
local ReactRoblox = require(Packages["react-roblox"])

local Scaled = require(script.Parent.DesignScale)

local UI = {}

export type Options = {
	-- Above or below the other screens. A full-screen modal wants to be over the panels, on-screen
	-- controls want to be under them, and most screens do not care. Default is 0.
	displayOrder: number?,
}

export type Screen = {
	root: any,
	gui: ScreenGui,
	destroy: () -> (),
}

-- Mounts `component` into a ScreenGui of its own. The component renders the *contents* — it does
-- not render a ScreenGui, because React does not own the container it was rooted on.
function UI.mount(name: string, component: any, options: Options?): Screen
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local settings: Options = options or {}

	local gui = Instance.new("ScreenGui")
	gui.Name = name
	-- The line this whole comment block is about.
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	if settings.displayOrder then
		gui.DisplayOrder = settings.displayOrder
	end
	gui.Parent = playerGui

	-- Wrapped in the layout provider rather than leaving each screen to place one: the metrics are
	-- screen-wide, and a screen's own root component is usually the thing that wants them — which
	-- it cannot do if the provider is somewhere inside what it renders.
	local root = ReactRoblox.createRoot(gui)
	root:render(React.createElement(Scaled.Provider, nil, {
		Screen = React.createElement(component),
	}))

	return {
		root = root,
		gui = gui,
		destroy = function()
			root:unmount()
			gui:Destroy()
		end,
	}
end

-- The layer for things that *are* the pointer, rather than things that are part of a panel: a
-- crosshair, a custom cursor, a drag ghost.
--
-- It exists because `DisplayOrder` is the only thing that decides between two ScreenGuis, so
-- something that must never be covered needs a ScreenGui of its own above all of them. Panels
-- sit at 0 and full-screen modals higher; this sits at 100. **Nothing clickable goes in here** —
-- it is above every button in the game and would swallow the press.
--
-- Built once and never destroyed: it is a layer, not a screen, and what is portalled into it
-- comes and goes with whatever owns it.
local cursorLayer: ScreenGui? = nil

function UI.cursorLayer(): ScreenGui
	if cursorLayer then
		return cursorLayer
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "Cursor"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	cursorLayer = gui
	return gui
end

return UI
