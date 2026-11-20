//
//  HUDStatusBar.mm
//  Helium
//

#import "HUDStatusBar.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <pthread.h>

#pragma mark - Accessibility plumbing

// Everything here is optional at runtime. The accessibility symbols live in
// AXRuntime, which is not in the public SDK, so they are looked up with
// dlsym: if any of them is missing the probe reports why and the HUD falls
// back to the heuristic layer instead of failing to launch.
typedef CFTypeRef AXElement;

static AXElement     (*gAXSystemWide)(void) = NULL;
static AXElement     (*gAXApplication)(pid_t) = NULL;
static int           (*gAXCopy)(AXElement, CFStringRef, CFTypeRef *) = NULL;
static int           (*gAXSetTimeout)(AXElement, float) = NULL;
static int           (*gAXValueGetValue)(CFTypeRef, int, void *) = NULL;
static pid_t         (*gAXGetPid)(AXElement) = NULL;

/// kAXValueCGRectType in AXRuntime.
static const int kHUDCGRectType = 3;

/// Strings pulled out of the accessibility tree. The whole probe runs on its
/// own queue with a messaging timeout, so this is only ever a soft cost: the
/// main queue reads a cached answer.
static NSString *HUDAXLoadNote = nil;

static NSString *HUDAXLoad(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *candidates[] = {
            "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
            "AXRuntime",
            "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        };
        void *handle = NULL;
        const char *loadedFrom = NULL;
        for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
            handle = dlopen(candidates[i], RTLD_NOW);
            if (handle) { loadedFrom = candidates[i]; break; }
        }
        if (!handle) {
            const char *why = dlerror();
            HUDAXLoadNote = [NSString stringWithFormat:@"dlopen failed: %s", why ?: "?"];
            return;
        }
        gAXSystemWide    = (AXElement (*)(void))dlsym(handle, "AXUIElementCreateSystemWide");
        gAXApplication   = (AXElement (*)(pid_t))dlsym(handle, "AXUIElementCreateApplication");
        gAXCopy          = (int (*)(AXElement, CFStringRef, CFTypeRef *))dlsym(handle, "AXUIElementCopyAttributeValue");
        gAXSetTimeout    = (int (*)(AXElement, float))dlsym(handle, "AXUIElementSetMessagingTimeout");
        gAXValueGetValue = (int (*)(CFTypeRef, int, void *))dlsym(handle, "AXValueGetValue");
        gAXGetPid        = (pid_t (*)(AXElement))dlsym(handle, "AXUIElementGetPid");
        // Optional: nothing uses AXUIElementCreateApplication yet, but keeping
        // the lookup here documents that it is available.
        (void)gAXApplication;
        if (!gAXSystemWide || !gAXCopy) {
            HUDAXLoadNote = [NSString stringWithFormat:@"loaded %s but the AXUIElement symbols are missing", loadedFrom];
            return;
        }
        HUDAXLoadNote = [NSString stringWithFormat:@"loaded %s", loadedFrom];
    });
    return HUDAXLoadNote;
}

/// The load note without loading anything: the diagnostics file is written from
/// the main queue and must not be the first place that dlopens a framework.
static NSString *HUDAXLoadNoteIfAny(void)
{
    return HUDAXLoadNote;
}

static CFTypeRef HUDAXCopy(AXElement element, NSString *attribute)
{
    if (!element || !gAXCopy) return NULL;
    CFTypeRef value = NULL;
    if (gAXCopy(element, (__bridge CFStringRef)attribute, &value) != 0) return NULL;
    return value;
}

static NSString *_Nullable HUDAXString(AXElement element, NSString *attribute)
{
    CFTypeRef value = HUDAXCopy(element, attribute);
    if (!value) return nil;
    id object = CFBridgingRelease(value);
    if ([object isKindOfClass:[NSString class]]) return object;
    if ([object isKindOfClass:[NSNumber class]]) return [object description];
    return nil;
}

static BOOL HUDAXBoolean(AXElement element, NSString *attribute, BOOL *found)
{
    CFTypeRef value = HUDAXCopy(element, attribute);
    if (!value) { if (found) *found = NO; return NO; }
    id object = CFBridgingRelease(value);
    if (found) *found = YES;
    if ([object isKindOfClass:[NSNumber class]]) return [object boolValue];
    return NO;
}

