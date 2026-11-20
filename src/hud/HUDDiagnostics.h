//
//  HUDDiagnostics.h
//  Helium
//
//  A HUD that draws nothing looks exactly like a HUD that is not running, a HUD
//  with no widget sets, a HUD whose widgets are off screen and a HUD whose
//  window was never shown -- and on a phone there is no console to tell them
//  apart. This writes one small text file that does: the window's level and
//  frame, every widget set's configuration, every label's text and frame, and
//  whether the band is connected.
//
//  Read it over ssh:
//      /var/mobile/Library/Preferences/helium_hud_debug.txt
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Called by the process that wants a report; returns the body, called on the
/// main thread every few seconds. Registering twice replaces the block.
OBJC_EXTERN void HUDDiagnosticsStart(NSString * (^report)(void));

/// A one-line note about how far startup has got. Written to the file straight
/// away, so it survives a HUD that never finishes launching.
OBJC_EXTERN void HUDDiagnosticsMark(NSString *mark);

/// Refresh the file right now (called on reloads, where a stale picture would
/// be worse than no picture).
OBJC_EXTERN void HUDDiagnosticsWriteNow(void);

/// Path of the file, for anyone who wants to print it.
OBJC_EXTERN NSString *HUDDiagnosticsPath(void);

NS_ASSUME_NONNULL_END
