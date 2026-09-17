import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore


extension ApplicationModel {
    private struct AgentNoteBinding {
        enum Transport {
            case local(environment: [String: String])
            case mediated(nonce: String, structureJSON: String)
        }

        let context: AgentNoteContext
        let kind: NoteArtifactKind
        let transport: Transport
    }

    private func makeAgentNoteBinding(
        _ note: WorkspaceNoteRecord?,
        store: DashboardStore,
        mediated: Bool
    ) async throws -> AgentNoteBinding? {
        guard let note else { return nil }
        guard flushNoteDrafts() else {
            throw ApplicationModelError.noteDraftSaveFailed
        }
        let response = try await store.handleNoteEditingRequest(
            NoteEditingRequest(command: .read, noteID: note.id)
        )
        guard response.success,
              let title = response.title,
              let revision = response.revision,
              let document = response.document else {
            throw ApplicationModelError.noteContextUnavailable
        }
        let transport: AgentNoteBinding.Transport
        let remoteNonce: String?
        if mediated {
            let nonce = UUID().uuidString.lowercased()
            remoteNonce = nonce
            transport = .mediated(
                nonce: nonce,
                structureJSON: Self.redactedNoteStructure(document)
            )
        } else {
            remoteNonce = nil
            let environment = noteCLIEnvironment(noteID: note.id)
            guard environment["WOVEN_NOTE_CLI"] != nil,
                  environment["WOVEN_NOTE_SOCKET"] != nil else {
                throw ApplicationModelError.noteContextUnavailable
            }
            transport = .local(environment: environment)
        }
        return AgentNoteBinding(
            context: AgentNoteContext(
                noteID: note.id,
                title: title,
                folderID: note.folderID,
                revision: revision,
                remoteEditNonce: remoteNonce,
                artifactKind: mediated ? document.kind : nil
            ),
            kind: document.kind,
            transport: transport
        )
    }

    private func noteAwarePrompt(
        _ content: String,
        binding: AgentNoteBinding?
    ) -> String {
        guard let binding else { return content }
        switch binding.transport {
        case .local(let environment):
            return localNoteAwarePrompt(content, binding: binding, environment: environment)
        case .mediated(let nonce, let structureJSON):
            return mediatedNoteAwarePrompt(
                content,
                binding: binding,
                nonce: nonce,
                structureJSON: structureJSON
            )
        }
    }

    private func localNoteAwarePrompt(
        _ content: String,
        binding: AgentNoteBinding,
        environment: [String: String]
    ) -> String {
        let exports = [
            "WOVEN_NOTE_CLI",
            "WOVEN_NOTE_SOCKET",
            "WOVEN_NOTE_ID",
            "WOVEN_DATABASES_DIR",
        ]
            .compactMap { key in
                environment[key].map { "export \(key)=\($0.shellQuoted)" }
            }
            .joined(separator: "\n")
        let editingGuidance: String
        switch binding.kind {
        case .note:
            editingGuidance = """
            This is a regular note. Preserve its prose. Databases attach to individual tables:
            "$WOVEN_NOTE_CLI" append --text "Text" --revision REVISION
            "$WOVEN_NOTE_CLI" table create --rows 3 --columns 3 --header --revision REVISION
            "$WOVEN_NOTE_CLI" table set-cell --table-id TABLE_ID --row 0 --column 0 --text "Value" --revision REVISION
            "$WOVEN_NOTE_CLI" link --source-id SOURCE --database-id DATABASE --path data.json --table-id TABLE_ID --revision REVISION
            """
        case .spreadsheet:
            editingGuidance = """
            This note is an editable spreadsheet. Read it to obtain its table ID, then use table operations to populate cells. The whole spreadsheet may link to database data:
            "$WOVEN_NOTE_CLI" table set-cell --table-id TABLE_ID --row 0 --column 0 --text "Value" --revision REVISION
            "$WOVEN_NOTE_CLI" link --source-id SOURCE --database-id DATABASE --path data.json --revision REVISION
            """
        case .html:
            editingGuidance = """
            This note is an HTML artifact. The user owns its title; render the artifact body with:
            "$WOVEN_NOTE_CLI" set-html --file artifact.html --revision REVISION
            Link database data with:
            "$WOVEN_NOTE_CLI" link --source-id SOURCE --database-id DATABASE --path data.json --revision REVISION
            Linked JSON is available to the rendered page as window.wovenMatterData.
            """
        }
        return """
        \(content)

        <woven-matter-note>
        The open Woven Matter note "\(binding.context.title)" is attached to this run. You may read and edit it with the local CLI. Use the current revision returned by `read` when applying related changes. Changes appear immediately in the open editor.

        \(exports)
        "$WOVEN_NOTE_CLI" read

        \(editingGuidance)
        "$WOVEN_NOTE_CLI" apply --file operations.json --revision REVISION
        Read the artifact first, preserve unrelated content, and use the CLI rather than editing Woven Matter's SQLite store directly. Database folders themselves are available under "$WOVEN_DATABASES_DIR".
        </woven-matter-note>
        """
    }

