import Foundation

/// Settings waits for both halves of a restart: the old socket drops, then a new one opens.
public struct PiBotRestartProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, restarting, back, failed }
    public private(set) var phase: Phase
    public private(set) var dropped = false
    public let activeWork: Int
    public let mode: String
    public var isRestarting: Bool { phase == .restarting }

    public init() { phase = .idle; activeWork = 0; mode = "reload" }
    public init(activeWork: Int, mode: String) {
        phase = .restarting; self.activeWork = activeWork; self.mode = mode
    }

    public mutating func connectionChanged(connected: Bool) {
        guard isRestarting else { return }
        if !connected { dropped = true }
        else if dropped { phase = .back }
    }

    public mutating func timedOut() { if isRestarting { phase = .failed } }

    public func message(show: Bool) -> String? {
        switch phase {
        case .idle: return show ? "Saved. Restart Pi Bot to apply." : nil
        case .back: return "Pi Bot is back and running with the saved config."
        case .failed: return "Pi Bot has not come back yet. Check the server log; this page keeps reconnecting."
        case .restarting:
            let waiting = activeWork > 0
                ? " Letting \(activeWork) running turn\(activeWork == 1 ? "" : "s") finish (up to 15 s); anything still running resumes after the restart." : ""
            return "Restarting Pi Bot…\(waiting) This page reconnects on its own."
                + (mode == "exit" ? " Waiting for the service manager to start it again." : "")
        }
    }
}

/// Provider prose stays prose unless it contains at least two numbered instructions.
public struct PiBotLoginSteps: Equatable, Sendable {
    public let lead: [String]
    public let steps: [String]

    public init(_ text: String) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let pattern = #"^\d+\.\s+"#
        let numbered = lines.filter { $0.range(of: pattern, options: .regularExpression) != nil }
        if numbered.count < 2 {
            lead = [text]; steps = []
        } else {
            lead = lines.filter { $0.range(of: pattern, options: .regularExpression) == nil }
            steps = numbered.map { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        }
    }
}

/// A provider may send its first prompt before `login.start` returns the login id.
/// Match the web client's bounded backlog, then drain it when the panel subscribes.
public struct PiBotLoginBacklog: Sendable {
    private var events: [String: [PiBotLoginEvent]] = [:]
    private var order: [String] = []

    public init() {}

    public mutating func append(_ event: PiBotLoginEvent, loginID: String) {
        if events[loginID] == nil { order.append(loginID) }
        events[loginID, default: []].append(event)
        if order.count > 20 { events[order.removeFirst()] = nil }
    }

    public mutating func take(loginID: String) -> [PiBotLoginEvent] {
        order.removeAll { $0 == loginID }
        return events.removeValue(forKey: loginID) ?? []
    }

    public mutating func removeAll() { events = [:]; order = [] }
}
