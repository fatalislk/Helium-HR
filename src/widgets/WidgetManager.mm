//
//  WidgetManager.m
//  
//
//  Created by lemin on 10/6/23.
//

#import <Foundation/Foundation.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>
#import "WidgetManager.h"
#import <IOKit/IOKitLib.h>
#import "../extensions/LunarDate.h"
#import "../extensions/FontUtils.h"
#import "../extensions/WeatherUtils.h"
#import <sqlite3.h>
#import <glob.h>

// Thanks to: https://github.com/lwlsw/NetworkSpeed13

#define KILOBITS 1000
#define MEGABITS 1000000
#define GIGABITS 1000000000
#define KILOBYTES (1 << 10)
#define MEGABYTES (1 << 20)
#define GIGABYTES (1 << 30)
#define SHOW_ALWAYS 1
// #define INLINE_SEPARATOR "\t"

// #pragma mark - Formatting Methods
// static unsigned char getSeparator(NSMutableAttributedString *currentAttributed)
// {
//     return [[currentAttributed string] isEqualToString:@""] ? *"" : *"\t";
// }

#pragma mark - Widget-specific Variables
// MARK: 0 - Date Widget
static NSDateFormatter *formatter = nil;

// MARK: Net Speed Widget
static uint8_t DATAUNIT = 0;

typedef struct {
    uint64_t inputBytes;
    uint64_t outputBytes;
} UpDownBytes;

static uint64_t prevOutputBytes = 0, prevInputBytes = 0;
static NSAttributedString *attributedUploadPrefix = nil;
static NSAttributedString *attributedDownloadPrefix = nil;
static NSAttributedString *attributedUploadPrefix2 = nil;
static NSAttributedString *attributedDownloadPrefix2 = nil;

#pragma mark - Date Widget
static NSString* formattedDate(NSString *dateFormat, NSString *dateLocale)
{
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:dateLocale];
    }
    NSDate *currentDate = [NSDate date];
    NSString *newDateFormat = [LunarDate getChineseCalendarWithDate:currentDate format:dateFormat];
    [formatter setDateFormat:newDateFormat];
    return [formatter stringFromDate:currentDate];
}

#pragma mark - Net Speed Widgets
static UpDownBytes getUpDownBytes()
{
    struct ifaddrs *ifa_list = 0, *ifa;
    UpDownBytes upDownBytes;
    upDownBytes.inputBytes = 0;
    upDownBytes.outputBytes = 0;
    
    if (getifaddrs(&ifa_list) == -1) return upDownBytes;

    for (ifa = ifa_list; ifa; ifa = ifa->ifa_next)
    {
        /* Skip invalid interfaces */
        if (ifa->ifa_name == NULL || ifa->ifa_addr == NULL || ifa->ifa_data == NULL)
            continue;
        
        /* Skip interfaces that are not link level interfaces */
        if (AF_LINK != ifa->ifa_addr->sa_family)
            continue;

        /* Skip interfaces that are not up or running */
        if (!(ifa->ifa_flags & IFF_UP) && !(ifa->ifa_flags & IFF_RUNNING))
            continue;
        
        /* Skip interfaces that are not ethernet or cellular */
        if (strncmp(ifa->ifa_name, "en", 2) && strncmp(ifa->ifa_name, "pdp_ip", 6))
            continue;
        
        struct if_data *if_data = (struct if_data *)ifa->ifa_data;
        
        upDownBytes.inputBytes += if_data->ifi_ibytes;
        upDownBytes.outputBytes += if_data->ifi_obytes;
    }
    
    freeifaddrs(ifa_list);
    return upDownBytes;
}

