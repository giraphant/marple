APP_NAME    := Marple
BUILD_DIR   := .build
APP_BUNDLE  := $(APP_NAME).app
# Dev bundle lives off the iCloud-synced repo tree (QUA-199): the File Provider
# re-stamps com.apple.FinderInfo onto an in-repo .app, which breaks codesign.
# Must match the APP_DIR default in build-app.sh.
DEV_APP     := $(HOME)/Library/Caches/marple-dev/$(APP_BUNDLE)
INSTALL_DIR := /Applications
DIST_DIR    := $(BUILD_DIR)/dist
DIST_DMG    := $(DIST_DIR)/$(APP_NAME).dmg

# Marketing version comes from the VERSION file (single source of truth).
# Override on the CLI only to double-check: `make release VERSION=0.1.0`.
VERSION ?= $(shell cat VERSION)

# Homebrew tap that ships the cask, so users can `brew upgrade --cask marple`.
TAP_REPO  ?= giraphant/homebrew-tap
CASK_PATH := Casks/marple.rb

# Per-developer signing config lives in Makefile.local (gitignored) — the same
# DEVELOPER_ID_IDENTITY + NOTARY_PROFILE used for dousha. Without it, dev builds
# stay unsigned and `make release` aborts.
-include Makefile.local

DEVELOPER_ID_IDENTITY ?= Developer ID Application: <Your Name> (<TEAMID>)
NOTARY_PROFILE        ?= <YourNotaryProfile>

.PHONY: all build run install dist notarize release update-cask clean

all: build

# Dev build: debug, unsigned, self-symlinks marple-cli onto PATH (build-app.sh).
build:
	APP_DIR="$(DEV_APP)" ./build-app.sh

run: build
	open "$(DEV_APP)"

install: build
	@rm -rf "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@cp -R "$(DEV_APP)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"

# Release bundle (signed, hardened runtime) packaged into a signed DMG.
#
# The repo lives under ~/Documents, an iCloud File Provider mount that keeps
# re-stamping com.apple.FinderInfo onto any .app directory — which invalidates
# the signature and fails notarization. So we assemble, sign, and package the
# DMG entirely in a temp dir on the local volume (off iCloud), then copy only
# the finished DMG (a single file, immune to the FinderInfo problem) back.
dist:
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)"
	@work=$$(mktemp -d /tmp/marple-dist.XXXXXX); \
	staging="$$work/dmg"; mkdir -p "$$staging"; \
	CONFIG=release SIGN=1 VERSION=$(VERSION) APP_DIR="$$staging/$(APP_BUNDLE)" \
		CODESIGN_IDENTITY="$(DEVELOPER_ID_IDENTITY)" ./build-app.sh || exit 1; \
	ln -s /Applications "$$staging/Applications"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$staging" -ov -format UDZO "$$work/$(APP_NAME).dmg" >/dev/null; \
	codesign --force --sign "$(DEVELOPER_ID_IDENTITY)" --timestamp "$$work/$(APP_NAME).dmg"; \
	cp "$$work/$(APP_NAME).dmg" "$(DIST_DMG)"; \
	rm -rf "$$work"
	@echo "Packaged $(DIST_DMG)"

notarize:
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)"
	@work=$$(mktemp -d /tmp/marple-dist.XXXXXX); \
	set -e; \
	trap 'rm -rf "$$work"' EXIT; \
	staging="$$work/dmg"; mkdir -p "$$staging"; \
	CONFIG=release SIGN=1 VERSION=$(VERSION) APP_DIR="$$staging/$(APP_BUNDLE)" \
		CODESIGN_IDENTITY="$(DEVELOPER_ID_IDENTITY)" ./build-app.sh || exit 1; \
	ditto -c -k --keepParent "$$staging/$(APP_BUNDLE)" "$$work/$(APP_NAME).app.zip"; \
	xcrun notarytool submit "$$work/$(APP_NAME).app.zip" --keychain-profile "$(NOTARY_PROFILE)" --wait; \
	xcrun stapler staple "$$staging/$(APP_BUNDLE)"; \
	xcrun stapler validate "$$staging/$(APP_BUNDLE)"; \
	ln -s /Applications "$$staging/Applications"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$staging" -ov -format UDZO "$$work/$(APP_NAME).dmg" >/dev/null; \
	codesign --force --sign "$(DEVELOPER_ID_IDENTITY)" --timestamp "$$work/$(APP_NAME).dmg"; \
	xcrun notarytool submit "$$work/$(APP_NAME).dmg" --keychain-profile "$(NOTARY_PROFILE)" --wait; \
	xcrun stapler staple "$$work/$(APP_NAME).dmg"; \
	xcrun stapler validate "$$work/$(APP_NAME).dmg"; \
	cp -R "$$staging/$(APP_BUNDLE)" "$(DIST_DIR)/$(APP_BUNDLE)"; \
	cp "$$work/$(APP_NAME).dmg" "$(DIST_DMG)"
	@echo "Notarized and stapled app + DMG: $(DIST_DMG)"

