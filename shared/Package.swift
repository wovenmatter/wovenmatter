// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "WovenMatterCompanion",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "WovenMatterCompanion", targets: ["WovenMatterCompanion"])],
  targets: [
    .target(name: "WovenMatterCompanion"),
    .testTarget(name: "WovenMatterCompanionTests", dependencies: ["WovenMatterCompanion"])
  ]
)