static NSString* formattedSpeed(uint64_t bytes, NSInteger minUnit)
{
    if (0 == DATAUNIT) {
        // Get min units first
        if (minUnit == 1 && bytes < KILOBYTES) return @"0 KB/s";
        else if (minUnit == 2 && bytes < MEGABYTES) return @"0 MB/s";
        else if (minUnit == 3 && bytes < GIGABYTES) return @"0 GB/s";

        if (bytes < KILOBYTES) return [NSString stringWithFormat:@"%.0f B/s", (double)bytes];
        else if (bytes < MEGABYTES) return [NSString stringWithFormat:@"%.0f KB/s", (double)bytes / KILOBYTES];
        else if (bytes < GIGABYTES) return [NSString stringWithFormat:@"%.2f MB/s", (double)bytes / MEGABYTES];
        else return [NSString stringWithFormat:@"%.2f GB/s", (double)bytes / GIGABYTES];
    } else {
        // Get min units first
        if (minUnit == 1 && bytes < KILOBITS) return @"0 Kb/s";
        else if (minUnit == 2 && bytes < MEGABITS) return @"0 Mb/s";
        else if (minUnit == 3 && bytes < GIGABITS) return @"0 Gb/s";

        if (bytes < KILOBITS) return [NSString stringWithFormat:@"%.0f b/s", (double)bytes];
        else if (bytes < MEGABITS) return [NSString stringWithFormat:@"%.0f Kb/s", (double)bytes / KILOBITS];
        else if (bytes < GIGABITS) return [NSString stringWithFormat:@"%.2f Mb/s", (double)bytes / MEGABITS];
        else return [NSString stringWithFormat:@"%.2f Gb/s", (double)bytes / GIGABITS];
    }
}

static NSAttributedString* formattedAttributedSpeedString(BOOL isUp, NSInteger speedIcon, NSInteger minUnit, BOOL hideWhenZero, double fontSize)
{
    @autoreleasepool {
        if (!attributedUploadPrefix)
            attributedUploadPrefix = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"▲"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedDownloadPrefix)
            attributedDownloadPrefix = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"▼"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedUploadPrefix2)
            attributedUploadPrefix2 = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"↑"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedDownloadPrefix2)
            attributedDownloadPrefix2 = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"↓"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        
        NSMutableAttributedString* mutableString = [[NSMutableAttributedString alloc] init];
        
        UpDownBytes upDownBytes = getUpDownBytes();
        
        uint64_t diff;
        
        if (isUp) {
            if (upDownBytes.outputBytes > prevOutputBytes)
                diff = upDownBytes.outputBytes - prevOutputBytes;
            else
                diff = 0;
            prevOutputBytes = upDownBytes.outputBytes;
        } else {
            if (upDownBytes.inputBytes > prevInputBytes)
                diff = upDownBytes.inputBytes - prevInputBytes;
            else
                diff = 0;
            prevInputBytes = upDownBytes.inputBytes;
        }
        
        if (DATAUNIT == 1)
            diff *= 8;
        
        NSString *speedString = formattedSpeed(diff, minUnit);
        if (!hideWhenZero || ![speedString hasPrefix:@"0"]) {
            if (isUp)
                [mutableString appendAttributedString:(speedIcon == 0 ? attributedUploadPrefix : attributedUploadPrefix2)];
            else
                [mutableString appendAttributedString:(speedIcon == 0 ? attributedDownloadPrefix : attributedDownloadPrefix2)];
            [mutableString appendAttributedString:[[NSAttributedString alloc] initWithString:speedString]];
        }
        
        return [mutableString copy];
    }
}

#pragma mark - Battery Temp Widget
NSDictionary* getBatteryInfo()
{
    CFDictionaryRef matching = IOServiceMatching("IOPMPowerSource");
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    CFMutableDictionaryRef prop = NULL;
    IORegistryEntryCreateCFProperties(service, &prop, NULL, 0);
    NSDictionary* dict = (__bridge_transfer NSDictionary*)prop;
    IOObjectRelease(service);
    return dict;
}

static NSString* formattedTemp(BOOL useFahrenheit)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        // AdapterDetails.Watts.Description.Temperature
        double temp = [batteryInfo[@"Temperature"] doubleValue] / 100.0;
        if (temp) {
            if (useFahrenheit) {
                temp = (temp * 9.0/5.0) + 32;
                return [NSString stringWithFormat: @"%.2fºF", temp];
            } else {
                return [NSString stringWithFormat: @"%.2fºC", temp];
            }
        }
    }
    return @"??ºC";
}

#pragma mark - Battery Widget
/*
 Battery Widget Identifiers:
 0 = Watts
 1 = Charging Current
 2 = Regular Amperage
 3 = Charge Cycles
 */
