#!/usr/bin/env bash
# Writes src/shared/core/Build/BuildInfo.json from git, so a running server can say which
# commit it is.
#
# Roblox tells you almost nothing about what is live: a place has a PlaceVersion, which is a
# number that counts publishes and maps to no commit you can check out. Without a stamp, "is the
# fix in?" is answered by guessing, and a bug report from the dev universe reads exactly like one
# from production.
#
# CI runs this immediately before `rojo upload`, after the asset-id commit, so the stamp never
# lands in a commit — it is a property of a build, not of the source. Run it by hand with
# `make stamp` to give a local Studio session the same label.
#
# See docs/environments.md#what-is-live.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="src/shared/core/Build/BuildInfo.json"

# GITHUB_* when CI is calling, git when a developer is. In CI the checkout is detached, so
# `rev-parse --abbrev-ref HEAD` would answer "HEAD" rather than the branch being published.
COMMIT="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
RUN="${GITHUB_RUN_ID:-}"

# A local build from a dirty tree is not the commit it claims to be, and saying so is the
# difference between a stamp you can trust and one that is usually right.
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
	DIRTY="true"
else
	DIRTY="false"
fi

BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<JSON
{
  "commit": "$COMMIT",
  "branch": "$BRANCH",
  "builtAt": "$BUILT_AT",
  "dirty": $DIRTY,
  "run": "$RUN"
}
JSON

if [ "$DIRTY" = true ]; then
	echo "stamped $OUT: ${COMMIT:0:7} on $BRANCH (dirty tree — the stamp is not this commit)"
else
	echo "stamped $OUT: ${COMMIT:0:7} on $BRANCH"
fi

echo "This file is committed as a placeholder and CI rewrites it per publish; put it back with"
echo "  git checkout $OUT"
