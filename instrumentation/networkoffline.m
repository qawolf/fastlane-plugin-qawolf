//
//  networkoffline.m
//  instrumentation
//
//  Makes the app under test's own reachability APIs report offline when
//  QAWolf's NETWORK_OFFLINE gateway condition is engaged, in addition to
//  the existing gateway-level packet loss — which the OS's own network
//  stack never sees on its own (the app still believes it has a valid
//  route, so its own SCNetworkReachability/NWPathMonitor calls keep
//  reporting online). See TASK.md in the offline-detection task for the
//  full investigation this is built on, including the dead ends ruled out
//  along the way (private Network.framework classes and its internal C
//  API calls are structurally unreachable via ObjC swizzling or fishhook
//  on a non-jailbroken device — confirmed by disassembly).
//
//  Two hook mechanisms, both plain fishhook symbol rebinding (no code
//  patching, no jailbreak):
//
//  1. SCNetworkReachabilityGetFlags — a normal C API import. Apps that
//     call it directly (classic Reachability wrappers, several
//     cross-platform bridges) get a real, rebindable reference in their
//     own compiled code, same pattern as keychain.m's SecItemCopyMatching
//     hook.
//
//  2. NWPath.status.getter — the Swift ABI *boundary* symbol
//     ($s7Network6NWPathV6statusAC6StatusOvg) that an app's own compiled
//     Swift code imports to cross into Network.framework. This is NOT
//     hooking Network.framework's internals (which is unreachable) — it's
//     hooking the app's own import of the entry point, exactly the same
//     "app calls system API directly" pattern as (1). Getting the
//     replacement's calling convention right required tracing the real
//     ABI by disassembly: Swift passes `self` via the dedicated x20
//     "swiftself" register (not x0), and returns NWPath.Status
//     indirectly via x8 (a caller-allocated buffer — Network.framework's
//     resilient/library-evolution ABI convention, even though the enum
//     itself is a tiny 3-case value), not in a register. Clang's
//     `swiftcall` convention plus explicit `swift_indirect_result`/
//     `swift_context` parameter attributes are required to call this
//     correctly — a plain C signature SIGBUSes on first real invocation.
//
//  Also hooked, same Swift ABI boundary/x20-self pattern as (2), but with a
//  direct-register Bool return (no x8 indirection — Bool is fixed-layout,
//  unlike the resilient NWPath.Status enum, confirmed by disassembly):
//    - NWPath.isExpensive.getter / NWPath.isConstrained.getter — forced to
//      NO when offline is active, matching a real unsatisfied path (nothing
//      to be expensive/constrained about with no interface at all).
//    - NWPath.usesInterfaceType(_:) — forced to NO when offline is active.
//      Its one parameter (NWInterface.InterfaceType) is itself a resilient
//      Network.framework type passed indirectly via a caller-allocated
//      buffer in x0 — irrelevant here since the override only ever touches
//      the Bool return, the parameter buffer is forwarded to the original
//      untouched either way.
//
//  Also hooked: nw_path_get_status, the C API's equivalent of (2) — real,
//  documented public function, same override logic, for apps whose own
//  code calls the C API directly rather than going through Swift.
//
//  Control channel: Documents/.qawolf/network.json, the same file-based
//  pattern used by the camera/keychain/location mocks (see filemonitor.m).
//    { "offline": true }   -> reachability APIs read as unreachable/unsatisfied
//    { "offline": false }  -> pass-through to the real value
//

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <Block.h>
#import "fishhook.h"
#import "utils.h"
#import "filemonitor.h"
#import "networkoffline.h"
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

// Best-effort guess at NWPath.Status's raw discriminant for .unsatisfied
// (Swift's automatic case-ordinal assignment for a plain enum: satisfied=0,
// unsatisfied=1, requiresConnection=2, in declaration order). Empirically
// confirmed on-device: passthrough consistently reads real=0 for
// .satisfied, and returning 1 under override correctly displays as
// "unsatisfied" through the app's own Swift switch statement.
#define QAW_SWIFT_NWPATH_STATUS_UNSATISFIED_GUESS ((uint8_t)1)

// Written from the file-watcher callback — filemonitor.m's dispatch_source
// runs on DISPATCH_TARGET_QUEUE_DEFAULT, a background GCD queue, NOT the
// main thread — and read from arbitrary hook call sites on whatever thread
// the app under test happens to call reachability APIs from. Atomic to make
// that cross-thread access well-defined, even though a plain BOOL is a
// single aligned byte and a torn/stale read was already mechanically very
// unlikely on arm64.
static atomic_bool gQAWNetworkOfflineActive = false;

// Push-event deliveries fired on every flip (defined below the control channel).
// Each reproduces one OS callback the app subscribes to but that a getter
// override alone never re-fires: the C nw_path_monitor block and the
// SCNetworkReachability callout. The Swift NWPathMonitor closure is delivered
// by QAWNetworkOfflineFireSyntheticUpdates.
static void QAWFireCPathUpdates(void);
static void QAWFireSCCallbacks(void);

#pragma mark - Synthetic NWPath update delivery
//
// Overriding the reachability *reads* (above/below) only takes effect the next
// time the app asks. An app that reacts to connectivity purely through
// NWPathMonitor's pathUpdateHandler (ServiceTitan's ConnectivityClient does)
// won't ask again until the OS delivers a real path change — e.g. unplugging
// the cable. To make the flag itself behave like that event, capture each
// monitor's handler closure and its start(queue:) queue, and when the flag
// flips, re-invoke the closure with the monitor's currentPath (whose .status
// read is already overridden). Same fishhook-the-app's-own-import approach as
// the getters; currentPath's getter and NWPath's metadata are resolved via
// dlsym since not every app imports currentPath directly (ServiceTitan does
// not, Trot does).

typedef struct { void *monitor; void *fn; void *ctx; void *queue; } QAWMonitorEntry;
// Registries grow on demand — no fixed cap. Big apps register many
// NWPathMonitors (Datadog, Firebase, gRPC, URLSession, Pusher, the app's own
// ConnectivityClient, ...); ServiceTitan alone has ~238. A fixed cap silently
// dropped the extras, including the one driving the offline banner, so a flip
// never reached them (GEN-2252). We hold a +1 on each captured monitor/ctx so
// we can re-fire it later, and release it when the app clears or replaces the
// handler so retention stays bounded to the app's live monitor set.
static QAWMonitorEntry *gQAWMonitors = NULL;
static int gQAWMonitorCount = 0;
static int gQAWMonitorCap = 0;
static pthread_mutex_t gQAWMonitorLock = PTHREAD_MUTEX_INITIALIZER;

