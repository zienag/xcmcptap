# Sourced by install/build/uninstall scripts. Resolves the active build
# variant and pulls identity values from BuildConfig/Identity.xcconfig
# through Xcode's own resolver (`xcodebuild -showBuildSettings`) —
# avoids having a hand-rolled xcconfig parser.
#
# Set XCMCPTAP_VARIANT=release to opt into the Release variant.
# Default is "debug" (local development).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${XCMCPTAP_VARIANT:-debug}"

case "$VARIANT" in
  debug)   CONFIGURATION="Debug" ;;
  release) CONFIGURATION="Release" ;;
  *) echo "Unknown XCMCPTAP_VARIANT: $VARIANT (use debug|release)" >&2; return 1 ;;
esac

# Generate the .xcodeproj if it doesn't exist yet — `-showBuildSettings`
# needs it. build.sh regenerates explicitly later; this is just a safety
# net for scripts sourced standalone (e.g. uninstall.sh).
if [ ! -e "$REPO_ROOT/XcodeMCPTap.xcodeproj" ]; then
  (cd "$REPO_ROOT" && xcodegen generate --quiet >/dev/null)
fi

_xcb_settings=$(xcodebuild -project "$REPO_ROOT/XcodeMCPTap.xcodeproj" \
  -target XcodeMCPTap -configuration "$CONFIGURATION" \
  -showBuildSettings 2>/dev/null)

_extract() {
  echo "$_xcb_settings" | awk -v key="$1" '
    {
      sub(/^[ \t]+/, "", $0)
      pos = index($0, " = ")
      if (pos == 0) next
      k = substr($0, 1, pos - 1)
      v = substr($0, pos + 3)
      if (k == key) { print v; exit }
    }
  '
}

SERVICE_NAME="$(_extract XCMCPTAP_SERVICE_NAME)"
PRODUCT_NAME="$(_extract XCMCPTAP_PRODUCT_NAME)"
SYMLINK_NAME="$(_extract XCMCPTAP_SYMLINK_NAME)"

if [ -z "$SERVICE_NAME" ] || [ -z "$PRODUCT_NAME" ] || [ -z "$SYMLINK_NAME" ]; then
  echo "Could not resolve identity values from BuildConfig/Identity.xcconfig" >&2
  echo "via 'xcodebuild -showBuildSettings -configuration $CONFIGURATION'." >&2
  return 1
fi

APP_NAME="$PRODUCT_NAME.app"
SIGN_IDENTITY="Developer ID Application: Alfred Zien (GU3RT64VWG)"
TEAM_ID="GU3RT64VWG"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME"
BUILD_DIR="$REPO_ROOT/.build/$CONFIGURATION"
APP_BUNDLE="$BUILD_DIR/$APP_NAME"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
CLIENT_LINK="$HOME/.local/bin/$SYMLINK_NAME"

export REPO_ROOT VARIANT CONFIGURATION SERVICE_NAME PRODUCT_NAME SYMLINK_NAME
export APP_NAME SIGN_IDENTITY TEAM_ID INSTALL_DIR APP_PATH BUILD_DIR APP_BUNDLE
export PLIST_PATH CLIENT_LINK
