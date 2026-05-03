#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<EOF
Usage: $0 [--dmg|--exit]

  (no args)  Build the Debug variant (separate bundle id + name + icon)
             and install it to /Applications. No notarization. Coexists
             alongside the Release / brew install.
  --dmg      Build the Release variant, notarize, package as
             .build/Release/XcodeMCPTap.dmg.
  --exit     Stop the active variant's service and quit the app.

To uninstall, run scripts/uninstall.sh directly.
Override variant in --exit/--uninstall: XCMCPTAP_VARIANT=release scripts/...
EOF
}

case "${1:-}" in
  --exit)      exec scripts/exit-service.sh ;;
  --dmg)
    export XCMCPTAP_VARIANT=release
    scripts/build.sh
    source scripts/_config.sh
    [ "${NOTARIZE:-true}" = "true" ] && scripts/notarize.sh
    exec scripts/make_dmg.py
    ;;
  "")
    export XCMCPTAP_VARIANT=debug
    scripts/build.sh
    exec scripts/install-app.sh
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
