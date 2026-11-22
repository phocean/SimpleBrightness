#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Jean-Christophe Baptiste
#
# Builds the distributable SimpleBrightness: Release build signed with Developer ID
# (Hardened Runtime, secure timestamp, no entitlement at all), checked, packaged as a
# DMG, notarized and stapled. Run through make on the Mac that holds the Developer ID
# key: `make publish` (also tags and uploads), `make release` (DMG only) or `make dmg`
# (trial without notarization). Same procedure as the author's other apps.
#
# Environment:
#   VERSION            version shown to users, e.g. 0.1.0 (required)
#   BUILD_NUMBER       CFBundleVersion (default 1)
#   TEAM_ID            Apple developer team ID (required)
#   SIGN_IDENTITY      default "Developer ID Application"
#   Notarization, one of:
#     NOTARY_PROFILE                                   keychain profile (notarytool store-credentials)
#     NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER  App Store Connect API key (.p8)
#     SKIP_NOTARIZATION=1                              local trial: signed DMG, not notarized
#
# Output: build/release/SimpleBrightness-<VERSION>.dmg and its .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, e.g. 0.1.0}"
: "${TEAM_ID:?set TEAM_ID}"
BUILD_NUMBER=${BUILD_NUMBER:-1}
SIGN_IDENTITY=${SIGN_IDENTITY:-Developer ID Application}
OUT=build/release
APP=$OUT/DerivedData/Build/Products/Release/SimpleBrightness.app
DMG=$OUT/SimpleBrightness-$VERSION.dmg
fail() { echo "release: $*" >&2; exit 1; }
step() { echo "\n==> $*"; }

step "Generate the project"
command -v xcodegen >/dev/null || fail "xcodegen is required (brew install xcodegen)"
xcodegen generate --quiet
rm -rf "$OUT"; mkdir -p "$OUT"

step "Build Release $VERSION ($BUILD_NUMBER), signed by $SIGN_IDENTITY"
if ! xcodebuild -project SimpleBrightness.xcodeproj -scheme SimpleBrightness -configuration Release \
       -derivedDataPath "$OUT/DerivedData" \
       MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
       DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
       CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
       build > "$OUT/build.log" 2>&1; then
  grep -E "error:" "$OUT/build.log" | sort -u >&2 || true
  fail "build failed (log: $OUT/build.log)"
fi

step "Check the app before shipping it"
codesign --verify --strict --deep "$APP" || fail "signature does not verify"
SIG=$(codesign -dvv "$APP" 2>&1)
grep -q "^Authority=Developer ID Application" <<<"$SIG" || fail "not signed with a Developer ID Application certificate"
grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$SIG" || fail "not signed by team $TEAM_ID"
grep -q "^Timestamp=" <<<"$SIG" || fail "no secure timestamp"
grep -q "flags=.*runtime" <<<"$SIG" || fail "Hardened Runtime is off"
# No entitlement at all: in particular no get-task-allow (a debugger could then attach to
# a process that holds the Accessibility permission). Parsed, not matched as text.
ENT=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
if [[ -n $ENT ]]; then
  ENT_JSON=$(plutil -convert json -o - - <<<"$ENT")
  [[ $ENT_JSON == '{}' ]] || fail "the app must carry no entitlement: $ENT_JSON"
fi
INFO=$APP/Contents/Info.plist
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO") == "$VERSION" ]] || fail "version mismatch"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO") == "com.jcbaptiste.SimpleBrightness" ]] \
  || fail "wrong bundle identifier (a Debug build?)"
echo "ok: Developer ID ($TEAM_ID), timestamp, Hardened Runtime, no entitlement, version $VERSION"

step "Package the DMG"
STAGE=$OUT/dmg; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SimpleBrightness" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"

if [[ ${SKIP_NOTARIZATION:-0} == 1 ]]; then
  echo "\nSKIP_NOTARIZATION=1: $DMG is signed but NOT notarized (Gatekeeper will refuse it on another Mac)."
else
  step "Notarize"
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n ${NOTARY_KEY_PATH:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER:-} ]]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    fail "no notarization credentials (NOTARY_PROFILE, or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER, or SKIP_NOTARIZATION=1)"
  fi
  RESULT=$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json)
  echo "$RESULT"
  STATUS=$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$RESULT")
  if [[ $STATUS != Accepted ]]; then
    ID=$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$RESULT")
    [[ -n $ID ]] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    fail "notarization status: $STATUS"
  fi

  step "Staple and verify with Gatekeeper"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "\nDone: $DMG"