static BOOL HUDAXFrame(AXElement element, CGRect *out)
{
    if (!gAXValueGetValue) return NO;
    CFTypeRef value = HUDAXCopy(element, @"AXFrame");
    if (!value) return NO;
    CGRect rect = CGRectZero;
    BOOL ok = gAXValueGetValue(value, kHUDCGRectType, &rect) ? YES : NO;
    CFRelease(value);
    if (ok && out) *out = rect;
    return ok;
}

/// A process name for a pid, so the report can say which application the
/// accessibility tree belonged to. Standard libc, no private frameworks.
static NSString *HUDProcessNameForPID(pid_t pid)
{
    if (pid <= 0) return nil;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return nil;
    return [NSString stringWithUTF8String:info.kp_proc.p_comm] ?: nil;
}

static pid_t HUDSpringBoardPID(void)
{
    static pid_t cached = 0;
    if (cached > 0) return cached;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        size_t count = size / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, "SpringBoard") == 0) {
                cached = procs[i].kp_proc.p_pid;
                break;
            }
        }
    }
    free(procs);
    return cached;
}

/// The front most application's bundle id, when SpringBoard will say. Optional
/// in every sense: it is only ever printed.
static NSString *HUDFrontmostApplicationIdentifier(void)
{
    static NSString *(*copyIdentifier)(void) = NULL;
    static BOOL looked = NO;
    if (!looked) {
        looked = YES;
        void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        if (handle) copyIdentifier = (NSString *(*)(void))dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
    }
    if (!copyIdentifier) return nil;
    NSString *identifier = nil;
    @try {
        identifier = copyIdentifier();
    } @catch (NSException *exception) {
        identifier = nil;
    }
    return identifier;
}

#pragma mark - One walk of the accessibility tree

@interface HUDStatusBarAXResult : NSObject
@property (nonatomic, copy) NSString *answer;   // visible / hidden / unknown
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *digest;
@property (nonatomic) NSUInteger nodes;
@property (nonatomic, copy) NSString *frontmost;
@property (nonatomic) pid_t pid;
@end

@implementation HUDStatusBarAXResult
- (instancetype)init
{
    self = [super init];
    if (self) {
        _answer = @"unknown";
        _detail = @"";
        _digest = @"";
    }
    return self;
}
@end

/// Anything whose role says "status bar" is decisive. A label like "Battery"
/// is only a hint -- Settings has one too -- so it is recorded but does not
/// hide or show anything by itself.
static BOOL HUDRoleIsStatusBar(NSString *role, NSString *identifier)
{
    NSString *blob = [[NSString stringWithFormat:@"%@|%@", role ?: @"", identifier ?: @""] lowercaseString];
    return [blob containsString:@"statusbar"] || [blob containsString:@"status_bar"];
}

static BOOL HUDLabelIsStatusBarHint(NSString *label)
{
    if (label.length == 0) return NO;
    static NSSet *hints = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hints = [NSSet setWithArray:@[@"time", @"battery", @"wifi", @"wi-fi", @"cellular",
                                      @"no sim", @"airplane mode", @"signal"]];
    });
    return [hints containsObject:label.lowercaseString];
}

/// The walk is bounded in every direction: a tree with hundreds of nodes would
/// otherwise cost a hundred IPC round trips per second on a HUD that only needs
/// to know whether one element is on screen.
static const NSUInteger kHUDAXNodeBudget = 70;
static const NSInteger kHUDAXMaxDepth = 4;
static const NSUInteger kHUDAXMaxChildrenPerNode = 14;
static const float kHUDAXMessageTimeout = 0.35f;

