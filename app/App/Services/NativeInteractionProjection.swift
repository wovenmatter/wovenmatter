import CryptoKit
import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

enum NativeInteractionProjection {
    static func responseIsSafeToJournal(_ command: LibraryCommand) -> Bool {
        guard command.interactionID?.hasPrefix("opencode:") == true else { return true }
        guard let response = command.response, response.answers.isEmpty else { return false }
        if command.interactionID?.hasPrefix("opencode:form:") == true {
            return response.cancelled && response.optionID == nil
        }
        return response.cancelled ? response.optionID == nil : ["once", "reject", "always"].contains(response.optionID ?? "")
    }

    static func id(link: OpenCodeSessionLink, kind: String, request: OpenCodeValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity: OpenCodeValue = ["connection": .string(link.connectionID),
            "session": .string(link.sessionID), "conversation": .string(link.conversationID),
            "kind": .string(kind), "request": request]
        let data = (try? encoder.encode(identity)) ?? Data()
        return "opencode:" + kind + ":" + SHA256.hash(data: data).hexString
    }

    static func pending(link: OpenCodeSessionLink, snapshot: OpenCodeSessionSnapshot,
                        runID: String?) -> [PendingInteraction] {
        let permissions = snapshot.permissions.compactMap { request -> PendingInteraction? in
            guard !request["id"].text.isEmpty, request["sessionID"].string == link.sessionID else { return nil }
            let ordinary = OpenCodePermissionHandling.libraryRequestID(request, sessionID: link.sessionID) != nil
            var options: [LibraryInteractionOption] = ordinary ? [.init(id: "once", label: "Allow Once")] : []
            if ordinary, !request["save"].array.isEmpty { options.append(.init(id: "always", label: "Always Allow")) }
            if ordinary { options.append(.init(id: "reject", label: "Reject")) }
            let detail = ordinary
                ? ([request["resources"].array.map(\.text).joined(separator: "\n"), request["message"].text]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n"))
                : "Review this OpenCode request in Woven Matter on your Mac."
            return .init(id: id(link: link, kind: "permission", request: request),
                conversationID: link.conversationID, runID: runID, kind: .approval,
                title: ordinary ? "Permission: " + request["action"].text : "Continue on your Mac",
                detail: detail, options: options)
        }
        let forms = snapshot.forms.compactMap { request -> PendingInteraction? in
            guard !request["id"].text.isEmpty else { return nil }
            return .init(id: id(link: link, kind: "form", request: request),
                conversationID: link.conversationID, runID: runID, kind: .approval,
                title: "Continue on your Mac",
                detail: "OpenCode needs a form completed in Woven Matter on your Mac. You can cancel this request here.")
        }
        return permissions + forms
    }
}

extension LibraryCommandService {
    func pendingNativeInteractions() async -> [PendingInteraction] {
        var result: [PendingInteraction] = []
        for native in model.openCodeInstances {
            for link in native.links.values.sorted(by: { $0.conversationID < $1.conversationID }) {
                let runID = await model.canonicalActiveRunID(conversationID: link.conversationID)
                guard native.isLocalSession(link.conversationID), let snapshot = native.snapshots[link.conversationID] else { continue }
                result += NativeInteractionProjection.pending(link: link, snapshot: snapshot, runID: runID)
            }
        }
        return result
    }

    func respondToNativeInteraction(_ command: LibraryCommand) async throws -> Bool {
        guard let interactionID = command.interactionID, interactionID.hasPrefix("opencode:") else { return false }
        guard NativeInteractionProjection.responseIsSafeToJournal(command),
              let conversationID = command.conversationID,
              let native = model.openCodeModel(for: conversationID), native.isLocalSession(conversationID),
              let link = native.links[conversationID], let snapshot = native.snapshots[conversationID],
              let response = command.response else { throw CommandError.interactionResolved }
        if let request = snapshot.permissions.first(where: {
            NativeInteractionProjection.id(link: link, kind: "permission", request: $0) == interactionID
        }) {
            let reply = response.cancelled ? "reject" : response.optionID ?? ""
            guard reply == "reject" || OpenCodePermissionHandling.libraryRequestID(request, sessionID: link.sessionID) != nil else {
                throw CommandError.interactionResolved
            }
            try await native.coordinator.replyToPermission(link, expectedRequest: request,
                expectedRunID: command.runID, reply: reply)
        } else if let request = snapshot.forms.first(where: {
            NativeInteractionProjection.id(link: link, kind: "form", request: $0) == interactionID
        }) {
            try await native.coordinator.cancelForm(link, expectedRequest: request, expectedRunID: command.runID)
        } else {
            throw CommandError.interactionResolved
        }
        return true
    }
}
