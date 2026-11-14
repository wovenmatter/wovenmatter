import AppKit
import SwiftUI
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized) struct PageEditorTests {
    private func editor(_ original: NoteDocument, editsPageFlow: Bool = true) -> (NoteEditor.Coordinator, NSTextView, () -> NoteDocument) {
        final class Storage { var value: NoteDocument; init(_ value: NoteDocument) { self.value = value } }
        let storage = Storage(original)
        let controller = NoteEditorController()
        let editor = NoteEditor(document: Binding(get: { storage.value }, set: { storage.value = $0 }),
            controller: controller, sizesToContent: true, editsPageFlow: editsPageFlow)
        let coordinator = editor.makeCoordinator()
        let view = NSTextView()
        view.isEditable = true
        view.delegate = coordinator
        coordinator.bind(view)
        coordinator.apply(original, to: view)
        return (coordinator, view, { storage.value })
    }

    /// An original Note embedded in a Page sizes to its content but keeps
    /// ordinary Notes editing. Its multiline block splits into paragraphs, and
    /// typing elsewhere must not restore the original block beside them.
    @Test func embeddedOriginalNoteTypingDoesNotDuplicateMultilineText() {
        let original = NoteDocument(kind: .note, blocks: [
            .richText(.init(id: "lines", text: "Line A\nLine B")), .richText(.init(id: "other", text: "Other"))])
        let (coordinator, view, saved) = editor(original, editsPageFlow: false)
        for (typed, addition) in [("Other", " text"), ("Other text", " again")] {
            let end = NSMaxRange((view.string as NSString).range(of: typed))
            view.textStorage!.replaceCharacters(in: NSRange(location: end, length: 0), with: addition)
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        }
        #expect(saved().blocks.map(\.plainText) == ["Line A", "Line B", "Other text again"])
        #expect(saved().kind == .note)
        #expect(saved().boardItems == nil)
    }

    @Test func emptyInsertionSlotsNeverReuseAnIDThatWasMovedIntoThePage() {
        let context = PageFlowEditingContext()
        var page = NoteDocument(kind: .canvas, blocks: [], pageNodes: [:])
        let first = context.emptyBlockID(in: page)
        #expect(context.emptyBlockID(in: page) == first)
        page.blocks = [.richText(.init(id: first, text: "Moved elsewhere"))]
        let next = context.emptyBlockID(in: page)
        #expect(next != first)
        #expect(context.emptyBlockID(in: page) == next)
    }

    @Test func nativeParsingDropsDefaultOnlyPageMetadata() {
        let original = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "a", text: "Plain"))], boardItems: ["a": .init()])
        let (coordinator, view, saved) = editor(original)
        view.insertText("Edited", replacementRange: NSRange(location: 0, length: 5))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(saved().boardItems == nil)
    }

    @Test func enteringBeforeTaskTextKeepsItsIdentityAndAssignmentOnTheExistingText() throws {
        let block = NoteRichTextBlock(id: "task", text: "Book the train")
        let original = NoteDocument(kind: .canvas, blocks: [.richText(block)],
            boardItems: [block.id: .init(task: .init(status: .doing, assignee: "Travel agent", outcome: "Compare fares"))])
        let (coordinator, view, saved) = editor(original)
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        let result = saved()
        #expect(result.blocks.count == 2)
        #expect(result.blocks.first?.id != block.id)
        #expect(result.blocks.last?.id == block.id)
        #expect(result.blocks.last?.plainText == block.plainText)
        #expect(result.boardItems?[block.id]?.task?.assignee == "Travel agent")
        #expect(result.boardItems?[block.id]?.task?.outcome == "Compare fares")
        #expect(result.boardItems?[result.blocks[0].id]?.task?.status == .todo)
    }

    @Test func nativeTaskCheckboxUpdatesDurableDocumentMetadata() throws {
        let original = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "task", text: "Pack"))],
            boardItems: ["task": .init(task: .init(assignee: "Trey"))])
        let (coordinator, _, saved) = editor(original)
        coordinator.toggleTask("task")
        #expect(saved().boardItems?["task"]?.task?.status == .done)
        #expect(saved().boardItems?["task"]?.task?.assignee == "Trey")
        let reopened = try NoteDocument.editableDocument(from: saved().encoded())
        #expect(reopened.boardItems?["task"]?.task?.status == .done)
        coordinator.toggleTask("task")
        #expect(saved().boardItems?["task"]?.task?.status == .todo)
    }

    /// Typing in Component details changes only task metadata. The flow keeps
    /// its text and history, and its stored metadata follows the new details.
    @Test func detailsOnlyChangesRefreshTaskMetadataInPlace() {
        let original = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "task", text: "Pack"))],
            boardItems: ["task": .init(task: .init(assignee: "Trey"))])
        let (coordinator, view, saved) = editor(original)
        let text = NSAttributedString(attributedString: view.attributedString())
        var details = original
        details.boardItems?["task"]?.task?.outcome = "Bags are ready"
        coordinator.apply(details, to: view)
        #expect(view.string == text.string)
        coordinator.toggleTask("task")
        #expect(saved().boardItems?["task"]?.task?.status == .done)
        #expect(saved().boardItems?["task"]?.task?.outcome == "Bags are ready")
        #expect(saved().boardItems?["task"]?.task?.assignee == "Trey")
    }

    @Test func legacyMultilineContentKeepsOneStableComponentWhileTyping() throws {
        let original = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "legacy", text: "First line\nSecond line"))],
            boardItems: ["legacy": .init(task: .init(outcome: "Existing outcome"))])
        let (coordinator, view, saved) = editor(original)
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Updated")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(saved().blocks.count == 1)
        #expect(saved().blocks[0].id == "legacy")
        #expect(saved().blocks[0].plainText == "Updated line\nSecond line")
        #expect(saved().boardItems?["legacy"]?.task?.outcome == "Existing outcome")
    }

    @Test func flowingTextPreservesStyledRunsListsAndTables() throws {
        let block = NoteRichTextBlock(id: "list", style: .bulletedList,
            runs: [.init(text: "Keep bold", bold: true), .init(text: " and a link", link: "https://example.com")])
        var table = NoteTableBlock(rows: 2, columns: 2, headerRow: true)
        table.rows[0].cells[0].runs = [.init(text: "Stored cell")]
        let original = NoteDocument(kind: .canvas, blocks: [.richText(block), .table(table)])
        let (coordinator, view, saved) = editor(original)
        let range = (view.string as NSString).range(of: "Keep bold")
        view.textStorage!.replaceCharacters(in: range, with: "Changed bold")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        guard case .richText(let text) = saved().blocks[0], case .table(let result) = saved().blocks[1] else {
            Issue.record("The native editor lost a component"); return
        }
        #expect(text.style == .bulletedList)
        #expect(text.runs.first?.bold == true)
        #expect(text.runs.last?.link == "https://example.com")
        #expect(result.id == table.id)
        #expect(result.rows[0].cells[0].plainText == "Stored cell")
        #expect(result == table)
    }

    @Test func typingDoesNotRewriteUntouchedParagraphsWithNativeFormattingDefaults() {
        let original = NoteDocument(kind: .canvas, blocks: [
            .richText(.init(id: "a", text: "First")), .richText(.init(id: "b", text: "Untouched"))])
        let (coordinator, view, saved) = editor(original)
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Edited")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(saved().blocks[1] == original.blocks[1])
    }

    @Test func nativeEnterCreatesAStableTaskComponentAcrossFurtherTyping() {
        let original = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "task", text: "Pack"))],
            boardItems: ["task": .init(task: .init(assignee: "Trey", outcome: "Existing task"))])
        let (coordinator, view, saved) = editor(original)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(coordinator.textView(view, doCommandBy: #selector(NSTextView.insertNewline(_:))))
        let id = saved().blocks.last!.id
        #expect(id != "task")
        view.insertText("Next", replacementRange: view.selectedRange())
        #expect(saved().blocks.last?.id == id)
        view.insertText(" task", replacementRange: view.selectedRange())
        #expect(saved().blocks.last?.id == id)
        #expect(saved().blocks.last?.plainText == "Next task")
        #expect(saved().boardItems?[id]?.task?.status == .todo)
        #expect(saved().boardItems?[id]?.task?.assignee.isEmpty == true)
        #expect(saved().boardItems?["task"]?.task?.outcome == "Existing task")
    }

    @Test func restoringNativeUndoAttributesRecoversTaskIdentityAndOutcome() {
        let original = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "task", text: "Pack"))],
            boardItems: ["task": .init(task: .init(assignee: "Trey", outcome: "Keep this outcome"))])
        let (coordinator, view, saved) = editor(original)
        let previous = NSAttributedString(attributedString: view.attributedString())
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: view.string.utf16.count), with: "")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        view.textStorage!.setAttributedString(previous)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(saved().blocks.first?.id == "task")
        #expect(saved().boardItems?["task"]?.task?.assignee == "Trey")
        #expect(saved().boardItems?["task"]?.task?.outcome == "Keep this outcome")
    }
}