static NSString* formattedBattery(NSInteger valueType)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        if (valueType == 0) {
            // Watts
            int watts = [batteryInfo[@"AdapterDetails"][@"Watts"] longLongValue];
            if (watts) {
                return [NSString stringWithFormat: @"%d W", watts];
            } else {
                return @"0 W";
            }
        } else if (valueType == 1) {
            // Charging Current
            double current = [batteryInfo[@"AdapterDetails"][@"Current"] doubleValue];
            if (current) {
                return [NSString stringWithFormat: @"%.0f mA", current];
            } else {
                return @"0 mA";
            }
        } else if (valueType == 2) {
            // Regular Amperage
            double amps = [batteryInfo[@"Amperage"] doubleValue];
            if (amps) {
                return [NSString stringWithFormat: @"%.0f mA", amps];
            } else {
                return @"0 mA";
            }
        } else if (valueType == 3) {
            // Charge Cycles
            return [batteryInfo[@"CycleCount"] stringValue];
        } else {
            return @"???";
        }
    }
    return @"??";
}

#pragma mark - Current Capacity Widget
static NSString* formattedCurrentCapacity(BOOL showPercentage)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        return [
            NSString stringWithFormat: @"%@%@",
            [batteryInfo[@"CurrentCapacity"] stringValue],
            showPercentage ? @"%" : @""
            ];
    }
    return @"??%";
}

#pragma mark - Charging Symbol Widget
static NSString* formattedChargingSymbol(BOOL filled)
{
    [[UIDevice currentDevice] setBatteryMonitoringEnabled: YES];
    if ([[UIDevice currentDevice] batteryState] != UIDeviceBatteryStateUnplugged) {
        if (filled) {
            return @"bolt.fill";
        } else {
            return @"bolt";
        }
    }
    return @"";
}


#pragma mark - Heart Rate Widget
/*
 Heart rate comes from the store Bolts/CoreAnalytics keeps on disk:

   /var/mobile/Containers/Data/Application/<uuid>/Library/
       Application Support/CCAStorage/<uuid>/CCADatabase.sqlite

 The Application uuid changes with every reinstall, so the path is globbed for
 and the newest matching file wins. dataPointRecord holds one row per minute
 with dataType 3 == HeartRate, `start` in microseconds since the epoch, and
 `value` a small protobuf blob laid out as

   05 1b 09 <double avg> 11 <double max> 19 <double min>

 (0x09/0x11/0x19 are the protobuf tags for fixed64 fields 1/2/3.) The store
 lags the sensor by about a minute, so anything older than ten minutes is
 treated as no data rather than as a reading.

 The HUD ticks about once a second; opening and closing a multi-megabyte
 sqlite, and walking the application container, that often would be wasteful,
 so the formatted string is cached for 30 seconds.
 */
#define HR_REFRESH_INTERVAL 30.0
#define HR_STALE_INTERVAL 600.0

static NSString *heartRateCachedString = nil;
static NSTimeInterval heartRateCachedAt = 0;

static double hrDoubleAt(const unsigned char *p)
{
    double d = 0;
    memcpy(&d, p, sizeof(double));
    return d;
}

// Decode the protobuf blob into avg/max/min.
static BOOL hrDecodeValue(const void *blob, int length, double *avg, double *maxv, double *minv)
{
    const unsigned char *b = (const unsigned char *)blob;
    if (!b || length < 12) return NO;
    if (length >= 29 && b[2] == 0x09 && b[11] == 0x11 && b[20] == 0x19) {
        *avg = hrDoubleAt(b + 3);
        *maxv = hrDoubleAt(b + 12);
        *minv = hrDoubleAt(b + 21);
    } else {
        // Unknown preamble: trust the field tags, but only for values that
        // could plausibly be a heart rate.
        BOOL foundAvg = NO;
        for (int i = 0; i + 9 <= length; i++) {
            double d = hrDoubleAt(b + i + 1);
            if (!(d >= 10.0 && d <= 300.0)) continue;
            if (b[i] == 0x09) { *avg = d; foundAvg = YES; }
            else if (b[i] == 0x11) { *maxv = d; }
            else if (b[i] == 0x19) { *minv = d; }
        }
        if (!foundAvg) return NO;
    }
    return (*avg >= 10.0 && *avg <= 300.0);
}

// Newest CCAStorage database, or nil when the glob finds nothing.
static NSString *heartRateDatabasePath(void)
{
    NSString *pattern = @"/var/mobile/Containers/Data/Application/*/Library/Application Support/CCAStorage/*/CCADatabase.sqlite";
    glob_t found;
    memset(&found, 0, sizeof(found));
    if (glob([pattern fileSystemRepresentation], 0, NULL, &found) != 0) {
        return nil;
    }
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (size_t i = 0; i < found.gl_pathc; i++) {
        NSString *path = [NSString stringWithUTF8String:found.gl_pathv[i]];
        if (!path) continue;
        NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (!best || (modified && (!bestDate || [modified compare:bestDate] == NSOrderedDescending))) {
            best = path;
            bestDate = modified;
        }
    }
    globfree(&found);
    return best;
}

