#import "InterlinkedChromium.h"
#import <objc/runtime.h>

#include "interlinked_blocker.h"

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_task.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_stream_resource_handler.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

NSString *NSStringFromCef(const CefString& value) {
  const std::string utf8 = value.ToString();
  return [[NSString alloc] initWithBytes:utf8.data()
                                  length:utf8.size()
                                encoding:NSUTF8StringEncoding] ?: @"";
}

CefString CefFromNSString(NSString *value) {
  return CefString(value.UTF8String ?: "");
}

std::string RequestSignature(CefRefPtr<CefRequest> request) {
  return request->GetMethod().ToString() + "\n" + request->GetURL().ToString();
}

ILNavigationKind NavigationKind(CefRefPtr<CefRequest> request, bool is_redirect) {
  if (is_redirect) {
    return ILNavigationKindRedirect;
  }
  const int transition = static_cast<int>(request->GetTransitionType());
  if ((transition & TT_FORWARD_BACK_FLAG) != 0) {
    return ILNavigationKindHistory;
  }
  switch (transition & TT_SOURCE_MASK) {
    case TT_LINK: return ILNavigationKindLink;
    case TT_FORM_SUBMIT: return ILNavigationKindForm;
    case TT_RELOAD: return ILNavigationKindReload;
    default: return ILNavigationKindOther;
  }
}

// Main-queue blocks never run while the main queue is already inside a block,
// for example a modal or terminate-later run loop started from a Task or a
// DispatchQueue.main.sync call. Run loop blocks still do, so Chromium keeps
// pumping there.
void PerformOnMainRunLoop(void (^block)(void)) {
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
    // Unlike libdispatch, the run loop gives blocks no autorelease pool, and
    // a closed browser is only destroyed once its host view is released.
    @autoreleasepool {
      block();
    }
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

NSTimer *g_message_pump_timer;
bool g_message_pump_active = false;
bool g_message_pump_reentrant = false;
bool g_immediate_pump_scheduled = false;

// Built-in content blocking. The engine is immutable once built, so the
// network thread only takes the lock long enough to copy the pointer.
struct BlockerEngine {
  explicit BlockerEngine(ILBlocker *blocker) : blocker(blocker) {}
  ~BlockerEngine() { il_blocker_free(blocker); }
  BlockerEngine(const BlockerEngine&) = delete;
  BlockerEngine& operator=(const BlockerEngine&) = delete;
  ILBlocker *const blocker;
};
std::mutex g_blocking_mutex;
std::shared_ptr<const BlockerEngine> g_blocker_engine;
std::shared_ptr<const std::unordered_set<std::string>> g_blocking_disabled_sites;
std::atomic_bool g_blocking_enabled(false);

std::string HostOfURL(const CefString& url) {
  CefURLParts parts;
  if (url.empty() || !CefParseURL(url, parts)) {
    return std::string();
  }
  std::string host = CefString(&parts.host).ToString();
  for (char& c : host) {
    c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
  }
  return host;
}

// The engine to use for a page on |page_host|, or null when blocking is off
// globally or for that site. Sites are stored without a leading "www.".
std::shared_ptr<const BlockerEngine> BlockerForPage(const std::string& page_host) {
  if (!g_blocking_enabled.load()) {
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(g_blocking_mutex);
  if (g_blocking_disabled_sites && !page_host.empty()) {
    const std::string site = page_host.rfind("www.", 0) == 0 ? page_host.substr(4) : page_host;
    if (g_blocking_disabled_sites->count(site)) {
      return nullptr;
    }
  }
  return g_blocker_engine;
}

const char *BlockerRequestType(cef_resource_type_t type) {
  switch (type) {
    case RT_MAIN_FRAME: return "document";
    case RT_SUB_FRAME: return "subdocument";
    case RT_STYLESHEET: return "stylesheet";
    case RT_SCRIPT: return "script";
    case RT_IMAGE: case RT_FAVICON: return "image";
    case RT_FONT_RESOURCE: return "font";
    case RT_MEDIA: return "media";
    case RT_OBJECT: case RT_PLUGIN_RESOURCE: return "object";
    case RT_XHR: return "xmlhttprequest";
    case RT_PING: return "ping";
    case RT_CSP_REPORT: return "csp_report";
    default: return "other";
  }
}

bool IsDocumentRequest(CefRefPtr<CefRequest> request) {
  const cef_resource_type_t type = request->GetResourceType();
  return type == RT_MAIN_FRAME || type == RT_SUB_FRAME;
}

std::string TakeBlockerString(char *value) {
  std::string result = value ? value : "";
  il_string_free(value);
  return result;
}

// Browser bookkeeping, touched only on the main (CEF UI) thread.
std::vector<CefRefPtr<CefBrowser>> g_browsers;
int g_pending_browser_creations = 0;
bool g_closing_all_browsers = false;
bool g_close_all_finished = false;
void (^g_close_all_completion)(BOOL);
// Chromium on macOS asks the app to terminate as soon as its last browser
// closes. Blank tabs own no browser, so this hidden page keeps Chromium alive
// until Interlinked itself decides to quit.
ILChromiumView *g_keep_alive_view;
// See +setChromeOwnsCursor:.
BOOL (^g_chrome_owns_cursor)(void);
NSCursor *g_last_page_cursor;
// SwiftUI can mount a restored page before the app delegate has started
// Chromium. Those views are remembered here and asked again once the runtime
// is up; without the retry a restored tab stays blank until AppKit happens to
// re-attach its view.
NSHashTable<ILChromiumView *> *g_views_awaiting_runtime;

void FinishClosingAllBrowsers(BOOL closed) {
  if (!g_close_all_completion) {
    return;
  }
  if (g_message_pump_active) {
    // Never tear Chromium down from inside its own message loop work.
    PerformOnMainRunLoop(^{
      FinishClosingAllBrowsers(closed);
    });
    return;
  }
  void (^completion)(BOOL) = g_close_all_completion;
  g_close_all_completion = nil;
  g_close_all_finished = true;
  completion(closed);
}

void FinishClosingAllBrowsersIfDone() {
  if (g_closing_all_browsers && g_browsers.empty() && g_pending_browser_creations == 0) {
    PerformOnMainRunLoop(^{
      FinishClosingAllBrowsers(YES);
    });
  }
}

void ScheduleMessagePump(int64_t delay_ms);

void CancelMessagePumpTimer() {
  [g_message_pump_timer invalidate];
  g_message_pump_timer = nil;
}

void PerformMessagePumpWork() {
  g_immediate_pump_scheduled = false;
  if (!ILChromiumRuntime.running) {
    return;
  }
  if (g_message_pump_active) {
    g_message_pump_reentrant = true;
    return;
  }

  g_message_pump_reentrant = false;
  g_message_pump_active = true;
  CefDoMessageLoopWork();
  g_message_pump_active = false;

  if (g_message_pump_reentrant) {
    ScheduleMessagePump(0);
  } else if (!g_message_pump_timer) {
    // Keep Chromium responsive even when it has no immediate work. This is
    // the same 30 fps upper bound used by CEF's external-pump sample.
    ScheduleMessagePump(1000 / 30);
  }
}

void ScheduleMessagePumpOnMain(int64_t delay_ms) {
  if (!ILChromiumRuntime.running) {
    return;
  }

  const int64_t bounded_delay = std::max<int64_t>(0, std::min<int64_t>(delay_ms, 1000 / 30));
  if (bounded_delay == 0) {
    CancelMessagePumpTimer();
    if (!g_immediate_pump_scheduled) {
      g_immediate_pump_scheduled = true;
      PerformOnMainRunLoop(^{
        PerformMessagePumpWork();
      });
    }
    return;
  }

  NSDate *requested_date = [NSDate dateWithTimeIntervalSinceNow:
      static_cast<NSTimeInterval>(bounded_delay) / 1000.0];
  if (g_message_pump_timer &&
      [g_message_pump_timer.fireDate compare:requested_date] != NSOrderedDescending) {
    return;
  }

  CancelMessagePumpTimer();
  g_message_pump_timer = [[NSTimer alloc] initWithFireDate:requested_date
                                                  interval:0
                                                   repeats:NO
                                                     block:^(NSTimer *) {
    g_message_pump_timer = nil;
    PerformMessagePumpWork();
  }];
  NSRunLoop *run_loop = NSRunLoop.mainRunLoop;
  [run_loop addTimer:g_message_pump_timer forMode:NSRunLoopCommonModes];
  [run_loop addTimer:g_message_pump_timer forMode:NSEventTrackingRunLoopMode];
}

void ScheduleMessagePump(int64_t delay_ms) {
  // CEF may make this callback from any thread.
  if (NSThread.isMainThread) {
    ScheduleMessagePumpOnMain(delay_ms);
  } else {
    PerformOnMainRunLoop(^{
      ScheduleMessagePumpOnMain(delay_ms);
    });
  }
}

// CefBrowserHost::SetFocus waits on Chromium worker threads that run at
// Default QoS. The app main thread is User-interactive, so calling it from a
// GCD/Swift block (outside CefDoMessageLoopWork) is a priority inversion.
class SetBrowserFocusTask final : public CefTask {
 public:
  SetBrowserFocusTask(CefRefPtr<CefBrowser> browser, bool focus)
      : browser_(std::move(browser)), focus_(focus) {}

  void Execute() override {
    if (browser_) {
      browser_->GetHost()->SetFocus(focus_);
    }
  }

 private:
  CefRefPtr<CefBrowser> browser_;
  const bool focus_;
  IMPLEMENT_REFCOUNTING(SetBrowserFocusTask);
};

void PostBrowserFocus(CefRefPtr<CefBrowser> browser, bool focus) {
  if (!browser) {
    return;
  }
  CefPostTask(TID_UI, new SetBrowserFocusTask(std::move(browser), focus));
}

NSView *FirstResponderCandidate(NSView *view) {
  if (!view || view.hidden) {
    return nil;
  }
  if (view.acceptsFirstResponder) {
    return view;
  }
  for (NSView *child in view.subviews) {
    if (NSView *found = FirstResponderCandidate(child)) {
      return found;
    }
  }
  return nil;
}

class InterlinkedBrowserApp final : public CefApp,
                                    public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty()) {
#ifdef DEBUG
      // Development builds use an isolated password store so a local build
      // cannot alter the user's installed-browser profile.
      command_line->AppendSwitch("use-mock-keychain");
#endif
      command_line->AppendSwitch("disable-component-update");
      // Interlinked ships its own page features instead of Chrome extensions.
      command_line->AppendSwitch("disable-extensions");
    }
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    ScheduleMessagePump(delay_ms);
  }

 private:
  IMPLEMENT_REFCOUNTING(InterlinkedBrowserApp);
};