// Grow *arr to hold at least count+1 elements of elemSize, doubling capacity.
// Returns false only on genuine allocation failure. Caller holds the matching
// registry lock. Shared by all three registries below.
static bool QAWGrowIfNeeded(void **arr, int *cap, int count, size_t elemSize) {
    if (count < *cap) return true;
    int newCap = *cap ? *cap * 2 : 16;
    void *grown = realloc(*arr, (size_t)newCap * elemSize);
    if (!grown) return false;
    *arr = grown;
    *cap = newCap;
    return true;
}

// NWPathMonitor.currentPath.getter: NWPath returned indirectly via x8, self in x20.
typedef __attribute__((swiftcall)) void (*QAWCurrentPathFn)(
    void * __attribute__((swift_indirect_result)) outPath,
    void * __attribute__((swift_context)) self);
// The captured handler: (NWPath) -> Void. NWPath passed indirectly in x0,
// closure context in the swiftself register x20.
typedef __attribute__((swiftcall)) void (*QAWPathClosureFn)(
    const void *path,
    void * __attribute__((swift_context)) ctx);
typedef struct { void *metadata; unsigned long state; } QAWMetaResp;
typedef __attribute__((swiftcall)) QAWMetaResp (*QAWMetaAccessorFn)(unsigned long request);
typedef void (*QAWSwiftRetainFn)(void *);

static QAWCurrentPathFn gQAWCurrentPathGetter = NULL;
static QAWSwiftRetainFn gQAWSwiftRetain = NULL;
static QAWSwiftRetainFn gQAWSwiftRelease = NULL; // balances gQAWSwiftRetain
static size_t gQAWNWPathStride = 0;
static size_t gQAWNWPathAlign = 16;
static bool gQAWSyntheticResolved = false;
static bool gQAWSyntheticAvailable = false;

static void QAWResolveSyntheticOnce(void) {
    if (gQAWSyntheticResolved) return;
    gQAWSyntheticResolved = true;
    gQAWSwiftRetain = (QAWSwiftRetainFn)dlsym(RTLD_DEFAULT, "swift_retain");
    gQAWSwiftRelease = (QAWSwiftRetainFn)dlsym(RTLD_DEFAULT, "swift_release");
    gQAWCurrentPathGetter = (QAWCurrentPathFn)dlsym(RTLD_DEFAULT, "$s7Network13NWPathMonitorC11currentPathAA0B0Vvg");
    QAWMetaAccessorFn meta = (QAWMetaAccessorFn)dlsym(RTLD_DEFAULT, "$s7Network6NWPathVMa");
    if (gQAWCurrentPathGetter && meta) {
        QAWMetaResp r = meta(0); // MetadataRequest: complete + blocking
        if (r.metadata) {
            // value witness table pointer sits one word before the metadata;
            // stride at offset 72, flags (low byte = alignment mask) at 80.
            void *vwt = *(void **)((uintptr_t)r.metadata - sizeof(void *));
            gQAWNWPathStride = *(size_t *)((uintptr_t)vwt + 72);
            uint32_t flags = *(uint32_t *)((uintptr_t)vwt + 80);
            gQAWNWPathAlign = (size_t)(flags & 0xFF) + 1;
            if (gQAWNWPathAlign < 16) gQAWNWPathAlign = 16;
            gQAWSyntheticAvailable = (gQAWNWPathStride > 0 && gQAWSwiftRetain != NULL);
        }
    }
    NSLog(@"QAWolf:netoffline: synthetic path update %s (stride=%zu align=%zu)",
          gQAWSyntheticAvailable ? "ready" : "UNAVAILABLE", gQAWNWPathStride, gQAWNWPathAlign);
}

// Find-or-create an entry for a monitor. Caller holds the lock.
static int QAWMonitorIndexLocked(void *monitor, bool create) {
    for (int i = 0; i < gQAWMonitorCount; i++)
        if (gQAWMonitors[i].monitor == monitor) return i;
    if (!create) return -1;
    if (!QAWGrowIfNeeded((void **)&gQAWMonitors, &gQAWMonitorCap, gQAWMonitorCount, sizeof(*gQAWMonitors))) {
        NSLog(@"QAWolf:netoffline: WARNING out of memory growing monitor table (%d entries) — dropping monitor=%p", gQAWMonitorCount, monitor);
        return -1;
    }
    int i = gQAWMonitorCount++;
    gQAWMonitors[i] = (QAWMonitorEntry){ .monitor = monitor, .fn = NULL, .ctx = NULL, .queue = NULL };
    return i;
}

static void QAWRegisterMonitorHandler(void *monitor, void *fn, void *ctx) {
    if (!gQAWSwiftRetain) gQAWSwiftRetain = (QAWSwiftRetainFn)dlsym(RTLD_DEFAULT, "swift_retain");
    if (!gQAWSwiftRelease) gQAWSwiftRelease = (QAWSwiftRetainFn)dlsym(RTLD_DEFAULT, "swift_release");
    pthread_mutex_lock(&gQAWMonitorLock);
    int idx = QAWMonitorIndexLocked(monitor, fn != NULL);
    if (fn == NULL) { // handler cleared -> drop our entry, releasing what we held
        if (idx < 0) { pthread_mutex_unlock(&gQAWMonitorLock); return; }
        QAWMonitorEntry e = gQAWMonitors[idx];
        gQAWMonitors[idx] = gQAWMonitors[--gQAWMonitorCount];
        pthread_mutex_unlock(&gQAWMonitorLock);
        // Release outside the lock. e.fn != NULL means we had activated this
        // entry and thus hold +1 on its ctx and monitor; a queue-only entry
        // (never activated) holds neither, only the CFRetain'd queue.
        if (gQAWSwiftRelease && e.fn) {
            if (e.ctx) gQAWSwiftRelease(e.ctx);
            gQAWSwiftRelease(e.monitor);
        }
        if (e.queue) CFRelease(e.queue);
        return;
    }
    if (idx < 0) { pthread_mutex_unlock(&gQAWMonitorLock); return; }
    // Hold the ctx (every set) and the monitor (first activation only) so we can
    // re-fire this handler later; release any ctx we're replacing so repeated
    // pathUpdateHandler assignments don't leak.
    void *oldCtx = gQAWMonitors[idx].ctx;
    bool firstActivation = (gQAWMonitors[idx].fn == NULL);
    if (gQAWSwiftRetain) { if (ctx) gQAWSwiftRetain(ctx); if (firstActivation) gQAWSwiftRetain(monitor); }
    gQAWMonitors[idx].fn = fn;
    gQAWMonitors[idx].ctx = ctx;
    int count = gQAWMonitorCount;
    pthread_mutex_unlock(&gQAWMonitorLock);
    if (!firstActivation && oldCtx && gQAWSwiftRelease) gQAWSwiftRelease(oldCtx);
    // fn address lets us confirm which monitors we captured (e.g. the app's
    // ConnectivityClient path handler) when diagnosing a flip that misses one.
    NSLog(@"QAWolf:netoffline: captured Swift NWPathMonitor monitor=%p fn=%p (%d total)", monitor, fn, count);
}

