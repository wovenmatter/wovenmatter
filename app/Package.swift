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
    // Exercise the same app service and socket/relay sources that the native
    // bundle uses, without launching the UI or any provider runtimes.
    .testTarget(
      name: "WovenMatterAgentToolsTests",
      dependencies: ["WovenMatterCore", "WovenMatterClient", "WovenMatterDashboardStore"],
      path: "App",
      exclude: [
        "ApplicationModel.swift", "WovenMatterApp.swift", "WovenMatterLifecycleDelegate.swift",
        "Info.plist", "Assets.xcassets", "Resources", "Views", "Services/DashboardNoteDrafts.swift",
        "Models/ApplicationModel+AgentTools.swift", "Models/ApplicationModel+Calendar.swift", "Models/AgentDatabases.swift",
        "Models/ConversationMarkdownDocument.swift", "Models/DashboardConversationReferencePreview.swift",
        "Models/DashboardConversationState.swift", "Models/OpenCodeModel.swift", "Models/RemoteWorkspacesModel.swift"
      ],
      sources: [
        "Models/WorkspaceAgentToolsModel.swift", "Models/WorkspaceAgentToolsModel+Calendar.swift", "Services/WovenMatterToolService.swift",
        "Services/WovenNoteService.swift", "Services/WovenMatterRemoteToolBridge.swift",
        "Tests/WorkspaceAgentToolsServiceTests.swift"
      ]
    )
  ]
)