class InterlinkedClient final : public CefClient,
                                public CefDevToolsMessageObserver,
                                public CefDisplayHandler,
                                public CefDownloadHandler,
                                public CefFindHandler,
                                public CefLifeSpanHandler,
                                public CefLoadHandler,
                                public CefPermissionHandler,
                                public CefRequestHandler,
                                public CefResourceRequestHandler {
 public:
  explicit InterlinkedClient(ILChromiumView *view) : view_(view), parent_view_(view) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    return this;
  }
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override;
  void OnResourceRedirect(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefRequest> request,
                          CefRefPtr<CefResponse> response,
                          CefString& new_url) override;
  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser,
                                                   CefRefPtr<CefFrame> frame,
                                                   CefRefPtr<CefRequest> request) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t cert_error,
                          const CefString& request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override;
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                       const CefString& method,
                       const void* params,
                       size_t params_size) override;

  void Detach() { view_ = nil; }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  bool OnCursorChange(CefRefPtr<CefBrowser> browser,
                      CefCursorHandle cursor,
                      cef_cursor_type_t type,
                      const CefCursorInfo& custom_cursor_info) override;
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool is_loading,
                            bool can_go_back,
                            bool can_go_forward) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int http_status_code) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode error_code,
                   const CefString& error_text,
                   const CefString& failed_url) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popup_features,
                     CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override;
  void OnFindResult(CefRefPtr<CefBrowser> browser,
                    int identifier,
                    int count,
                    const CefRect& selection_rect,
                    int active_match_ordinal,
                    bool final_update) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;
  void CancelDownload(uint32_t identifier) {
    auto found = downloads_.find(identifier);
    if (found != downloads_.end()) found->second->Cancel();
  }

  void ObserveDevTools(CefRefPtr<CefBrowser> browser) {
    devtools_registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
  }

 private:
  __weak ILChromiumView *view_;
  // Chromium creates and closes browsers asynchronously and keeps a raw
  // pointer to the parent view, so the view must outlive the browser even
  // after the tab that owned it is gone. Released in OnBeforeClose.
  ILChromiumView *parent_view_;
  CefRefPtr<CefRegistration> devtools_registration_;
  std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> downloads_;
  std::atomic<int> unreported_blocks_{0};
  // Stand-in responses chosen in OnBeforeResourceLoad, keyed by request id.
  std::mutex replacements_mutex_;
  std::map<uint64_t, std::string> replacements_;
  uint64_t navigation_review_generation_ = 0;
  std::string approved_navigation_;
  // The host whose blocking rules are registered, and how many redirects in a
  // row were restarted to register another host's rules first.
  std::string blocking_host_;
  int redirect_restarts_ = 0;
  // A restarted redirect whose rules are registered already.
  std::string restarted_navigation_;
  bool certificate_error_reported_ = false;
  void CountBlockedRequest();
  void PrepareBlocking(ILChromiumView *view, CefRefPtr<CefRequest> request);
  bool RestartRedirect(uint64_t generation,
                       CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       CefRefPtr<CefRequest> request);
  void ContinueNavigation(uint64_t generation,
                          CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefRequest> request);
  IMPLEMENT_REFCOUNTING(InterlinkedClient);
};

// Runs in an isolated world at document start; blocker-cosmetics.js explains
// the |cfg| the caller defines first.
NSString *ILCosmeticsScript() {
  static NSString *source = [NSString
      stringWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"blocker-cosmetics" withExtension:@"js"]
                     encoding:NSUTF8StringEncoding
                        error:nil] ?: @"";
  return source;
}

std::unique_ptr<CefScopedLibraryLoader> g_library_loader;
CefRefPtr<InterlinkedBrowserApp> g_browser_app;
std::atomic_bool g_running(false);

}  // namespace

@interface ILChromiumView () {
 @private
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<InterlinkedClient> _client;
  NSURL *_pendingURL;
  NSURL *_URL;
  NSString *_pageTitle;
  BOOL _loading;
  BOOL _canGoBack;
  BOOL _canGoForward;
  BOOL _closing;
  BOOL _forcedDarkMode;
  // The document-start script and the identifier Chromium assigned to it.
  NSString *_documentStartSource;
  NSString *_documentStartIdentifier;
  int _documentStartRequest;
  NSMutableSet<NSNumber *> *_documentStartPending;
  // Content blocking scripts registered for the next document, and the
  // navigation they were registered for.
  NSMutableArray<NSString *> *_blockingScriptIdentifiers;
  NSMutableDictionary<NSNumber *, NSNumber *> *_blockingScriptRequests;
  NSInteger _blockingGeneration;
  void (^_blockingRegistered)(void);
  NSString *_blockingExceptionsJSON;
  BOOL _blockingBindingInstalled;
  NSMutableDictionary<NSNumber *, void (^)(id _Nullable, NSError * _Nullable)> *_evaluations;
  void (^_findCompletion)(BOOL);
}
- (void)createBrowserIfPossible;
- (void)didCreateBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)didChangeURLString:(NSString *)URLString;
- (void)didChangePageTitle:(NSString *)title;
- (void)didChangeLoading:(BOOL)isLoading
               canGoBack:(BOOL)canGoBack
            canGoForward:(BOOL)canGoForward;
- (void)didCommitNavigation;
- (void)didFinishNavigation;
- (void)didFailNavigation:(NSString *)message;
- (void)didRequestPopupURLString:(NSString *)URLString userGesture:(BOOL)userGesture;
- (void)didStartDownload:(uint32_t)identifier URLString:(NSString *)URLString suggestedFilename:(NSString *)filename;
- (void)didUpdateDownload:(uint32_t)identifier fullPath:(NSString *)fullPath receivedBytes:(int64_t)receivedBytes totalBytes:(int64_t)totalBytes percent:(NSInteger)percent complete:(BOOL)complete cancelled:(BOOL)cancelled interrupted:(BOOL)interrupted;
- (void)didCloseBrowser;
- (void)didBlockRequests:(NSInteger)count;
- (void)prepareBlockingForURLString:(NSString *)URLString runImmediately:(BOOL)runImmediately;
- (void)whenBlockingRegistered:(void (^)(void))block;
- (void)didReceiveBindingCall:(NSData *)parameters;
- (void)removeBlockingScript:(NSString *)identifier;
- (void)applyForcedDarkMode;
- (void)applyDocumentStartScript;
- (void)failPendingRequests;
- (void)didReceiveEvaluation:(int)identifier
                     success:(BOOL)success
                        bytes:(const void *)bytes
                       length:(size_t)length;
