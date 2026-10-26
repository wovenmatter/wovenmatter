import Foundation
import WovenMatterCore

public enum RuntimeProcessMetrics {
    /// Only registered owners and their observed descendants enter the result.
    /// Command arguments and environments are never collected.
    public static func sample(_ items: [RuntimeInspection.Item], includeServerDescendants: Bool = true) async -> [RuntimeInspection.Item] {
        await Task.detached(priority: .utility) { sampleSynchronously(items, includeServerDescendants: includeServerDescendants) }.value
    }

    private static func sampleSynchronously(_ items: [RuntimeInspection.Item], includeServerDescendants: Bool) -> [RuntimeInspection.Item] {
        let process = Process(), done = DispatchSemaphore(value: 0)
        let file = FileManager.default.temporaryDirectory.appending(path: "woven-process-metrics-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: file) else { return items }
        defer { try? output.close(); try? FileManager.default.removeItem(at: file) }
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,comm="]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return items }
        guard done.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return items
        }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: file) else { return items }
        struct Sample { let pid: Int32; let parent: Int32; let cpu: Double; let bytes: Int64; let name: String }
        let samples: [Sample] = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard fields.count == 5, let pid = Int32(fields[0]), pid != process.processIdentifier,
                  let parent = Int32(fields[1]), let cpu = Double(fields[2]), let rss = Int64(fields[3]) else { return nil }
            return Sample(pid: pid, parent: parent, cpu: cpu, bytes: rss * 1024,
                          name: URL(fileURLWithPath: String(fields[4])).lastPathComponent)
        }
        var result = items
        var owners: [Int32: RuntimeInspection.Item] = [:]
        for item in items where includeServerDescendants || item.kind != "service" {
            if let pid = item.processID { owners[pid] = item }
        }
        // Parent traversal attributes children without guessing which unrelated
        // host processes belong to a chat. An inspection is an observation only.
        for _ in 0..<16 {
            var added = false
            for sample in samples where owners[sample.pid] == nil {
                guard let parent = owners[sample.parent] else { continue }
                let kind = ["connectionSupervisor", "connectionProcess"].contains(parent.kind) ? "connectionProcess" : "process"
                let item = RuntimeInspection.Item(id: "process:\(sample.pid)", parentID: parent.id,
                    conversationID: parent.conversationID, kind: kind, title: sample.name,
                    state: "running", processID: sample.pid, cpuPercent: sample.cpu, residentBytes: sample.bytes)
                owners[sample.pid] = item; result.append(item); added = true
                if result.count >= 1_000 { break }
            }
            if !added || result.count >= 1_000 { break }
        }
        let indexed = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        return result.map { item in
            var item = item
            if let pid = item.processID, let sample = indexed[pid] {
                item.cpuPercent = sample.cpu; item.residentBytes = sample.bytes
            }
            return item
        }
    }
}
