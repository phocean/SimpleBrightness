PROJECT   = SimpleBrightness.xcodeproj
SCHEME    = SimpleBrightness
DERIVED   = build/DerivedData
APP       = $(DERIVED)/Build/Products/Release/SimpleBrightness.app
INSTALLED = /Applications/SimpleBrightness.app
BUNDLE_ID = com.jcbaptiste.SimpleBrightness

.PHONY: project build test install uninstall clean

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
