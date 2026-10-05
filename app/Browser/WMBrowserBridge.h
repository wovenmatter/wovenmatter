#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@class WMBrowserPage;

@protocol WMBrowserPageDelegate <NSObject>
- (void)browserPageDidChange:(WMBrowserPage *)page;
- (void)browserPageDidClose:(WMBrowserPage *)page;
// Called synchronously on the main thread. Returning nil blocks at capacity.
- (nullable WMBrowserPage *)browserPage:(WMBrowserPage *)page createPopup:(NSString *)url;
- (void)browserPage:(WMBrowserPage *)page showMessage:(NSString *)message;
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
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next;
- (void)stopFinding;
- (void)close;
@end

@interface WMBrowserRuntime : NSObject
+ (void)prepareApplication;
+ (instancetype)sharedRuntime;
@property(nonatomic, readonly) NSUInteger livePageCount;
- (BOOL)startWithProfilePath:(NSString *)profilePath error:(NSError **)error;
- (nullable WMBrowserPage *)createPage;
// Close and release all browsers before shutdown. Completion runs outside CEF.
- (void)shutdownWithCompletion:(void (^)(BOOL completed))completion;
@end
NS_ASSUME_NONNULL_END
