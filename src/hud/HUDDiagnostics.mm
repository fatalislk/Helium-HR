//
//  HUDDiagnostics.mm
//  Helium
//

#import "HUDDiagnostics.h"

#import <UIKit/UIKit.h>
#import <unistd.h>

#import "../widgets/WidgetManager.h"

static NSString *const kHUDDiagnosticsFilePath = @"/var/mobile/Library/Preferences/helium_hud_debug.txt";

/// The same file, written to places that can actually be read from a shell on
/// this device: the Preferences directory is not necessarily visible outside the
/// app's own mount view, while the app's Caches directory always is.
static NSArray<NSString *> *HUDDiagnosticsPaths(void)
{
    static NSArray<NSString *> *paths = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray arrayWithObject:kHUDDiagnosticsFilePath];
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        if (caches.length) {
            [list addObject:[caches stringByAppendingPathComponent:@"hud_debug.txt"]];
        }
        [list addObject:@"/tmp/helium_hud_debug.txt"];
        paths = list;
    });
    return paths;
}

/// Every mark is kept, because the interesting case is the one where the last
/// mark is not the one you expected: "window created" with no "viewDidLoad"
/// after it says the view never loaded at all.
static const NSUInteger kHUDDiagnosticsMaxMarks = 40;
/// Five seconds is the interval asked for, and it is also about how long a
/// person waits before deciding that nothing is going to happen.
static const NSTimeInterval kHUDDiagnosticsInterval = 5.0;

static NSString * (^gHUDDiagnosticsReport)(void) = nil;
static NSMutableArray<NSString *> *gHUDDiagnosticsMarks = nil;
static dispatch_source_t gHUDDiagnosticsTimer = nil;
static NSTimeInterval gHUDDiagnosticsStartedAt = 0;

NSString *HUDDiagnosticsPath(void)
{
    return kHUDDiagnosticsFilePath;
}

static NSString *HUDDiagnosticsNowString(void)
{
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        [formatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    });
    return [formatter stringFromDate:[NSDate date]];
}

/// One write, whole file, no appending: the file always describes *now*, which
/// is the only thing that makes a five-second-old report worth reading.
static void HUDDiagnosticsFlush(NSString *body)
{
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"# helium HUD diagnostics, written by pid %d\n", getpid()];
    [text appendFormat:@"time=%@ epoch=%.0f uptime=%.0fs\n",
        HUDDiagnosticsNowString(),
        [[NSDate date] timeIntervalSince1970],
        gHUDDiagnosticsStartedAt > 0 ? [[NSDate date] timeIntervalSince1970] - gHUDDiagnosticsStartedAt : 0];
    if (gHUDDiagnosticsMarks.count) {
        [text appendString:@"marks:\n"];
        for (NSString *mark in gHUDDiagnosticsMarks) {
            [text appendFormat:@"  %@\n", mark];
        }
    }
    if (body.length) {
        [text appendString:body];
        if (![body hasSuffix:@"\n"]) [text appendString:@"\n"];
    }
    for (NSString *path in HUDDiagnosticsPaths()) {
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void HUDDiagnosticsMark(NSString *mark)
{
    if (mark.length == 0) return;
    if (!gHUDDiagnosticsMarks) gHUDDiagnosticsMarks = [NSMutableArray array];
    [gHUDDiagnosticsMarks addObject:[NSString stringWithFormat:@"%@ %@", HUDDiagnosticsNowString(), mark]];
    while (gHUDDiagnosticsMarks.count > kHUDDiagnosticsMaxMarks) {
        [gHUDDiagnosticsMarks removeObjectAtIndex:0];
    }
    HUDDiagnosticsWriteNow();
}

void HUDDiagnosticsWriteNow(void)
{
    NSString *body = nil;
    if (gHUDDiagnosticsReport) {
        @try {
            body = gHUDDiagnosticsReport();
        } @catch (NSException *exception) {
            body = [NSString stringWithFormat:@"report failed: %@: %@\n", exception.name, exception.reason];
        }
    }
    HUDDiagnosticsFlush(body);
}

void HUDDiagnosticsStart(NSString * (^report)(void))
{
    dispatch_async(dispatch_get_main_queue(), ^{
        gHUDDiagnosticsReport = [report copy];
        if (gHUDDiagnosticsStartedAt == 0) {
            gHUDDiagnosticsStartedAt = [[NSDate date] timeIntervalSince1970];
        }
        // Main queue, so the report can read views and frames without racing
        // the HUD's own layout pass.
        if (!gHUDDiagnosticsTimer) {
            gHUDDiagnosticsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gHUDDiagnosticsTimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                (uint64_t)(kHUDDiagnosticsInterval * NSEC_PER_SEC),
                (uint64_t)(0.5 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gHUDDiagnosticsTimer, ^{
                HUDDiagnosticsWriteNow();
            });
            dispatch_resume(gHUDDiagnosticsTimer);
        }
        HUDDiagnosticsWriteNow();
    });
}
