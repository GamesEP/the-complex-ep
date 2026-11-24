# Development commands for this place.
#
# The repo is the source of truth: a place file is a build output, never a workspace.
# Everything here runs against default.project.json unless PROJECT is overridden.
#
# Run `make` or `make help` to list targets.

PROJECT ?= default.project.json

# Scratch place each developer syncs into. Gitignored — safe to delete and rebuild.
LOCAL_PLACE ?= local.rbxlx

# Project listing only the Workspace models Studio is allowed to write back to. It
# deliberately omits src/, so a syncback run can never rewrite a script.
SYNCBACK_PROJECT ?= syncback.project.json

# Place that syncback reads. Studio must have saved it to disk — an unsaved session
# is invisible to the CLI.
INPUT ?= $(LOCAL_PLACE)

# Artifact matching what CI builds, for checking a build without touching Studio.
BUILD_PLACE ?= game.rbxl

SOURCEMAP ?= sourcemap.json

# How the sourcemap is generated, in one place: it is built from two targets — `sourcemap` for
# the language server, and the Packages rule, where wally-package-types needs one before it can
# patch the type stubs — and two copies of the flags would drift the first time one changed.
#
# Deliberately *without* `--include-non-scripts`. That flag adds every part inside every model
# under assets/, so `make watch-sourcemap` would rewrite half a megabyte of crate positions on
# every save. The scripts are all present without it, which is what both consumers actually read.
SOURCEMAP_CMD = rojo sourcemap $(PROJECT) --output $(SOURCEMAP)

# Rojo's default. Override if you run two projects at once: make serve PORT=34873
PORT ?= 34872

.DEFAULT_GOAL := help
.PHONY: help setup plugin plugin-win dev serve place build packages sourcemap watch-sourcemap fmt check test test-list globals style style-check analyze lsp-defs clean upload sync-assets check-assets upload-asset syncback syncback-dry logs stamp

## help: List available targets
help:
	@echo "development commands"
	@echo ""
	@grep -E '^## [a-z-]+:' $(MAKEFILE_LIST) | sed 's/^## /  make /' | column -t -s ':'
	@echo ""
	@echo "First time?  make setup && make plugin && make dev"
	@echo "             (on Windows or macOS use 'make plugin-win')"

## setup: Install the toolchain pinned in rokit.toml
setup:
	@command -v rokit >/dev/null 2>&1 || { \
		echo "error: rokit is not installed."; \
		echo ""; \
		echo "Install it, then re-run 'make setup':"; \
		echo "  macOS/Linux:  curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash"; \
		echo "  Windows:      Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression"; \
		echo ""; \
		echo "See https://github.com/rojo-rbx/rokit for other install options (Cargo, manual binary)."; \
		exit 1; \
	}
	rokit install
	@$(MAKE) --no-print-directory packages

## plugin: Install the Rojo Studio plugin on Linux/Vinegar (once per machine)
plugin:
	./scripts/install-plugin.sh

## plugin-win: Install the Rojo Studio plugin on Windows or macOS (once per machine)
plugin-win:
	rojo plugin install

## dev: Build your scratch place, then serve it — the normal way to start work
dev: place
	@./scripts/sync-assets.sh --check >/dev/null 2>&1 || { \
		echo ""; \
		echo "Note: some files in assets/ are not on Roblox yet, so they will be silent."; \
		echo "      Run 'make check-assets' to see which, 'make sync-assets' to upload them."; \
	}
	@echo ""
	@echo "Open $(LOCAL_PLACE) in Studio, then connect the Rojo plugin to localhost:$(PORT)."
	@echo "Leave this running; edits on disk sync into Studio live."
	@echo ""
	@$(MAKE) --no-print-directory serve

## serve: Start the live-sync server (Studio pulls from disk)
serve: Packages
	rojo serve $(PROJECT) --port $(PORT)

## packages: Download the Wally dependencies into Packages/ and patch their types
##           Packages/ is a build output, gitignored and rebuilt from wally.lock, the same
##           way rokit.toml pins the toolchain. Every target that reads the project depends
##           on it: default.project.json mounts Packages at ReplicatedStorage.Packages, and
##           rojo will not build a project whose $path is missing.
packages: Packages