    private func mediatedNoteAwarePrompt(
        _ content: String,
        binding: AgentNoteBinding,
        nonce: String,
        structureJSON: String
    ) -> String {
        let begin = RemoteNoteEditEnvelope.beginMarker(nonce: nonce)
        let end = RemoteNoteEditEnvelope.endMarker(nonce: nonce)
        let kindGuidance: String
        switch binding.kind {
        case .note:
            kindGuidance = "Preserve prose. Database links belong on individual tables."
        case .spreadsheet:
            kindGuidance = "Edit cells using the table ID below; an artifact-level database link is allowed."
        case .html:
            kindGuidance = "The user owns the title. You may replace the HTML body and set an artifact-level database link, but must not emit setTitle."
        }
        return """
        \(content)

        <woven-matter-note>
        The open Woven Matter \(binding.kind.displayName.lowercased()) "\(binding.context.title)" is attached to this remote run. \(kindGuidance)
        For privacy, only its structural map is attached; existing prose, cell values, and HTML are not sent:
        \(structureJSON)

        If and only if you want to edit the artifact, append exactly one revision-checked JSON envelope after your normal response, without a Markdown code fence:
        \(begin)
        {"version":1,"nonce":"\(nonce)","noteID":"\(binding.context.noteID)","expectedRevision":"\(binding.context.revision)","operations":[{"type":"appendText","text":"Example","style":"paragraph"}]}
        \(end)
        Use only NoteEditOperation JSON. The envelope is limited to 1 MiB and 128 operations. Woven Matter applies it only after this run completes successfully and only if the note revision still matches. Never attempt to access Woven Matter's SQLite store directly.
        </woven-matter-note>
        """
    }

