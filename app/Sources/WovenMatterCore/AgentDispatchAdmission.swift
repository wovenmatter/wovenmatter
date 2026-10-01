import Foundation

/// A frontend's causal position, scoped to one backend lifetime. New sends keep
/// their current Stop sequence; clicking Stop advances it before any IPC await.
public struct AgentDispatchAdmission: Codable, Sendable {
    public let instanceID: UUID
    public let clientID: UUID
    public let stopSequence: UInt64
    public let observedStopRevision: UInt64

    public init(instanceID: UUID, clientID: UUID, stopSequence: UInt64, observedStopRevision: UInt64) {
        self.instanceID = instanceID
        self.clientID = clientID
        self.stopSequence = stopSequence
        self.observedStopRevision = observedStopRevision
    }
}

public enum AgentDispatchAdmissionError: LocalizedError, Equatable {
    case restarted, stopped, capacity, invalid
    public var errorDescription: String? {
        switch self {
        case .restarted: "The background service restarted. Wait for it to reconnect, then send again."
        case .stopped: "This message was stopped before it was sent. Send again to start a new turn."
        case .capacity: "The background service cannot track another conversation safely. Restart the app before sending."
        case .invalid: "Restart Woven Matter to update its background service before sending."
        }
    }
}

/// The execution owner serializes this value. Stop tombstones are never evicted:
/// capacity fails closed rather than letting a delayed request become new work.
public struct AgentDispatchAdmissionLedger: Sendable {
    private struct Client: Sendable {
        var sequence: UInt64
        var stopRevision: UInt64
    }
    private struct Conversation: Sendable {
        var revision: UInt64 = 0
        var clients: [UUID: Client] = [:]
    }
    public let instanceID: UUID
    private let capacity: Int
    private var clientCount = 0
    private var conversations: [String: Conversation] = [:]

    public init(instanceID: UUID, capacity: Int = 4_096) {
        precondition(capacity > 0)
        self.instanceID = instanceID
        self.capacity = capacity
    }

    public var stopRevisions: [String: UInt64] { conversations.mapValues(\.revision) }

    /// True means Stop must be performed before this input can be admitted. A
    /// newer send can carry a Stop that has not arrived on its own socket yet.
    public mutating func prepareSend(_ admission: AgentDispatchAdmission, conversationID: String) throws -> Bool {
        try validateIdentity(admission)
        var state = try conversation(conversationID)
        let previous = state.clients[admission.clientID]
        guard admission.stopSequence >= (previous?.sequence ?? 0) else { throw AgentDispatchAdmissionError.stopped }
        let advances = admission.stopSequence > (previous?.sequence ?? 0)
        // Even an unseen local Stop cannot override a newer Stop from another
        // frontend. The sender must have observed that shared revision first.
        try validateRevision(admission, state: state)
        if previous == nil, clientCount >= capacity { throw AgentDispatchAdmissionError.capacity }
        if advances {
            guard state.revision < UInt64.max else { throw AgentDispatchAdmissionError.capacity }
            state.revision += 1
        }
        state.clients[admission.clientID] = Client(sequence: admission.stopSequence,
            stopRevision: advances ? state.revision : previous?.stopRevision ?? 0)
        if previous == nil { clientCount += 1 }
        conversations[conversationID] = state
        return advances
    }

    /// Duplicate or late Stop from the same frontend is harmless. A Stop from
    /// another frontend advances the shared revision and fences every old send.
    public mutating func prepareStop(_ admission: AgentDispatchAdmission, conversationID: String) throws -> Bool {
        try validateIdentity(admission)
        guard admission.stopSequence > 0 else { throw AgentDispatchAdmissionError.invalid }
        var state = try conversation(conversationID)
        let previous = state.clients[admission.clientID]
        guard admission.stopSequence > (previous?.sequence ?? 0) else { return false }
        if previous == nil, clientCount >= capacity { throw AgentDispatchAdmissionError.capacity }
        guard state.revision < UInt64.max else { throw AgentDispatchAdmissionError.capacity }
        state.revision += 1
        state.clients[admission.clientID] = Client(sequence: admission.stopSequence, stopRevision: state.revision)
        if previous == nil { clientCount += 1 }
        conversations[conversationID] = state
        return true
    }

    /// Legacy Stop still stops current native/scheduled work, but also fences
    /// all versioned inputs created before it. Legacy sends are not admitted.
    public mutating func prepareLegacyStop(conversationID: String) throws {
        var state = try conversation(conversationID)
        guard state.revision < UInt64.max else { throw AgentDispatchAdmissionError.capacity }
        state.revision += 1
        conversations[conversationID] = state
    }

    /// Stop must still fence known clients when a new client cannot be recorded.
    /// This conversation then requires a backend restart; no tombstone is evicted.
    public mutating func refuseFurtherSends(conversationID: String) {
        guard conversations[conversationID] != nil else { return }
        conversations[conversationID]?.revision = UInt64.max
    }

    public func validateSend(_ admission: AgentDispatchAdmission, conversationID: String) throws {
        try validateIdentity(admission)
        guard let state = conversations[conversationID],
              state.clients[admission.clientID]?.sequence == admission.stopSequence else {
            throw AgentDispatchAdmissionError.stopped
        }
        try validateRevision(admission, state: state)
    }

    private func conversation(_ id: String) throws -> Conversation {
        guard !id.isEmpty, id.utf8.count <= 512 else { throw AgentDispatchAdmissionError.invalid }
        if let value = conversations[id] { return value }
        guard conversations.count < capacity else { throw AgentDispatchAdmissionError.capacity }
        return Conversation()
    }

    private func validateIdentity(_ admission: AgentDispatchAdmission) throws {
        guard admission.instanceID == instanceID else { throw AgentDispatchAdmissionError.restarted }
    }

    private func validateRevision(_ admission: AgentDispatchAdmission, state: Conversation) throws {
        guard state.revision < UInt64.max else { throw AgentDispatchAdmissionError.capacity }
        // An immediately following send may not have received its own Stop's
        // reply yet. Its sequence is sufficient only until another Stop occurs.
        let ownStop = state.clients[admission.clientID]?.stopRevision
        guard admission.observedStopRevision == state.revision
            || (ownStop != nil && ownStop != 0 && ownStop == state.revision) else {
            throw AgentDispatchAdmissionError.stopped
        }
    }
}