- (void)didReceiveFindCount:(int)count finalUpdate:(BOOL)finalUpdate;
@end

@implementation ILChromiumApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEvent;
  [super sendEvent:event];
}

@end

/// SwiftUI creates a private NSApplication subclass and ignores
/// NSPrincipalClass. Add CEF's tiny event contract to NSApplication itself so
/// the SwiftUI subclass inherits it without replacing the app or its scenes.
@interface NSApplication (InterlinkedCEF) <CefAppProtocol>
@end

@implementation NSApplication (InterlinkedCEF)

+ (void)load {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Method original = class_getInstanceMethod(self, @selector(sendEvent:));
    Method replacement = class_getInstanceMethod(self, @selector(il_sendEvent:));
    method_exchangeImplementations(original, replacement);
    method_exchangeImplementations(class_getInstanceMethod(self, @selector(terminate:)),
                                   class_getInstanceMethod(self, @selector(il_terminate:)));
  });
}

- (void)il_terminate:(id)sender {
  if (g_closing_all_browsers && !g_close_all_finished) {
    // Chromium requests termination when its last browser closes. Interlinked
    // is already quitting and terminates once Chromium has shut down.
    return;
  }
  [self il_terminate:sender];
}

- (BOOL)isHandlingSendEvent {
  return [objc_getAssociatedObject(self, @selector(isHandlingSendEvent)) boolValue];
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  objc_setAssociatedObject(self, @selector(isHandlingSendEvent), @(handlingSendEvent),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)il_sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEvent;
  [self il_sendEvent:event];
}

@end

@implementation ILChromiumRuntime

+ (BOOL)isRunning {
  return g_running.load();
}

+ (BOOL)isPumpingMessages {
  return g_message_pump_active;
}

+ (NSString *)engineVersion {
  return [NSString stringWithFormat:@"Chromium %d.%d.%d.%d / CEF %d.%d.%d",
                                    CHROME_VERSION_MAJOR,
                                    CHROME_VERSION_MINOR,
                                    CHROME_VERSION_BUILD,
                                    CHROME_VERSION_PATCH,
                                    CEF_VERSION_MAJOR,
                                    CEF_VERSION_MINOR,
                                    CEF_VERSION_PATCH];
}

+ (nullable NSData *)buildBlockerWithLists:(NSArray<NSString *> *)lists
                              trustedLists:(NSIndexSet *)trustedLists
                             resourcesJSON:(NSString *)resourcesJSON {
  ILFilters *filters = il_filters_new();
  [lists enumerateObjectsUsingBlock:^(NSString *list, NSUInteger index, BOOL *stop) {
    il_filters_add(filters, list.UTF8String ?: "", [trustedLists containsIndex:index]);
  }];
  ILBlocker *blocker = il_blocker_new(filters, resourcesJSON.UTF8String ?: "[]");
  if (!blocker) {
    return nil;
  }
  size_t length = 0;
  uint8_t *bytes = il_blocker_serialize(blocker, &length);
  NSData *serialized = [NSData dataWithBytes:bytes length:length];
  il_bytes_free(bytes, length);
  auto engine = std::make_shared<const BlockerEngine>(blocker);
  std::lock_guard<std::mutex> lock(g_blocking_mutex);
  g_blocker_engine = std::move(engine);
  return serialized;
}

+ (BOOL)restoreBlockerFromData:(NSData *)data resourcesJSON:(NSString *)resourcesJSON {
  ILBlocker *blocker = il_blocker_restore(static_cast<const uint8_t *>(data.bytes), data.length,
                                          resourcesJSON.UTF8String ?: "[]");
  if (!blocker) {
    return NO;
  }
  auto engine = std::make_shared<const BlockerEngine>(blocker);
  std::lock_guard<std::mutex> lock(g_blocking_mutex);
  g_blocker_engine = std::move(engine);
  return YES;
}

+ (void)setContentBlockingEnabled:(BOOL)enabled disabledSites:(NSArray<NSString *> *)disabledSites {
  auto sites = std::make_shared<std::unordered_set<std::string>>();
  for (NSString *site in disabledSites) {
    sites->emplace(site.lowercaseString.UTF8String ?: "");
  }
  {
    std::lock_guard<std::mutex> lock(g_blocking_mutex);
    g_blocking_disabled_sites = std::move(sites);
  }
  g_blocking_enabled.store(enabled);
}

+ (BOOL)startWithError:(NSError **)error {
  if (g_running.load()) {
    return YES;
  }

  if (![NSApp conformsToProtocol:@protocol(CefAppProtocol)]) {
    if (error) {
      *error = [NSError errorWithDomain:@"computer.interlinked.chromium"
                                    code:1
                                userInfo:@{NSLocalizedDescriptionKey:
                                             @"The SwiftUI application could not install CEF event handling."}];
    }
    return NO;
  }

  g_library_loader = std::make_unique<CefScopedLibraryLoader>();
  if (!g_library_loader->LoadInMain()) {
    if (error) {
      *error = [NSError errorWithDomain:@"computer.interlinked.chromium"
                                    code:2
                                userInfo:@{NSLocalizedDescriptionKey:
                                             @"Chromium Embedded Framework could not be loaded from the app bundle."}];
    }
    g_library_loader.reset();
    return NO;
  }

  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  std::vector<std::string> argument_storage;
  std::vector<char *> argument_values;
  argument_storage.reserve(arguments.count);
  argument_values.reserve(arguments.count);
  for (NSString *argument in arguments) {
    argument_storage.emplace_back(argument.UTF8String ?: "");
  }
  for (std::string& argument : argument_storage) {
    argument_values.push_back(argument.data());
  }

  CefMainArgs main_args(static_cast<int>(argument_values.size()), argument_values.data());
  CefSettings settings;
  settings.no_sandbox = false;
  settings.external_message_pump = true;
  settings.persist_session_cookies = true;
  settings.log_severity = LOGSEVERITY_WARNING;
#ifdef DEBUG
  // Lets development tools inspect pages over the DevTools protocol.
  if (const char *port = getenv("INTERLINKED_REMOTE_DEBUGGING_PORT")) {
    settings.remote_debugging_port = atoi(port);
  }
#endif

  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *support = [files URLForDirectory:NSApplicationSupportDirectory
                                 inDomain:NSUserDomainMask
                        appropriateForURL:nil
                                   create:YES
                                    error:nil];
  NSURL *root = [[support URLByAppendingPathComponent:@"Interlinked" isDirectory:YES]
      URLByAppendingPathComponent:@"Chromium" isDirectory:YES];
  [files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
  CefString(&settings.root_cache_path) = CefFromNSString(root.path);
  CefString(&settings.cache_path) = CefFromNSString([root.path stringByAppendingPathComponent:@"Default"]);

  NSString *helper = [[NSBundle.mainBundle.privateFrameworksPath
      stringByAppendingPathComponent:@"Interlinked Helper.app/Contents/MacOS"]
      stringByAppendingPathComponent:@"Interlinked Helper"];
  CefString(&settings.browser_subprocess_path) = CefFromNSString(helper);

  NSString *logs = [NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Logs/Interlinked/Chromium.log"];
  [files createDirectoryAtPath:logs.stringByDeletingLastPathComponent
    withIntermediateDirectories:YES attributes:nil error:nil];
  CefString(&settings.log_file) = CefFromNSString(logs);

  g_browser_app = new InterlinkedBrowserApp();
  if (!CefInitialize(main_args, settings, g_browser_app, nullptr)) {
    if (error) {
      *error = [NSError errorWithDomain:@"computer.interlinked.chromium"
                                    code:3
                                userInfo:@{NSLocalizedDescriptionKey:
                                             @"Chromium initialization failed."}];
    }
    g_browser_app = nullptr;
    g_library_loader.reset();
    return NO;
  }

  g_running.store(true);
  // Requests Chromium made while initializing were dropped because the
  // runtime was not running yet, and Chromium does not repeat a wake-up it
  // believes is pending. Pumping through the scheduler starts the timer chain
  // that keeps the engine alive regardless.
  PerformMessagePumpWork();
  g_keep_alive_view = [[ILChromiumView alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)
                                                 initialURL:[NSURL URLWithString:@"about:blank"]];
  NSArray<ILChromiumView *> *waiting = g_views_awaiting_runtime.allObjects;
  [g_views_awaiting_runtime removeAllObjects];
  for (ILChromiumView *view in waiting) {
    [view createBrowserIfPossible];
  }
  return YES;
}

+ (void)closeAllBrowsersWithCompletion:(void (^)(BOOL))completion {
  if (!g_running.load() || g_closing_all_browsers) {
    completion(g_browsers.empty() && g_pending_browser_creations == 0);
    return;
  }
  g_closing_all_browsers = true;
  g_close_all_completion = [completion copy];
  [g_keep_alive_view closeBrowser];
  g_keep_alive_view = nil;
  const std::vector<CefRefPtr<CefBrowser>> browsers = g_browsers;
  for (const CefRefPtr<CefBrowser>& browser : browsers) {
    browser->GetHost()->CloseBrowser(true);
  }
  FinishClosingAllBrowsersIfDone();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    PerformOnMainRunLoop(^{
      FinishClosingAllBrowsers(NO);
    });
  });
}

