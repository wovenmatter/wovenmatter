// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "WovenMatterIntegration",
  platforms: [.macOS(.v26)],
  dependencies: [.package(path: "../app"), .package(path: "../ios"), .package(path: "../shared")],
  targets: [
    .testTarget(name: "CrossDeviceIntegrationTests", dependencies: [
      .product(name: "WovenMatterDashboardStore", package: "app"),
      .product(name: "WovenMatterCore", package: "app"),
      .product(name: "LibraryClient", package: "ios"),
      .product(name: "WovenMatterShared", package: "shared")
    ])
  ]
)
