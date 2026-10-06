#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@class WMBrowserPage;

@protocol WMBrowserPageDelegate <NSObject>
- (void)browserPageDidChange:(WMBrowserPage *)page;
- (void)browserPageDidClose:(WMBrowserPage *)page;
// Called synchronously on the main thread. Returning nil blocks at capacity.
- (nullable WMBrowserPage *)browserPage:(WMBrowserPage *)page createPopup:(NSString *)url;
- (void)browserPage:(WMBrowserPage *)page showMessage:(NSString *)message;
// Native password UI/store remain outside website and agent interfaces.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)browserPage:(WMBrowserPage *)page passwordsForOrigin:(NSString *)origin;
- (nullable NSString *)browserPage:(WMBrowserPage *)page saveUsername:(NSString *)username password:(NSString *)password origin:(NSString *)origin;
@end

@interface WMBrowserPage : NSObject
@property(nonatomic, weak, nullable) id<WMBrowserPageDelegate> delegate;
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly) NSString *url;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly, nullable) NSString *errorMessage;
@property(nonatomic, readonly) BOOL loading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly) BOOL popup;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next;
- (void)stopFinding;
@property(nonatomic, readonly, nullable) NSString *passwordOfferTitle;
@property(nonatomic, readonly, nullable) NSString *passwordOfferOrigin;
@property(nonatomic, readonly) NSArray<NSString *> *passwordUsernames;
- (void)acceptPasswordOffer;
- (void)dismissPasswordOffer;
- (void)fillPasswordForUsername:(NSString *)username;
- (void)close;
@end

@interface WMBrowserRuntime : NSObject
+ (void)prepareApplication;
+ (instancetype)sharedRuntime;
- (BOOL)startWithProfilePath:(NSString *)profilePath error:(NSError **)error;
- (nullable WMBrowserPage *)createPage;
// Resolve unload prompts before committing an update/restart. Keep CEF alive
// and block new tabs until shutdown, or cancel the preparation after a failure.
- (void)prepareForTerminationWithCompletion:(void (^)(BOOL completed))completion;
- (void)cancelPreparedTermination;
// Close and release all browsers before shutdown. Completion runs outside CEF.
- (void)shutdownWithCompletion:(void (^)(BOOL completed))completion;
@end
NS_ASSUME_NONNULL_END