+ (void)shutdown {
  if (!g_running.load()) {
    return;
  }
  if (g_message_pump_active || !g_browsers.empty() || g_pending_browser_creations > 0) {
    // CefShutdown aborts when called from inside CefDoMessageLoopWork or while
    // browsers are still open. Exiting without it is the safer failure.
    NSLog(@"Interlinked skipped Chromium shutdown: %@.",
          g_message_pump_active ? @"called from Chromium's message loop" : @"browsers are still open");
    return;
  }
  g_running.store(false);
  CancelMessagePumpTimer();
  g_immediate_pump_scheduled = false;
  g_message_pump_reentrant = false;
  CefShutdown();
  g_browser_app = nullptr;
  g_library_loader.reset();
}

@end

@implementation ILChromiumView

+ (void)setChromeOwnsCursor:(BOOL (^)(void))owns {
  g_chrome_owns_cursor = [owns copy];
}

+ (void)restorePageCursor {
  [(g_last_page_cursor ?: NSCursor.arrowCursor) set];
}

- (instancetype)initWithFrame:(NSRect)frame initialURL:(NSURL *)URL {
  self = [super initWithFrame:frame];
  if (self) {
    _pendingURL = URL;
    _pageTitle = @"";
    _evaluations = [NSMutableDictionary dictionary];
    _blockingScriptIdentifiers = [NSMutableArray array];
    _blockingScriptRequests = [NSMutableDictionary dictionary];
    self.wantsLayer = YES;
    [self createBrowserIfPossible];
  }
  return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  return [self initWithFrame:frameRect initialURL:[NSURL URLWithString:@"about:blank"]];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    _pendingURL = [NSURL URLWithString:@"about:blank"];
    _pageTitle = @"";
    _evaluations = [NSMutableDictionary dictionary];
    _blockingScriptIdentifiers = [NSMutableArray array];
    _blockingScriptRequests = [NSMutableDictionary dictionary];
    self.wantsLayer = YES;
    [self createBrowserIfPossible];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)isBrowserReady {
  return _browser != nullptr;
}

- (NSURL *)URL { return _URL; }
- (NSString *)title { return _pageTitle ?: @""; }
- (BOOL)isLoading { return _loading; }
- (BOOL)canGoBack { return _canGoBack; }
- (BOOL)canGoForward { return _canGoForward; }

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self createBrowserIfPossible];
  [self updateBrowserVisibility];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self syncBrowserViewFrame];
}