/// Walks one element tree, bounded in depth and node count, and reports what it
/// found. Returns nil when there was no status bar element at all.
static NSString *HUDAXWalkTree(id root, NSMutableString *digestOut, NSMutableDictionary *roles,
                               NSMutableArray *hints, NSUInteger *nodesOut,
                               NSString **matchDescription)
{
    NSMutableArray *stack = [NSMutableArray array];
    [stack addObject:@[root, @0]];
    NSMutableArray *matches = [NSMutableArray array];
    NSString *verdict = nil;
    NSUInteger nodes = 0;

    while (stack.count && nodes < kHUDAXNodeBudget) {
        if (verdict) break;
        NSArray *entry = stack.lastObject;
        [stack removeLastObject];
        id element = entry[0];
        NSInteger depth = [(NSNumber *)entry[1] integerValue];
        nodes++;

        AXElement axElement = (__bridge AXElement)element;
        NSString *role = HUDAXString(axElement, @"AXRole") ?: @"?";
        NSString *identifier = nil;
        if ([role isEqualToString:@"AXGroup"] || [role isEqualToString:@"AXOther"]
            || [role isEqualToString:@"AXUnknown"] || [role hasSuffix:@"Bar"]) {
            identifier = HUDAXString(axElement, @"AXIdentifier");
        }
        roles[role] = @([roles[role] integerValue] + 1);
        if (depth <= 2) {
            [digestOut appendFormat:@"%s%@(%@)", depth ? "  > " : "", role, identifier ?: @"-"];
        }

        if (HUDRoleIsStatusBar(role, identifier)) {
            CGRect frame = CGRectZero;
            BOOL haveFrame = HUDAXFrame(axElement, &frame);
            if (!haveFrame && gAXValueGetValue) {
                CFTypeRef sizeRef = HUDAXCopy(axElement, @"AXSize");
                if (sizeRef) {
                    CGSize size = CGSizeZero;
                    if (gAXValueGetValue(sizeRef, 2, &size)) {
                        frame.size = size;
                        haveFrame = YES;
                    }
                    CFRelease(sizeRef);
                }
            }
            BOOL hiddenFound = NO;
            BOOL hiddenValue = HUDAXBoolean(axElement, @"AXHidden", &hiddenFound);
            NSString *identifierText = identifier ?: @"";
            NSString *label = HUDAXString(axElement, @"AXLabel") ?: HUDAXString(axElement, @"AXTitle") ?: @"";
            BOOL empty = haveFrame && (frame.size.width < 1.0 || frame.size.height < 1.0);
            [matches addObject:role];
            if (hiddenValue || empty) {
                verdict = [NSString stringWithFormat:@"status bar element %@%@%@ is %@",
                           role,
                           identifierText.length ? [NSString stringWithFormat:@" id=%@", identifierText] : @"",
                           label.length ? [NSString stringWithFormat:@" \"%@\"", label] : @"",
                           hiddenValue ? @"AXHidden" : @"zero sized"];
            } else {
                verdict = [NSString stringWithFormat:@"found element id=%@ role=%@ frame=%.0fx%.0f hidden=0",
                           identifierText.length ? identifierText : (label.length ? label : @"-"),
                           role, frame.size.width, frame.size.height];
            }
        } else if (depth <= 3) {
            NSString *label = HUDAXString(axElement, @"AXLabel");
            if (HUDLabelIsStatusBarHint(label)) {
                [hints addObject:[NSString stringWithFormat:@"%@:%@", role, label]];
            }
        }

        if (verdict || depth >= kHUDAXMaxDepth) continue;

        CFTypeRef childrenRef = HUDAXCopy(axElement, @"AXChildren");
        if (!childrenRef) continue;
        id children = CFBridgingRelease(childrenRef);
        if (![children isKindOfClass:[NSArray class]]) continue;
        NSArray *childList = children;
        NSUInteger limit = MIN(childList.count, kHUDAXMaxChildrenPerNode);
        for (NSInteger i = (NSInteger)limit - 1; i >= 0; i--) {
            [stack addObject:@[childList[(NSUInteger)i], @(depth + 1)]];
        }
    }

    *nodesOut = nodes;
    if (matchDescription) *matchDescription = [matches componentsJoinedByString:@","];
    return verdict;
}

