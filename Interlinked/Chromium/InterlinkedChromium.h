#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ILChromiumView;

typedef NS_ENUM(NSInteger, ILNavigationKind) {
    ILNavigationKindLink,
    ILNavigationKindForm,
    ILNavigationKindRedirect,
    ILNavigationKindReload,
    ILNavigationKindHistory,
    ILNavigationKindOther,
};

typedef NS_ENUM(NSInteger, ILWebsitePermissionKind) {
    ILWebsitePermissionKindCamera,
    ILWebsitePermissionKindMicrophone,
    ILWebsitePermissionKindCameraAndMicrophone,
    ILWebsitePermissionKindLocation,
};

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
- (BOOL)chromiumView:(ILChromiumView *)view
    decideNavigationToURL:(NSURL *)URL
                sourceURL:(nullable NSURL *)sourceURL
                     kind:(ILNavigationKind)kind
               completion:(void (^)(BOOL allow))completion;
- (void)chromiumView:(ILChromiumView *)view
    decidePermissionForOrigin:(NSString *)origin
                         kind:(ILWebsitePermissionKind)kind
                   completion:(void (^)(BOOL allow))completion;
- (void)chromiumView:(ILChromiumView *)view
    decideDownloadFromURL:(nullable NSURL *)sourceURL
                    toURL:(NSURL *)URL
               completion:(void (^)(BOOL allow))completion;
- (void)chromiumView:(ILChromiumView *)view
    didRejectCertificateAtURL:(NSURL *)URL
                        error:(NSString *)error;
- (void)chromiumViewWebContentProcessDidTerminate:(ILChromiumView *)view;
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

/// Builds the content blocker from filter lists in uBlock Origin syntax and
/// starts using it. Lists at |trustedLists| may use response-rewriting
/// scriptlets. Slow; call off the main thread. Returns the engine serialized
/// for -restoreBlockerFromData:, or nil.
+ (nullable NSData *)buildBlockerWithLists:(NSArray<NSString *> *)lists
                              trustedLists:(NSIndexSet *)trustedLists
                             resourcesJSON:(NSString *)resourcesJSON;
+ (BOOL)restoreBlockerFromData:(NSData *)data resourcesJSON:(NSString *)resourcesJSON;
/// |disabledSites| are hosts without a leading "www." whose pages load unfiltered.
+ (void)setContentBlockingEnabled:(BOOL)enabled disabledSites:(NSArray<NSString *> *)disabledSites;

+ (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
/// Closes every Chromium browser. The completion runs on the main thread,
/// outside Chromium's message loop, with NO if some browser failed to close.
+ (void)closeAllBrowsersWithCompletion:(void (^)(BOOL closed))completion;
/// Call only after every browser has closed.
+ (void)shutdown;

@end

@interface ILChromiumView : NSView

/// Interlinked's controls float over the page. While this returns YES the
/// page may not change the cursor; its latest cursor is kept for later.
+ (void)setChromeOwnsCursor:(nullable BOOL (^)(void))owns;
/// Shows the page's latest cursor again once the mouse leaves the controls.
+ (void)restorePageCursor;

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

/// A script that runs at the start of every document in this view, before
/// the page paints, and immediately in the current one. Setting nil removes
/// it; |stopScript| then runs in the current document to undo its effects.
- (void)setDocumentStartScript:(nullable NSString *)source stopScript:(nullable NSString *)stopScript;
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
