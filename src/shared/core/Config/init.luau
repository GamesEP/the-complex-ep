--[[
	One flat table, assembled from the parts in this folder. Every part owns one subject and
	returns plain `Config.KEY = value` assignments; this merges them and refuses a key defined
	twice, so `Config.MOVE_SPEED` reads the same however many files the tunables are spread
	across while each file stays small enough to find things in.

	Adding a subject is a new file next to these and a new line in PARTS. Nothing else in the
	codebase changes, because nothing else knows the folder exists.

	The rule that makes this worth doing: **a number that decides how the game feels lives
	here, not in the module that reads it.** A feature module should be behaviour; the values
	it is tuned with should be findable without knowing which feature owns them.
]]

local PARTS = {
	"Animations",
	"Audio",
	"Classes",
	"Combat",
	"Diagnostics",
	"Difficulty",
	"Drops",
	"Enemies",
	"Environments",
	"Flags",
	"Net",
	"Screen",
	"Tonemapping",
	"World",
}

local Config = {}

for _, name in ipairs(PARTS) do
	for key, value in pairs(require(script[name])) do
		if Config[key] ~= nil then
			error(`Config.{key} is defined by two parts`)
		end
		Config[key] = value
	end
end

return Config
