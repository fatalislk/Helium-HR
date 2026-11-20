#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDRootViewController: UIViewController
- (void)resetLoopTimer;
- (void)pauseLoopTimer;
- (void)resumeLoopTimer;
- (void)reloadUserDefaults;

/// Re-decides whether the HUD should be on screen right now: the status bar
/// went away, came back, the screen locked, or the device turned. Called from
/// notifications and from a one second backstop timer.
- (void)refreshHUDVisibilityWithTrigger:(NSString *)trigger;

/// A settings change arrived. Reloads the widget configuration, and leaves the
/// process entirely when the switch in the app now says the HUD is off.
- (void)handleReloadNotification;
@end

NS_ASSUME_NONNULL_END