#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/_config.sh"

echo "Generating Xcode project..."
xcodegen generate --spec "$REPO_ROOT/project.yml"

echo "Building $APP_NAME..."
xcodebuild -project "$REPO_ROOT/XcodeMCPTap.xcodeproj" \
  -scheme XcodeMCPTap \
  -configuration Release \
  -skipMacroValidation \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID"

echo "Verifying signature..."
codesign --verify --deep --strict "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || true