static BOOL hrQueryDatabase(NSString *path, double *avg, double *maxv, double *minv, double *age)
{
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([path fileSystemRepresentation], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }
    sqlite3_busy_timeout(db, 1000);
    sqlite3_stmt *stmt = NULL;
    BOOL ok = NO;
    if (sqlite3_prepare_v2(db, "SELECT start, value FROM dataPointRecord WHERE dataType = 3 ORDER BY start DESC LIMIT 1", -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            sqlite3_int64 startMicros = sqlite3_column_int64(stmt, 0);
            if (hrDecodeValue(sqlite3_column_blob(stmt, 1), sqlite3_column_bytes(stmt, 1), avg, maxv, minv)) {
                *age = [[NSDate date] timeIntervalSince1970] - ((double)startMicros / 1000000.0);
                ok = YES;
            }
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return ok;
}

// A database left behind by a process we cannot see may refuse READONLY on the
// WAL (no usable -shm). Copying the trio to /tmp costs a few hundred KB and
// always works.
static BOOL hrQueryDatabaseWithFallback(NSString *path, double *avg, double *maxv, double *minv, double *age)
{
    if (hrQueryDatabase(path, avg, maxv, minv, age)) return YES;

    NSString *copyPrefix = [NSTemporaryDirectory() stringByAppendingPathComponent:@"helium_hr.sqlite"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:copyPrefix error:nil];
    if (![fm copyItemAtPath:path toPath:copyPrefix error:nil]) return NO;
    [fm copyItemAtPath:[path stringByAppendingString:@"-wal"] toPath:[copyPrefix stringByAppendingString:@"-wal"] error:nil];
    [fm copyItemAtPath:[path stringByAppendingString:@"-shm"] toPath:[copyPrefix stringByAppendingString:@"-shm"] error:nil];
    BOOL ok = hrQueryDatabase(copyPrefix, avg, maxv, minv, age);
    [fm removeItemAtPath:copyPrefix error:nil];
    [fm removeItemAtPath:[copyPrefix stringByAppendingString:@"-wal"] error:nil];
    [fm removeItemAtPath:[copyPrefix stringByAppendingString:@"-shm"] error:nil];
    return ok;
}

// valueType: 0 = average, 1 = maximum, 2 = minimum
static NSString *formattedHeartRate(NSInteger valueType)
{
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!heartRateCachedString || now - heartRateCachedAt >= HR_REFRESH_INTERVAL) {
        NSString *result = @"❤ --";
        @autoreleasepool {
            NSString *path = heartRateDatabasePath();
            double avg = 0, maxv = 0, minv = 0, age = 0;
            if (path && hrQueryDatabaseWithFallback(path, &avg, &maxv, &minv, &age)) {
                if (age <= HR_STALE_INTERVAL) {
                    double hr = valueType == 1 ? maxv : (valueType == 2 ? minv : avg);
                    if (hr < 10.0 || hr > 300.0) hr = avg;
                    if (hr >= 10.0 && hr <= 300.0) {
                        result = [NSString stringWithFormat:@"❤ %.0f", hr];
                    }
                }
            }
        }
        heartRateCachedString = result;
        heartRateCachedAt = now;
    }
    return heartRateCachedString;
}

#pragma mark - Main Widget Functions
/*
 Widget Identifiers:
 0 = None
 1 = Date
 2 = Network Up/Down
 3 = Device Temp
 4 = Battery Detail
 5 = Time
 6 = Text
 7 = Battery Percentage
 8 = Charging Symbol
 9 = Weather
 10 = Heart Rate

 TODO:
 - Music Visualizer
 */
void formatParsedInfo(NSDictionary *parsedInfo, NSInteger parsedID, NSMutableAttributedString *mutableString, double fontSize, UIColor *textColor, NSString *apiKey, NSString *dateLocale)
{
    NSString *widgetString;
    NSString *sfSymbolName;
    NSTextAttachment *imageAttachment;
    switch (parsedID) {
        case 1:
        case 5:
            // Date/Time
            widgetString = formattedDate(
                [parsedInfo valueForKey:@"dateFormat"] ? [parsedInfo valueForKey:@"dateFormat"] : (parsedID == 1 ? NSLocalizedString(@"E MMM dd", comment: @"") : @"hh:mm"), dateLocale
            );
            break;
        case 2:
            // Network Speed
            [
                mutableString appendAttributedString: formattedAttributedSpeedString(
                    [parsedInfo valueForKey:@"isUp"] ? [[parsedInfo valueForKey:@"isUp"] boolValue] : NO,
                    [parsedInfo valueForKey:@"speedIcon"] ? [[parsedInfo valueForKey:@"speedIcon"] intValue] : 0,
                    [parsedInfo valueForKey:@"minUnit"] ? [[parsedInfo valueForKey:@"minUnit"] intValue] : 1,
                    [parsedInfo valueForKey:@"hideSpeedWhenZero"] ? [[parsedInfo valueForKey:@"hideSpeedWhenZero"] boolValue] : NO,
                    fontSize
                )
            ];
            break;
        case 3:
            // Device Temp
            widgetString = formattedTemp(
                [parsedInfo valueForKey:@"useFahrenheit"] ? [[parsedInfo valueForKey:@"useFahrenheit"] boolValue] : NO
            );
            break;
        case 4:
            // Battery Stats
            widgetString = formattedBattery(
                [parsedInfo valueForKey:@"batteryValueType"] ? [[parsedInfo valueForKey:@"batteryValueType"] integerValue] : 0
            );
            break;
        case 6:
            // Text
            widgetString = [parsedInfo valueForKey:@"text"] ? [parsedInfo valueForKey:@"text"] : @"Unknown";
            break;
        case 7:
            // Current Capacity
            widgetString = formattedCurrentCapacity(
                [parsedInfo valueForKey:@"showPercentage"] ? [[parsedInfo valueForKey:@"showPercentage"] boolValue] : YES
            );
            break;
        case 8:
            // Charging Symbol
            sfSymbolName = formattedChargingSymbol(
                [parsedInfo valueForKey:@"filled"] ? [[parsedInfo valueForKey:@"filled"] boolValue] : YES
            );
            if (![sfSymbolName isEqualToString:@""]) {
                imageAttachment = [[NSTextAttachment alloc] init];
                imageAttachment.image = [
                    [
                        UIImage systemImageNamed:sfSymbolName
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:fontSize]
                    ]
                    imageWithTintColor:textColor
                ];
                [mutableString appendAttributedString:[NSAttributedString attributedStringWithAttachment:imageAttachment]];
            }
            break;
        case 9:
            {
                // Weather
                NSString *location = [parsedInfo valueForKey:@"location"];
                NSString *format = [parsedInfo valueForKey:@"format"];
                NSDictionary *now = [WeatherUtils fetchNowWeatherForLocation: location apiKey:apiKey dateLocale:dateLocale];
                NSDictionary *today = [WeatherUtils fetchTodayWeatherForLocation: location apiKey:apiKey dateLocale:dateLocale];
                widgetString = [WeatherUtils formatNowResult:now format:format];
                widgetString = [WeatherUtils formatTodayResult:today format:widgetString];
            }
            break;
        case 10:
            // Heart Rate
            widgetString = formattedHeartRate(
                [parsedInfo valueForKey:@"hrValue"] ? [[parsedInfo valueForKey:@"hrValue"] integerValue] : 0
            );
            break;
        default:
            // do not add anything
            break;
    }
    if (widgetString) {
        widgetString = [widgetString stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        widgetString = [widgetString stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
        [
            mutableString appendAttributedString:[[NSAttributedString alloc] initWithString: widgetString]
        ];
    }
}

NSAttributedString* formattedAttributedString(NSArray *identifiers, double fontSize, UIColor *textColor, NSString *apiKey, NSString *dateLocale)
{
    @autoreleasepool {
        NSMutableAttributedString* mutableString = [[NSMutableAttributedString alloc] init];
        
        if (identifiers) {
            for (id idInfo in identifiers) {
                NSDictionary *parsedInfo = idInfo;
                NSInteger parsedID = [parsedInfo valueForKey:@"widgetID"] ? [[parsedInfo valueForKey:@"widgetID"] integerValue] : 0;
                formatParsedInfo(parsedInfo, parsedID, mutableString, fontSize, textColor, apiKey, dateLocale);
            }
        } else {
            return nil;
        }
        
        return [mutableString copy];
    }
}
