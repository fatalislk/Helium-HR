//
//  HRMonitor.h
//  Helium
//
//  Live heart rate straight off the band's standard Bluetooth Heart Rate
//  service (180D / characteristic 2A37), replacing a local database read that
//  only ever saw data minutes old.
//
//  Everything that touches CoreBluetooth lives in the .mm; this header stays
//  Foundation-only so that the Swift side can see it through the bridging
//  header without dragging CoreBluetooth into every Swift file.
//

#import <Foundation/Foundation.h>

@interface HRMonitor : NSObject

/// Latest beats per minute, or -1 when nothing has ever arrived. Freshness is
/// the caller's business: see +lastUpdate.
+ (NSInteger)currentBPM;

/// UNIX time of the last reading, or 0 when there has never been one.
+ (NSTimeInterval)lastUpdate;

/// Scan, connect, subscribe. Idempotent -- calling it twice does not open a
/// second central manager. Must be called from a process that has Bluetooth
/// permission; in the HUD that permission is inherited from the app's grant.
+ (void)startMonitoring;

/// Stop scanning and drop the link (used when the HUD is torn down).
+ (void)stopMonitoring;

/// Create a central manager and keep it, without scanning. The first
/// CBCentralManager in a bundle is what makes iOS put up its Bluetooth prompt,
/// so the app calls this from a button while it still has a real UI.
+ (void)requestBluetoothPermission;

/// Latest "<bpm> <epoch>" line of the debug file written by the monitoring
/// process. This is the fallback path: the app can host the connection and the
/// HUD, which cannot always get Bluetooth of its own, reads what it wrote.
+ (NSInteger)bpmFromDebugFileWithTimestamp:(NSTimeInterval *)outTimestamp;

/// pid of the process that wrote the newest debug file: which side of the pair
/// is holding the band, since both the app and the HUD can write it.
+ (NSInteger)debugFileWriterPID;

/// Where the connection has got to, in words, for the HUD's diagnostics file:
/// "scanning (180D)", "subscribed to 2A37", "bluetooth unauthorized"...
+ (NSString *)statusDescription;

/// YES while the band is actually connected and being read from.
+ (BOOL)isBandConnected;

@end