# One-shot release: bump VERSION + commit first. Notarizes the DMG, publishes a
# GitHub release with the DMG attached (gh pushes the v$(VERSION) tag), and bumps
# the Homebrew cask.
release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=0.1.0"; exit 1; fi
	@file_v=$$(cat VERSION); \
	if [ "$$file_v" != "$(VERSION)" ]; then \
		echo "ERROR: VERSION file ($$file_v) != VERSION=$(VERSION). Bump the VERSION file first."; exit 1; \
	fi
	@if ! git diff-index --quiet HEAD --; then \
		echo "ERROR: working tree has uncommitted changes. Commit the version bump first."; exit 1; \
	fi
	@$(MAKE) notarize
	gh release create "v$(VERSION)" "$(DIST_DMG)" --title "v$(VERSION)" --generate-notes
	@echo "Release v$(VERSION) published."
	@$(MAKE) update-cask VERSION=$(VERSION)

# Bump (or create) the Homebrew cask in $(TAP_REPO) to $(VERSION) with the DMG's
# sha256. The cask installs Marple.app and symlinks the bundled marple-cli onto
# PATH. Idempotent: no-op if the cask already matches.
update-cask:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make update-cask VERSION=0.1.0"; exit 1; fi
	@if [ ! -f "$(DIST_DMG)" ]; then echo "ERROR: $(DIST_DMG) not found. Run 'make dist' first."; exit 1; fi
	@sha=$$(shasum -a 256 "$(DIST_DMG)" | awk '{print $$1}'); \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	echo "Cloning $(TAP_REPO)..."; \
	gh repo clone "$(TAP_REPO)" "$$tmp" -- -q || exit 1; \
	if [ ! -f "$$tmp/$(CASK_PATH)" ]; then \
		mkdir -p "$$tmp/Casks"; \
		printf 'cask "marple" do\n  version "%s"\n  sha256 "%s"\n\n  url "https://github.com/giraphant/marple/releases/download/v#{version}/$(APP_NAME).dmg"\n  name "Marple"\n  desc "Native macOS reader for your knowledge vault"\n  homepage "https://github.com/giraphant/marple"\n\n  depends_on macos: :sequoia\n\n  app "Marple.app"\n  binary "#{appdir}/Marple.app/Contents/MacOS/marple-cli"\n\n  zap trash: [\n    "~/Library/Application Support/com.marple.app",\n    "~/Library/Preferences/com.marple.app.plist",\n  ]\nend\n' "$(VERSION)" "$$sha" > "$$tmp/$(CASK_PATH)"; \
	else \
		sed -i '' -E "s|^  version \".*\"|  version \"$(VERSION)\"|" "$$tmp/$(CASK_PATH)"; \
		sed -i '' -E "s|^  sha256 \".*\"|  sha256 \"$$sha\"|" "$$tmp/$(CASK_PATH)"; \
	fi; \
	git -C "$$tmp" add "$(CASK_PATH)"; \
	if git -C "$$tmp" diff --cached --quiet; then \
		echo "Cask already at $(VERSION) / $$sha — nothing to push."; \
	else \
		git -C "$$tmp" commit -q -m "marple $(VERSION)"; \
		git -C "$$tmp" push -q origin HEAD; \
		echo "Cask bumped to $(VERSION) ($$sha) and pushed to $(TAP_REPO)."; \
	fi

# $(APP_BUNDLE) sweeps up stale in-tree bundles from before QUA-199.
clean:
	rm -rf $(BUILD_DIR) $(APP_BUNDLE) "$(DEV_APP)"
