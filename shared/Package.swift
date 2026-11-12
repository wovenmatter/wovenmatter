// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "WovenMatterShared",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [.library(name: "WovenMatterShared", targets: ["WovenMatterShared"])],
  targets: [
    .target(name: "WovenMatterShared"),
    .executableTarget(name: "WovenMCPCatalogExport", dependencies: ["WovenMatterShared"], path: "Tools/WovenMCPCatalogExport"),
    .testTarget(name: "WovenMatterSharedTests", dependencies: ["WovenMatterShared"],
                // Shared with the Node server tests, which read the same vectors.
                exclude: ["MemberSignatureVectors.json", "generate-member-signature-vectors.mjs"])
  ]
)
