// Exercise the actual adapter's ownership/termination state without loading
// Chromium. In particular, these tests cannot touch Chromium Safe Storage.
#define CefInitialize TestCefInitialize
#define CefShutdown TestCefShutdown
#define CefDoMessageLoopWork TestCefDoMessageLoopWork
#include "../../app/Browser/WMBrowserBridge.mm"
#include <cstdio>
#include <cstdlib>

static int shutdowns = 0;
bool TestCefInitialize(const CefMainArgs&, const CefSettings&, CefRefPtr<CefApp>, void*) {
  std::abort(); // Initialization is forbidden in this state-machine fixture.
}
void TestCefShutdown() { ++shutdowns; }
void TestCefDoMessageLoopWork() {}

#define Check(condition) do { if (!(condition)) { \
  std::fprintf(stderr, "Browser lifecycle assertion failed at line %d: %s\n", __LINE__, #condition); \
  std::exit(1); \
} } while (false)
static void DrainUntil(BOOL (^finished)()) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
  while (!finished() && deadline.timeIntervalSinceNow > 0) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  Check(finished());
}

@interface PendingPage : WMBrowserPage
@property(nonatomic) NSUInteger closeRequests;
@end
@implementation PendingPage
- (void)close { self.closing = YES; ++_closeRequests; }
@end

@interface QuitProbe : NSObject <NSApplicationDelegate>
@property(nonatomic) NSUInteger requests;
@end
@implementation QuitProbe
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  Check(![WMBrowserRuntime sharedRuntime].pumping);
  ++_requests;
  return NSTerminateCancel; // Keep the fixture process alive after inspecting quit.
}
@end

static WMBrowserRuntime *Runtime(BOOL running) {
  WMBrowserRuntime *runtime = [WMBrowserRuntime new];
  runtime.pages = [NSMutableSet new];
  runtime.running = running;
  return runtime;
}

int main() {
  @autoreleasepool {
    // Never-started CEF still fences new tabs until a failed restart recovers.
    WMBrowserRuntime *cold = Runtime(NO);
    __block BOOL prepared = NO;
    [cold prepareForTerminationWithCompletion:^(BOOL allowed) { prepared = allowed; }];
    Check(prepared && cold.stopping && !cold.shutdownRequested);
    [cold cancelPreparedTermination];
    Check(!cold.stopping);

    WMBrowserRuntime *runtime = Runtime(YES);
    __weak WMBrowserPage *retainedPage;
    @autoreleasepool {
      PendingPage *page = [PendingPage new];
      [runtime.pages addObject:page];
      retainedPage = page;
      __block int answers = 0;
      [runtime prepareForTerminationWithCompletion:^(BOOL allowed) { Check(allowed); ++answers; }];
      Check(answers == 0 && page.closeRequests == 1 && [runtime createPage] == nil);
      // An overlapping request must not overwrite the original continuation or
      // upgrade a reversible preparation into irreversible CefShutdown.
      __block BOOL duplicateRejected = NO;
      [runtime shutdownWithCompletion:^(BOOL allowed) { duplicateRejected = !allowed; }];
      Check(duplicateRejected && !runtime.shutdownRequested);
      page = nil;
      Check(retainedPage != nil && runtime.pages.count == 1);
      [runtime pageClosed:retainedPage];
      Check(answers == 0); // Completion leaves the CEF callback first.
      DrainUntil(^BOOL { return answers == 1; });
      Check(shutdowns == 0 && runtime.running && runtime.stopping);
    }
    Check(retainedPage == nil);

    // Failed backend/update preparation restores admission without reinitializing
    // CEF (CEF does not support shutdown followed by initialize in one process).
    [runtime cancelPreparedTermination];
    Check(!runtime.stopping && runtime.running);
    PendingPage *retryPage = [PendingPage new];
    [runtime.pages addObject:retryPage];
    __block BOOL cancelled = NO;
    [runtime prepareForTerminationWithCompletion:^(BOOL allowed) { cancelled = !allowed; }];
    [runtime cancelShutdown]; // The production Stay-dialog callback uses this.
    retryPage.closing = NO;
    Check(cancelled && runtime.running && !runtime.stopping && shutdowns == 0);

    // Retry, wait for OnBeforeClose, then perform final teardown exactly once.
    __block BOOL retried = NO;
    [runtime prepareForTerminationWithCompletion:^(BOOL allowed) { retried = allowed; }];
    Check(retryPage.closeRequests == 2);
    [runtime pageClosed:retryPage];
    DrainUntil(^BOOL { return retried; });
    __block int finalAnswers = 0;
    runtime.pumping = YES;
    [runtime shutdownWithCompletion:^(BOOL allowed) { Check(allowed); ++finalAnswers; }];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    Check(shutdowns == 0 && finalAnswers == 0);
    runtime.pumping = NO;
    DrainUntil(^BOOL { return finalAnswers == 1; });
    Check(shutdowns == 1 && !runtime.running && runtime.pages.count == 0);
    [runtime shutdownWithCompletion:^(BOOL allowed) { Check(allowed); ++finalAnswers; }];
    Check(shutdowns == 1 && finalAnswers == 2);

    // A Cmd-Q delivered from inside CEF must return before AppKit begins its
    // asynchronous termination barrier. Repeated requests coalesce, and a
    // cancelled quit does not leave a queued request that quits again later.
    WMBrowserApplication *application = [WMBrowserApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
    QuitProbe *probe = [QuitProbe new];
    application.delegate = probe;
    WMBrowserRuntime *shared = [WMBrowserRuntime sharedRuntime];
    shared.pumping = YES;
    [application terminate:nil];
    [application terminate:nil];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false);
    Check(probe.requests == 0 && application.terminationScheduled);
    shared.pumping = NO;
    DrainUntil(^BOOL { return probe.requests == 1; });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false);
    Check(probe.requests == 1 && !application.terminationScheduled);
    [application terminate:nil];
    Check(probe.requests == 2);
    std::puts("Browser lifecycle passed: retained owners, unload cancellation, restart recovery, duplicate requests, deferred shutdown and Cmd-Q outside the CEF pump. No Chromium or Keychain access.");
  }
}
