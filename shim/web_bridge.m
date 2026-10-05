// Roblox's embedded web pages (signing in with a password and its captcha,
// purchase and account pages, links) in the launcher's WebKit window instead
// of Darling's WebKit, which is a stub. Adapted from spidercraft's Roblox Mac
// Linux Port (runtime/shims/appkit/browser.m and webview.inc), with their
// permission.
//
// The launcher listens on a Unix socket (MACNCHEESE_WEB_SOCKET, its host path
// as the guest sees it) and both sides speak JSON, one object per line: the
// game sends requests ({"op": ...}), the launcher events and replies
// ({"event": ...}). WKWebView objects here are stand-ins that forward every
// call over the socket; no browser runs inside the Darwin process. Without
// the socket nothing here is installed. Every class is declared here with
// the methods used: the Darling runtime ships no headers.

typedef struct objc_class *Class;
typedef struct objc_object { Class isa; } *id;
typedef struct objc_selector *SEL;
typedef struct objc_method *Method;
typedef void (*IMP)(void);
typedef signed char BOOL;
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef struct { double x, y; } NSPoint;
typedef struct { double width, height; } NSSize;
typedef struct { NSPoint origin; NSSize size; } NSRect;
typedef struct { NSUInteger location, length; } NSRange;
#define YES 1
#define NO 0
#define nil ((id)0)

extern Class objc_getClass(const char *);
extern Class object_getClass(id);
extern SEL sel_registerName(const char *);
extern Method class_getInstanceMethod(Class, SEL);
extern Method class_getClassMethod(Class, SEL);
extern IMP method_setImplementation(Method, IMP);
extern BOOL class_addMethod(Class, SEL, IMP, const char *);
static id webViewAllocWithZone(id cls, SEL selector, void *zone);
extern id objc_getAssociatedObject(id, const void *);
extern void objc_setAssociatedObject(id, const void *, id, unsigned long);
extern id objc_storeWeak(id *, id);
extern id objc_loadWeakRetained(id *);
extern void objc_destroyWeak(id *);
extern char *getenv(const char *);
extern unsigned long strlen(const char *);
extern void *memchr(const void *, int, unsigned long);
extern int socket(int, int, int);
extern int connect(int, const void *, unsigned int);
extern int setsockopt(int, int, int, const void *, unsigned int);
extern int getsockopt(int, int, int, void *, unsigned int *);
extern int fcntl(int, int, ...);
extern long read(int, void *, unsigned long);
extern long write(int, const void *, unsigned long);
extern int close(int);
extern int *__error(void);
extern void *_Block_copy(const void *);
extern void _Block_release(const void *);
extern struct dispatch_queue_s _dispatch_main_q;
extern void dispatch_async(void *, void (^)(void));
#define errno (*__error())
#define EAGAIN 35
#define EINTR 4
#define EINPROGRESS 36
#define EALREADY 37
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOL_SOCKET 0xffff
#define SO_NOSIGPIPE 0x1022
#define SO_ERROR 0x1007
#define F_GETFL 3
#define F_SETFL 4
#define O_NONBLOCK 4
struct sockaddr_un { unsigned char sun_len, sun_family; char sun_path[104]; };
struct pollfd { int fd; short events, revents; };
extern int poll(struct pollfd *, unsigned int, int);
#define POLLOUT 4
#define POLLERR 8
#define POLLHUP 16
extern const void *CFURLCreateWithFileSystemPathRelativeToBase(const void *, id, long, BOOL, const void *);

