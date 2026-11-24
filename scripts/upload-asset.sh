#!/usr/bin/env bash
# Upload a local file to Roblox through the Open Cloud Assets API and print its asset id.
#
# Roblox only plays audio and shows images that live on its CDN, and Rojo does not sync
# binary media, so anything in assets/ has to be uploaded once and then referenced by id.
#
#   ROBLOX_API_KEY=... ROBLOX_CREATOR_ID=... ./scripts/upload-asset.sh assets/single-shot.mp3 Audio
#
# The key needs the assets:write scope — that is a separate permission from the
# universe-places:write one that publishes the place, so add it in the same key or make
# a second key at create.roblox.com/dashboard/credentials.
#
# ROBLOX_CREATOR_TYPE defaults to Group. Upload to whoever owns the experience: audio
# uploaded by a user account is private to that account and stays silent in a group's
# game, which looks exactly like a bug in the code.
set -euo pipefail

file=${1:-}
asset_type=${2:-}
display_name=${3:-}

if [ -z "$file" ] || [ -z "$asset_type" ]; then
	echo "usage: $0 <file> <Audio|Decal|Model> [displayName]" >&2
	exit 1
fi
[ -f "$file" ] || { echo "error: no such file: $file" >&2; exit 1; }

: "${ROBLOX_API_KEY:?set ROBLOX_API_KEY (needs the assets:write scope)}"

# VultGames, the group that owns both the prod and the dev experience. The default lives
# here rather than in the Makefile because CI calls this script directly.
creator_id=${ROBLOX_CREATOR_ID:-858453754}
creator_type=${ROBLOX_CREATOR_TYPE:-Group}
display_name=${display_name:-$(basename "${file%.*}")}

case "$creator_type" in
	Group) creator="{\"groupId\":\"$creator_id\"}" ;;
	User)  creator="{\"userId\":\"$creator_id\"}" ;;
	*) echo "error: ROBLOX_CREATOR_TYPE must be Group or User" >&2; exit 1 ;;
esac

case "${file##*.}" in
	mp3) mime="audio/mpeg" ;;
	ogg) mime="audio/ogg" ;;
	png) mime="image/png" ;;
	jpg|jpeg) mime="image/jpeg" ;;
	fbx) mime="model/fbx" ;;
	*) echo "error: unsupported file type: ${file##*.}" >&2; exit 1 ;;
esac

request=$(printf '{"assetType":"%s","displayName":"%s","description":"game asset","creationContext":{"creator":%s}}' \
	"$asset_type" "$display_name" "$creator")

echo "uploading $file as $asset_type to $creator_type $creator_id..." >&2
started=$(curl -sS -X POST "https://apis.roblox.com/assets/v1/assets" \
	-H "x-api-key: $ROBLOX_API_KEY" \
	-F "request=$request;type=application/json" \
	-F "fileContent=@$file;type=$mime")

# `|| true` on every extraction: pipefail turns a grep that matches nothing into an abort,
# which would kill the script before it could report what Roblox actually said.
operation=$(printf '%s' "$started" | grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\(operations\/[^"]*\)"/\1/' || true)
if [ -z "$operation" ]; then
	echo "error: upload rejected: $started" >&2
	exit 1
fi

# The upload returns an operation, not the asset: Roblox moderates media before it exists.
for _ in $(seq 1 30); do
	sleep 2
	result=$(curl -sS "https://apis.roblox.com/assets/v1/$operation" -H "x-api-key: $ROBLOX_API_KEY")
	asset_id=$(printf '%s' "$result" | grep -o '"assetId"[[:space:]]*:[[:space:]]*"\?[0-9]*' | grep -o '[0-9]*$' | head -1 || true)
	if [ -n "$asset_id" ]; then
		echo "$asset_id"
		exit 0
	fi
	case "$result" in
		*'"error"'*|*'"code"'*) echo "error: $result" >&2; exit 1 ;;
	esac
done

echo "error: still processing after 60s. Check create.roblox.com/dashboard/creations" >&2
exit 1