static void QAWRegisterMonitorQueue(void *monitor, void *queue) {
    pthread_mutex_lock(&gQAWMonitorLock);
    int idx = QAWMonitorIndexLocked(monitor, true);
    if (idx >= 0 && gQAWMonitors[idx].queue == NULL && queue) {
        CFRetain(queue);
        gQAWMonitors[idx].queue = queue;
    }
    pthread_mutex_unlock(&gQAWMonitorLock);
}

static void QAWNetworkOfflineFireSyntheticUpdates(void) {
    QAWResolveSyntheticOnce();
    if (!gQAWSyntheticAvailable) return;
    pthread_mutex_lock(&gQAWMonitorLock);
    int n = gQAWMonitorCount;
    QAWMonitorEntry *snapshot = n ? malloc((size_t)n * sizeof(*snapshot)) : NULL;
    if (snapshot) {
        memcpy(snapshot, gQAWMonitors, (size_t)n * sizeof(*snapshot));
        // Retain each deliverable entry's monitor/ctx/queue while still holding
        // the lock, so a concurrent handler-clear (which now releases them) can't
        // free them out from under an in-flight async delivery. Each block below
        // releases its own after use.
        for (int i = 0; i < n; i++) {
            if (!snapshot[i].fn) continue;
            if (gQAWSwiftRetain) { gQAWSwiftRetain(snapshot[i].monitor); if (snapshot[i].ctx) gQAWSwiftRetain(snapshot[i].ctx); }
            if (snapshot[i].queue) CFRetain(snapshot[i].queue);
        }
    }
    pthread_mutex_unlock(&gQAWMonitorLock);
    if (!snapshot) return;
    for (int i = 0; i < n; i++) {
        QAWMonitorEntry e = snapshot[i];
        if (!e.fn) continue;
        void *monitor = e.monitor, *fn = e.fn, *ctx = e.ctx, *queue = e.queue;
        dispatch_queue_t q = queue ? (__bridge dispatch_queue_t)queue
                                   : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_async(q, ^{
            void *buf = NULL;
            if (posix_memalign(&buf, gQAWNWPathAlign, gQAWNWPathStride) == 0 && buf) {
                memset(buf, 0, gQAWNWPathStride);
                gQAWCurrentPathGetter(buf, monitor); // buf = +1 NWPath; its .status read hits our override
                ((QAWPathClosureFn)fn)(buf, ctx);    // deliver update; closure consumes the value
                free(buf);                            // free our storage (value already destroyed by the closure)
                NSLog(@"QAWolf:netoffline: delivered synthetic NWPath update to monitor=%p", monitor);
            }
            if (gQAWSwiftRelease) { gQAWSwiftRelease(monitor); if (ctx) gQAWSwiftRelease(ctx); }
            if (queue) CFRelease(queue);
        });
    }
    free(snapshot);
}

#pragma mark - NWPathMonitor.pathUpdateHandler.setter / start(queue:) capture

// pathUpdateHandler.setter: optional closure arrives as {fn in x0, ctx in x1};
// fn == NULL means the handler is being cleared. self (monitor) in x20.
typedef __attribute__((swiftcall)) void (*QAWSetHandlerFn)(
    void *fn, void *ctx, void * __attribute__((swift_context)) self);
static QAWSetHandlerFn original_swift_NWPathMonitor_setHandler;

__attribute__((swiftcall))
static void my_swift_NWPathMonitor_setHandler(void *fn, void *ctx, void * __attribute__((swift_context)) self) {
    QAWRegisterMonitorHandler(self, fn, ctx);
    original_swift_NWPathMonitor_setHandler(fn, ctx, self);
}

// start(queue:) — queue (OS_dispatch_queue) in x0, self in x20.
typedef __attribute__((swiftcall)) void (*QAWStartFn)(
    void *queue, void * __attribute__((swift_context)) self);
static QAWStartFn original_swift_NWPathMonitor_start;

__attribute__((swiftcall))
static void my_swift_NWPathMonitor_start(void *queue, void * __attribute__((swift_context)) self) {
    QAWRegisterMonitorQueue(self, queue);
    original_swift_NWPathMonitor_start(queue, self);
}

#pragma mark - Control channel

@interface QAWNetworkOfflineController : NSObject
+ (instancetype)shared;
- (void)start;
@end

// AFC creates the file before writing it, so the folder event can fire on an
// empty file: re-read after a short delay, like MetadataObjectFileMonitor.m.
static const NSTimeInterval kQAWNetworkOfflineReadDelay = 0.1;
static const int kQAWNetworkOfflineReadRetries = 3;

// All reloads run on this one serial queue so a file-read and its
// atomic_exchange stay ordered against each other. filemonitor.m posts an event
// for every write in .qawolf/, and the host does delete-then-write on each push
// (two events), so reloads overlap in practice; on the global concurrent queue
// a reload that read the older value could exchange last and leave a stale
// state (e.g. stuck offline after a clear). A serial queue keeps event order.
static dispatch_queue_t QAWNetworkOfflineReloadQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.qawolf.netoffline.reload", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@implementation QAWNetworkOfflineController

+ (instancetype)shared {
    static QAWNetworkOfflineController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[QAWNetworkOfflineController alloc] init];
    });
    return instance;
}

- (NSString *)configPath {
    return [[Utils getQAWolfFolder] stringByAppendingPathComponent:kQAWNetworkOfflineConfigFilename];
}

- (void)start {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(onFileChanged:)
                                                  name:kFileChangedEvent
                                                object:nil];
    // pick up config already on disk at launch, on the reload queue so it stays
    // ordered against any event-driven reload that arrives right after.
    dispatch_async(QAWNetworkOfflineReloadQueue(), ^{
        [self reloadFromDiskWithRetry:kQAWNetworkOfflineReadRetries];
    });
    NSLog(@"QAWolf:netoffline: control channel started, watching %@", [self configPath]);
}

- (void)onFileChanged:(NSNotification *)notification {
    // filemonitor.m watches the whole .qawolf/ directory, not just our
    // file, so always re-check rather than trying to filter the userInfo.
    [self scheduleReloadWithRetry:kQAWNetworkOfflineReadRetries];
}

- (void)scheduleReloadWithRetry:(int)remainingRetries {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQAWNetworkOfflineReadDelay * NSEC_PER_SEC)),
                   QAWNetworkOfflineReloadQueue(), ^{
        [self reloadFromDiskWithRetry:remainingRetries];
    });
}

