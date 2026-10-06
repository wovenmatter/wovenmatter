#import "WMBrowserBridge.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_message_router.h"
#import <Security/Security.h>
#include "include/wrapper/cef_library_loader.h"
#include <memory>
#include <map>

// SwiftUI owns the application UI; Chromium needs these two AppKit hooks.
@interface WMBrowserApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@property(nonatomic) BOOL terminationScheduled;
@end

static NSString *String(const CefString &value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}
static CefString Cef(NSString *value) { return CefString(value.UTF8String ?: ""); }
static BOOL AllowedURL(NSString *url) {
  NSString *scheme = [NSURLComponents componentsWithString:url].scheme.lowercaseString;
  return [@[@"http", @"https", @"about", @"blob", @"data"] containsObject:scheme];
}

static NSString *PasswordOrigin(NSString *address) {
  CefURLParts parts;
  if (!CefParseURL(Cef(address), parts) || parts.username.length || parts.password.length) return nil;
  NSString *scheme = String(CefString(&parts.scheme));
  NSString *host = String(CefString(&parts.host));
  if (![scheme isEqualToString:@"https"] &&
      !([scheme isEqualToString:@"http"] && [@[@"localhost", @"127.0.0.1", @"[::1]", @"::1"] containsObject:host])) return nil;
  // CEF's origin includes a trailing slash; DOM location.origin and the Swift
  // vault use the web-origin serialization without that slash.
  NSString *origin = String(CefString(&parts.origin));
  return [origin hasSuffix:@"/"] ? [origin substringToIndex:origin.length - 1] : origin;
}

class BrowserClient;
@interface WMBrowserPage () {
 @public
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<BrowserClient> client_;
}
@property(nonatomic, readwrite) NSView *view;
@property(nonatomic, readwrite) NSString *url;
@property(nonatomic, readwrite) NSString *title;
@property(nonatomic, readwrite, nullable) NSString *errorMessage;
@property(nonatomic, readwrite) BOOL loading;
@property(nonatomic, readwrite) BOOL canGoBack;
@property(nonatomic, readwrite) BOOL canGoForward;
@property(nonatomic, readwrite) BOOL closed;
@property(nonatomic, readwrite) BOOL popup;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL closing;
@property(nonatomic) NSAlert *activeDialog;
@property(nonatomic, readwrite) NSString *passwordOfferTitle;
@property(nonatomic, readwrite) NSString *passwordOfferOrigin;
@property(nonatomic) NSString *offeredUsername;
@property(nonatomic) NSString *offeredPassword;
- (void)changed;
@end
@interface WMBrowserRuntime () {
  std::unique_ptr<CefScopedLibraryLoader> loader_;
  CefRefPtr<CefApp> app_;
}
@property(nonatomic) NSMutableSet<WMBrowserPage *> *pages;
@property(nonatomic) NSTimer *pumpTimer;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL shutdownRequested;
@property(nonatomic) BOOL pumping;
@property(nonatomic, copy) void (^shutdownCompletion)(BOOL);
- (void)schedulePump:(int64_t)delay;
- (void)pageClosed:(WMBrowserPage *)page;
- (void)finishShutdownIfReady;
- (void)cancelShutdown;
@end

@implementation WMBrowserApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scopedEvent;
  [super sendEvent:event];
}
- (void)terminate:(id)sender {
  if (_terminationScheduled) return;
  // Chromium can dispatch Cmd-Q while CefDoMessageLoopWork is on the stack.
  // AppKit's deferred-quit loop would then prevent that pump from returning,
  // while browser cleanup waits for it. Leave the pump before starting quit.
  if ([WMBrowserRuntime sharedRuntime].pumping) {
    _terminationScheduled = YES;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.01 repeats:NO block:^(NSTimer *) {
      self.terminationScheduled = NO;
      [self terminate:nil];
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return;
  }
  [super terminate:sender];
}
@end

class BrowserApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnScheduleMessagePumpWork(int64_t delay) override {
    // This callback can originate on any CEF thread. A CF run-loop block also
    // runs during AppKit's nested termination loop; the main dispatch queue may
    // be held by the initiating Swift task there.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
      [[WMBrowserRuntime sharedRuntime] schedulePump:delay];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
  }
  IMPLEMENT_REFCOUNTING(BrowserApp);
};

