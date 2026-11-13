#if DEBUG
import Foundation
import LibraryClient
import WovenMatterShared

/// UI fixture of a Page on this device: text, a task, a section with a child,
/// a table and an embedded original note. `page-incoming` also has a Quick
/// Chat tool add a component at the top once the writing "Mid typing" is saved,
/// as an agent on this device would while the Page is open.
extension MobileModel {
  static let pageFixtureID = "22222222-2222-4222-8222-222222222222"
  static let pageFixtureEmbeddedNoteID = "11111111-1111-4111-8111-111111111111"

  func seedPageFixture(_ store: MobileStore, incoming: Bool) async throws -> String {
    let id = Self.pageFixtureID
    if state.notes[id] == nil {
      let table = NoteTableBlock(id: "page-table", columns: [.init(), .init()], rows: [
        .init(cells: [.init(text: "Item"), .init(text: "Owner")]),
        .init(cells: [.init(text: "Tickets"), .init(text: "Sam")]),
      ], headerRowCount: 1)
      let page = NoteDocument(kind: .canvas, blocks: [
        .richText(.init(id: "page-intro", text: "Plan the weekend trip.")),
        .richText(.init(id: "page-task", text: "Book the train")),
        .richText(.init(id: "page-section", style: .heading2, text: "Packing")),
        .richText(.init(id: "page-child", text: "Bring the charger.")),
        .table(table),
        .richText(.init(id: "page-note-text", text: "Notes from the plan:")),
        .richText(.init(id: "page-embed")),
      ], canvas: ["page-embed": CanvasCardPlacement(x: 0, y: 0, assetID: Self.pageFixtureEmbeddedNoteID)],
        boardPurpose: "Weekend trip", boardItems: ["page-task": BoardItem(task: BoardTask())],
        pageNodes: ["page-section": PageNode(isSection: true), "page-child": PageNode(parentID: "page-section")])
      _ = try await store.createNote(folderID: "inbox", title: "Trip Page", content: try page.encoded(), id: id)
      await reload()
    }
    if incoming {
      Task { @MainActor [weak self] in
        for _ in 0..<1_200 {
          try? await Task.sleep(for: .milliseconds(100))
          guard let self, let store = self.store else { return }
          guard self.state.notes[id]?.content.contains("Mid typing") == true else { continue }
          let response = await store.executeLocalTool(.init(arguments: ["pages", "add-component", "--note-id", id,
            "--kind", "text", "--text", "Added from Quick Chat", "--at-start"], requestID: UUID().uuidString.lowercased()),
            context: .init(sessionID: "fixture-chat", workspaceID: self.state.deviceID, enabled: [.notes], sessionTitle: "Launch plan"))
          if !response.success { self.errorMessage = response.error ?? "The fixture Page edit failed." }
          await self.reload()
          return
        }
      }
    }
    return id
  }
}
#endif
