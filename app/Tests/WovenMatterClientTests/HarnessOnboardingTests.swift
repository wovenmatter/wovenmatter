import Foundation
import Testing
@testable import WovenMatterClient
import WovenMatterCore

struct HarnessOnboardingTests {

}

extension HarnessOnboardingTests {
}

extension HarnessOnboardingTests {
    @Test func nativeStatusCanArriveOnStandardError() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "harness-status-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "fake-opencode")
        try Data("#!/bin/sh\nprintf '0 credentials\\n0 environment variables\\n' >&2\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let status = await HarnessOnboarding.checkSignIn(.opencode, executable: executable)
        #expect(status.state == "sign_in_required")
    }
}

extension HarnessOnboardingTests {
    @Test func accountMetadataShowsMethodsAndNamesWithoutSecrets() throws {
        let claude = HarnessOnboarding.parseSignIn(.claudeCode,
            output: #"{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.test","accessToken":"private-secret"}"#, succeeded: true)
        #expect(claude.accounts?.first?.name == "person@example.test")
        #expect(claude.accounts?.first?.method == "Claude subscription")
        let key = HarnessOnboarding.parseSignIn(.claudeCode,
            output: #"{"loggedIn":true,"authMethod":"api_key","apiKeyName":"Development","apiKey":"sk-private-secret"}"#, succeeded: true)
        #expect(key.accounts?.first?.name == "Development")
        #expect(key.accounts?.first?.method == "API key")
        let code = HarnessOnboarding.parseSignIn(.opencode,
            output: "│ ● OpenAI oauth\n│ ● Anthropic api\n└ 2 credentials", succeeded: true)
        #expect(code.accounts?.map(\.name) == ["OpenAI", "Anthropic"])
        #expect(code.accounts?.map(\.method) == ["OAuth", "API key"])
        let encoded = try JSONEncoder().encode(key)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("sk-private-secret"))
        let old = try JSONDecoder().decode(AgentSignInStatus.self, from: Data(#"{"id":"codex","name":"Codex","state":"verified","detail":"Signed in"}"#.utf8))
        #expect(old.accounts == nil)
        let denied = HarnessOnboarding.parseSignIn(.claudeCode,
            output: #"{"loggedIn":false,"email":"old@example.test"}"#, succeeded: true)
        #expect(denied.accounts?.isEmpty == true)
    }
}
