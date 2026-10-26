# Test-suite audit — 2026-10-26

Inventory and production-source baseline: `26f5e3952b11af34aa2b6485dad05e8430ab665b` (main after the dead-code cleanup). The production sources measured by package coverage and all dependency graphs are identical on both sides. The separate iOS app target has one crash fix described below.

The audit removes 245 named test definitions, from 1,222 to 977 (**20.05%**).
Previously covered production Swift lines lose **1.9895%** of their coverage, equivalent to **0.9806 percentage points** with the executable-source denominator held fixed.

## Inventory

| Test definitions | Before | After | Removed |
| --- | ---: | ---: | ---: |
| Desktop Swift | 521 | 338 | 183 |
| iOS Swift, including retained app/UI tests | 188 | 155 | 33 |
| Shared Swift | 45 | 16 | 29 |
| Companion integration | 29 | 29 | 0 |
| Named standalone Swift checks | 16 | 16 | 0 |
| Default-agent Node | 213 | 213 | 0 |
| Remote Node | 170 | 170 | 0 |
| Native MCP Node | 10 | 10 | 0 |
| Python unittest methods | 30 | 30 | 0 |
| **Total** | **1,222** | **977** | **245** |

A Swift parameterized declaration counts once, matching Swift Testing's test summary; its argument combinations are not counted as separate definitions. The 52 standalone/driver files listed in the [machine-readable inventory](testing/test-suite-audit.json) remain intact and are outside this named-test count. Drivers often invoke already counted cases. This is a reduction in test definitions, not a claim that 20% of files, assertions, or execution time disappeared.

Of the 245 removed definitions, 244 are deletions and one is a consolidation: the broker's permission assertions now share the surviving response-validation scenario. It additionally verifies that completing a question releases the identifier for a subsequent permission request. Twenty-five empty test files and their private fixtures were removed; persistence fixtures used elsewhere moved into `Support/PersistenceFixtures.swift`.

## Coverage evidence

| Production Swift metric | Baseline covered | Candidate covered | Previously covered locations lost | Relative loss of baseline hits | Loss in percentage points |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unique source lines | 43,227 | 42,409 | 860 | 1.9895% | 0.9806 |
| Unique source regions | 27,885 | 26,815 | 1,107 | 3.9699% | 1.8005 |

The denominator is frozen at 87,698 executable source lines and 61,484 source regions. Line coverage is 49.2907% before and 48.3580% after. The loss calculation gives no credit for newly observed hits, so it is stricter than subtracting the displayed coverage rates. Missing files cannot improve the result by shrinking the denominator.

The primary gate is less than 2% relative loss of previously covered **lines**. Source regions are also reported: their relative loss is 3.9699%, while their coverage-rate loss remains under two percentage points. These are different metrics; this audit does not claim less than 2% relative region loss.

Both sides used Xcode 27.0 (27A5194q), Swift 6.4, arm64, `swiftbuild`, committed dependency graphs, and `--enable-code-coverage`. Fresh runs enumerated 722 baseline and 477 retained package/integration test definitions: 720 and 475 passed, respectively, with the same two existing environment-gated cases skipped on each side. After retaining the execution-revocation and approval-response regressions, all tests in their two rebuilt binaries were rerun; profiles were reused only for nine binaries verified byte-identical by SHA-256.

The baseline exposed an existing fixture bug in `InferenceOAuthTests`: comparing independently serialized JWTs could fail to select the mismatched account, depending on JSON key order. Both baseline and candidate use the same explicit credential/account case pairs, preserving every assertion. The fixture file and hash are recorded in the JSON report. The only production change is in the separate iOS app target: reopening saved conversations could trap on an overlapping dictionary read/write while migrating tool selections. The migration now reads the loop’s local record value before writing the dictionary. The existing defaults and goal-restoration tests caught this on iPhone. This file is outside package coverage; the measured sources and coverage results are unchanged.

Each test ran in a separate process except the unchanged four-test `PiCodeModePolicyTests` class, which ran in normal XCTest order on both sides. That preserves its WebKit warm-up: isolating its approval-wait test exposed a cold-start timeout in the synthetic two-second watchdog on both sides, while complete classes and normal package runs passed unchanged. No timeout or assertion was weakened.

Profiles from every component and isolated suite were merged with `llvm-profdata merge -sparse`. `llvm-cov export` produced LCOV and JSON using every instrumented test binary. The comparator deduplicates source coordinates across binaries and generic instantiations, and excludes tests, fixtures, generated macros, dependencies, and non-repository code.

```sh
python3 scripts/compare-test-coverage.py \
  --baseline-root "$BASELINE_ROOT" --candidate-root "$CANDIDATE_ROOT" \
  --baseline-lcov "$BASELINE_COVERAGE/coverage.lcov" \
  --candidate-lcov "$CANDIDATE_COVERAGE/coverage.lcov" \
  --baseline-json "$BASELINE_COVERAGE/coverage.json" \
  --candidate-json "$CANDIDATE_COVERAGE/coverage.json" \
  --output comparison.json
```

Use separate instrumented builds and profile directories for the two revisions, with the same deterministic credential fixture correction described above applied to the baseline. Build the `app`, `shared`, `ios`, and `integration` packages with `swift test --build-system swiftbuild --enable-code-coverage`; collect and merge all process profiles, including the suites the repository runner isolates. Export against the corresponding revision's binaries. A single overwritten SwiftPM `default.profdata` from the last filtered run is not the full-suite baseline.

## Selection and validation boundaries

The removal candidates had low incremental source coverage relative to broader retained tests. Coverage alone does not establish equivalent assertions: this change deliberately gives up some narrow regression checks, reflected in the source-region loss above. The manifest names every removed declaration for review.

The integration flows, credential probes and keychain checks, pairing/authentication boundaries, durable archive/privacy checks, async database tests, optional OpenCode compatibility check, and all newly merged HTML tests remain. JavaScriptCore/WebKit runtime suites were protected because Swift coverage cannot measure their embedded JavaScript. All 61 iOS app/UI tests and 16 named standalone Swift checks remain and are outside the package coverage measurement. Hosted iPhone/iPad validation exposed a dangling-symlink fixture in the HTML boundary test: the outside image had never been created. The fixture now creates a readable image and verifies rejection both by the workspace resolver and by HTML preparation; no assertion was removed. Node and Python suites are unchanged by this PR. The optional OpenCode executable check and packaged-HTML acceptance case retain their existing environment gates; coverage did not enable them or use provider services.

Fresh baseline and retained coverage runs passed. Full portable validation (`scripts/test-ci.sh --all`) also passed after the main refresh: default-agent had 212 passes plus one platform skip, remote had 169 passes plus one platform skip, and native MCP had ten passes, alongside the repository's Python and shell fixtures. Local iOS UI launch was blocked by `DTServiceHubClient failed to bless service hub`; it is not counted as passed. Automatic PR CI and explicitly dispatched desktop/companion, iPhone, and iPad validation workflows are the final production-readiness checks; their outcomes and tested revisions are recorded in the PR rather than inferred from coverage.
