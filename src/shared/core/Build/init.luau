local Info = require(script.BuildInfo)

--[[
	Which build this is.

	Roblox will not tell you. A place has a `PlaceVersion`, which counts publishes and maps to no
	commit you can check out; there is no "what is deployed" page. So the commit is packed into
	the build by `scripts/stamp-build.sh`, which CI runs immediately before `rojo upload`.

	It earns its keep three times over: `make logs` says which build faulted, the dev universe
	wears its label on screen so a bug report cannot come from the environment nobody meant, and
	"is the fix in?" stops being a guess. See docs/environments.md#what-is-live.

	Unstamped is a real state — a local `make dev` has no stamp unless somebody ran `make stamp` —
	and everything here reads as "unknown" rather than pretending.
]]

local Build = {}

Build.COMMIT = Info.commit or "unknown"
Build.BRANCH = Info.branch or "unknown"
Build.BUILT_AT = Info.builtAt or ""
-- True when the tree had uncommitted changes at stamp time, which only a local `make stamp` can
-- produce. A stamp from a dirty tree names a commit whose source is not what is running.
Build.DIRTY = Info.dirty == true
-- The CI run, for finding the workflow log that produced this build. Empty outside CI.
Build.RUN = Info.run or ""

Build.SHORT = if #Build.COMMIT >= 7 then Build.COMMIT:sub(1, 7) else Build.COMMIT

function Build.isStamped(): boolean
	return Build.COMMIT ~= "unknown" and Build.COMMIT ~= ""
end

-- One line, for a console print, a watermark or a telemetry field.
function Build.label(): string
	if not Build.isStamped() then
		return "unstamped build"
	end
	return `{Build.BRANCH} {Build.SHORT}{if Build.DIRTY then "+dirty" else ""}`
end

return Build