static HUDStatusBarAXResult *HUDRunAXProbe(void)
{
    HUDStatusBarAXResult *result = [[HUDStatusBarAXResult alloc] init];
    NSString *loadNote = HUDAXLoad();
    result.detail = loadNote ?: @"";
    if (!gAXSystemWide || !gAXCopy) return result;

    NSMutableDictionary *roles = [NSMutableDictionary dictionary];
    NSMutableArray *hints = [NSMutableArray array];
    NSMutableString *digest = [NSMutableString string];
    NSString *attempts = @"";

    // First choice: the front most application, the one whose status bar this
    // is. Its tree is the only place that knows whether the app is drawing one.
    NSString *focusedError = nil;
    id application = nil;
    @try {
        AXElement systemWide = gAXSystemWide();
        if (!systemWide) {
            focusedError = @"AXUIElementCreateSystemWide returned NULL";
        } else {
            if (gAXSetTimeout) gAXSetTimeout(systemWide, kHUDAXMessageTimeout);
            CFTypeRef focused = NULL;
            int err = gAXCopy(systemWide, CFSTR("AXFocusedApplication"), &focused);
            CFRelease(systemWide);
            if (err != 0 || !focused) {
                focusedError = [NSString stringWithFormat:@"AXFocusedApplication err=%d", err];
            } else {
                application = CFBridgingRelease(focused);
            }
        }
    } @catch (NSException *exception) {
        focusedError = [NSString stringWithFormat:@"focused app threw %@", exception.name];
    }

    if (application) {
        if (gAXSetTimeout) gAXSetTimeout((__bridge AXElement)application, kHUDAXMessageTimeout);
        if (gAXGetPid) {
            result.pid = gAXGetPid((__bridge AXElement)application);
            result.frontmost = HUDProcessNameForPID(result.pid);
        }
        NSUInteger nodes = 0;
        NSString *matched = nil;
        NSString *verdict = HUDAXWalkTree(application, digest, roles, hints, &nodes, &matched);
        result.nodes = nodes;
        attempts = [NSString stringWithFormat:@"frontmost(pid=%d,%@)=%@", (int)result.pid,
                    result.frontmost ?: @"?", verdict ? @"match" : @"no-statusbar"];
        if (verdict) {
            result.answer = [verdict containsString:@"AXHidden"] || [verdict containsString:@"zero sized"]
                ? @"hidden" : @"visible";
            result.detail = verdict;
            result.digest = [NSString stringWithFormat:@"%@ | %@", digest, verdict];
            return result;
        }
        if (nodes == 0)
            focusedError = @"front most application returned an empty tree";
    }

    // Second choice: SpringBoard itself. On the home screen, the lock screen and
    // the app switcher *it* is the front most application, and its own status bar
    // is the one on screen. The system wide element does not always hand out the
    // focused application (-25216 on iOS 16), so ask for the process directly.
    pid_t springboard = HUDSpringBoardPID();
    if (gAXApplication && springboard > 0) {
        id board = nil;
        @try {
            AXElement element = gAXApplication(springboard);
            if (element) board = CFBridgingRelease(element);
        } @catch (NSException *exception) {
            board = nil;
        }
        if (board) {
            if (gAXSetTimeout) gAXSetTimeout((__bridge AXElement)board, kHUDAXMessageTimeout);
            if (!result.frontmost) {
                result.frontmost = HUDProcessNameForPID(springboard);
                result.pid = springboard;
            }
            NSUInteger nodes = 0;
            NSString *matched = nil;
            if (digest.length) [digest appendString:@" | springboard: "];
            NSString *verdict = HUDAXWalkTree(board, digest, roles, hints, &nodes, &matched);
            result.nodes += nodes;
            attempts = [attempts stringByAppendingFormat:@" %@ springboard(pid=%d)=%@",
                        attempts.length ? @"" : @"", (int)springboard,
                        verdict ? @"match" : @"no-statusbar"];
            if (verdict) {
                result.answer = [verdict containsString:@"AXHidden"] || [verdict containsString:@"zero sized"]
                    ? @"hidden" : @"visible";
                result.detail = [NSString stringWithFormat:@"%@ (springboard)", verdict];
                result.digest = [NSString stringWithFormat:@"%@ | %@", digest, verdict];
                return result;
            }
        }
    }

    NSMutableString *roleSummary = [NSMutableString string];
    for (NSString *key in [[roles allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (roleSummary.length) [roleSummary appendString:@","];
        [roleSummary appendFormat:@"%@:%@", key, roles[key]];
    }
    result.answer = @"unknown";
    result.digest = [NSString stringWithFormat:@"%@ | roles={%@} hints=%@",
                     digest.length ? digest : @"(empty tree)", roleSummary,
                     hints.count ? [hints componentsJoinedByString:@","] : @"none"];
    result.detail = [NSString stringWithFormat:@"no status bar element in the tree (nodes=%lu%@%@%@)",
                     (unsigned long)result.nodes,
                     focusedError ? [NSString stringWithFormat:@"; %@", focusedError] : @"",
                     attempts.length ? [NSString stringWithFormat:@"; tried %@", attempts] : @"",
                     loadNote.length ? @"" : @""];
    return result;
}

#pragma mark - Reading

@implementation HUDStatusBarReading
- (NSString *)hideReasonName
{
    switch (self.hideReason) {
        case HUDHideReasonLocked: return @"locked";
        case HUDHideReasonStatusBar: return @"statusbar-hidden";
        case HUDHideReasonNone: return @"none";
    }
    return @"none";
}

- (NSString *)layerName
{
    switch (self.layer) {
        case HUDStatusBarLayerAX: return @"ax";
        case HUDStatusBarLayerHeuristic: return @"heuristic";
        case HUDStatusBarLayerNone: return @"none";
    }
    return @"none";
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<HUDStatusBarReading layer=%@ reason=%@ visible=%d detail=%@>",
            self.layerName, self.hideReasonName, (int)self.statusBarVisible, self.detail];
}
@end

#pragma mark - Probe

/// One walk of the tree costs a few dozen IPC round trips, so it is rate
/// limited: the main queue asks once a second, the tree is walked at most once
/// every `kHUDProbeMinimumGap` seconds and never twice at the same time.
static const NSTimeInterval kHUDProbeMinimumGap = 1.5;
/// An answer older than this is not trusted any more and the heuristic decides.
static const NSTimeInterval kHUDProbeFreshness = 4.0;

@implementation HUDStatusBarProbe {
    NSLock *_lock;
    dispatch_queue_t _queue;
    BOOL _inFlight;
    NSTimeInterval _lastStart;
    NSTimeInterval _probeCount;

    NSString *_axAnswer;
    NSString *_axDetail;
    NSString *_axDigest;
    NSString *_axFrontmost;
    NSTimeInterval _axAt;
    NSUInteger _axNodes;
    pid_t _axPid;
    NSString *_lastProbeError;
    NSTimeInterval _lastProbeDuration;
}

+ (instancetype)sharedProbe
{
    static HUDStatusBarProbe *probe = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        probe = [[HUDStatusBarProbe alloc] init];
    });
    return probe;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _queue = dispatch_queue_create("com.leemin.helium.statusbar", DISPATCH_QUEUE_SERIAL);
        _axAnswer = @"unknown";
        _axDetail = @"not sampled yet";
    }
    return self;
}

