import CryptoKit
import Foundation
import WovenMatterCore

/// Copies message attachments into a remote workspace container for harnesses
/// with a file attachment contract. Files are content-addressed under `directory`;
/// unchanged bytes are reused and modified copies are repaired.
public struct RemoteAttachmentStager: Sendable {
    /// Under the container workspace root the harnesses launch in, so agents
    /// whose ACP adapters reduce a link to an `@name` mention can still find
    /// the file by searching their working tree.
    public static let directory = "/home/.woven-matter/.wovenmatter/attachments"

    private let runner: RemoteWorkspaceSSHClient.Runner

    public init() {
        runner = RemoteWorkspaceSSHClient.runAttachmentSSH
    }

    public init(runner: @escaping RemoteWorkspaceSSHClient.Runner) {
        self.runner = runner
    }

    /// The container path `draft` will occupy once staged.
    public static func containerPath(for draft: AgentFileAttachmentDraft) throws -> String {
        guard draft.contentHash.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
            throw AgentMessageAttachmentError.unreadableFile(draft.fileName)
        }
        return "\(directory)/\(draft.contentHash)/\(fileName(for: draft))"
    }

    /// Stages `draft` in the container for `configuration` and returns its path.
    /// The transfer is one `ssh … docker exec` with the file on stdin.
    public func stage(
        _ draft: AgentFileAttachmentDraft,
        in configuration: RemoteWorkspaceConfiguration
    ) async throws -> String {
        try Task.checkCancellation()
        let destination = try RemoteWorkspaceSSHClient.validatedDestination(
            hostName: configuration.hostName,
            userName: configuration.userName
        )
        let path = try Self.containerPath(for: draft)
        let runner = runner
        let transfer = Task.detached(priority: .userInitiated) {
            // Bound the read even if the local blob changed since it was imported.
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: draft.localURL)
                defer { try? handle.close() }
                data = try handle.read(upToCount: Int(AgentMessageAttachmentLimits.maximumFileBytes) + 1) ?? Data()
            } catch {
                throw AgentMessageAttachmentError.unreadableFile(draft.fileName)
            }
            guard data.count <= AgentMessageAttachmentLimits.maximumFileBytes else {
                throw AgentMessageAttachmentError.fileTooLarge(name: draft.fileName,
                    maximumBytes: AgentMessageAttachmentLimits.maximumFileBytes)
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == draft.contentHash, data.count == draft.sizeBytes else {
                throw AgentMessageAttachmentError.unreadableFile(draft.fileName)
            }
            let script = Self.stagingScript(path: path, byteCount: data.count, hash: hash)
            let command = [
                "docker", "exec", "--interactive",
                "wovenmatter-\(configuration.workspaceID)",
                "bash", "-c", script,
            ].map(Self.quoted).joined(separator: " ")
            return try runner(destination, command, data)
        }
        let output = try await withTaskCancellationHandler {
            try await transfer.value
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()
        let reported = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == path else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "The workspace did not confirm the staged attachment path."
            )
        }
        return path
    }

    /// Validate content, not just size: agents can edit an already staged file.
    /// A unique temporary file and EXIT trap keep failed transfers unpublished.
    static func stagingScript(path: String, byteCount: Int, hash: String) -> String {
        """
        set -e
        umask 077
        p=\(quoted(path)); n=\(byteCount); h=\(quoted(hash))
        matches() { [ -f "$1" ] && [ "$(wc -c <"$1")" -eq "$n" ] && [ "$(sha256sum <"$1" | cut -d ' ' -f 1)" = "$h" ]; }
        if matches "$p"; then cat >/dev/null; else
          mkdir -p "$(dirname "$p")"
          t=$(mktemp "$p.part.XXXXXX")
          trap 'rm -f "$t"' EXIT
          cat >"$t"
          matches "$t" || { echo "attachment integrity check failed" >&2; exit 1; }
          mv -f "$t" "$p"
        fi
        printf %s "$p"
        """
    }

    /// The original name with path separators and control characters removed,
    /// so agents see the real extension.
    static func fileName(for draft: AgentFileAttachmentDraft) -> String {
        let cleaned = draft.fileName.unicodeScalars
            .map { $0 == "/" || $0 == "\\" || $0.value < 0x20 ? "_" : Character($0) }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "." || name == ".." ? "attachment" : name
    }

    private static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