    private nonisolated static func redactedNoteStructure(_ document: NoteDocument) -> String {
        let blocks: [[String: Any]] = document.blocks.map { block in
            switch block {
            case .richText(let richText):
                return [
                    "id": richText.id,
                    "type": "richText",
                    "style": richText.style.rawValue,
                ]
            case .table(let table):
                return [
                    "id": table.id,
                    "type": "table",
                    "rows": table.rows.count,
                    "columns": table.columns.count,
                    "headerRows": table.headerRowCount,
                ]
            }
        }
        let object: [String: Any] = [
            "version": NoteDocument.currentVersion,
            "kind": document.kind.rawValue,
            "blocks": blocks,
            "hasArtifactDatabaseLink": document.databaseLink != nil,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    func sendAgentMessage(
        conversation: WorkspaceConversationRecord,
        content: String,
        note: WorkspaceNoteRecord? = nil
    ) async -> Bool {
        await sendAgentMessage(
            conversation: conversation,
            input: AgentMessageInput(text: content),
            note: note
        )
    }

    func stageMessageAttachments(
        _ files: [(url: URL, mimeType: String)]
    ) async throws -> [AgentMessageAttachmentDraft] {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        var staged: [AgentMessageAttachmentDraft] = []
        for file in files {
            staged.append(try await dashboardStore.stageMessageAttachment(
                fileURL: file.url,
                mimeType: file.mimeType
            ))
        }
        return staged
    }

    func noteAttachmentDraft(_ note: WorkspaceNoteRecord) -> AgentMessageAttachmentDraft {
        let folder = note.folderID.flatMap { folderID in
            workspaceOverview?.folders.first(where: { $0.id == folderID })
        }
        return .reference(AgentMessageReferenceDraft(
            kind: .note,
            resourceID: note.id,
            titleSnapshot: note.title,
            contentSnapshot: String(note.content.prefix(AgentMessageAttachmentLimits.maximumReferenceCharacters)),
            revisionSnapshot: note.updatedAt ?? note.createdAt ?? "",
            folderIDSnapshot: note.folderID,
            folderTitleSnapshot: folder?.name
        ))
    }

    func conversationAttachmentDraft(
        _ conversation: WorkspaceConversationRecord
    ) async throws -> AgentMessageAttachmentDraft {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        let content = try await dashboardStore.conversationContent(id: conversation.id)
        let preview = DashboardConversationReferencePreview.make(
            messages: content.messages,
            limit: AgentMessageAttachmentLimits.maximumReferenceCharacters
        )
        return .reference(AgentMessageReferenceDraft(
            kind: .conversation,
            resourceID: conversation.id,
            titleSnapshot: conversation.title,
            contentSnapshot: preview,
            revisionSnapshot: conversation.lastMessageAt ?? "",
            folderIDSnapshot: conversation.folderID,
            folderTitleSnapshot: conversation.folderID.flatMap { folderID in
                workspaceOverview?.folders.first(where: { $0.id == folderID })?.name
            },
            agentCodenameSnapshot: conversation.agentCodename
        ))
    }

    @discardableResult
    func sendAgentMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        note: WorkspaceNoteRecord? = nil
    ) async -> Bool {
        let conversationState = ensureConversationState(id: conversation.id)
        if conversation.localRuntimeKind == .hermes, conversation.remoteWorkspaceID == nil,
           !buzzBoundLocalACPConversationIDs.contains(conversation.id) {
            do { try requireLocalHermesLink(conversationID: conversation.id, openSettings: true) }
            catch { conversationState.setError(error.localizedDescription); return false }
        }
        guard !usesLocallyInstalledRuntime(conversation) || installingLocalACPRuntimeKinds.isEmpty else {
            conversationState.setError("Wait for runtime installation or update to finish before sending a message.")
            return false
        }
        let normalized = AgentMessageInput(
            text: input.text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: input.attachments
        )
        guard normalized.hasContent, let dashboardStore else {
            conversationState.setError(
                ApplicationModelError.localACPRuntimeUnavailable.localizedDescription
            )
            return false
        }
        if conversation.localRuntimeKind == .opencode {
            do {
                guard let openCode = openCodeModel(for: conversation.id) else { throw OpenCodeError.message("This workspace's OpenCode connection is unavailable.") }
                try await openCode.send(conversation.id, input: normalized)
                conversationState.setError(nil)
                return true
            } catch { conversationState.setError(error.localizedDescription); return false }
        }
        guard !loadingLocalACPSessionIDs.contains(conversation.id),
              !updatingLocalACPSessionIDs.contains(conversation.id) else {
            conversationState.setError(
                ApplicationModelError.localSessionConfigurationInProgress
                    .localizedDescription
            )
            return false
        }
        let isSteeringActiveTurn = localRunningConversationIDs.contains(
            conversation.id
        )
        if !isSteeringActiveTurn {
            guard localRunningConversationIDs.count
                    < Self.maximumActiveTurnCount else {
                conversationState.setError(
                    ApplicationModelError.activeTurnLimitReached.localizedDescription
                )
                return false
            }
            localRunningConversationIDs.insert(conversation.id)
        }

        conversationState.setError(nil)
        localRunError = nil
        do {
            let usesOpenClawGateway = isOpenClawGatewayConversation(conversation.id)
            let usesMediatedNoteEditing = usesOpenClawGateway
            let noteBinding = canAgentEditOpenNote(conversation)
                && !(isSteeringActiveTurn && usesMediatedNoteEditing)
                ? try await makeAgentNoteBinding(
                    note,
                    store: dashboardStore,
                    mediated: usesMediatedNoteEditing
                ) : nil
            let deliveryContent = noteAwarePrompt(
                normalized.text,
                binding: noteBinding
            )
            if isSteeringActiveTurn {
                if usesOpenClawGateway {
                    do {
                        _ = try await dashboardStore.sendActiveOpenClawGatewayPrompt(
                            conversationID: conversation.id,
                            input: normalized,
                            deliveryContent: deliveryContent
                        )
                    } catch LocalACPSessionDatabaseError.steeringUnsupported {
                        throw ApplicationModelError.steeringUnavailable
                    }
                    return true
                }
                do {
                    _ = try await dashboardStore.sendActiveLocalACPPrompt(
                        conversationID: conversation.id,
                        input: normalized,
                        deliveryContent: deliveryContent
                    )
                } catch LocalACPSessionDatabaseError.steeringUnsupported {
                    throw ApplicationModelError.steeringUnavailable
                }
                return true
            }
            if usesOpenClawGateway {
                _ = try await acceptOpenClawGatewayMessage(
                    conversation: conversation,
                    input: normalized,
                    deliveryContent: deliveryContent,
                    noteContext: noteBinding?.context,
                    store: dashboardStore
                )
            } else {
                _ = try await acceptLocalAgentMessage(
                    conversation: conversation,
                    input: normalized,
                    deliveryContent: deliveryContent,
                    noteContext: noteBinding?.context,
                    store: dashboardStore
                )
            }
            scheduleConversationTitleGeneration(
                conversation: conversation,
                firstPrompt: normalized.previewText
            )
            return true
        } catch {
            if !isSteeringActiveTurn {
                localRunningConversationIDs.remove(conversation.id)
            }
            await refreshWorkspaceIfChanged()
            await refreshConversation(id: conversation.id)
            conversationState.setError(error.localizedDescription)
            return false
        }
    }

    func processPendingRemoteNoteEdit(
        _ pending: PendingRemoteNoteEdit,
        store: DashboardStore
    ) throws -> NoteEditingResponse? {
        guard let envelope = try RemoteNoteEditEnvelope.extract(
            from: pending.assistantContent,
            nonce: pending.nonce,
            noteID: pending.noteID,
            expectedRevision: pending.expectedRevision,
            noteKind: pending.noteKind
        ) else {
            try store.database.dismissPendingRemoteNoteEdit(runID: pending.runID)
            return nil
        }
        let current = try store.database.readNoteForEditing(id: pending.noteID)
        guard current.success, let document = current.document else {
            throw ApplicationModelError.noteContextUnavailable
        }
        try envelope.validateApplying(to: document)
        return try store.database.applyPendingRemoteNoteEdit(
            pending,
            envelope: envelope,
            visibleAssistantContent: RemoteNoteEditEnvelope.redactingEnvelopes(
                in: pending.assistantContent
            )
        )
    }

    func recoverPendingRemoteNoteEdits(store: DashboardStore) {
        guard flushNoteDrafts() else { return }
        for pending in (try? store.database.pendingRemoteNoteEdits()) ?? [] {
            do {
                if let response = try processPendingRemoteNoteEdit(pending, store: store) {
                    if adoptNoteEditingResponseDraft(response) {
                        Task { await refreshWorkspace() }
                    }
                }
            } catch {
                try? store.database.dismissPendingRemoteNoteEdit(runID: pending.runID)
                noteMutationError = "A recovered remote note edit was not applied: \(error.localizedDescription)"
            }
        }
        try? store.database.dismissTerminalRemoteNoteEdits()
    }

    func canAgentEditOpenNote(_ conversation: WorkspaceConversationRecord?) -> Bool {
        guard let conversation else { return false }
        return conversation.localRuntimeKind != nil && conversation.localRuntimeKind != .opencode
    }

    private func acceptOpenClawGatewayMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        deliveryContent: String,
        noteContext: AgentNoteContext?,
        store: DashboardStore
    ) async throws -> LocalACPRunIdentifiers {
        guard openClawGatewayConversationIDs.contains(conversation.id) else {
            throw OpenClawGatewayClientError.invalidEndpoint
        }
        return try await store.acceptOpenClawGatewayPrompt(
            conversationID: conversation.id,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            onPermission: { request in
                await self.requestLocalACPPermission(
                    conversationID: conversation.id,
                    request: request
                )
            }
        )
    }

    private func acceptLocalAgentMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        deliveryContent: String,
        noteContext: AgentNoteContext?,
        store: DashboardStore
    ) async throws -> LocalACPRunIdentifiers {
        guard let runtimeKind = conversation.localRuntimeKind else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        if conversation.remoteWorkspaceID != nil, !input.files.isEmpty {
            throw AgentMessageAttachmentError.unsupportedForAgent(
                "Remote workspace file upload is not available yet. Add the file to the remote workspace first."
            )
        }
        if runtimeKind == .pi, !input.files.isEmpty {
            throw AgentMessageAttachmentError.unsupportedForAgent(
                "Pi RPC does not expose a file attachment contract yet."
            )
        }
        return try await store.acceptLocalACPPrompt(
            conversationID: conversation.id,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            launch: launch,
            workspace: workspace,
            onPermission: { request in
                await self.requestLocalACPPermission(
                    conversationID: conversation.id,
                    request: request
                )
            },
            onInteraction: { request in
                await self.requestLocalACPInteraction(
                    conversationID: conversation.id,
                    request: request
                )
            }
        )
    }

    func finishAgentRunInteractions(conversationID: String) {
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        cancelLocalACPInteractions(conversationID: conversationID)
    }
}
