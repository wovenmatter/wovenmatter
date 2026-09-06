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
  dependencies: [.package(path: "../shared")],
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
        .linkedFramework("Security")
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
    .target(
      name: "WovenMatterAppFacade",
      dependencies: ["WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore"],
      path: "App",
      exclude: ["WovenMatterApp.swift", "Assets.xcassets", "Info.plist", "Resources"],
      sources: ["ApplicationModel.swift", "Models", "Services", "Views"],
      swiftSettings: [.define("COMPANION_FACADE_TESTS")]
    ),
    .testTarget(
      name: "WovenMatterAppFacadeTests",
      dependencies: ["WovenMatterAppFacade", "WovenMatterDashboardStore"]
    )
  ]
)
