APP_NAME    := Marple
BUILD_DIR   := .build
APP_BUNDLE  := $(APP_NAME).app
INSTALL_DIR := /Applications
DIST_DIR    := $(BUILD_DIR)/dist
DIST_DMG    := $(DIST_DIR)/$(APP_NAME).dmg
DMG_STAGING := $(BUILD_DIR)/dmg-staging

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
	./build-app.sh

run: build
	open $(APP_BUNDLE)

install: build
	@rm -rf "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"

# Release bundle (signed, hardened runtime) packaged into a signed DMG.
dist:
	CONFIG=release SIGN=1 VERSION=$(VERSION) \
		CODESIGN_IDENTITY="$(DEVELOPER_ID_IDENTITY)" ./build-app.sh
	@rm -rf "$(DIST_DIR)" "$(DMG_STAGING)"
	@mkdir -p "$(DIST_DIR)" "$(DMG_STAGING)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/$(APP_BUNDLE)"
	@ln -s /Applications "$(DMG_STAGING)/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DIST_DMG)" >/dev/null
	@codesign --force --sign "$(DEVELOPER_ID_IDENTITY)" --timestamp "$(DIST_DMG)"
	@echo "Packaged $(DIST_DMG)"

notarize: dist
	xcrun notarytool submit "$(DIST_DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DIST_DMG)"
	@echo "Notarized and stapled $(DIST_DMG)"

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
	url="https://github.com/giraphant/marple/releases/download/v$(VERSION)/$(APP_NAME).dmg"; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	echo "Cloning $(TAP_REPO)..."; \
	gh repo clone "$(TAP_REPO)" "$$tmp" -- -q || exit 1; \
	if [ ! -f "$$tmp/$(CASK_PATH)" ]; then \
		mkdir -p "$$tmp/Casks"; \
		printf 'cask "marple" do\n  version "%s"\n  sha256 "%s"\n\n  url "%s"\n  name "Marple"\n  desc "Native macOS reader for your knowledge vault"\n  homepage "https://github.com/giraphant/marple"\n\n  depends_on macos: ">= :sequoia"\n\n  app "Marple.app"\n  binary "#{appdir}/Marple.app/Contents/MacOS/marple-cli"\n\n  zap trash: [\n    "~/Library/Application Support/com.marple.app",\n    "~/Library/Preferences/com.marple.app.plist",\n  ]\nend\n' "$(VERSION)" "$$sha" "$$url" > "$$tmp/$(CASK_PATH)"; \
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

clean:
	rm -rf $(BUILD_DIR) $(APP_BUNDLE)
