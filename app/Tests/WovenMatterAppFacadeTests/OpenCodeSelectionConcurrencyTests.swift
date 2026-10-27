import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct OpenCodeSelectionConcurrencyTests {
    @Test func completedManualUpdateReleasesItsSendBarrierBeforeReturning() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let model = await OpenCodeModel(store: f.store, ownerDeviceID: UUID(), defaults: f.defaults)
        let task = try #require(model.updateSelection("chat"))
        try await task.value
        #expect(!model.updatingSessions.contains("chat"))
        try await model.applySessionSelections("chat", selections: .init())
        await model.shutdown()
    }

    @Test func openingChatSharesItsInFlightInitialSettings() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let model = await OpenCodeModel(store: f.store, ownerDeviceID: UUID(), defaults: f.defaults)
        let gate = FacadeGate(); gate.hold(); defer { gate.open() }
        var applications = 0
        model.applyInitialSessionTools = { _, _ in
            applications += 1
            await gate.pass()
        }
        let selections = SessionSelections(tools: ["notes"])
        let activation = Task { try await model.applySessionSelections("chat", selections: selections) }
        await gate.waitForArrival()
        var openingStarted = false
        let opening = Task {
            openingStarted = true
            try await model.applySessionSelections("chat", selections: selections)
        }
        while !openingStarted { await Task.yield() }
        #expect(model.updatingSessions.contains("chat"))
        #expect(applications == 1)
        // A different edit must still be rejected while activation owns the chat.
        await #expect(throws: (any Error).self) {
            try await model.applySessionSelections("chat", selections: .init(tools: ["history"]))
        }
        #expect(model.updateSelection("chat", model: "another-model") == nil)
        gate.open()
        try await activation.value
        try await opening.value
        #expect(applications == 1)
        #expect(!model.updatingSessions.contains("chat"))
        await model.shutdown()
    }

    @Test func sharedFailureReachesBothCallersAndAllowsAnExplicitRetry() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let model = await OpenCodeModel(store: f.store, ownerDeviceID: UUID(), defaults: f.defaults)
        let gate = FacadeGate(); gate.hold(); defer { gate.open() }
        var applications = 0
        model.applyInitialSessionTools = { _, _ in
            applications += 1
            await gate.pass()
            throw OpenCodeError.message("Fixture settings failure")
        }
        let selections = SessionSelections(tools: ["notes"])
        let activation = Task { try await model.applySessionSelections("chat", selections: selections) }
        await gate.waitForArrival()
        var openingStarted = false
        let opening = Task {
            openingStarted = true
            try await model.applySessionSelections("chat", selections: selections)
        }
        while !openingStarted { await Task.yield() }
        gate.open()
        for task in [activation, opening] {
            do { try await task.value; Issue.record("Failed settings were accepted") }
            catch { #expect(error.localizedDescription == "Fixture settings failure") }
        }
        #expect(applications == 1)
        #expect(!model.updatingSessions.contains("chat"))
        model.applyInitialSessionTools = { _, _ in applications += 1 }
        try await model.applySessionSelections("chat", selections: selections)
        #expect(applications == 2)
        #expect(!model.updatingSessions.contains("chat"))
        await model.shutdown()
    }
}
