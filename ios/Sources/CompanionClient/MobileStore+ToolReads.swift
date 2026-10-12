import Foundation
import CryptoKit
import WovenMatterCompanion

extension MobileStore {
  static func historyTool(_ c: WovenMatterToolCommand, context: MobileToolContext, state: MobileStoreState, journal: WorkspaceJournalState) throws -> GatewayJSONValue {
    let conversations = state.conversations.merging(journal.conversations) { _, durable in durable }.filter { !journal.deletedConversationIDs.contains($0.key) }
    let transcripts = state.transcripts.merging(journal.transcripts) { _, durable in durable }
    let search = c.options["search"] ?? (c.action == "search" ? c.positional.first : nil) ?? ""
    let folder = c.options["folder"] ?? (c.options["all-workspace"] == nil ? context.folderID : nil)
    let since = try c.options["since"].map(MobileToolSupport.date), until = try c.options["until"].map(MobileToolSupport.date)
    if let since, let until, until < since { throw WorkspaceToolError.invalid("--until must be at or after --since.") }
    func permitted(_ id: String) -> Bool {
      guard let conversation = conversations[id] else { return id == context.sessionID }
      return (folder == nil || conversation.folderID == folder) && (c.options["conversation"] == nil || c.options["conversation"] == id) && (c.options["harness"] == nil || c.options["harness"] == conversation.runtimeKind)
    }
    func inRange(_ timestamp: String) -> Bool {
      guard since != nil || until != nil else { return true }
      guard let date = try? MobileToolSupport.date(timestamp) else { return false }
      return (since == nil || date >= since!) && (until == nil || date <= until!)
    }
    if c.action == "folders" { return try MobileToolSupport.page(state.folders.values.sorted { $0.id < $1.id }.map(MobileToolSupport.value), command: c) }
    if c.action == "harnesses" { return .object(["rows": .array([.object(["id": .string("pi-durable"), "name": .string("Pi Durable"), "workspaceID": .string(context.workspaceID)])]), "hasMore": .bool(false)]) }
    if c.action == "receipts" {
      let all = (state.toolReceipts ?? [:]).values.filter { $0.sessionID == context.sessionID }.sorted { $0.requestID < $1.requestID }
      let rows = all.filter { c.options["before"] == nil || $0.requestID < c.options["before"]! }
      return try MobileToolSupport.page(rows.map(MobileToolSupport.value), command: c)
    }
    if ["list", "status", "conversations"].contains(c.action) {
      let id = c.action == "status" ? try c.required("id", allowPositional: true) : nil
      let rows = conversations.values.filter { permitted($0.id) && (id == nil || $0.id == id) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search)) }.sorted { a,b in a.updatedAt == b.updatedAt ? a.id < b.id : c.options["sort"] == "oldest" ? a.updatedAt < b.updatedAt : a.updatedAt > b.updatedAt }
      if id != nil, rows.isEmpty { throw WorkspaceToolError.notFound("The requested session is not available on this device.") }
      return try MobileToolSupport.page(rows.map { row in
        var value = try MobileToolSupport.value(row).objectValue ?? [:]
        value["status"] = .string(row.activeRunID == nil ? "idle" : "working")
        value["transcriptAvailable"] = .bool(transcripts[row.id] != nil)
        if c.action == "status", let relation = state.localToolCoordinations?[row.id] {
          value["relationship"] = try MobileToolSupport.value(relation)
          value["coordinationEpoch"] = .string(relation.epoch)
          value["coordinatorID"] = .string(relation.coordinatorID)
          value["purpose"] = .string(relation.purpose)
          value["notifications"] = .bool(relation.notifications)
        }
        return .object(value)
      }, command: c)
    }
    if c.action == "conversation" {
      let id = try c.required("id", allowPositional: true)
      guard permitted(id), let transcript = transcripts[id] else { throw WorkspaceToolError.notFound("This conversation transcript is not saved on this device.") }
      let rows = try transcript.messages.map { message -> GatewayJSONValue in
        var value = try MobileToolSupport.value(message).objectValue ?? [:]
        value.merge(try MobileToolSupport.chunk(message.content, command: c)) { _, chunk in chunk }
        return .object(value)
      }
      var page = try MobileToolSupport.page(rows, command: c).objectValue ?? [:]
      page["conversationID"] = .string(id); page["olderRemoteHistoryAvailable"] = .bool(transcript.olderCursor != nil)
      return .object(page)
    }
    if c.action == "message" {
      let id = try c.required("id", allowPositional: true)
      guard let message = transcripts.values.flatMap(\.messages).first(where: { $0.id == id && permitted($0.conversationID) }) else { throw WorkspaceToolError.notFound("This message is not saved on this device.") }
      var value = try MobileToolSupport.value(message).objectValue ?? [:]
      value.merge(try MobileToolSupport.chunk(message.content, command: c)) { _, chunk in chunk }
      return .object(value)
    }
    if c.action == "runs" {
      var seen = Set<String>(), rows: [GatewayJSONValue] = []
      for transcript in transcripts.values.sorted(by: { $0.conversationID < $1.conversationID }) where permitted(transcript.conversationID) {
        for run in transcript.runs ?? [] where seen.insert(run.id).inserted {
          var value = try MobileToolSupport.value(run).objectValue ?? [:]
          value["conversationID"] = .string(transcript.conversationID)
          rows.append(.object(value))
        }
        for message in transcript.messages {
          if let id = message.runID, seen.insert(id).inserted { rows.append(.object(["id": .string(id), "conversationID": .string(transcript.conversationID), "status": .string(transcript.activeRunID == id ? "working" : "unknown")])) }
        }
      }
      return try MobileToolSupport.page(rows, command: c)
    }
    if ["search", "events", "event", "trace"].contains(c.action) {
      let id = c.action == "event" ? try c.required("id", allowPositional: true) : nil
      let run = c.options["run"] ?? (c.action == "trace" ? c.options["id"] ?? c.positional.first : nil)
      // Durable journal entries survive the bounded UI cache; do not pretend an
      // evicted UI transcript is the complete device history.
      func eventDate(_ entry: CompanionJournalEntry) -> String {
        entry.transcript?.messages.first?.createdAt ?? entry.conversation?.updatedAt ?? ""
      }
      var events: [CompanionJournalEntry] = []
      for entry in journal.entries.values {
        guard permitted(entry.conversationID) else { continue }
        if let id, entry.eventID != id { continue }
        if let run, entry.runID != run { continue }
        if entry.nativeRecord == nil {
          if let kind = c.options["kind"], kind != entry.kind.rawValue { continue }
          guard inRange(eventDate(entry)) else { continue }
        }
        events.append(entry)
      }
      events.sort { a, b in a.workspaceID == b.workspaceID ? a.originSequence < b.originSequence : a.workspaceID < b.workspaceID }
      var rows: [GatewayJSONValue] = []
      for event in events {
        // Native records retain full untruncated bodies. Reassemble and verify
        // their immutable chunks before applying character-window reads.
        var value: [String: GatewayJSONValue] = try MobileToolSupport.value(event).objectValue ?? [:]
        value.removeValue(forKey: "nativeRecord")
        var content = event.conversation?.title ?? ""
        if let transcript = event.transcript {
          let messages = transcript.messages.map { $0.content }.joined(separator: "\n")
          let activities = transcript.activities.map { $0.detail ?? $0.title }.joined(separator: "\n")
          content = messages + "\n" + activities
        }
        var nativeConversationID: String?
        if let metadata = event.nativeRecord {
          if id == nil, metadata.partIndex != 0 { continue }
          let parts = journal.entries.values.filter { $0.workspaceID == event.workspaceID && $0.conversationID == event.conversationID && $0.nativeRecord?.recordID == metadata.recordID }.sorted { $0.nativeRecord!.partIndex < $1.nativeRecord!.partIndex }
          guard parts.count == metadata.partCount, metadata.byteCount <= 32 * 1_024 * 1_024 else { throw MobileConnectionError.invalidResponse }
          var bytes = Data()
          for (index, part) in parts.enumerated() {
            guard let native = part.nativeRecord, native.partIndex == index, native.partCount == metadata.partCount, native.byteCount == metadata.byteCount, native.sha256 == metadata.sha256 else { throw MobileConnectionError.invalidResponse }
            bytes.append(native.data)
          }
          guard bytes.count == metadata.byteCount, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == metadata.sha256, let text = String(data: bytes, encoding: .utf8) else { throw MobileConnectionError.invalidResponse }
          content = text
          var recordedAt = eventDate(event), nativeKind: String?
          if let raw = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            if let identity = raw["conversationId"] { nativeConversationID = String(describing: identity) }
            nativeKind = raw["kind"] as? String
            if let timestamp = raw["createdAt"] as? String { recordedAt = timestamp }
            if metadata.format == "pi-durable.entry.v1", let model = (raw["model"] as? [[String: Any]])?.first,
               let milliseconds = model["timestamp"] as? Double, milliseconds.isFinite {
              recordedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
            }
          }
          if let kind = c.options["kind"], kind != event.kind.rawValue, kind != nativeKind { continue }
          guard inRange(recordedAt) else { continue }
          if !recordedAt.isEmpty { value["recordedAt"] = .string(recordedAt) }
          if let nativeKind { value["nativeKind"] = .string(nativeKind) }
          value["nativeRecordID"] = .string(metadata.recordID)
          value["nativeFormat"] = .string(metadata.format)
        }
        if let requested = c.options["native-conversation-id"], requested != nativeConversationID { continue }
        if !search.isEmpty, !content.localizedCaseInsensitiveContains(search) { continue }
        if let source = c.options["source-id"], source != event.workspaceID { continue }
        if let session = c.options["native-session-id"], session != event.conversationID { continue }
        if let record = c.options["native-record-id"], record != event.nativeRecord?.recordID { continue }
        if id != nil { value.removeValue(forKey: "transcript"); value.merge(try MobileToolSupport.chunk(content, command: c)) { _, chunk in chunk } }
        else { value["preview"] = .string(String(content.prefix(512))); value.removeValue(forKey: "transcript") }
        rows.append(.object(value))
      }
      if id != nil { guard let row = rows.first else { throw WorkspaceToolError.notFound("This history event is not saved on this device.") }; return row }
      if rows.isEmpty, c.action == "search", c.options["folder"] == nil, c.options["all-workspace"] == nil, context.folderID != nil {
        var broader = context; broader.folderID = nil
        return try historyTool(c, context: broader, state: state, journal: journal)
      }
      return try MobileToolSupport.page(rows, command: c)
    }
    throw WorkspaceToolError.invalid("This session operation requires the device execution adapter.")
  }

  func libraryTool(_ c: WovenMatterToolCommand) async throws -> GatewayJSONValue {
    let manifests = await artifacts.manifests().filter { !$0.deleted }
    if c.action == "read" {
      let id = try c.required("id", allowPositional: true)
      guard let manifest = manifests.first(where: { $0.id == id }) else { throw WorkspaceToolError.notFound("This library item is not available on this device.") }
      var value = try MobileToolSupport.value(manifest).objectValue ?? [:]
      value["downloaded"] = .bool(await artifacts.localURL(id: id) != nil)
      // Never return internal sandbox paths. The runtime adapter may explicitly
      // copy this saved artifact into the caller's workspace for file tools.
      return .object(value)
    }
    let query = c.options["search"] ?? "", kind = c.options["kind"]
    if let kind, !["file", "link", "photo"].contains(kind) { throw WorkspaceToolError.invalid("Library kind must be file, link, or photo.") }
    let workspaces = c.options["workspace"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) }
    let rows = manifests.filter { item in
      let mediaType = item.mediaType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
      let itemKind = mediaType.hasPrefix("image/") ? "photo" : mediaType == "text/uri-list" ? "link" : "file"
      return (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)) && (workspaces == nil || workspaces!.contains(item.workspaceID)) && (kind == nil || itemKind == kind)
    }.sorted { $0.id < $1.id }
    if c.options["harness"] != nil || c.options["sender"] != nil || c.options["since"] != nil || c.options["until"] != nil { throw WorkspaceToolError.invalid("These filters require the central library's retained-item attribution. Use target central when connected.") }
    return try MobileToolSupport.page(rows.map(MobileToolSupport.value), command: c, offsetKey: "offset")
  }
}
