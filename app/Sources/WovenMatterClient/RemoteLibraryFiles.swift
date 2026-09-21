import Foundation
import WovenMatterCore

/// Reads only an explicitly shared regular file from this workspace's container.
/// Uses existing noninteractive SSH; no remote service upgrade or credential prompt.
public struct RemoteLibraryFiles: Sendable {
  private let runner: RemoteWorkspaceSSHClient.Runner
  public init() { runner = RemoteWorkspaceSSHClient.runAttachmentSSH }
  public init(runner: @escaping RemoteWorkspaceSSHClient.Runner) { self.runner = runner }

  public func read(source: String, root: String, configuration: RemoteWorkspaceConfiguration) async throws -> Data {
    let destination = try RemoteWorkspaceSSHClient.validatedDestination(hostName: configuration.hostName, userName: configuration.userName)
    guard configuration.workspaceID.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}/) != nil else {
      throw RemoteWorkspaceClientError.invalidResponse("The remote workspace identity is invalid.")
    }
    let path = try Self.path(source: source, root: root)
    let args = ["docker", "exec", "wovenmatter-" + configuration.workspaceID, "node", "-e", Self.readScript,
      "--", path, root, String(AgentMessageAttachmentLimits.maximumFileBytes)]
    let command = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    let runner = runner
    let transfer = Task.detached(priority: .utility) { try runner(destination, command, nil) }
    let data = try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() }
    try Task.checkCancellation()
    guard data.count <= AgentMessageAttachmentLimits.maximumFileBytes else {
      throw RemoteWorkspaceClientError.invalidResponse("The file exceeds the 25 MB retention limit.")
    }
    return data
  }

  public static func path(source: String, root: String) throws -> String {
    var path = source
    if source.hasPrefix("sandbox:") { path = String(source.dropFirst("sandbox:".count)).removingPercentEncoding ?? String(source.dropFirst("sandbox:".count)) }
    else if source.hasPrefix("file:") {
      guard let url = URL(string: source), url.host == nil || url.host == "" || url.host == "localhost" else {
        throw RemoteWorkspaceClientError.invalidResponse("The file link names a different host.")
      }
      path = url.path
    }
    if path.hasPrefix("~/") { path = "/home/" + path.dropFirst(2) }
    guard !path.contains("\u{0}"), path.utf8.count <= 8192 else {
      throw RemoteWorkspaceClientError.invalidResponse("The file path is invalid.")
    }
    return path.hasPrefix("/") ? path : root + "/" + path
  }

  // Open without following the final symlink, verify confinement and file identity,
  // then read a bounded snapshot. No shell evaluates the returned path.
  public static let readScript = #"""
    const fs = require('node:fs'), path = require('node:path');
    const [name, root, maxString] = process.argv.slice(1), max = Number(maxString);
    try {
      const requested = path.resolve(name), actual = fs.realpathSync(requested);
      const roots = [root, '/tmp', '/mnt/data'].filter(p => fs.existsSync(p)).map(p => fs.realpathSync(p));
      if (!roots.some(r => actual.startsWith(r + '/')) || fs.lstatSync(requested).isSymbolicLink())
        throw Error('The shared file is outside the workspace or is a symbolic link.');
      const fd = fs.openSync(requested, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
      try {
        const before = fs.fstatSync(fd);
        const opened = fs.realpathSync('/proc/self/fd/' + fd);
        if (!roots.some(r => opened.startsWith(r + '/')) || !before.isFile()) throw Error('Not a regular workspace file.');
        if (before.size > max) throw Error('The file exceeds the 25 MB retention limit.');
        const bytes = Buffer.alloc(before.size + 1);
        let count = 0, n;
        while (count < bytes.length && (n = fs.readSync(fd, bytes, count, bytes.length - count, null)) > 0) count += n;
        const after = fs.fstatSync(fd);
        if (count !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs)
          throw Error('The file changed while it was being saved. Try again.');
        process.stdout.write(bytes.subarray(0, count));
      } finally { fs.closeSync(fd); }
    } catch (error) { process.stderr.write(error.message); process.exitCode = 1; }
    """#
}
