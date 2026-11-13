// swift-tools-version: 6.2

import PackageDescription

let linuxCrypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
let linuxSQLite: Target.Dependency = .target(name: "CSQLite", condition: .when(platforms: [.linux]))

let package = Package(
  name: "WovenMatterMacOS",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "WovenMatterCore", targets: ["WovenMatterCore"]),
    .library(name: "WovenMatterClient", targets: ["WovenMatterClient"]),
    .library(name: "WovenMatterAutomation", targets: ["WovenMatterAutomation"]),
    .library(name: "WovenMatterDashboardStore", targets: ["WovenMatterDashboardStore"]),
    .executable(name: "wovenmatter-library", targets: ["WovenMatterLibraryDaemon"]),
    .executable(name: "WovenCuaDesktopFixture", targets: ["WovenCuaDesktopFixture"])
  ],
  dependencies: [
    .package(path: "../shared"), .package(path: "../ios"),
    // Linux-only replacement for CryptoKit; see docs/DEPENDENCIES.md.
    .package(url: "https://github.com/apple/swift-crypto.git", "5.1.1"..<"1000.0.0")
  ],
  targets: [
    // Linux links the system or pinned static SQLite; Apple platforms use the SDK module.
    // No pkg-config: its host search paths would leak glibc libraries into static musl links.
    .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
    .target(
      name: "WovenMatterCore",
      dependencies: [.product(name: "WovenMatterShared", package: "shared"), linuxCrypto],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny")
      ]
    ),
    .target(
      name: "WovenMatterClient",
      dependencies: ["WovenMatterCore", linuxCrypto, linuxSQLite],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny")
      ],
      linkerSettings: [
        .linkedFramework("Security", .when(platforms: [.macOS])),
        .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
        .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
        .linkedLibrary("sqlite3", .when(platforms: [.macOS]))
      ]
    ),
    .target(
      name: "WovenMatterAutomation",
      dependencies: ["WovenMatterCore", "WovenMatterClient"],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .testTarget(name: "WovenMatterAutomationTests", dependencies: ["WovenMatterAutomation", "WovenMatterCore", "WovenMatterClient"]),
    .executableTarget(name: "WovenCuaDesktopFixture", dependencies: ["WovenMatterAutomation", "WovenMatterCore", "WovenMatterClient"], path: "TestsSupport/CuaDesktopFixture"),
    .target(
      name: "WovenMatterDashboardStore",
      dependencies: ["WovenMatterCore", "WovenMatterClient", linuxCrypto, linuxSQLite],
      swiftSettings: [
        .enableUpcomingFeature("ExistentialAny")
      ],
      linkerSettings: [
        .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
        .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
        .linkedFramework("Security", .when(platforms: [.macOS]))
      ]
    ),
    // Headless library host for Linux machines (docs/architecture/WOVEN_EVERYWHERE.md).
    .target(
      name: "WovenMatterLibraryHost",
      dependencies: ["WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore", linuxCrypto, linuxSQLite],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .executableTarget(
      name: "WovenMatterLibraryDaemon",
      dependencies: ["WovenMatterLibraryHost"],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
    ),
    .testTarget(
      name: "WovenMatterLibraryHostTests",
      dependencies: ["WovenMatterLibraryHost", "WovenMatterDashboardStore", "WovenMatterCore", linuxSQLite,
                     // The phone client, for the in-process Mac + Linux + phone reach test.
                     .product(name: "LibraryClient", package: "ios", condition: .when(platforms: [.macOS]))]
    ),
    .target(name: "WorkspaceFixtures", dependencies: ["WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore", linuxCrypto, linuxSQLite], path: "TestsSupport/WorkspaceFixtures"),
    .testTarget(
      name: "WovenMatterCoreTests",
      dependencies: [
        "WovenMatterCore",
        "WovenMatterDashboardStore", "WorkspaceFixtures", linuxCrypto, linuxSQLite,
        // The window's stream client, for the Unix-socket stream tests.
        .product(name: "LibraryClient", package: "ios", condition: .when(platforms: [.macOS]))
      ]
    ),
    .testTarget(
      name: "WovenMatterClientTests",
      dependencies: ["WovenMatterClient", linuxCrypto, linuxSQLite]
    ),
    // A fail-closed bridge keeps provider-free facade tests independent of CEF.
    // The native Xcode target still compiles and validates the production bridge.
    .target(
      name: "FacadeBrowserTestBridge",
      path: "TestsSupport/FacadeBrowserTestBridge",
      publicHeadersPath: "include",
      cSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    // Build the native app sources once without its executable entry point.
    // Both test suites exercise those same services without starting providers.
    .target(
      name: "WovenMatterAppFacade",
      dependencies: ["FacadeBrowserTestBridge", "WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore", "WovenMatterAutomation", .product(name: "LibraryClient", package: "ios")],
      path: "App",
      exclude: ["Assets.xcassets", "SharedAssets.xcassets", "Info.plist", "Tests"],
      sources: ["ApplicationModel.swift", "WovenMatterApp.swift", "WovenMatterLifecycleDelegate.swift", "Models", "Services", "Views"],
      swiftSettings: [.define("APP_FACADE_TESTS")]
    ),
    .testTarget(
      name: "WovenMatterAgentToolsTests",
      dependencies: ["WovenMatterAppFacade", "WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore", "WorkspaceFixtures"],
      path: "App/Tests"
    ),
    .testTarget(
      name: "WovenMatterAppFacadeTests",
      dependencies: ["WovenMatterAppFacade", "WovenMatterDashboardStore", "WorkspaceFixtures", .product(name: "LibraryClient", package: "ios")]
    )
  ]
)

#if os(Linux)
// A native Linux build covers the portable library targets only. Apple-only
// targets stay declared for every macOS host, including Linux cross-builds.
let appleOnlyTargets: Set<String> = [
  "WovenMatterAutomation", "WovenMatterAutomationTests", "WovenCuaDesktopFixture", "FacadeBrowserTestBridge",
  "WovenMatterAppFacade", "WovenMatterAgentToolsTests", "WovenMatterAppFacadeTests"
]
package.targets.removeAll { appleOnlyTargets.contains($0.name) }
package.products.removeAll { appleOnlyTargets.contains($0.name) }
#endif