- (void)createBrowserIfPossible {
  if (_browser || _client || _closing || g_closing_all_browsers) {
    return;
  }
  if (!ILChromiumRuntime.running) {
    if (!g_views_awaiting_runtime) {
      g_views_awaiting_runtime = [NSHashTable weakObjectsHashTable];
    }
    [g_views_awaiting_runtime addObject:self];
    return;
  }
  [g_views_awaiting_runtime removeObject:self];
  _client = new InterlinkedClient(self);
  CefWindowInfo window_info;
  const int width = std::max(1, static_cast<int>(NSWidth(self.bounds)));
  const int height = std::max(1, static_cast<int>(NSHeight(self.bounds)));
  window_info.SetAsChild((__bridge CefWindowHandle)self, CefRect(0, 0, width, height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings browser_settings;
  NSString *URLString = _pendingURL.absoluteString ?: @"about:blank";
  if (CefBrowserHost::CreateBrowser(window_info, _client, CefFromNSString(URLString),
                                     browser_settings, nullptr, nullptr)) {
    g_pending_browser_creations++;
  } else {
    _client = nullptr;
    [self didFailNavigation:@"Chromium could not create the page view."];
  }
}

- (void)updateBrowserVisibility {
  if (!_browser) {
    return;
  }
  [self syncBrowserViewFrame];
  NSView *browserView = (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
  if (browserView && browserView != self) {
    // Hiding the windowed child while SwiftUI detaches a background tab stops
    // AppKit/Core Animation from compositing a page that cannot be seen. CEF's
    // WasHidden API is only valid for windowless rendering.
    browserView.hidden = self.window == nil;
  }
  if (self.window == nil) {
    PostBrowserFocus(_browser, false);
  }
}

- (void)syncBrowserViewFrame {
  if (!_browser) {
    return;
  }
  NSView *browserView = (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
  if (!browserView || browserView == self) {
    return;
  }
  browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  browserView.frame = self.bounds;
}

- (void)navigateToURL:(NSURL *)URL {
  _pendingURL = URL;
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(CefFromNSString(URL.absoluteString));
  } else {
    [self createBrowserIfPossible];
  }
}

- (void)goBack { if (_browser && _browser->CanGoBack()) _browser->GoBack(); }
- (void)goForward { if (_browser && _browser->CanGoForward()) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)reloadIgnoringCache { if (_browser) _browser->ReloadIgnoreCache(); }
- (void)stopLoading { if (_browser) _browser->StopLoad(); }

- (void)focusBrowser {
  if (!_browser) {
    return;
  }
  // Windowed Chromium takes keyboard focus through AppKit. That path does not
  // wait on Default-QoS worker threads the way CefBrowserHost::SetFocus does.
  NSView *hostView = (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
  NSView *target = FirstResponderCandidate(hostView);
  if (target.window && [target.window makeFirstResponder:target]) {
    return;
  }
  PostBrowserFocus(_browser, true);
}

- (void)evaluateJavaScript:(NSString *)script
                completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
  if (!_browser) {
    completion(nil, [NSError errorWithDomain:@"computer.interlinked.chromium"
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"The page is not ready."}]);
    return;
  }
  CefRefPtr<CefDictionaryValue> parameters = CefDictionaryValue::Create();
  parameters->SetString("expression", CefFromNSString(script));
  parameters->SetBool("awaitPromise", true);
  parameters->SetBool("returnByValue", true);
  parameters->SetBool("userGesture", true);
  const int identifier = _browser->GetHost()->ExecuteDevToolsMethod(
      0, "Runtime.evaluate", parameters);
  if (identifier == 0) {
    completion(nil, [NSError errorWithDomain:@"computer.interlinked.chromium"
                                         code:11
                                     userInfo:@{NSLocalizedDescriptionKey: @"Chromium rejected the script request."}]);
    return;
  }
  _evaluations[@(identifier)] = [completion copy];
}

- (void)findText:(NSString *)text
       backwards:(BOOL)backwards
        findNext:(BOOL)findNext
       completion:(void (^)(BOOL))completion {
  if (!_browser) {
    completion(NO);
    return;
  }
  _findCompletion = [completion copy];
  _browser->GetHost()->Find(CefFromNSString(text), !backwards, false, findNext);
}

- (void)stopFinding {
  if (_browser) {
    _browser->GetHost()->StopFinding(true);
  }
  _findCompletion = nil;
}

- (BOOL)forcedDarkMode {
  return _forcedDarkMode;
}

- (void)setForcedDarkMode:(BOOL)forcedDarkMode {
  if (_forcedDarkMode == forcedDarkMode) {
    return;
  }
  _forcedDarkMode = forcedDarkMode;
  [self applyForcedDarkMode];
}

- (void)applyForcedDarkMode {
  if (!_browser) {
    return;
  }
  // Sites with their own dark theme are asked for it; Chromium's Auto Dark
  // Mode recolors the rest and leaves images alone.
  CefRefPtr<CefDictionaryValue> media = CefDictionaryValue::Create();
  CefRefPtr<CefListValue> features = CefListValue::Create();
  if (_forcedDarkMode) {
    CefRefPtr<CefDictionaryValue> scheme = CefDictionaryValue::Create();
    scheme->SetString("name", "prefers-color-scheme");
    scheme->SetString("value", "dark");
    features->SetDictionary(0, scheme);
  }
  media->SetList("features", features);
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Emulation.setEmulatedMedia", media);

  CefRefPtr<CefDictionaryValue> automatic = CefDictionaryValue::Create();
  if (_forcedDarkMode) {
    automatic->SetBool("enabled", true);
  }
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Emulation.setAutoDarkModeOverride", automatic);
}

#pragma mark - Document-start script

- (void)setDocumentStartScript:(NSString *)source stopScript:(NSString *)stopScript {
  if ((source == nil && _documentStartSource == nil) || [source isEqualToString:_documentStartSource]) {
    return;
  }
  NSString *previous = _documentStartIdentifier;
  _documentStartIdentifier = nil;
  _documentStartSource = [source copy];
  if (!_browser) {
    return;
  }
  if (previous) {
    [self removeBlockingScript:previous];
  }
  if (!source && stopScript.length > 0) {
    [self evaluateJavaScript:stopScript completion:^(id result, NSError *error) {}];
  }
  [self applyDocumentStartScript];
}

- (void)applyDocumentStartScript {
  _documentStartRequest = 0;
  if (!_browser || !_documentStartSource) {
    return;
  }
  // Blink only runs new-document scripts while the Page domain is enabled.
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Page.enable", nullptr);
  CefRefPtr<CefDictionaryValue> parameters = CefDictionaryValue::Create();
  parameters->SetString("source", CefFromNSString(_documentStartSource));
  parameters->SetBool("runImmediately", true);
  _documentStartRequest = _browser->GetHost()->ExecuteDevToolsMethod(
      0, "Page.addScriptToEvaluateOnNewDocument", parameters);
  if (_documentStartRequest != 0) {
    if (!_documentStartPending) {
      _documentStartPending = [NSMutableSet set];
    }
    [_documentStartPending addObject:@(_documentStartRequest)];
  }
}

#pragma mark - Content blocking

static NSString *const ILCosmeticsWorld = @"interlinked-cosmetics";
static NSString *const ILCosmeticsBinding = @"__interlinkedCosmetics";

- (void)removeBlockingScript:(NSString *)identifier {
  if (!_browser) {
    return;
  }
  CefRefPtr<CefDictionaryValue> parameters = CefDictionaryValue::Create();
  parameters->SetString("identifier", CefFromNSString(identifier));
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Page.removeScriptToEvaluateOnNewDocument", parameters);
}

- (void)addBlockingScript:(NSString *)source
                    world:(nullable NSString *)world
           runImmediately:(BOOL)runImmediately {
  CefRefPtr<CefDictionaryValue> parameters = CefDictionaryValue::Create();
  parameters->SetString("source", CefFromNSString(source));
  parameters->SetBool("runImmediately", runImmediately);
  if (world) {
    parameters->SetString("worldName", CefFromNSString(world));
  }
  const int request = _browser->GetHost()->ExecuteDevToolsMethod(
      0, "Page.addScriptToEvaluateOnNewDocument", parameters);
  if (request != 0) {
    _blockingScriptRequests[@(request)] = @(_blockingGeneration);
  }
}

/// Registers what the document at |URLString| needs: scriptlets in the page's
/// world, and element hiding in an isolated world the page cannot see.
- (void)prepareBlockingForURLString:(NSString *)URLString runImmediately:(BOOL)runImmediately {
  if (!_browser) {
    return;
  }
  _blockingGeneration += 1;
  for (NSString *identifier in _blockingScriptIdentifiers) {
    [self removeBlockingScript:identifier];
  }
  [_blockingScriptIdentifiers removeAllObjects];
  _blockingExceptionsJSON = @"[]";

  const std::string host = HostOfURL(CefFromNSString(URLString));
  const std::shared_ptr<const BlockerEngine> engine = BlockerForPage(host);
  if (!engine || host.empty()) {
    return;
  }
  const std::string found = TakeBlockerString(il_blocker_cosmetics(engine->blocker, URLString.UTF8String ?: ""));
  NSDictionary *cosmetics = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:found.data() length:found.size()]
                                                            options:0 error:nil];
  if (![cosmetics isKindOfClass:NSDictionary.class]) {
    return;
  }
  if (!_blockingBindingInstalled) {
    _blockingBindingInstalled = YES;
    // Blink only runs new-document scripts while the Page domain is enabled,
    // and only reports binding calls while the Runtime domain is.
    _browser->GetHost()->ExecuteDevToolsMethod(0, "Page.enable", nullptr);
    _browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.enable", nullptr);
    CefRefPtr<CefDictionaryValue> binding = CefDictionaryValue::Create();
    binding->SetString("name", CefFromNSString(ILCosmeticsBinding));
    binding->SetString("executionContextName", CefFromNSString(ILCosmeticsWorld));
    _browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.addBinding", binding);
  }

  NSString *hostString = @(host.c_str());
  NSData *hostJSON = [NSJSONSerialization dataWithJSONObject:hostString options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *hostLiteral = [[NSString alloc] initWithData:hostJSON encoding:NSUTF8StringEncoding];
  // Subframes from other sites get neither: the rules were chosen for this site.
  NSString *guard = [NSString stringWithFormat:
      @"const h=%@,l=location.hostname;if(l!==h&&!l.endsWith('.'+h)&&!h.endsWith('.'+l))return;", hostLiteral];

  NSString *scriptlets = cosmetics[@"script"];
  if ([scriptlets isKindOfClass:NSString.class] && scriptlets.length > 0) {
    // uBlock Origin's injector gives its scriptlets a shared |scriptletGlobals|
    // object; without it they throw a ReferenceError on first use.
    [self addBlockingScript:[NSString stringWithFormat:@"(()=>{%@const scriptletGlobals={};\n%@\n})();", guard, scriptlets]
                      world:nil
             runImmediately:runImmediately];
  }

  NSArray *exceptions = cosmetics[@"exceptions"] ?: @[];
  NSData *exceptionsJSON = [NSJSONSerialization dataWithJSONObject:exceptions options:0 error:nil];
  _blockingExceptionsJSON = [[NSString alloc] initWithData:exceptionsJSON encoding:NSUTF8StringEncoding] ?: @"[]";
  NSDictionary *configuration = @{
    @"hide": cosmetics[@"hide"] ?: @[],
    @"procedural": cosmetics[@"procedural"] ?: @[],
    @"generic": @(![cosmetics[@"generichide"] boolValue]),
    @"binding": ILCosmeticsBinding,
  };
  NSData *configurationJSON = [NSJSONSerialization dataWithJSONObject:configuration options:0 error:nil];
  NSString *configurationLiteral = [[NSString alloc] initWithData:configurationJSON encoding:NSUTF8StringEncoding];
  [self addBlockingScript:[NSString stringWithFormat:@"(()=>{%@const cfg=%@;%@})();", guard, configurationLiteral,
                                                     ILCosmeticsScript()]
                    world:ILCosmeticsWorld
           runImmediately:runImmediately];
}

/// Runs |block| on a later turn once Chromium has confirmed every script the
/// latest -prepareBlockingForURLString: registered.
- (void)whenBlockingRegistered:(void (^)(void))block {
  _blockingRegistered = [block copy];
  [self runBlockingRegisteredIfDone];
}

- (void)runBlockingRegisteredIfDone {
  if (!_blockingRegistered || [_blockingScriptRequests.allValues containsObject:@(_blockingGeneration)]) {
    return;
  }
  void (^block)(void) = _blockingRegistered;
  _blockingRegistered = nil;
  PerformOnMainRunLoop(block);
}

/// The page reported class names and ids it uses; answer with the generic
/// hiding rules that apply to them.
- (void)didReceiveBindingCall:(NSData *)parameters {
  NSDictionary *event = [NSJSONSerialization JSONObjectWithData:parameters options:0 error:nil];
  if (![event isKindOfClass:NSDictionary.class] || ![event[@"name"] isEqual:ILCosmeticsBinding] || !_browser) {
    return;
  }
  NSString *payload = event[@"payload"];
  NSNumber *context = event[@"executionContextId"];
  if (![payload isKindOfClass:NSString.class] || ![context isKindOfClass:NSNumber.class] || payload.length > 2000000) {
    return;
  }
  const std::shared_ptr<const BlockerEngine> engine = BlockerForPage(HostOfURL(CefFromNSString(_URL.absoluteString)));
  NSDictionary *names = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0 error:nil];
  if (!engine || ![names isKindOfClass:NSDictionary.class]) {
    return;
  }
  NSData *exceptions = [_blockingExceptionsJSON ?: @"[]" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *query = @{
    @"classes": [names[@"classes"] isKindOfClass:NSArray.class] ? names[@"classes"] : @[],
    @"ids": [names[@"ids"] isKindOfClass:NSArray.class] ? names[@"ids"] : @[],
    @"exceptions": [NSJSONSerialization JSONObjectWithData:exceptions options:0 error:nil] ?: @[],
  };
  NSData *queryJSON = [NSJSONSerialization dataWithJSONObject:query options:0 error:nil];
  std::string request(static_cast<const char *>(queryJSON.bytes), queryJSON.length);
  const std::string selectors = TakeBlockerString(il_blocker_generic_selectors(engine->blocker, request.c_str()));
  if (selectors.size() <= 2) {
    return;
  }
  CefRefPtr<CefDictionaryValue> evaluate = CefDictionaryValue::Create();
  evaluate->SetString("expression", "globalThis.__interlinkedHide?.(" + selectors + ")");
  evaluate->SetInt("contextId", context.intValue);
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", evaluate);
}

- (void)didBlockRequests:(NSInteger)count {
  [self.delegate chromiumView:self didBlockRequests:count];
}

- (void)cancelDownload:(uint32_t)identifier {
  if (_client) _client->CancelDownload(identifier);
}

- (void)closeBrowser {
  if (_closing) {
    return;
  }
  _closing = YES;
  if (_client) {
    _client->Detach();
  }
  // Chromium destroys the host view as the close completes, while SwiftUI may
  // still move this view between windows. Drop the references now so no later
  // AppKit callback can reach the dead browser. A browser still being created
  // is closed by the detached client in OnAfterCreated.
  CefRefPtr<CefBrowser> browser = _browser;
  _browser = nullptr;
  _client = nullptr;
  [self failPendingRequests];
  if (browser) {
    browser->GetHost()->CloseBrowser(true);
  }
}

- (void)failPendingRequests {
  NSError *error = [NSError errorWithDomain:@"computer.interlinked.chromium"
                                        code:12
                                    userInfo:@{NSLocalizedDescriptionKey: @"The page was closed."}];
  NSArray<void (^)(id, NSError *)> *completions = _evaluations.allValues;
  [_evaluations removeAllObjects];
  for (void (^completion)(id, NSError *) in completions) {
    completion(nil, error);
  }
  _findCompletion = nil;
}

- (void)dealloc {
  [self closeBrowser];
}

- (void)didCreateBrowser:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  _client->ObserveDevTools(browser);
  [self applyForcedDarkMode];
  [self applyDocumentStartScript];
  [self updateBrowserVisibility];
  NSString *pendingURLString = _pendingURL.absoluteString;
  NSString *createdURLString = NSStringFromCef(browser->GetMainFrame()->GetURL());
  if (pendingURLString.length > 0 && ![pendingURLString isEqualToString:createdURLString]) {
    browser->GetMainFrame()->LoadURL(CefFromNSString(pendingURLString));
  }
  [self.delegate chromiumViewDidCreateBrowser:self];
}

