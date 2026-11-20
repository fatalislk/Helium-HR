//
//  HRMonitor.mm
//  Helium
//
//  A Bluetooth Heart Rate client for the HUD.
//
//  The band (a Google Fitbit Air) advertises the standard Heart Rate service
//  180D and notifies its measurement characteristic 2A37 once a second. That
//  needs no pairing, no key and no vendor protocol, which is the whole reason
//  this file exists: the previous source was a local sqlite store that lags the
//  wrist by minutes.
//
//  Two things here are less obvious than they look.
//
//  First, the peripheral is never identified by UUID. CoreBluetooth hands out a
//  per-app identifier, so the same band is a different CBPeripheral on every
//  install; only the advertised service (and, as a backstop, the name) is
//  stable.
//
//  Second, the HUD is a process posix_spawn'd out of the app bundle, not a
//  normal launch, and CoreBluetooth is not guaranteed to be usable from there.
//  Every frame therefore also lands in a small text file, which is how anyone
//  -- including the person debugging this on a phone with no console -- can
//  tell whether the connection is alive, and which lets the app host the
//  connection instead if the HUD cannot.
//

#import "HRMonitor.h"

#import <CoreBluetooth/CoreBluetooth.h>

#include <atomic>

static NSString *const kHRServiceUUIDString = @"180D";
static NSString *const kHRMeasurementUUIDString = @"2A37";
static NSString *const kHREquipmentName = @"Google Fitbit Air";

/// Read by anyone who wants to know whether Bluetooth is alive inside the HUD:
/// a `#` header line with the central's state, then the last handful of
/// "<bpm> <epoch>" lines, newest last.
static NSString *const kHRDebugFilePath = @"/var/mobile/Library/Preferences/helium_hr.txt";

/// Scan with the service filter first; the name is only a backstop for a band
/// that has stopped putting 180D in its advertisement.
static const NSTimeInterval kHRScanPassSeconds = 15.0;
/// A connect that has not completed by then is treated as a failure; giving up
/// is what lets the retry backoff run instead of hanging forever.
static const NSTimeInterval kHRConnectTimeoutSeconds = 20.0;
/// Enough history to see that the timestamps are moving, small enough to be
/// rewritten every few seconds without anybody noticing.
static const NSUInteger kHRDebugHistoryLines = 20;
static const NSTimeInterval kHRDebugMaxAge = 5.0;

// Shared between the Bluetooth queue and the HUD's once-a-second render tick,
// which is why they are atomic rather than plain statics.
static std::atomic<int32_t> gHeartRateBPM(-1);
static std::atomic<int64_t> gHeartRateTimestampMs(0);

