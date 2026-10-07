# Release policy cleanup for the next release

Baseline: accepted main `14e6d533b0ba9c4f2f9500b76af3eb9b1f6f4a8c` and
[successful main CI 37642257650](https://github.com/wovenmatter/wovenmatter/actions/runs/37642257650).
This change is for a future main-based release. It does not change the v0.2.5
source/tag, its running release workflow, or publication ownership.

## Removed and retained policy

Source tests belong to development/main CI. A release starts from an accepted
main commit and does not become another validation cycle. Apple notarization is
a signature/security scan, not execution of this repository's source test suites.
The platform requirements and repository choices below are different things.

| Check or work | Before | After | Reason / retained coverage |
| --- | --- | --- | --- |
| Existing GitHub API identity matches configured SSH account | Local access preflight before mutation | Retained | Credential security; no login/recovery/account changes |
| Clean, current main candidate | Local release procedure | Retained | Repository source integrity |
| Annotated semantic version tag, never moved/reused | Local release procedure | Retained | Repository immutable source identity |
| Tag syntax, tag SHA equals workflow SHA, accepted main ancestry | Release job | Retained before secrets | Small source integrity gates |
| Local `test-changes.sh --all` prerequisite | Mandatory before tagging | Removed entirely | Main/development validation owns this; no conditional local fallback |
| Release-triggered CI dispatch, wait, or rerun | No separate dispatch, but source suites repeated | Forbidden during release preparation | Start the release workflow; no new CI validation cycle |
| Already-completed exact-source main CI metadata | Not reused | Informational URL when available | Does not block on unavailable metadata, skipped jobs, or request new permissions |
| Extra standalone release-contract fixtures | `test-release.sh` before `--all`, then again inside `--all` | Removed from release | Manifest/access/approval/notary/code fixtures remain in main/development static checks |
| Public-tree privacy/secret scan | Main CI and multiple release invocations | Main CI only | Identical accepted tree; remove repeated release scanning |
| Shell/JS syntax and harness catalog checks | Main CI and release `--all` | Main/development CI only | Existing test dispatcher unchanged |
| Development signing fixture | Main CI and release `--all` | Main/development CI only | Identity selection and persistence tests retained |
| Termination/composer/layout/note-editor/note-socket fixtures | Main CI and release `--all` | Main/development CI only | Existing implementations retained |
| Executor deployment, remote tools, native CLI, Hermes and remote-workspace fixtures | Main CI and release `--all` | Main/development CI only | Existing implementations retained |
| Built-in agent npm tests | Main CI and release `--all` | Main/development CI only | Locked dependency validation retained in CI |
| Remote npm tests | Main CI and release `--all` | Main/development CI only | Linux/remote validation stays in existing CI selection |
| Aggregate Swift tests | Main CI and release `--all` | Main/development CI only | Swift test sources/dispatcher retained |
| Six isolated resource-heavy Swift suites | Main CI and release `--all` | Main/development CI only | Startup/deadline/reaping/archive/concurrency bounds retained |
| Application usage/backend process fixtures | Main CI and release `--all` | Main/development CI only | Same Swift fixture sources |
| Unsigned Debug app / CEF build | Main CI and release `--all` | Main/development CI only | Never used as a production Release binary |
| Debug bundled native CLI and mocked CEF lifecycle fixture | Main CI and release `--all` | Main/development CI only | Lifecycle test substitutes CEF entry points; it does not run all of Chromium |
| Linux workspace/Executor image builds, helper prerequisites, scope/approval/cancellation tests | Main CI | Retained unchanged | Platform/remote functionality checks; never newly introduced into release |
| Opt-in container lifecycle / real-CEF password fixtures | Separate development checks | Retained unchanged | Not evidence supplied by automated release; no live test expansion |
| CMake availability | Before release validation/build | Before production build | Required build input |
| New production Release arm64 build, fresh DerivedData, version/build/source revision | After repeated Debug build/tests | Retained | Production functionality/distribution identity |
| Bundled resources, helpers, engines, licenses and removed-symbol checks | Actual production app validation | Retained | Validate what ships; different from source tests |
| Root Developer ID grep | Separate root signature detail command | Removed duplicate | Per-Mach-O validator already checks the main executable and every other native image |
| Deep/strict bundle verification and per-image Developer ID/timestamp/runtime/signature checks | Production app preflight | Retained | Bundle resource sealing plus executable signing security |
| Hand-written manifest generator in publication fixture | Parallel fixture implementation | Removed | Fixture calls the real generator; all approval/download scenarios remain |
| Developer ID signing / hardened runtime / secure timestamps | Production app/helpers/DMG | Retained | Apple's notarization requirements for this distribution method |
| App ZIP submission, accepted-status gate and rejection log | Production notarization | Retained | Apple distribution/security checks; reject pending/invalid/transport failures |
| App staple/validate and Gatekeeper assessment | Production app | Retained | Ticket availability and distribution acceptance |
| DMG creation, compression, application link and signing | Production packaging | Retained | Repository distribution format; Apple accepts multiple formats |
| DMG submission, accepted-status gate, staple/validate and Gatekeeper assessment | Production DMG | Retained | Final deliverable distribution/security checks |
| `latest-mac.json` and SHA256SUMS | Production output | Retained | Updater functionality and exact download identity |
| Exact private asset set, refuse replacement of published assets | Same build job stages draft | Separate staging job, tag commit rechecked before mutation | Preserve private-draft protections; retry upload without build/notary repetition |
| Downloaded draft verification before approval/publication | Publication script | Retained unchanged | Remote tag/main/workflow/assets/manifest/checksums/signing/notarization/Gatekeeper checks are on downloaded artifacts |
| Full user-facing description, exact approved notes, default verify-only, explicit publication approval | Skill / publication script | Retained unchanged | Repository consent/publication protection |
| Signing environment, keychain/key cleanup, existing credentials and token permissions | Release job | Retained | No branch-protection, credential, environment or permission changes |
| Compiler inputs / dependency trees / signed products in Actions cache | No Actions cache | Not cached | Avoid toolchain staleness, signed product reuse and secret caching |
| Pinned CEF raw download | Cold hosted-runner download | Exact OS/architecture + pin/script-hash cache | No fallback keys; checksum checked on fresh extraction including restore; no `.verified` marker or extracted SDK in Actions cache |
| Build progress | One opaque build/sign/notarize/package step | Timestamped stage notices and step summary | Exposes compile, signing preflight, app Apple wait, packaging, DMG Apple wait, manifest and completion without a new framework |

GitHub's [release API](https://docs.github.com/en/rest/releases/releases#create-a-release)
requires authorized repository access and a tag/asset publication operation. It
does not require this project's Swift/npm/fixture suites or a Debug build.
Apple's [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
cover valid Developer ID signing, hardened runtime, secure timestamps and other
binary protections. Stapling/Gatekeeper checks support reliable distribution.
The two app/DMG submissions, DMG format, arm64-only build, manifest, main/tag
policy and notes approval are repository distribution/policy choices, not a
GitHub mandate to rerun tests. They remain because they protect the shipped
artifact, updater functionality or publication consent. Neither platform
requires a locally repeated `--all` as a release gate.

## Coverage evidence and limits

There is no recorded line/branch baseline or code-coverage gate in `ci.yml`,
`test-changes.sh`, the Xcode scheme, or the npm package scripts. Swift tests do
not enable code coverage; npm uses `node --test` without coverage instrumentation.
No percentage loss can be established from test counts. **The requested maximum
2% measured code-coverage loss cannot be numerically established from this
repository's current facilities.** This PR does not pretend otherwise or delete
unique behavioral fixtures based on a guessed allowance.

| Verifiable inventory / behavior | Baseline | Candidate |
| --- | --- | --- |
| Existing Swift package test files | 117 | Same 117, byte-identical |
| Existing Built-in agent test files | 22 | Same 22, byte-identical |
| Existing remote test files | 11 | Same 11, byte-identical |
| Existing script fixture files | 22 | Same 22; 21 byte-identical, approval fixture uses real manifest generator |
| General main CI and source-test dispatcher | Existing path-selected checks | Byte-identical; no suite/filter/bounds removed |
| Approval fixture scenarios | Default private; explicit verify; empty/whitespace/placeholder/missing notes rejected; failed verification blocks publication; approved exact text published | Same scenarios, focused fixture passes |
| Manifest/access/notarization/signing fixtures | Existing contract cases | Retained; focused baseline and candidate checks pass |
| New CEF archive cache boundary | No cross-run archive cache | Offline cold download, archive restore without redownload, corrupt checksum rejection |
| Duplicate root signing identity assertion | Root grep plus every-Mach-O identity assertion | Every-Mach-O assertion retains main executable identity; deep resource sealing remains |
| Source test executions in release | Local full suite + separate release fixtures + release full suite | None; development/main CI remains the source of those checks |
| Measured line / branch delta | Not available | Not available; no invented 2% or test-count-to-coverage conversion |

The aggressive cuts are repeat executions, the duplicate root identity assertion,
and the parallel fixture manifest implementation. The remaining release-contract
fixtures cover different failure modes; manifest generation, access identity,
publication consent, Apple outcomes and per-image signing are not interchangeable.
Deleting unique scenarios without a coverage baseline would not establish the
requested boundary. No additional broad source-test deletion is justified by
this audit. This is behavioral/check evidence, not a measured code-coverage claim.

## Observed avoidable time

These are the supplied observations for the baseline, not a new benchmark and
not a promised total release duration:

| Observation | Time | Effect of cleanup |
| --- | --- | --- |
| Main macOS CI job | 16m02s | Runs in development/main CI; not repeated for release |
| Cold SwiftPM compile within that job | 3m30s | Removed from release repeat; included in job duration, not additive |
| Aggregate Swift tests | About 75s | Removed from release repeat |
| Six isolated heavy suites | About 77s | Removed from release repeat |
| Unsigned app/CEF build and bundle interval | 6m47s | Removed from release; signed Release build remains |
| Local pre-tag validation | 4m44s failed CMake PATH attempt + 5m26s warm success = 10m10s | Entire prerequisite removed |
| Repeated release validation on the same source | About 8m failed attempt + 15m01s successful retry = about 23m | Removed entirely |
| CEF Actions archive cache | No before/after timing | No claimed savings; still compiles wrapper/adapter and bundles/signs fresh outputs |
| Signed build / Apple wait / packaging / queue time | Separate variable costs | Retained; no total-duration promise |

Do not add component durations to the CI/validation durations: they overlap.
The supplied duplicate local/release attempt history totals about 33 minutes of
avoidable validation work for this candidate, not a guaranteed future saving.
Future stage notices identify actual progress in the running Actions log; the
step summary retains the timestamped timeline when the step completes. This does
not add a separate downloadable live-log service or estimate Apple's ETA.

## Retry and artifact boundary

The successful signed job uploads only `dist/*` as an immutable, run/attempt-named
transfer artifact. Staging uses the upstream job's output name in the same run,
checks SHA256SUMS and the remote annotated tag against the workflow SHA, then
uploads only into a private draft and checks its asset set.
Rerunning a failed staging job reuses that successful build's artifact, including
when the successful build came from an earlier attempt. Transfer retention is
seven days; an expired transfer requires a new signed build. No signing material
or source/build cache is uploaded. Build/sign/notarize/package still form one
retry unit; finer persistence of intermediate signed products was not introduced.

The published release remains gated by `publish-release.sh` and explicit approved
notes. Branch protection, general CI, credentials, token permissions and v0.2.5
remain untouched. This cleanup does not itself tag, build, publish, install, merge
or dispatch any workflow.
