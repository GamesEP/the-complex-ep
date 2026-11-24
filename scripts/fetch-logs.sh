#!/usr/bin/env bash
# Pulls the diagnostics ring buffer out of a published game and prints it.
#
# Roblox gives you no server log file. A published server's `print` and `warn` never reach any
# player's log — the server runs on Roblox's machines — and F9 only shows you what is happening
# while you happen to be standing in the game. So the server keeps its own ring buffer in a
# DataStore (src/server/features/telemetry/LogSink.luau) and this reads it back out through
# Open Cloud, which is the one door into a live universe that does not involve being in it.
#
# One key per server, so listing the keys is listing the servers that have faulted.
#
#   make logs                  the newest server's buffer
#   make logs ARGS="--list"    every server key, newest first
#   make logs ARGS="--all"     every server's buffer
#   make logs ARGS="--key server_abc123"
#   make logs ARGS="--raw"     the JSON, for jq
#
# Credentials come from the environment, the same two the publish workflow uses:
#
#   ROBLOX_API_KEY        an Open Cloud key with **universe-datastores:read**
#   ROBLOX_UNIVERSE_ID    the universe the place belongs to
#
# The publish key is scoped `universe-places:write` and will get a 403 here — add the datastore
# read scope to it, or make a second key. Keep it out of the repo: export it from your shell, or
# put it in .env, which is gitignored and sourced below if present.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

STORE="${DIAG_STORE:-Diagnostics}"
PREFIX="${DIAG_PREFIX:-server_}"
API="https://apis.roblox.com/datastores/v1/universes"

MODE=newest
KEY=""
RAW=0
while [ $# -gt 0 ]; do
	case "$1" in
		--list) MODE=list; shift ;;
		--all) MODE=all; shift ;;
		--key) MODE=key; KEY="${2:?--key needs a key}"; shift 2 ;;
		--raw) RAW=1; shift ;;
		-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

missing=""
[ -z "${ROBLOX_API_KEY:-}" ] && missing="$missing ROBLOX_API_KEY"
[ -z "${ROBLOX_UNIVERSE_ID:-}" ] && missing="$missing ROBLOX_UNIVERSE_ID"
if [ -n "$missing" ]; then
	echo "error: missing in the environment:$missing" >&2
	echo "       export them, or put them in .env (gitignored). The key needs the" >&2
	echo "       universe-datastores:read scope — the publish key only has places:write." >&2
	exit 1
fi

# Open Cloud answers 403 for both "wrong key" and "right key, missing scope", so the message
# says which one to check rather than guessing.
api() {
	local url="$1" body code
	body="$(curl -sS -w '\n%{http_code}' -H "x-api-key: $ROBLOX_API_KEY" "$url")"
	code="${body##*$'\n'}"
	body="${body%$'\n'*}"
	if [ "$code" != "200" ]; then
		echo "error: Open Cloud returned $code" >&2
		echo "$body" >&2
		[ "$code" = "403" ] && echo "hint: the key needs the universe-datastores:read scope on universe $ROBLOX_UNIVERSE_ID" >&2
		[ "$code" = "404" ] && echo "hint: no '$STORE' datastore yet — nothing has faulted, or the place has not run since LogSink shipped" >&2
		exit 1
	fi
	printf '%s' "$body"
}

list_keys() {
	api "$API/$ROBLOX_UNIVERSE_ID/standard-datastores/datastore/entries?datastoreName=$STORE&prefix=$PREFIX&limit=100" \
		| python3 -c 'import json,sys; [print(k["key"]) for k in json.load(sys.stdin).get("keys",[])]'
}

get_key() {
	api "$API/$ROBLOX_UNIVERSE_ID/standard-datastores/datastore/entries/entry?datastoreName=$STORE&entryKey=$1"
}

# $1 = key, $2 = file holding the entry. The payload comes from a file rather than a pipe
# because the program itself arrives on stdin through the heredoc — a piped payload would be
# swallowed by it and every render would see an empty document.
render() {
	python3 - "$1" "$2" <<'PY'
import json, sys, datetime

key = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as fh:
    d = json.load(fh)
when = lambda t: datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S") if t else "?"

print(f"\n=== {key} " + "=" * max(0, 60 - len(key)))
print(f"  place {d.get('place')} v{d.get('version')}  studio={d.get('studio')}  "
      f"players={d.get('players')}")
# Which universe and which commit. PlaceVersion counts publishes and maps to no source, so
# these are what tie a fault to a diff - see docs/environments.md.
print(f"  {d.get('environment', '?')}  {d.get('branch', '?')} {d.get('commit', '?')}")
print(f"  up since {when(d.get('started'))}, written {when(d.get('wrote'))}")

causes = d.get("causes") or []
if causes:
    print(f"\n  distinct causes ({len(causes)}), worst first:")
    for c in sorted(causes, key=lambda c: -c.get("count", 0)):
        print(f"    {c.get('count'):>7} x  {c.get('key')}")
        if c.get("fields"):
            print(f"              {c['fields']}")
        if c.get("detail"):
            print(f"              {c['detail']}")
else:
    print("\n  no faults recorded")

tail = d.get("tail") or []
if tail:
    print(f"\n  tail ({len(tail)} newest):")
    for e in tail:
        mark = {"error": "E", "warn": "W", "fault": "F"}.get(e.get("kind"), "?")
        label = f"{e.get('area')}/{e.get('code')}" if e.get("kind") == "fault" else ""
        n = f" (x{e['count']})" if e.get("count", 1) > 1 else ""
        print(f"    {when(e.get('t'))} {mark} {label}{n} {e.get('detail','')}")
        if e.get("fields"):
            print(f"        {e['fields']}")
PY
}

case "$MODE" in
	list)
		list_keys
		;;
	key|newest|all)
		if [ "$MODE" = "key" ]; then
			keys="$KEY"
		else
			keys="$(list_keys)"
			[ -z "$keys" ] && { echo "no diagnostics keys under '$PREFIX' — nothing has faulted yet"; exit 0; }
			[ "$MODE" = "newest" ] && keys="$(printf '%s\n' "$keys" | head -1)"
		fi
		tmp="$(mktemp)"
		trap 'rm -f "$tmp"' EXIT
		for k in $keys; do
			get_key "$k" > "$tmp"
			if [ "$RAW" = "1" ]; then
				cat "$tmp"; echo
			else
				render "$k" "$tmp"
			fi
		done
		;;
esac