@MainActor struct ArtifactInputBridgeTests {
    @Test func acceptedInputQueueSurvivesViewClosureAndParticipatesInShutdownFlush() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.database.createNote(folderID: nil, title: "Planner", content: NoteDocument(kind: .html, html: "<input id='title'>").encoded(), kind: .html)
        await fixture.model.refreshWorkspace()
        let first = fixture.model.enqueueArtifactInput(noteID: id, edit: .init(action: .set, key: "app:title", value: .string("a")))
        let second = fixture.model.enqueueArtifactInput(noteID: id, edit: .init(action: .set, key: "app:title", value: .string("ab")), after: first)
        _ = fixture.model.enqueueArtifactInput(noteID: id, edit: .init(action: .set, key: "app:title", value: .string("abc")), after: second)
        fixture.model.suspendNoteEditing()
        #expect(await fixture.model.flushNotesBeforeBackendClientQuit())
        let saved = try #require(try await fixture.database.readNoteForEditing(id: id).document)
        #expect(saved.artifactState?["app:title"]?.value == .string("abc"))
        #expect(saved.artifactState?["app:title"]?.version == 3)
        #expect(fixture.model.artifactInputWrites.isEmpty)
    }

    @Test func queuedInputCannotOverwriteAnInterveningWriter() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.database.createNote(folderID: nil, title: "Planner", content: NoteDocument(kind: .html, html: "<main>Planner</main>").encoded(), kind: .html)
        await fixture.model.refreshWorkspace()
        let first = fixture.model.enqueueArtifactInput(noteID: id, edit: .init(action: .set, key: "app:title", value: .string("Mine")))
        _ = try await first.value
        _ = try await fixture.database.applyArtifactStateEdit(noteID: id,
            edit: .init(action: .set, key: "app:title", value: .string("Other writer"), expectedVersion: 1))
        let continued = fixture.model.enqueueArtifactInput(noteID: id,
            edit: .init(action: .set, key: "app:title", value: .string("Continued typing")), after: first)
        await #expect(throws: ArtifactInputFailure.self) { try await continued.value }
        let saved = try #require(try await fixture.database.readNoteForEditing(id: id).document)
        #expect(saved.artifactState?["app:title"]?.value == .string("Other writer"))
    }

    @Test func aFailedInputStillFlushesAnUnrelatedNote() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let id = try await f.database.createNote(folderID: nil, title: "Writing", content: "Before")
        await f.model.refreshWorkspace()
        let note = try #require(f.model.workspaceOverview?.notes.first { $0.id == id })
        f.model.updateNoteDraft(note: note, content: "Saved despite the unrelated input error")
        let failure = Task<ArtifactStateWriteResult, any Error> { throw ArtifactInputError.saveFailed }
        let key = UUID()
        f.model.artifactInputWrites[key] = failure
        #expect(!(await f.model.flushNotesBeforeBackendClientQuit()))
        #expect(try await f.database.readNoteForEditing(id: id).document?.plainText == "Saved despite the unrelated input error")
        f.model.artifactInputWrites[key] = nil
    }

    /// Input that failed before quitting and still waits for Retry blocks the quit
    /// barrier, even though no write is in flight; retrying or closing releases it.
    @Test func earlierFailedInputBlocksQuitUntilRetriedOrClosed() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let coordinator = HTMLArtifactView(html: "", linkedDataJSON: nil,
            reportUnsaved: { f.model.setArtifactInputsUnsaved(generation: $0, $1) }).makeCoordinator()
        coordinator.token = "current"
        coordinator.updateSaveError("Conflict", key: "app:a", generation: "current")
        #expect(f.model.artifactInputWrites.isEmpty)
        #expect(!(await f.model.flushNotesBeforeBackendClientQuit()))
        coordinator.updateSaveError(nil, key: "app:a", generation: "current")
        #expect(await f.model.flushNotesBeforeBackendClientQuit())
        coordinator.updateSaveError("Conflict", key: "app:a", generation: "current")
        f.model.setArtifactInputsUnsaved(generation: "current", false)
        #expect(await f.model.flushNotesBeforeBackendClientQuit())
    }

    @Test func anErrorOnOneKeySurvivesAnotherKeysSuccessAndOldGenerationReplies() {
        var visible: String?
        let coordinator = HTMLArtifactView(html: "", linkedDataJSON: nil, onSaveError: { visible = $0 }).makeCoordinator()
        coordinator.token = "current"
        coordinator.updateSaveError("Keep this error", key: "app:a", generation: "current")
        coordinator.updateSaveError(nil, key: "app:b", generation: "current")
        #expect(visible == "Keep this error")
        coordinator.updateSaveError(nil, key: "app:a", generation: "old")
        #expect(visible == "Keep this error")
        coordinator.updateSaveError(nil, key: "app:a", generation: "current")
        #expect(visible == nil)
    }

    @Test func theOpenPageAdoptsItsMergedSaveAndDoesNotCreateAnotherCopyOnTheNextEdit() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let base = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "a", text: "Base"))], pageNodes: [:])
        let id = try await f.database.createNote(folderID: nil, title: "Page", content: base.encoded(), kind: .canvas)
        await f.model.refreshWorkspace()
        let note = try #require(f.model.workspaceOverview?.notes.first { $0.id == id })
        f.model.prepareNoteDraft(note)
        var remote = base
        remote.blocks = [.richText(.init(id: "a", text: "Remote"))]
        _ = try await f.database.persistNoteDraft(id: id, title: "Page", content: remote.encoded(), expectedRevision: note.revision, baseContent: note.content, baseTitle: note.title)
        var local = base
        local.blocks = [.richText(.init(id: "a", text: "Local"))]
        f.model.updateNoteDraft(note: note, content: try local.encoded())
        #expect(await f.model.flushNoteDrafts())
        // Completion and snapshot reconciliation deliberately run asynchronously.
        for _ in 0..<100 {
            await f.model.refreshWorkspace()
            let current = try #require(f.model.workspaceOverview?.notes.first { $0.id == id })
            f.model.prepareNoteDraft(current)
            if f.model.noteDraft(for: current).editRevision == 0 { break }
            await Task.yield()
        }
        let current = try #require(f.model.workspaceOverview?.notes.first { $0.id == id })
        let draft = f.model.noteDraft(for: current)
        var merged = try NoteDocument.editableDocument(from: draft.content)
        #expect(Set(merged.blocks.map(\.plainText)) == ["Remote", "Local"])
        let copyID = try #require(merged.blocks.first { $0.plainText == "Local" }?.id)
        #expect(copyID.hasPrefix("conflict-"))
        #expect(draft.reconciliationNotice != nil)
        #expect(draft.conflictComponentRemaps["a"] == copyID)
        merged.blocks = merged.blocks.map { $0.id == copyID ? .richText(.init(id: copyID, text: "Continued")) : $0 }
        f.model.updateNoteDraft(note: current, content: try merged.encoded())
        #expect(await f.model.flushNoteDrafts())
        let saved = try #require(try await f.database.readNoteForEditing(id: id).document)
        #expect(saved.blocks.count == 2)
        #expect(Set(saved.blocks.map(\.plainText)) == ["Remote", "Continued"])
    }

    @Test func stateProjectionKeepsSavedNullAndRemovalVersionsDistinct() throws {
        let snapshot = DesktopArtifactStateSnapshot([
            "app:null": .init(value: .null, version: 2, updatedAt: "now"),
            "app:removed": .init(value: nil, version: 3, updatedAt: "now")
        ])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(snapshot.json.utf8))
        #expect(value.objectValue?["values"]?.objectValue?["app:null"] == .null)
        #expect(value.objectValue?["values"]?.objectValue?["app:removed"] == nil)
        #expect(value.objectValue?["versions"]?.objectValue?["app:removed"]?.intValue == 3)
    }

    @Test func nativeMessageIsBoundToItsDocumentGenerationAndHasNoDocumentSelector() throws {
        let body: [String: Any] = ["token": "current", "requestID": "1", "noteID": "forged-other-document",
            "edit": ["action": "set", "key": "app:x", "value": NSNull()]]
        let request = try ArtifactStateMessage.decode(body, token: "current")
        #expect(request.edit.value == .null)
        #expect(throws: (any Error).self) { try ArtifactStateMessage.decode(body, token: "different") }
        #expect(throws: (any Error).self) {
            try ArtifactStateMessage.decode(["token": "current", "requestID": "2", "edit": ["value": String(repeating: "x", count: 90_000)]], token: "current")
        }
    }

    @Test func savedStateCannotEscapeTheRendererBootstrap() throws {
        let hostile = "</script><img src=x onerror=alert(1)>\u{2028}"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(JSONValue.object(["value": .string(hostile)])), as: UTF8.self)
        let html = HTMLArtifactDocument.render(html: "<main>Artifact</main>", linkedDataJSON: nil,
            artifactConfigurationJSON: json)
        #expect(!html.contains(hostile))
        #expect(html.contains("\\u003c/script\\u003e"))
        #expect(html.contains("window.__wovenArtifactConfiguration"))
        #expect(html.contains("default-src 'none'"))
    }
}
