import AppKit
import Foundation
import Testing
import WebKit
import WovenMatterCore
@testable import WovenMatterAppFacade

@Suite("Conversation HTML WebKit", .serialized)
@MainActor struct ConversationHTMLWebKitTests {
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
        for _ in 0..<100 where ready == 0 { try await Task.sleep(for: .milliseconds(20)) }
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
        fetch('https://example.invalid/blocked').then(()=>console.error('network-accessible'),()=>console.log('network-blocked'));
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
            #expect(logs.contains("network-blocked"))
            #expect(logs.contains("policy-blocked:connect-src"))
            #expect(!logs.contains("network-accessible"))
            let encoded = try #require(content.last?.objectValue?["data"]?.stringValue)
            let png = try #require(Data(base64Encoded: encoded))
            #expect(png.count > 1000)
            try png.write(to: URL(fileURLWithPath: "/private/tmp/wovenmatter-html-\(appearance)-\(width).png"))
        }
        #expect(heights[1] > heights[0])
    }
}
