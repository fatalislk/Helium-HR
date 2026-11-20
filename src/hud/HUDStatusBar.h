//
//  HUDStatusBar.h
//  Helium
//
//  Follows the system status bar: when iOS does not show a status bar (a
//  full screen video, a game, the app switcher, the lock screen) the HUD has
//  nothing to sit next to and should get out of the way; when the status bar
//  comes back the HUD should come back with it.
//
//  The answer is one of three layers, in priority order:
//    1. ax         -- the accessibility tree of the front most application
//                     says whether a status bar element exists and is on
//                     screen. Only used when the probe returns an answer.
//    2. heuristic  -- screen locked, or the device is in landscape (the
//                     shape a full screen video or a game has).
//    3. none       -- nothing could decide it: keep the HUD visible, which is
//                     the behaviour before any of this existed.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, HUDHideReason) {
    HUDHideReasonNone = 0,
    HUDHideReasonLocked,
    HUDHideReasonStatusBar,
};

/// Where the answer came from. Printed in the diagnostics file as `layer=`.
typedef NS_ENUM(NSInteger, HUDStatusBarLayer) {
    HUDStatusBarLayerNone = 0,
    HUDStatusBarLayerHeuristic,
    HUDStatusBarLayerAX,
};

NS_ASSUME_NONNULL_BEGIN

@interface HUDStatusBarReading : NSObject
@property (nonatomic) HUDStatusBarLayer layer;
@property (nonatomic) HUDHideReason hideReason;
@property (nonatomic) BOOL statusBarVisible;
@property (nonatomic) BOOL statusBarHidden;
/// One line, quoted in the diagnostics file: why this reading says what it says.
@property (nonatomic, copy) NSString *detail;
/// "statusbar-hidden" / "locked" / "none", the word the diagnostics file uses.
@property (nonatomic, readonly) NSString *hideReasonName;
@property (nonatomic, readonly) NSString *layerName;
@end

@interface HUDStatusBarProbe : NSObject

+ (instancetype)sharedProbe;

/// Never blocks the caller: returns what is known right now (the last
/// accessibility result, if it is still fresh) and starts a background probe
/// when one is due. Safe to call from the main queue once a second.
- (HUDStatusBarReading *)readingLocked:(BOOL)locked
                             landscape:(BOOL)landscape
                    hideInLandscape:(BOOL)hideInLandscape;

/// The multi-line block appended to `helium_hud_debug.txt`.
- (NSString *)diagnosticsReport;

/// How many times the accessibility tree has been walked, for the report.
@property (nonatomic, readonly) NSUInteger probeCount;

@end

NS_ASSUME_NONNULL_END
