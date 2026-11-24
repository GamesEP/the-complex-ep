#!/usr/bin/env bash
# Installs the Rojo Studio plugin on Linux, matching the version pinned in rokit.toml.
#
# `rojo plugin install` only knows about Windows and macOS — on Linux it exits with
# "Your platform is not currently supported" and writes nothing. Studio on Linux runs
# under Wine (Vinegar), so the plugin has to be dropped into the Wine prefix by hand.
#
# Run this with `make plugin`. On Windows and macOS use `make plugin-win` instead.
# Override the destination with PLUGINS_DIR=/path/to/Plugins if your setup is unusual.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep the plugin and the CLI on the same version — a mismatch shows up as a protocol
# warning in Studio.
version="$(sed -n 's/^rojo *= *"rojo-rbx\/rojo@\(.*\)"/\1/p' "$repo_root/rokit.toml")"
if [ -z "$version" ]; then
	echo "error: could not read the rojo version from rokit.toml" >&2
	exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
	echo "error: this script installs into a Wine prefix and is Linux-only." >&2
	echo "On Windows or macOS run 'make plugin-win' instead." >&2
	exit 1
fi

echo "Installing the Rojo $version plugin into the Wine prefix..."

find_plugins_dir() {
	if [ -n "${PLUGINS_DIR:-}" ]; then
		printf '%s\n' "$PLUGINS_DIR"
		return
	fi
	# Vinegar as a Flatpak, Vinegar installed natively, then anything else that looks
	# like a Studio Wine prefix. First match wins.
	local root found
	for root in \
		"$HOME/.var/app/org.vinegarhq.Vinegar/data/vinegar" \
		"$HOME/.local/share/vinegar" \
		"$HOME/.var/app/org.vinegarhq.Vinegar/data"; do
		[ -d "$root" ] || continue
		# No `| head` here: it would SIGPIPE find and trip `set -o pipefail`.
		found="$(find "$root" -maxdepth 10 -type d \
			-path '*/drive_c/users/*/AppData/Local/Roblox/Plugins' 2>/dev/null || true)"
		if [ -n "$found" ]; then
			printf '%s\n' "${found%%$'\n'*}"
			return 0
		fi
	done

	# Plugins doesn't exist yet — Studio creates it lazily on first launch. Fall back
	# to the Wine user profile dir, which is created as soon as the prefix itself is
	# (by Vinegar/wineboot), and let the caller mkdir -p the rest onto it.
	for root in \
		"$HOME/.var/app/org.vinegarhq.Vinegar/data/vinegar" \
		"$HOME/.local/share/vinegar" \
		"$HOME/.var/app/org.vinegarhq.Vinegar/data"; do
		[ -d "$root" ] || continue
		found="$(find "$root" -maxdepth 6 -type d \
			-path '*/drive_c/users/*' -not -path '*/drive_c/users/*/*' 2>/dev/null || true)"
		if [ -n "$found" ]; then
			printf '%s\n' "${found%%$'\n'*}/AppData/Local/Roblox/Plugins"
			return 0
		fi
	done
}

plugins_dir="$(find_plugins_dir)"

if [ -z "$plugins_dir" ]; then
	cat >&2 <<EOF

error: could not find a Roblox Studio Wine prefix.

Vinegar has to have set up its prefix at least once. If it exists somewhere unusual,
pass the plugins folder explicitly:

  PLUGINS_DIR=~/path/to/drive_c/users/\$USER/AppData/Local/Roblox/Plugins make plugin

Or install by hand: download
  https://github.com/rojo-rbx/rojo/releases/download/v$version/Rojo.rbxm
and drop it in that folder.
EOF
	exit 1
fi

mkdir -p "$plugins_dir"

url="https://github.com/rojo-rbx/rojo/releases/download/v$version/Rojo.rbxm"
dest="$plugins_dir/Rojo.rbxm"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Downloading Rojo $version plugin..."
if command -v curl >/dev/null 2>&1; then
	curl -fsSL "$url" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
	wget -qO "$tmp" "$url"
else
	echo "error: need curl or wget to download the plugin" >&2
	exit 1
fi

# A 404 or an HTML error page would otherwise be written out as a "plugin".
if [ ! -s "$tmp" ]; then
	echo "error: downloaded an empty file from $url" >&2
	exit 1
fi
case "$(head -c 8 "$tmp")" in
"<roblox"* | *"roblox"*) ;;
*)
	echo "error: $url did not return a Roblox model file" >&2
	exit 1
	;;
esac

install -m 644 "$tmp" "$dest"
echo "Installed Rojo $version plugin to:"
echo "  $dest"
echo ""
echo "Restart Roblox Studio — plugins are only loaded at startup."
