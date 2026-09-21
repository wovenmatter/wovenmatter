import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(1)))
struct ACPSessionPermissionTests {
    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode])
    func nativeConfigurationAndLabelsSurviveOtherSelections(kind: AgentRuntimeKind) async throws {
        let state = configuration(permission: "default")
        let selected = configuration(permission: "full")
        try await withClient(kind: kind, state: state, handlers: [
            "session/set_config_option": respond(selected),
        ]) { client, fixture, initialized async throws in
            let initial = initialized.configuration
            #expect(initial.permission == "default")
            #expect(initial.permissionOptions == ["default", "full"])
            #expect(initial.permissionOptionMetadata["full"]?.name == "Native full label")
            #expect(initial.permissionOptionMetadata["full"]?.description == "Native full description")
            #expect(initial.selecting(model: "other", thinking: "high").permission == "default")
            #expect(initial.selecting(permission: "full").model == "fixture-model")
            #expect(initial.selecting(permission: "full").thinking == "low")
            let result = try await client.setSessionPermission("full")
            #expect(result.permission == "full")
            #expect(result.model == "fixture-model" && result.thinking == "low")
            let requests = try fixture.requests(method: "session/set_config_option")
            #expect(requests.count == 1)
            let params = requests.first?["params"] as? [String: Any]
            #expect(params?["sessionId"] as? String == "permission-session")
            #expect(params?["configId"] as? String == "mode")
            #expect(params?["value"] as? String == "full")
        }
    }

    @Test(arguments: [true, false])
    func codexSmartReviewRequiresNativeClassification(modern: Bool) async throws {
        let idKey = modern ? "value" : "id"
        let options: [[String: Any]] = [
            [idKey: "read-only", "name": "Read only"],
            [idKey: "agent", "name": "Auto", "_meta": ["kind": "auto_review"]],
            [idKey: "agent-full-access", "name": "Bypass"],
            [idKey: "future-policy", "name": "Native future mode", "description": "Native future behavior"],
        ]
        let state: [String: Any] = modern
            ? ["configOptions": [["id": "mode", "category": "mode", "currentValue": "agent", "options": options]]]
            : ["modes": ["currentModeId": "agent", "availableModes": options]]
        try await withClient(state: state) { _, fixture, initialized async throws in
            let value = initialized.configuration
            #expect(value.permission == "agent")
            #expect(value.permissionOptions == ["read-only", "agent", "agent-full-access", "future-policy"])
            #expect(value.permissionOptionMetadata["read-only"]?.name == "Ask for approval")
            #expect(value.permissionOptionMetadata["agent"]?.name == "Approve for me")
            #expect(value.permissionOptionMetadata["agent-full-access"]?.name == "Full access")
            #expect(value.permissionOptionMetadata["future-policy"]?.name == "Native future mode")
            #expect(value.permissionOptionMetadata["future-policy"]?.description == "Native future behavior")
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            #expect(try fixture.requests(method: "session/set_mode").isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func oldCodexWorkspacePresetIsNotRelabeledSmartAuto(modern: Bool) async throws {
        let options = [[modern ? "value" : "id": "agent", "name": "Auto", "description": "Run in the workspace"]]
        let state: [String: Any] = modern
            ? ["configOptions": [["id": "mode", "category": "mode", "currentValue": "agent", "options": options]]]
            : ["modes": ["currentModeId": "agent", "availableModes": options]]
        try await withClient(state: state) { _, _, initialized async throws in
            #expect(initialized.configuration.permission == "agent")
            #expect(initialized.configuration.permissionOptionMetadata["agent"]?.name == "Workspace access")
        }
    }

    @Test func claudeKnownModesUseApprovalLabelsWithoutInventingCapabilities() async throws {
        let options = ["default", "auto", "acceptEdits", "bypassPermissions"].map {
            ["value": $0, "name": "Native " + $0]
        }
        let state: [String: Any] = ["configOptions": [[
            "id": "mode", "category": "mode", "currentValue": "default", "options": options,
        ]]]
        try await withClient(kind: .claudeCode, state: state, requestedPermission: "default") { _, fixture, initialized async throws in
            let labels = initialized.configuration.permissionOptionMetadata
            #expect(labels["default"]?.name == "Ask for approval")
            #expect(labels["auto"]?.name == "Auto")
            #expect(labels["acceptEdits"]?.name == "Auto-accept edits")
            #expect(labels["bypassPermissions"]?.name == "Full access")
            #expect(initialized.configuration.permissionOptions == ["default", "auto", "acceptEdits", "bypassPermissions"])
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
        }
    }

    @Test(arguments: ["plan", "dontAsk"])
    func claudeLegacyPoliciesStayReadableWithoutAppearingAsApprovalPresets(current: String) async throws {
        let options = ["default", "auto", "acceptEdits", "bypassPermissions", "plan", "dontAsk"].map {
            ["value": $0, "name": "Native " + $0]
        }
        let state: [String: Any] = ["configOptions": [[
            "id": "mode", "category": "mode", "currentValue": current, "options": options,
        ]]]
        try await withClient(kind: .claudeCode, state: state, requestedPermission: current) { client, fixture, initialized async throws in
            #expect(initialized.configuration.permission == current)
            #expect(initialized.configuration.permissionOptionMetadata[current]?.name == "Native " + current)
            #expect(try await client.setSessionPermission(current).permission == current)
            #expect(initialized.configuration.permissionOptions == ["default", "auto", "acceptEdits", "bypassPermissions"])
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
        }
    }

    @Test(arguments: [true, false], ["plan", "dontAsk"])
    func claudeSavedLegacyPolicyCanBeRestoredWithoutAppearingInPicker(modern: Bool, saved: String) async throws {
        let options = ["default", "auto", "acceptEdits", "bypassPermissions", "plan", "dontAsk"].map {
            [modern ? "value" : "id": $0, "name": "Native " + $0]
        }
        func state(_ current: String) -> [String: Any] {
            modern
                ? ["configOptions": [["id": "mode", "category": "mode", "currentValue": current, "options": options]]]
                : ["modes": ["currentModeId": current, "availableModes": options]]
        }
        try await withClient(kind: .claudeCode, state: state("default"), handlers: [
            modern ? "session/set_config_option" : "session/set_mode": respond(state(saved)),
        ], existingID: "existing-claude", requestedPermission: saved) { client, fixture, initialized async throws in
            #expect(initialized.configuration.permission == "default")
            let restored = try await client.setSessionPermission(saved)
            #expect(restored.permission == saved)
            #expect(restored.permissionOptions == ["default", "auto", "acceptEdits", "bypassPermissions"])
            #expect(try await client.setSessionPermission(saved).permission == saved)
            #expect(try fixture.requests(method: modern ? "session/set_config_option" : "session/set_mode").count == 1)
        }
    }

    @Test(arguments: ["permission_mode", "approval_mode"])
    func explicitPermissionConfigurationIDIsUsed(id: String) async throws {
        let state = configuration(permission: "default", id: id)
        try await withClient(state: state, handlers: [
            "session/set_config_option": respond(configuration(permission: "full", id: id)),
        ]) { client, fixture, _ async throws in
            #expect(try await client.setSessionPermission("full").permission == "full")
            let params = try fixture.requests(method: "session/set_config_option").first?["params"] as? [String: Any]
            #expect(params?["configId"] as? String == id)
        }
    }

    @Test func nativeErrorAndUnknownValuesNeverEscalate() async throws {
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": #"printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Policy rejects full"}}\n' "$id""#,
        ]) { client, fixture, _ async throws in
            do {
                _ = try await client.setSessionPermission("unadvertised")
                Issue.record("An unadvertised permission value was accepted")
            } catch LocalACPClientError.invalidConfigurationValue { }
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("A rejected native change was accepted")
            } catch LocalACPClientError.agent(let code, _) { #expect(code == -32602) }
            #expect(await client.sessionConfiguration().permission == "default")
        }
    }

    @Test func modernSetterRequiresNativeReadback() async throws {
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": respond([:]),
        ]) { client, _, _ async throws in
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("An empty modern setter response did not confirm the change")
            } catch LocalACPClientError.configurationNotConfirmed { }
            #expect(await client.sessionConfiguration().permission == "default")
        }
    }

    @Test func foreignConfigurationCannotConfirmPermissionChange() async throws {
        let childMode = notification(["sessionUpdate": "current_mode_update", "currentModeId": "full"], session: "child-session")
        let childOptions = notification(configuration(permission: "full").merging(["sessionUpdate": "config_option_update"]) { _, new in new }, session: "child-session")
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": childMode + "\n" + childOptions + "\n" + respond([:]),
        ]) { client, _, initialized async throws in
            let snapshots = PermissionSnapshots()
            await client.setConfigurationHandler { await snapshots.append($0) }
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("A child session's mode falsely confirmed the parent setter")
            } catch LocalACPClientError.configurationNotConfirmed { }
            #expect(await client.sessionConfiguration() == initialized.configuration)
            #expect(await snapshots.values() == [initialized.configuration])
        }
    }

    @Test func foreignModeDoesNotInvalidateLegacyAcknowledgement() async throws {
        try await withClient(state: legacyModes(), handlers: [
            "session/set_mode": notification(["sessionUpdate": "current_mode_update", "currentModeId": "default"], session: "child-session")
                + "\n" + respond([:]),
        ]) { client, _, _ async throws in
            #expect(try await client.setSessionPermission("full").permission == "full")
        }
    }

    @Test(arguments: [String?.none, "existing-parent"])
    func earlyConfigurationUpdatesWaitForSessionIdentity(existingID: String?) async throws {
        let parent = notification(configuration(permission: "default").merging(["sessionUpdate": "config_option_update"]) { _, new in new }, session: existingID ?? "permission-session")
        let child = notification(configuration(permission: "full").merging(["sessionUpdate": "config_option_update"]) { _, new in new }, session: "child-session")
        try await withClient(state: [:], existingID: existingID, sessionPrelude: parent + "\n" + child) { client, _, initialized async throws in
            #expect(initialized.configuration.permission == "default")
            #expect(initialized.configuration.permissionOptions == ["default", "full"])
            #expect(initialized.loadedExistingSession == (existingID != nil))
            #expect(await client.sessionConfiguration() == initialized.configuration)
        }
    }

    @Test func legacyMissingSessionIdentityConfigurationStillApplies() async throws {
        try await withClient(state: legacyModes(), handlers: [
            "session/set_mode": notification(["sessionUpdate": "current_mode_update", "currentModeId": "full"], session: nil)
                + "\n" + respond([:]),
        ]) { client, _, _ async throws in
            #expect(try await client.setSessionPermission("full").permission == "full")
        }
    }

    @Test func notificationsPreserveCommandsAndAuthoritativeModelClamp() async throws {
        let clamped = configuration(permission: "default", model: "changed-model")
        let update = notification(["sessionUpdate": "current_mode_update", "currentModeId": "full"])
        let commands = notification(["sessionUpdate": "available_commands_update", "availableCommands": [["name": "review"]]])
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": update + "\n" + respond(configuration(permission: "full")),
            "session/prompt": commands + "\n" + notification(clamped.merging(["sessionUpdate": "config_option_update"]) { _, new in new })
                + "\n" + respond(["stopReason": "end_turn"]),
        ]) { client, _, _ async throws in
            let snapshots = PermissionSnapshots()
            await client.setConfigurationHandler { await snapshots.append($0) }
            _ = try await client.setSessionPermission("full")
            #expect(await snapshots.values().map(\.permission) == ["default", "full"])
            _ = try await client.prompt("fixture")
            let result = await client.sessionConfiguration()
            #expect(result.permission == "default")
            #expect(result.model == "changed-model")
            #expect(result.slashCommands.map(\.name) == ["review"])
            #expect(await snapshots.values().map(\.permission) == ["default", "full", "full", "default"])
        }
    }

    @Test func catalogRemovalDisablesPermissionSetter() async throws {
        var removed = configuration(permission: "default")
        removed["configOptions"] = (removed["configOptions"] as? [[String: Any]])?.filter { $0["id"] as? String != "mode" }
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": respond(removed),
        ]) { client, _, _ async throws in
            let result = try await client.setSessionConfiguration(model: "other")
            #expect(result.permission == nil && result.permissionOptions.isEmpty)
            #expect(result.permissionOptionMetadata.isEmpty)
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("Removed permission options remained selectable")
            } catch LocalACPClientError.unsupportedConfiguration { }
        }
    }

    @Test func legacyAdvertisedModesUseStandardMethod() async throws {
        try await withClient(state: legacyModes(), handlers: ["session/set_mode": respond([:])]) { client, fixture, _ async throws in
            let result = try await client.setSessionPermission("full")
            #expect(result.permission == "full")
            #expect(result.permissionOptionMetadata["full"]?.name == "Native full label")
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            let params = try fixture.requests(method: "session/set_mode").first?["params"] as? [String: Any]
            #expect(params?["modeId"] as? String == "full")
        }
    }

    @Test func legacySetterRespectsAuthoritativeClamp() async throws {
        try await withClient(state: legacyModes(), handlers: [
            "session/set_mode": notification(["sessionUpdate": "current_mode_update", "currentModeId": "default"])
                + "\n" + respond([:]),
        ]) { client, _, _ async throws in
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("A native policy clamp was overwritten by optimistic state")
            } catch LocalACPClientError.configurationNotConfirmed { }
            #expect(await client.sessionConfiguration().permission == "default")
        }
    }

    @Test func claudeLoadedSessionNeverResetsToAuto() async throws {
        try await withClient(kind: .claudeCode, state: claudeState(), existingID: "existing-claude") { client, fixture, initialized async throws in
            #expect(initialized.loadedExistingSession)
            #expect(initialized.configuration.permission == "default")
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            #expect(try fixture.requests(method: "session/new").isEmpty)
            #expect(await client.sessionConfiguration().permissionOptions == ["default", "auto"])
        }
    }

    @Test func claudeExplicitPreferenceSuppressesLegacyFreshAutoDefault() async throws {
        try await withClient(kind: .claudeCode, state: claudeState(), requestedPermission: "default") { _, fixture, initialized async throws in
            #expect(initialized.configuration.permission == "default")
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
        }
    }

    @Test func claudeFreshSessionRetainsNativeAutoDefaultWithoutPreference() async throws {
        var selected = claudeState()
        var options = try #require(selected["configOptions"] as? [[String: Any]])
        options[0]["currentValue"] = "auto"
        selected["configOptions"] = options
        try await withClient(kind: .claudeCode, state: claudeState(), handlers: ["session/set_config_option": respond(selected)]) { _, fixture, initialized async throws in
            #expect(initialized.configuration.permission == "auto")
            #expect(try fixture.requests(method: "session/set_config_option").count == 1)
        }
    }

    @Test func cursorExecutionModesAreNotPermissionModes() async throws {
        try await withClient(kind: .cursor, state: [
            "modes": ["currentModeId": "agent", "availableModes": [["id": "agent", "name": "Agent"]]],
            "configOptions": [["id": "mode", "category": "mode", "currentValue": "agent", "options": [["value": "agent"], ["value": "ask"], ["value": "plan"]]]],
        ]) { client, fixture, initialized async throws in
            #expect(initialized.configuration.permission == "normal")
            #expect(initialized.configuration.permissionOptions == ["normal", "auto"])
            #expect(initialized.configuration.permissionOptionMetadata["normal"]?.name == "Ask for approval")
            #expect(initialized.configuration.permissionOptionMetadata["auto"]?.name == "Full access")
            do {
                _ = try await client.setSessionPermission("agent")
                Issue.record("Cursor execution mode was treated as a permission policy")
            } catch LocalACPClientError.invalidConfigurationValue { }
            #expect(try fixture.requests(method: "session/set_mode").isEmpty)
        }
    }

    @Test(arguments: [String?.none, "normal", "auto"])
    func cursorApprovalsAreScopedToTheClientAndSwitchWithoutNativeModeChanges(permission: String?) async throws {
        try await withClient(kind: .cursor, state: [:], handlers: [
            "session/prompt": permissionRequest() + "\n" + respond(["stopReason": "end_turn"]),
        ], requestedPermission: permission) { client, fixture, initialized async throws in
            let manual = PermissionHandlerCalls()
            #expect(initialized.configuration.permission == (permission ?? "normal"))
            let handler: LocalACPClient.PermissionHandler = { request in
                await manual.append(request.title)
                return "reject-this-request"
            }
            _ = try await client.prompt("fixture", onPermission: handler)
            #expect(await manual.count() == (permission == "auto" ? 0 : 1))
            let initial = try fixture.responses().first?["result"] as? [String: Any]
            let initialOutcome = initial?["outcome"] as? [String: Any]
            #expect(initialOutcome?["optionId"] as? String == (permission == "auto" ? "native-once-id" : "reject-this-request"))
            _ = try await client.setSessionPermission("auto")
            _ = try await client.prompt("fixture", onPermission: handler)
            _ = try await client.setSessionPermission("normal")
            _ = try await client.prompt("fixture", onPermission: handler)
            #expect(await manual.count() == (permission == "auto" ? 1 : 2))
            #expect(try fixture.responses().count == 3)
            #expect(try fixture.requests(method: "session/set_mode").isEmpty)
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            #expect(try fixture.launchArguments().isEmpty)
        }
    }

    @Test(arguments: [String?.none, "child-session", "permission-session"])
    func cursorFullAccessRequiresExactSessionAndNativeAllowOnce(session: String?) async throws {
        // The parent's request omits allow_once; the child advertises it but
        // belongs elsewhere; the missing-session request is kept manual.
        let offersOnce = session != "permission-session"
        try await withClient(kind: .cursor, state: [:], handlers: [
            "session/prompt": permissionRequest(session: session, offersOnce: offersOnce)
                + "\n" + respond(["stopReason": "end_turn"]),
        ], requestedPermission: "auto") { client, fixture, _ async throws in
            let manual = PermissionHandlerCalls()
            _ = try await client.prompt("fixture", onPermission: { request in
                await manual.append(request.title)
                return "reject-this-request"
            })
            #expect(await manual.count() == (session == "child-session" ? 0 : 1))
            let result = try fixture.responses().first?["result"] as? [String: Any]
            let outcome = result?["outcome"] as? [String: Any]
            #expect(outcome?["outcome"] as? String == (session == "child-session" ? "cancelled" : "selected"))
            #expect(outcome?["optionId"] as? String != "always-id")
            #expect(outcome?["optionId"] as? String != "native-once-id")
        }
    }

    @Test func cursorFullAccessLeavesUserQuestionsInteractive() async throws {
        let question: [String: Any] = ["jsonrpc": "2.0", "id": 101, "method": "cursor/ask_question", "params": [
            "sessionId": "permission-session", "toolCallId": "question-tool", "questions": [
                ["id": "color", "prompt": "Choose a color", "options": [["id": "blue", "label": "Blue"]]],
            ],
        ]]
        try await withClient(kind: .cursor, state: [:], handlers: [
            "session/prompt": receiveResponse(to: question) + "\n" + respond(["stopReason": "end_turn"]),
        ], requestedPermission: "auto") { client, fixture, _ async throws in
            let calls = PermissionHandlerCalls()
            _ = try await client.prompt("fixture", onInteraction: { request in
                if case .questions(let value) = request {
                    await calls.append(value.questions[0].prompt)
                }
                return .cancelled
            })
            #expect(await calls.count() == 1)
            #expect(try fixture.responses().count == 1)
        }
    }

    @Test(arguments: [true, false])
    func cursorFullAccessNeverAnswersPermissionFallbackQuestions(knownMarker: Bool) async throws {
        var options = [["optionId": "blue", "name": "Blue", "kind": "allow_once"]]
        if knownMarker {
            options.append(["optionId": "__ask_question_skip__", "name": "Skip", "kind": "reject_once"])
        } else {
            options.append(["optionId": "green", "name": "Green", "kind": "allow_once"])
        }
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 102, "method": "session/request_permission", "params": [
            "sessionId": "permission-session", "toolCall": ["toolCallId": "ask_fixture_q0", "title": "Choose a color", "kind": "other"], "options": options,
        ]]
        try await withClient(kind: .cursor, state: [:], handlers: [
            "session/prompt": receiveResponse(to: frame) + "\n" + respond(["stopReason": "end_turn"]),
        ], requestedPermission: "auto") { client, fixture, _ async throws in
            let manual = PermissionHandlerCalls()
            _ = try await client.prompt("fixture", onPermission: { request in
                await manual.append(request.title)
                return nil
            })
            #expect(await manual.count() == 1)
            let result = try fixture.responses().first?["result"] as? [String: Any]
            let outcome = result?["outcome"] as? [String: Any]
            #expect(outcome?["optionId"] as? String != "blue")
            #expect(outcome?["optionId"] as? String != "green")
        }
    }

    @Test(arguments: [String?.none, "default", "auto", "bypassPermissions"])
    func grokLaunchPolicyRequiresReconnectAndPreservesNativeSession(permission: String?) async throws {
        try await withClient(kind: .grokBuild, state: configuration(permission: "unused"),
            existingID: "existing-grok", requestedPermission: permission) { client, fixture, initialized async throws in
            #expect(initialized.loadedExistingSession && initialized.sessionID == "existing-grok")
            #expect(initialized.configuration.permission == permission)
            #expect(initialized.configuration.permissionOptions == LocalACPSessionPermissions.grokOptions)
            #expect(initialized.configuration.model == "fixture-model")
            if let permission {
                #expect(try await client.setSessionPermission(permission).permission == permission)
                #expect(try fixture.launchArguments() == ["--permission-mode", permission, "agent", "--no-leader", "stdio"])
            } else {
                #expect(try fixture.launchArguments() == ["agent", "stdio"])
            }
            do {
                _ = try await client.setSessionPermission(permission == "default" ? "auto" : "default")
                Issue.record("Grok's no-op mode setter was used as a live policy setter")
            } catch LocalACPClientError.permissionChangeRequiresRestart { }
            #expect(try fixture.requests(method: "session/new").isEmpty)
            #expect(try fixture.requests(method: "session/set_mode").isEmpty)
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
        }
    }

    @Test func grokKeepsLegacyDontAskOnlyWhileSelected() async throws {
        #expect(LocalACPSessionPermissions.grokOptions == ["default", "acceptEdits", "auto", "bypassPermissions"])
        #expect(LocalACPSessionPermissions.grokMetadata["default"]?.name == "Ask for approval")
        #expect(LocalACPSessionPermissions.grokMetadata["bypassPermissions"]?.name == "Full access")
        try await withClient(kind: .grokBuild, state: [:], requestedPermission: "dontAsk") { client, fixture, initialized async throws in
            #expect(initialized.configuration.permission == "dontAsk")
            #expect(initialized.configuration.permissionOptions.contains("dontAsk"))
            #expect(try await client.setSessionPermission("dontAsk").permission == "dontAsk")
            #expect(try fixture.launchArguments() == ["--permission-mode", "dontAsk", "agent", "--no-leader", "stdio"])
        }
    }

    @Test func grokLaunchReplacesConflictingFlagsWithoutChangingOtherHarnesses() throws {
        let arguments = ["--no-auto-update", "--permission-mode=bypassPermissions", "agent", "--always-approve", "--leader", "stdio"]
        #expect(try LocalACPSessionPermissions.launchArguments(arguments, runtimeKind: .grokBuild, permission: "default") ==
            ["--permission-mode", "default", "--no-auto-update", "agent", "--no-leader", "stdio"])
        #expect(try LocalACPSessionPermissions.launchArguments(["--permission-mode", "auto", "agent", "--no-leader", "stdio"], runtimeKind: .grokBuild, permission: "dontAsk") ==
            ["--permission-mode", "dontAsk", "agent", "--no-leader", "stdio"])
        #expect(try LocalACPSessionPermissions.launchArguments(arguments, runtimeKind: .cursor, permission: "normal") == arguments)
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["agent", "--always-approve", "stdio"]) == "bypassPermissions")
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["--permission-mode", "auto", "agent", "stdio"]) == "auto")
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["--permission-mode=default", "agent", "stdio"]) == "default")
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["agent", "stdio"]) == nil)
        #expect(throws: LocalACPClientError.self) {
            try LocalACPSessionPermissions.launchArguments(["agent", "stdio"], runtimeKind: .grokBuild, permission: "invented")
        }
    }

    @Test func remoteGrokPolicyRewritesOnlyStructuredHarnessArguments() throws {
        let resolved = try RemoteHarnessLaunchResolver.resolve(
            configuration: .init(name: "Fixture", workspaceID: "permission-fixture", hostName: "fixture.invalid"),
            runtimeKind: .grokBuild, processWorkingDirectory: URL(filePath: "/private/tmp")
        ).launch
        let wrapped = try #require(resolved.wrappedCommand)
        let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: resolved.runtimeKind,
            executableURL: resolved.executableURL, arguments: resolved.arguments,
            processWorkingDirectoryURL: resolved.processWorkingDirectoryURL,
            requestedPermission: "default", wrappedCommand: wrapped)
        let prepared = try LocalACPSessionPermissions.prepareLaunch(launch)
        #expect(launch.executableURL.path == "/usr/bin/ssh")
        #expect(prepared.arguments.dropLast() == resolved.arguments.dropLast())
        #expect(prepared.explicitPermission == "default")
        let command = try shellTokens(prepared.arguments[wrapped.argumentIndex])
        #expect(Array(command.prefix(wrapped.harnessArgumentsStartIndex)) == Array(wrapped.command.prefix(wrapped.harnessArgumentsStartIndex)))
        #expect(Array(command.dropFirst(wrapped.harnessArgumentsStartIndex)) == ["--permission-mode", "default", "agent", "--no-leader", "stdio"])
        #expect(command.contains("HOME=/home"))
        #expect(command.contains(where: { $0.contains("flock --shared --nonblock 9") }))
        // A launch without an override remains byte-for-byte identical.
        #expect(try LocalACPSessionPermissions.prepareLaunch(resolved).arguments == resolved.arguments)
    }

    @Test func wrappedLaunchRetainsLiteralArgumentsAndRejectsInvalidOffsets() throws {
        let prefix = ["docker", "exec", "container", "env", "LITERAL=$(printf forbidden)", "bash", "-c", "exec \"$@\"", "wrapper", "/path/with 'quotes'/grok"]
        let inner = ["--permission-mode", "bypassPermissions", "agent", "--always-approve", "stdio", "--debug-file", "/tmp/it's `literal`.log"]
        let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .grokBuild, executableURL: URL(filePath: "/usr/bin/ssh"),
            arguments: ["-T", "fixture.invalid", "unused"], requestedPermission: "auto",
            wrappedCommand: .init(argumentIndex: 2, command: prefix + inner, harnessArgumentsStartIndex: prefix.count))
        let prepared = try LocalACPSessionPermissions.prepareLaunch(launch)
        #expect(try shellTokens(prepared.arguments[2]) == prefix + ["--permission-mode", "auto", "agent", "--no-leader", "stdio", "--debug-file", "/tmp/it's `literal`.log"])
        let invalid = LocalACPRuntimeLaunchConfiguration(runtimeKind: .grokBuild, executableURL: launch.executableURL,
            arguments: launch.arguments, requestedPermission: "auto",
            wrappedCommand: .init(argumentIndex: 99, command: [], harnessArgumentsStartIndex: 0))
        #expect(throws: LocalACPClientError.self) { try LocalACPSessionPermissions.prepareLaunch(invalid) }
    }

    private func shellTokens(_ quotedCommand: String) throws -> [String] {
        // Parse into positional parameters only; never execute the remote command.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "set -- " + quotedCommand + "; printf '%s\\0' \"$@\""]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    private func withClient(
        kind: AgentRuntimeKind = .codex,
        state: [String: Any],
        handlers: [String: String] = [:],
        existingID: String? = nil,
        requestedPermission: String? = nil,
        sessionPrelude: String = "",
        body: (LocalACPClient, PermissionFixture, LocalACPInitializedSession) async throws -> Void
    ) async throws {
        let fixture = try PermissionFixture(kind: kind, state: state, handlers: handlers, sessionPrelude: sessionPrelude)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = try fixture.client(requestedPermission: requestedPermission)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await client.shutdown()
        }
        do {
            let initialized = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: existingID, title: nil)
            try await body(client, fixture, initialized)
            deadline.cancel()
            await client.shutdown()
        } catch {
            deadline.cancel()
            await client.shutdown()
            throw error
        }
    }

    private func configuration(permission: String, id: String = "mode", model: String = "fixture-model") -> [String: Any] {
        ["configOptions": [
            ["id": id, "category": "mode", "currentValue": permission, "options": [
                ["value": "default", "name": "Native default label"],
                ["value": "full", "name": "Native full label", "description": "Native full description"],
            ]],
            ["id": "model", "category": "model", "currentValue": model, "options": [["value": "fixture-model"], ["value": "other"], ["value": "changed-model"]]],
            ["id": "effort", "category": "thought_level", "currentValue": "low", "options": [["value": "low"], ["value": "high"]]],
        ]]
    }

    private func legacyModes() -> [String: Any] {
        ["modes": ["currentModeId": "default", "availableModes": [
            ["id": "default", "name": "Native default label"],
            ["id": "full", "name": "Native full label"],
        ]]]
    }

    private func claudeState() -> [String: Any] {
        ["configOptions": [["id": "mode", "currentValue": "default", "options": [["value": "default"], ["value": "auto"]]]]]
    }

    private func respond(_ result: [String: Any]) -> String {
        "respond \"$id\" \(PermissionFixture.quotedJSON(result))"
    }

    private func notification(_ update: [String: Any], session: String? = "permission-session") -> String {
        var params: [String: Any] = ["update": update]
        if let session { params["sessionId"] = session }
        let frame: [String: Any] = ["jsonrpc": "2.0", "method": "session/update", "params": params]
        return "printf '%s\\n' \(PermissionFixture.quotedJSON(frame))"
    }

    private func permissionRequest(session: String? = "permission-session", offersOnce: Bool = true) -> String {
        var options = [["optionId": "always-id", "kind": "allow_always"], ["optionId": "reject-this-request", "kind": "reject_once"]]
        if offersOnce { options.append(["optionId": "native-once-id", "kind": "allow_once"]) }
        var params: [String: Any] = ["options": options, "toolCall": ["title": "Fixture shell", "kind": "execute"]]
        if let session { params["sessionId"] = session }
        return receiveResponse(to: ["jsonrpc": "2.0", "id": "native-permission-id", "method": "session/request_permission", "params": params])
    }

    private func receiveResponse(to frame: [String: Any]) -> String {
        """
        printf '%s\\n' \(PermissionFixture.quotedJSON(frame))
        IFS= read -r reply
        printf '%s\\n' "$reply" >> "$response_log"
        """
    }
}