@interface NSObject { Class isa; }
+ (id)alloc; + (id)new; + (Class)class; - (id)init; - (id)copy; - (id)mutableCopy;
- (id)retain; - (void)release; - (id)autorelease; - (void)dealloc;
- (BOOL)isKindOfClass:(Class)cls; - (BOOL)respondsToSelector:(SEL)selector; - (BOOL)isEqual:(id)other;
@end
@interface NSString : NSObject
+ (id)stringWithUTF8String:(const char *)text; + (id)stringWithFormat:(NSString *)format, ...;
- (const char *)UTF8String; - (NSUInteger)length; - (id)lowercaseString; - (BOOL)isEqualToString:(NSString *)other;
@end
@interface NSNumber : NSObject
+ (id)numberWithLong:(long)value; + (id)numberWithBool:(BOOL)value; + (id)numberWithDouble:(double)value;
+ (id)numberWithInt:(int)value; + (id)numberWithUnsignedLong:(unsigned long)value;
- (long)longValue; - (BOOL)boolValue; - (double)doubleValue;
@end
@interface NSArray : NSObject
+ (id)array;
+ (id)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
- (NSUInteger)count; - (id)objectAtIndex:(NSUInteger)index; - (id)objectAtIndexedSubscript:(NSUInteger)index;
- (id)lastObject; - (id)sortedArrayUsingDescriptors:(NSArray *)order;
@end
@interface NSMutableArray : NSArray
+ (id)array; - (void)addObject:(id)object; - (void)removeObjectAtIndex:(NSUInteger)index;
- (void)removeAllObjects;
@end
@interface NSDictionary : NSObject
+ (id)dictionary;
+ (id)dictionaryWithObjects:(const id *)objects forKeys:(const id *)keys count:(NSUInteger)count;
- (id)objectForKey:(id)key; - (id)objectForKeyedSubscript:(id)key; - (NSArray *)allKeys;
@end
@interface NSMutableDictionary : NSDictionary
+ (id)dictionary; + (id)dictionaryWithDictionary:(NSDictionary *)other;
- (void)setObject:(id)object forKey:(id)key; - (void)setObject:(id)object forKeyedSubscript:(id)key;
- (void)removeObjectForKey:(id)key;
@end
@interface NSData : NSObject
+ (id)dataWithBytes:(const void *)bytes length:(NSUInteger)length;
- (const void *)bytes; - (NSUInteger)length;
@end
@interface NSMutableData : NSData
+ (id)new; - (void)appendBytes:(const void *)bytes length:(NSUInteger)length;
- (void)replaceBytesInRange:(NSRange)range withBytes:(const void *)bytes length:(NSUInteger)length;
- (void)setLength:(NSUInteger)length;
@end
@interface NSJSONSerialization : NSObject
+ (id)dataWithJSONObject:(id)object options:(NSUInteger)options error:(id *)error;
+ (id)JSONObjectWithData:(NSData *)data options:(NSUInteger)options error:(id *)error;
@end
@interface NSDate : NSObject
+ (id)date; + (id)dateWithTimeIntervalSince1970:(double)seconds; - (double)timeIntervalSince1970;
@end
@interface NSError : NSObject
+ (id)errorWithDomain:(NSString *)domain code:(NSInteger)code userInfo:(NSDictionary *)info;
@end
@interface NSURL : NSObject
+ (id)URLWithString:(NSString *)text; - (NSString *)absoluteString; - (NSString *)scheme; - (NSString *)host; - (NSString *)path;
@end
@interface NSURLRequest : NSObject
+ (id)requestWithURL:(NSURL *)url; - (NSURL *)URL; - (NSDictionary *)allHTTPHeaderFields;
@end
@interface NSHTTPCookie : NSObject
+ (id)cookieWithProperties:(NSDictionary *)properties;
- (NSString *)name; - (NSString *)value; - (NSString *)domain; - (NSString *)path;
- (NSDictionary *)properties; - (NSDate *)expiresDate;
@end
@interface NSThread : NSObject
+ (BOOL)isMainThread;
@end
@interface NSTimer : NSObject
+ (id)scheduledTimerWithTimeInterval:(double)seconds target:(id)target selector:(SEL)selector userInfo:(id)info repeats:(BOOL)repeats;
+ (id)timerWithTimeInterval:(double)seconds target:(id)target selector:(SEL)selector userInfo:(id)info repeats:(BOOL)repeats;
@end
@interface NSRunLoop : NSObject
+ (id)mainRunLoop; - (void)addTimer:(id)timer forMode:(id)mode;
@end
extern NSString *NSRunLoopCommonModes;
@interface NSFileManager : NSObject
+ (id)defaultManager; - (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)directory;
@end
@interface NSView : NSObject
- (id)initWithFrame:(NSRect)frame; - (void)viewDidMoveToWindow; - (id)window; - (void)removeFromSuperview;
- (id)superview; - (NSRect)bounds; - (void)setFrame:(NSRect)frame; - (void)setAutoresizingMask:(NSUInteger)mask;
@end
@interface NSWindow : NSObject
- (NSRect)frame; - (BOOL)isVisible; - (id)platformWindow;
@end
@interface NSPanel : NSWindow
@end
@interface NSApplication : NSObject
- (NSArray *)windows; - (id)delegate;
@end
extern NSApplication *NSApp;
@interface NSImage : NSObject
- (id)initWithSize:(NSSize)size; - (void)setFlipped:(BOOL)flipped; - (void)lockFocus; - (void)unlockFocus;
@end
@interface NSButton : NSView
- (void)setTitle:(NSString *)title; - (void)setImage:(NSImage *)image; - (void)setTarget:(id)target;
- (void)setAction:(SEL)action; - (void)setBordered:(BOOL)bordered;
@end
@interface NSAnimationContext : NSObject
@end
@interface NSObject (MacNCheeseWebHost)
- (unsigned long)windowHandle; - (id)getView; - (void)macncheeseCloseHostedView;
- (id)configuration; - (id)userContentController;
- (void)webView:(id)view didStartProvisionalNavigation:(id)navigation;
- (void)webView:(id)view didCommitNavigation:(id)navigation;
- (void)webView:(id)view didFinishNavigation:(id)navigation;
- (void)webView:(id)view didFailProvisionalNavigation:(id)navigation withError:(id)error;
- (void)webView:(id)view decidePolicyForNavigationAction:(id)action decisionHandler:(void (^)(long))handler;
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message;
- (void)closeButtonAction:(id)sender;
- (id)title;
- (void)application:(id)application openURLs:(NSArray *)urls;
@end

#define NSLocalizedDescriptionKey @"NSLocalizedDescription"
#define OBJC_ASSOCIATION_RETAIN_NONATOMIC 1

