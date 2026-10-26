import AppKit
import Foundation
import Network
import Testing
import WebKit
import WovenMatterCore
@testable import WovenMatterAppFacade

@Suite("Conversation HTML WebKit", .serialized)
@MainActor struct ConversationHTMLWebKitTests {
    @Test func externalScriptsStylesImagesAndFetchLoadWithoutAppAccess() async throws {
        _ = NSApplication.shared
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        let server = try HTMLResourceFixture(png: try #require(bitmap.representation(using: .png, properties: [:])))
        let port = try await server.start(); defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let local = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        try server.png.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let html = """
        <!doctype html><html><head><link rel="stylesheet" href="\(base)/style.css"><script src="\(base)/script.js"></script></head>
        <body><div id="styled">External resources</div><img src="\(base)/image.png" onload="console.log('image-loaded')"><img src="\(local.path)" onload="console.log('embedded-image-loaded')">
        <script>fetch('\(base)/data').then(r=>r.text()).then(v=>console.log(v));
        addEventListener('load',()=>console.log('style:'+getComputedStyle(document.getElementById('styled')).height));
        try{parent.document.body;console.log('parent-accessible')}catch(e){console.log('parent-isolated')}
        </script></body></html>
        """
        let prepared = try ConversationHTMLResources.prepare(html)
        try FileManager.default.removeItem(at: local)
        let result = try await ConversationHTMLPreview().capture(.object(["action": .string("preview"), "html": .string(prepared.html)]))
        let content = try #require(result.objectValue?["content"]?.arrayValue)
        let text = try #require(content.first?.objectValue?["text"]?.stringValue)
        #expect(text.contains("script-loaded"))
        #expect(text.contains("image-loaded"))
        #expect(text.contains("embedded-image-loaded"))
        #expect(text.contains("fetch-loaded"))
        #expect(text.contains("style:123px"))
        #expect(text.contains("parent-isolated"))
        #expect(!text.contains("parent-accessible"))
        #expect(server.paths == Set(["/script.js", "/style.css", "/image.png", "/data"]))
        #expect(!server.receivedCookie)
    }

    @Test func fragmentsKeepStandardsModeAndImageHeavyPreviewsFitTheResponseBudget() async throws {
        _ = NSApplication.shared
        let html = #"""
        <!-- a fake <head> must not swallow the bootstrap -->
        <canvas id="noise" width="1600" height="1800"></canvas><script>
        const fake='<head>';const canvas=document.getElementById('noise'), ctx=canvas.getContext('2d');
        const pixels=ctx.createImageData(canvas.width,canvas.height);let seed=1;
        for(let i=0;i<pixels.data.length;i+=4){seed=(Math.imul(seed,1664525)+1013904223)>>>0;
          pixels.data[i]=seed&255;pixels.data[i+1]=(seed>>>8)&255;pixels.data[i+2]=(seed>>>16)&255;pixels.data[i+3]=255;}
        ctx.putImageData(pixels,0,0);console.log('mode:'+document.compatMode);
        for(let i=0;i<20;i++)console.log('\u0000'.repeat(2000));
        </script>
        """#
        let result = try await ConversationHTMLPreview().capture(.object(["action": .string("preview"), "html": .string(html), "width": .number(1600)]))
        let content = try #require(result.objectValue?["content"]?.arrayValue)
        let metadata = try #require(content.first?.objectValue?["text"]?.stringValue)
        #expect(metadata.contains("mode:CSS1Compat"))
        let values = try #require(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
        #expect(try #require(values["screenshotWidth"] as? Int) < 1600)
        #expect(try JSONEncoder().encode(WovenMatterToolResponse(success: true, result: result)).count < WovenMatterToolResponse.maximumResponseBytes)
    }
    @Test func themeAndZoomPreserveStateAndChildFramesCannotCallNativeHandler() async throws {
        _ = NSApplication.shared
        let coordinator = ConversationHTMLWebCoordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 200)
        defer { coordinator.stop(view) }
        var ready = 0
        var links: [URL] = []
        coordinator.onReady = { ready += 1 }
        coordinator.onLink = { links.append($0) }
        let html = #"""
        <!doctype html><html><head></head><body><button id="count" onclick="this.textContent=Number(this.textContent)+1">0</button><script>
        document.getElementById('count').click();
        addEventListener('message',e=>{if(e.data?.kind==='theme')console.log(e.data.appearance+':'+document.getElementById('count').textContent);});
        window.webkit?.messageHandlers.wovenHTML.postMessage({kind:'link',url:'https://example.invalid/forged'});
        </script></body></html>
        """#
        coordinator.apply(html: html, theme: ConversationHTMLTheme.value(.green), to: view)
        let deadline = ContinuousClock.now + .seconds(20)
        while ready == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ready == 1)
        coordinator.apply(html: html, theme: ConversationHTMLTheme.value(.cognac), to: view)
        view.pageZoom = 1.5
        try await Task.sleep(for: .milliseconds(100))
        coordinator.apply(html: html, theme: ConversationHTMLTheme.value(.dark), to: view)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ready == 1)
        #expect(links.isEmpty)
        #expect(view.pageZoom == 1.5)
        #expect(coordinator.consoleMessages.contains { $0["text"] == "dark:1" })
    }

    @Test func interactiveSandboxAndResponsivePreview() async throws {
        _ = NSApplication.shared
        let html = #"""
        <!doctype html><html><head><style>
        body { padding:16px; color:var(--foreground); font-family:var(--font-sans) }
        h2 { margin:0 0 16px } .cards { display:grid; grid-template-columns:repeat(3,1fr); gap:12px }
        .card { background:var(--muted); padding:16px; border-radius:var(--radius); border:1px solid var(--border) }
        strong { display:block; color:var(--primary); font-size:26px }
        button { margin-top:16px; padding:10px; color:var(--primary-foreground); background:var(--primary); border:0; border-radius:8px }
        @media(max-width:450px) { .cards { grid-template-columns:1fr } }
        </style></head><body><h2>Interactive forecast</h2><div class="cards">
        <div class="card">Revenue<strong>$42,000</strong></div><div class="card">Growth<strong>18%</strong></div>
        <div class="card">Customers<strong>720</strong></div></div><button id="counter" onclick="this.textContent=Number(this.textContent)+1">0</button>
        <script>
        document.getElementById('counter').click();console.log('count='+document.getElementById('counter').textContent);
        try { parent.document.body;console.error('parent-accessible'); } catch(e) { console.log('parent-isolated'); }
        document.addEventListener('securitypolicyviolation',e=>console.log('policy-blocked:'+e.effectiveDirective));
        fetch('file:///private/not-a-web-resource').then(()=>console.error('file-accessible'),()=>console.log('file-blocked'));
        </script></body></html>
        """#
        var heights: [Int] = []
        for (width, appearance) in [(728, "light"), (390, "dark")] {
            let result = try await ConversationHTMLPreview().capture(.object([
                "action": .string("preview"), "html": .string(html), "width": .number(Double(width)), "appearance": .string(appearance)
            ]))
            let content = try #require(result.objectValue?["content"]?.arrayValue)
            let metadata = try #require(content.first?.objectValue?["text"]?.stringValue)
            let values = try #require(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
            let height = try #require(values["contentHeight"] as? Int)
            #expect(height >= 80 && height < 1000)
            heights.append(height)
            let messages = try #require(values["consoleMessages"] as? [[String: String]])
            let logs = messages.compactMap { $0["text"] }
            #expect(logs.contains("count=1"))
            #expect(logs.contains("parent-isolated"))
            #expect(logs.contains("file-blocked"))
            #expect(logs.contains("policy-blocked:connect-src"))
            #expect(!logs.contains("file-accessible"))
            let encoded = try #require(content.last?.objectValue?["data"]?.stringValue)
            let png = try #require(Data(base64Encoded: encoded))
            #expect(png.count > 1000)
            try png.write(to: URL(fileURLWithPath: "/private/tmp/wovenmatter-html-\(appearance)-\(width).png"))
        }
        #expect(heights[1] > heights[0])
    }
}

/// A loopback-only CDN fixture. The production companion parser deliberately
/// rejects browser origins, so resource/CORS testing uses its own small server.
private final class HTMLResourceFixture: @unchecked Sendable {
    let listener: NWListener
    let png: Data
    private let queue = DispatchQueue(label: "html-resource-fixture")
    private let lock = NSLock()
    private var requested: Set<String> = []
    private var cookie = false
    var paths: Set<String> { lock.withLock { requested } }
    var receivedCookie: Bool { lock.withLock { cookie } }
    init(png: Data) throws {
        self.png = png
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state, let port = listener.port {
                    listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue)
                } else if case .failed(let error) = state {
                    listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    lock.withLock { requested.insert(path); cookie = cookie || request.lowercased().contains("\r\ncookie:") }
                    let type: String, body: Data
                    switch path {
                    case "/script.js": type = "application/javascript"; body = Data("console.log('script-loaded')".utf8)
                    case "/style.css": type = "text/css"; body = Data("#styled{height:123px}".utf8)
                    case "/image.png": type = "image/png"; body = png
                    default: type = "text/plain"; body = Data("fetch-loaded".utf8)
                    }
                    var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}
