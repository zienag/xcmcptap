#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/_config.sh"

ZIP_PATH="$REPO_ROOT/.build/XcodeMCPTap.zip"
trap 'rm -f "$ZIP_PATH"' EXIT

ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Submitting for notarization..."
if xcrun notarytool submit "$ZIP_PATH" --keychain-profile "notarytool" --wait; then
  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP_BUNDLE"
else
  cat <<EOF >&2

Notarization failed. To set up credentials, run:
  xcrun notarytool store-credentials notarytool --apple-id YOUR_APPLE_ID --team-id $TEAM_ID

Or skip notarization: NOTARIZE=false ./install.sh
EOF
  exit 1
fi