static int connection = -1;
static BOOL connecting;
static double connectDeadline, retryAfter;
static NSMutableData *received;
static NSMutableArray *outgoing;
static NSWindow *gameWindow;
static NSMutableDictionary *views, *callbacks;
static long nextView, nextRequest;
static void receiveMessage(NSDictionary *message);
static void failRequests(id view, NSString *reason);

static double bridgeTime(void) { return [[NSDate date] timeIntervalSince1970]; }
static void initializeBridge(void) {
    if (!received) received = [NSMutableData new];
    if (!outgoing) outgoing = [NSMutableArray new];
    if (!views) views = [NSMutableDictionary new];
    if (!callbacks) callbacks = [NSMutableDictionary new];
}
static void disconnectBridge(NSString *reason) {
    if (connection >= 0) close(connection);
    connection = -1;
    connecting = NO;
    retryAfter = bridgeTime() + 1.0;
    /* Frames belong to one stream. A suffix from a partial write must never
     * be replayed on a new connection as though it were a complete JSON line. */
    [received setLength:0];
    [outgoing removeAllObjects];
    failRequests(nil, reason);
}

static const char *socketPath(void) {
    const char *path = getenv("MACNCHEESE_WEB_SOCKET");
    return path && *path ? path : 0;
}

static BOOL sendMessage(NSDictionary *message) {
    if (!socketPath())
        return NO;
    if (![NSThread isMainThread]) {
        dispatch_async(&_dispatch_main_q, ^{ sendMessage(message); });
        return YES;
    }
    initializeBridge();
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:0];
    if (!json || [json length] > 1024 * 1024 || [outgoing count] >= 128)
        return NO;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    [outgoing addObject:line];
    [line release];
    return YES;
}

// The visible page and its toolbar are laid out by the launcher's window;
// keep Roblox's container view sized for its callbacks, without Auto Layout.
static void hostedViewLayout(id self, SEL selector) {
    (void)selector;
    id view = [self getView];
    [view setFrame:[self bounds]];
    [view setAutoresizingMask:18];
}
static void (*removeHostedView)(id, SEL);
static void closeHostedView(id self, SEL selector) {
    // Cocotron calls removeFromSuperview even during the first addSubview.
    // Roblox's override tears down its script handlers: only when attached.
    if (![self superview])
        return;
    removeHostedView(self, selector);
}

@interface MacNCheeseWebBridge : NSObject
+ (void)tick:(id)timer;
@end
@implementation MacNCheeseWebBridge
+ (void)load {
    if (!socketPath())
        return;
    // WKWebView objects become stand-ins that talk to the launcher.
    Class webView = objc_getClass("WKWebView");
    if (webView)
        class_addMethod(object_getClass((id)webView), sel_registerName("allocWithZone:"),
                        (IMP)webViewAllocWithZone, "@@:^v");
    dispatch_async(&_dispatch_main_q, ^{
        initializeBridge();
        id timer = [NSTimer timerWithTimeInterval:0.02 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        write(2, "[MacNCheese Web] Embedded pages open in the launcher's browser window\n", 68);
    });
}
+ (void)tick:(id)timer {
    (void)timer;
    initializeBridge();
    double now = bridgeTime();
    NSArray *keys = [callbacks allKeys];
    for (NSUInteger i = 0; i < [keys count]; i++) {
        id key = [keys objectAtIndex:i];
        if ([callbacks[key][@"deadline"] doubleValue] <= now)
            receiveMessage(@{@"event": @"reply", @"request": key, @"error": @"The embedded browser request timed out."});
    }
    static BOOL adapted = NO;
    if (!adapted) {
        Method layout = class_getInstanceMethod(objc_getClass("EmbeddedWebView"), sel_registerName("setupConstraints"));
        if (layout) {
            method_setImplementation(layout, (IMP)hostedViewLayout);
            Method remove = class_getInstanceMethod(objc_getClass("EmbeddedWebView"), sel_registerName("removeFromSuperview"));
            if (remove)
                removeHostedView = (void (*)(id, SEL))method_setImplementation(remove, (IMP)closeHostedView);
            adapted = YES;
        }
    }
    if (connection < 0) {
        if (now < retryAfter) return;
        const char *path = socketPath();
        struct sockaddr_un address = {0, AF_UNIX, {0}};
        if (!path || strlen(path) >= sizeof address.sun_path)
            return;
        for (unsigned long i = 0; path[i]; i++)
            address.sun_path[i] = path[i];
        address.sun_len = sizeof address;
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0)
            return;
        int flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            close(fd);
            return;
        }
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
        int result = connect(fd, &address, sizeof address);
        if (result && errno != EINPROGRESS && errno != EALREADY) {
            close(fd);
            retryAfter = now + 1.0;
            return;
        }
        connection = fd;
        connecting = result != 0;
        connectDeadline = now + 5.0;
    }
    if (connecting) {
        struct pollfd state = {connection, POLLOUT, 0};
        int result = poll(&state, 1, 0);
        if (now >= connectDeadline || result < 0 || (state.revents & (POLLERR | POLLHUP))) {
            disconnectBridge(@"The embedded browser connection failed.");
            return;
        }
        if (result == 0 || !(state.revents & POLLOUT)) return;
        int error = 0;
        unsigned int size = sizeof error;
        if (getsockopt(connection, SOL_SOCKET, SO_ERROR, &error, &size) || error) {
            disconnectBridge(@"The embedded browser connection failed.");
            return;
        }
        connecting = NO;
    }
    if (!gameWindow) {
        NSArray *windows = [NSApp windows];
        for (NSUInteger i = 0; i < [windows count]; i++) {
            NSWindow *w = [windows objectAtIndex:i];
            if ([w isVisible] && ![w isKindOfClass:[NSPanel class]] &&
                [w frame].size.width > 400 && [w frame].size.height > 300) {
                gameWindow = [w retain];
                sendMessage(@{@"op": @"attach", @"window": @([[w platformWindow] windowHandle])});
                break;
            }
        }
    }
    while ([outgoing count]) {
        NSMutableData *line = [outgoing objectAtIndex:0];
        long n = write(connection, [line bytes], [line length]);
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
            break;
        if (n <= 0) {
            disconnectBridge(@"The embedded browser disconnected.");
            return;
        }
        NSRange done = {0, (NSUInteger)n};
        [line replaceBytesInRange:done withBytes:0 length:0];
        if (![line length])
            [outgoing removeObjectAtIndex:0];
    }
    char buffer[8192];
    long n;
    while ((n = read(connection, buffer, sizeof buffer)) > 0)
        [received appendBytes:buffer length:(NSUInteger)n];
    if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) || [received length] > 1024 * 1024) {
        disconnectBridge(@"The embedded browser disconnected.");
        return;
    }
    for (;;) {
        const char *bytes = [received bytes];
        const char *end = memchr(bytes, '\n', [received length]);
        if (!end)
            break;
        NSUInteger length = (NSUInteger)(end - bytes);
        NSData *line = [NSData dataWithBytes:bytes length:length];
        NSRange consumed = {0, length + 1};
        [received replaceBytesInRange:consumed withBytes:0 length:0];
        id message = [NSJSONSerialization JSONObjectWithData:line options:0 error:0];
        if ([message isKindOfClass:[NSDictionary class]])
            receiveMessage(message);
    }
}
@end