class BrowserClient final : public CefClient,
                            public CefLifeSpanHandler,
                            public CefDisplayHandler,
                            public CefLoadHandler,
                            public CefRequestHandler,
                            public CefDownloadHandler,
                            public CefJSDialogHandler,
                            public CefMessageRouterBrowserSide::Handler {
 public:
  explicit BrowserClient(WMBrowserPage *page) : page_(page) {}
  ~BrowserClient() override { if (passwords_) passwords_->RemoveHandler(this); }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    return passwords_ && source == PID_RENDERER && passwords_->OnProcessMessageReceived(browser, frame, source, message);
  }
  bool OnQuery(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int64_t,
      const CefString &request, bool persistent, CefRefPtr<Callback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    WMBrowserPage *page = page_;
    NSString *origin = frame->IsMain() ? PasswordOrigin(String(frame->GetURL())) : nil;
    if (!page || page.closed || page.closing || !origin || persistent || request.length() > 16384) {
      callback->Failure(1, "Password access is unavailable for this frame."); return true;
    }
    auto value = CefParseJSON(request, JSON_PARSER_RFC);
    auto data = value ? value->GetDictionary() : nullptr;
    if (!data) { callback->Failure(1, "Invalid password request."); return true; }
    NSArray<NSDictionary *> *saved = [page.delegate browserPage:page passwordsForOrigin:origin];
    NSString *action = String(data->GetString("action"));
    if ([action isEqualToString:@"lookup"]) {
      auto result = CefDictionaryValue::Create();
      if (NSDictionary *credential = saved.firstObject) {
        result->SetString("origin", Cef(origin));
        result->SetString("username", Cef(credential[@"username"]));
        result->SetString("password", Cef(credential[@"password"]));
      }
      auto response = CefValue::Create(); response->SetDictionary(result);
      callback->Success(CefWriteJSON(response, JSON_WRITER_DEFAULT));
      [page changed];
      return true;
    }
    NSString *username = String(data->GetString("username"));
    NSString *password = String(data->GetString("password"));
    NSString *formOrigin = PasswordOrigin(String(data->GetString("formAction")));
    if (![action isEqualToString:@"offer"] || ![origin isEqualToString:formOrigin] ||
        username.length > 1024 || !password.length || password.length > 4096) {
      callback->Failure(1, "Invalid password form."); return true;
    }
    BOOL update = NO;
    for (NSDictionary *credential in saved) {
      if ([credential[@"username"] isEqualToString:username]) {
        if ([credential[@"password"] isEqualToString:password]) { callback->Success("{}"); return true; }
        update = YES;
      }
    }
    page.offeredUsername = username; page.offeredPassword = password;
    page.passwordOfferOrigin = origin;
    page.passwordOfferTitle = [NSString stringWithFormat:@"%@ password%@?", update ? @"Update" : @"Save",
      username.length ? [@" for " stringByAppendingString:username] : @""];
    [page changed];
    callback->Success("{}");
    return true;
  }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    CefMessageRouterConfig config;
    config.js_query_function = "wovenPasswordsQuery";
    config.js_cancel_function = "wovenPasswordsCancel";
    passwords_ = CefMessageRouterBrowserSide::Create(config);
    passwords_->AddHandler(this, false);
    WMBrowserPage *page = page_;
    if (!page) { browser->GetHost()->CloseBrowser(true); return; }
    page->browser_ = browser;
    NSView *native = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    native.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    native.frame = page.view.bounds;
    [page changed];
    if (page.closing) browser->GetHost()->CloseBrowser(false);
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    // CEF's default would close the entire Woven Matter window. Detaching the
    // browser's child view instead starts its native teardown, then CEF calls
    // OnBeforeClose. The owning page stays retained until that callback.
    NSView *native = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [native removeFromSuperview];
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    passwords_->OnBeforeClose(browser);
    CEF_REQUIRE_UI_THREAD();
    WMBrowserPage *page = page_;
    if (!page) return;
    page.closed = YES;
    page->browser_ = nullptr;
    page->client_ = nullptr;
    [page.delegate browserPageDidClose:page];
    [[WMBrowserRuntime sharedRuntime] pageClosed:page];
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int popupID,
      const CefString &url, const CefString &, WindowOpenDisposition, bool,
      const CefPopupFeatures &, CefWindowInfo &window,
      CefRefPtr<CefClient> &client, CefBrowserSettings &,
      CefRefPtr<CefDictionaryValue> &, bool *) override {
    CEF_REQUIRE_UI_THREAD();
    WMBrowserPage *page = page_;
    if (!page || page.closing || (!url.empty() && !AllowedURL(String(url)))) return true;
    WMBrowserPage *popup = [page.delegate browserPage:page createPopup:String(url)];
    if (!popup) return true;
    popup.popup = YES;
    popup.started = YES;
    std::erase_if(pendingPopups_, [](const auto &entry) {
      WMBrowserPage *pending = entry.second;
      return !pending || pending->browser_ || pending.closed;
    });
    pendingPopups_[popupID] = popup;
    window.SetAsChild((__bridge void *)popup.view, CefRect(0, 0, 800, 600));
    window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    client = popup->client_;
    return false; // Preserve window.opener, POSTs and about:blank popups.
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popupID) override {
    CEF_REQUIRE_UI_THREAD();
    auto entry = pendingPopups_.find(popupID);
    if (entry == pendingPopups_.end()) return;
    WMBrowserPage *page = entry->second;
    pendingPopups_.erase(entry);
    if (page && !page->browser_) {
      page.closed = YES; page->client_ = nullptr;
      [page.delegate browserPageDidClose:page];
      [[WMBrowserRuntime sharedRuntime] pageClosed:page];
    }
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString &, bool reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    WMBrowserPage *page = page_;
    if (!page) { callback->Continue(false, CefString()); return true; }
    NSAlert *alert = [NSAlert new];
    alert.messageText = reload ? @"Reload this page?" : @"Leave this page?";
    alert.informativeText = @"Changes you made on this website may not be saved.";
    [alert addButtonWithTitle:reload ? @"Reload" : @"Leave Page"];
    [alert addButtonWithTitle:@"Stay"];
    page.activeDialog = alert;
    NSWindow *window = page.view.window ?: NSApp.keyWindow ?: NSApp.mainWindow;
    void (^answer)(NSModalResponse) = ^(NSModalResponse response) {
      page.activeDialog = nil;
      BOOL leave = response == NSAlertFirstButtonReturn;
      if (!leave) {
        page.closing = NO;
        [[WMBrowserRuntime sharedRuntime] cancelShutdown];
      }
      callback->Continue(leave, CefString());
    };
    if (window) [alert beginSheetModalForWindow:window completionHandler:answer];
    else answer([alert runModal]);
    return true;
  }
  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    CEF_REQUIRE_UI_THREAD(); WMBrowserPage *page = page_;
    if (page.activeDialog.window.sheetParent) {
      [page.activeDialog.window.sheetParent endSheet:page.activeDialog.window returnCode:NSModalResponseCancel];
    }
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
    CEF_REQUIRE_UI_THREAD(); WMBrowserPage *page = page_;
    page.title = String(title); [page changed];
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    CEF_REQUIRE_UI_THREAD(); if (!frame->IsMain()) return;
    WMBrowserPage *page = page_; page.url = String(url); [page changed];
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    CEF_REQUIRE_UI_THREAD(); WMBrowserPage *page = page_;
    page.loading = loading; page.canGoBack = back; page.canGoForward = forward;
    if (loading) page.errorMessage = nil;
    [page changed];
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   ErrorCode code, const CefString &text, const CefString &) override {
    CEF_REQUIRE_UI_THREAD(); if (!frame->IsMain() || code == ERR_ABORTED) return;
    WMBrowserPage *page = page_; page.errorMessage = String(text); [page changed];
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       CefRefPtr<CefRequest> request, bool, bool) override {
    CEF_REQUIRE_UI_THREAD();
    passwords_->OnBeforeBrowse(browser, frame);
    if (AllowedURL(String(request->GetURL()))) return false;
    WMBrowserPage *page = page_;
    [page.delegate browserPage:page showMessage:@"This link requires an external application."];
    return true;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
      const CefString &url, WindowOpenDisposition, bool) override {
    CEF_REQUIRE_UI_THREAD(); WMBrowserPage *page = page_;
    if (AllowedURL(String(url))) {
      WMBrowserPage *tab = [page.delegate browserPage:page createPopup:String(url)];
      tab.popup = YES;
      [tab loadURL:String(url)];
    }
    return true;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus,
                                 int, const CefString &) override {
    CEF_REQUIRE_UI_THREAD(); WMBrowserPage *page = page_;
    passwords_->OnRenderProcessTerminated(browser);
    page.errorMessage = @"This page stopped responding. Reload to try again.";
    [page changed];
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
      const CefString &, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    CEF_REQUIRE_UI_THREAD(); callback->Continue(CefString(), true); return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                          CefRefPtr<CefDownloadItemCallback>) override {
    CEF_REQUIRE_UI_THREAD(); WMBrowserPage *page = page_;
    if (item->IsComplete()) {
      [page.delegate browserPage:page showMessage:[@"Downloaded " stringByAppendingString:
          [String(item->GetFullPath()) lastPathComponent]]];
    }
  }
 private:
  CefRefPtr<CefMessageRouterBrowserSide> passwords_;
  std::map<int, __weak WMBrowserPage *> pendingPopups_;
  __weak WMBrowserPage *page_; // No CEF -> ObjC -> CEF ownership cycle.
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

