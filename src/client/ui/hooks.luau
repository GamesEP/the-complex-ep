--[[
	The three ways a component reads something that lives outside React: an attribute, an atom,
	a signal.

	**Every hook here re-reads inside its effect before trusting its subscription.** Seeding
	happens during render and subscribing happens later, so anything that moves in between is
	never reported. React Lua is React 17 — there is no `useSyncExternalStore` to do this for us.

	See docs/ui-architecture.md#state for the rest, including when to use a binding instead.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Charm = require(Packages.charm)
local React = require(Packages.react)

local hooks = {}

--=============================================================================
-- Atoms
--=============================================================================

-- A Charm atom, as React state. Re-renders when the atom changes.
--
-- `useLayoutEffect` rather than `useEffect`, which is what closes the seeding race the note at the
-- top describes: it subscribes before the frame is drawn rather than after, so there is no
-- window in which the atom can move unobserved. The re-read is kept anyway — it costs one
-- comparison and it is the difference between "narrow window" and "no window".
function hooks.useAtom<T>(atom: () -> T): T
	local value, setValue = React.useState(atom)

	React.useLayoutEffect(function()
		setValue(atom())
		return Charm.subscribe(atom, setValue :: any)
	end, { atom })

	return value
end

-- The same thing as a React binding: the value reaches the property without a render.
--
-- This is the one to reach for when an atom changes every frame. `useAtom` on a countdown clock
-- or a thumbstick knob would reconcile a whole screen sixty times a second to move one number;
-- this writes the property and React never wakes up.
function hooks.useAtomBinding<T>(atom: () -> T)
	local binding, setBinding = React.useBinding(React.useMemo(atom, {}))

	React.useLayoutEffect(function()
		setBinding(atom())
		return Charm.subscribe(atom, setBinding :: any)
	end, { atom })

	return binding
end

--=============================================================================
-- Attributes
--=============================================================================

-- One replicated attribute off one instance, as state.
--
-- This is the hook that deletes the `refresh()` functions. Anything the server owns and the
-- client displays — a score, a role, a phase, a timer — is an attribute, and without this every
-- panel carries its own `GetAttributeChangedSignal` connection and a function to re-read and
-- rewrite its labels.
--
-- Returns nil for an attribute that is not set, which is the same thing `GetAttribute` does and
-- is a real state: a player in the joining window has no score until the server writes one.
-- Callers keep their own `or` defaults rather than the hook inventing one.
function hooks.useAttribute(instance: Instance, name: string): any
	local value, setValue = React.useState(function()
		return instance:GetAttribute(name)
	end)

	React.useEffect(function()
		setValue(instance:GetAttribute(name))
		local connection = instance:GetAttributeChangedSignal(name):Connect(function()
			setValue(instance:GetAttribute(name))
		end)
		return function()
			connection:Disconnect()
		end
	end, { instance, name })

	return value
end

-- Several attributes off one instance, as one table keyed by name.
--
-- This exists because of the rules of hooks, not for convenience. A panel that needs one value
-- per item in a list would otherwise call `useAttribute` from inside a loop, and a hook call
-- whose count depends on anything is a hook call that will eventually be skipped. One call here
-- subscribes to all of them however long the list is.
--
-- The list is treated as fixed for the lifetime of the component — Config is the usual source —
-- and is compared by content, so passing a fresh table of the same names each render does not
-- resubscribe.
function hooks.useAttributes(instance: Instance, names: { string }): { [string]: any }
	local key = table.concat(names, "\0")

	local function read(): { [string]: any }
		local map = {}
		for _, name in ipairs(names) do
			map[name] = instance:GetAttribute(name)
		end
		return map
	end

	local values, setValues = React.useState(read)

	React.useEffect(function()
		-- Same re-read as `useAttribute`, and the same reason. Compared field by field rather than
		-- set outright: a new table every mount would re-render every panel that uses this for
		-- nothing, and the common case is that none of them moved.
		local fresh = read()
		local changed = false
		for name, value in pairs(fresh) do
			changed = changed or values[name] ~= value
		end
		if changed then
			setValues(fresh)
		end

		local connections = {}
		for _, name in ipairs(names) do
			table.insert(
				connections,
				instance:GetAttributeChangedSignal(name):Connect(function()
					setValues(read())
				end)
			)
		end
		return function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
		end
		-- Keyed on the names' content, not the table's identity, so a caller building the list
		-- inline does not tear the subscriptions down every render.
	end, { instance, key })

	return values
end

--=============================================================================
-- Signals
--=============================================================================

-- Connects to an RBXScriptSignal for as long as the component is mounted.
--
-- The handler is held in a ref and swapped on every render rather than being a dependency, so
-- it can close over this render's props and state without the connection being torn down and
-- remade. That matters most for the frame signals: `RenderStepped` reconnected sixty times a
-- second is not a subscription, it is a leak with good timing.
--
-- **This is not how a value gets on screen every frame.** A handler that calls a state setter
-- per frame re-renders the whole screen per frame. Pair this with `React.useBinding` and write
-- the property directly.
function hooks.useSignal(signal: RBXScriptSignal, handler: (...any) -> ())
	local latest = React.useRef(handler)
	latest.current = handler

	React.useEffect(function()
		local connection = signal:Connect(function(...)
			latest.current(...)
		end)
		return function()
			connection:Disconnect()
		end
	end, { signal })
end

return hooks
