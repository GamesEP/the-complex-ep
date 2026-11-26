--!strict
--[[
	Everything a Roblox module takes for granted, handed to a Lune chunk.

	Several scripts here load real source out of `src/` rather than keeping a second copy of
	what it says — the arena builder runs `Arena.build()`, the test runner runs the self tests.
	They all need the same thing first: `luau.load` starts from an empty environment, so the
	standard library, the Roblox datatypes, and stubs for `game`/`workspace`/`require` have to
	be handed over explicitly. That setup lives here once instead of once per script, because
	three copies of a stubbed ReplicatedStorage drift apart the first time a module reaches for
	something new.

	The datatypes are the real ones from @lune/roblox, so a CFrame computed here is the CFrame
	a server would compute. What is *not* real is anything with runtime behaviour: no signals
	fire, no instance replicates, no service answers. A module that reaches for one of those is
	by definition not checkable offline, and `Sandbox.service` says so by name rather than
	handing back a nil that fails somewhere else.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Sandbox = {}

Sandbox.CONFIG_DIR = "src/shared/core/Config"

--=============================================================================
-- Environment
--=============================================================================

local function datatypes(): { [string]: any }
	return {
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		Instance = roblox.Instance,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
	}
end

-- `extra` wins over both the standard library and the datatypes, which is how a caller swaps in
-- a patched `Instance` or a stub `game` without a second environment builder.
function Sandbox.environment(extra: { [string]: any }?): { [string]: any }
	local env: { [string]: any } = {
		assert = assert,
		buffer = buffer,
		error = error,
		getmetatable = getmetatable,
		ipairs = ipairs,
		math = math,
		next = next,
		os = os,
		pairs = pairs,
		pcall = pcall,
		print = print,
		select = select,
		setmetatable = setmetatable,
		string = string,
		table = table,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		typeof = typeof,
		warn = print,
	}
	for key, value in datatypes() do
		env[key] = value
	end
	for key, value in extra or {} do
		env[key] = value
	end
	return env
end

function Sandbox.run(path: string, extra: { [string]: any }?): any
	return luau.load(fs.readFile(path), {
		debugName = path,
		environment = Sandbox.environment(extra),
	})()
end

--=============================================================================
-- Stubs
--=============================================================================

-- A service that exists only to be named in the failure. Anything that actually calls through
-- one is reaching outside the pure path, and the error says which member gave it away.
function Sandbox.service(name: string): any
	return setmetatable({}, {
		__index = function(_, key)
			error(`used {name}.{key}, which is not pure — it cannot be run offline`)
		end,
	})
end

-- Lune's Instance.new builds real instances but no runtime behaviour, so a BindableEvent has
-- no usable `.Event`. Modules that only want somewhere to fire "something changed" are happy
-- with a table of the same shape, and nothing offline is listening.
function Sandbox.inertInstance(): any
	return setmetatable({
		Event = { Connect = function() end },
		Fire = function() end,
	}, {
		__index = function()
			return function() end
		end,
		__newindex = function() end,
	})
end

-- `Instance`, with the given class names answered by an inert table instead of a real instance.
function Sandbox.instanceStubbing(classNames: { string }): any
	local inert: { [string]: boolean } = {}
	for _, className in classNames do
		inert[className] = true
	end

	return {
		new = function(className: string, ...): any
			if inert[className] then
				return Sandbox.inertInstance()
			end
			return roblox.Instance.new(className, ...)
		end,
	}
end

--=============================================================================
-- Config
--
-- Config reaches for the asset manifest, which is a lookup of upload ids and has nothing to say
-- about geometry or screen size. Stubbed rather than loaded: a missing id is already the "not
-- uploaded yet" case every caller handles.
--=============================================================================

local ASSETS_STUB = {
	id = function(_fileName: string): number
		return 0
	end,
}

-- Config is a folder of parts merged by its init.luau. The stubs mirror the two shapes a
-- part's requires take: `script.Parent.<Part>` names a sibling part, `script.Parent.Parent.
-- Assets` names the manifest — and init's own `script[<Part>]` names a child. All three
-- resolve to the part's name, and `load` turns a name back into a file.
function Sandbox.config(): any
	local parts: { [string]: any } = {}

	local partScript = {
		Parent = setmetatable({}, {
			__index = function(_, key: string): any
				if key == "Parent" then
					return { Assets = "Assets" }
				end
				return key
			end,
		}),
	}
	local initScript = setmetatable({}, {
		__index = function(_, key: string): string
			return key
		end,
	})

	local function load(target: any): any
		if target == "Assets" then
			return ASSETS_STUB
		end
		if type(target) ~= "string" then
			error(`Config required something the sandbox does not stub: {tostring(target)}`)
		end
		if parts[target] == nil then
			parts[target] = Sandbox.run(`{Sandbox.CONFIG_DIR}/{target}.luau`, {
				script = partScript,
				require = load,
			})
		end
		return parts[target]
	end

	return Sandbox.run(`{Sandbox.CONFIG_DIR}/init.luau`, {
		script = initScript,
		require = load,
	})
end

return Sandbox