static int64_t HRNowMs(void)
{
    return (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

/// Decode a Heart Rate Measurement. Flags bit 0 says whether the value is a
/// UINT8 or a little-endian UINT16 -- the band sends "01 57" for 87, i.e. the
/// short form.
static NSInteger HRBPMFromMeasurement(NSData *data)
{
    const uint8_t *v = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    if (length < 2) return -1;

    uint8_t flags = v[0];
    NSInteger bpm;
    if (flags & 0x01) {
        bpm = v[1];
    } else {
        if (length < 3) return -1;
        bpm = (NSInteger)((uint16_t)v[1] | ((uint16_t)v[2] << 8));
    }
    // 0 is "sensor not in contact" on many bands, and anything above 300 is
    // not a person; either way it is better to keep the last good reading.
    if (bpm < 20 || bpm > 300) return -1;
    return bpm;
}

@interface HRMonitor () <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

@implementation HRMonitor {
    CBCentralManager *_central;
    CBPeripheral *_peripheral;
    dispatch_queue_t _queue;
    BOOL _permissionOnly;
    BOOL _scanning;
    BOOL _nameScan;
    NSUInteger _scanGeneration;
    NSInteger _retryDelay;
    NSUInteger _frames;
    NSTimeInterval _lastFlush;
    NSMutableArray<NSString *> *_recent;
    NSString *_status;
}

#pragma mark - Lifecycle

+ (instancetype)shared
{
    static HRMonitor *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[HRMonitor alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.leemin.helium.hr", DISPATCH_QUEUE_SERIAL);
        _retryDelay = 5;
        _recent = [NSMutableArray array];
        _status = @"idle";
    }
    return self;
}

#pragma mark - Public API

+ (NSInteger)currentBPM
{
    if (gHeartRateTimestampMs.load() == 0) return -1;
    return (NSInteger)gHeartRateBPM.load();
}

+ (NSTimeInterval)lastUpdate
{
    int64_t ms = gHeartRateTimestampMs.load();
    return ms == 0 ? 0 : (NSTimeInterval)ms / 1000.0;
}

+ (void)startMonitoring
{
    HRMonitor *monitor = [self shared];
    dispatch_async(monitor->_queue, ^{
        [monitor _startOnQueue];
    });
}

+ (void)stopMonitoring
{
    HRMonitor *monitor = [self shared];
    dispatch_async(monitor->_queue, ^{
        monitor->_scanGeneration++;
        [monitor->_central stopScan];
        monitor->_scanning = NO;
        if (monitor->_peripheral) {
            [monitor->_central cancelPeripheralConnection:monitor->_peripheral];
            monitor->_peripheral = nil;
        }
        [monitor _setStatus:@"stopped"];
    });
}

+ (void)requestBluetoothPermission
{
    HRMonitor *monitor = [self shared];
    dispatch_async(monitor->_queue, ^{
        if (!monitor->_central) {
            monitor->_permissionOnly = YES;
            monitor->_central = [[CBCentralManager alloc] initWithDelegate:monitor
                                                                    queue:monitor->_queue
                                                                  options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
        }
        [monitor _setStatus:@"permission only"];
    });
}

+ (NSInteger)bpmFromDebugFileWithTimestamp:(NSTimeInterval *)outTimestamp
{
    if (outTimestamp) *outTimestamp = 0;
    NSString *text = [NSString stringWithContentsOfFile:kHRDebugFilePath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (text.length == 0) return -1;

    NSInteger bpm = -1;
    NSTimeInterval timestamp = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;
        NSArray<NSString *> *fields = [trimmed componentsSeparatedByString:@" "];
        if (fields.count < 2) continue;
        NSInteger value = [fields[0] integerValue];
        NSTimeInterval stamp = [fields[1] doubleValue];
        if (value <= 0 || stamp <= 0) continue;
        // The file keeps its lines in order, but nothing stops a torn write
        // from leaving an older one last, so the newest timestamp wins.
        if (stamp >= timestamp) {
            timestamp = stamp;
            bpm = value;
        }
    }
    if (outTimestamp) *outTimestamp = timestamp;
    return bpm;
}

#pragma mark - Bluetooth queue

- (void)_startOnQueue
{
    _permissionOnly = NO;
    if (!_central) {
        _central = [[CBCentralManager alloc] initWithDelegate:self
                                                        queue:_queue
                                                      options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
        // -centralManagerDidUpdateState: picks it up from here.
        return;
    }
    if (_central.state == CBManagerStatePoweredOn) {
        [self _startScanPass:NO];
    }
}

- (void)_startScanPass:(BOOL)nameScan
{
    if (!_central || _central.state != CBManagerStatePoweredOn) return;
    if (_peripheral) return;

    _scanGeneration++;
    NSUInteger generation = _scanGeneration;
    _scanning = YES;
    _nameScan = nameScan;

    [_central stopScan];
    NSArray *services = nameScan ? nil : @[[CBUUID UUIDWithString:kHRServiceUUIDString]];
    [_central scanForPeripheralsWithServices:services
                                     options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    [self _setStatus:nameScan ? @"scanning (name)" : @"scanning (180D)"];

    __weak HRMonitor *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHRScanPassSeconds * NSEC_PER_SEC)), _queue, ^{
        HRMonitor *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf->_scanGeneration || strongSelf->_peripheral) return;
        // Nothing on this pass: try the other one rather than scanning for a
        // service that may have dropped out of the packet forever.
        [strongSelf _startScanPass:!nameScan];
    });
}

/// Give up on a connect that never completed. Without this a band that accepts
/// the connection request and then goes quiet leaves the HUD waiting for good.
- (void)_armConnectWatchdog:(CBPeripheral *)peripheral
{
    __weak HRMonitor *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHRConnectTimeoutSeconds * NSEC_PER_SEC)), _queue, ^{
        HRMonitor *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_peripheral != peripheral) return;
        if (peripheral.state == CBPeripheralStateConnected) return;
        [strongSelf->_central cancelPeripheralConnection:peripheral];
        [strongSelf _handleLoss:@"connect timeout"];
    });
}