// roblox:// and roblox-player:// links (server joins, follow-user, launch
// tickets) go to the running client's URL handler, never to the host.
static BOOL clientURL(const char *url) {
    if (!url || strlen(url) > 16384)
        return NO;
    for (const unsigned char *p = (const unsigned char *)url; *p; p++)
        if (*p < 32 || *p == 127)
            return NO;
    static const char *const schemes[] = {"roblox:", "roblox-player:"};
    for (int s = 0; s < 2; s++) {
        unsigned long i = 0;
        for (; schemes[s][i]; i++) {
            char c = url[i];
            if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
            if (c != schemes[s][i]) break;
        }
        if (!schemes[s][i] && url[i])
            return YES;
    }
    return NO;
}
static BOOL deliverClientURL(id value) {
    if (![value isKindOfClass:[NSString class]] || !clientURL([value UTF8String]))
        return NO;
    NSURL *url = [NSURL URLWithString:value];
    if (!url)
        return NO;
    if (![NSThread isMainThread]) {
        dispatch_async(&_dispatch_main_q, ^{ deliverClientURL(value); });
        return YES;
    }
    id delegate = [NSApp delegate];
    if (![delegate respondsToSelector:@selector(application:openURLs:)])
        return NO;
    [delegate application:NSApp openURLs:@[url]];
    return YES;
}

// -[NSWorkspace openURL:], from libMacNCheeseShims.m: 1 when handled here.
int macncheese_web_open_url(id url) {
    NSString *text = [url absoluteString];
    if (deliverClientURL(text))
        return 1;
    NSString *scheme = [[url scheme] lowercaseString];
    if (!socketPath() || connection < 0 || !([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) || ![[url host] length])
        return 0;
    return sendMessage(@{@"op": @"load", @"view": @0, @"url": text});
}

// ---------------------------------------------------------------- AppKit gaps
// Methods Roblox's web-view chrome uses that Darling's AppKit lacks.
@implementation NSButton (MacNCheeseWebChrome)
+ (id)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action {
    NSButton *button = [[[self alloc] initWithFrame:(NSRect){{0, 0}, {100, 28}}] autorelease];
    [button setTitle:title];
    [button setTarget:target];
    [button setAction:action];
    return button;
}
@end
@implementation NSImage (MacNCheeseWebChrome)
+ (id)imageWithSize:(NSSize)size flipped:(BOOL)flipped drawingHandler:(BOOL (^)(NSRect))draw {
    NSImage *image = [[[self alloc] initWithSize:size] autorelease];
    [image setFlipped:flipped];
    [image lockFocus];
    @try {
        draw((NSRect){{0, 0}, size});
    } @finally {
        [image unlockFocus];
    }
    return image;
}
@end
@implementation NSAnimationContext (MacNCheeseWebChrome)
+ (void)runAnimationGroup:(void (^)(id))changes completionHandler:(void (^)(void))completion {
    // Darling's animator applies properties immediately; still complete.
    id context = [[[self alloc] init] autorelease];
    if (changes) changes(context);
    if (completion) completion();
}
@end
@implementation NSURL (MacNCheeseWebChrome)
+ (id)fileURLWithPath:(NSString *)path isDirectory:(BOOL)directory relativeToURL:(NSURL *)base {
    return [(id)CFURLCreateWithFileSystemPathRelativeToBase(0, (id)path, 0 /* POSIX */, directory, base) autorelease];
}
+ (id)fileURLWithPath:(NSString *)path relativeToURL:(NSURL *)base {
    NSURL *url = [self fileURLWithPath:path isDirectory:NO relativeToURL:base];
    BOOL directory = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&directory];
    return directory ? [self fileURLWithPath:path isDirectory:YES relativeToURL:base] : url;
}
@end