@implementation WMBrowserPage
- (instancetype)init {
  if ((self = [super init])) {
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _url = @"about:blank"; _title = @"New tab";
    client_ = new BrowserClient(self);
  }
  return self;
}
- (void)changed { if (!_closed) [_delegate browserPageDidChange:self]; }
- (void)loadURL:(NSString *)url {
  NSAssert(NSThread.isMainThread, @"Browser operations require the main thread");
  if (_closed || _closing || !AllowedURL(url)) return;
  _url = url; [self changed];
  if (browser_) { browser_->GetMainFrame()->LoadURL(Cef(url)); return; }
  if (_started) return;
  _started = YES;
  CefWindowInfo window;
  window.SetAsChild((__bridge void *)_view, CefRect(0, 0, _view.bounds.size.width, _view.bounds.size.height));
  window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  if (!CefBrowserHost::CreateBrowser(window, client_, Cef(url), settings, nullptr, nullptr)) {
    _closed = YES;
    client_ = nullptr;
    [_delegate browserPage:self showMessage:@"Chromium could not create a browser tab."];
    [_delegate browserPageDidClose:self];
    [[WMBrowserRuntime sharedRuntime] pageClosed:self];
  }
}
- (void)goBack { if (browser_ && !_closing) browser_->GoBack(); }
- (void)goForward { if (browser_ && !_closing) browser_->GoForward(); }
- (void)reload { if (browser_ && !_closing) browser_->Reload(); }
- (void)stop { if (browser_ && !_closing) browser_->StopLoad(); }
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next {
  if (browser_ && !_closing) browser_->GetHost()->Find(Cef(text), forward, false, next);
}
- (void)stopFinding { if (browser_ && !_closing) browser_->GetHost()->StopFinding(true); }
- (NSArray<NSString *> *)passwordUsernames {
  NSString *origin = PasswordOrigin(_url);
  if (!origin || !_delegate) return @[];
  return [[_delegate browserPage:self passwordsForOrigin:origin] valueForKey:@"username"] ?: @[];
}
- (void)fillPasswordForUsername:(NSString *)username {
  if (!browser_ || _closing) return;
  auto frame = browser_->GetMainFrame();
  NSString *origin = PasswordOrigin(String(frame->GetURL()));
  if (!origin) return;
  for (NSDictionary *credential in [_delegate browserPage:self passwordsForOrigin:origin]) {
    if (![credential[@"username"] isEqualToString:username]) continue;
    auto message = CefProcessMessage::Create("WovenPasswordFill");
    auto args = message->GetArgumentList();
    args->SetString(0, Cef(origin)); args->SetString(1, Cef(username));
    args->SetString(2, Cef(credential[@"password"]));
    frame->SendProcessMessage(PID_RENDERER, message);
    break;
  }
}
- (void)acceptPasswordOffer {
  if (!_offeredPassword || !_passwordOfferOrigin || _closing) return;
  NSString *error = [_delegate browserPage:self saveUsername:_offeredUsername
    password:_offeredPassword origin:_passwordOfferOrigin];
  if (error) { _errorMessage = error; [self changed]; return; }
  [self dismissPasswordOffer];
}
- (void)dismissPasswordOffer {
  _offeredUsername = nil; _offeredPassword = nil;
  _passwordOfferOrigin = nil; _passwordOfferTitle = nil;
  [self changed];
}
- (void)close {
  NSAssert(NSThread.isMainThread, @"Browser operations require the main thread");
  if (_closed || _closing) return;
  // Retain the owner until OnBeforeClose, including unload confirmation.
  _closing = YES;
  [self dismissPasswordOffer];
  if (browser_) { browser_->GetHost()->CloseBrowser(false); return; }
  if (!_started) {
    _closed = YES; client_ = nullptr;
    [_delegate browserPageDidClose:self];
    [[WMBrowserRuntime sharedRuntime] pageClosed:self];
  }
}
@end

