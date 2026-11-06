import Foundation

/// Reads Codex's archived `.jsonl.zst` sessions. macOS has no Zstandard decoder, so
/// this uses the Node the app already ships. Only lines holding a marker come back,
/// numbered as in the original file.
enum UsageCompressedTranscript {
  private static let suffix = ".jsonl.zst"
  private static let script = #"""
    import {createReadStream} from 'node:fs'
    import {createInterface} from 'node:readline'
    import {createZstdDecompress} from 'node:zlib'
    import {once} from 'node:events'
    const [file, ...markers] = process.argv.slice(1)
    const source = createReadStream(file).pipe(createZstdDecompress())
    let number = 0
    for await (const line of createInterface({input: source, crlfDelay: Infinity})) {
      number += 1
      if (markers.some(marker => line.includes(marker))
        && !process.stdout.write(number + '\t' + line + '\n')) await once(process.stdout, 'drain')
    }
    """#

  static var bundledNode: URL? {
    let node = Bundle.main.resourceURL?.appending(path: "default-agent/bin/node")
    return node.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
  }

  static func isCompressed(_ url: URL) -> Bool {
    url.lastPathComponent.hasSuffix(suffix)
  }

  static func isTranscript(_ url: URL) -> Bool {
    url.pathExtension == "jsonl" || isCompressed(url)
  }

  /// A session keeps one identity when Codex compresses it, so its rows are replaced
  /// by the archived copy rather than counted a second time.
  static func identityPath(_ url: URL) -> String {
    isCompressed(url) ? String(url.path.dropLast(".zst".count)) : url.path
  }

  /// Keeps the plain file when both copies of a session exist, and leaves compressed
  /// files out when no decoder is available.
  static func preferred(_ files: [URL], node: URL?) -> [URL] {
    let paths = Set(files.map(\.path))
    return files.filter { file in
      guard isCompressed(file) else { return true }
      return node != nil && !paths.contains(identityPath(file))
    }
  }

  static func forEachMarkedLine(
    in url: URL,
    markers: [String],
    node: URL,
    check: () throws -> Void,
    body: (Data.SubSequence, Int) throws -> Void
  ) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = node
    process.arguments = ["--no-warnings", "--input-type=module", "-e", script, "--", url.path] + markers
    process.environment = [:]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let newline = UInt8(ascii: "\n"), tab = UInt8(ascii: "\t")
    var buffer = Data()
    while true {
      try check()
      let chunk = output.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      buffer.append(chunk)
      var start = buffer.startIndex
      while let end = buffer[start...].firstIndex(of: newline) {
        let line = buffer[start..<end]
        if let separator = line.firstIndex(of: tab),
           let number = Int(String(decoding: line[line.startIndex..<separator], as: UTF8.self)) {
          try body(line[line.index(after: separator)...], number)
        }
        start = buffer.index(after: end)
      }
      buffer = Data(buffer[start...])
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
  }
}