- (void)didChangeURLString:(NSString *)URLString {
  _URL = [NSURL URLWithString:URLString];
  [self.delegate chromiumView:self didChangeURL:_URL];
}

- (void)didChangePageTitle:(NSString *)title {
  _pageTitle = [title copy] ?: @"";
  [self.delegate chromiumView:self didChangeTitle:_pageTitle];
}

- (void)didChangeLoading:(BOOL)isLoading
               canGoBack:(BOOL)canGoBack
            canGoForward:(BOOL)canGoForward {
  _loading = isLoading;
  _canGoBack = canGoBack;
  _canGoForward = canGoForward;
  [self.delegate chromiumView:self
             didChangeLoading:isLoading
                    canGoBack:canGoBack
                 canGoForward:canGoForward];
}

- (void)didCommitNavigation {
  [self.delegate chromiumViewDidCommitNavigation:self];
}

- (void)didFinishNavigation {
  [self.delegate chromiumViewDidFinishNavigation:self];
}

- (void)didFailNavigation:(NSString *)message {
  [self.delegate chromiumView:self didFailNavigation:message];
}

- (void)didRequestPopupURLString:(NSString *)URLString userGesture:(BOOL)userGesture {
  NSURL *URL = [NSURL URLWithString:URLString];
  if (URL) {
    [self.delegate chromiumView:self requestedPopupURL:URL userGesture:userGesture];
  }
}

- (void)didStartDownload:(uint32_t)identifier URLString:(NSString *)URLString suggestedFilename:(NSString *)filename {
  NSURL *URL = [NSURL URLWithString:URLString];
  if (URL) {
    [self.delegate chromiumView:self didStartDownload:identifier URL:URL suggestedFilename:filename];
  }
}

- (void)didUpdateDownload:(uint32_t)identifier fullPath:(NSString *)fullPath receivedBytes:(int64_t)receivedBytes totalBytes:(int64_t)totalBytes percent:(NSInteger)percent complete:(BOOL)complete cancelled:(BOOL)cancelled interrupted:(BOOL)interrupted {
  [self.delegate chromiumView:self didUpdateDownload:identifier fullPath:fullPath receivedBytes:receivedBytes totalBytes:totalBytes percent:percent complete:complete cancelled:cancelled interrupted:interrupted];
}

- (void)didCloseBrowser {
  [self failPendingRequests];
  _browser = nullptr;
  _client = nullptr;
  [self.delegate chromiumViewDidClose:self];
}

- (void)didReceiveEvaluation:(int)identifier
                     success:(BOOL)success
                        bytes:(const void *)bytes
                       length:(size_t)length {
  if ([_documentStartPending containsObject:@(identifier)]) {
    [_documentStartPending removeObject:@(identifier)];
    NSDictionary *reply = success && length > 0
        ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil]
        : nil;
    NSString *script = [reply isKindOfClass:NSDictionary.class] ? reply[@"identifier"] : nil;
    if (![script isKindOfClass:NSString.class]) {
      return;
    }
    if (identifier == _documentStartRequest && _documentStartSource) {
      _documentStartRequest = 0;
      _documentStartIdentifier = script;
    } else {
      // Turned off or replaced before Chromium answered.
      [self removeBlockingScript:script];
    }
    return;
  }
  NSNumber *generation = _blockingScriptRequests[@(identifier)];
  if (generation) {
    [_blockingScriptRequests removeObjectForKey:@(identifier)];
    [self runBlockingRegisteredIfDone];
    NSDictionary *reply = success && length > 0
        ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil]
        : nil;
    NSString *script = [reply isKindOfClass:NSDictionary.class] ? reply[@"identifier"] : nil;
    if (![script isKindOfClass:NSString.class]) {
      return;
    }
    if (generation.integerValue == _blockingGeneration) {
      [_blockingScriptIdentifiers addObject:script];
    } else {
      // A newer navigation started before Chromium answered.
      [self removeBlockingScript:script];
    }
    return;
  }
  void (^completion)(id, NSError *) = _evaluations[@(identifier)];
  if (!completion) {
    return;
  }
  [_evaluations removeObjectForKey:@(identifier)];
  NSData *data = [NSData dataWithBytes:bytes length:length];
  NSError *parseError = nil;
  NSDictionary *payload = length > 0
      ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError]
      : @{};
  if (!success || parseError) {
    NSString *message = payload[@"message"] ?: parseError.localizedDescription ?: @"JavaScript evaluation failed.";
    completion(nil, [NSError errorWithDomain:@"computer.interlinked.chromium"
                                         code:13
                                     userInfo:@{NSLocalizedDescriptionKey: message}]);
    return;
  }
  NSArray *cookies = payload[@"cookies"];
  if ([cookies isKindOfClass:NSArray.class]) {
    completion(cookies, nil);
    return;
  }
  NSDictionary *exception = payload[@"exceptionDetails"];
  if (exception) {
    NSString *message = exception[@"text"] ?: @"JavaScript evaluation failed.";
    completion(nil, [NSError errorWithDomain:@"computer.interlinked.chromium"
                                         code:14
                                     userInfo:@{NSLocalizedDescriptionKey: message}]);
    return;
  }
  NSDictionary *remote = payload[@"result"];
  id value = remote[@"value"];
  completion(value == NSNull.null ? nil : value, nil);
}

- (void)didReceiveFindCount:(int)count finalUpdate:(BOOL)finalUpdate {
  if (!finalUpdate || !_findCompletion) {
    return;
  }
  void (^completion)(BOOL) = _findCompletion;
  _findCompletion = nil;
  completion(count > 0);
}

@end

namespace {

void InterlinkedClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        const CefString& url) {
  CEF_REQUIRE_UI_THREAD();
  if (frame->IsMain()) {
    [view_ didChangeURLString:NSStringFromCef(url)];
  }
}

void InterlinkedClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                      const CefString& title) {
  CEF_REQUIRE_UI_THREAD();
  [view_ didChangePageTitle:NSStringFromCef(title)];
}

