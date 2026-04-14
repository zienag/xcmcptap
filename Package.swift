// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "XcodeMCPTap",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "XcodeMCPTapShared", targets: ["XcodeMCPTapShared"]),
    .library(name: "XcodeMCPTapClient", targets: ["XcodeMCPTapClient"]),
    .library(name: "XcodeMCPTapService", targets: ["XcodeMCPTapService"]),
    .library(name: "XcodeMCPTapHelper", targets: ["XcodeMCPTapHelper"]),
    .library(name: "XcodeMCPTapUI", targets: ["XcodeMCPTapUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.17.0"),
  ],
  targets: [
    .target(name: "XcodeMCPTapShared", path: "Sources/Shared"),
    .target(
      name: "XcodeMCPTapClient",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/Client"
    ),
    .target(
      name: "XcodeMCPTapService",
      dependencies: [
        "XcodeMCPTapShared",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      path: "Sources/Service"
    ),
    .target(
      name: "XcodeMCPTapHelper",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/Helper"
    ),
    .target(
      name: "XcodeMCPTapUI",
      dependencies: [
        "XcodeMCPTapShared",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      path: "Sources/UI"
    ),
    .executableTarget(
      name: "xpc-test-echo-server",
      dependencies: ["XcodeMCPTapShared"],
      path: "Sources/TestEchoServer"
    ),
    .executableTarget(
      name: "xcmcptap-helper",
      dependencies: ["XcodeMCPTapHelper"],
      path: "Sources/HelperExec"
    ),
    .testTarget(
      name: "XPCTests",
      dependencies: [
        "XcodeMCPTapService",
        "XcodeMCPTapShared",
        "XcodeMCPTapHelper",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      path: "Tests/XPCTests"
    ),
    .testTarget(
      name: "UISnapshotTests",
      dependencies: [
        "XcodeMCPTapUI",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      path: "Tests/UISnapshotTests"
    ),
    .testTarget(
      name: "FeatureTests",
      dependencies: [
        "XcodeMCPTapUI",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      path: "Tests/FeatureTests"
    ),
  ]
)
