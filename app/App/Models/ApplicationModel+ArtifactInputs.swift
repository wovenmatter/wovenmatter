import Foundation
import WovenMatterCore

extension ApplicationModel {
    /// Settle every input admitted before this barrier without allowing one
    /// failed key to skip other input writes or the Note recovery journal.
    /// Input that failed earlier and is still waiting for Retry also counts as
    /// unsaved until it is retried or its Artifact is closed.
    func flushArtifactInputs() async -> Bool {
        var succeeded = true
        for write in Array(artifactInputWrites.values) {
            do { _ = try await write.value } catch { succeeded = false }
        }
        return succeeded && unsavedArtifactGenerations.isEmpty
    }

    func setArtifactInputsUnsaved(generation: String, _ unsaved: Bool) {
        if unsaved { unsavedArtifactGenerations.insert(generation) }
        else { unsavedArtifactGenerations.remove(generation) }
    }

    func scheduleArtifactWorkspaceRefresh() {
        artifactRefreshNeeded = true
        guard artifactRefreshTask == nil else { return }
        artifactRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                artifactRefreshNeeded = false
                try? await Task.sleep(for: .milliseconds(100))
                await refreshWorkspace()
            } while artifactRefreshNeeded && !Task.isCancelled
            artifactRefreshTask = nil
        }
    }

    func enqueueArtifactInput(noteID: String, edit: ArtifactStateEdit, after previous: Task<ArtifactStateWriteResult, any Error>? = nil) -> Task<ArtifactStateWriteResult, any Error> {
        guard !noteEditingSuspended, !backendStopping else { return Task { throw ArtifactInputError.unavailable } }
        let id = UUID()
        let write = Task { @MainActor in
            defer { artifactInputWrites[id] = nil }
            var acceptedEdit = edit
            if let previous {
                let committed = try await previous.value
                acceptedEdit.expectedVersion = committed.version == 0 ? nil : committed.version
            }
            return try await persistArtifactInput(noteID: noteID, edit: acceptedEdit)
        }
        artifactInputWrites[id] = write
        return write
    }

    /// A real user write to one key of one original Artifact. The latest host
    /// document is mutated atomically; HTML and database links are never supplied
    /// by the renderer and cannot be replaced by a stale UI snapshot.
    private func persistArtifactInput(noteID: String, edit: ArtifactStateEdit) async throws -> ArtifactStateWriteResult {
        do {
            let response: ArtifactStateWriteResult
            if isBackendFrontend {
                let result = try await sendBackendCommand(.workspaceMutation(.artifactState(noteID: noteID, edit: edit)))
                guard let value = result.artifactStateResult else { throw ArtifactInputError.saveFailed }
                response = value
            } else {
                guard let database = dashboardStore?.database else { throw ArtifactInputError.unavailable }
                response = try await database.applyArtifactStateEdit(noteID: noteID, edit: edit)
            }
            scheduleArtifactWorkspaceRefresh()
            return response
        } catch {
            // Only this small projection is needed for an explicit retry. A
            // full workspace refresh must not sit in each keystroke's queue.
            let snapshot: ArtifactStateSnapshot?
            if isBackendFrontend {
                snapshot = try? await sendBackendCommand(.workspaceMutation(.readArtifactState(noteID: noteID))).artifactStateSnapshot
            } else {
                snapshot = try? await dashboardStore?.database.artifactStateSnapshot(noteID: noteID)
            }
            scheduleArtifactWorkspaceRefresh()
            throw ArtifactInputFailure(message: error.localizedDescription, snapshot: snapshot)
        }
    }
}

struct ArtifactInputFailure: LocalizedError {
    let message: String
    let snapshot: ArtifactStateSnapshot?
    var errorDescription: String? { message }
}
