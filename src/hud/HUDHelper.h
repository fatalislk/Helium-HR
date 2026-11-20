#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

OBJC_EXTERN BOOL IsHUDEnabled(void);
OBJC_EXTERN void SetHUDEnabled(BOOL isEnabled);

/// The switch's state as it is stored in the HUD settings file, which is what
/// the HUD itself can read. `known` is NO when the key has never been written,
/// ie when this version of the app has never toggled the switch -- the HUD then
/// treats itself as wanted, because something started it on purpose.
OBJC_EXTERN BOOL HUDEnabledPreference(BOOL *known);
OBJC_EXTERN void SetHUDEnabledPreference(BOOL enabled);

/// Kill the HUD by the pid in hud.pid, after checking that the pid really is
/// this bundle's executable: pids are reused and killing a stranger would be
/// far worse than a HUD that lingers.
OBJC_EXTERN BOOL TerminateHUDProcessIfRunning(NSString **how);
OBJC_EXTERN void waitForNotification(void (^onFinish)(), BOOL isEnabled);

/// The build a running HUD came from, as "modification time-size" of the
/// executable. Installing a new tipa replaces the file on disk but not the
/// process already on screen, and the version fields cannot tell the difference
/// (they are deliberately frozen at the upstream 3.2.6), so the file is what
/// says which build is running.
OBJC_EXTERN NSString *HUDBuildFingerprint(void);

/// Called by the HUD as it starts, next to the pid it writes.
OBJC_EXTERN void RecordHUDBuildFingerprint(void);

/// Called by `-exit`, next to unlinking the pid.
OBJC_EXTERN void ClearHUDBuildFingerprint(void);

/// YES only when a HUD is running and it is not this build. A stopped HUD is
/// never stale -- starting one is the switch's job, not this.
OBJC_EXTERN BOOL IsHUDBuildStale(void);

NS_ASSUME_NONNULL_END