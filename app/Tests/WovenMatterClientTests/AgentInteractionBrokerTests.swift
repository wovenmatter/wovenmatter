import Foundation
import Testing
@testable import WovenMatterClient
import WovenMatterCore

struct AgentInteractionBrokerTests {
    @Test @MainActor func nativeSecretReplyStillResolvesOnDesktop() async {
        let broker = AgentInteractionBroker()
        let id = UUID()
        let answer = await withCheckedContinuation { continuation in
            broker.registerInteraction(id: id, request: .secret(prompt: "Enter a value"), continuation: continuation)
            #expect(!broker.resolveInteraction(id: id, response: .answers(["value": .single("fixture")])))
            #expect(broker.resolveInteraction(id: id, response: .secret(" fixture value ")))
            #expect(!broker.resolveInteraction(id: id, response: .cancelled))
        }
        #expect(answer == .secret(" fixture value "))
    }

    @Test @MainActor func invalidPermissionCannotConsumeAndFirstValidResponseWins() async {
        let broker = AgentInteractionBroker()
        let id = UUID()
        let answer = await withCheckedContinuation { continuation in
            broker.registerPermission(id: id, request: .init(title: "Run command?", options: [
                .init(id: "once", name: "Allow once", kind: "allow_once"),
                .init(id: "deny", name: "Deny", kind: "reject_once")
            ]), continuation: continuation)
            #expect(!broker.resolvePermission(id: id, optionID: "not-an-option"))
            #expect(broker.resolvePermission(id: id, optionID: "once"))
            #expect(!broker.resolvePermission(id: id, optionID: "deny"))
        }
        #expect(answer == "once")
    }

    @Test @MainActor func questionValidationPreservesPendingUntilCompleteAnswer() async {
        let broker = AgentInteractionBroker()
        let id = UUID()
        let request = LocalACPInteractionRequest.questions(.init(questions: [
            .init(id: "a", prompt: "Choose one", options: []),
            .init(id: "b", prompt: "Choose several", options: [], allowsMultiple: true)
        ]))
        let answer = await withCheckedContinuation { continuation in
            broker.registerInteraction(id: id, request: request, continuation: continuation)
            #expect(!broker.resolveInteraction(id: id, response: .planAccepted(true)))
            #expect(!broker.resolveInteraction(id: id, response: .answers(["a": .single("yes")])))
            #expect(!broker.resolveInteraction(id: id, response: .answers([
                "a": .multiple(["one", "two"]), "b": .single("text")
            ])))
            #expect(broker.resolveInteraction(id: id, response: .answers([
                "a": .single("freeform response"), "b": .multiple(["one", "two"])
            ])))
            #expect(!broker.resolveInteraction(id: id, response: .cancelled))
        }
        #expect(answer == .answers(["a": .single("freeform response"), "b": .multiple(["one", "two"])]))
    }

}