- (void)reloadFromDiskWithRetry:(int)remainingRetries {
    NSString *path = [self configPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return; // file not present -> leave state as-is
    }

    NSError *error = nil;
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (remainingRetries > 0) {
            [self scheduleReloadWithRetry:remainingRetries - 1];
        } else {
            NSLog(@"QAWolf:netoffline: giving up on %@ (%lu bytes): %@", path, (unsigned long)data.length, error);
        }
        return;
    }

    BOOL offline = [((NSDictionary *)json)[@"offline"] boolValue];
    // atomic_exchange rather than load-then-store: makes the read-and-write a
    // single atomic RMW, so two overlapping reloadFromDisk calls (e.g. two
    // VNODE events coalesced from rapid back-to-back writes) can't both
    // observe the same stale "previous" value and both log a transition.
    BOOL previous = atomic_exchange(&gQAWNetworkOfflineActive, offline);
    if (previous != offline) {
        NSLog(@"QAWolf:netoffline: offline override now %@", offline ? @"ON" : @"OFF");
        // Re-fire the OS's own connectivity callbacks so handler-driven apps
        // react immediately, the same way unplugging the cable would, instead
        // of waiting to poll a getter: the Swift NWPathMonitor closure, the C
        // nw_path_monitor block, and the SCNetworkReachability callout.
        QAWNetworkOfflineFireSyntheticUpdates();
        QAWFireCPathUpdates();
        QAWFireSCCallbacks();
    }
}

@end

#pragma mark - nw_path_get_status: C API status override

static nw_path_status_t (*original_nw_path_get_status)(nw_path_t path);

// No pass-through log here (Copilot review, 2026-08-26) — nw_path_get_status
// can be called frequently by networking stacks; logging every call would
// add avoidable per-call I/O and log noise in the common (non-offline) case
// across every test run that touches this dylib, not just NETWORK_OFFLINE
// ones. The override branch still logs, since that only fires during a
// deliberately engaged offline-simulation window.
static nw_path_status_t my_nw_path_get_status(nw_path_t path) {
    nw_path_status_t real = original_nw_path_get_status(path);
    if (atomic_load(&gQAWNetworkOfflineActive)) {
        NSLog(@"QAWolf:netoffline: nw_path_get_status overridden: real=%d -> nw_path_status_unsatisfied (offline override active)", real);
        return nw_path_status_unsatisfied;
    }
    return real;
}

#pragma mark - SCNetworkReachabilityGetFlags: status override

static Boolean (*original_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags);

// No pass-through log here either (Copilot review, 2026-08-26), same
// reasoning as nw_path_get_status above — many apps poll reachability
// frequently.
static Boolean my_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean ok = original_SCNetworkReachabilityGetFlags(target, flags);
    if (!ok) {
        return ok;
    }
    if (atomic_load(&gQAWNetworkOfflineActive)) {
        SCNetworkReachabilityFlags real = *flags;
        *flags = 0; // no kSCNetworkReachabilityFlagsReachable bit -> unreachable
        NSLog(@"QAWolf:netoffline: SCNetworkReachabilityGetFlags overridden: real=0x%x -> 0x0 (offline override active)", real);
    }
    return ok;
}

#pragma mark - NWPath.status.getter: Swift ABI boundary status override

// See the file header for why this is `swiftcall` with explicit
// swift_indirect_result/swift_context parameter attributes rather than a
// plain C signature — this is not optional, a naive signature SIGBUSes on
// first real invocation.
typedef __attribute__((swiftcall)) void (*QAWNWPathStatusGetterFn)(
    void * __attribute__((swift_indirect_result)) outStatus,
    void * __attribute__((swift_context)) self);

static QAWNWPathStatusGetterFn original_swift_NWPath_status_getter;

// No pass-through log here either (Copilot review, 2026-08-26) — .status is
// the most-read NWPath property of all, same log-flood reasoning as the two
// hooks above.
__attribute__((swiftcall))
static void my_swift_NWPath_status_getter(
    void * __attribute__((swift_indirect_result)) outStatus,
    void * __attribute__((swift_context)) self) {
    original_swift_NWPath_status_getter(outStatus, self); // fills *outStatus, same convention
    if (atomic_load(&gQAWNetworkOfflineActive)) {
        uint8_t real = *(uint8_t *)outStatus;
        NSLog(@"QAWolf:netoffline: SWIFT-ABI NWPath.status overridden: self=%p real=%u -> %u (offline override active)", self, real, QAW_SWIFT_NWPATH_STATUS_UNSATISFIED_GUESS);
        *(uint8_t *)outStatus = QAW_SWIFT_NWPATH_STATUS_UNSATISFIED_GUESS;
    }
}

#pragma mark - NWPath Bool-getter override helper
//
// Shared by isExpensive/.isConstrained/.usesInterfaceType below — all three
// reduce to the exact same shape (call original, force NO when offline is
// active, otherwise pass the real value through), so the override decision
// lives in one place rather than three hand-copied ones. Deliberately does
// NOT log the pass-through branch (unlike .status, which is normally read
// once per NWPathMonitor update): these Bool getters can be polled
// per-request by networking SDKs (confirmed for usesInterfaceType on
// Sleeper), so logging every single call would add per-call I/O to every
// test run that touches this dylib, not just NETWORK_OFFLINE ones. The
// override branch still logs — that only fires during a deliberately
// engaged offline-simulation window.
static inline BOOL QAWMaybeOverrideNWPathBool(BOOL real, void *self, const char *propertyName) {
    if (atomic_load(&gQAWNetworkOfflineActive)) {
        NSLog(@"QAWolf:netoffline: SWIFT-ABI NWPath.%s overridden: self=%p real=%d -> NO (offline override active)", propertyName, self, real);
        return NO;
    }
    return real;
}

#pragma mark - NWPath.isExpensive/.isConstrained: Swift ABI boundary overrides
//
// Same Swift ABI boundary as NWPath.status.getter (self via the swiftself
// x20 register), but the return type here is `Bool`, a fixed-layout stdlib
// type — unlike the resilient `NWPath.Status` enum, it returns directly in
// w0/x0, no indirect-result buffer/x8. Confirmed by disassembling real call
// sites in TrotWithInstrumentation.debug.dylib (see TASK.md): no
// value-witness-table size lookup or stack alloca precedes these calls,
// just the x20 self-load immediately before `bl`, matching a plain BOOL
// return. Forced to NO (false) when offline is active — mirrors a real
// unsatisfied NWPath, which reports both as false (nothing to be
// expensive/constrained about when there's no interface at all).
typedef __attribute__((swiftcall)) BOOL (*QAWNWPathBoolGetterFn)(
    void * __attribute__((swift_context)) self);

static QAWNWPathBoolGetterFn original_swift_NWPath_isExpensive_getter;
static QAWNWPathBoolGetterFn original_swift_NWPath_isConstrained_getter;

__attribute__((swiftcall))
static BOOL my_swift_NWPath_isExpensive_getter(void * __attribute__((swift_context)) self) {
    return QAWMaybeOverrideNWPathBool(original_swift_NWPath_isExpensive_getter(self), self, "isExpensive");
}

__attribute__((swiftcall))
static BOOL my_swift_NWPath_isConstrained_getter(void * __attribute__((swift_context)) self) {
    return QAWMaybeOverrideNWPathBool(original_swift_NWPath_isConstrained_getter(self), self, "isConstrained");
}

