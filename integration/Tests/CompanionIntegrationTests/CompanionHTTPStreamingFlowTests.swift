import Foundation
import Testing
import WovenMatterDashboardStore

/// Real loopback connections exercise transfer framing, progressive delivery,
/// and cancellation of the producer that owns the inference-only process.
@Suite("Companion HTTP streaming", .serialized)
struct CompanionHTTPStreamingFlowTests {
  @Test("first model output arrives before completion and sliced large emissions remain intact")
  func progressiveDelivery() async throws {
    let probe = StreamProbe()
    let payload = String(repeating: "x", count: 150_000)
    let server = CompanionHTTPServer { _ in
      CompanionHTTPResponse(contentType: "application/x-ndjson", stream: { emit in
        try await emit(Data("first\n".utf8))
        while !(await probe.released) { try await Task.sleep(for: .milliseconds(5)) }
        let framed = Data(("ignored" + payload + "\n").utf8)
        try await emit(framed.dropFirst(7))
        await probe.finish()
      })
    }
    let session = makeSession()
    defer { session.invalidateAndCancel(); server.stop() }
    let port = try await server.start()
    let (bytes, response) = try await session.bytes(from: URL(string: "http://127.0.0.1:\(port)/stream")!)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    // URLSession normalizes chunked transfer encoding to Identity after decoding.
    #expect(http.expectedContentLength == -1)
    #expect(http.value(forHTTPHeaderField: "Content-Length") == nil)
    var lines = bytes.lines.makeAsyncIterator()
    #expect(try await lines.next() == "first")
    #expect(await probe.finished == false)
    await probe.release()
    #expect(try await lines.next() == payload)
    #expect(try await lines.next() == nil)
    #expect(await probe.finished)
  }

  @Test("disconnect cancels a silent inference producer promptly")
  func disconnectCancellation() async throws {
    let probe = StreamProbe()
    let server = CompanionHTTPServer { _ in quietResponse(probe: probe) }
    let session = makeSession()
    defer { session.invalidateAndCancel(); server.stop() }
    let port = try await server.start()
    let (bytes, _) = try await session.bytes(from: URL(string: "http://127.0.0.1:\(port)/stream")!)
    var lines = bytes.lines.makeAsyncIterator()
    #expect(try await lines.next() == "first")
    session.invalidateAndCancel()
    #expect(await eventually { await probe.cancelled })
  }

  @Test("idle deadline resets after output and cancels only a stalled stream")
  func idleDeadline() async throws {
    let probe = StreamProbe()
    let server = CompanionHTTPServer(streamIdleTimeout: 0.3) { request in
      if request.target == "/quiet" { return quietResponse(probe: probe) }
      return CompanionHTTPResponse(contentType: "application/x-ndjson", stream: { emit in
        // The complete response outlives one idle interval without stalling.
        for _ in 0..<6 {
          try await emit(Data("output\n".utf8))
          try await Task.sleep(for: .milliseconds(90))
        }
      })
    }
    let session = makeSession()
    defer { session.invalidateAndCancel(); server.stop() }
    let port = try await server.start()
    let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/active")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(data: data, encoding: .utf8) == String(repeating: "output\n", count: 6))
    let (bytes, _) = try await session.bytes(from: URL(string: "http://127.0.0.1:\(port)/quiet")!)
    var lines = bytes.lines.makeAsyncIterator()
    #expect(try await lines.next() == "first")
    #expect(await eventually { await probe.cancelled })
    // CFNetwork may accept bare EOF on an incomplete chunked response. The
    // inference decoder separately requires its terminal done/error event.
    do { #expect(try await lines.next() == nil) } catch {}
  }

  @Test("server shutdown cancels inference but accepted ordinary commands survive disconnect")
  func ownership() async throws {
    let command = StreamProbe()
    let stream = StreamProbe()
    let server = CompanionHTTPServer { request in
      if request.target == "/stream" { return quietResponse(probe: stream) }
      await command.release()
      try? await Task.sleep(for: .milliseconds(150))
      await command.finish()
      return CompanionHTTPResponse(body: Data("done".utf8))
    }
    let port = try await server.start()
    defer { server.stop() }
    let commandSession = makeSession()
    let accepted = Task { try await commandSession.data(from: URL(string: "http://127.0.0.1:\(port)/command")!) }
    #expect(await eventually { await command.released })
    commandSession.invalidateAndCancel()
    _ = try? await accepted.value
    #expect(await eventually { await command.finished })
    let streamSession = makeSession()
    defer { streamSession.invalidateAndCancel() }
    let (bytes, _) = try await streamSession.bytes(from: URL(string: "http://127.0.0.1:\(port)/stream")!)
    var lines = bytes.lines.makeAsyncIterator()
    #expect(try await lines.next() == "first")
    server.stop()
    #expect(await eventually { await stream.cancelled })
  }
}

private actor StreamProbe {
  private(set) var released = false
  private(set) var finished = false
  private(set) var cancelled = false
  func release() { released = true }
  func finish() { finished = true }
  func cancel() { cancelled = true }
}

private func quietResponse(probe: StreamProbe) -> CompanionHTTPResponse {
  CompanionHTTPResponse(contentType: "application/x-ndjson", stream: { emit in
    do {
      try await emit(Data("first\n".utf8))
      try await Task.sleep(for: .seconds(20))
    } catch {
      if Task.isCancelled { await probe.cancel() }
      throw error
    }
  })
}

private func eventually(_ predicate: @Sendable () async -> Bool) async -> Bool {
  for _ in 0..<100 {
    if await predicate() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return false
}

private func makeSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.timeoutIntervalForRequest = 4
  configuration.timeoutIntervalForResource = 5
  return URLSession(configuration: configuration)
}