private actor PermissionHandlerCalls {
    private var titles: [String] = []
    func append(_ title: String) { titles.append(title) }
    func count() -> Int { titles.count }
}

private actor PermissionSnapshots {
    private var configurations: [LocalACPSessionConfiguration] = []
    func append(_ configuration: LocalACPSessionConfiguration) { configurations.append(configuration) }
    func values() -> [LocalACPSessionConfiguration] { configurations }
}

private struct PermissionFixture {
    let root: URL
    let kind: AgentRuntimeKind
    let executable: URL

    init(kind: AgentRuntimeKind, state: [String: Any], handlers: [String: String], sessionPrelude: String) throws {
        self.kind = kind
        root = FileManager.default.temporaryDirectory.appending(path: "acp-permission-\(UUID())")
        executable = root.appending(path: "adapter")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var session = state
        session["sessionId"] = "permission-session"
        let cases = handlers.map { method, body in "*'\"method\":\"\(method)\"'*) \(body) ;;" }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        response_log='\(root.appending(path: "responses").path)'
        printf '%s\\n' "$@" > '\(root.appending(path: "arguments").path)'
        respond() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$1" "$2"; }
        while IFS= read -r request; do
          printf '%s\\n' "$request" >> '\(root.appending(path: "requests").path)'
          request=$(printf '%s' "$request" | sed 's#\\\\/#/#g')
          id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$request" in
            *'"method":"initialize"'*) respond "$id" '{"protocolVersion":2,"agentCapabilities":{"loadSession":true}}' ;;
            *'"method":"session/new"'*|*'"method":"session/load"'*)
              \(sessionPrelude)
              respond "$id" \(Self.quotedJSON(session)) ;;
            *'"method":"authenticate"'*|*'"method":"cursor/list_available_models"'*) respond "$id" '{}' ;;
            \(cases)
            *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unexpected fixture method"}}\\n' "$id" ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func client(requestedPermission: String?) throws -> LocalACPClient {
        try LocalACPClient.start(launch: .init(runtimeKind: kind, executableURL: executable,
            arguments: kind == .grokBuild ? ["agent", "stdio"] : [], requestedPermission: requestedPermission), workingDirectory: root)
    }

    func requests(method: String) throws -> [[String: Any]] {
        try String(contentsOf: root.appending(path: "requests"), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { $0["method"] as? String == method }
    }

    func launchArguments() throws -> [String] {
        try String(contentsOf: root.appending(path: "arguments"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func responses() throws -> [[String: Any]] {
        try String(contentsOf: root.appending(path: "responses"), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    static func quotedJSON(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return "'" + String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
