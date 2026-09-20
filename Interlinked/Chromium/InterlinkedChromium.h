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
- (void)chromiumViewDidClose:(ILChromiumView *)view;
@end

/// NSApplication integration required by CEF on macOS. Info.plist selects this
/// class before SwiftUI creates the shared application instance.
@interface ILChromiumApplication : NSApplication
@end

@interface ILChromiumRuntime : NSObject

@property(class, nonatomic, readonly, getter=isRunning) BOOL running;
@property(class, nonatomic, readonly, copy) NSString *engineVersion;
@property(class, nonatomic, readonly) BOOL supportsManifestV3Extensions;

/// Absolute paths to valid enabled unpacked extensions in the startup catalog.
/// Chromium reads this same list before its browser process is initialized.
+ (NSArray<NSString *> *)startupExtensionPaths;
+ (void)prepareManifestV3ExtensionPaths:(NSArray<NSString *> *)paths;

+ (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
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