- (NSUInteger)probeCount
{
    [_lock lock];
    NSUInteger count = (NSUInteger)_probeCount;
    [_lock unlock];
    return count;
}

- (void)kickProbe
{
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [_lock lock];
    if (_inFlight || (now - _lastStart) < kHUDProbeMinimumGap) {
        [_lock unlock];
        return;
    }
    _inFlight = YES;
    _lastStart = now;
    [_lock unlock];

    __weak HUDStatusBarProbe *weakSelf = self;
    dispatch_async(_queue, ^{
        HUDStatusBarProbe *self_ = weakSelf;
        if (!self_) return;
        NSTimeInterval start = [[NSDate date] timeIntervalSince1970];
        HUDStatusBarAXResult *result = nil;
        @try {
            result = HUDRunAXProbe();
        } @catch (NSException *exception) {
            result = [[HUDStatusBarAXResult alloc] init];
            result.answer = @"unknown";
            result.detail = [NSString stringWithFormat:@"probe threw %@: %@", exception.name, exception.reason];
        } @catch (...) {
            result = [[HUDStatusBarAXResult alloc] init];
            result.answer = @"unknown";
            result.detail = @"probe threw an unknown exception";
        }
        NSTimeInterval duration = [[NSDate date] timeIntervalSince1970] - start;

        [self_->_lock lock];
        self_->_axAnswer = result.answer ?: @"unknown";
        self_->_axDetail = result.detail ?: @"";
        self_->_axDigest = result.digest ?: @"";
        self_->_axFrontmost = result.frontmost ?: HUDProcessNameForPID(result.pid);
        self_->_axPid = result.pid;
        self_->_axNodes = result.nodes;
        self_->_axAt = [[NSDate date] timeIntervalSince1970];
        self_->_probeCount = self_->_probeCount + 1;
        self_->_lastProbeDuration = duration;
        self_->_lastProbeError = [result.answer isEqualToString:@"unknown"] ? result.detail : @"";
        self_->_inFlight = NO;
        [self_->_lock unlock];
    });
}

