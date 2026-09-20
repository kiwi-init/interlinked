#import "InterlinkedChromium.h"
#import <objc/runtime.h>

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
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_helpers.h"
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

// Built-in content blocking. Rules are immutable once published, so the
// network thread only takes the lock long enough to copy the pointer.
struct BlockingRules {
  std::unordered_set<std::string> blocked;              // ||host^
  std::unordered_set<std::string> blocked_third_party;  // ||host^$third-party
  std::unordered_set<std::string> allowed;              // @@||host^
  std::unordered_set<std::string> disabled_sites;       // sites the user exempted
};
std::mutex g_blocking_mutex;
std::shared_ptr<const BlockingRules> g_blocking_rules;

std::shared_ptr<const BlockingRules> CurrentBlockingRules() {
  std::lock_guard<std::mutex> lock(g_blocking_mutex);
  return g_blocking_rules;
}

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

// True when |host| or one of its parent domains is in |set|.
bool MatchesHostOrParent(const std::unordered_set<std::string>& set, const std::string& host) {
  if (set.empty()) {
    return false;
  }
  size_t start = 0;
  while (start < host.size()) {
    if (set.count(host.substr(start))) {
      return true;
    }
    const size_t dot = host.find('.', start);
    if (dot == std::string::npos) {
      break;
    }
    start = dot + 1;
  }
  return false;
}

// Approximates the registrable domain with the last two labels. A wrong guess
// for suffixes such as co.uk only makes a third-party rule apply less often.
std::string SiteOfHost(const std::string& host) {
  const size_t last = host.rfind('.');
  if (last == std::string::npos || last == 0) {
    return host;
  }
  const size_t previous = host.rfind('.', last - 1);
  return previous == std::string::npos ? host : host.substr(previous + 1);
}

bool ShouldBlockRequest(const std::string& host, const std::string& page_host) {
  const std::shared_ptr<const BlockingRules> rules = CurrentBlockingRules();
  if (!rules || host.empty()) {
    return false;
  }
  if (!page_host.empty() && MatchesHostOrParent(rules->disabled_sites, page_host)) {
    return false;
  }
  if (MatchesHostOrParent(rules->allowed, host)) {
    return false;
  }
  if (MatchesHostOrParent(rules->blocked, host)) {
    return true;
  }
  const bool third_party = !page_host.empty() && SiteOfHost(host) != SiteOfHost(page_host);
  return third_party && MatchesHostOrParent(rules->blocked_third_party, host);
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
      command_line->AppendSwitch("use-mock-keychain");
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
                                public CefRequestHandler,
                                public CefResourceRequestHandler {
 public:
  explicit InterlinkedClient(ILChromiumView *view) : view_(view), parent_view_(view) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
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

  void Detach() { view_ = nil; }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
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
  IMPLEMENT_REFCOUNTING(InterlinkedClient);
};

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
  NSMutableDictionary<NSNumber *, void (^)(id _Nullable, NSError * _Nullable)> *_evaluations;
  void (^_findCompletion)(BOOL);
}
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
- (void)applyForcedDarkMode;
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

+ (void)setBlockedHosts:(NSArray<NSString *> *)blocked
      thirdPartyHosts:(NSArray<NSString *> *)thirdParty
         allowedHosts:(NSArray<NSString *> *)allowed
        disabledSites:(NSArray<NSString *> *)disabledSites {
  auto rules = std::make_shared<BlockingRules>();
  void (^fill)(std::unordered_set<std::string>&, NSArray<NSString *> *) =
      ^(std::unordered_set<std::string>& set, NSArray<NSString *> *hosts) {
    set.reserve(hosts.count);
    for (NSString *host in hosts) {
      set.emplace(host.lowercaseString.UTF8String ?: "");
    }
  };
  fill(rules->blocked, blocked);
  fill(rules->blocked_third_party, thirdParty);
  fill(rules->allowed, allowed);
  fill(rules->disabled_sites, disabledSites);
  std::lock_guard<std::mutex> lock(g_blocking_mutex);
  g_blocking_rules = std::move(rules);
}

+ (void)disableContentBlocking {
  std::lock_guard<std::mutex> lock(g_blocking_mutex);
  g_blocking_rules = nullptr;
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
  settings.no_sandbox = true;
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

- (instancetype)initWithFrame:(NSRect)frame initialURL:(NSURL *)URL {
  self = [super initWithFrame:frame];
  if (self) {
    _pendingURL = URL;
    _pageTitle = @"";
    _evaluations = [NSMutableDictionary dictionary];
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
  if (_browser || _client || _closing || g_closing_all_browsers || !ILChromiumRuntime.running) {
    return;
  }
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
    _browser->GetHost()->SetFocus(false);
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
  if (_browser) {
    _browser->GetHost()->SetFocus(true);
  }
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

CefResourceRequestHandler::ReturnValue InterlinkedClient::OnBeforeResourceLoad(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) {
  // Called on the network thread. The page the user navigated to always loads.
  if (request->GetResourceType() == RT_MAIN_FRAME) {
    return RV_CONTINUE;
  }
  std::string page_host = HostOfURL(request->GetFirstPartyForCookies());
  if (page_host.empty() && browser && browser->GetMainFrame()) {
    page_host = HostOfURL(browser->GetMainFrame()->GetURL());
  }
  if (!ShouldBlockRequest(HostOfURL(request->GetURL()), page_host)) {
    return RV_CONTINUE;
  }
  if (unreported_blocks_.fetch_add(1) == 0) {
    CefRefPtr<InterlinkedClient> self(this);
    PerformOnMainRunLoop(^{
      [self->view_ didBlockRequests:self->unreported_blocks_.exchange(0)];
    });
  }
  return RV_CANCEL;
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
  [view_ didStartDownload:download_item->GetId()
                URLString:NSStringFromCef(download_item->GetURL())
        suggestedFilename:NSStringFromCef(suggested_name)];
  callback->Continue(CefString(), true);
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
