--!strict
--[[
	One place that knows how big the screen is and what is pointing at it. Numbers only — this
	module builds no instances; `DesignScale` is the frame and the context.

	**Do not multiply by `scale()` inside a GUI that has been attached.** It is already scaled;
	doing it again shrinks twice. What panels want is `room()` / `safe()` — the screen in the same
	design units they are written in.

	`metrics` is pure — viewport and input mode in, numbers out — which is what lets `selfTest`
	run offline under lune rather than costing a Studio round trip per threshold tweak.

	See docs/ui-architecture.md#scaling.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Charm = require(ReplicatedStorage:WaitForChild("Packages").charm)
local Config = require(ReplicatedStorage:WaitForChild("Shared").core.Config)

export type Metrics = {
	scale: number,
	compact: boolean,
	touch: boolean,
	room: Vector2,
}

local Layout = {}

-- Set by `_force` for tests. nil means "read the real screen".
local forcedViewport: Vector2? = nil
local forcedTouch: boolean? = nil

--=============================================================================
-- The pure part
--=============================================================================

-- Everything the rest of the module answers with, derived from nothing but the screen size and
-- the input mode. Kept free of services so it can be checked offline.
function Layout.metrics(viewport: Vector2, touch: boolean): Metrics
	local reference = Config.UI_REFERENCE
	local fit = math.min(viewport.X / reference.X, viewport.Y / reference.Y)

	-- Floored to a step rather than rounded: rounding up would let a screen one pixel short of
	-- the reference render at 1 and clip.
	local step = Config.UI_SCALE_STEP
	local scale = math.clamp(math.floor(fit / step) * step, Config.UI_MIN_SCALE, 1)

	return {
		scale = scale,
		compact = viewport.X < Config.UI_COMPACT_WIDTH or viewport.Y < Config.UI_COMPACT_HEIGHT,
		touch = touch,
		-- Design units, which is what a panel written in offsets is measuring itself in. On a
		-- phone this is *larger* than the viewport, because the UIScale has shrunk everything
		-- into it: 667 real pixels at 0.55 is 1212 units of room.
		room = viewport / scale,
	}
end

--=============================================================================
-- Reading the real screen
--=============================================================================

local function viewportNow(): Vector2
	if forcedViewport then
		return forcedViewport
	end
	local camera = workspace.CurrentCamera
	-- Nil for the first frames of a client, and a zero viewport would divide the scale to
	-- infinity. The reference is the honest guess until the camera turns up.
	if not camera or camera.ViewportSize.X < 1 or camera.ViewportSize.Y < 1 then
		return Config.UI_REFERENCE
	end
	return camera.ViewportSize
end

local function touchNow(): boolean
	if forcedTouch ~= nil then
		return forcedTouch
	end
	-- A tablet with a keyboard attached is a desktop as far as the HUD is concerned: it has
	-- hotkeys, a cursor and room, and handing it a thumbstick would be worse on every count.
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- `room` counts, even though nothing restructures on it: it is the size of the container every
-- panel is anchored inside, so a viewport that moves without crossing a scale step still has to
-- be announced or the whole HUD stays pinned to the old edges.
local function same(a: Metrics, b: Metrics): boolean
	return a.scale == b.scale and a.compact == b.compact and a.touch == b.touch and a.room == b.room
end

-- The screen, as state rather than as an event.
--
-- This was a BindableEvent and a cached `current` beside it, which is the shape you end up with
-- when the thing being announced is a *value*: a signal cannot be asked what it is now, so every
-- consumer needed the accessors below as well as a connection. An atom is one object that answers
-- both, and `same` is its equality rather than a hand-rolled guard inside the notifier — so a
-- viewport that moves without crossing a scale step costs nothing, and `metrics` returning a
-- fresh table every call stops mattering.
--
-- Seeded from the reference viewport, which is the honest guess until the camera turns up. That
-- also keeps this module loadable with no services at all, which is what lets `metrics` be
-- checked offline.
Layout.state = Charm.atom(Layout.metrics(Config.UI_REFERENCE, false), same)

local function recompute()
	Layout.state(Layout.metrics(viewportNow(), touchNow()))
end

function Layout.scale(): number
	return Layout.state().scale
end

function Layout.compact(): boolean
	return Layout.state().compact
end

function Layout.isTouch(): boolean
	return Layout.state().touch
end

function Layout.viewport(): Vector2
	return viewportNow()
end

-- The screen in the units panels are written in. Anything asking "does this fit" asks here.
function Layout.room(): Vector2
	return Layout.state().room
end

-- Roblox's own top bar, in design units, so a panel pinned to the top of a screen with
-- IgnoreGuiInset set still clears the menu and chat buttons.
function Layout.inset(): number
	return GuiService:GetGuiInset().Y / Layout.scale()
end

-- Height of the strip along the bottom that the thumbstick and the jump/fire buttons own, in
-- design units. Zero on a mouse, where nothing is reserved. Panels keep out of it.
function Layout.band(): number
	if not Layout.isTouch() then
		return 0
	end
	return 2 * Config.TOUCH_MARGIN + 2 * Config.THUMBSTICK_RADIUS
end

-- What is left for panels once the top bar and the control band are taken out, in design units.
function Layout.safe(): Vector2
	local room = Layout.room()
	return Vector2.new(room.X, math.max(room.Y - Layout.inset() - Layout.band(), 1))
end

-- The largest radius a ring of `button`-wide buttons can have and still fit, capped at the one
-- it was designed with. Rings are the one thing here that cannot reflow — a ring is as wide as
-- it is tall, and a phone is neither — so on a short screen it closes up instead of hanging off
-- the top and bottom. Floored well above nothing: a ring tighter than this is a pile.
function Layout.ring(preferred: number, button: number): number
	local room = Layout.room()
	local shorter = math.min(room.X, room.Y - Layout.inset())
	return math.max(math.min(preferred, (shorter - button - 24) / 2), button * 0.7)
end

-- The rectangles the touch controls occupy, in *real* pixels, so a test can check that nothing
-- else is drawn over them. Empty on a mouse.
function Layout.reserved(): { { min: Vector2, max: Vector2 } }
	if not Layout.isTouch() then
		return {}
	end
	local scale = Layout.scale()
	local viewport = Layout.viewport()
	local pad = (2 * Config.THUMBSTICK_RADIUS + Config.TOUCH_MARGIN) * scale
	local corner = (2 * Config.TOUCH_BUTTON + 2 * Config.TOUCH_MARGIN) * scale
	return {
		{ min = Vector2.new(0, viewport.Y - pad), max = Vector2.new(pad, viewport.Y) },
		{ min = Vector2.new(viewport.X - corner, viewport.Y - corner), max = viewport },
	}
end

--=============================================================================
-- Test hooks
--=============================================================================

-- Test hook: pretend the screen is this size and this input mode. Pass nothing to go back to
-- reading the real one. Lets a desktop Studio session lay the HUD out at phone metrics, which
-- is the only way to inspect it without a device in hand.
function Layout._force(viewport: Vector2?, touch: boolean?)
	forcedViewport = viewport
	forcedTouch = touch
	recompute()
end

-- The same hook, reachable from outside the game's Luau VM. Calling `_force` over the Studio
-- MCP does nothing useful: `require` there hands back a *fresh copy* of this module, and the
-- override lands on a table the running HUD has never heard of. Attributes are instance state,
-- which both VMs can see, so that is how the override travels:
--
--   game.Players.LocalPlayer:SetAttribute("LayoutViewport", Vector2.new(667, 375))
--   game.Players.LocalPlayer:SetAttribute("LayoutTouch", true)
--
-- Clearing them puts the real screen back. Studio only — there is nothing here worth shipping,
-- and an attribute a client can set is an attribute a client can lie with.
local function watchOverrides(player: Player)
	local function apply()
		local size = player:GetAttribute("LayoutViewport")
		local touch = player:GetAttribute("LayoutTouch")
		Layout._force(
			if typeof(size) == "Vector2" and size.X > 0 and size.Y > 0 then size else nil,
			if typeof(touch) == "boolean" then touch else nil
		)
	end
	player:GetAttributeChangedSignal("LayoutViewport"):Connect(apply)
	player:GetAttributeChangedSignal("LayoutTouch"):Connect(apply)
	apply()
end

--=============================================================================
-- Staying current
--=============================================================================

local started = false

function Layout.start()
	if started then
		return
	end
	started = true
	recompute()

	local viewportConnection: RBXScriptConnection? = nil
	local function watchCamera()
		if viewportConnection then
			viewportConnection:Disconnect()
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			recompute()
		end)
		recompute()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()

	-- Both of these flip under Studio's device emulator, and a real tablet can gain a keyboard
	-- mid-session. Either one changes the entire shape of the HUD.
	UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(function()
		recompute()
	end)
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(function()
		recompute()
	end)

	if RunService:IsStudio() then
		Layout.selfTest()
		print("Layout.selfTest passed")
		watchOverrides(Players.LocalPlayer)
	end
end

--=============================================================================
-- Self test
--=============================================================================

-- `metrics` decides whether a panel fits, so a wrong threshold is a panel off the side of a
-- phone. Runs on client start in Studio, next to the checks Spray and FaceMath already do on
-- the server, and offline under lune where it costs nothing.
function Layout.selfTest()
	local function check(width: number, height: number, touch: boolean, expect: { [string]: any })
		local got = Layout.metrics(Vector2.new(width, height), touch)
		for key, value in pairs(expect) do
			assert(
				(got :: any)[key] == value,
				`Layout {width}x{height}: {key} was {tostring((got :: any)[key])}, expected {tostring(value)}`
			)
		end
	end

	-- Desktop and up: capped at 1, never compact. A 4K screen gets more room, not bigger buttons.
	check(1920, 1080, false, { scale = 1, compact = false })
	check(3840, 2160, false, { scale = 1, compact = false })
	check(1280, 720, false, { scale = 1, compact = false })
	-- A small window is not a phone: it shrinks, and past the thresholds it also restructures.
	check(1024, 768, false, { compact = false })
	check(800, 600, false, { compact = true })
	-- Phones, both ways up. Both restructure, both sit on the scale floor.
	check(667, 375, true, { scale = Config.UI_MIN_SCALE, compact = true, touch = true })
	check(375, 667, true, { scale = Config.UI_MIN_SCALE, compact = true, touch = true })

	-- The floor holds however absurd the screen, and the cap holds however large.
	assert(Layout.metrics(Vector2.new(1, 1), true).scale == Config.UI_MIN_SCALE, "scale floor")
	assert(Layout.metrics(Vector2.new(99999, 99999), false).scale == 1, "scale cap")

	-- Room is the screen back in design units, so a phone has *more* room than its pixel count
	-- suggests. Panels measure themselves against this; getting the direction wrong would mean
	-- shrinking a panel that already fits.
	local phone = Layout.metrics(Vector2.new(667, 375), true)
	assert(phone.room.X > 667, "room is design units, not pixels")
	assert(math.abs(phone.room.X * phone.scale - 667) < 0.01, "room round-trips through scale")
end

return Layout
