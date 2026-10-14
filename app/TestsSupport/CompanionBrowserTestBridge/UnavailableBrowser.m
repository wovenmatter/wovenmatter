// Provider-free facade tests never start Chromium or touch a browser profile.
// Compile against the production Objective-C interface so drift is a build error.
#import "../../Browser/WMBrowserBridge.h"
@implementation WMBrowserRuntime
+ (void)prepareApplication {}
+ (instancetype)sharedRuntime { static WMBrowserRuntime *runtime; static dispatch_once_t once;
  dispatch_once(&once, ^{ runtime = [WMBrowserRuntime new]; }); return runtime; }
- (BOOL)startWithProfilePath:(NSString *)path error:(NSError **)error {
  if (error) *error = [NSError errorWithDomain:@"CompanionFacadeTests" code:1
    userInfo:@{NSLocalizedDescriptionKey: @"Browser unavailable in companion facade tests."}];
  return NO;
}
- (WMBrowserPage *)createPage { return nil; }
- (void)prepareForTerminationWithCompletion:(void (^)(BOOL))completion { completion(YES); }
- (void)cancelPreparedTermination {}
- (void)shutdownWithCompletion:(void (^)(BOOL))completion { completion(YES); }
@end
@implementation WMBrowserPage
- (NSView *)view { return [NSView new]; }
- (NSString *)url { return @"about:blank"; }
- (NSString *)title { return @""; }
- (NSString *)errorMessage { return @"Browser unavailable in companion facade tests."; }
- (BOOL)loading { return NO; }
- (BOOL)canGoBack { return NO; }
- (BOOL)canGoForward { return NO; }
- (BOOL)closed { return YES; }
- (BOOL)popup { return NO; }
- (void)loadURL:(NSString *)url { [NSException raise:NSInternalInconsistencyException format:@"Browser use in companion facade tests"]; }
- (void)goBack {}
- (void)goForward {}
- (void)reload {}
- (void)stop {}
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next {}
- (void)stopFinding {}
- (NSString *)passwordOfferTitle { return nil; }
- (NSString *)passwordOfferOrigin { return nil; }
- (NSArray<NSString *> *)passwordUsernames { return @[]; }
- (void)acceptPasswordOffer {}
- (void)dismissPasswordOffer {}
- (void)fillPasswordForUsername:(NSString *)username {}
- (void)close {}
@end