// ------------------------------------------------------------- WKWebView
static char stateKey;
static NSMutableDictionary *stateFor(id object) {
    NSMutableDictionary *state = (NSMutableDictionary *)objc_getAssociatedObject(object, &stateKey);
    if (!state) {
        state = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(object, &stateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}
static BOOL validUserAgent(NSString *agent) {
    const unsigned char *p = (const unsigned char *)[agent UTF8String];
    if (!p || !*p)
        return NO;
    for (; *p; p++)
        if (*p < 32 || *p > 126)
            return NO;
    return YES;
}
static void enqueueRequest(long number, NSMutableDictionary *message, void (^completion)(id, NSError *)) {
    initializeBridge();
    if (completion) {
        id block = (id)_Block_copy(completion);
        callbacks[@(number)] = @{@"block": block, @"deadline": @(bridgeTime() + 15.0),
                                  @"view": message[@"view"] ?: @0};
        _Block_release(block);
    }
    [message setObject:@(number) forKey:@"request"];
    if (!sendMessage(message))
        receiveMessage(@{@"event": @"reply", @"request": @(number), @"error": @"The embedded browser request could not be sent."});
}
static long request(NSMutableDictionary *message, void (^completion)(id, NSError *)) {
    long number = __atomic_add_fetch(&nextRequest, 1, __ATOMIC_RELAXED);
    if ([NSThread isMainThread]) enqueueRequest(number, message, completion);
    else dispatch_async(&_dispatch_main_q, ^{ enqueueRequest(number, message, completion); });
    [message release];
    return number;
}
static void failRequests(id view, NSString *reason) {
    NSArray *keys = [callbacks allKeys];
    for (NSUInteger i = 0; i < [keys count]; i++) {
        id key = [keys objectAtIndex:i];
        if (!view || [callbacks[key][@"view"] isEqual:view])
            receiveMessage(@{@"event": @"reply", @"request": key, @"error": reason});
    }
}

@interface NSButton (MacNCheeseWebTint)
@end
@implementation NSButton (MacNCheeseWebTint)
// The hosted browser toolbar is drawn by the launcher, which applies its theme.
- (void)setContentTintColor:(id)color {
    if (color) stateFor(self)[@"contentTintColor"] = color;
    else [stateFor(self) removeObjectForKey:@"contentTintColor"];
}
- (id)contentTintColor { return stateFor(self)[@"contentTintColor"]; }
@end
@implementation NSAnimationContext (MacNCheeseWebState)
- (void)setDuration:(double)duration { stateFor(self)[@"duration"] = @(duration); }
- (double)duration { return [stateFor(self)[@"duration"] doubleValue]; }
- (void)setTimingFunction:(id)function { if (function) stateFor(self)[@"timing"] = function; }
@end

@interface WKWebView : NSObject @end
@interface WKWebViewConfiguration : NSObject @end
@interface WKPreferences : NSObject @end
@interface WKUserContentController : NSObject @end
@interface WKWebsiteDataStore : NSObject
+ (id)defaultDataStore;
@end
@interface WKHTTPCookieStore : NSObject @end
@interface WKUserScript : NSObject @end

@implementation WKWebViewConfiguration (MacNCheeseWeb)
- (id)preferences {
    id p = stateFor(self)[@"preferences"];
    if (!p) stateFor(self)[@"preferences"] = p = [[[WKPreferences alloc] init] autorelease];
    return p;
}
- (id)userContentController {
    id p = stateFor(self)[@"controller"];
    if (!p) stateFor(self)[@"controller"] = p = [[[WKUserContentController alloc] init] autorelease];
    return p;
}
- (void)setUserContentController:(id)value { stateFor(self)[@"controller"] = value; }
- (id)websiteDataStore { return [WKWebsiteDataStore defaultDataStore]; }
- (void)setApplicationNameForUserAgent:(id)value { if (value) stateFor(self)[@"agent"] = value; }
- (id)applicationNameForUserAgent { return stateFor(self)[@"agent"]; }
@end
@implementation WKPreferences (MacNCheeseWeb)
- (void)setValue:(id)value forKey:(NSString *)key { if (value) stateFor(self)[key] = value; }
- (id)valueForKey:(NSString *)key { return stateFor(self)[key]; }
@end
@implementation WKWebsiteDataStore (MacNCheeseWeb)
+ (id)defaultDataStore { static id store; if (!store) store = [self new]; return store; }
- (id)httpCookieStore { static id store; if (!store) store = [WKHTTPCookieStore new]; return store; }
@end
@implementation WKHTTPCookieStore (MacNCheeseWeb)
- (void)setCookie:(NSHTTPCookie *)cookie completionHandler:(void (^)(void))completion {
    NSMutableDictionary *c = [NSMutableDictionary dictionaryWithDictionary:@{
        @"name": [cookie name], @"value": [cookie value], @"domain": [cookie domain], @"path": [cookie path],
        @"secure": @([[[cookie properties] objectForKey:@"Secure"] boolValue]),
        @"httpOnly": @([[[cookie properties] objectForKey:@"HTTPOnly"] boolValue])}];
    if ([cookie expiresDate])
        c[@"expires"] = @([[cookie expiresDate] timeIntervalSince1970]);
    request([@{@"op": @"cookie-set", @"cookie": c} mutableCopy], ^(id value, NSError *error) {
        (void)value; (void)error;
        if (completion) completion();
    });
}
- (void)getAllCookies:(void (^)(NSArray *))completion {
    request([@{@"op": @"cookies-get"} mutableCopy], ^(id value, NSError *error) {
        (void)error;
        NSMutableArray *cookies = [NSMutableArray array];
        NSArray *list = [value isKindOfClass:[NSArray class]] ? value : [NSArray array];
        for (NSUInteger i = 0; i < [list count]; i++) {
            NSDictionary *c = [list objectAtIndex:i];
            if (![c isKindOfClass:[NSDictionary class]] || !c[@"name"] || !c[@"value"] || !c[@"domain"] || !c[@"path"])
                continue;
            NSMutableDictionary *props = [NSMutableDictionary dictionaryWithDictionary:@{
                @"Name": c[@"name"], @"Value": c[@"value"], @"Domain": c[@"domain"], @"Path": c[@"path"], @"Version": @0}];
            if ([c[@"secure"] boolValue]) props[@"Secure"] = @YES;
            if ([c[@"httpOnly"] boolValue]) props[@"HTTPOnly"] = @YES;
            if (c[@"expires"]) props[@"Expires"] = [NSDate dateWithTimeIntervalSince1970:[c[@"expires"] doubleValue]];
            NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
            if (cookie) [cookies addObject:cookie];
        }
        if (completion) completion(cookies);
    });
}
@end
@implementation WKUserScript (MacNCheeseWeb)
- (id)initWithSource:(NSString *)source injectionTime:(long)time forMainFrameOnly:(BOOL)main {
    self = [self init];
    if (source) stateFor(self)[@"script"] = source;
    stateFor(self)[@"atEnd"] = @(time == 1);
    stateFor(self)[@"mainOnly"] = @(main);
    return self;
}
@end
@implementation WKUserContentController (MacNCheeseWeb)
- (void)addScriptMessageHandler:(id)handler name:(NSString *)name {
    NSMutableDictionary *handlers = stateFor(self)[@"handlers"];
    if (!handlers) stateFor(self)[@"handlers"] = handlers = [NSMutableDictionary dictionary];
    if (handler && name) handlers[name] = handler;
}
- (void)removeScriptMessageHandlerForName:(NSString *)name { if (name) [stateFor(self)[@"handlers"] removeObjectForKey:name]; }
- (void)addUserScript:(id)script {
    NSMutableArray *scripts = stateFor(self)[@"scripts"];
    if (!scripts) stateFor(self)[@"scripts"] = scripts = [NSMutableArray array];
    if (script) [scripts addObject:script];
}
@end

@interface MacNCheeseFrameInfo : NSObject { @public NSURLRequest *_request; }
@end
@implementation MacNCheeseFrameInfo
- (id)request { return _request; }
- (void)dealloc { [_request release]; [super dealloc]; }
@end
@interface MacNCheeseNavigation : NSObject { @public NSURLRequest *_request; long _type; }
@end
@implementation MacNCheeseNavigation
- (NSURLRequest *)request { return _request; }
- (long)navigationType { return _type; }
- (id)targetFrame {
    // New-window requests are handled by the launcher; these actions target
    // an existing frame. nil would tell Roblox to open an external browser.
    MacNCheeseFrameInfo *frame = [[[MacNCheeseFrameInfo alloc] init] autorelease];
    frame->_request = [_request retain];
    return frame;
}
- (id)sourceFrame { return nil; }
- (void)dealloc { [_request release]; [super dealloc]; }
@end
@interface MacNCheeseScriptMessage : NSObject { @public id _body; NSString *_name; id _webView; }
@end
@implementation MacNCheeseScriptMessage
- (id)body { return _body; }
- (id)name { return _name; }
- (id)webView { return _webView; }
- (id)frameInfo { return nil; }
- (void)dealloc { [_body release]; [_name release]; [_webView release]; [super dealloc]; }
@end

@interface MacNCheeseWebView : NSView {
  @public
    long _id;
    id _configuration, _navigationDelegate, _UIDelegate;
    NSURL *_URL;
    NSString *_title;
    BOOL _loading, _back, _forward, _attached;
    id _navigation;
}
- (id)initWithFrame:(NSRect)frame configuration:(id)configuration;
- (void)macncheeseCloseHostedView;
@end
// Installed by +[MacNCheeseWebBridge load], only when the launcher listens:
// without it Roblox keeps Darling's WKWebView.
static id webViewAllocWithZone(id cls, SEL selector, void *zone) {
    (void)cls; (void)selector; (void)zone;
    return (id)[MacNCheeseWebView alloc];
}
@implementation MacNCheeseWebView
- (id)initWithFrame:(NSRect)frame {
    return [self initWithFrame:frame configuration:[[[WKWebViewConfiguration alloc] init] autorelease]];
}
- (id)initWithFrame:(NSRect)frame configuration:(id)configuration {
    self = [super initWithFrame:frame];
    if (self) {
        initializeBridge();
        _id = ++nextView;
        _configuration = [configuration retain];
        views[@(_id)] = self;
    }
    return self;
}
- (id)configuration { return _configuration; }
- (void)setNavigationDelegate:(id)delegate { objc_storeWeak(&_navigationDelegate, delegate); }
- (id)navigationDelegate { return [objc_loadWeakRetained(&_navigationDelegate) autorelease]; }
- (void)setUIDelegate:(id)delegate { objc_storeWeak(&_UIDelegate, delegate); }
- (id)UIDelegate { return [objc_loadWeakRetained(&_UIDelegate) autorelease]; }
- (NSURL *)URL { return _URL; }
- (NSString *)title { return _title; }
- (BOOL)isLoading { return _loading; }
- (double)estimatedProgress { return _loading ? 0.1 : 1.0; }
- (BOOL)canGoBack { return _back; }
- (BOOL)canGoForward { return _forward; }
- (NSString *)customUserAgent { return stateFor(self)[@"customAgent"]; }
- (NSString *)userAgent {
    NSString *custom = [self customUserAgent];
    if (validUserAgent(custom))
        return custom;
    const char *base = getenv("MACNCHEESE_WEB_USER_AGENT");
    NSString *baseText = [NSString stringWithUTF8String:base ? base : ""];
    NSString *application = [_configuration applicationNameForUserAgent];
    return validUserAgent(application) ? [NSString stringWithFormat:@"%@ %@", baseText, application] : baseText;
}
- (void)setCustomUserAgent:(NSString *)agent {
    if (agent) stateFor(self)[@"customAgent"] = [[agent copy] autorelease];
    else [stateFor(self) removeObjectForKey:@"customAgent"];
    sendMessage(@{@"op": @"user-agent", @"view": @(_id), @"agent": [self userAgent]});
}
- (void)setUserAgent:(NSString *)agent { [self setCustomUserAgent:agent]; }
- (id)loadRequest:(NSURLRequest *)urlRequest {
    BOOL delivered = YES;
    id controller = [_configuration userContentController];
    NSDictionary *handlers = stateFor(controller)[@"handlers"];
    NSArray *names = handlers ? [(id)handlers allKeys] : [NSArray array];
    for (NSUInteger i = 0; i < [names count]; i++)
        delivered &= sendMessage(@{@"op": @"handler", @"view": @(_id), @"name": [names objectAtIndex:i]});
    NSArray *scripts = stateFor(controller)[@"scripts"];
    for (NSUInteger i = 0; i < [scripts count]; i++) {
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:stateFor([scripts objectAtIndex:i])];
        m[@"op"] = @"script";
        m[@"view"] = @(_id);
        delivered &= sendMessage(m);
    }
    [_navigation release];
    _navigation = [NSObject new];
    id delegate = [self navigationDelegate];
    id title = [delegate respondsToSelector:@selector(title)] ? [delegate title] : nil;
    NSString *url = [[urlRequest URL] absoluteString];
    if (url) {
        delivered &= sendMessage(@{@"op": @"load", @"view": @(_id), @"url": url,
                  @"headers": [urlRequest allHTTPHeaderFields] ?: [NSDictionary dictionary],
                  @"panelTitle": [title isKindOfClass:[NSString class]] ? title : @"",
                  @"delegate": @([delegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]),
                  @"agent": [self userAgent]});
    } else {
        delivered = NO;
    }
    _loading = delivered;
    if (!delivered) {
        id navigation = _navigation;
        dispatch_async(&_dispatch_main_q, ^{
            // Another load or a closed view supersedes this navigation.
            if (views[@(_id)] != self || _navigation != navigation)
                return;
            _loading = NO;
            id currentDelegate = [self navigationDelegate];
            if ([currentDelegate respondsToSelector:@selector(webView:didFailProvisionalNavigation:withError:)])
                [currentDelegate webView:self didFailProvisionalNavigation:navigation
                    withError:[NSError errorWithDomain:@"MacNCheeseWeb" code:1
                        userInfo:@{NSLocalizedDescriptionKey: @"The embedded page could not be sent to the browser."}]];
        });
    }
    return _navigation;
}
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))completion {
    if (!script) { if (completion) completion(nil, nil); return; }
    request([@{@"op": @"eval", @"view": @(_id), @"script": script} mutableCopy], completion);
}
- (id)goBack { sendMessage(@{@"op": @"back", @"view": @(_id)}); return _navigation; }
- (id)goForward { sendMessage(@{@"op": @"forward", @"view": @(_id)}); return _navigation; }
- (id)reload { sendMessage(@{@"op": @"reload", @"view": @(_id)}); return _navigation; }
- (void)stopLoading { sendMessage(@{@"op": @"stop", @"view": @(_id)}); }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    BOOL attached = [self window] != nil;
    if (_attached && !attached)
        [self macncheeseCloseHostedView];
    _attached = attached;
}
- (void)macncheeseCloseHostedView {
    if (views[@(_id)] != self)
        return;
    [self retain];
    sendMessage(@{@"op": @"close", @"view": @(_id)});
    [self setNavigationDelegate:nil];
    [self setUIDelegate:nil];
    [views removeObjectForKey:@(_id)];
    failRequests(@(_id), @"The embedded page was closed.");
    [self release];
}
- (void)removeFromSuperview {
    if ([self superview])
        [self macncheeseCloseHostedView];
    [super removeFromSuperview];
}
- (void)dealloc {
    objc_destroyWeak(&_navigationDelegate);
    objc_destroyWeak(&_UIDelegate);
    [_configuration release]; [_URL release]; [_title release]; [_navigation release];
    [super dealloc];
}
@end

