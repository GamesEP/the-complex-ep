--!strict
--[[
	Every check that can run without Studio, in one place: the syntax sweep, and the `selfTest`
	of every pure module and every store, loaded out of `src/` under `scripts/lib/sandbox.luau`.

	One entry point rather than one script per check, so CI, the publish workflow and `make test`
	all call the same command and a new suite reaches all three by being added to SUITES below.

	**The rule for adding a suite: if it needs a service, it does not belong here** — and the
	sandbox enforces that rather than trusting it, by handing every service an object that errors
	with the member name that reached for it. See docs/testing.md.

	  lune run scripts/run-tests.luau            # everything
	  lune run scripts/run-tests.luau --only ui
	  lune run scripts/run-tests.luau --list
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Sandbox = require("./lib/sandbox")

local LAYOUT_SOURCE = "src/client/ui/ScreenMetrics.luau"
local FEATURES_DIR = "src/client/features"
local CHARM_DIR = "Packages/_Index/littensy_charm@0.11.0/charm/src"
local SHARED_DIR = "src/shared"

-- Everything that ships to Roblox, plus the lune scripts themselves — a broken script is just
-- as annoying to discover at the point of use.
local SYNTAX_ROOTS = { "src", "scripts" }

--=============================================================================
-- Module loading
--
-- The self tests print their own "passed" line, which is this script's job to decide. Their
-- output is collected instead and shown only for a suite that fails, where a warn on the way
-- down is usually the interesting part.
--=============================================================================

local output: { string } = {}

local function collect(...)
	local parts = {}
	for i = 1, select("#", ...) do
		table.insert(parts, tostring((select(i, ...))))
	end
	table.insert(output, table.concat(parts, " "))
end

-- The trees are nested (core/, features/), so a stubbed module cannot be a flat name — it is a
-- *path*. A vnode stands in for an Instance at one spot in that tree: indexing it walks down,
-- `Parent` walks up, and `FindFirstAncestor("Shared")` jumps to the root, which covers every way
-- one module names another. `require` gets the vnode and turns its path back into a file.
--
-- The client tree is kept apart by its own field: a shared path and a client path resolve to
-- different files, and conflating them would let a module quietly load the wrong realm's copy.
local cnode
function cnode(cpath: string): any
	return setmetatable({ __cpath = cpath }, {
		__index = function(t: any, key: string): any
			if key == "WaitForChild" then
				return function(_self: any, name: string): any
					return cnode(if t.__cpath == "" then name else `{t.__cpath}/{name}`)
				end
			end
			return cnode(if t.__cpath == "" then key else `{t.__cpath}/{key}`)
		end,
	})
end

local function vnode(vpath: string): any
	return setmetatable({ __vpath = vpath }, {
		__index = function(t: any, key: string): any
			if key == "Parent" then
				return vnode((t.__vpath:gsub("/?[^/]*$", "")))
			end
			if key == "FindFirstAncestor" then
				return function(_self: any, name: string): any
					if name == "Shared" then
						return vnode("")
					end
					if name == "Client" then
						return cnode("")
					end
					error(`FindFirstAncestor({name}) is not stubbed offline`)
				end
			end
			if key == "WaitForChild" then
				return function(_self: any, name: string): any
					return vnode(if t.__vpath == "" then name else `{t.__vpath}/{name}`)
				end
			end
			return vnode(if t.__vpath == "" then key else `{t.__vpath}/{key}`)
		end,
	})
end

-- Loaded once each and memoised by path, the same as a real `require`.
local loaded: { [string]: any } = {}

local function shared(vpath: any): any
	if vpath == "charm" then
		error("charm resolves through requireStub, not shared()")
	end
	if type(vpath) == "table" then
		vpath = rawget(vpath, "__vpath") or error("required something that is not a shared module")
	end
	if type(vpath) ~= "string" then
		error(`the sandbox only resolves shared modules by path, got {typeof(vpath)}`)
	end
	if loaded[vpath] then
		return loaded[vpath]
	end

	-- Config is a folder merged by its own init, and `script[name]` is not something a vnode can
	-- answer, so the sandbox assembles it the same way the real init does.
	if vpath == "core/Config" then
		loaded[vpath] = Sandbox.config()
		return loaded[vpath]
	end

	local source = `{SHARED_DIR}/{vpath}.luau`
	if not fs.isFile(source) then
		error(`required {vpath}, which is not a module under {SHARED_DIR}`)
	end

	loaded[vpath] = Sandbox.run(source, {
		script = vnode(vpath),
		require = shared,
		print = collect,
		warn = collect,
	})
	return loaded[vpath]
end

-- Charm, loaded the way a store gets it. It reaches for nothing outside the Luau standard
-- library, so it needs no stubs of its own — which is the only reason the modules that hold
-- their state in an atom can be checked offline at all.
--
-- `strict` and `frozen` both default to `isStudio()`, and there is no `game` out here, so they
-- would be off. Turned on deliberately: they catch a yielding effect and an in-place mutation of
-- a table inside an atom, which are exactly the two failures that are hardest to reproduce by
-- pressing Play, and here they cost microseconds.
local charmModule: any = nil

local function charm(): any
	if charmModule then
		return charmModule
	end
	local system = Sandbox.run(`{CHARM_DIR}/system.luau`, { print = collect, warn = collect })
	charmModule = Sandbox.run(`{CHARM_DIR}/init.luau`, {
		require = function(): any
			return system
		end,
		print = collect,
		warn = collect,
	})
	charmModule.flags.strict = true
	charmModule.flags.frozen = true
	return charmModule
end

-- One ReplicatedStorage for every client module checked offline: Packages holds charm, and
-- anything else asked for is the Shared tree's root vnode, so `.core.Config` and its neighbours
-- resolve the same way they do in the game.
local function replicatedStorageStub(): any
	return {
		WaitForChild = function(_self: any, name: string): any
			if name == "Packages" then
				return { charm = "charm" }
			end
			return vnode("")
		end,
	}
end

-- Faults reported by whatever module is loaded under the current harness. A suite that wants to
-- assert "did this path report?" swaps the real Diagnostics — which fires a RemoteEvent and
-- cannot load here at all — for this.
local faults: { { area: string, code: string, detail: string, fields: any } } = {}

local function diagnosticsDouble(): any
	table.clear(faults)
	return {
		fault = function(area: string, code: string, detail: string, fields: any)
			table.insert(faults, { area = area, code = code, detail = detail, fields = fields })
		end,
		stats = function(): any
			return {}
		end,
	}
end

local function requireStub(who: string, diagnostics: any?): (any) -> any
	return function(target: any): any
		if target == "charm" then
			return charm()
		end
		if type(target) == "table" and rawget(target, "__vpath") then
			return shared(target)
		end
		if type(target) == "table" and rawget(target, "__cpath") then
			local cpath = rawget(target, "__cpath")
			if cpath == "core/Diagnostics" then
				return diagnostics or diagnosticsDouble()
			end
			error(`{who} required a client module the sandbox does not stub: {cpath}`)
		end
		error(`{who} required something the sandbox does not stub: {tostring(target)}`)
	end
end

-- ScreenMetrics is a client module and reaches further than a shared one: a viewport off the
-- camera and an input mode off UserInputService. None of that is on the pure path `metrics`
-- takes, so the services are the erroring stub — if `metrics` ever touches one, this fails with
-- the member that did it rather than quietly testing something else.
local function layoutModule(): any
	return Sandbox.run(LAYOUT_SOURCE, {
		workspace = Sandbox.service("workspace"),
		game = {
			GetService = function(_self: any, name: string): any
				if name == "ReplicatedStorage" then
					return replicatedStorageStub()
				end
				return Sandbox.service(name)
			end,
		},
		require = requireStub("ScreenMetrics"),
		print = collect,
		warn = collect,
	})
end

--=============================================================================
-- Suites
--=============================================================================

-- Lune appends its own traceback to a compile error, which is about this script rather than
-- about the file that failed to parse. Only the first line is useful.
local function firstLine(err: string): string
	return (err:gsub("\nstack traceback:.*$", ""):gsub("\n.*$", ""))
end

-- `rojo build` packs source, it does not read it. A file with a syntax error is packed verbatim,
-- the build succeeds, CI publishes it, and the error only surfaces when Roblox runs the script —
-- which for a ModuleScript means the first `require`, potentially mid-round.
--
-- It compiles, so it catches syntax and compile errors only. It does not resolve `require`s,
-- does not know Roblox's globals, and is not a type checker: a misspelled `Workspae` still gets
-- through, and `make globals` is what has anything to say about that.
local function syntaxSuite(): string
	local failures = {}
	local checked = 0

	local function walk(dir: string)
		if not fs.isDir(dir) then
			return
		end
		for _, entry in fs.readDir(dir) do
			local path = `{dir}/{entry}`
			if fs.isDir(path) then
				walk(path)
			elseif entry:match("%.luau$") then
				checked += 1
				local ok, err = pcall(luau.load, fs.readFile(path), { debugName = path })
				if not ok then
					table.insert(failures, `{path}: {firstLine(tostring(err))}`)
				end
			end
		end
	end

	for _, root in SYNTAX_ROOTS do
		walk(root)
	end

	if #failures > 0 then
		error(`{#failures} of {checked} files failed to compile\n      ` .. table.concat(failures, "\n      "), 0)
	end
	return `{checked} Luau files compile`
end

-- Every pure module under `shared/features/` that carries a `selfTest`, rather than a list a new
-- one has to be added to. This is the suite most game rules belong in: extract the decision into
-- a module that touches no service, assert it here, and the Studio round trip stops being how
-- you find out.
local function sharedSuite(): string
	local tested = {}

	local function walk(dir: string, vprefix: string)
		if not fs.isDir(dir) then
			return
		end
		for _, entry in fs.readDir(dir) do
			local path = `{dir}/{entry}`
			if fs.isDir(path) then
				walk(path, `{vprefix}{entry}/`)
			else
				local name = entry:match("^(.+)%.luau$")
				if name and name ~= "init" then
					local module = shared(`{vprefix}{name}`)
					if type(module) == "table" and module.selfTest then
						module.selfTest()
						table.insert(tested, `{vprefix}{name}`)
					end
				end
			end
		end
	end

	walk(`{SHARED_DIR}/features`, "features/")

	if #tested == 0 then
		return "no shared module carries a selfTest yet"
	end
	return table.concat(tested, ", ")
end

-- The pure modules at the top of `shared/core/` — the vocabulary every feature is written in,
-- rather than any one feature's rules. Discovered by walking, like the two suites either side.
--
-- Top-level files only, and that is the boundary rather than an accident: everything else in
-- `core/` is a folder, and the folders are the parts that reach for a service. `Net/Remotes`
-- creates a RemoteEvent at require time and cannot load out here at all, which is the point —
-- a module that belongs in this suite is one with nothing to stub.
local function coreSuite(): string
	local tested = {}
	local dir = `{SHARED_DIR}/core`

	for _, entry in fs.readDir(dir) do
		if fs.isDir(`{dir}/{entry}`) then
			continue
		end
		local name = entry:match("^(.+)%.luau$")
		if not name then
			continue
		end
		local module = shared(`core/{name}`)
		if type(module) == "table" and module.selfTest then
			module.selfTest()
			table.insert(tested, `core/{name}`)
		end
	end

	if #tested == 0 then
		return "no core module carries a selfTest yet"
	end
	return table.concat(tested, ", ")
end

-- How far the UI shrinks and when it restructures. A wrong threshold is a panel hanging off the
-- side of a phone, which is expensive to see and cheap to assert.
local function layoutSuite(): string
	local Config = shared("core/Config")
	layoutModule().selfTest()

	return `scale {Config.UI_MIN_SCALE}..1 against {Config.UI_REFERENCE.X}x{Config.UI_REFERENCE.Y}, `
		.. `compact under {Config.UI_COMPACT_WIDTH}x{Config.UI_COMPACT_HEIGHT}`
end

-- Every store under every client feature, discovered by walking `features/*/stores/` rather than
-- listed here. A store is the seam between the plain modules and React, and its rules are
-- usually orderings that two clients and a stopwatch cannot be relied on to reproduce. Pure
-- Luau, no instance and no signal object, so they load with almost no stubs.
local function uiSuite(): string
	local tested = {}
	if not fs.isDir(FEATURES_DIR) then
		return "no client features yet"
	end
	for _, feature in fs.readDir(FEATURES_DIR) do
		local dir = `{FEATURES_DIR}/{feature}/stores`
		if not fs.isDir(dir) then
			continue
		end
		for _, entry in fs.readDir(dir) do
			local name = entry:match("^(.+)%.luau$")
			if not name then
				continue
			end
			local module = Sandbox.run(`{dir}/{entry}`, {
				game = {
					GetService = function(_self: any, service: string): any
						if service == "ReplicatedStorage" then
							return replicatedStorageStub()
						end
						return Sandbox.service(service)
					end,
				},
				require = requireStub(`store {feature}/{name}`),
				print = collect,
				warn = collect,
			})
			if module.selfTest then
				module.selfTest()
				table.insert(tested, `{feature}/{name}`)
			end
		end
	end

	if #tested == 0 then
		return "no store carries a selfTest yet"
	end
	return table.concat(tested, ", ")
end

type Suite = {
	name: string,
	detail: string,
	run: () -> string,
}

local SUITES: { Suite } = {
	{ name = "syntax", detail = "every .luau file compiles", run = syntaxSuite },
	{ name = "shared", detail = "selfTest on every pure module under shared/features", run = sharedSuite },
	{ name = "core", detail = "selfTest on every pure module at the top of shared/core", run = coreSuite },
	{ name = "layout", detail = "ScreenMetrics.selfTest", run = layoutSuite },
	{ name = "ui", detail = "selfTest on every store under client features", run = uiSuite },
}

--=============================================================================
-- Arguments
--=============================================================================

local only: { [string]: boolean } = {}
local selective = false
local list = false

local args = process.args
local i = 1
while i <= #args do
	local a = args[i]
	if a == "--list" then
		list = true
		i += 1
	elseif a == "--only" then
		local name = args[i + 1] or error("--only needs a suite name")
		only[name] = true
		selective = true
		i += 2
	else
		error(`unknown argument {a} — expected --only <suite> or --list`)
	end
end

if list then
	for _, suite in SUITES do
		print(`{suite.name}  {suite.detail}`)
	end
	return
end

for name in only do
	local known = false
	for _, suite in SUITES do
		known = known or suite.name == name
	end
	if not known then
		print(`error: no suite named {name} — run with --list to see them`)
		process.exit(1)
	end
end

--=============================================================================
-- Run
--=============================================================================

local passed = 0
local failed = 0

for _, suite in SUITES do
	if selective and not only[suite.name] then
		continue
	end

	table.clear(output)
	local ok, result = pcall(suite.run)

	if ok then
		passed += 1
		print(`OK    {suite.name} — {result}`)
	else
		failed += 1
		print(`FAIL  {suite.name} — {firstLine(tostring(result))}`)
		-- The first line above is the assertion; the rest of a multi-line failure, and anything
		-- the module printed on its way down, belong under it.
		local rest = tostring(result):gsub("^[^\n]*\n?", ""):gsub("\nstack traceback:.*$", "")
		if rest ~= "" then
			print(rest)
		end
		for _, line in output do
			print(`      {line}`)
		end
	end
end

local function suites(count: number): string
	return count == 1 and "suite" or "suites"
end

print("")
if failed > 0 then
	print(`{failed} of {passed + failed} {suites(passed + failed)} failed`)
	process.exit(1)
end
print(`{passed} {suites(passed)} passed — no Studio needed for any of it.`)