# A real file target rather than .PHONY, so a build only reinstalls when the manifest or the
# lock has actually moved.
#
# wally-package-types rewrites the one-line re-export stubs Wally leaves in Packages/ so
# luau-lsp can follow them to the types inside _Index. It reads a sourcemap, which is why one
# is built here — the same command `make sourcemap` runs, called directly rather than through
# the target so this does not depend on what it is a prerequisite of.
Packages: wally.toml wally.lock
	wally install
	$(SOURCEMAP_CMD)
	wally-package-types --sourcemap $(SOURCEMAP) Packages/
	@touch Packages

## place: Rebuild the local scratch place from scratch, discarding its contents
place: Packages
	rojo build $(PROJECT) --output $(LOCAL_PLACE)
	@echo "Built $(LOCAL_PLACE) — this file is disposable, rebuild it any time."

## build: Build the place the way CI does, to verify the project compiles
build: Packages
	rojo build $(PROJECT) --output $(BUILD_PLACE)

## sourcemap: Generate sourcemap.json for luau-lsp autocomplete
sourcemap: Packages
	$(SOURCEMAP_CMD)

## watch-sourcemap: Keep the sourcemap current as files are added or renamed
watch-sourcemap: Packages
	$(SOURCEMAP_CMD) --watch

## fmt: Reformat the project JSON to Rojo's canonical style
fmt:
	rojo fmt-project $(PROJECT)

## test: Run every check that does not need Studio — the syntax sweep and the self tests
##       Narrow it while iterating: make test ONLY=ui. `make test-list` names them all,
##       from the runner itself rather than a copy here that goes stale every time one is added.
test:
	lune run scripts/run-tests.luau $(if $(ONLY),--only $(ONLY))

## test-list: Name every suite `make test ONLY=` accepts
test-list:
	@lune run scripts/run-tests.luau --list

## style: Format every .luau file with stylua, per stylua.toml
style:
	stylua src scripts

## style-check: Report files stylua would reformat, changing nothing
style-check:
	stylua --check src scripts

## lsp-defs: Download the Roblox type definitions luau-lsp needs (once per machine)
lsp-defs:
	./scripts/fetch-luau-defs.sh

## analyze: Type-check against the Roblox API. Needs `make lsp-defs` first.
##          Not part of `make check`: a growing codebase accumulates type findings that are
##          not worth gating on, and the moment this fails for something nobody intends to fix
##          it stops being run at all. `make globals` is the part that can gate.
analyze: sourcemap
	@test -f .lsp/globalTypes.d.luau || { echo "error: run 'make lsp-defs' first"; exit 1; }
	luau-lsp analyze --sourcemap=$(SOURCEMAP) --definitions=.lsp/globalTypes.d.luau \
		--base-luaurc=.luaurc --platform=roblox src

## globals: Fail on any undefined global. Needs `make lsp-defs` first.
##          Narrower than `make analyze` on purpose, so it can gate while analyze cannot.
##          Nothing else catches this class — `rojo build` packs source without reading it and
##          the syntax sweep compiles without resolving names, so a require through a name
##          nobody bound builds clean, passes every suite, and takes the whole realm's
##          bootstrap down on the first frame of a real server.
globals: sourcemap
	@test -f .lsp/globalTypes.d.luau || { echo "error: run 'make lsp-defs' first"; exit 1; }
	@if luau-lsp analyze --sourcemap=$(SOURCEMAP) --definitions=.lsp/globalTypes.d.luau \
		--base-luaurc=.luaurc --platform=roblox src 2>&1 | grep "Unknown global"; then \
		echo "error: the globals above are bound nowhere — reading one gets nil, requiring through one throws"; \
		exit 1; \
	else \
		echo "OK — no undefined globals."; \
	fi

## check: What CI runs — the offline suites pass, no undefined globals, and the project builds
check: test globals build
	@echo "OK — $(PROJECT) builds."

