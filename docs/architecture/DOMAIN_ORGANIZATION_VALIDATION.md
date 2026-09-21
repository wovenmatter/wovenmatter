# Domain organization validation

Historical validation for PR #63. These results describe the refactor candidate,
not the current release candidate.

Product and test implementation: `be09947f52278a5afe2671fd36f8807695d3f5c1`.
Base: `51b592a61e99a10575516263bdd31dfb29646991` (`main`).

The checks below completed on September 19, 2026. This record preserves the
verified command outcomes and probe source from the implementation task after
the temporary build caches and logs were removed. Subsequent documentation-only
changes do not change the tested implementation. Hosted checks are attached to
[PR63](https://github.com/wovenmatter/wovenmatter/pull/63).

## Source audit

The complete diff was reviewed alongside the ownership and moved-symbol map in
[DOMAIN_ORGANIZATION.md](DOMAIN_ORGANIZATION.md). A fresh comparison with the
base confirms:

- All 195 original database method/type bodies are preserved, including
  declaration attributes and constructors. Comparison permits only documented
  private-to-internal access changes, `lock.withLock` to `withLock`, and
  `sqlite3_changes(connection)` to `changedRowCountUnlocked`. The only additional
  method is the forwarding `withLock` entry point.
- All 171 multiline SQL literals and all 11 public value/error types are
  byte-identical. The multiset of public declarations is unchanged.
- All 21 methods moved to `ApplicationUsageModel` are byte-identical. The
  application retains its existing signatures and forwards every argument.
- The SQLite connection and lock remain private. Domain-only helpers retain
  private access. No schema, persistence policy, provider behavior, refresh
  policy, UI layout or rendering implementation changed.
- Project plist validation and `git diff --check` passed.

These comparisons are review evidence, not new tests of file locations. Runtime
contracts continue to be exercised by the existing persistence/provider suites
and the usage observation tests.

## Full local validation

```sh
WOVENMATTER_TEST_CACHE_DIR=/private/tmp/wovenmatter-organization-validation \
WOVENMATTER_NOTE_TEST_CACHE_DIR=/private/tmp/wovenmatter-organization-validation/NoteEditor \
WOVENMATTER_SOCKET_TEST_CACHE_DIR=/private/tmp/wovenmatter-organization-validation/NoteSocket \
scripts/test-changes.sh --all
```

The command exited with status 0. Results:

- 161 core tests in 31 suites and 105 client tests in 18 suites passed.
- Remote service tests: 50 passed, one platform-specific skip, zero failures.
- The usage model probe passed preference restoration, observable consent/error
  changes, idempotent consent and rejected-action guards.
- Native quit, composer, six note edit/parse/save/reopen cases and eight note
  socket tests passed, as did remote workspace inspection and privacy checks.
- The complete unsigned Xcode app build and native bundle validation passed.

Hosted macOS validation also passed. The first hosted Remote workspace job
failed in unchanged `remote/test/service.test.mjs:258` with `UND_ERR_SOCKET`
(`other side closed`), the inherited readiness race addressed by PR55. One
bounded failed-job rerun passed, making all checks green at the implementation
head. PR55's fix was not imported into this PR.

## Real ApplicationModel observation probe

A second probe linked the already-built app's testable `WovenMatter` module and
Debug dylib. It instantiated the real `ApplicationModel`, with automatic startup
disabled and a unique temporary UserDefaults suite. No app/package rebuild,
provider access, credential access, provider CLI or shared Dev operation was
needed. It verified the application getters through the private usage owner,
not a substitute facade.

The executable exited with status 0 and printed:

```text
Real ApplicationModel facade: observable consent/error changes propagate through the private usage owner; disabled sign-in stays rejected and startup stays disabled.
```

To reproduce after the full local build, save this source as
`/private/tmp/wovenmatter-organization-facade-probe.swift`:

```swift
import Foundation
import Observation
import WovenMatterCore
@testable import WovenMatter

@main
struct ApplicationUsageFacadeProbe {
    @MainActor
    static func main() throws {
        let suite = "wovenmatter-organization-facade.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ApplicationModel(applicationDefaults: defaults, startsAutomatically: false)
        precondition(model.state == .starting)
        precondition(model.localUsage == nil && !model.isRefreshingLocalUsage)
        precondition(model.enabledUsageProviders.isEmpty)
        precondition(!model.hasAcknowledgedCredentialAccessDisclosure)
        let consent = Changes()
        withObservationTracking {
            _ = model.hasAcknowledgedCredentialAccessDisclosure
        } onChange: { consent.record() }
        model.acknowledgeCredentialAccessDisclosure()
        precondition(consent.count == 1)
        precondition(model.hasAcknowledgedCredentialAccessDisclosure)
        let errors = Changes()
        withObservationTracking {
            _ = model.localUsageError
        } onChange: { errors.record() }
        model.signInUsageProvider(.claude)
        precondition(errors.count == 1)
        precondition(model.localUsageError == "Enable Claude usage tracking before signing in.")
        precondition(model.signingInUsageProviders.isEmpty)
        precondition(model.localUsage == nil && !model.isRefreshingLocalUsage)
        precondition(model.state == .starting)
        print("Real ApplicationModel facade: observable consent/error changes propagate through the private usage owner; disabled sign-in stays rejected and startup stays disabled.")
    }
}
private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
```

The recorded command on the arm64 Mac was:

```sh
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos26.0 \
  -module-cache-path /private/tmp/wovenmatter-organization-validation/ModuleCache \
  -I /private/tmp/wovenmatter-organization-validation/DerivedData/Build/Products/Debug \
  /private/tmp/wovenmatter-organization-facade-probe.swift \
  '/private/tmp/wovenmatter-organization-validation/DerivedData/Build/Products/Debug/Woven Matter Dev.app/Contents/MacOS/Woven Matter Dev.debug.dylib' \
  -Xlinker -rpath -Xlinker '/private/tmp/wovenmatter-organization-validation/DerivedData/Build/Products/Debug/Woven Matter Dev.app/Contents/MacOS' \
  -o /private/tmp/wovenmatter-organization-validation/ApplicationUsageFacadeProbe
/private/tmp/wovenmatter-organization-validation/ApplicationUsageFacadeProbe
```

This establishes the changed observation boundary and the native build. It does
not claim a live provider run or acceptance of the combined Dev build. Shared
Dev integration and combined feature testing remain manager-owned.
