#!/bin/bash
set -euo pipefail

# Regenerate the Xcode project first, before sourcing _config.sh —
# _config.sh queries the project for identity values via xcodebuild.
echo "Generating Xcode project..."
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
xcodegen generate --spec "$REPO_ROOT/project.yml"

source "$(dirname "$0")/_config.sh"

echo "Building $APP_NAME ($CONFIGURATION)..."

xcodebuild_args=(
  -project "$REPO_ROOT/XcodeMCPTap.xcodeproj"
  -scheme XcodeMCPTap
  -configuration "$CONFIGURATION"
  -skipMacroValidation
  CONFIGURATION_BUILD_DIR="$BUILD_DIR"
)

# Manual code-signing only for the Release variant — that's the one we
# notarize and ship. Debug uses Xcode's default (which usually picks an
# Apple Development cert) so local builds work without prompting for
# the Developer ID identity.
if [ "$CONFIGURATION" = "Release" ]; then
  xcodebuild_args+=(
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="$TEAM_ID"
  )
fi

xcodebuild "${xcodebuild_args[@]}"

echo "Verifying signature..."
codesign --verify --deep --strict "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || true
