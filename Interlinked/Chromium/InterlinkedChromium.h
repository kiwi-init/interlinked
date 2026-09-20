#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ILChromiumView;

@protocol ILChromiumViewDelegate <NSObject>
- (void)chromiumViewDidCreateBrowser:(ILChromiumView *)view;
- (void)chromiumView:(ILChromiumView *)view didChangeURL:(nullable NSURL *)url;
- (void)chromiumView:(ILChromiumView *)view didChangeTitle:(NSString *)title;
- (void)chromiumView:(ILChromiumView *)view
      didChangeLoading:(BOOL)isLoading
             canGoBack:(BOOL)canGoBack
          canGoForward:(BOOL)canGoForward;
- (void)chromiumViewDidCommitNavigation:(ILChromiumView *)view;
- (void)chromiumViewDidFinishNavigation:(ILChromiumView *)view;
- (void)chromiumView:(ILChromiumView *)view didFailNavigation:(NSString *)message;
- (void)chromiumView:(ILChromiumView *)view requestedPopupURL:(NSURL *)url userGesture:(BOOL)userGesture;
- (void)chromiumView:(ILChromiumView *)view
    didStartDownload:(uint32_t)identifier
                 URL:(NSURL *)URL
   suggestedFilename:(NSString *)suggestedFilename;
- (void)chromiumView:(ILChromiumView *)view
   didUpdateDownload:(uint32_t)identifier
            fullPath:(NSString *)fullPath
       receivedBytes:(int64_t)receivedBytes
          totalBytes:(int64_t)totalBytes
             percent:(NSInteger)percent
            complete:(BOOL)complete
           cancelled:(BOOL)cancelled
         interrupted:(BOOL)interrupted;
- (void)chromiumView:(ILChromiumView *)view didBlockRequests:(NSInteger)count;
- (void)chromiumViewDidClose:(ILChromiumView *)view;
@end

/// NSApplication integration required by CEF on macOS. Info.plist selects this
/// class before SwiftUI creates the shared application instance.
@interface ILChromiumApplication : NSApplication
@end

@interface ILChromiumRuntime : NSObject

@property(class, nonatomic, readonly, getter=isRunning) BOOL running;
/// True while the main thread is inside Chromium's message loop work.
@property(class, nonatomic, readonly, getter=isPumpingMessages) BOOL pumpingMessages;
@property(class, nonatomic, readonly, copy) NSString *engineVersion;

/// Publishes the built-in blocker's rules. Hosts also cover their subdomains.
/// Requests from pages on |disabledSites| are never blocked.
+ (void)setBlockedHosts:(NSArray<NSString *> *)blocked
      thirdPartyHosts:(NSArray<NSString *> *)thirdParty
         allowedHosts:(NSArray<NSString *> *)allowed
        disabledSites:(NSArray<NSString *> *)disabledSites;
+ (void)disableContentBlocking;

+ (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
/// Closes every Chromium browser. The completion runs on the main thread,
/// outside Chromium's message loop, with NO if some browser failed to close.
+ (void)closeAllBrowsersWithCompletion:(void (^)(BOOL closed))completion;
/// Call only after every browser has closed.
+ (void)shutdown;

@end

@interface ILChromiumView : NSView

@property(nonatomic, weak, nullable) id<ILChromiumViewDelegate> delegate;
@property(nonatomic, readonly, nullable) NSURL *URL;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly, getter=isBrowserReady) BOOL browserReady;
/// Renders the page dark: its own dark theme if it has one, otherwise
/// Chromium's Auto Dark Mode.
@property(nonatomic) BOOL forcedDarkMode;

- (instancetype)initWithFrame:(NSRect)frame initialURL:(NSURL *)URL NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect;
- (nullable instancetype)initWithCoder:(NSCoder *)coder;

- (void)navigateToURL:(NSURL *)URL NS_SWIFT_NAME(navigate(to:));
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)focusBrowser;
- (void)closeBrowser;
- (void)evaluateJavaScript:(NSString *)script
                completion:(void (^)(id _Nullable result, NSError * _Nullable error))completion;
- (void)findText:(NSString *)text
       backwards:(BOOL)backwards
        findNext:(BOOL)findNext
       completion:(void (^)(BOOL found))completion;
- (void)stopFinding;
- (void)cancelDownload:(uint32_t)identifier;

@end

NS_ASSUME_NONNULL_END