bool InterlinkedClient::OnCursorChange(CefRefPtr<CefBrowser> browser,
                                       CefCursorHandle cursor,
                                       cef_cursor_type_t type,
                                       const CefCursorInfo& custom_cursor_info) {
  CEF_REQUIRE_UI_THREAD();
  g_last_page_cursor = (__bridge NSCursor *)cursor;
  return g_chrome_owns_cursor && g_chrome_owns_cursor();
}

void InterlinkedClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                             bool is_loading,
                                             bool can_go_back,
                                             bool can_go_forward) {
  CEF_REQUIRE_UI_THREAD();
  [view_ didChangeLoading:is_loading
                canGoBack:can_go_back
             canGoForward:can_go_forward];
}

void InterlinkedClient::OnLoadStart(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    TransitionType transition_type) {
  CEF_REQUIRE_UI_THREAD();
  if (frame->IsMain()) {
    [view_ didCommitNavigation];
  }
}

void InterlinkedClient::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  int http_status_code) {
  CEF_REQUIRE_UI_THREAD();
  if (frame->IsMain()) {
    [view_ didFinishNavigation];
  }
}

void InterlinkedClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    ErrorCode error_code,
                                    const CefString& error_text,
                                    const CefString& failed_url) {
  CEF_REQUIRE_UI_THREAD();
  if (frame->IsMain() && error_code != ERR_ABORTED) {
    [view_ didFailNavigation:NSStringFromCef(error_text)];
  }
}

bool InterlinkedClient::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString& target_url,
    const CefString& target_frame_name,
    WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures& popup_features,
    CefWindowInfo& window_info,
    CefRefPtr<CefClient>& client,
    CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue>& extra_info,
    bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  if (!target_url.empty()) {
    [view_ didRequestPopupURLString:NSStringFromCef(target_url)
                        userGesture:user_gesture];
  }
  return true;
}

void InterlinkedClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  g_pending_browser_creations = std::max(0, g_pending_browser_creations - 1);
  g_browsers.push_back(browser);
  ILChromiumView *view = view_;
  if (!view || g_closing_all_browsers) {
    // The tab was closed while Chromium was still creating its browser.
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  [view didCreateBrowser:browser];
}

void InterlinkedClient::CountBlockedRequest() {
  if (unreported_blocks_.fetch_add(1) == 0) {
    CefRefPtr<InterlinkedClient> self(this);
    PerformOnMainRunLoop(^{
      [self->view_ didBlockRequests:self->unreported_blocks_.exchange(0)];
    });
  }
}

CefResourceRequestHandler::ReturnValue InterlinkedClient::OnBeforeResourceLoad(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) {
  // Called on the network thread.
  const bool navigation = request->GetResourceType() == RT_MAIN_FRAME;
  if (IsDocumentRequest(request)) {
    // Tracking parameters never reach a page, whether or not blocking is on.
    const std::string clean = TakeBlockerString(il_strip_tracking(request->GetURL().ToString().c_str()));
    if (!clean.empty()) {
      request->SetURL(clean);
    }
  }
  CefString page_url = navigation ? request->GetURL() : request->GetFirstPartyForCookies();
  if (page_url.empty() && browser && browser->GetMainFrame()) {
    page_url = browser->GetMainFrame()->GetURL();
  }
  const std::shared_ptr<const BlockerEngine> engine = BlockerForPage(HostOfURL(page_url));
  if (!engine) {
    return RV_CONTINUE;
  }
  char *detail = nullptr;
  const int32_t verdict = il_blocker_check(engine->blocker, request->GetURL().ToString().c_str(),
                                           page_url.ToString().c_str(),
                                           BlockerRequestType(request->GetResourceType()),
                                           request->GetMethod().ToString().c_str(), &detail);
  const std::string value = TakeBlockerString(detail);
  if (verdict == IL_REWRITE && !value.empty()) {
    // Tracking parameters removed from the address.
    request->SetURL(value);
    return RV_CONTINUE;
  }
  // The page the user navigated to always loads.
  if (navigation || verdict == IL_ALLOW) {
    return RV_CONTINUE;
  }
  CountBlockedRequest();
  if (verdict == IL_REDIRECT && !value.empty()) {
    std::lock_guard<std::mutex> lock(replacements_mutex_);
    replacements_[request->GetIdentifier()] = value;
    return RV_CONTINUE;
  }
  return RV_CANCEL;
}

// A server redirect to a tagged address is followed to the clean address.
void InterlinkedClient::OnResourceRedirect(CefRefPtr<CefBrowser> browser,
                                           CefRefPtr<CefFrame> frame,
                                           CefRefPtr<CefRequest> request,
                                           CefRefPtr<CefResponse> response,
                                           CefString& new_url) {
  // Called on the network thread.
  if (!IsDocumentRequest(request)) {
    return;
  }
  const std::string clean = TakeBlockerString(il_strip_tracking(new_url.ToString().c_str()));
  if (!clean.empty()) {
    new_url = clean;
  }
}

CefRefPtr<CefResourceHandler> InterlinkedClient::GetResourceHandler(CefRefPtr<CefBrowser> browser,
                                                                    CefRefPtr<CefFrame> frame,
                                                                    CefRefPtr<CefRequest> request) {
  std::string replacement;
  {
    std::lock_guard<std::mutex> lock(replacements_mutex_);
    auto found = replacements_.find(request->GetIdentifier());
    if (found == replacements_.end()) {
      return nullptr;
    }
    replacement = std::move(found->second);
    replacements_.erase(found);
  }
  // Answer with a harmless stand-in (data:<mime>;base64,<body>) so pages that
  // depend on an ad or analytics script keep working.
  const size_t comma = replacement.find(',');
  if (replacement.rfind("data:", 0) != 0 || comma == std::string::npos) {
    return nullptr;
  }
  std::string mime = replacement.substr(5, comma - 5);
  const size_t semicolon = mime.find(';');
  if (semicolon != std::string::npos) {
    mime.resize(semicolon);
  }
  CefRefPtr<CefBinaryValue> body = CefBase64Decode(replacement.substr(comma + 1));
  if (!body) {
    return nullptr;
  }
  std::vector<uint8_t> bytes(body->GetSize());
  body->GetData(bytes.data(), bytes.size(), 0);
  CefResponse::HeaderMap headers;
  headers.insert({"Access-Control-Allow-Origin", "*"});
  headers.insert({"Cache-Control", "no-store"});
  return new CefStreamResourceHandler(
      200, "OK", mime.empty() ? "text/plain" : mime, headers,
      CefStreamReader::CreateForData(bytes.data(), bytes.size()));
}

void InterlinkedClient::PrepareBlocking(ILChromiumView *view, CefRefPtr<CefRequest> request) {
  blocking_host_ = HostOfURL(request->GetURL());
  [view prepareBlockingForURLString:NSStringFromCef(request->GetURL()) runImmediately:NO];
}

// A server redirect to another host needs that host's rules, but Chromium
// confirms rules registered during a navigation only after a fast redirected
// document has already started without them. The redirect is restarted at its
// destination once that host's rules are confirmed.
bool InterlinkedClient::RestartRedirect(uint64_t generation,
                                        CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        CefRefPtr<CefRequest> request) {
  const std::string method = request->GetMethod().ToString();
  const std::string host = HostOfURL(request->GetURL());
  // Only GET restarts without replaying a body; the cap stops a server that
  // bounces between hosts from redirecting forever.
  if (!(method.empty() || method == "GET") || host == blocking_host_ || redirect_restarts_ >= 5 ||
      !BlockerForPage(host)) {
    return false;
  }
  ILChromiumView *view = view_;
  if (!view) {
    return false;
  }
  redirect_restarts_ += 1;
  PrepareBlocking(view, request);
  restarted_navigation_ = RequestSignature(request);
  CefRefPtr<InterlinkedClient> self(this);
  [view whenBlockingRegistered:^{
    self->ContinueNavigation(generation, browser, frame, request);
  }];
  return true;
}