#pragma mark - NWPath.usesInterfaceType(_:): Swift ABI boundary override
//
// Real usage confirmed on Sleeper (a bundled analytics/tracking SDK calls
// `path.usesInterfaceType(.wifi)` instead of checking `.status`). Same
// swiftself (x20) convention as the other NWPath accessors, but the single
// `NWInterface.InterfaceType` parameter is itself a resilient Network.framework
// type — passed indirectly via a caller-allocated buffer addressed by a plain
// x0 argument (confirmed by disassembling the real call site in Sleeper's
// binary: a runtime value-witness-table size lookup + alloca precede the
// call, the same pattern `.status`'s *return* uses, here on the *parameter*
// instead). We never need to interpret that buffer's contents, though — we
// forward the pointer to the original untouched either way and only ever
// override the returned Bool, exactly like isExpensive/isConstrained, so the
// parameter's internal layout/tag mapping (which the disassembly explicitly
// couldn't pin down statically — see TASK.md) is irrelevant here. The Bool
// return itself is fixed-layout, so it comes back directly in w0/x0, same as
// the other two Bool getters — no indirect result.
typedef __attribute__((swiftcall)) BOOL (*QAWNWPathUsesInterfaceTypeFn)(
    const void *interfaceType, // x0 — opaque pointer to the caller's InterfaceType buffer, untouched
    void * __attribute__((swift_context)) self); // x20

static QAWNWPathUsesInterfaceTypeFn original_swift_NWPath_usesInterfaceType;

__attribute__((swiftcall))
static BOOL my_swift_NWPath_usesInterfaceType(const void *interfaceType, void * __attribute__((swift_context)) self) {
    return QAWMaybeOverrideNWPathBool(original_swift_NWPath_usesInterfaceType(interfaceType, self), self, "usesInterfaceType");
}

#pragma mark - NWPath.availableInterfaces.getter: empty list when offline (matches an unplug)
//
// ServiceTitan's ConnectivityClient reads availableInterfaces. With our
// .status override but the real interface still present, that reads as a
// degraded ("poor connection") link rather than hard offline, so it waits
// for a failing request before escalating. A real cable unplug empties this
// list. Returning Swift's empty-array singleton when offline makes the path
// we present look like an interface that is actually gone, so handler-driven
// apps escalate straight to offline. Returns [NWInterface] — a Swift Array,
// one pointer in x0; self in x20. The empty-array singleton is immortal, so
// handing it back as an owned +1 value is safe (retain/release are no-ops).
typedef __attribute__((swiftcall)) const void * (*QAWNWPathAvailIfFn)(
    void * __attribute__((swift_context)) self);
static QAWNWPathAvailIfFn original_swift_NWPath_availableInterfaces;
static const void *gQAWEmptyArrayValue = NULL; // Swift [] singleton, resolved at install

__attribute__((swiftcall))
static const void *my_swift_NWPath_availableInterfaces(void * __attribute__((swift_context)) self) {
    if (atomic_load(&gQAWNetworkOfflineActive) && gQAWEmptyArrayValue) {
        NSLog(@"QAWolf:netoffline: SWIFT-ABI NWPath.availableInterfaces overridden: self=%p -> [] (offline override active)", self);
        return gQAWEmptyArrayValue;
    }
    return original_swift_NWPath_availableInterfaces(self);
}

#pragma mark - nw_path_uses_interface_type: C API interface override
//
// ServiceTitan reads interface state through the C nw_path_uses_interface_type
// (it imports that, not nw_path_get_status), so its offline check keys on this.
// Forced to false while offline — matches a path with no interface at all,
// same as the Swift usesInterfaceType override. Frequent, so no passthrough log.

static bool (*original_nw_path_uses_interface_type)(nw_path_t path, nw_interface_type_t type);

static bool my_nw_path_uses_interface_type(nw_path_t path, nw_interface_type_t type) {
    bool real = original_nw_path_uses_interface_type(path, type);
    if (atomic_load(&gQAWNetworkOfflineActive)) {
        return false;
    }
    return real;
}

#pragma mark - C nw_path_monitor: capture handler + re-deliver on flip
//
// The C-API twin of the Swift NWPathMonitor capture above, for apps that use
// nw_path_monitor directly (ServiceTitan does; Swift NWPathMonitor apps go
// through the Swift symbols instead). We wrap the app's update handler so we
// always hold the most recent real nw_path, then on a flip re-invoke the app's
// handler with it on the monitor's queue — the handler's own
// nw_path_get_status / nw_path_uses_interface_type reads are already overridden,
// so it observes offline exactly as it would on a real path-down event.

typedef struct { void *monitor; void *handler; void *queue; void *lastPath; } QAWCMonitorEntry;
static QAWCMonitorEntry *gQAWCMonitors = NULL;
static int gQAWCMonitorCount = 0;
static int gQAWCMonitorCap = 0;
static pthread_mutex_t gQAWCMonitorLock = PTHREAD_MUTEX_INITIALIZER;

static void (*original_nw_path_monitor_set_update_handler)(nw_path_monitor_t, nw_path_monitor_update_handler_t);
static void (*original_nw_path_monitor_set_queue)(nw_path_monitor_t, dispatch_queue_t);
static void (*original_nw_path_monitor_cancel)(nw_path_monitor_t);

static int QAWCMonitorIndexLocked(void *monitor, bool create) {
    for (int i = 0; i < gQAWCMonitorCount; i++)
        if (gQAWCMonitors[i].monitor == monitor) return i;
    if (!create) return -1;
    if (!QAWGrowIfNeeded((void **)&gQAWCMonitors, &gQAWCMonitorCap, gQAWCMonitorCount, sizeof(*gQAWCMonitors))) return -1;
    int i = gQAWCMonitorCount++;
    gQAWCMonitors[i] = (QAWCMonitorEntry){ .monitor = monitor, .handler = NULL, .queue = NULL, .lastPath = NULL };
    return i;
}

static void QAWStoreCMonitorHandler(void *monitor, nw_path_monitor_update_handler_t appHandler) {
    pthread_mutex_lock(&gQAWCMonitorLock);
    int idx = QAWCMonitorIndexLocked(monitor, true);
    void *old = idx >= 0 ? gQAWCMonitors[idx].handler : NULL;
    if (idx >= 0) gQAWCMonitors[idx].handler = (__bridge_retained void *)appHandler;
    pthread_mutex_unlock(&gQAWCMonitorLock);
    if (old) { id released = (__bridge_transfer id)old; (void)released; }
}

static void QAWStoreCMonitorLastPath(void *monitor, nw_path_t path) {
    pthread_mutex_lock(&gQAWCMonitorLock);
    int idx = QAWCMonitorIndexLocked(monitor, true);
    void *old = idx >= 0 ? gQAWCMonitors[idx].lastPath : NULL;
    if (idx >= 0) gQAWCMonitors[idx].lastPath = (__bridge_retained void *)path;
    pthread_mutex_unlock(&gQAWCMonitorLock);
    if (old) { id released = (__bridge_transfer id)old; (void)released; }
}

