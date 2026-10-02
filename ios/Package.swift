// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WovenMatterMobile",
  platforms: [.iOS(.v18), .macOS(.v14)],
  products: [.library(name: "CompanionClient", targets: ["CompanionClient"])],
  dependencies: [.package(path: "../shared")],
  targets: [
    .target(name: "CompanionClient", dependencies: [.product(name: "WovenMatterCompanion", package: "shared")]),
    .testTarget(name: "CompanionClientTests", dependencies: ["CompanionClient"]),
  ]
)
