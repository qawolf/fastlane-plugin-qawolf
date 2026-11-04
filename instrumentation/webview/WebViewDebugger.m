//
//  WebViewDebugger.m
//  Instrumentation
//
//  Automatically enables Safari Web Inspector debugging for all WKWebViews
//  with dynamic configuration support
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "../utils.h"
#import "../filemonitor.h"

// Forward declaration
@class WebViewDebugger;

@interface WebViewDebugger : NSObject

@property (nonatomic, strong) NSPointerArray *webViews;  // Weak references to all webviews
@property (nonatomic, assign) BOOL debuggingEnabled;
@property (nonatomic, strong) dispatch_queue_t queue;

+ (instancetype)sharedInstance;
- (void)registerWebView:(WKWebView *)webView;
- (void)configureWebView:(WKWebView *)webView;
- (void)updateDebuggingState;
- (BOOL)shouldEnableDebugging;

@end

@implementation WebViewDebugger

static WebViewDebugger *sharedInstance = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[WebViewDebugger alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _webViews = [NSPointerArray weakObjectsPointerArray];
        _queue = dispatch_queue_create("com.qawolf.webview.debugger", DISPATCH_QUEUE_SERIAL);
        _debuggingEnabled = YES;  // Default to enabled when no config exists

        // Check initial config
        [self updateDebuggingState];

        // Set up FileMonitor notification listener
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(fileChanged:)
                                                     name:kFileChangedEvent
                                                   object:nil];

        NSLog(@"QAWolf:WebViewDebugger - Set up FileMonitor listener for config changes");
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)fileChanged:(NSNotification *)notification {
    NSString *changedPath = notification.userInfo[@"path"];
    NSString *configFolder = [Utils getQAWolfFolder];
    
    // Check if the change is in our monitored folder (FileMonitor monitors the entire QAWolf folder)
    if ([changedPath isEqualToString:configFolder]) {
        NSLog(@"QAWolf:WebViewDebugger - QAWolf folder changed, checking for webview_debug.json updates");
        
        // Update debugging state on main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateDebuggingState];
        });
    }
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"QAWolf:WebViewDebugger initializing...");

        // Initialize shared instance
        [WebViewDebugger sharedInstance];

        // Swizzle WKWebView init methods
        [self swizzleWKWebViewInit];

        NSLog(@"✅ QAWolf:WebViewDebugger ready - webview debugging control enabled");
    });
}

