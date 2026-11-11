#if os(macOS)
import Foundation
import Testing
@testable import WovenMatterClient
import WovenMatterCore

struct HarnessOnboardingTests {
    @Test func openCodeStoredAccountRowsAreRecognizedWithoutVerifyingProviderAccess() {
        let output = "OpenCode Go  OpenCode Go 2               stored\nOpenCode Go  OpenCode Go                 stored\nOpenCode Go  API key                     stored\n"
        let status = HarnessOnboarding.parseSignIn(.opencode, output: output, succeeded: true)
        #expect(status.state == "credentials_present")
        #expect(status.accounts?.map(\.name) == ["OpenCode Go · OpenCode Go 2", "OpenCode Go", "OpenCode Go"])
        #expect(status.accounts?.map(\.method) == ["Saved credential", "Saved credential", "API key"])
        #expect(status.accounts?.map(\.target) == ["OpenCode Go", "OpenCode Go", "OpenCode Go"])
        #expect(status.accounts?.map(\.credential) == ["OpenCode Go 2", "OpenCode Go", "API key"])
        #expect(HarnessSignInFlow.openCodeRemoveArguments(target: "OpenCode Go", credential: "OpenCode Go 2")
            == ["auth", "logout", "OpenCode Go", "OpenCode Go 2"])
        #expect(HarnessOnboarding.parseSignIn(.opencode, output: output, succeeded: false).state == "check_failed")
        #expect(HarnessOnboarding.parseSignIn(.opencode, output: "stored\n", succeeded: true).state == "not_checked")
        #expect(HarnessOnboarding.parseSignIn(.opencode, output: "OpenCode Go  sk-secret  stored\n", succeeded: true).accounts?.isEmpty == true)
    }

    @Test func signInOutputYieldsTheLinkAndOneTimeCode() {
        let codex = HarnessSignInFlow.artifacts("""
            \u{1b}[1mWelcome to Codex\u{1b}[0m
            Follow these steps to sign in with ChatGPT using device code authorization:

            1. Open this link in your browser and sign in to your account
               https://auth.openai.com/codex/device

            2. Enter this one-time code (expires in 15 minutes)
               ABCD-EFGHI
            """)
        #expect(codex.url?.absoluteString == "https://auth.openai.com/codex/device")
        #expect(codex.code == "ABCD-EFGHI")
        let labeled = HarnessSignInFlow.artifacts("Open https://example.test/device\nDevice code ABCD-EFGH\n")
        #expect(labeled.url?.absoluteString == "https://example.test/device")
        #expect(labeled.code == "ABCD-EFGH")
        let query = HarnessSignInFlow.artifacts("Visit https://accounts.example.test/activate?user_code=WXYZ-1234.")
        #expect(query.url?.absoluteString == "https://accounts.example.test/activate?user_code=WXYZ-1234")
        #expect(query.code == "WXYZ-1234")
        let browser = HarnessSignInFlow.artifacts("Opening browser to sign in…\nIf it didn't open, visit: https://claude.ai/oauth/authorize?code=true&state=abc\n")
        #expect(browser.url?.host == "claude.ai")
        #expect(browser.code == nil)
        #expect(HarnessSignInFlow.artifacts("Device: LOGIN\nhttp://insecure.example.test").url == nil)
    }

    @Test func signInRunsInAppExceptOpenCode() {
        #expect(HarnessSignInFlow.methods(.codex).map(\.arguments) == [["login", "--device-auth"], ["login", "--with-api-key"]])
        #expect(HarnessSignInFlow.methods(.grokBuild).map(\.arguments) == [["login", "--device-auth"]])
        #expect(HarnessSignInFlow.methods(.claudeCode).first?.arguments == ["auth", "login", "--claudeai"])
        #expect(HarnessSignInFlow.methods(.opencode).isEmpty)
        #expect(HarnessSignInFlow.signOutArguments(.codex) == ["logout"])
        #expect(HarnessSignInFlow.signOutArguments(.claudeCode) == ["auth", "logout"])
        #expect(HarnessSignInFlow.signOutArguments(.grokBuild) == ["logout"])
        let executable = URL(fileURLWithPath: "/usr/local/bin/tool")
        #expect(HarnessOnboarding.signInScript(.codex, executable: executable, searchPath: "/usr/bin") == nil)
        #expect(HarnessOnboarding.signInScript(.opencode, executable: executable, searchPath: "/usr/bin")?.contains("'auth' 'login'") == true)
    }

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
#endif