- (void)_handleLoss:(NSString *)reason
{
    _peripheral = nil;
    _scanning = NO;
    _scanGeneration++;   // cancels the pending scan-mode flip and watchdog
    [_central stopScan];

    NSTimeInterval delay = (NSTimeInterval)_retryDelay;
    _retryDelay = MIN(_retryDelay * 2, 30);
    [self _setStatus:[NSString stringWithFormat:@"%@ -> rescan in %.0fs", reason, delay]];
    _lastFlush = 0;
    [self _flushDebugFile];

    NSUInteger generation = _scanGeneration;
    __weak HRMonitor *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        HRMonitor *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_scanGeneration) return;
        [strongSelf _startScanPass:NO];
    });
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    if (central.state != CBManagerStatePoweredOn) {
        _scanning = NO;
        NSString *reason;
        switch (central.state) {
            case CBManagerStateUnauthorized: reason = @"bluetooth unauthorized"; break;
            case CBManagerStateUnsupported:  reason = @"bluetooth unsupported"; break;
            case CBManagerStatePoweredOff:   reason = @"bluetooth off"; break;
            case CBManagerStateResetting:    reason = @"bluetooth resetting"; break;
            default:                         reason = @"bluetooth unknown"; break;
        }
        [self _setStatus:reason];
        return;
    }
    if (_permissionOnly) {
        [self _setStatus:@"powered on (permission only)"];
        return;
    }
    [self _startScanPass:NO];
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI
{
    if (_peripheral) return;

    NSString *name = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey];
    if (_nameScan) {
        // Only the unfiltered pass needs to look at the name.
        BOOL nameHit = [name isEqualToString:kHREquipmentName] ||
                       [name.lowercaseString containsString:@"fitbit"];
        if (!nameHit) return;
    }

    _peripheral = peripheral;
    _scanGeneration++;   // stops the scan-mode flip and any pending watchdog
    _scanning = NO;
    [central stopScan];
    peripheral.delegate = self;
    [self _setStatus:[NSString stringWithFormat:@"found %@ (%@ dBm), connecting", name ?: @"?", RSSI]];
    [central connectPeripheral:peripheral
                       options:@{CBConnectPeripheralOptionNotifyOnDisconnectionKey: @YES}];
    [self _armConnectWatchdog:peripheral];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    _retryDelay = 5;
    [self _setStatus:@"connected, discovering 180D"];
    peripheral.delegate = self;
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kHRServiceUUIDString]]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    [self _handleLoss:[NSString stringWithFormat:@"connect failed (%@)", error.localizedDescription ?: @"?"]];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    _retryDelay = 5;
    [self _handleLoss:error ? [NSString stringWithFormat:@"disconnected (%@)", error.localizedDescription]
                            : @"disconnected"];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    if (error) {
        [self _handleLoss:[NSString stringWithFormat:@"services (%@)", error.localizedDescription]];
        return;
    }
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:kHRServiceUUIDString]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:kHRMeasurementUUIDString]]
                                     forService:service];
            return;
        }
    }
    // A band that never says 180D after connecting is not the band we want.
    [self _handleLoss:@"no 180D service"];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didDiscoverCharacteristicsForService:(CBService *)service
                                error:(NSError *)error
{
    if (error) {
        [self _handleLoss:[NSString stringWithFormat:@"characteristics (%@)", error.localizedDescription]];
        return;
    }
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kHRMeasurementUUIDString]]) {
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
            return;
        }
    }
    [self _handleLoss:@"no 2A37 characteristic"];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
                                       error:(NSError *)error
{
    if (error) {
        [self _handleLoss:[NSString stringWithFormat:@"notify (%@)", error.localizedDescription]];
        return;
    }
    if (!characteristic.isNotifying) {
        [self _handleLoss:@"notify refused"];
        return;
    }
    _retryDelay = 5;
    [self _setStatus:@"subscribed to 2A37"];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
                             error:(NSError *)error
{
    if (error) {
        [self _handleLoss:[NSString stringWithFormat:@"notify (%@)", error.localizedDescription]];
        return;
    }
    NSInteger bpm = HRBPMFromMeasurement(characteristic.value);
    if (bpm < 0) return;

    _frames++;
    gHeartRateBPM.store((int32_t)bpm);
    gHeartRateTimestampMs.store(HRNowMs());
    [self _recordFrame:bpm];
}

#pragma mark - Debug file

/// Status changes are rare and always worth a write; frames are once a second
/// and are not, so they are batched -- rewriting a file 86,400 times a day for
/// a value nobody reads would be its own bug.
- (void)_setStatus:(NSString *)status
{
    _status = status ?: @"";
    _lastFlush = 0;
    [self _flushDebugFile];
}

- (void)_recordFrame:(NSInteger)bpm
{
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [_recent addObject:[NSString stringWithFormat:@"%ld %.0f", (long)bpm, now]];
    while (_recent.count > kHRDebugHistoryLines) {
        [_recent removeObjectAtIndex:0];
    }
    if (now - _lastFlush < kHRDebugMaxAge && (_frames % 30) != 0) return;
    _lastFlush = now;
    [self _flushDebugFile];
}

- (void)_flushDebugFile
{
    NSString *header = [NSString stringWithFormat:
        @"# helium HRMonitor: %@ | central=%ld connected=%d scanning=%d frames=%lu",
        _status,
        (long)(_central ? _central.state : -1),
        (_peripheral.state == CBPeripheralStateConnected) ? 1 : 0,
        _scanning ? 1 : 0,
        (unsigned long)_frames];
    NSString *body = _recent.count ? [_recent componentsJoinedByString:@"\n"] : @"# no frames yet";
    NSString *text = [NSString stringWithFormat:@"%@\n%@\n", header, body];
    [text writeToFile:kHRDebugFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end
