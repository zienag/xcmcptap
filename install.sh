#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="XcodeMCPProxy.app"
INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME"
SIGN_IDENTITY="Developer ID Application: Alfred Zien (GU3RT64VWG)"
TEAM_ID="GU3RT64VWG"
NOTARIZE=${NOTARIZE:-true}
BUILD_DIR="$SCRIPT_DIR/.build/Release"

SERVICE_NAME="dev.multivibe.xcode-mcp-proxy"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
CLIENT_LINK="$HOME/.local/bin/xcode-mcp-client"

# --- Uninstall ---

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  rm -f "$CLIENT_LINK"
  rm -rf "$APP_PATH"
  echo "Done."
  exit 0
fi

# --- Build ---

echo "Generating Xcode project..."
xcodegen generate --spec "$SCRIPT_DIR/project.yml"

echo "Building XcodeMCPProxy..."
xcodebuild -project "$SCRIPT_DIR/XcodeMCPProxy.xcodeproj" \
  -scheme XcodeMCPProxy \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  2>&1

APP_BUNDLE="$BUILD_DIR/$APP_NAME"

echo "Verifying signature..."
codesign --verify --deep --strict "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || true

# --- Notarize ---

if [ "$NOTARIZE" = "true" ]; then
  echo "Submitting for notarization..."
  ZIP_PATH="$SCRIPT_DIR/.build/XcodeMCPProxy.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "notarytool" \
    --wait 2>&1 && NOTARIZED=true || NOTARIZED=false

  if [ "$NOTARIZED" = "true" ]; then
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"
  else
    echo ""
    echo "Notarization failed. To set up credentials, run:"
    echo "  xcrun notarytool store-credentials notarytool --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
    echo ""
    echo "Then re-run ./install.sh"
    echo "Or skip notarization: NOTARIZE=false ./install.sh"
    exit 1
  fi

  rm -f "$ZIP_PATH"
fi

# --- DMG ---

if [ "${1:-}" = "--dmg" ]; then
  echo "Creating DMG..."
  DMG_NAME="XcodeMCPProxy"
  DMG_STAGING="$SCRIPT_DIR/.build/dmg"
  DMG_TEMP="$SCRIPT_DIR/.build/${DMG_NAME}-rw.dmg"
  DMG_FINAL="$SCRIPT_DIR/.build/${DMG_NAME}.dmg"

  rm -rf "$DMG_STAGING" "$DMG_TEMP" "$DMG_FINAL"
  mkdir -p "$DMG_STAGING"
  cp -R "$APP_BUNDLE" "$DMG_STAGING/"
  ln -s /Applications "$DMG_STAGING/Applications"

  hdiutil create -srcfolder "$DMG_STAGING" -volname "$DMG_NAME" \
    -fs HFS+ -format UDRW -ov "$DMG_TEMP"

  MOUNT_POINT=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" \
    | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/' | head -1)

  osascript <<EOF
tell application "Finder"
  tell disk "$DMG_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {400, 200, 1000, 500}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 100
    set position of item "$APP_NAME" of container window to {150, 150}
    set position of item "Applications" of container window to {450, 150}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

  sync
  hdiutil detach "$MOUNT_POINT"
  hdiutil convert "$DMG_TEMP" -format UDZO -o "$DMG_FINAL"
  rm -f "$DMG_TEMP"
  rm -rf "$DMG_STAGING"

  codesign --force --sign "$SIGN_IDENTITY" "$DMG_FINAL"

  echo "DMG created: .build/${DMG_NAME}.dmg"
  exit 0
fi

# --- Install ---

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
cp -R "$APP_BUNDLE" "$APP_PATH"
echo "Installed $APP_NAME to $INSTALL_DIR"

# --- Register LaunchAgent ---

SERVICE_BIN="$APP_PATH/Contents/MacOS/xcode-mcp-service"
CLIENT_BIN="$APP_PATH/Contents/MacOS/xcode-mcp-client"
LOG_PATH="$HOME/Library/Logs/${SERVICE_NAME}.log"

launchctl bootout "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || true

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SERVICE_BIN}</string>
  </array>
  <key>MachServices</key>
  <dict>
    <key>${SERVICE_NAME}</key>
    <true/>
    <key>${SERVICE_NAME}.status</key>
    <true/>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart "gui/$(id -u)/${SERVICE_NAME}"

# Symlink client
mkdir -p "$(dirname "$CLIENT_LINK")"
rm -f "$CLIENT_LINK"
ln -s "$CLIENT_BIN" "$CLIENT_LINK"

CONFIG_CMD="claude mcp add --transport stdio xcode -- $CLIENT_LINK"
echo ""
echo "Service registered and started!"
echo "Configure Claude Code:"
echo "  $CONFIG_CMD"
