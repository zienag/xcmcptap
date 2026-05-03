# Build identity & variants

The codebase ships in two variants that coexist on disk: **Release** (production, distributed via the `xcmcptap` brew cask) and **Dev** (local development). Every per-variant identifier — bundle id, app name, icon, CLI symlink, Mach service names, LaunchAgent label — is derived from one source of truth and threaded through the system as an `Identity` value.

## Source of truth

`BuildConfig/Identity.xcconfig` defines the identifiers per Xcode build configuration via `[config=Debug]` / `[config=Release]` qualifiers:

| Variant | Bundle id | App / display name | Icon | CLI symlink |
|---|---|---|---|---|
| Release | `alfred.xcmcptap` | `Xcode MCP Tap` | `AppIcon` | `xcmcptap` |
| Dev | `alfred.xcmcptap.dev` | `Xcode MCP Tap Dev` | `AppIcon-Dev` (orange tint) | `xcmcptap-dev` |

`statusServiceName`, `helperServiceName`, `agentPlistName`, `helperPlistName` are computed from `serviceName` — change the bundle id and the rest follows.

## How values flow

1. Xcode reads `Identity.xcconfig` via `configFiles:` in `project.yml` and exposes the `XCMCPTAP_*` settings as build env vars.
2. Each Xcode-native target's pre-build phase runs `scripts/gen-build-config.sh`, which reads those env vars and writes `BuildConfig.swift` into `${DERIVED_FILE_DIR}` (DerivedData, **never the source tree**). The file declares one constant: `enum BuildConfig { static let identity = Identity(...) }`.
3. The four `App/` `@main` wrappers compile in `BuildConfig.swift` and pass `BuildConfig.identity` into the SPM entry points (`ClientMain.run(identity:)`, `ServiceMain.run(identity:)`, `HelperMain.run(identity:)`) and into `prepareDependencies` for `StatusClient.live(statusServiceName:)` / `ServiceInstallerClient.live(installer:)`.
4. The App target additionally runs `scripts/install-bundle-plists.sh` to substitute `__SERVICE_NAME__` in `BuildConfig/agent.plist.template` + `helper.plist.template`, writing the resolved plists into `${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}/Contents/Library/Launch{Agents,Daemons}/`.

Nothing in the SPM library code references identifiers — `Identity` is the only carrier. Tests construct fixtures (`Tests/XPCTests/TestIdentity.swift`); production passes `BuildConfig.identity`.

## install.sh

Default `./install.sh` builds the **Dev** variant (no notarization, signs with the default identity, installs `Xcode MCP Tap Dev.app` alongside any Release/brew install). `./install.sh --dmg` keeps the Release+notarize+DMG path for distribution. The variant is selected by `XCMCPTAP_VARIANT={debug,release}` in `scripts/_config.sh`, which resolves identity values via `xcodebuild -showBuildSettings` (no hand-rolled xcconfig parser).

## Adding or changing an identity field

1. Add the per-config qualifiers to `BuildConfig/Identity.xcconfig`.
2. Add the field to `Identity` in `Sources/Shared/Protocol.swift`.
3. Pass it through the relevant entry point or struct.
4. Update `scripts/gen-build-config.sh` to emit it into the generated `BuildConfig.swift`.
5. Update `Tests/XPCTests/TestIdentity.swift` so test fixtures construct the new field.

## What ranges over the variant

- Bundle id, product name, display name, icon, symlink — driven by xcconfig.
- LaunchAgent label, Mach service names, plist file names — derived from `serviceName`.
- The MCP `clientName` advertised in the `initialize` handshake (the string Xcode shows in its "X wants to use Xcode's tools" dialog) — passed via `MCPRouter(clientName:)`. **This is not the bundle id and not `CFBundleDisplayName`**; it must be threaded explicitly from `identity.appDisplayName` or the dialog displays the wrong name.