+ (void)swizzleWKWebViewInit {
    Class wkWebViewClass = [WKWebView class];

    // Swizzle initWithFrame:configuration:
    SEL originalSelector = @selector(initWithFrame:configuration:);
    SEL swizzledSelector = @selector(qawolf_initWithFrame:configuration:);

    Method originalMethod = class_getInstanceMethod(wkWebViewClass, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(wkWebViewClass, swizzledSelector);

    BOOL didAddMethod = class_addMethod(wkWebViewClass,
                                        originalSelector,
                                        method_getImplementation(swizzledMethod),
                                        method_getTypeEncoding(swizzledMethod));

    if (didAddMethod) {
        class_replaceMethod(wkWebViewClass,
                           swizzledSelector,
                           method_getImplementation(originalMethod),
                           method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }

    // Also swizzle initWithCoder: for storyboard/nib created webviews
    SEL coderOriginal = @selector(initWithCoder:);
    SEL coderSwizzled = @selector(qawolf_initWithCoder:);

    Method coderOriginalMethod = class_getInstanceMethod(wkWebViewClass, coderOriginal);
    Method coderSwizzledMethod = class_getInstanceMethod(wkWebViewClass, coderSwizzled);

    method_exchangeImplementations(coderOriginalMethod, coderSwizzledMethod);
}

- (void)registerWebView:(WKWebView *)webView {
    dispatch_async(self.queue, ^{
        [self.webViews addPointer:(__bridge void *)webView];
        [self.webViews compact];  // Remove nil references
        NSLog(@"QAWolf:Registered WebView, total count: %lu", (unsigned long)self.webViews.count);
    });
}

- (void)configureWebView:(WKWebView *)webView {
    if (!webView) return;

    // Check iOS version first
    if (!@available(iOS 16.4, *)) {
        NSLog(@"❌ QAWolf:WebView debugging requires iOS 16.4 or later (current iOS version is too old)");
        return;
    }

    // Check if selector is available
    if (![webView respondsToSelector:@selector(setInspectable:)]) {
        NSLog(@"❌ QAWolf:setInspectable selector not available on iOS 16.4+");
        return;
    }

    // All checks passed, set the inspectable property
    BOOL shouldDebug = self.debuggingEnabled;

    // We can safely use KVC here since we've already checked the selector exists
    [webView setValue:@(shouldDebug) forKey:@"inspectable"];

    NSLog(@"✅ QAWolf:Set webView.inspectable = %@", shouldDebug ? @"YES" : @"NO");
}

- (BOOL)shouldEnableDebugging {
    // Read config file to determine if debugging should be enabled
    NSString *configPath = [[Utils getQAWolfFolder] stringByAppendingPathComponent:@"webview_debug.json"];

    // If file doesn't exist, default to debuggable (true)
    if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
        NSLog(@"QAWolf:WebView debug config file not found - defaulting to ENABLED");
        return YES;
    }

    // Read the file content
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:configPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];

    if (error) {
        NSLog(@"QAWolf:Error reading webview_debug config: %@ - defaulting to ENABLED", error.localizedDescription);
        return YES;
    }

    // Trim whitespace and newlines
    NSString *trimmed = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Only "true" content means debuggable, everything else means not debuggable
    BOOL enabled = [trimmed isEqualToString:@"true"];

    NSLog(@"QAWolf:WebView debug config path: %@", configPath);
    NSLog(@"QAWolf:WebView debug config raw content: '%@'", content);
    NSLog(@"QAWolf:WebView debug config trimmed: '%@' -> %@", trimmed, enabled ? @"ENABLED" : @"DISABLED");
    return enabled;
}

- (void)updateDebuggingState {
    BOOL newState = [self shouldEnableDebugging];

    if (newState != self.debuggingEnabled) {
        self.debuggingEnabled = newState;
        NSLog(@"QAWolf:WebView debugging state changed to: %@", newState ? @"ENABLED" : @"DISABLED");

        // Update all existing webviews
        dispatch_async(self.queue, ^{
            [self.webViews compact];  // Remove nil references first

            NSUInteger updatedCount = 0;
            for (NSInteger i = 0; i < self.webViews.count; i++) {
                void *pointer = [self.webViews pointerAtIndex:i];
                if (pointer == NULL) continue;

                WKWebView *webView = (__bridge WKWebView *)pointer;
                if (webView) {
                    [self configureWebView:webView];
                    updatedCount++;
                }
            }

            NSLog(@"QAWolf:Successfully updated %lu webviews (out of %lu registered)",
                  (unsigned long)updatedCount, (unsigned long)self.webViews.count);
        });
    } else {
        NSLog(@"QAWolf:WebView debugging state unchanged: %@", newState ? @"ENABLED" : @"DISABLED");
    }
}

@end

// Category to swizzle WKWebView methods
@implementation WKWebView (QAWolfDebugger)

- (instancetype)qawolf_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    NSLog(@"QAWolf:WebView being created with initWithFrame:configuration:");

    // Call original implementation first
    WKWebView *webView = [self qawolf_initWithFrame:frame configuration:configuration];

    // Configure and register the webview
    [[WebViewDebugger sharedInstance] configureWebView:webView];
    [[WebViewDebugger sharedInstance] registerWebView:webView];

    return webView;
}

- (instancetype)qawolf_initWithCoder:(NSCoder *)coder {
    NSLog(@"QAWolf:WebView being created with initWithCoder:");

    // Call original implementation
    WKWebView *webView = [self qawolf_initWithCoder:coder];

    if (webView) {
        // Configure and register the webview
        [[WebViewDebugger sharedInstance] configureWebView:webView];
        [[WebViewDebugger sharedInstance] registerWebView:webView];
    }

    return webView;
}

@end