- (HUDStatusBarReading *)readingLocked:(BOOL)locked
                             landscape:(BOOL)landscape
                       hideInLandscape:(BOOL)hideInLandscape
{
    [self kickProbe];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *axAnswer = @"unknown";
    NSString *axDetail = @"";
    NSTimeInterval axAt = 0;
    [_lock lock];
    axAnswer = [_axAnswer copy];
    axDetail = [_axDetail copy];
    axAt = _axAt;
    [_lock unlock];

    BOOL axFresh = (axAt > 0) && (now - axAt) <= kHUDProbeFreshness;

    HUDStatusBarReading *reading = [[HUDStatusBarReading alloc] init];
    reading.statusBarVisible = YES;
    reading.statusBarHidden = NO;

    // Priority 1 (hard): a locked screen hides the HUD, as it always did.
    if (locked) {
        reading.layer = HUDStatusBarLayerHeuristic;
        reading.hideReason = HUDHideReasonLocked;
        reading.statusBarVisible = NO;
        reading.statusBarHidden = YES;
        reading.detail = @"screen locked (SBGetScreenLockStatus)";
        return reading;
    }

    // Priority 2: the accessibility tree, when it actually answered.
    if (axFresh && [axAnswer isEqualToString:@"visible"]) {
        reading.layer = HUDStatusBarLayerAX;
        reading.hideReason = HUDHideReasonNone;
        reading.statusBarVisible = YES;
        reading.statusBarHidden = NO;
        reading.detail = axDetail.length ? axDetail : @"status bar element on screen";
        return reading;
    }
    if (axFresh && [axAnswer isEqualToString:@"hidden"]) {
        reading.layer = HUDStatusBarLayerAX;
        reading.hideReason = HUDHideReasonStatusBar;
        reading.statusBarVisible = NO;
        reading.statusBarHidden = YES;
        reading.detail = axDetail.length ? axDetail : @"status bar element hidden or zero sized";
        return reading;
    }

    // Priority 3: the heuristic -- landscape is what a full screen video or a
    // game looks like, and neither of them draws a status bar.
    if (landscape && hideInLandscape) {
        reading.layer = HUDStatusBarLayerHeuristic;
        reading.hideReason = HUDHideReasonStatusBar;
        reading.statusBarVisible = NO;
        reading.statusBarHidden = YES;
        reading.detail = @"landscape orientation (FBSOrientationObserver)";
        return reading;
    }

    // Nothing could decide it: keep the HUD on screen, and say so.
    reading.layer = HUDStatusBarLayerNone;
    reading.hideReason = HUDHideReasonNone;
    reading.statusBarVisible = YES;
    reading.statusBarHidden = NO;
    NSString *why = axAt > 0
        ? [NSString stringWithFormat:@"no accessibility answer yet (%@)", axDetail.length ? axDetail : @"pending"]
        : @"accessibility probe has not answered yet";
    reading.detail = why;
    return reading;
}

- (NSString *)diagnosticsReport
{
    NSMutableString *out = [NSMutableString string];

    [_lock lock];
    NSString *answer = [_axAnswer copy];
    NSString *detail = [_axDetail copy];
    NSString *digest = [_axDigest copy];
    NSString *frontmost = [_axFrontmost copy];
    NSTimeInterval axAt = _axAt;
    NSUInteger nodes = _axNodes;
    pid_t pid = _axPid;
    NSUInteger count = (NSUInteger)_probeCount;
    NSTimeInterval duration = _lastProbeDuration;
    NSString *error = [_lastProbeError copy];
    [_lock unlock];

    NSTimeInterval age = axAt > 0 ? [[NSDate date] timeIntervalSince1970] - axAt : -1;
    NSMutableString *clean = [NSMutableString stringWithString:detail ?: @""];
    [clean replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, clean.length)];

    [out appendFormat:@"statusbarAX: load=\"%@\" answer=%@ age=%.1fs samples=%lu nodes=%lu pid=%d app=%@ took=%.0fms\n",
        HUDAXLoadNoteIfAny() ?: @"(not loaded yet)", answer ?: @"?", age, count, (unsigned long)nodes, (int)pid,
        frontmost.length ? frontmost : @"?", duration * 1000.0];
    [out appendFormat:@"statusbarAX: detail=\"%@\"\n", clean];
    [out appendFormat:@"statusbarAX: tree=%@\n", digest.length ? digest : @"(not sampled)"];
    if (error.length) {
        NSMutableString *cleanError = [NSMutableString stringWithString:error];
        [cleanError replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, cleanError.length)];
        [out appendFormat:@"statusbarAX: lastError=\"%@\"\n", cleanError];
    }
    NSString *springboard = HUDProcessNameForPID(HUDSpringBoardPID());
    [out appendFormat:@"statusbarAX: springboardPid=%d(%@) frontmostBundle=%@\n",
        (int)HUDSpringBoardPID(), springboard ?: @"?", HUDFrontmostApplicationIdentifier() ?: @"?"];
    return out;
}

@end
