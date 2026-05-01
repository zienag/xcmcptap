# Sourced by every install/build script. Defines repo paths and signing identity.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Xcode MCP Tap.app"
SERVICE_NAME="alfred.xcmcptap"
SIGN_IDENTITY="Developer ID Application: Alfred Zien (GU3RT64VWG)"
TEAM_ID="GU3RT64VWG"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME"
BUILD_DIR="$REPO_ROOT/.build/Release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
CLIENT_LINK="$HOME/.local/bin/xcmcptap"

export REPO_ROOT APP_NAME SERVICE_NAME SIGN_IDENTITY TEAM_ID
export INSTALL_DIR APP_PATH BUILD_DIR APP_BUNDLE PLIST_PATH CLIENT_LINK
