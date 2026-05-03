#!/bin/bash
# Substitute __SERVICE_NAME__ in BuildConfig/agent.plist.template +
# helper.plist.template and write the results into the .app bundle's
# Library directory. Invoked from the App target's pre-build phase.
set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?must be set by Xcode}"
: "${WRAPPER_NAME:?must be set by Xcode}"
: "${SRCROOT:?must be set by Xcode}"
: "${XCMCPTAP_SERVICE_NAME:?missing from xcconfig - wire BuildConfig/Identity.xcconfig into the App target}"

agents_dir="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME/Contents/Library/LaunchAgents"
daemons_dir="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME/Contents/Library/LaunchDaemons"
mkdir -p "$agents_dir" "$daemons_dir"

agent_plist="$agents_dir/${XCMCPTAP_SERVICE_NAME}.plist"
helper_plist="$daemons_dir/${XCMCPTAP_SERVICE_NAME}.helper.plist"

sed "s/__SERVICE_NAME__/${XCMCPTAP_SERVICE_NAME}/g" \
  "$SRCROOT/BuildConfig/agent.plist.template" > "$agent_plist"

sed "s/__SERVICE_NAME__/${XCMCPTAP_SERVICE_NAME}/g" \
  "$SRCROOT/BuildConfig/helper.plist.template" > "$helper_plist"
