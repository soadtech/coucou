#!/usr/bin/env bash
# Signs the Debug build with a stable development identity.
#
# Xcode signs Debug ad-hoc, and macOS ties TCC grants (Screen Recording,
# Microphone) to the binary's hash when there is no team — so every rebuild
# looks like a brand-new app and the permissions have to be granted again.
# Signing with a real development certificate keeps the grant across builds.
#
# Picks the first "Apple Development" identity in the keychain; nothing
# personal is committed. Override with: SIGN_IDENTITY="..." scripts/sign-debug.sh
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
  APP="$(xcodebuild -scheme NotchBuddy -configuration Debug -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')/Coucou.app"
fi
[ -d "$APP" ] || { echo "No Debug build found at: $APP" >&2; exit 1; }

# The identity must stay the SAME across builds: TCC keys the grant to it, so
# switching certificates looks like a different app and the permissions reset.
# The first choice is remembered in .sign-identity (gitignored).
PINNED="$(dirname "$0")/../.sign-identity"
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f "$PINNED" ]; then
  IDENTITY=$(cat "$PINNED")
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
             | awk '/Apple Development/{print $2; exit}')
  [ -n "$IDENTITY" ] && echo "$IDENTITY" > "$PINNED"
fi
[ -n "$IDENTITY" ] || { echo "No 'Apple Development' identity in the keychain." >&2; exit 1; }

# Nested code first, then the bundle.
find "$APP/Contents" -name "*.dylib" -type f -print0 \
  | xargs -0 -I{} codesign --force --sign "$IDENTITY" --timestamp=none {}
codesign --force --sign "$IDENTITY" --timestamp=none --options runtime "$APP"

codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|TeamIdentifier=|Authority=Apple Development" || true
echo "Signed. If macOS still asks for permissions, remove the stale Coucou"
echo "entries in System Settings > Privacy & Security and grant them once more."
