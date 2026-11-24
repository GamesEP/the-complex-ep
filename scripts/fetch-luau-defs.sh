#!/usr/bin/env bash
# Downloads the Roblox type definitions and API documentation luau-lsp needs.
#
# luau-lsp knows the Luau language on its own, but nothing about Roblox — without
# these, `workspace`, `Instance.new` and every service are unknown globals and the
# editor is little more than a syntax highlighter.
#
# They land in .lsp/, which is gitignored: together they are about 8 MB, they are
# generated artifacts, and they track Roblox's weekly releases rather than this
# repo. Re-run whenever the API you are calling is newer than your definitions.
#
#   ./scripts/fetch-luau-defs.sh      (or: make lsp-defs)
set -euo pipefail

cd "$(dirname "$0")/.."

DEST=.lsp

# globalTypes.d.luau is generated from the API dump at the security level a normal
# game script runs at — the PluginSecurity variant would also offer methods our
# code is not allowed to call, and would report no error when we called them.
TYPES_URL="https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"

# Hover documentation for the same API. Maintained alongside the client release,
# so it is a separate download from a separate repo.
DOCS_URL="https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/api-docs/en-us.json"

mkdir -p "$DEST"

fetch() {
	local url="$1" dest="$2" tmp
	tmp="$(mktemp)"

	echo "Fetching $(basename "$dest")..."
	if ! curl -fsSL "$url" -o "$tmp"; then
		rm -f "$tmp"
		echo "error: could not download $url" >&2
		return 1
	fi

	# A truncated or HTML error page written over a good file is worse than no
	# file: luau-lsp would load it, report nonsense, and give no clue why.
	if [ ! -s "$tmp" ]; then
		rm -f "$tmp"
		echo "error: $url returned an empty file" >&2
		return 1
	fi

	mv "$tmp" "$dest"
	echo "  $dest ($(du -h "$dest" | cut -f1))"
}

fetch "$TYPES_URL" "$DEST/globalTypes.d.luau"
fetch "$DOCS_URL" "$DEST/api-docs.json"

echo ""
echo "Done. Restart the language server to pick them up (:LspRestart in Neovim)."
