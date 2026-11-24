--[[
	The UIScale that shrinks a whole screen, plus the context every panel reads its metrics from.

	The frame is sized in *design units* (`room`) rather than `fromScale(1, 1)`, because a UIScale
	scales the object it is parented to as well as its descendants — a full-screen frame at 0.55
	is 55% of the screen pinned to the top left, and every edge-anchored panel lands in the middle
	of the window. Sizing to `room` and letting the scale multiply it back keeps an edge an edge.

	See docs/ui-architecture.md#scaling.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages").react)

local Layout = require(script.Parent.ScreenMetrics)
local hooks = require(script.Parent.hooks)

local Scaled = {}

-- No default: a component asking for layout metrics outside a `Scaled.Frame` is a mounting
-- mistake, and a plausible-looking fallback would hide it until the panel turned up in the
-- wrong place on somebody's phone.
Scaled.Context = React.createContext(nil)

-- The screen, as the panels inside are measuring it. Also carries `scale`, `compact` and
-- `touch`, which is what decides the whole shape of the HUD.
function Scaled.useLayout(): Layout.Metrics
	local metrics = React.useContext(Scaled.Context)
	if not metrics then
		error("useLayout() outside a Scaled.Frame — the panel is mounted in the wrong place")
	end
	return metrics
end

function Scaled.Provider(props)
	-- `Layout.state` dedupes a viewport that moves without crossing a scale step, so this does
	-- not re-render every panel on every pixel of a window drag.
	local metrics = hooks.useAtom(Layout.state)

	return React.createElement(Scaled.Context.Provider, {
		value = metrics,
	}, props.children)
end

-- The full-screen frame the panels hang off, carrying the UIScale that shrinks them together.
function Scaled.Frame(props)
	local metrics = Scaled.useLayout()

	return React.createElement("Frame", {
		Name = "Scaled",
		Size = UDim2.fromOffset(metrics.room.X, metrics.room.Y),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- These GUIs run ZIndexBehavior.Global, where a tie falls back to tree order. 0 keeps
		-- this container from ever winning one against something it contains.
		ZIndex = 0,
	}, {
		Scale = React.createElement("UIScale", { Scale = metrics.scale }),
		-- A Fragment adds no instance of its own, so the panels land directly under the frame
		-- rather than inside a wrapper that would break their anchoring.
		Panels = React.createElement(React.Fragment, nil, props.children),
	})
end

return Scaled
