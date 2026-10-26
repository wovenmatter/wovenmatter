# Test-suite audit — 2026-10-26

Baseline: `07e7bdaa6cbca9eb9bf4994d3a1fde1bfc28b43f` (main after the HTML reply merge).

The audit removes 252 named test definitions, from 1,231 to 979 (**20.47%**).
Previously covered production Swift lines lose **1.9623%** of their coverage, equivalent to **0.9636 percentage points** with the executable-source denominator held fixed.

## Inventory

| Test definitions | Before | After | Removed |
| --- | ---: | ---: | ---: |
| Desktop Swift | 534 | 344 | 190 |
| iOS Swift, including unchanged app/UI tests | 190 | 157 | 33 |
| Shared Swift | 45 | 16 | 29 |
| Companion integration | 29 | 29 | 0 |
| Named standalone Swift checks | 16 | 16 | 0 |
| Default-agent Node | 213 | 213 | 0 |
| Remote Node | 170 | 170 | 0 |
| Native MCP Node | 10 | 10 | 0 |
| Python unittest methods | 24 | 24 | 0 |
| **Total** | **1,231** | **979** | **252** |

A Swift parameterized declaration counts once, matching Swift Testing's test summary; its argument combinations are not counted as separate definitions. The 51 standalone/driver files listed in the [machine-readable inventory](testing/test-suite-audit.json) remain intact and are outside this named-test count. Drivers often invoke already counted cases. This is a reduction in test definitions, not a claim that 20% of files, assertions, or execution time disappeared.

Of the 252 removed definitions, 251 are deletions and one is a consolidation: the broker's permission assertions now share the surviving response-validation scenario. It additionally verifies that completing a question releases the identifier for a subsequent permission request. Twenty-four empty test files and their private fixtures were removed; persistence fixtures used elsewhere moved into `Support/PersistenceFixtures.swift`.

## Coverage evidence

| Production Swift metric | Baseline covered | Candidate covered | Previously covered locations lost | Relative loss of baseline hits | Loss in percentage points |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unique source lines | 43,979 | 43,126 | 863 | 1.9623% | 0.9636 |
| Unique source regions | 28,323 | 27,200 | 1,130 | 3.9897% | 1.8055 |

The denominator is frozen at 89,563 executable source lines and 62,586 source regions. Line coverage is 49.1040% before and 48.1516% after. The loss calculation gives no credit for newly observed hits, so it is stricter than subtracting the displayed coverage rates. Missing files cannot improve the result by shrinking the denominator.

The primary gate is less than 2% relative loss of previously covered **lines**. Source regions are also reported: their relative loss is 3.9897%, while their coverage-rate loss remains under two percentage points. These are different metrics; this audit does not claim less than 2% relative region loss.

Both sides used Xcode 27.0 (27A5194q), Swift 6.4, arm64, `swiftbuild`, committed dependency graphs, and `--enable-code-coverage`. Production sources were identical between the baseline and candidate. Fresh runs enumerated 736 baseline and 484 retained package/integration test definitions: 734 and 482 passed, respectively, with the same two existing environment-gated cases skipped on each side. Each test ran in a separate process except the unchanged four-test `PiCodeModePolicyTests` class, which ran in normal XCTest order on both sides. That preserves its WebKit warm-up: isolating its approval-wait test exposed a cold-start timeout in the synthetic two-second watchdog on both sides, while both complete classes and normal package runs passed unchanged. No timeout or assertion was weakened.

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

Use separate instrumented builds and profile directories for the two revisions. Build the `app`, `shared`, `ios`, and `integration` packages with `swift test --build-system swiftbuild --enable-code-coverage`; collect and merge all process profiles, including the suites the repository runner isolates. Export against the corresponding revision's binaries. A single overwritten SwiftPM `default.profdata` from the last filtered run is not the full-suite baseline.

## Selection and validation boundaries

The removal candidates had low incremental source coverage relative to broader retained tests. Coverage alone does not establish equivalent assertions: this change deliberately gives up some narrow regression checks, reflected in the source-region loss above. The manifest names every removed declaration for review.

The integration flows, credential probes and keychain checks, pairing/authentication boundaries, durable archive/privacy checks, async database tests, optional OpenCode compatibility check, and all newly merged HTML tests remain. JavaScriptCore/WebKit runtime suites were protected because Swift coverage cannot measure their embedded JavaScript. The 62 iOS app/UI tests and 16 named standalone Swift checks were unchanged and are outside the package coverage measurement. Node and Python suites were unchanged. The optional OpenCode executable check and packaged-HTML acceptance case retain their existing environment gates; coverage did not enable them or use provider services.

Fresh baseline and retained coverage runs passed, as did the shared/iOS package and integration runs. Node results were 212 passes plus one platform skip for default-agent, 169 passes plus one platform skip for remote, and ten native MCP passes. The full `scripts/test-changes.sh --all` workflow and the PR's desktop, companion, iPhone, and iPad CI checks are the final release-readiness validation; their final outcomes are recorded in the PR rather than inferred from coverage.
