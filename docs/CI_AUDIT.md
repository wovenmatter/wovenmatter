# CI audit — October 26, 2026

The review used all six workflows, their invoked scripts, the active main
ruleset, the 100 most recent workflow runs, and seven representative job lists.
Step durations below exclude runner queue time; run-level elapsed time includes
queueing and can also include reruns, so it is not used as a benchmark.

## Measured costs

| Work | Observed duration | Evidence |
| --- | --- | --- |
| Desktop validation | 16.5–26.8 minutes across sampled successful jobs | [26.8-minute job](https://github.com/wovenmatter/wovenmatter/actions/runs/40344171138/job/121646666740) |
| iPhone UI | 10.9–19.4 minutes across sampled successful jobs | [19.4-minute job](https://github.com/wovenmatter/wovenmatter/actions/runs/40344171138/job/121646666619) |
| iPad UI | 11.1–17.9 minutes across sampled successful jobs | [17.9-minute job](https://github.com/wovenmatter/wovenmatter/actions/runs/40355746006/job/121687737721) |
| Companion job | 13.7–18.9 minutes across sampled successful jobs | [18.9-minute job](https://github.com/wovenmatter/wovenmatter/actions/runs/40344171138/job/121646667075) |
| Remote image construction | 31.2 minutes for workspace alone on amd64; 22.2 on arm64 | [amd64 job](https://github.com/wovenmatter/wovenmatter/actions/runs/40378196789/job/121767554568) |
| Remote deterministic validation | 1.4–2.0 minutes, repeated by desktop and each remote architecture | [2.0-minute step](https://github.com/wovenmatter/wovenmatter/actions/runs/40378196789/job/121767554568) |
| Release cache preparation | 19.6 minutes of job execution, including 14.5 minutes warming the Release compiler | [cache job](https://github.com/wovenmatter/wovenmatter/actions/runs/40372267906/job/121745836994) |

The 100-run sample contained 64 PR CI runs: 38 cancelled, 18 failed, seven
successful, and one pending. This is a snapshot, not a long-term failure rate.
The main branch could accumulate independent CI runs because concurrency was
keyed by commit and cancellation applied only to PRs. A source merge also
started a separate macOS Release cache job.

The companion log identifies substantial duplication: its shared package built
in 57 seconds, mobile package in 69 seconds, then it spent roughly 12.7 minutes
building/running simulator app tests before building integration in 134 seconds
and running its 29 tests in 13 seconds. The iPhone UI job already runs those app
tests. Removing the companion simulator pass saves that repeated build, boot,
and XCTest work while retaining both app tests and protocol integration.

## Changes

| Trigger | Previous automatic CI jobs | New automatic CI jobs |
| --- | ---: | ---: |
| Agent JavaScript source | 8 | 1 |
| Remote service JavaScript | 4 | 1 |
| iOS app view | 6 | 1 |
| Desktop-only view | 3 | 1 |
| Core package source not shared with iOS | 4 | 1 |
| Integration fixtures | 6 | 1 |
| Documentation | 2 | 1 |
| CI configuration | 8 | 1 |
| Merge to main | 2–8, plus an optional Release cache job | 0 |

Previous counts exclude the automatic PR Author label job. Author classification
is now explicitly requested with `/recheck-author`, so new PRs also avoid that
extra automatic check. No repository protection or code-owner settings change.

- `ci.yml` has one Linux job named **CI**, triggered only by PRs. It scans the
  public tree, checks shell/Python syntax and routing fixtures, and selects
  portable scripts, agent/service tests and generated-resource checks by path.
  JavaScript suites run once. A failed command fails the same check directly;
  no detector or aggregate gate runner is needed.
- New commits cancel stale CI on that PR. There is no main push trigger or
  per-merge Release cache warmer. Release cache preparation remains manual.
- `validation.yml` runs only through explicit workflow dispatch. Choose
  `desktop`, `mobile`, `images`, or `all` (default). Desktop retains native
  fixtures, package tests, the unsigned app build, embedded WebKit smoke,
  companion integration and signed delta validation. Mobile retains both iPhone
  and iPad app/UI tests. Images retain both architectures, container isolation,
  Executor helper/permission/cancellation checks and the vulnerability inventory.
  The `all` option also runs every portable suite.
- Manual desktop and mobile jobs use stable disposable paths and build caches
  keyed by toolchain, architecture and dependencies. Companion integration no
  longer repeats simulator app tests; the mobile jobs provide that coverage.
  Platform jobs do not repeat portable suites already handled by Linux.
- Fetch only the two compared commits rather than all history. Disable rename
  detection for scope selection so moving a file checks both its old and new
  component. Preserve shell failure propagation and frozen package graphs.
- Remove the release workflow's informational lookup of completed main CI,
  since those runs no longer exist. Source ancestry, signing, notarization,
  updater verification and explicit publication approval remain intact.

The [portable job on the first cleanup revision](https://github.com/wovenmatter/wovenmatter/actions/runs/40393227941/job/121819379775)
completed successfully in 2 minutes 20 seconds on GitHub. This is an observed
baseline for the retained Linux path, not a universal duration guarantee.

The local comprehensive validation commands remain available. Manual platform
jobs retain their existing tests and failure status; moving them out of PR CI
does not establish that they pass. The earlier combined PR run had native,
mobile and image failures, which remain separate from portable CI success.

## Coverage boundary and other workflows

Automatic CI does not compile Swift, launch simulators, build containers, test
container isolation, or produce an image vulnerability inventory. A Swift-only
PR receives repository scans and portable infrastructure checks; native behavior
requires a local or explicitly requested platform run. Compile, mobile UI,
architecture and image-security regressions can therefore reach merge without
an automatic failure. Maintainers choose when to request those checks.

Manual validation can still take many minutes. Caching primarily helps repeat
runs; [GitHub restricts PR cache sharing across branches](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).
Cold image builds intentionally preserve fresh package/security inputs. Moving
this work to an explicit run removes it from the emerging PR review path.

PR Author is comment-triggered and metadata-only. Analytics history remains
daily rather than per PR. Release and release refresh retain their existing
explicit release triggers. Signed production release builds remain separate
from source validation. The active main ruleset enforces review/ownership, not
required status checks; this PR does not change those repository settings.
