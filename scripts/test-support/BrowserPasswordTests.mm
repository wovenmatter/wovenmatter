// Real CEF, synthetic form/account, fake Chromium Keychain, disposable profile.
// Never link this executable into the shipping app.
#include "../../app/Browser/WMBrowserBridge.mm"
#include <cstdio>
#include <cstdlib>
#define Check(x) do { if (!(x)) { fprintf(stderr,"Password fixture failed at line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static void WaitUntil(int line, BOOL (^done)()) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
  while (!done() && deadline.timeIntervalSinceNow > 0) {
    @autoreleasepool {
    while (NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.date
      inMode:NSDefaultRunLoopMode dequeue:YES]) [NSApp sendEvent:event];
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
  }
  if (!done()) { fprintf(stderr,"Password fixture timed out at line %d\n", line); exit(1); }
}
#define Until(...) WaitUntil(__LINE__, __VA_ARGS__)
@interface PasswordFixture : NSObject <WMBrowserPageDelegate>
@property(nonatomic) NSMutableArray<NSDictionary *> *saved;
@property(nonatomic) NSString *file;
@end
@implementation PasswordFixture
- (void)browserPageDidChange:(WMBrowserPage *)page {}
- (void)browserPageDidClose:(WMBrowserPage *)page {}
- (WMBrowserPage *)browserPage:(WMBrowserPage *)page createPopup:(NSString *)url { return nil; }
- (void)browserPage:(WMBrowserPage *)page showMessage:(NSString *)message { Check(NO); }
- (NSArray<NSDictionary<NSString *,NSString *> *> *)browserPage:(WMBrowserPage *)page passwordsForOrigin:(NSString *)origin {
  Check(![origin hasSuffix:@"/"]);
  NSMutableArray *matches = [NSMutableArray new];
  for (NSDictionary *value in _saved) if ([value[@"origin"] isEqualToString:origin]) [matches addObject:value];
  return matches;
}
- (NSString *)browserPage:(WMBrowserPage *)page saveUsername:(NSString *)username password:(NSString *)password origin:(NSString *)origin {
  NSIndexSet *old = [_saved indexesOfObjectsPassingTest:^BOOL(NSDictionary *value, NSUInteger, BOOL *) {
    return [value[@"username"] isEqualToString:username] && [value[@"origin"] isEqualToString:origin];
  }];
  [_saved removeObjectsAtIndexes:old];
  [_saved insertObject:@{@"origin":origin,@"username":username,@"password":password} atIndex:0];
  Check([[NSJSONSerialization dataWithJSONObject:_saved options:0 error:nil] writeToFile:_file atomically:YES]);
  return nil;
}
@end
static void Script(WMBrowserPage *page, const char *script) {
  Check(page->browser_ != nullptr);
  page->browser_->GetMainFrame()->ExecuteJavaScript(script, page->browser_->GetMainFrame()->GetURL(), 0);
}
int main(int argc, char **argv) {
  BOOL restarted;
  WMBrowserRuntime *runtime;
  WMBrowserPage *page;
  __attribute__((objc_precise_lifetime)) PasswordFixture *delegate;
  __attribute__((objc_precise_lifetime)) NSWindow *window;
  @autoreleasepool {
    Check(argc == 4);
    NSString *root = @(argv[1]), *url = @(argv[2]);
    restarted = [@(argv[3]) isEqualToString:@"restart"];
    Check([root hasPrefix:@"/private/tmp/"] || [root hasPrefix:@"/tmp/"]);
    Check([url hasPrefix:@"http://127.0.0.1:"]);
    Check(SecKeychainSetUserInteractionAllowed(false) == errSecSuccess);
    [WMBrowserRuntime prepareApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    delegate = [PasswordFixture new];
    delegate.file = [root stringByAppendingPathComponent:@"synthetic-passwords.json"];
    NSData *data = [NSData dataWithContentsOfFile:delegate.file];
    delegate.saved = data ? [[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy] : [NSMutableArray new];
    NSString *profile = [root stringByAppendingPathComponent:@"profile"];
    Check([NSFileManager.defaultManager createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil]);
    runtime = WMBrowserRuntime.sharedRuntime;
    NSError *error = nil;
    Check([runtime startWithProfilePath:profile error:&error]);
    page = [runtime createPage]; page.delegate = delegate;
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600)
      styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.contentView = page.view;
    [page loadURL:url];
    Until(^BOOL { return page->browser_ && !page.loading && [page.title isEqualToString:@"Fixture"]; });
    if (!restarted) {
      Script(page, "setTimeout(()=>{document.querySelector('[name=username]').value='fixture-user';document.querySelector('[name=password]').value='fixture-original';document.forms[0].requestSubmit()},100)");
      Until(^BOOL { return page.passwordOfferTitle != nil; });
      Check([page.passwordOfferTitle hasPrefix:@"Save"]);
      [page acceptPasswordOffer]; Check(delegate.saved.count == 1 && page.passwordOfferTitle == nil);
      Until(^BOOL { return !page.loading && [page.title isEqualToString:@"Done"]; });
      [page loadURL:[url stringByAppendingString:@"?second"]];
      Until(^BOOL { return !page.loading && [page.title isEqualToString:@"Fixture"]; });
      Script(page, "setTimeout(()=>{document.title=document.querySelector('[name=username]').value==='fixture-user'&&document.querySelector('[name=password]').value==='fixture-original'?'AUTOFILL_OK':'AUTOFILL_FAILED'},500)");
      Until(^BOOL { return [page.title hasPrefix:@"AUTOFILL_"]; }); Check([page.title isEqualToString:@"AUTOFILL_OK"]);
      Script(page, "document.querySelector('[name=password]').value='fixture-updated';document.forms[0].requestSubmit()");
      Until(^BOOL { return page.passwordOfferTitle != nil; }); Check([page.passwordOfferTitle hasPrefix:@"Update"]);
      [page acceptPasswordOffer]; Check([delegate.saved.firstObject[@"password"] isEqualToString:@"fixture-updated"]);
    } else {
      Script(page, "setTimeout(()=>{document.title=document.querySelector('[name=password]').value==='fixture-updated'?'RESTART_OK':'RESTART_FAILED'},500)");
      Until(^BOOL { return [page.title hasPrefix:@"RESTART_"]; }); Check([page.title isEqualToString:@"RESTART_OK"]);
      [delegate browserPage:page saveUsername:@"second-user" password:@"second-synthetic-password"
        origin:PasswordOrigin(url)];
      [page fillPasswordForUsername:@"second-user"];
      Script(page, "setTimeout(()=>{document.title=document.querySelector('[name=username]').value==='second-user'&&document.querySelector('[name=password]').value==='second-synthetic-password'?'MANUAL_OK':'MANUAL_FAILED'},500)");
      Until(^BOOL { return [page.title hasPrefix:@"MANUAL_"]; }); Check([page.title isEqualToString:@"MANUAL_OK"]);
      // Changing the host/origin cannot receive the saved credential.
      [page loadURL:[url stringByReplacingOccurrencesOfString:@"127.0.0.1" withString:@"localhost"]];
      Until(^BOOL { return !page.loading && [page.title isEqualToString:@"Fixture"]; });
      Script(page, "setTimeout(()=>{document.title=document.querySelector('[name=password]').value===''?'ISOLATION_OK':'ISOLATION_FAILED'},500)");
      Until(^BOOL { return [page.title hasPrefix:@"ISOLATION_"]; }); Check([page.title isEqualToString:@"ISOLATION_OK"]);
      [page loadURL:[url stringByAppendingString:@"guards"]];
      Until(^BOOL { return !page.loading && [page.title isEqualToString:@"Guards"]; });
      Script(page, "setTimeout(()=>{document.title=Array.from(document.querySelectorAll('input[type=password]')).every(i=>!i.value)&&!document.querySelector('iframe').contentDocument.querySelector('[name=password]').value&&typeof frames[0].wovenPasswordsQuery==='undefined'?'GUARDS_OK':'GUARDS_FAILED'},500)");
      Until(^BOOL { return [page.title hasPrefix:@"GUARDS_"]; }); Check([page.title isEqualToString:@"GUARDS_OK"]);
      Script(page, "document.body.innerHTML='<form><input name=username autocomplete=username><input name=password type=password autocomplete=current-password></form>';setTimeout(()=>{document.title=document.querySelector('[name=password]').value==='second-synthetic-password'?'DYNAMIC_OK':'DYNAMIC_FAILED'},500)");
      Until(^BOOL { return [page.title hasPrefix:@"DYNAMIC_"]; }); Check([page.title isEqualToString:@"DYNAMIC_OK"]);
    }
  } // Drain all setup/form autoreleases before testing native view destruction.
  @autoreleasepool {
    __block BOOL stopped = NO;
    @autoreleasepool {
      [runtime shutdownWithCompletion:^(BOOL complete) { Check(complete); stopped=YES; }];
    }
    Until(^BOOL { return stopped; });
    puts(restarted ? "Browser password fixture: restart, manual account selection, origin/form/iframe isolation and dynamic forms passed." : "Browser password fixture: save, autofill and update passed.");
  }
}
