// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WovenMatterCompanionIntegration",
  platforms: [.macOS(.v26)],
  dependencies: [.package(path: "../app"), .package(path: "../ios"), .package(path: "../shared")],
  targets: [
    .testTarget(name: "CompanionIntegrationTests", dependencies: [
      .product(name: "WovenMatterDashboardStore", package: "app"),
      .product(name: "WovenMatterCore", package: "app"),
      .product(name: "CompanionClient", package: "ios"),
      .product(name: "WovenMatterCompanion", package: "shared")
    ])
  ]
)
