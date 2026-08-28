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
  dependencies: [],
  targets: [
    .target(
      name: "WovenMatterCore",
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
    )
  ]
)