static void receiveMessage(NSDictionary *message) {
    NSString *type = message[@"event"];
    if ([type isEqual:@"launch-url"]) {
        if (deliverClientURL(message[@"url"]))
            sendMessage(@{@"op": @"return-to-game"});
        else
            write(2, "[MacNCheese Web] A launch link from the page could not be delivered\n", 66);
        return;
    }
    if ([type isEqual:@"reply"]) {
        id key = message[@"request"];
        if (!key)
            return;
        void (^block)(id, NSError *) = (void (^)(id, NSError *))_Block_copy(callbacks[key][@"block"]);
        [callbacks removeObjectForKey:key];
        if (block) {
            NSError *error = message[@"error"]
                ? [NSError errorWithDomain:@"MacNCheeseWeb" code:1 userInfo:@{NSLocalizedDescriptionKey: message[@"error"]}]
                : nil;
            block(message[@"value"], error);
            _Block_release(block);
        }
        return;
    }
    MacNCheeseWebView *view = views[message[@"view"]];
    if (!view)
        return;
    id delegate = [view navigationDelegate];
    if ([type isEqual:@"state"]) {
        [view->_URL release];
        view->_URL = [[NSURL URLWithString:message[@"url"]] retain];
        [view->_title release];
        view->_title = [message[@"title"] copy];
        view->_back = [message[@"back"] boolValue];
        view->_forward = [message[@"forward"] boolValue];
        view->_loading = [message[@"loading"] boolValue];
    } else if ([type isEqual:@"load"]) {
        long stage = [message[@"stage"] longValue];
        view->_loading = stage != 3;
        if (stage == 0 && [delegate respondsToSelector:@selector(webView:didStartProvisionalNavigation:)])
            [delegate webView:view didStartProvisionalNavigation:view->_navigation];
        if (stage == 2 && [delegate respondsToSelector:@selector(webView:didCommitNavigation:)])
            [delegate webView:view didCommitNavigation:view->_navigation];
        if (stage == 3 && [delegate respondsToSelector:@selector(webView:didFinishNavigation:)])
            [delegate webView:view didFinishNavigation:view->_navigation];
    } else if ([type isEqual:@"navigation"]) {
        MacNCheeseNavigation *action = [[[MacNCheeseNavigation alloc] init] autorelease];
        action->_request = [[NSURLRequest requestWithURL:[NSURL URLWithString:message[@"url"]]] retain];
        action->_type = [message[@"type"] longValue];
        if (action->_type == 5)
            action->_type = -1;
        id decision = message[@"decision"];
        void (^decide)(long) = ^(long allow) {
            sendMessage(@{@"op": @"policy", @"decision": decision ?: @0, @"allow": @(allow != 0)});
        };
        if ([delegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)])
            [delegate webView:view decidePolicyForNavigationAction:action decisionHandler:decide];
        else
            decide(1);
    } else if ([type isEqual:@"message"]) {
        id controller = [view->_configuration userContentController];
        id handler = [[stateFor(controller)[@"handlers"][message[@"name"]] retain] autorelease];
        if (!handler)
            return;
        MacNCheeseScriptMessage *m = [[[MacNCheeseScriptMessage alloc] init] autorelease];
        m->_body = [message[@"body"] retain];
        m->_name = [message[@"name"] copy];
        m->_webView = [view retain];
        [handler userContentController:controller didReceiveScriptMessage:m];
    } else if ([type isEqual:@"closed"]) {
        if ([delegate respondsToSelector:@selector(closeButtonAction:)])
            [delegate closeButtonAction:nil];
    } else if ([type isEqual:@"error"]) {
        view->_loading = NO;
        if ([delegate respondsToSelector:@selector(webView:didFailProvisionalNavigation:withError:)])
            [delegate webView:view didFailProvisionalNavigation:view->_navigation
                withError:[NSError errorWithDomain:@"MacNCheeseWeb" code:1
                                          userInfo:@{NSLocalizedDescriptionKey: message[@"message"] ?: @"The page could not be loaded."}]];
    }
}
