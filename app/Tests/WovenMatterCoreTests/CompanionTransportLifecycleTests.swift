import Darwin
import Foundation
import XCTest
@testable import WovenMatterDashboardStore
import WovenMatterCore

@MainActor
extension CompanionTransportTests {
  func testRealSupervisorStopsAfterAbruptParentDeathWithoutCleanupHandlers() async throws {
    let fixture = try await SupervisorFixture.build()
    defer { fixture.remove() }
    let helperPIDFile = fixture.directory.appendingPathComponent("helper.pid")
    let childPIDFile = fixture.directory.appendingPathComponent("child.pid")
    let report = fixture.directory.appendingPathComponent("reaped.txt")
    let parent = try fixture.launch(arguments: ["--fixture-crashing-parent", helperPIDFile.path, childPIDFile.path],
                                    childPIDFile: childPIDFile, reapReport: report)
    defer { parent.cleanup(childPIDFile: childPIDFile) }
    try await waitForFixture { !parent.process.isRunning }
    XCTAssertEqual(parent.process.terminationReason, .uncaughtSignal)
    XCTAssertEqual(parent.process.terminationStatus, SIGKILL)
    let pid = try fixturePID(at: childPIDFile)
    let helperPID = try fixturePID(at: helperPIDFile)
    try await waitForFixture { FileManager.default.fileExists(atPath: report.path) }
    XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "-1:\(ECHILD)")
    try await waitForFixture { kill(pid, 0) == -1 && errno == ESRCH }
    try await waitForFixture { kill(helperPID, 0) == -1 && errno == ESRCH }
  }

}

@MainActor
private func waitForFixture(timeout: TimeInterval = 5, _ condition: () throws -> Bool) async throws {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  while try !condition() {
    if ProcessInfo.processInfo.systemUptime >= deadline { throw FixtureFailure.timeout }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private enum FixtureFailure: Error { case timeout, invalidPID }
private func fixturePID(at url: URL) throws -> Int32 {
  guard let pid = Int32(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
    throw FixtureFailure.invalidPID
  }
  return pid
}

@MainActor
private struct SupervisorFixture {
  let directory: URL
  var executable: URL { directory.appendingPathComponent("CompanionServeSupervisorFixture") }
  static func build() async throws -> Self {
    let source = URL(fileURLWithPath: #filePath)
    let repository = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("woven-supervisor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = Self(directory: directory)
    do {
      _ = try await CompanionProcessProbe().run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", "-parse-as-library",
        repository.appendingPathComponent("app/Sources/WovenMatterDashboardStore/CompanionServeSupervisor.swift").path,
        repository.appendingPathComponent("scripts/test-support/CompanionServeSupervisorFixture.swift").path,
        "-module-cache-path", directory.appendingPathComponent("ModuleCache").path, "-o", fixture.executable.path], timeout: 30)
      return fixture
    } catch { fixture.remove(); throw error }
  }
  func launch(arguments: [String], childPIDFile: URL? = nil, reapReport: URL? = nil) throws -> SupervisorFixtureProcess {
    let process = Process(), heartbeat = Pipe()
    _ = fcntl(heartbeat.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = heartbeat
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["WOVEN_FIXTURE_CHILD_PID_FILE"] = childPIDFile?.path
    environment["WOVEN_FIXTURE_REAP_REPORT"] = reapReport?.path
    process.environment = environment
    try process.run()
    try heartbeat.fileHandleForReading.close()
    return SupervisorFixtureProcess(process: process, heartbeat: heartbeat)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private struct SupervisorFixtureProcess {
  let process: Process
  let heartbeat: Pipe
  func cleanup(childPIDFile: URL) {
    try? heartbeat.fileHandleForWriting.close()
    // Only fixture-owned IDs are eligible for emergency cleanup if an assertion fails.
    if let pid = try? fixturePID(at: childPIDFile), kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
    if process.isRunning { process.terminate() }
  }
}