static void QAWStoreCMonitorQueue(void *monitor, dispatch_queue_t queue) {
    pthread_mutex_lock(&gQAWCMonitorLock);
    int idx = QAWCMonitorIndexLocked(monitor, true);
    void *old = idx >= 0 ? gQAWCMonitors[idx].queue : NULL;
    if (idx >= 0) gQAWCMonitors[idx].queue = queue ? (__bridge_retained void *)queue : NULL;
    pthread_mutex_unlock(&gQAWCMonitorLock);
    if (old) { id released = (__bridge_transfer id)old; (void)released; }
}

static void QAWClearCMonitor(void *monitor) {
    pthread_mutex_lock(&gQAWCMonitorLock);
    int idx = QAWCMonitorIndexLocked(monitor, false);
    QAWCMonitorEntry cleared = {0};
    if (idx >= 0) {
        cleared = gQAWCMonitors[idx];
        gQAWCMonitors[idx] = gQAWCMonitors[--gQAWCMonitorCount];
    }
    pthread_mutex_unlock(&gQAWCMonitorLock);
    if (cleared.handler) { id r = (__bridge_transfer id)cleared.handler; (void)r; }
    if (cleared.lastPath) { id r = (__bridge_transfer id)cleared.lastPath; (void)r; }
    if (cleared.queue) { id r = (__bridge_transfer id)cleared.queue; (void)r; }
}

static void my_nw_path_monitor_set_update_handler(nw_path_monitor_t monitor, nw_path_monitor_update_handler_t handler) {
    void *key = (__bridge void *)monitor;
    if (handler == NULL) {
        QAWClearCMonitor(key);
        original_nw_path_monitor_set_update_handler(monitor, NULL);
        return;
    }
    nw_path_monitor_update_handler_t appHandler = handler;
    QAWStoreCMonitorHandler(key, appHandler);
    // Wrap so every real OS delivery records the path we re-send on a flip.
    nw_path_monitor_update_handler_t wrapper = ^(nw_path_t path) {
        QAWStoreCMonitorLastPath(key, path);
        appHandler(path);
    };
    original_nw_path_monitor_set_update_handler(monitor, wrapper);
    NSLog(@"QAWolf:netoffline: captured nw_path_monitor handler monitor=%p", key);
}

static void my_nw_path_monitor_set_queue(nw_path_monitor_t monitor, dispatch_queue_t queue) {
    QAWStoreCMonitorQueue((__bridge void *)monitor, queue);
    original_nw_path_monitor_set_queue(monitor, queue);
}

static void my_nw_path_monitor_cancel(nw_path_monitor_t monitor) {
    QAWClearCMonitor((__bridge void *)monitor);
    original_nw_path_monitor_cancel(monitor);
}

static void QAWFireCPathUpdates(void) {
    pthread_mutex_lock(&gQAWCMonitorLock);
    int n = gQAWCMonitorCount;
    for (int i = 0; i < n; i++) {
        QAWCMonitorEntry e = gQAWCMonitors[i];
        if (!e.handler || !e.lastPath) continue;
        nw_path_monitor_update_handler_t handler = (__bridge nw_path_monitor_update_handler_t)e.handler;
        nw_path_t path = (__bridge nw_path_t)e.lastPath;
        void *key = e.monitor;
        dispatch_queue_t q = e.queue ? (__bridge dispatch_queue_t)e.queue
                                     : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_async(q, ^{
            handler(path); // handler's status/interface reads hit our overrides
            NSLog(@"QAWolf:netoffline: delivered synthetic nw_path_monitor update to monitor=%p", key);
        });
    }
    pthread_mutex_unlock(&gQAWCMonitorLock);
}

#pragma mark - SCNetworkReachability callback: capture + re-deliver on flip
//
// SCNetworkReachabilityGetFlags is a *pull* — overriding it only helps when the
// app re-reads. Apps built on Reachability.swift / Alamofire's
// NetworkReachabilityManager (ServiceTitan among them) instead register a
// *push* callout via SCNetworkReachabilitySetCallback and wait to be told.
// Capture that callout plus wherever it was scheduled (dispatch queue or
// run loop), and on a flip invoke it with unreachable flags (0) when going
// offline, real flags when coming back — the OS's own change event.

typedef struct { void *target; void *callout; void *info; void *queue; void *runLoop; void *runLoopMode; } QAWSCEntry;
static QAWSCEntry *gQAWSCEntries = NULL;
static int gQAWSCEntryCount = 0;
static int gQAWSCEntryCap = 0;
static pthread_mutex_t gQAWSCEntryLock = PTHREAD_MUTEX_INITIALIZER;

static Boolean (*original_SCNetworkReachabilitySetCallback)(SCNetworkReachabilityRef, SCNetworkReachabilityCallBack, SCNetworkReachabilityContext *);
static Boolean (*original_SCNetworkReachabilitySetDispatchQueue)(SCNetworkReachabilityRef, dispatch_queue_t);
static Boolean (*original_SCNetworkReachabilityScheduleWithRunLoop)(SCNetworkReachabilityRef, CFRunLoopRef, CFStringRef);

static int QAWSCIndexLocked(void *target, bool create) {
    for (int i = 0; i < gQAWSCEntryCount; i++)
        if (gQAWSCEntries[i].target == target) return i;
    if (!create) return -1;
    if (!QAWGrowIfNeeded((void **)&gQAWSCEntries, &gQAWSCEntryCap, gQAWSCEntryCount, sizeof(*gQAWSCEntries))) return -1;
    int i = gQAWSCEntryCount++;
    gQAWSCEntries[i] = (QAWSCEntry){ .target = target };
    CFRetain(target);
    return i;
}

static void QAWStoreSCCallback(SCNetworkReachabilityRef target, void *callout, void *info) {
    pthread_mutex_lock(&gQAWSCEntryLock);
    int idx = QAWSCIndexLocked((void *)target, true);
    if (idx >= 0) { gQAWSCEntries[idx].callout = callout; gQAWSCEntries[idx].info = info; }
    pthread_mutex_unlock(&gQAWSCEntryLock);
}

static void QAWClearSCEntry(SCNetworkReachabilityRef target) {
    pthread_mutex_lock(&gQAWSCEntryLock);
    int idx = QAWSCIndexLocked((void *)target, false);
    if (idx >= 0) { gQAWSCEntries[idx].callout = NULL; gQAWSCEntries[idx].info = NULL; }
    pthread_mutex_unlock(&gQAWSCEntryLock);
}

static Boolean my_SCNetworkReachabilitySetCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityCallBack callout, SCNetworkReachabilityContext *context) {
    if (callout == NULL) {
        QAWClearSCEntry(target);
    } else {
        void *info = context ? (void *)context->info : NULL;
        if (context && context->retain && info) info = (void *)context->retain(info);
        QAWStoreSCCallback(target, (void *)callout, info);
        NSLog(@"QAWolf:netoffline: captured SCNetworkReachability callback target=%p", target);
    }
    return original_SCNetworkReachabilitySetCallback(target, callout, context);
}

static Boolean my_SCNetworkReachabilitySetDispatchQueue(SCNetworkReachabilityRef target, dispatch_queue_t queue) {
    pthread_mutex_lock(&gQAWSCEntryLock);
    int idx = QAWSCIndexLocked((void *)target, true);
    void *old = idx >= 0 ? gQAWSCEntries[idx].queue : NULL;
    if (idx >= 0) gQAWSCEntries[idx].queue = queue ? (__bridge_retained void *)queue : NULL;
    pthread_mutex_unlock(&gQAWSCEntryLock);
    if (old) { id r = (__bridge_transfer id)old; (void)r; }
    return original_SCNetworkReachabilitySetDispatchQueue(target, queue);
}

static Boolean my_SCNetworkReachabilityScheduleWithRunLoop(SCNetworkReachabilityRef target, CFRunLoopRef runLoop, CFStringRef runLoopMode) {
    pthread_mutex_lock(&gQAWSCEntryLock);
    int idx = QAWSCIndexLocked((void *)target, true);
    if (idx >= 0 && gQAWSCEntries[idx].runLoop == NULL && runLoop) {
        CFRetain(runLoop);
        gQAWSCEntries[idx].runLoop = (void *)runLoop;
        if (runLoopMode) { CFRetain(runLoopMode); gQAWSCEntries[idx].runLoopMode = (void *)runLoopMode; }
    }
    pthread_mutex_unlock(&gQAWSCEntryLock);
    return original_SCNetworkReachabilityScheduleWithRunLoop(target, runLoop, runLoopMode);
}

static void QAWFireSCCallbacks(void) {
    bool offline = atomic_load(&gQAWNetworkOfflineActive);
    // Dispatch while holding the lock (like QAWFireCPathUpdates): my_...SetDispatchQueue
    // takes the same lock before releasing a replaced queue, so it can't free e.queue
    // out from under us mid-flip, and dispatch_async/CFRunLoop retain what they need
    // once scheduled. target/info live for the process (never released on teardown).
    pthread_mutex_lock(&gQAWSCEntryLock);
    int n = gQAWSCEntryCount;
    for (int i = 0; i < n; i++) {
        QAWSCEntry e = gQAWSCEntries[i];
        if (!e.callout) continue;
        SCNetworkReachabilityRef target = (SCNetworkReachabilityRef)e.target;
        SCNetworkReachabilityFlags flags = 0;
        if (!offline) {
            if (!(original_SCNetworkReachabilityGetFlags && original_SCNetworkReachabilityGetFlags(target, &flags)))
                flags = kSCNetworkReachabilityFlagsReachable;
        }
        SCNetworkReachabilityCallBack callout = (SCNetworkReachabilityCallBack)e.callout;
        void *info = e.info;
        void (^deliver)(void) = ^{
            callout(target, flags, info);
            NSLog(@"QAWolf:netoffline: delivered synthetic SCNetworkReachability callback target=%p flags=0x%x", target, flags);
        };
        if (e.queue) {
            dispatch_async((__bridge dispatch_queue_t)e.queue, deliver);
        } else if (e.runLoop) {
            CFStringRef mode = e.runLoopMode ? (CFStringRef)e.runLoopMode : kCFRunLoopDefaultMode;
            CFRunLoopPerformBlock((CFRunLoopRef)e.runLoop, mode, deliver);
            CFRunLoopWakeUp((CFRunLoopRef)e.runLoop);
        } else {
            deliver();
        }
    }
    pthread_mutex_unlock(&gQAWSCEntryLock);
}

#pragma mark - Install

// Logs a hook's install result uniformly and, critically, flags a non-zero
// rebind_symbols rc with the same "WARNING" prefix the dlsym-not-found path
// already uses — previously rc was interpolated into a plain info-level log
// line, easy to miss when grepping device logs for actual problems. A
// non-zero rc here is safe (fishhook's prepend_rebindings fails, if at all,
// before touching any binding table, so the hook is simply never installed
// rather than partially installed), but is still worth surfacing loudly:
// it means the underlying override for that symbol did not go live.
static void QAWLogHookInstallResult(const char *label, int rc, void *original) {
    if (rc != 0) {
        NSLog(@"QAWolf:netoffline: WARNING %s hook install FAILED (rebind_symbols rc=%d) — override NOT installed", label, rc);
    } else {
        NSLog(@"QAWolf:netoffline: %s hook installed (rebind_symbols rc=%d, original=%p)", label, rc, original);
    }
}

