import Foundation
import WovenMatterCore

/// Copies message attachments into a remote workspace container so every
/// harness running there can open them by path. Files are content-addressed
/// under `directory`, so a blob is written once however often it is attached.
public struct RemoteAttachmentStager: Sendable {
    /// Under the container workspace root the harnesses launch in, so agents
    /// whose ACP adapters reduce a link to an `@name` mention can still find
    /// the file by searching their working tree.
    public static let directory = "/home/.woven-matter/.wovenmatter/attachments"

    private let runner: RemoteWorkspaceSSHClient.Runner

    public init() {
        runner = RemoteWorkspaceSSHClient.runSSH
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
        let destination = try RemoteWorkspaceSSHClient.validatedDestination(
            hostName: configuration.hostName,
            userName: configuration.userName
        )
        let path = try Self.containerPath(for: draft)
        let data: Data
        do {
            data = try Data(contentsOf: draft.localURL, options: [.mappedIfSafe])
        } catch {
            throw AgentMessageAttachmentError.unreadableFile(draft.fileName)
        }
        // An existing file only counts if it is complete; otherwise it is
        // rewritten. stdin is always drained so ssh never sees a closed pipe,
        // and the size is checked before the rename so a short read cannot
        // leave a truncated blob under a content-addressed name.
        let script = """
        set -e
        p=\(Self.quoted(path)); n=\(data.count)
        if [ -f "$p" ] && [ "$(wc -c <"$p")" -eq "$n" ]; then cat >/dev/null; else
          mkdir -p "$(dirname "$p")"
          t="$p.part.$$"
          cat >"$t"
          [ "$(wc -c <"$t")" -eq "$n" ] || { rm -f "$t"; echo "short write" >&2; exit 1; }
          mv -f "$t" "$p"
        fi
        printf %s "$p"
        """
        let command = [
            "docker", "exec", "--interactive",
            "wovenmatter-\(configuration.workspaceID)",
            "bash", "-c", script,
        ].map(Self.quoted).joined(separator: " ")
        let runner = runner
        let output = try await Task.detached(priority: .userInitiated) {
            try runner(destination, command, data)
        }.value
        let reported = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == path else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "The workspace did not confirm the staged attachment path."
            )
        }
        return path
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
