PROJECT   = SimpleBrightness.xcodeproj
SCHEME    = SimpleBrightness
DERIVED   = build/DerivedData
APP       = $(DERIVED)/Build/Products/Release/SimpleBrightness.app
INSTALLED = /Applications/SimpleBrightness.app
BUNDLE_ID = com.jcbaptiste.SimpleBrightness

VERSION        ?= $(shell sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD_NUMBER   ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
TEAM_ID        ?= $(shell sed -n 's/^ *DEVELOPMENT_TEAM: *\([A-Z0-9]\{10\}\)$$/\1/p' project.yml | head -1)
# Keychain profile created once with `xcrun notarytool store-credentials` (docs/RELEASE.md).
NOTARY_PROFILE ?= studio-eq
TAG            := v$(VERSION)
DMG            := build/release/SimpleBrightness-$(VERSION).dmg
NOTES          := docs/releases/$(TAG).md

.PHONY: project build test install uninstall clean dmg release publish

# Regenerates the Xcode project from project.yml (requires XcodeGen).
project:
	xcodegen generate

# Release build, then a blocking gate: the signature must verify, and a
# distributed build must never carry get-task-allow. A codesign failure refuses
# the build; it is never read as "no entitlement".
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build
	@codesign --verify --strict "$(APP)" || { echo "codesign --verify failed: refusing" >&2; exit 1; }
	@ents=$$(codesign -d --entitlements - "$(APP)" 2>/dev/null) || { echo "codesign -d failed: refusing" >&2; exit 1; }; \
	if printf '%s' "$$ents" | grep -q get-task-allow; then echo "get-task-allow present: refusing" >&2; exit 1; fi

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) test

install: build
	-osascript -e 'quit app "SimpleBrightness"'
	ditto "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

# Full removal: login item (while the bundle still exists), app, preferences,
# Accessibility permission, local builds. A tccutil failure stops the recipe.
uninstall:
	-osascript -e 'quit app "SimpleBrightness"'
	@if [ -x "$(INSTALLED)/Contents/MacOS/SimpleBrightness" ]; then "$(INSTALLED)/Contents/MacOS/SimpleBrightness" --unregister-login-item; fi
	rm -rf "$(INSTALLED)"
	-defaults delete $(BUNDLE_ID) 2>/dev/null
	tccutil reset Accessibility $(BUNDLE_ID)
	rm -rf build

clean:
	rm -rf build

# Signed Developer ID DMG, checked but NOT notarized (local trial).
dmg:
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" TEAM_ID="$(TEAM_ID)" SKIP_NOTARIZATION=1 zsh scripts/release.sh

# Signed, checked, notarized and stapled DMG, not published. SKIP_NOTARIZATION=0 is
# forced: a SKIP_NOTARIZATION=1 left in the shell must never let an un-notarized DMG ship.
release:
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" TEAM_ID="$(TEAM_ID)" \
	  NOTARY_PROFILE="$(NOTARY_PROFILE)" SKIP_NOTARIZATION=0 zsh scripts/release.sh

# The DMG is built on this Mac: the Developer ID private key never leaves its keychain.
# The source must be committed and pushed first, so the published binary matches the
# published source (GPL). The tag (signed) is pushed only once the DMG is notarized,
# and removed again if the GitHub release cannot be created.
publish:
	@test -z "$$(git status --porcelain)" || { echo "publish: commit your changes first" >&2; exit 1; }
	@git fetch --quiet origin && test "$$(git rev-parse HEAD)" = "$$(git rev-parse @{u})" \
	  || { echo "publish: push the branch first, the release must match the published source" >&2; exit 1; }
	@! git ls-remote --exit-code --tags origin "refs/tags/$(TAG)" >/dev/null \
	  || { echo "publish: $(TAG) already exists on GitHub (bump MARKETING_VERSION in project.yml)" >&2; exit 1; }
	@test -f "$(NOTES)" || { echo "publish: write the release notes in $(NOTES) first" >&2; exit 1; }
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory release
	@git tag -s $(TAG) -m "SimpleBrightness $(VERSION)"
	@git push --quiet origin $(TAG) || { git tag -d $(TAG) >/dev/null; echo "publish: could not push $(TAG)" >&2; exit 1; }
	@gh release create $(TAG) $(DMG) $(DMG).sha256 --verify-tag --title "SimpleBrightness $(VERSION)" --notes-file "$(NOTES)" \
	  || { gh release delete $(TAG) --yes >/dev/null 2>&1; git push --quiet --delete origin $(TAG); git tag -d $(TAG) >/dev/null; \
	       echo "publish: GitHub release failed, $(TAG) removed (the notarized DMG is still in build/release)" >&2; exit 1; }
	@echo "Published $$(gh release view $(TAG) --json url -q .url)"