__attribute__((constructor))
static void QAWolfNetworkOfflineInit(void) {
    if (dlsym(RTLD_DEFAULT, "nw_path_get_status")) {
        int rc = rebind_single_symbol("nw_path_get_status", (void *)my_nw_path_get_status, (void **)&original_nw_path_get_status);
        QAWLogHookInstallResult("nw_path_get_status", rc, original_nw_path_get_status);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING nw_path_get_status symbol not found — status override NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "nw_path_uses_interface_type")) {
        int rc = rebind_single_symbol("nw_path_uses_interface_type", (void *)my_nw_path_uses_interface_type, (void **)&original_nw_path_uses_interface_type);
        QAWLogHookInstallResult("nw_path_uses_interface_type", rc, original_nw_path_uses_interface_type);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING nw_path_uses_interface_type symbol not found — interface override NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "nw_path_monitor_set_update_handler")) {
        int rc = rebind_single_symbol("nw_path_monitor_set_update_handler", (void *)my_nw_path_monitor_set_update_handler, (void **)&original_nw_path_monitor_set_update_handler);
        QAWLogHookInstallResult("nw_path_monitor_set_update_handler", rc, original_nw_path_monitor_set_update_handler);
        int rcq = rebind_single_symbol("nw_path_monitor_set_queue", (void *)my_nw_path_monitor_set_queue, (void **)&original_nw_path_monitor_set_queue);
        QAWLogHookInstallResult("nw_path_monitor_set_queue", rcq, original_nw_path_monitor_set_queue);
        int rcc = rebind_single_symbol("nw_path_monitor_cancel", (void *)my_nw_path_monitor_cancel, (void **)&original_nw_path_monitor_cancel);
        QAWLogHookInstallResult("nw_path_monitor_cancel", rcc, original_nw_path_monitor_cancel);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING nw_path_monitor_set_update_handler symbol not found — C path-monitor delivery NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "SCNetworkReachabilitySetCallback")) {
        int rc = rebind_single_symbol("SCNetworkReachabilitySetCallback", (void *)my_SCNetworkReachabilitySetCallback, (void **)&original_SCNetworkReachabilitySetCallback);
        QAWLogHookInstallResult("SCNetworkReachabilitySetCallback", rc, original_SCNetworkReachabilitySetCallback);
        int rcq = rebind_single_symbol("SCNetworkReachabilitySetDispatchQueue", (void *)my_SCNetworkReachabilitySetDispatchQueue, (void **)&original_SCNetworkReachabilitySetDispatchQueue);
        QAWLogHookInstallResult("SCNetworkReachabilitySetDispatchQueue", rcq, original_SCNetworkReachabilitySetDispatchQueue);
        int rcs = rebind_single_symbol("SCNetworkReachabilityScheduleWithRunLoop", (void *)my_SCNetworkReachabilityScheduleWithRunLoop, (void **)&original_SCNetworkReachabilityScheduleWithRunLoop);
        QAWLogHookInstallResult("SCNetworkReachabilityScheduleWithRunLoop", rcs, original_SCNetworkReachabilityScheduleWithRunLoop);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING SCNetworkReachabilitySetCallback symbol not found — reachability callback delivery NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "SCNetworkReachabilityGetFlags")) {
        int rc = rebind_single_symbol("SCNetworkReachabilityGetFlags", (void *)my_SCNetworkReachabilityGetFlags, (void **)&original_SCNetworkReachabilityGetFlags);
        QAWLogHookInstallResult("SCNetworkReachabilityGetFlags", rc, original_SCNetworkReachabilityGetFlags);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING SCNetworkReachabilityGetFlags symbol not found — status override NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "$s7Network6NWPathV6statusAC6StatusOvg")) {
        int rc = rebind_single_symbol("$s7Network6NWPathV6statusAC6StatusOvg", (void *)my_swift_NWPath_status_getter, (void **)&original_swift_NWPath_status_getter);
        QAWLogHookInstallResult("SWIFT-ABI[NWPath.status.getter]", rc, original_swift_NWPath_status_getter);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING NWPath.status.getter Swift symbol not resolvable via dlsym — status override NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "$s7Network6NWPathV11isExpensiveSbvg")) {
        int rc = rebind_single_symbol("$s7Network6NWPathV11isExpensiveSbvg", (void *)my_swift_NWPath_isExpensive_getter, (void **)&original_swift_NWPath_isExpensive_getter);
        QAWLogHookInstallResult("SWIFT-ABI[NWPath.isExpensive.getter]", rc, original_swift_NWPath_isExpensive_getter);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING NWPath.isExpensive.getter Swift symbol not resolvable via dlsym — override NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "$s7Network6NWPathV13isConstrainedSbvg")) {
        int rc = rebind_single_symbol("$s7Network6NWPathV13isConstrainedSbvg", (void *)my_swift_NWPath_isConstrained_getter, (void **)&original_swift_NWPath_isConstrained_getter);
        QAWLogHookInstallResult("SWIFT-ABI[NWPath.isConstrained.getter]", rc, original_swift_NWPath_isConstrained_getter);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING NWPath.isConstrained.getter Swift symbol not resolvable via dlsym — override NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "$s7Network6NWPathV17usesInterfaceTypeySbAA11NWInterfaceV0dE0OF")) {
        int rc = rebind_single_symbol("$s7Network6NWPathV17usesInterfaceTypeySbAA11NWInterfaceV0dE0OF", (void *)my_swift_NWPath_usesInterfaceType, (void **)&original_swift_NWPath_usesInterfaceType);
        QAWLogHookInstallResult("SWIFT-ABI[NWPath.usesInterfaceType]", rc, original_swift_NWPath_usesInterfaceType);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING NWPath.usesInterfaceType Swift symbol not resolvable via dlsym — override NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "$s7Network13NWPathMonitorC17pathUpdateHandleryAA0B0VcSgvs")) {
        int rc = rebind_single_symbol("$s7Network13NWPathMonitorC17pathUpdateHandleryAA0B0VcSgvs", (void *)my_swift_NWPathMonitor_setHandler, (void **)&original_swift_NWPathMonitor_setHandler);
        QAWLogHookInstallResult("SWIFT-ABI[NWPathMonitor.pathUpdateHandler.setter]", rc, original_swift_NWPathMonitor_setHandler);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING NWPathMonitor.pathUpdateHandler.setter not resolvable via dlsym — synthetic updates NOT installed (iOS ABI may have changed)");
    }

    if (dlsym(RTLD_DEFAULT, "$s7Network13NWPathMonitorC5start5queueySo012OS_dispatch_E0C_tF")) {
        int rc = rebind_single_symbol("$s7Network13NWPathMonitorC5start5queueySo012OS_dispatch_E0C_tF", (void *)my_swift_NWPathMonitor_start, (void **)&original_swift_NWPathMonitor_start);
        QAWLogHookInstallResult("SWIFT-ABI[NWPathMonitor.start(queue:)]", rc, original_swift_NWPathMonitor_start);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING NWPathMonitor.start(queue:) not resolvable via dlsym — synthetic updates NOT installed (iOS ABI may have changed)");
    }

    // Resolve Swift's empty-array singleton so availableInterfaces can return [].
    const char *qawEmptyArrayNames[] = {"_swiftEmptyArrayStorage", "swiftEmptyArrayStorage", "__swift_EmptyArrayStorage"};
    for (size_t i = 0; i < sizeof(qawEmptyArrayNames)/sizeof(qawEmptyArrayNames[0]); i++) {
        void *sym = dlsym(RTLD_DEFAULT, qawEmptyArrayNames[i]);
        if (sym) {
            gQAWEmptyArrayValue = sym;
            NSLog(@"QAWolf:netoffline: empty-array singleton resolved via %s = %p", qawEmptyArrayNames[i], sym);
            break;
        }
    }
    if (!gQAWEmptyArrayValue) {
        NSLog(@"QAWolf:netoffline: WARNING empty-array singleton not resolved — availableInterfaces override disabled");
    } else if (dlsym(RTLD_DEFAULT, "$s7Network6NWPathV19availableInterfacesSayAA11NWInterfaceVGvg")) {
        int rc = rebind_single_symbol("$s7Network6NWPathV19availableInterfacesSayAA11NWInterfaceVGvg", (void *)my_swift_NWPath_availableInterfaces, (void **)&original_swift_NWPath_availableInterfaces);
        QAWLogHookInstallResult("SWIFT-ABI[NWPath.availableInterfaces.getter]", rc, original_swift_NWPath_availableInterfaces);
    } else {
        NSLog(@"QAWolf:netoffline: WARNING NWPath.availableInterfaces.getter Swift symbol not resolvable via dlsym — override NOT installed (iOS ABI may have changed)");
    }

    QAWResolveSyntheticOnce();
    [[QAWNetworkOfflineController shared] start];
}
