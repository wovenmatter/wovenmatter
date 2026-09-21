import Foundation

/// One canonical continuation per provider request. The Mac owns this broker;
/// transport disconnects do not resolve or cancel any pending interaction.
@MainActor
public final class AgentInteractionBroker {
    private struct Permission {
        let request: LocalACPPermissionRequest
        let continuation: CheckedContinuation<String?, Never>
    }
    private struct Interaction {
        let request: LocalACPInteractionRequest
        let continuation: CheckedContinuation<LocalACPInteractionResponse, Never>
    }
    private var permissions: [UUID: Permission] = [:]
    private var interactions: [UUID: Interaction] = [:]

    public init() {}

    public func registerPermission(
        id: UUID,
        request: LocalACPPermissionRequest,
        continuation: CheckedContinuation<String?, Never>
    ) {
        precondition(permissions[id] == nil && interactions[id] == nil)
        permissions[id] = Permission(request: request, continuation: continuation)
    }

    public func registerInteraction(
        id: UUID,
        request: LocalACPInteractionRequest,
        continuation: CheckedContinuation<LocalACPInteractionResponse, Never>
    ) {
        precondition(permissions[id] == nil && interactions[id] == nil)
        interactions[id] = Interaction(request: request, continuation: continuation)
    }

    /// Validation precedes removal; an invalid response cannot consume a request.
    @discardableResult
    public func resolvePermission(id: UUID, optionID: String?) -> Bool {
        guard let pending = permissions[id],
              optionID == nil || pending.request.options.contains(where: { $0.id == optionID })
        else { return false }
        permissions.removeValue(forKey: id)
        pending.continuation.resume(returning: optionID)
        return true
    }

    @discardableResult
    public func resolveInteraction(id: UUID, response: LocalACPInteractionResponse) -> Bool {
        guard let pending = interactions[id], Self.isValid(response, for: pending.request)
        else { return false }
        interactions.removeValue(forKey: id)
        pending.continuation.resume(returning: response)
        return true
    }

    public static func isValid(
        _ response: LocalACPInteractionResponse,
        for request: LocalACPInteractionRequest
    ) -> Bool {
        switch (request, response) {
        case (_, .cancelled), (.plan, .planAccepted):
            return true
        case let (.secret, .secret(value)):
            return !value.isEmpty && value.utf8.count <= 32_768
        case let (.questions(request), .answers(answers)):
            guard Set(answers.keys) == Set(request.questions.map(\.id)) else { return false }
            return request.questions.allSatisfy { question in
                switch answers[question.id] {
                // Desktop supports freeform answers even on multiple-choice questions.
                case .single(let value):
                    return validText(value)
                case .multiple(let values):
                    return question.allowsMultiple && !values.isEmpty && values.count <= 100
                        && Set(values).count == values.count && values.allSatisfy(validText)
                case nil:
                    return false
                }
            }
        default:
            return false
        }
    }

    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= 32_768
    }
}
