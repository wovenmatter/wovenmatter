// Real CEF + Playwright, hidden window, fake Keychain and loopback fixtures.
#include "../../app/Browser/WMBrowserBridge.mm"
#include <cstdio>
#include <cstdlib>
#define Check(x) do { if (!(x)) { fprintf(stderr,"Automation fixture failed at line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static void WaitUntil(int line, BOOL (^done)()) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
  while (!done() && deadline.timeIntervalSinceNow > 0) {
    @autoreleasepool {
      while (NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.date inMode:NSDefaultRunLoopMode dequeue:YES]) [NSApp sendEvent:event];
      [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
  }
  if (!done()) { fprintf(stderr,"Automation fixture timed out at line %d\n",line); exit(1); }
}
#define Until(...) WaitUntil(__LINE__, __VA_ARGS__)
static NSDictionary *Action(WMBrowserPage *page, NSString *node, NSString *script, NSDictionary *input, BOOL expectsFailure = NO) {
  fprintf(stderr,"Testing browser action: %s\n",[input[@"action"] UTF8String]);
  NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:node]; task.arguments = @[script];
  NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe]; task.standardInput = in; task.standardOutput = out;
  void (^send)(NSDictionary *) = ^(NSDictionary *packet) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:packet options:0 error:nil] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [in.fileHandleForWriting writeData:data];
  };
  page.automationMessageHandler = ^(NSString *message) { send(@{@"native":[NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]}); };
  __block NSDictionary *result;
  __block NSString *failure;
  NSMutableData *pending = [NSMutableData new];
  out.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
    NSData *data = handle.availableData;
    if (!data.length) { handle.readabilityHandler = nil; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
      [pending appendData:data];
      while (true) {
        NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0,pending.length)];
        if (newline.location == NSNotFound) break;
        NSDictionary *packet = [NSJSONSerialization JSONObjectWithData:[pending subdataWithRange:NSMakeRange(0,newline.location)] options:0 error:nil];
        [pending replaceBytesInRange:NSMakeRange(0,newline.location+1) withBytes:nullptr length:0];
        Check(packet);
        if (packet[@"cdp"]) Check([page sendAutomationMessage:[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:packet[@"cdp"] options:0 error:nil] encoding:NSUTF8StringEncoding]]);
        if (packet[@"result"]) result = packet[@"result"];
        if (packet[@"error"]) failure = packet[@"error"];
      }
    });
  };
  Check([task launchAndReturnError:nil]);
  send(@{@"target":@{@"id":@"fixture",@"title":page.title,@"url":page.url},@"version":@"154.0.8037.98",@"input":input});
  Until(^BOOL { return result || failure; });
  if (failure && !expectsFailure) fprintf(stderr,"Playwright: %s\n",failure.UTF8String);
  Check(expectsFailure ? [failure containsString:@"at most 2 MiB"] : !failure);
  [page detachAutomation]; [in.fileHandleForWriting closeFile];
  if (task.running) [task terminate];
  Until(^BOOL { return !task.running; });
  out.fileHandleForReading.readabilityHandler = nil;
  return result;
}
int main(int argc, char **argv) {
  WMBrowserRuntime *runtime;
  __attribute__((objc_precise_lifetime)) NSWindow *window;
  @autoreleasepool {
    Check(argc == 5);
    NSString *root = @(argv[1]), *url = @(argv[2]), *node = @(argv[3]), *script = @(argv[4]);
    Check([root hasPrefix:@"/private/tmp/"]); Check([url hasPrefix:@"http://127.0.0.1:"]);
    Check(SecKeychainSetUserInteractionAllowed(false) == errSecSuccess);
    [WMBrowserRuntime prepareApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    runtime = WMBrowserRuntime.sharedRuntime;
    NSString *profile = [root stringByAppendingPathComponent:@"profile"];
    Check([NSFileManager.defaultManager createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil]);
    Check([runtime startWithProfilePath:profile error:nil]);
    WMBrowserPage *page = [runtime createPage];
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.contentView = page.view; [page loadURL:url];
    Until(^BOOL { return page->browser_ && !page.loading && [page.title isEqualToString:@"Automation fixture"]; });
    NSDictionary *snapshot = Action(page,node,script,@{@"action":@"snapshot"});
    Check([snapshot[@"content"][0][@"text"] containsString:@"Name"]);
    Action(page,node,script,@{@"action":@"fill",@"selector":@"#name",@"text":@"synthetic user"});
    Action(page,node,script,@{@"action":@"click",@"selector":@"#submit"});
    NSDictionary *value = Action(page,node,script,@{@"action":@"evaluate",@"code":@"document.querySelector('#result').textContent"});
    Check([value[@"content"][0][@"text"] containsString:@"synthetic user"]);
    Action(page,node,script,@{@"action":@"fill",@"selector":@"#name",@"text":@"viewport input"});
    value = Action(page,node,script,@{@"action":@"evaluate",@"code":@"(()=>{const r=document.querySelector('#submit').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()"});
    NSDictionary *point = [NSJSONSerialization JSONObjectWithData:[value[@"content"][0][@"text"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    Action(page,node,script,@{@"action":@"hover",@"x":point[@"x"],@"y":point[@"y"]});
    Action(page,node,script,@{@"action":@"click",@"x":point[@"x"],@"y":point[@"y"]});
    value = Action(page,node,script,@{@"action":@"evaluate",@"code":@"document.querySelector('#result').textContent"});
    Check([value[@"content"][0][@"text"] containsString:@"viewport input"]);
    Action(page,node,script,@{@"action":@"upload",@"selector":@"#file",@"name":@"fixture.txt",@"data":@"aGVsbG8="});
    value = Action(page,node,script,@{@"action":@"evaluate",@"code":@"document.querySelector('#file').files[0].name"});
    Check([value[@"content"][0][@"text"] containsString:@"fixture.txt"]);
    NSMutableData *upload = [NSMutableData dataWithLength:2 * 1024 * 1024];
    Action(page,node,script,@{@"action":@"upload",@"selector":@"#file",@"name":@"large.bin",@"data":[upload base64EncodedStringWithOptions:0]});
    value = Action(page,node,script,@{@"action":@"evaluate",@"code":@"document.querySelector('#file').files[0].size"});
    Check([value[@"content"][0][@"text"] isEqualToString:@"2097152"]);
    [upload increaseLengthBy:1];
    Action(page,node,script,@{@"action":@"upload",@"selector":@"#file",@"name":@"oversized.bin",@"data":[upload base64EncodedStringWithOptions:0]},YES);
    value = Action(page,node,script,@{@"action":@"evaluate",@"code":@"document.querySelector('#file').files[0].name"});
    Check([value[@"content"][0][@"text"] containsString:@"large.bin"]);
    Action(page,node,script,@{@"action":@"fill",@"frame":@"#subframe",@"selector":@"#frame-name",@"text":@"cross-origin frame"});
    value = Action(page,node,script,@{@"action":@"evaluate",@"frame":@"#subframe",@"code":@"document.querySelector('#frame-name').value"});
    Check([value[@"content"][0][@"text"] containsString:@"cross-origin frame"]);
    value = Action(page,node,script,@{@"action":@"evaluate",@"code":@"prompt('Synthetic prompt')",@"accept":@YES,@"text":@"fixture answer"});
    Check([value[@"content"][0][@"text"] containsString:@"fixture answer"]);
    NSDictionary *image = Action(page,node,script,@{@"action":@"screenshot"});
    Check([image[@"content"][0][@"mimeType"] isEqualToString:@"image/jpeg"]);
    Check([[NSData alloc] initWithBase64EncodedString:image[@"content"][0][@"data"] options:0].length > 1000);
    NSDictionary *download = Action(page,node,script,@{@"action":@"download",@"selector":@"#download"});
    NSDictionary *receipt = [NSJSONSerialization JSONObjectWithData:[download[@"content"][0][@"text"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    Check([receipt[@"status"] isEqualToString:@"complete"]);
    Check(!receipt[@"path"]);
    NSDictionary *chunk = [page readAutomationDownload:receipt[@"id"] offset:0];
    Check([chunk[@"data"] isEqualToString:@"aGVsbG8="]);
    Action(page,node,script,@{@"action":@"navigate",@"url":[url stringByAppendingString:@"?next"]});
  } // Drain native view autoreleases before waiting for CEF shutdown.
  @autoreleasepool {
    __block BOOL stopped = NO;
    @autoreleasepool { [runtime shutdownWithCompletion:^(BOOL complete) { Check(complete); stopped=YES; }]; }
    Until(^BOOL { return stopped; });
    puts("Browser automation fixture: real CEF/Playwright snapshots, forms, uploads, downloads, screenshots, navigation, reconnect and shutdown passed.");
  }
}