## clean: Remove build outputs and scratch places
##        Leaves Packages/ alone on purpose: everything else here is regenerated from the
##        repo, and that one needs the network. Delete it by hand to force a reinstall.
clean:
	rm -f $(LOCAL_PLACE) $(BUILD_PLACE) $(SOURCEMAP) *.rbxlx.lock *.rbxl.lock

## sync-assets: Upload anything in assets/ that Roblox does not have, and record its id
##              Needs ROBLOX_API_KEY with the assets:write scope. CI does this on push.
sync-assets:
	./scripts/sync-assets.sh

## check-assets: Report assets that are missing from src/shared/core/Assets/AssetIds.json (no upload)
check-assets:
	./scripts/sync-assets.sh --check

## upload-asset: Upload one file and print its id, without touching the manifest
##               Usage: make upload-asset FILE=assets/click.ogg TYPE=Audio
upload-asset:
	@test -n "$(FILE)" || { echo "error: set FILE=<path>"; exit 1; }
	@test -n "$(TYPE)" || { echo "error: set TYPE=<Audio|Decal|Model>"; exit 1; }
	./scripts/upload-asset.sh "$(FILE)" "$(TYPE)"

## stamp: Write the current commit into the place, so a local session says which build it is
##        CI runs this before every publish; by hand it is for reproducing something a published
##        server reported. It modifies one tracked file and the stamp belongs to a build rather
##        than to the source, so put it back before committing:
##            git checkout src/shared/core/Build/BuildInfo.json
stamp:
	./scripts/stamp-build.sh

## logs: Read the published game's diagnostics ring buffer through Open Cloud
##       Roblox keeps no server log file — a published server's warnings never reach any
##       player's log and F9 only shows what is happening while you are standing in it. The
##       server writes its own buffer to a DataStore (features/telemetry/LogSink) and this
##       reads it back. Needs ROBLOX_API_KEY (with universe-datastores:read) and
##       ROBLOX_UNIVERSE_ID in the environment or in .env.
##       Usage: make logs                  newest server
##              make logs ARGS="--list"    every server key
##              make logs ARGS="--all"     every server's buffer
##              make logs ARGS="--raw"     the JSON, for jq
logs:
	./scripts/fetch-logs.sh $(ARGS)

## syncback-dry: Preview pulling geometry edited in Studio back to disk (writes nothing)
##               Save the place in Studio first. Defaults to INPUT=$(LOCAL_PLACE).
syncback-dry:
	@test -f "$(INPUT)" || { echo "error: $(INPUT) does not exist — save the place from Studio first"; exit 1; }
	rojo syncback $(SYNCBACK_PROJECT) --input $(INPUT) --list --dry-run

## syncback: Pull geometry edited in Studio back into assets/, then review the diff
##           Stop Play first, save the place, and expect a prompt before it writes.
syncback:
	@test -f "$(INPUT)" || { echo "error: $(INPUT) does not exist — save the place from Studio first"; exit 1; }
	rojo syncback $(SYNCBACK_PROJECT) --input $(INPUT)
	@echo ""
	@echo "Review before committing:  git diff assets/"

## upload: Publish by hand. Prefer pushing to staging/main and letting CI do it.
##         Needs ROBLOX_API_KEY, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID.
upload: Packages
	@test -n "$(ROBLOX_API_KEY)"     || { echo "error: ROBLOX_API_KEY not set";     exit 1; }
	@test -n "$(ROBLOX_UNIVERSE_ID)" || { echo "error: ROBLOX_UNIVERSE_ID not set"; exit 1; }
	@test -n "$(ROBLOX_PLACE_ID)"    || { echo "error: ROBLOX_PLACE_ID not set";    exit 1; }
	@echo "About to publish LIVE to place $(ROBLOX_PLACE_ID). Ctrl-C within 5s to abort."
	@sleep 5
	rojo upload $(PROJECT) \
		--api_key "$(ROBLOX_API_KEY)" \
		--universe_id "$(ROBLOX_UNIVERSE_ID)" \
		--asset_id "$(ROBLOX_PLACE_ID)"
