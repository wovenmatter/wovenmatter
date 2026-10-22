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
