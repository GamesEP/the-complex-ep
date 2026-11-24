#!/usr/bin/env bash
# Upload anything in assets/ that Roblox does not have yet, and record its id.
#
#   ./scripts/sync-assets.sh          upload what is missing or changed
#   ./scripts/sync-assets.sh --check  report what is out of sync, upload nothing
#
# src/shared/core/Assets/AssetIds.json is the record of what has been uploaded: file name -> asset id
# plus the hash of the bytes that were sent. Rojo turns that file into a ModuleScript, so
# the game reads the ids straight from it and nobody pastes numbers by hand.
#
# Uploading needs ROBLOX_API_KEY with the assets:write scope. --check needs nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

ASSET_DIR=assets
MANIFEST=src/shared/core/Assets/AssetIds.json

check_only=false
[ "${1:-}" = "--check" ] && check_only=true

[ -d "$ASSET_DIR" ] || { echo "no $ASSET_DIR directory, nothing to do"; exit 0; }
[ -f "$MANIFEST" ] || echo '{}' > "$MANIFEST"

asset_type_for() {
	case "${1##*.}" in
		mp3|ogg) echo Audio ;;
		png|jpg|jpeg) echo Decal ;;
		fbx) echo Model ;;
		*) echo "" ;;
	esac
}

pending=0
uploaded=0
rejected=0

for file in "$ASSET_DIR"/*; do
	[ -f "$file" ] || continue
	name=$(basename "$file")
	type=$(asset_type_for "$name")
	if [ -z "$type" ]; then
		case "${name##*.}" in
			wav|flac|m4a|aac)
				# Roblox takes mp3 and ogg only, so a wav is a dead file in this folder.
				echo "cannot upload $name: Roblox accepts mp3 and ogg audio only. Convert it:"
				echo "    ffmpeg -i $ASSET_DIR/$name -c:a libvorbis -q:a 5 $ASSET_DIR/${name%.*}.ogg"
				echo "    rm $ASSET_DIR/$name"
				rejected=$((rejected + 1))
				;;
			*) echo "skipping $name: not a media file" ;;
		esac
		continue
	fi

	hash=$(sha256sum "$file" | cut -d' ' -f1)
	known=$(python3 -c "
import json,sys
m = json.load(open('$MANIFEST'))
entry = m.get('$name')
print(entry['sha256'] if entry and 'sha256' in entry else '')
")

	if [ "$known" = "$hash" ]; then
		continue
	fi

	pending=$((pending + 1))
	if [ -z "$known" ]; then
		echo "missing on Roblox: $name"
	else
		echo "changed since upload: $name"
	fi

	if [ "$check_only" = true ]; then
		continue
	fi

	# A changed file becomes a new asset rather than an in-place update: Open Cloud does not
	# update audio content, and a new id is cheaper than a silently stale sound.
	id=$(./scripts/upload-asset.sh "$file" "$type")
	python3 -c "
import json
m = json.load(open('$MANIFEST'))
m['$name'] = {'assetId': '$id', 'sha256': '$hash', 'type': '$type'}
json.dump(dict(sorted(m.items())), open('$MANIFEST', 'w'), indent=2)
open('$MANIFEST', 'a').write('\n')
"
	echo "uploaded $name -> $id"
	uploaded=$((uploaded + 1))
done

if [ "$rejected" -gt 0 ]; then
	echo "$rejected file(s) in $ASSET_DIR are in a format Roblox will not take"
	exit 1
fi

if [ "$check_only" = true ]; then
	if [ "$pending" -gt 0 ]; then
		echo "$pending asset(s) not on Roblox yet. Run: make sync-assets"
		exit 1
	fi
	echo "all assets are in $MANIFEST"
	exit 0
fi

echo "synced $uploaded asset(s)"
