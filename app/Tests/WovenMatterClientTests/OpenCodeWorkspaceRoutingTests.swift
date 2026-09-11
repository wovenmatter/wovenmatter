import Foundation
import Testing
@testable import WovenMatterClient

struct OpenCodeWorkspaceRoutingTests {
    @Test func separateWorkspaceConnectionsKeepCredentialsAndPathsSeparate() throws {
        let firstID = UUID(), secondID = UUID()
        let first = try OpenCodeConnection(identity: "remote-workspace:" + firstID.uuidString.lowercased(),
            url: URL(string: "http://127.0.0.1:32101")!, password: "", servicePathPrefix: "/v1/workspace-instances/opencode", bearerToken: "first-fixture-token")
        let second = try OpenCodeConnection(identity: "remote-workspace:" + secondID.uuidString.lowercased(),
            url: URL(string: "http://127.0.0.1:32102")!, password: "", servicePathPrefix: "/v1/workspace-instances/opencode", bearerToken: "second-fixture-token")
        let requestA = try OpenCodeHTTPClient(connection: first).request("POST", "/api/session/ses_a/prompt", body: ["text": "fixture"])
        let requestB = try OpenCodeHTTPClient(connection: second).request("GET", "/api/health")
        #expect(requestA.url?.absoluteString == "http://127.0.0.1:32101/v1/workspace-instances/opencode/api/session/ses_a/prompt")
        #expect(requestB.url?.port == 32102)
        #expect(requestA.value(forHTTPHeaderField: "Authorization") == "Bearer first-fixture-token")
        #expect(requestB.value(forHTTPHeaderField: "Authorization") == "Bearer second-fixture-token")
        #expect(first.identity != second.identity)
        #expect(first.browserURL.query == nil)
        #expect(!first.browserURL.absoluteString.contains("token"))
        let path = try OpenCodeHTTPClient(connection: first).request("GET", "/api/file/" + OpenCodeHTTPClient.segment("/home/repo/file name.md"))
        #expect(path.url?.absoluteString.contains("%2Fhome%2Frepo%2Ffile%20name%2Emd") == true)
    }

    @Test func workspaceCredentialsCannotBeSentToAnArbitraryOriginOrPrefix() {
        for origin in ["http://example.com", "https://127.0.0.1", "http://127.0.0.1/path"] {
            #expect(throws: OpenCodeError.self) {
                try OpenCodeConnection(identity: "remote-workspace:" + UUID().uuidString,
                    url: URL(string: origin)!, password: "", servicePathPrefix: "/v1/workspace-instances/opencode", bearerToken: "fixture")
            }
        }
        #expect(throws: OpenCodeError.self) {
            try OpenCodeConnection(identity: "local:fixture", url: URL(string: "http://127.0.0.1")!, password: "",
                servicePathPrefix: "/v1/workspace-instances/opencode", bearerToken: "fixture")
        }
        #expect(throws: OpenCodeError.self) {
            try OpenCodeConnection(identity: "remote-workspace:" + UUID().uuidString, url: URL(string: "http://127.0.0.1")!, password: "",
                servicePathPrefix: "/other-host", bearerToken: "fixture")
        }
    }
}
