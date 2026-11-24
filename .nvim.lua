-- Project-local Neovim configuration for this Roblox project.
--
-- Neovim only reads this when 'exrc' is enabled, and then only after you trust the
-- file once (it prompts; or run :trust with the file open). Add to your own config:
--
--     vim.o.exrc = true
--
-- Everything here is scoped to this repo, so nothing leaks into your other projects
-- and nobody has to hand-edit their personal config to work on this one.
--
-- It wires up three things:
--   * luau-lsp, pointed at this repo's Roblox type definitions and sourcemap
--   * stylua as the formatter for .luau, using the repo's stylua.toml
--   * a sourcemap refresh, because luau-lsp resolves `require` through it
--
-- The binaries all come from rokit.toml (`make setup`), so the versions match CI.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local definitions = root .. "/.lsp/globalTypes.d.luau"
local documentation = root .. "/.lsp/api-docs.json"
local luaurc = root .. "/.luaurc"
local sourcemap = root .. "/sourcemap.json"
local project = root .. "/default.project.json"

--=============================================================================
-- Sourcemap
--=============================================================================

-- luau-lsp reads sourcemap.json to know that `src/shared/Config.luau` is
-- `ReplicatedStorage.Shared.Config` at runtime. Without a current one, every
-- `require(ReplicatedStorage.Shared.Config)` resolves to nothing and the whole
-- file types as `any` — which looks like the server being broken rather than a
-- stale file. It only goes stale when files are added, renamed or moved, so
-- regenerating on entry is enough for most sessions.
--
-- Async: it takes about a second, and blocking startup on it would be felt.
local function refreshSourcemap(notify)
	vim.system({ "rojo", "sourcemap", project, "--output", sourcemap }, { cwd = root }, function(result)
		if result.code ~= 0 then
			vim.schedule(function()
				vim.notify("sourcemap refresh failed:\n" .. (result.stderr or ""), vim.log.levels.WARN)
			end)
		elseif notify then
			vim.schedule(function()
				vim.notify("sourcemap refreshed", vim.log.levels.INFO)
			end)
		end
	end)
end

vim.api.nvim_create_user_command("SourcemapRefresh", function()
	refreshSourcemap(true)
end, { desc = "regenerate sourcemap.json for luau-lsp" })

refreshSourcemap(false)

-- A new or renamed file is exactly the case a stale sourcemap gets wrong, and it is
-- rare enough to rebuild on. Saving an existing file changes nothing about the tree.
vim.api.nvim_create_autocmd({ "BufNewFile", "BufFilePost" }, {
	group = vim.api.nvim_create_augroup("rojo-sourcemap", { clear = true }),
	pattern = root .. "/src/*",
	callback = function()
		refreshSourcemap(false)
	end,
})

--=============================================================================
-- Language server
--=============================================================================

if vim.fn.filereadable(definitions) == 0 or vim.fn.filereadable(documentation) == 0 then
	vim.notify(
		"Roblox type definitions are missing — run `make lsp-defs`.\n"
			.. "Until then luau-lsp will not know `workspace`, `Instance.new` or any service.",
		vim.log.levels.WARN
	)
end

-- Layered over the config nvim-lspconfig ships for luau_lsp, which already sets the
-- filetype and the base command. Passing the definitions on the command line rather
-- than through settings means the server has them before it handles the first
-- request, so there is no window where the whole Roblox API looks undefined.
vim.lsp.config("luau_lsp", {
	cmd = {
		"luau-lsp",
		"lsp",
		"--definitions=" .. definitions,
		"--docs=" .. documentation,
		"--base-luaurc=" .. luaurc,
	},
	-- Without this the server treats a .luau file 40 directories deep as its own
	-- workspace and never finds the sourcemap.
	root_markers = { "default.project.json", ".luaurc", ".git" },
	settings = {
		["luau-lsp"] = {
			platform = { type = "roblox" },
			sourcemap = {
				enabled = true,
				-- The server's own autogenerate is implemented by the VS Code
				-- client, not by the server, so in Neovim it does nothing. The
				-- refresh above is the replacement.
				autogenerate = false,
				rojoProjectFile = "default.project.json",
			},
			completion = {
				imports = { enabled = true },
			},
		},
	},
})

vim.lsp.enable("luau_lsp")

--=============================================================================
-- Formatting
--=============================================================================

-- Registered on first .luau buffer rather than at startup: conform is lazy-loaded on
-- BufWritePre, so requiring it here would either force it early or fail outright.
--
-- stylua finds this repo's stylua.toml by searching upward from the file, which is
-- what keeps a personal ~/.stylua.toml (commonly 2 spaces and single quotes) from
-- rewriting every line of a tab-indented, double-quoted codebase.
vim.api.nvim_create_autocmd("FileType", {
	group = vim.api.nvim_create_augroup("luau-format", { clear = true }),
	pattern = "luau",
	callback = function()
		local ok, conform = pcall(require, "conform")
		if ok then
			conform.formatters_by_ft.luau = { "stylua" }
		end
	end,
})
