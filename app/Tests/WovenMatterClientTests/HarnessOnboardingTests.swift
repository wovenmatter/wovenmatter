import Foundation
import Testing
@testable import WovenMatterClient
import WovenMatterCore

struct HarnessOnboardingTests {
    @Test func firstLaunchRespectsExistingInstallsAndDismissal() throws {
        let name = "HarnessOnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        HarnessOnboarding.prepareFirstLaunch(defaults: defaults, hasExistingWorkspace: false, hasExistingPreferences: false)
        #expect(defaults.string(forKey: HarnessOnboarding.preferenceKey) == "pending")
        // Startup creates the database before the welcome window appears.
        HarnessOnboarding.prepareFirstLaunch(defaults: defaults, hasExistingWorkspace: true, hasExistingPreferences: true)
        #expect(defaults.string(forKey: HarnessOnboarding.preferenceKey) == "pending")
        defaults.set("dismissed", forKey: HarnessOnboarding.preferenceKey)
        HarnessOnboarding.prepareFirstLaunch(defaults: defaults, hasExistingWorkspace: false, hasExistingPreferences: false)
        #expect(defaults.string(forKey: HarnessOnboarding.preferenceKey) == "dismissed")

        for evidence in [(true, false), (false, true)] {
            defaults.removeObject(forKey: HarnessOnboarding.preferenceKey)
            HarnessOnboarding.prepareFirstLaunch(defaults: defaults, hasExistingWorkspace: evidence.0, hasExistingPreferences: evidence.1)
            #expect(defaults.string(forKey: HarnessOnboarding.preferenceKey) == "dismissed")
        }
    }

    @Test func nativeAuthenticationEvidenceMustBeExplicit() {
        #expect(HarnessOnboarding.parseSignIn(.codex, output: "Logged in using ChatGPT", succeeded: true).state == "verified")
        #expect(HarnessOnboarding.parseSignIn(.claudeCode, output: #"{"loggedIn":true}"#, succeeded: true).state == "verified")
        #expect(HarnessOnboarding.parseSignIn(.grokBuild, output: "You are logged in", succeeded: true).state == "verified")
        #expect(HarnessOnboarding.parseSignIn(.codex, output: "Not logged in", succeeded: false).state == "sign_in_required")
        #expect(HarnessOnboarding.parseSignIn(.claudeCode, output: #"{"loggedIn":false}"#, succeeded: true).state == "sign_in_required")
        #expect(HarnessOnboarding.parseSignIn(.grokBuild, output: "network unavailable", succeeded: false).state == "check_failed")
        #expect(HarnessOnboarding.parseSignIn(.grokBuild, output: "model catalog", succeeded: true).state == "not_checked")
        #expect(HarnessOnboarding.parseSignIn(.codex, output: "Logged in using ChatGPT\nrequest failed", succeeded: false).state == "check_failed")
    }

    @Test func savedOpenCodeCredentialsDoNotImplyVerifiedAccess() {
        #expect(HarnessOnboarding.parseSignIn(.opencode, output: "0 credentials\n0 environment variables", succeeded: true).state == "sign_in_required")
        #expect(HarnessOnboarding.parseSignIn(.opencode, output: "1 credential\n0 environment variables", succeeded: true).state == "credentials_present")
        #expect(HarnessOnboarding.parseSignIn(.opencode, output: "0 credentials\n2 environment variables", succeeded: true).state == "credentials_present")
        #expect(HarnessOnboarding.parseSignIn(.opencode, output: "1 credential", succeeded: false).state == "check_failed")
    }

    @Test func rawStatusOutputIsNeverExposedInTheUI() {
        let privateOutput = "credential-secret@example.invalid token=private-token"
        let result = HarnessOnboarding.parseSignIn(.codex, output: privateOutput, succeeded: false)
        #expect(!result.detail.contains("private-token"))
        #expect(!result.detail.contains("example.invalid"))
    }
}

extension HarnessOnboardingTests {
    @Test func signInCommandsQuotePathsAndKeepOpenCodeProviderChoiceInteractive() throws {
        let executable = URL(fileURLWithPath: "/fixture/O'Brien $(touch danger)/tool")
        let script = try #require(HarnessOnboarding.signInScript(.opencode, executable: executable, searchPath: "/fixture/bin:$PATH"))
        #expect(script.contains("export PATH='/fixture/bin:$PATH'"))
        #expect(script.contains("'/fixture/O'\\''Brien $(touch danger)/tool' 'auth' 'login'"))
        #expect(!script.contains("--provider"))
        #expect(HarnessOnboarding.signInScript(.defaultAgent, executable: executable, searchPath: "") == nil)
    }
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