@implementation WMBrowserRuntime
+ (void)prepareApplication { [WMBrowserApplication sharedApplication]; }
+ (instancetype)sharedRuntime {
  static WMBrowserRuntime *runtime;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ runtime = [WMBrowserRuntime new]; runtime.pages = [NSMutableSet new]; });
  return runtime;
}
- (BOOL)startWithProfilePath:(NSString *)path error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"CEF initialization requires the main thread");
  // Swift installs a process-wide policy before entering CEF. Refuse an
  // unguarded entry point rather than allowing an asynchronous system prompt.
  Boolean interactive = true;
  if (SecKeychainGetUserInteractionAllowed(&interactive) != errSecSuccess || interactive) {
    if (error) *error = [NSError errorWithDomain:@"WovenBrowser" code:2 userInfo:@{
      NSLocalizedDescriptionKey: @"Reconnect saved credentials in Settings > General before opening the browser."}];
    return NO;
  }
  if (_running) return YES;
  NSString *failure = nil;
  if (_stopping) failure = @"The browser is shutting down.";
  else if (![NSApp conformsToProtocol:@protocol(CefAppProtocol)])
    failure = @"The browser requires Woven Matter's native application event loop.";
  if (!failure) {
    loader_ = std::make_unique<CefScopedLibraryLoader>();
    if (!loader_->LoadInMain()) failure = @"The bundled Chromium framework could not be loaded.";
  }
  if (!failure) {
    const char *executable = NSBundle.mainBundle.executablePath.UTF8String;
#if defined(WOVEN_BROWSER_TESTING)
    // Only the standalone synthetic fixture is compiled with this definition.
    // Shipping code cannot select a mock key or a different browser profile.
    char mock[] = "--use-mock-keychain";
    char *argv[] = {const_cast<char *>(executable), mock, nullptr};
    const int argc = 2;
#else
    char *argv[] = {const_cast<char *>(executable), nullptr};
    const int argc = 1;
#endif
    CefSettings settings;
    settings.external_message_pump = true;
    settings.persist_session_cookies = true;
    settings.log_severity = LOGSEVERITY_WARNING;
    CefString(&settings.root_cache_path) = Cef(path);
    CefString(&settings.cache_path) = Cef([path stringByAppendingPathComponent:@"Default"]);
    CefString(&settings.log_file) = Cef([path stringByAppendingPathComponent:@"chromium.log"]);
    app_ = new BrowserApp;
    _running = CefInitialize(CefMainArgs(argc, argv), settings, app_, nullptr);
    if (!_running) failure = @"Chromium could not initialize its browser profile.";
    else {
      CefString preferenceError;
      auto enabled = CefValue::Create(); enabled->SetBool(true);
      auto context = CefRequestContext::GetGlobalContext();
      context->SetPreference("credentials_enable_service", enabled, preferenceError);
      context->SetPreference("profile.password_manager_enabled", enabled, preferenceError);
      [self schedulePump:0];
    }
  }
  if (failure && error) *error = [NSError errorWithDomain:@"WovenBrowser" code:1
      userInfo:@{NSLocalizedDescriptionKey:failure}];
  return !failure;
}
- (WMBrowserPage *)createPage {
  NSAssert(NSThread.isMainThread, @"Browser operations require the main thread");
  if (!_running || _stopping) return nil;
  WMBrowserPage *page = [WMBrowserPage new]; [_pages addObject:page]; return page;
}
- (void)schedulePump:(int64_t)delay {
  if (!_running) return;
  NSDate *date = [NSDate dateWithTimeIntervalSinceNow:MIN(33, MAX(0, delay)) / 1000.0];
  if (_pumpTimer && [_pumpTimer.fireDate compare:date] != NSOrderedDescending) return;
  [_pumpTimer invalidate];
  __weak WMBrowserRuntime *weakSelf = self;
  _pumpTimer = [[NSTimer alloc] initWithFireDate:date interval:0 repeats:NO block:^(NSTimer *) {
    WMBrowserRuntime *runtime = weakSelf;
    runtime.pumpTimer = nil;
    if (!runtime.running) return;
    if (runtime.pumping) { [runtime schedulePump:1]; return; }
    runtime.pumping = YES;
    CefDoMessageLoopWork();
    runtime.pumping = NO;
    // CEF's reference external pump caps idle waits at 30 Hz. Some native
    // events do not produce OnScheduleMessagePumpWork, so callbacks alone can
    // stall navigation. Earliest-deadline scheduling avoids duplicate timers.
    if (runtime.pages.count || runtime.stopping) [runtime schedulePump:33];
  }];
  [NSRunLoop.mainRunLoop addTimer:_pumpTimer forMode:NSRunLoopCommonModes];
}
- (void)pageClosed:(WMBrowserPage *)page {
  [_pages removeObject:page];
  [self finishShutdownIfReady];
}
- (void)shutdownWithCompletion:(void (^)(BOOL))completion {
  if (_shutdownCompletion) { completion(NO); return; }
  _shutdownRequested = YES;
  [self prepareForTerminationWithCompletion:completion];
}
- (void)prepareForTerminationWithCompletion:(void (^)(BOOL))completion {
  NSAssert(NSThread.isMainThread, @"Browser operations require the main thread");
  // A second request must not replace an in-flight continuation.
  if (_shutdownCompletion) { completion(NO); return; }
  _stopping = YES;
  if (!_running) { completion(YES); return; }
  _shutdownCompletion = [completion copy];
  for (WMBrowserPage *page in _pages.allObjects) {
    [page close];
  }
  [self finishShutdownIfReady];
}
- (void)cancelPreparedTermination {
  if (!_shutdownRequested) [self cancelShutdown];
}
- (void)cancelShutdown {
  if (!_stopping) return;
  _stopping = NO;
  _shutdownRequested = NO;
  void (^completion)(BOOL) = _shutdownCompletion;
  _shutdownCompletion = nil;
  if (completion) completion(NO);
}
- (void)finishShutdownIfReady {
  if (!_stopping || _pages.count || !_running) return;
  // Never call CefShutdown inside a CEF callback or CefDoMessageLoopWork.
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
    if (!self.stopping || !self.running || self.pages.count) return;
    if (self.pumping) {
      [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:NO block:^(NSTimer *) {
        [self finishShutdownIfReady];
      }];
      return;
    }
    if (self.shutdownRequested) {
      [self.pumpTimer invalidate]; self.pumpTimer = nil;
      self.running = NO;
      CefShutdown();
      self->app_ = nullptr;
      self->loader_.reset();
    }
    void (^completion)(BOOL) = self.shutdownCompletion;
    self.shutdownCompletion = nil;
    if (completion) completion(YES);
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
@end
