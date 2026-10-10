// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "WovenMatterMacOS",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "WovenMatterCore", targets: ["WovenMatterCore"]),
    .library(name: "WovenMatterClient", targets: ["WovenMatterClient"]),
    .library(name: "WovenMatterDashboardStore", targets: ["WovenMatterDashboardStore"])
  ],
  dependencies: [.package(path: "../shared"), .package(path: "../ios")],
  targets: [
    .target(
      name: "WovenMatterCore",
      dependencies: [.product(name: "WovenMatterCompanion", package: "shared")],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny")
      ]
    ),
    .target(
      name: "WovenMatterClient",
      dependencies: ["WovenMatterCore"],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny")
      ],
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("LocalAuthentication"),
        .linkedLibrary("sqlite3")
      ]
    ),
    .target(
      name: "WovenMatterDashboardStore",
      dependencies: ["WovenMatterCore", "WovenMatterClient"],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny")
      ],
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedFramework("LocalAuthentication"),
        .linkedFramework("Security")
      ]
    ),
    .testTarget(
      name: "WovenMatterCoreTests",
      dependencies: [
        "WovenMatterCore",
        "WovenMatterDashboardStore"
      ]
    ),
    .testTarget(
      name: "WovenMatterClientTests",
      dependencies: ["WovenMatterClient"]
    ),
    // A fail-closed bridge keeps provider-free facade tests independent of CEF.
    // The native Xcode target still compiles and validates the production bridge.
    .target(
      name: "CompanionBrowserTestBridge",
      path: "TestsSupport/CompanionBrowserTestBridge",
      publicHeadersPath: "include",
      cSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    // Build the native app sources once without its executable entry point.
    // Both test suites exercise those same services without starting providers.
    .target(
      name: "WovenMatterAppFacade",
      dependencies: ["CompanionBrowserTestBridge", "WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore", .product(name: "CompanionClient", package: "ios")],
      path: "App",
      exclude: ["Assets.xcassets", "SharedAssets.xcassets", "Info.plist", "Resources", "Tests"],
      sources: ["ApplicationModel.swift", "WovenMatterApp.swift", "WovenMatterLifecycleDelegate.swift", "Models", "Services", "Views"],
      swiftSettings: [.define("COMPANION_FACADE_TESTS")]
    ),
    .testTarget(
      name: "WovenMatterAgentToolsTests",
      dependencies: ["WovenMatterAppFacade", "WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore"],
      path: "App/Tests"
    ),
    .testTarget(
      name: "WovenMatterAppFacadeTests",
      dependencies: ["WovenMatterAppFacade", "WovenMatterDashboardStore", .product(name: "CompanionClient", package: "ios")]
    )
  ]
)
