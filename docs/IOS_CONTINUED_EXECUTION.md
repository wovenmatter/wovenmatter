# On-device continued execution

Pi Durable executes in the app process. A user-initiated foreground run can request
an iOS 26+ `BGContinuedProcessingTask` allowance so CPU and network work may continue
after the app enters the background. This is an allowance for an existing run,
not a separate agent, a retry queue, or a calendar scheduler.

## Integration contract

`DeviceBackgroundExecution` wraps the system scheduler. Keep one coordinator on
`CompanionModel`, excluded from fixtures and isolated test hosts.

1. After assigning and persisting a run ID in a foreground user Send or Resume
   action, call `begin(conversationID:runID:title:onExpiration:)` before yielding.
2. The scheduler handler attaches an allowance to that exact run and task identity.
   It **never** submits input, opens a runtime, or resumes a saved run. Submission
   uses `.fail`: if iOS cannot admit the task immediately, execution keeps using
   the existing short `UIApplication.beginBackgroundTask` fallback.
3. Feed real SDK progress events into `advanceProgress`. Completed progress units
   represent observed execution steps, with one outstanding step while the final
   workload size remains unknown. Do not manufacture progress with a timer.
4. On success, failure, Stop, or interruption, call `finish` with the captured run
   ID before clearing it. A completed run releases its allowance immediately.
5. On system expiration or system UI cancellation, persist interruption, invalidate
   the observer, cancel pending approval waits, and close the exact runtime. Keep
   the durable submission and its receipts for explicit Resume. Do not call Abort
   unless the user explicitly requested Stop. Prevent Resume while interruption
   cleanup is in flight; the same durable run ID survives resumption.
6. Returning to the foreground ends only the short UIApplication allowance, not
   an active continued-processing task. The short allowance's expiration handler
   skips runs for which `isContinuing` is true. Other runs still save and close.

Required app configuration:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array><string>$(PRODUCT_BUNDLE_IDENTIFIER).pi-durable.*</string></array>
<key>UIBackgroundModes</key>
<array><string>processing</string></array>
```

The coordinator registers concrete unique identifiers before submission; the
plist wildcard authorizes those identifiers. No GPU resource or entitlement is
requested: inference remains external, and this app requests CPU/network work.
The implementation checks iOS availability and foreground application state.
On iOS 27, submission uses the asynchronous API away from the main thread. Older
supported systems use the prior scheduler API; iOS 18–25 retain the short-task
fallback. SDK 26 builds compile the older path.

## Limits and scheduling

An allowance is not guaranteed runtime. iOS can reject or expire it because of
resource pressure, system settings, stalled progress, or user cancellation. The
system presents its own progress UI. WebKit runs code-mode JavaScript separately;
continuation of the host app does **not** establish that the WebKit worker will
remain scheduled after backgrounding or lock. Durable tool receipts still need
to distinguish an interrupted operation from one safe to retry. The code worker
must not replay side effects merely because the OS allowance expired.

Calendar entries and scheduled tasks sync independently. A due task owned by the
iPhone remains assigned to that phone. When iOS next permits execution, overdue
one-time tasks run once; missed recurring occurrences coalesce into one run.
Continued processing does not promise wakeups at arbitrary calendar times and
must not be used to transfer execution silently to the Mac.

## Validation

Offline `ContinuedExecutionLedgerTests` exercise delayed delivery after completion,
stale expiration after replacement or resumption of the same submission,
exactly-once expiration, independent conversations, denied submission cleanup,
and progress overflow. iOS SDK compilation checks the availability and scheduler
API calls. Those checks cannot establish physical-device background admission.

The Debug-only `WOVENMATTER_DEVICE_RUNTIME_SMOKE=1` hosted smoke also runs the real
Pi Durable SDK with in-memory inference, an isolated library, and a throwing
central transport. It verifies exact runtime closure before resumption, preserved
submission identity, ignored stale expiration, opening without automatic resume,
and one missed calendar task completing on its assigned device through the durable
inbox/observer path. It writes synthetic results to `Documents/runtime-smoke.json`.
Run this only in a dedicated test simulator/app container. It does not request a
continued-processing grant or establish system background admission.

Physical acceptance requires a foreground-started controlled run that uses no
provider, a real device, and these observations:

- A grant is admitted and visible in the system's progress UI; progress reflects
  actual completed work while the app is backgrounded.
- Normal completion removes the system activity and releases the allowance.
- System cancellation saves an interrupted run, closes its worker/runtime, and
  does not submit or execute anything again until the user resumes.
- Lock/background during a code-mode operation does not silently repeat writes.
- Expiration after a run has finished cannot affect a newer run or resumed attempt.
- If the system rejects admission, the short-task fallback saves an interrupted
  run when its allowance expires.

Do not report simulator or unit-test results as completion of this device gate.

## Apple sources

- [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [Continued-processing request initializer](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/init(identifier:title:subtitle:))
- [Finish tasks in the background, WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/)
- The installed iOS 27 SDK's `BGTask.h`, `BGTaskRequest.h`, and `BGTaskScheduler.h`
  verify availability, explicit progress/expiration requirements, late registration
  support for continued-processing tasks, and asynchronous submission requirements.
