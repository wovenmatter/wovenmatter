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

| Trigger | Previous automatic jobs | New automatic jobs |
| --- | ---: | ---: |
| Agent JavaScript source | 8 | 3: quick checks, macOS, gate |
| Remote service JavaScript | 4 | 2: quick checks, gate |
| iOS app view | 6 | 3: quick checks, iPhone, gate |
| Desktop-only view | 3 | 3: quick checks, macOS, gate |
| Core package source not shared with iOS | 4 | 3: quick checks, macOS with integration, gate |
| Integration fixtures | 6 | 3: quick checks, integration on macOS, gate |
| Documentation | 2 | 2: quick checks, gate |
| CI orchestrator / full automatic selection | 8 | 6: quick checks, macOS, iPhone, two image architectures, gate |

Counts exclude the PR Author label job, which only runs when a PR is opened or
reopened. Main uses the same scoped selection and cancels superseded runs.

- Run portable scripts, MCP fixtures, JavaScript suites, and generated bundle
  checks once on Linux. macOS retains native fixtures, package tests, embedded
  WebKit smoke and the unsigned app build. Image jobs retain image-specific
  isolation, native helper, Executor permission/cancellation, and vulnerability
  checks, without repeating the portable suite per architecture.
- Remove the standalone companion job and its duplicate simulator invocation.
  Run its shared package and desktop integration checks on macOS only when their
  inputs change. Integration-only changes do not build the entire desktop app.
- Keep one iPhone UI run automatically. iPad runs with the manually dispatched
  full CI workflow. Both use the same target/test suite; tablet-specific layout
  regressions consequently require manual/full validation.
- Service code changes run service tests. Image recipes, installed dependency
  records, entrypoints, security backports, harness packaging, and image test
  helpers retain both architecture builds. Pure service/agent JavaScript changes
  no longer rebuild OS packages just to copy updated source into an image.
- Replace run-specific empty build directories with stable disposable runner
  paths and cache compiler intermediates, package graphs and verified downloads.
  Cache prefixes include architecture, toolchain and dependency inputs; Swift
  and Xcode still rebuild changed sources. CI caches are separate from release
  compiler caches. No signing/provider credentials are present in these jobs.
- Fetch only the two compared commits rather than all history. Disable rename
  detection for scope selection so moving a file checks both its old and new
  component. Preserve shell failure propagation and the aggregate CI gate.
- Make Release cache warming manual, removing an unrelated macOS job from every
  source merge. A later release may take longer if its caches are cold.

The local comprehensive validation commands remain available. Signed releases,
notarization, updater verification and explicit publication approval are unchanged.

## Other workflows and limits

PR Author performs inexpensive metadata-only classification on open/reopen or
an explicit comment. It does not repeat on pushed commits and remains intact.
Analytics history runs daily, not per PR, and remains intact. Release and release
refresh workflows run only for their existing release triggers and remain intact.
The active main ruleset enforces review/ownership, not required status checks;
this PR does not change repository settings or rely on that to bypass validation.

Native and mobile cold builds can still take many minutes. Caching primarily
helps subsequent pushes; [GitHub restricts PR cache sharing across branches](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).
Image-input changes intentionally retain expensive cold image builds. These
changes reduce work and runner demand; they do not establish a universal wall
clock target. Compare the new workflow's actual job/queue timings after merge.