bool InterlinkedClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       CefRefPtr<CefRequest> request,
                                       bool user_gesture,
                                       bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame->IsMain()) {
    return false;
  }
  const std::string signature = RequestSignature(request);
  if (!approved_navigation_.empty() && approved_navigation_ == signature) {
    approved_navigation_.clear();
    certificate_error_reported_ = false;
    if (restarted_navigation_ != signature) {
      PrepareBlocking(view_, request);
    }
    restarted_navigation_.clear();
    return false;
  }
  if (!is_redirect) {
    redirect_restarts_ = 0;
  }

  const uint64_t generation = ++navigation_review_generation_;
  ILChromiumView *view = view_;
  id<ILChromiumViewDelegate> delegate = view.delegate;
  if (!view || !delegate) {
    PrepareBlocking(view, request);
    return false;
  }
  NSURL *destination = [NSURL URLWithString:NSStringFromCef(request->GetURL())];
  NSURL *source = [NSURL URLWithString:NSStringFromCef(browser->GetMainFrame()->GetURL())];
  if (!destination) {
    return true;
  }
  CefRefPtr<InterlinkedClient> self(this);
  const BOOL reviewing = [delegate chromiumView:view
                          decideNavigationToURL:destination
                                      sourceURL:source
                                           kind:NavigationKind(request, is_redirect)
                                     completion:^(BOOL allow) {
    if (allow) {
      self->ContinueNavigation(generation, browser, frame, request);
    }
  }];
  if (!reviewing) {
    certificate_error_reported_ = false;
    if (is_redirect && RestartRedirect(generation, browser, frame, request)) {
      return true;
    }
    PrepareBlocking(view, request);
  }
  return reviewing;
}

void InterlinkedClient::ContinueNavigation(uint64_t generation,
                                           CefRefPtr<CefBrowser> browser,
                                           CefRefPtr<CefFrame> frame,
                                           CefRefPtr<CefRequest> request) {
  CEF_REQUIRE_UI_THREAD();
  if (!view_ || !browser || generation != navigation_review_generation_ || !frame || !frame->IsValid()) {
    return;
  }
  approved_navigation_ = RequestSignature(request);
  // Replaying through the captured frame is renderer-initiated: CEF sends the
  // request to the frame's render frame, which starts the navigation with that
  // document as the initiator. If another navigation began while the review
  // was pending, the captured frame is stale and the initiator no longer
  // matches the browser's navigation state, so Chromium kills the renderer
  // for an invalid initiator origin ("This page stopped responding").
  // Re-resolve the current main frame and replay idempotent navigations as
  // browser-initiated loads instead, the same path typed URLs take.
  CefRefPtr<CefFrame> current = browser->GetMainFrame();
  if (!current || !current->IsValid()) {
    return;
  }
  const std::string method = request->GetMethod().ToString();
  const std::string url = request->GetURL().ToString();
  if ((method.empty() || method == "GET") && current->IsMain()) {
    current->LoadURL(url);
    return;
  }
  // State-changing methods keep their body by replaying the original request.
  current->LoadRequest(request);
}

bool InterlinkedClient::OnCertificateError(CefRefPtr<CefBrowser> browser,
                                           cef_errorcode_t cert_error,
                                           const CefString& request_url,
                                           CefRefPtr<CefSSLInfo> ssl_info,
                                           CefRefPtr<CefCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  callback->Cancel();
  if (!certificate_error_reported_) {
    certificate_error_reported_ = true;
    NSURL *URL = [NSURL URLWithString:NSStringFromCef(request_url)];
    if (URL) {
      NSString *message = [NSString stringWithFormat:@"Chromium rejected certificate error %d.", cert_error];
      [view_.delegate chromiumView:view_ didRejectCertificateAtURL:URL error:message];
    }
  }
  return true;
}

void InterlinkedClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                                  TerminationStatus status,
                                                  int error_code,
                                                  const CefString& error_string) {
  CEF_REQUIRE_UI_THREAD();
  [view_.delegate chromiumViewWebContentProcessDidTerminate:view_];
}

bool InterlinkedClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  const uint32_t audio = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
  const uint32_t video = CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
  const uint32_t supported = audio | video;
  if ((requested_permissions & supported) == 0 ||
      (requested_permissions & ~supported) != 0 || !view_.delegate) {
    callback->Cancel();
    return true;
  }
  const ILWebsitePermissionKind kind =
      (requested_permissions & supported) == supported
          ? ILWebsitePermissionKindCameraAndMicrophone
          : (requested_permissions & video) != 0
                ? ILWebsitePermissionKindCamera
                : ILWebsitePermissionKindMicrophone;
  [view_.delegate chromiumView:view_
      decidePermissionForOrigin:NSStringFromCef(requesting_origin)
                           kind:kind
                     completion:^(BOOL allow) {
    callback->Continue(allow ? requested_permissions : CEF_MEDIA_PERMISSION_NONE);
  }];
  return true;
}

bool InterlinkedClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  const uint32_t camera = CEF_PERMISSION_TYPE_CAMERA_STREAM;
  const uint32_t microphone = CEF_PERMISSION_TYPE_MIC_STREAM;
  const uint32_t location = CEF_PERMISSION_TYPE_GEOLOCATION;
  const uint32_t supported = camera | microphone | location;
  if ((requested_permissions & supported) == 0 ||
      (requested_permissions & ~supported) != 0 ||
      ((requested_permissions & location) != 0 && (requested_permissions & (camera | microphone)) != 0) ||
      !view_.delegate) {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }
  ILWebsitePermissionKind kind = ILWebsitePermissionKindLocation;
  if ((requested_permissions & (camera | microphone)) == (camera | microphone)) {
    kind = ILWebsitePermissionKindCameraAndMicrophone;
  } else if ((requested_permissions & camera) != 0) {
    kind = ILWebsitePermissionKindCamera;
  } else if ((requested_permissions & microphone) != 0) {
    kind = ILWebsitePermissionKindMicrophone;
  }
  [view_.delegate chromiumView:view_
      decidePermissionForOrigin:NSStringFromCef(requesting_origin)
                           kind:kind
                     completion:^(BOOL allow) {
    callback->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
  }];
  return true;
}

void InterlinkedClient::OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                                        const CefString& method,
                                        const void* params,
                                        size_t params_size) {
  CEF_REQUIRE_UI_THREAD();
  if (method == "Runtime.bindingCalled") {
    [view_ didReceiveBindingCall:[NSData dataWithBytes:params length:params_size]];
  }
}

bool InterlinkedClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  // Returning false would make CEF send performClose: to the top-level window,
  // closing all of Interlinked for one tab. Tearing down the browser's own
  // view completes the close instead and leads to OnBeforeClose.
  NSView *browserView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  PerformOnMainRunLoop(^{
    [browserView removeFromSuperview];
  });
  return true;
}

void InterlinkedClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  for (auto it = g_browsers.begin(); it != g_browsers.end(); ++it) {
    if ((*it)->IsSame(browser)) {
      g_browsers.erase(it);
      break;
    }
  }
  devtools_registration_ = nullptr;
  downloads_.clear();
  [view_ didCloseBrowser];
  parent_view_ = nil;
  FinishClosingAllBrowsersIfDone();
}

void InterlinkedClient::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                               int message_id,
                                               bool success,
                                               const void* result,
                                               size_t result_size) {
  CEF_REQUIRE_UI_THREAD();
  [view_ didReceiveEvaluation:message_id
                      success:success
                         bytes:result
                        length:result_size];
}

void InterlinkedClient::OnFindResult(CefRefPtr<CefBrowser> browser,
                                     int identifier,
                                     int count,
                                     const CefRect& selection_rect,
                                     int active_match_ordinal,
                                     bool final_update) {
  CEF_REQUIRE_UI_THREAD();
  [view_ didReceiveFindCount:count finalUpdate:final_update];
}

bool InterlinkedClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  ILChromiumView *view = view_;
  id<ILChromiumViewDelegate> delegate = view.delegate;
  NSURL *destination = [NSURL URLWithString:NSStringFromCef(download_item->GetURL())];
  NSURL *source = [NSURL URLWithString:NSStringFromCef(browser->GetMainFrame()->GetURL())];
  if (!view || !delegate || !destination) {
    return true;
  }
  const uint32_t identifier = download_item->GetId();
  NSString *URLString = [destination.absoluteString copy];
  NSString *filename = [NSStringFromCef(suggested_name) copy];
  [delegate chromiumView:view
      decideDownloadFromURL:source
                      toURL:destination
                 completion:^(BOOL allow) {
    if (!allow || !view) {
      return;
    }
    [view didStartDownload:identifier URLString:URLString suggestedFilename:filename];
    callback->Continue(CefString(), true);
  }];
  return true;
}

void InterlinkedClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  const uint32_t identifier = download_item->GetId();
  downloads_[identifier] = callback;
  [view_ didUpdateDownload:identifier
                  fullPath:NSStringFromCef(download_item->GetFullPath())
             receivedBytes:download_item->GetReceivedBytes()
                totalBytes:download_item->GetTotalBytes()
                   percent:download_item->GetPercentComplete()
                  complete:download_item->IsComplete()
                 cancelled:download_item->IsCanceled()
               interrupted:download_item->IsInterrupted()];
  if (download_item->IsComplete() || download_item->IsCanceled() || download_item->IsInterrupted()) {
    downloads_.erase(identifier);
  }
}

}  // namespace
