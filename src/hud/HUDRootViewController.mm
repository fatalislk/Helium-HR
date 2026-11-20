#import <notify.h>
#import <objc/runtime.h>
#import <unistd.h>

#import "HUDRootViewController.h"
#import "AnyBackdropView.h"
#import "HeliumHalo.h"
#import "HUDDiagnostics.h"
#import "HUDHelper.h"
#import "HRMonitor.h"
#import "Helium-Swift.h"

#import "../widgets/WidgetManager.h"
#import "../extensions/UsefulFunctions.h"
#import "../extensions/FontUtils.h"
#import "../extensions/EZTimer.h"
#import "../extensions/WeatherUtils.h"

#import "../helpers/private_headers/FBSOrientationUpdate.h"
#import "../helpers/private_headers/FBSOrientationObserver.h"
#import "../helpers/private_headers/LSApplicationProxy.h"
#import "../helpers/private_headers/LSApplicationWorkspace.h"
#import "../helpers/private_headers/SpringBoardServices.h"
#import "../helpers/private_headers/UIApplication+Private.h"

#define NOTIFY_UI_LOCKSTATE    "com.apple.springboard.lockstate"
#define NOTIFY_LS_APP_CHANGED  "com.apple.LaunchServices.ApplicationsChanged"

// What a text label was last painted with, kept on the label itself: each
// widget set has its own, and they update on independent timers, so one shared
// record would be overwritten by the next widget before it could ever match.
static const void *kLastPaintSignature = &kLastPaintSignature;

static void LaunchServicesApplicationStateChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    /* Application installed or uninstalled */

    BOOL isAppInstalled = NO;
    
    for (LSApplicationProxy *app in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications])
    {
        if ([app.applicationIdentifier isEqualToString:@"com.leemin.helium"])
        {
            isAppInstalled = YES;
            break;
        }
    }

    if (!isAppInstalled)
    {
        UIApplication *app = [UIApplication sharedApplication];
        [app terminateWithSuccess];
    }
}

static void SpringBoardLockStatusChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    HUDRootViewController *rootViewController = (__bridge HUDRootViewController *)observer;
    NSString *lockState = (__bridge NSString *)name;
    if ([lockState isEqualToString:@NOTIFY_UI_LOCKSTATE])
    {
        mach_port_t sbsPort = SBSSpringBoardServerPort();
        
        if (sbsPort == MACH_PORT_NULL)
            return;
        
        BOOL isLocked;
        BOOL isPasscodeSet;
        SBGetScreenLockStatus(sbsPort, &isLocked, &isPasscodeSet);

        if (!isLocked)
        {
            [rootViewController.view setHidden:NO];
            [rootViewController resumeLoopTimer];
        }
        else
        {
            [rootViewController pauseLoopTimer];
            [rootViewController.view setHidden:YES];
        }
    }
}

static void ReloadHUD
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    // NSLog(@"boom ReloadHUD");
    HUDRootViewController *rootViewController = (__bridge HUDRootViewController *)observer;
    // [rootViewController createWidgetSets];
    [rootViewController reloadUserDefaults];
    [rootViewController resetLoopTimer];
    [rootViewController updateViewConstraints];
    HUDDiagnosticsWriteNow();
}

#pragma mark - HUDRootViewController

/// The body of the file written by HUDDiagnostics. Implemented here because
/// this is the only object holding the widget sets and their labels.
@interface HUDRootViewController ()
- (NSString *)diagnosticsReport;
@end

@implementation HUDRootViewController {
    NSMutableDictionary *_userDefaults;
    NSMutableArray <NSLayoutConstraint *> *_constraints;
    FBSOrientationObserver *_orientationObserver;
    // view object arrays
    NSMutableArray <UIVisualEffectView *> *_blurViews;
    NSMutableArray <UILabel *> *_labelViews;
    
    NSMutableArray <AnyBackdropView *> *_backdropViews;
    NSMutableArray <UILabel *> *_maskLabelViews;
    // one halo label per widget set, sitting behind the text
    NSMutableArray <HeliumHaloLabel *> *_haloViews;

    UIView *_contentView;
    
    UIInterfaceOrientation _orientation;

    UIView *_horizontalLine;
    UIView *_verticalLine;

    // How far startup got, for the diagnostics file: a HUD that never reaches
    // -viewDidLoad cannot draw anything, and that is worth being able to see.
    BOOL _viewDidLoaded;
    BOOL _viewDidAppeared;
}

- (void)registerNotifications
{
    int token;
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &token, dispatch_get_main_queue(), ^(int token) {
        [self reloadUserDefaults];
        [self resetLoopTimer];
        [self updateViewConstraints];
    });

    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
    
    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        LaunchServicesApplicationStateChanged,
        CFSTR(NOTIFY_LS_APP_CHANGED),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
    
    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        SpringBoardLockStatusChanged,
        CFSTR(NOTIFY_UI_LOCKSTATE),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        ReloadHUD,
        CFSTR(NOTIFY_RELOAD_HUD),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
}


#pragma mark - User Default Stuff

- (void)loadUserDefaults:(BOOL)forceReload
{
    if (forceReload || !_userDefaults)
        _userDefaults = [[NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH] mutableCopy] ?: [NSMutableDictionary dictionary];
}

- (void) reloadUserDefaults
{
    [self loadUserDefaults: YES];
    
    if ([self debugBorder]) {
        _contentView.layer.borderWidth = 1.0;
        [_horizontalLine setHidden:NO];
        [_verticalLine setHidden:NO];
    } else {
        _contentView.layer.borderWidth = 0.0;
        [_horizontalLine setHidden:YES];
        [_verticalLine setHidden:YES];
    }

    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex: i];
        UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];

        NSDictionary *properties = [widgetProps objectAtIndex:i];
        NSInteger orientationMode = getIntFromDictKey(properties, @"orientationMode", 0);
        NSDictionary *blurDetails = [properties valueForKey:@"blurDetails"] ? [properties valueForKey:@"blurDetails"] : @{@"hasBlur" : @(NO)};
        UIBlurEffect *blurEffect = [
            UIBlurEffect effectWithStyle: getBoolFromDictKey(blurDetails, @"styleDark", true) ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight
        ];
        BOOL hasBlur = getBoolFromDictKey(blurDetails, @"hasBlur");
        NSInteger blurCornerRadius = getIntFromDictKey(blurDetails, @"cornerRadius", 4);
        double blurAlpha = getDoubleFromDictKey(blurDetails, @"alpha", 1.0);
        // NSTextAlignment is the property's type; clang 16 refuses the implicit NSInteger narrowing.
        NSTextAlignment textAlign = (NSTextAlignment)getIntFromDictKey(properties, @"textAlignment", 1);
        NSDictionary *colorDetails = [properties valueForKey:@"colorDetails"] ? [properties valueForKey:@"colorDetails"] : @{@"usesCustomColor" : @(NO)};
        BOOL usesCustomColor = getBoolFromDictKey(colorDetails, @"usesCustomColor");
        UIColor *textColor = [UIColor whiteColor];
        if (usesCustomColor && [colorDetails valueForKey:@"color"]) {
            NSData *customColorData = [colorDetails valueForKey:@"color"];
            textColor = [NSKeyedUnarchiver unarchiveObjectWithData:customColorData];
        }
        NSString *fontName = getStringFromDictKey(properties, @"fontName", @"System Font");
        UIFont *textFont = [FontUtils loadFontWithName:fontName size: getDoubleFromDictKey(properties, @"fontSize", 10) bold: getBoolFromDictKey(properties, @"textBold") italic: getBoolFromDictKey(properties, @"textItalic")];
        double textAlpha = getDoubleFromDictKey(properties, @"textAlpha", 1.0);
        BOOL dynamicColor = getBoolFromDictKey(properties, @"dynamicColor", true);
        
        labelView.textAlignment = textAlign;
        labelView.font = textFont;
        maskLabelView.textAlignment = textAlign;
        maskLabelView.font = textFont;
        maskLabelView.textColor = [UIColor whiteColor];

        if (dynamicColor) {
            [blurView setEffect:nil];
            [blurView setHidden:YES];
            [labelView setHidden:YES];
            [backdropView setHidden:NO];
            [maskLabelView setHidden:NO];
            maskLabelView.alpha = textAlpha;
        } else {
            labelView.textColor = textColor;
            labelView.alpha = textAlpha;
            [labelView setHidden:NO];
            [backdropView setHidden:YES];
            [maskLabelView setHidden:YES];
            if (hasBlur) {
                [blurView setEffect:blurEffect];
                [blurView setHidden:NO];
                blurView.layer.cornerRadius = blurCornerRadius;
                blurView.alpha = blurAlpha;
            } else {
                [blurView setEffect:nil];
                [blurView setHidden:YES];
            }
        }

        if ((orientationMode == 1 && [self isLandscapeOrientation])
            || (orientationMode == 2 && ![self isLandscapeOrientation])) {
            [blurView setHidden:YES];
            [labelView setHidden:YES];
            [backdropView setHidden:YES];
            [maskLabelView setHidden:YES];
        }

        // MARK: Text Halo
        if (i < (NSInteger)_haloViews.count) {
            HeliumHaloLabel *haloView = [_haloViews objectAtIndex:i];
            HeliumHaloStyle *haloStyle = HeliumHaloStyleFromProperties(properties);
            haloView.textAlignment = textAlign;
            haloView.font = textFont;
            haloView.alpha = textAlpha;
            // The halo sits behind whichever view is showing the text, so it
            // takes its visibility from that view: a widget the user turned
            // off, or an orientation it is not shown in, means no halo either.
            // It is set here and not on every repaint, or the once-a-second
            // text update would keep switching a hidden halo back on.
            BOOL textVisible = dynamicColor ? !backdropView.hidden : !labelView.hidden;
            haloView.hidden = !(textVisible && haloStyle.isActive);
            if (haloView.haloPad != haloStyle.pad) {
                haloView.haloPad = haloStyle.pad;
                // A wider halo means a bigger frame, which is a new layout
                // rather than a repaint.
                [self.view setNeedsUpdateConstraints];
            }
        }

        if ([self debugBorder]) {
            labelView.layer.borderWidth = 1.0;
            // backdropView.layer.borderWidth = 1.0;
            maskLabelView.layer.borderWidth = 1.0;
        } else {
            labelView.layer.borderWidth = 0.0;
            // backdropView.layer.borderWidth = 0.0;
            maskLabelView.layer.borderWidth = 0.0;
        }
    }
}

- (BOOL) debugBorder
{
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey: @"debugBorder"];
    return mode ? [mode boolValue] : NO;
}

- (NSString*) apiKey
{
    [self loadUserDefaults:NO];
    NSString *apiKey = [_userDefaults objectForKey: @"apiKey"];
    return apiKey ? apiKey : @"";
}

- (NSString*) dateLocale
{
    [self loadUserDefaults:NO];
    NSString *locale = [_userDefaults objectForKey: @"dateLocale"];
    return locale ? locale : @"en_US";
}

- (NSArray*) widgetProperties
{
    [self loadUserDefaults: NO];
    NSArray *properties = [_userDefaults objectForKey: @"widgetProperties"];
    return properties;
}

- (BOOL) isLandscapeOrientation
{
    BOOL isLandscape;
    if (_orientation == UIInterfaceOrientationUnknown) {
        isLandscape = CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds);
    } else {
        isLandscape = UIInterfaceOrientationIsLandscape(_orientation);
    }
    return isLandscape;
}

#pragma mark - Initialization and Deallocation

- (instancetype)init
{
    self = [super init];
    if (self) {
        // load fonts from app
        [FontUtils loadFontsFromFolder:[NSString stringWithFormat:@"%@%@", [[NSBundle mainBundle] resourcePath],  @"/fonts"]];
        // load fonts from documents
        [FontUtils loadFontsFromFolder:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]];
        _constraints = [NSMutableArray array];
        _blurViews = [NSMutableArray array];
        _labelViews = [NSMutableArray array];
        _backdropViews = [NSMutableArray array];
        _maskLabelViews = [NSMutableArray array];
        _haloViews = [NSMutableArray array];
        _orientationObserver = [[objc_getClass("FBSOrientationObserver") alloc] init];
        __weak HUDRootViewController *weakSelf = self;
        [_orientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
            HUDRootViewController *strongSelf = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf updateOrientation:(UIInterfaceOrientation)orientationUpdate.orientation animateWithDuration:orientationUpdate.duration];
            });
        }];
        [self registerNotifications];

        // Started before the view exists on purpose: if -loadView or -viewDidLoad
        // never runs, the file still says the controller was built and the
        // window was not.
        __weak HUDRootViewController *weakController = self;
        HUDDiagnosticsStart(^NSString *{
            return [weakController diagnosticsReport] ?: @"";
        });
    }
    return self;
}

- (void)dealloc
{
    [_orientationObserver invalidate];
}

#pragma mark - HUD UI Main Functions

- (void) viewDidLoad
{
    [super viewDidLoad];
    _viewDidLoaded = YES;
    HUDDiagnosticsMark(@"rootVC viewDidLoad");
    // MARK: Main Content View
    _contentView = [[UIView alloc] init];
    _contentView.backgroundColor = [UIColor clearColor];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    _contentView.layer.borderColor = [UIColor redColor].CGColor;
    [_contentView setUserInteractionEnabled:YES];
    [self.view addSubview:_contentView];

    _horizontalLine = [[UIView alloc] initWithFrame: CGRectZero];
    _horizontalLine.backgroundColor = [UIColor redColor];
    _horizontalLine.translatesAutoresizingMaskIntoConstraints = NO;
    [_horizontalLine setHidden:YES];
    [_contentView addSubview:_horizontalLine];

    _verticalLine = [[UIView alloc] initWithFrame: CGRectZero];
    _verticalLine.backgroundColor = [UIColor redColor];
    _verticalLine.translatesAutoresizingMaskIntoConstraints = NO;
    [_verticalLine setHidden:YES];
    [_contentView addSubview:_verticalLine];

    [self createWidgetSetsView];
    notify_post(NOTIFY_RELOAD_HUD);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    _viewDidAppeared = YES;
    HUDDiagnosticsMark(@"rootVC viewDidAppear");
    notify_post(NOTIFY_LAUNCHED_HUD);
}

#pragma mark - Diagnostics

static NSString *HUDDiagRect(CGRect rect)
{
    return [NSString stringWithFormat:@"{%.1f,%.1f %.1fx%.1f}",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}

/// Text on one line: a label's contents with newlines would otherwise read as
/// extra rows of diagnostics.
static NSString *HUDDiagText(NSString *text)
{
    if (text.length == 0) return @"\"\"";
    NSMutableString *escaped = [text mutableCopy];
    [escaped replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\t" withString:@"\\t" options:0 range:NSMakeRange(0, escaped.length)];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

- (NSString *)diagnosticsReport
{
    NSMutableString *out = [NSMutableString string];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    [out appendFormat:@"hudEnabled=%d build=%@\n", (int)IsHUDEnabled(), HUDBuildFingerprint() ?: @"?"];
    [out appendFormat:@"lifecycle viewDidLoad=%d viewDidAppear=%d\n", (int)_viewDidLoaded, (int)_viewDidAppeared];

    UIScreen *screen = [UIScreen mainScreen];
    UIEdgeInsets safeInsets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safeInsets = self.view.safeAreaInsets;
    }
    [out appendFormat:@"screen bounds=%@ scale=%.2f\n", HUDDiagRect(screen.bounds), screen.scale];
    [out appendFormat:@"safeArea top=%.1f left=%.1f bottom=%.1f right=%.1f\n",
        safeInsets.top, safeInsets.left, safeInsets.bottom, safeInsets.right];
    [out appendFormat:@"orientation=%ld landscape=%d\n", (long)_orientation, (int)[self isLandscapeOrientation]];

    UIWindow *window = self.view.window;
    if (window) {
        [out appendFormat:@"window frame=%@ level=%.0f hidden=%d alpha=%.2f rootVC=%@\n",
            HUDDiagRect(window.frame), window.windowLevel, (int)window.isHidden, window.alpha,
            NSStringFromClass([window.rootViewController class])];
    } else {
        [out appendString:@"window NONE (the view has no window, so nothing can be drawn)\n"];
    }
    [out appendFormat:@"rootView frame=%@ hidden=%d alpha=%.2f\n",
        HUDDiagRect(self.view.frame), (int)self.view.isHidden, self.view.alpha];
    if (_contentView) {
        [out appendFormat:@"contentView frame=%@ hidden=%d alpha=%.2f subviews=%lu\n",
            HUDDiagRect(_contentView.frame), (int)_contentView.isHidden, _contentView.alpha,
            (unsigned long)_contentView.subviews.count];
    } else {
        [out appendString:@"contentView NONE (viewDidLoad has not run)\n"];
    }

    NSArray *widgetProps = [self widgetProperties];
    if (![widgetProps isKindOfClass:[NSArray class]]) widgetProps = @[];
    [out appendFormat:@"widgetProperties=%lu labelViews=%lu\n",
        (unsigned long)widgetProps.count, (unsigned long)_labelViews.count];

    NSInteger enabledSets = 0;
    NSInteger enabledWithWidgets = 0;
    NSInteger drawnLabels = 0;
    NSInteger drawnWithText = 0;

    for (NSUInteger i = 0; i < widgetProps.count; i++) {
        id entry = widgetProps[i];
        if (![entry isKindOfClass:[NSDictionary class]]) {
            [out appendFormat:@"set[%lu] not a dictionary: %@\n", (unsigned long)i, [entry class]];
            continue;
        }
        NSDictionary *properties = entry;
        BOOL isEnabled = getBoolFromDictKey(properties, @"isEnabled");
        NSArray *identifiers = [properties objectForKey:@"widgetIDs"];
        if (![identifiers isKindOfClass:[NSArray class]]) identifiers = @[];

        NSMutableArray *idList = [NSMutableArray array];
        for (id widget in identifiers) {
            if ([widget isKindOfClass:[NSDictionary class]]) {
                id widgetID = [(NSDictionary *)widget objectForKey:@"widgetID"];
                [idList addObject:[NSString stringWithFormat:@"%@", widgetID ?: @"?"]];
            } else {
                [idList addObject:[widget description] ?: @"?"];
            }
        }

        if (isEnabled) enabledSets++;
        if (isEnabled && identifiers.count) enabledWithWidgets++;

        [out appendFormat:@"set[%lu] isEnabled=%d widgetIDs=(%@)%lu anchor=%ld anchorY=%ld "
                          @"offsetPX=%.1f offsetPY=%.1f offsetLX=%.1f offsetLY=%.1f "
                          @"fontSize=%.1f updateInterval=%.2f autoResizes=%d scale=%.1f scaleY=%.1f "
                          @"dynamicColor=%d textAlpha=%.2f\n",
            (unsigned long)i, (int)isEnabled, [idList componentsJoinedByString:@","],
            (unsigned long)identifiers.count,
            (long)getIntFromDictKey(properties, @"anchor"),
            (long)getIntFromDictKey(properties, @"anchorY"),
            getDoubleFromDictKey(properties, @"offsetPX", 0), getDoubleFromDictKey(properties, @"offsetPY", 0),
            getDoubleFromDictKey(properties, @"offsetLX", 0), getDoubleFromDictKey(properties, @"offsetLY", 0),
            getDoubleFromDictKey(properties, @"fontSize", 10),
            getDoubleFromDictKey(properties, @"updateInterval", 1),
            (int)getBoolFromDictKey(properties, @"autoResizes"),
            getDoubleFromDictKey(properties, @"scale", 50), getDoubleFromDictKey(properties, @"scaleY", 12),
            (int)getBoolFromDictKey(properties, @"dynamicColor", true),
            getDoubleFromDictKey(properties, @"textAlpha", 1.0)];

        if (i < _labelViews.count) {
            UILabel *label = _labelViews[i];
            CGRect inWindow = [label convertRect:label.bounds toView:nil];
            BOOL onScreen = CGRectIntersectsRect(inWindow, screen.bounds);

            [out appendFormat:@"  label frame=%@ inWindow=%@ onScreen=%d hidden=%d alpha=%.2f text=%@\n",
                HUDDiagRect(label.frame), HUDDiagRect(inWindow), (int)onScreen,
                (int)label.isHidden, label.alpha, HUDDiagText(label.text)];
            if (i < _maskLabelViews.count) {
                UILabel *mask = _maskLabelViews[i];
                [out appendFormat:@"  maskLabel frame=%@ hidden=%d text=%@\n",
                    HUDDiagRect(mask.frame), (int)mask.isHidden, HUDDiagText(mask.text)];
            }
            if (i < _haloViews.count) {
                [out appendFormat:@"  halo frame=%@ hidden=%d\n",
                    HUDDiagRect(_haloViews[i].frame), (int)_haloViews[i].isHidden];
            }
            if (i < _backdropViews.count) {
                [out appendFormat:@"  backdrop frame=%@ hidden=%d\n",
                    HUDDiagRect(_backdropViews[i].frame), (int)_backdropViews[i].isHidden];
            }
            if (!onScreen) {
                [out appendFormat:@"  !! label %lu is entirely off screen (window bounds are %@)\n",
                    (unsigned long)i, HUDDiagRect(screen.bounds)];
            }

            // Which view actually puts the glyphs on screen is configuration:
            // a plain label, or -- with dynamicColor, the default -- a
            // CABackdropLayer the label is only the mask of. Counting the label
            // alone would call a correctly configured HUD blank.
            BOOL dynamicColor = getBoolFromDictKey(properties, @"dynamicColor", true);
            UIView *textHost = (dynamicColor && i < _backdropViews.count)
                ? (UIView *)_backdropViews[i] : (UIView *)label;
            BOOL hostDrawing = textHost && !textHost.isHidden && textHost.alpha > 0.01 && label.text.length > 0;
            if (hostDrawing) drawnLabels++;
            if (hostDrawing && onScreen) drawnWithText++;
            [out appendFormat:@"  draws via=%@ hidden=%d alpha=%.2f\n",
                dynamicColor ? @"CABackdropLayer+mask" : @"UILabel",
                (int)textHost.isHidden, textHost.alpha];
        } else {
            [out appendFormat:@"  !! no label was created for this set\n"];
        }
    }

    // Which side of the pair is actually holding the band. The HUD cannot, so
    // this normally says the app -- and if it ever says the HUD, the file is
    // the app's stale leftovers and the age will show it.
    NSInteger inProcessBPM = [HRMonitor currentBPM];
    NSTimeInterval inProcessAt = [HRMonitor lastUpdate];
    NSTimeInterval fileAt = 0;
    NSInteger fileBPM = [HRMonitor bpmFromDebugFileWithTimestamp:&fileAt];
    NSInteger writerPID = [HRMonitor debugFileWriterPID];
    NSInteger myPID = (NSInteger)getpid();
    NSString *owner = @"unknown";
    if (writerPID > 0) {
        owner = (writerPID == myPID)
            ? @"this process (the HUD)"
            : [NSString stringWithFormat:@"the other process pid %ld (the app)", (long)writerPID];
    }
    [out appendFormat:@"heartRate inProcess: connected=%d status=%@ bpm=%ld lastFrame=%.0f age=%.1fs\n",
        (int)[HRMonitor isBandConnected], [HRMonitor statusDescription] ?: @"?",
        (long)inProcessBPM, inProcessAt, inProcessAt > 0 ? now - inProcessAt : -1.0];
    [out appendFormat:@"heartRate fromFile: bpm=%ld lastFrame=%.0f age=%.1fs writerPid=%ld bleOwner=%@\n",
        (long)fileBPM, fileAt, fileAt > 0 ? now - fileAt : -1.0, (long)writerPID, owner];
    [out appendFormat:@"thisPid=%ld\n", (long)myPID];

    [out appendString:@"diagnosis:\n"];
    if (widgetProps.count == 0) {
        [out appendString:@"  - widgetProperties is empty: no widget set has ever been configured\n"];
    } else if (enabledSets == 0) {
        [out appendString:@"  - every widget set has isEnabled=0: nothing is meant to be drawn\n"];
    } else if (enabledWithWidgets == 0) {
        [out appendString:@"  - every enabled set has an empty widgetID list: nothing to draw\n"];
    }
    if (!_viewDidLoaded) {
        [out appendString:@"  - the view controller never reached viewDidLoad\n"];
    }
    if (!window) {
        [out appendString:@"  - no window: the HUD's window was never attached\n"];
    } else {
        if (window.isHidden) [out appendString:@"  - window is hidden\n"];
        if (window.windowLevel < 1) {
            [out appendFormat:@"  - window level %.0f is at or below normal windows and will be covered\n", window.windowLevel];
        }
        if (window.alpha < 0.01) [out appendString:@"  - window alpha is 0\n"];
    }
    if (_viewDidLoaded && widgetProps.count > 0 && drawnWithText == 0) {
        if (drawnLabels == 0) {
            [out appendString:@"  - no widget is drawing anything (hidden, transparent, or empty text)\n"];
        } else {
            [out appendString:@"  - every widget with text is off screen\n"];
        }
    }
    // The dynamic colour mode draws the text with a CABackdropLayer (blur,
    // brightness, contrast, invert) masked by the glyphs. If that layer produces
    // nothing the widget's frame is right, its text is right, and the screen is
    // still empty -- which is the one blank HUD this file cannot rule out.
    if (drawnWithText > 0 && [widgetProps[0] isKindOfClass:[NSDictionary class]]
        && getBoolFromDictKey((NSDictionary *)widgetProps[0], @"dynamicColor", true)) {
        [out appendString:@"  - note: the text is drawn through a CABackdropLayer; an empty area at the widget's frame means that layer rendered nothing\n"];
    }
    return out;
}

#pragma mark - Timer and View Updating

- (void)resetLoopTimer
{
    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex: i];
        UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];

        NSDictionary *properties = [widgetProps objectAtIndex:i];
        HeliumHaloLabel *haloView = (i < (NSInteger)_haloViews.count) ? [_haloViews objectAtIndex:i] : nil;
        HeliumHaloStyle *haloStyle = HeliumHaloStyleFromProperties(properties);
        if (!labelView || !maskLabelView || !properties)
            break;
        NSArray *identifiers = [properties objectForKey: @"widgetIDs"] ? [properties objectForKey: @"widgetIDs"] : @[];
        double fontSize = [properties objectForKey: @"fontSize"] ? [[properties objectForKey: @"fontSize"] doubleValue] : 10.0;
        double updateInterval = getDoubleFromDictKey(properties, @"updateInterval", 1.0);
        BOOL isEnabled = getBoolFromDictKey(properties, @"isEnabled");
        BOOL autoResizes = getBoolFromDictKey(properties, @"autoResizes");
        float width = getDoubleFromDictKey(properties, @"scale", 50.0);
        float height = getDoubleFromDictKey(properties, @"scaleY", 12.0);
        if (isEnabled) {
            [[EZTimer shareInstance] timer:[NSString stringWithFormat:@"labelview%d", i] timerInterval:updateInterval leeway:0.1 resumeType:EZTimerResumeTypeNow queue:EZTimerQueueTypeConcurrent queueName:@"update" repeats:YES action:^(NSString *timerName) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self updateLabel: labelView updateMaskLabel: maskLabelView updateHaloLabel: haloView haloStyle: haloStyle backdropView: backdropView identifiers: identifiers fontSize: fontSize autoResizes: autoResizes width: width height: height];
                });
            }];
        } else {
            [blurView setEffect:nil];
            [blurView setHidden:YES];
            [labelView setHidden:YES];
            [backdropView setHidden:YES];
            [maskLabelView setHidden:YES];
            [haloView setHidden:YES];
            [[EZTimer shareInstance] cancel:[NSString stringWithFormat:@"labelview%d", i]];
        }
    }
}

- (void) updateLabel:(UILabel *) label updateMaskLabel:(UILabel *) maskLabel updateHaloLabel:(HeliumHaloLabel *) haloLabel haloStyle:(HeliumHaloStyle *) haloStyle backdropView:(AnyBackdropView *) backdropView identifiers:(NSArray *) identifiers fontSize:(double) fontSize autoResizes:(BOOL) autoResizes width:(CGFloat) width height:(CGFloat) height
{
#if DEBUG
    os_log_debug(OS_LOG_DEFAULT, "updateLabel");
#endif
    NSAttributedString *attributedText = formattedAttributedString(identifiers, fontSize, label.textColor, [self apiKey], [self dateLocale]);
    if (attributedText) {
        // Everything below is what this method reads, so an unchanged signature
        // means an unchanged screen and there is nothing to do. A widget that
        // refreshes every second but whose text changes once a minute was
        // otherwise laying out three labels, re-rendering a blurred shadow and
        // invalidating a live backdrop sixty times a minute, and the backdrop
        // is the expensive one: it samples whatever is behind it.
        //
        // The halo style is part of the signature rather than assumed constant:
        // a reload that only moves the width slider leaves the text identical
        // and still has to repaint. Bounds, because a reload can resize the box
        // without touching the text.
        NSArray *signature = @[attributedText, @(fontSize), @(autoResizes), @(width), @(height),
                               haloStyle ?: [[HeliumHaloStyle alloc] init]];
        NSArray *lastSignature = objc_getAssociatedObject(label, kLastPaintSignature);
        if (lastSignature && [signature isEqualToArray:lastSignature]) {
            return;
        }
        objc_setAssociatedObject(label, kLastPaintSignature, signature, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // NSLog(@"boom attr:%@", attributedText);
        [label setAttributedText: attributedText];
        [maskLabel setAttributedText: attributedText];
        // The same string once more for the halo, which is drawn underneath and
        // therefore can only show outside the glyphs.
        HeliumDrawHalo(haloLabel, attributedText, fontSize, haloStyle);
        if (autoResizes) {
            [self useSizeThatFitsZeroWithLabel:maskLabel];
        } else {
            [self useSizeThatFitsCustomWithLabel:maskLabel width: width height: height];
        }
    }
}

- (void) useSizeThatFitsZeroWithLabel:(UILabel *)label{
    CGSize size = [label sizeThatFits:CGSizeZero];
    label.frame = CGRectMake(label.frame.origin.x, label.frame.origin.y, size.width, size.height);
}

- (void) useSizeThatFitsCustomWithLabel:(UILabel *)label width:(CGFloat) width height:(CGFloat) height{
    // CGSize size = [label sizeThatFits:CGSizeMake(width, height)];
    label.frame = CGRectMake(label.frame.origin.x, label.frame.origin.y, width, height);
}

- (void)pauseLoopTimer
{
    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        NSDictionary *properties = [widgetProps objectAtIndex:i];
        if (!getBoolFromDictKey(properties, @"isEnabled"))
            continue;
        [[EZTimer shareInstance] pause:[NSString stringWithFormat:@"labelview%d", i]];
    }
}

- (void)resumeLoopTimer
{
    NSArray *widgetProps = [self widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        NSDictionary *properties = [widgetProps objectAtIndex:i];
        if (!getBoolFromDictKey(properties, @"isEnabled"))
            continue;
        [[EZTimer shareInstance] resume:[NSString stringWithFormat:@"labelview%d", i]];
    }
}

- (void)viewSafeAreaInsetsDidChange
{
    [super viewSafeAreaInsetsDidChange];
    [self updateViewConstraints];
}

- (void)createWidgetSetsView
{
    // MARK: Create the Widgets
    // MIGHT NEED OPTIMIZATION
    for (NSDictionary *properties in [self widgetProperties]) {
        // create the blur
        NSDictionary *blurDetails = [properties valueForKey:@"blurDetails"] ? [properties valueForKey:@"blurDetails"] : @{@"hasBlur" : @(NO)};
        UIBlurEffect *blurEffect = [
            UIBlurEffect effectWithStyle: getBoolFromDictKey(blurDetails, @"styleDark", true) ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight
        ];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurView.layer.masksToBounds = YES;
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [_contentView addSubview:blurView];
        [_blurViews addObject:blurView];
        // create the halo label (behind the text, in front of any blur panel)
        HeliumHaloLabel *haloView = [[HeliumHaloLabel alloc] initWithFrame:CGRectZero];
        haloView.numberOfLines = 0;
        haloView.lineBreakMode = NSLineBreakByWordWrapping;
        haloView.translatesAutoresizingMaskIntoConstraints = NO;
        haloView.userInteractionEnabled = NO;
        // The halo is sized by the constraints in updateViewConstraints, not by
        // its own content: with hugging and compression resistance left at
        // their defaults, the halo's idea of its own width would feed back into
        // the text label's width through the equality between the two.
        [haloView setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
        [haloView setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
        [haloView setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisHorizontal];
        [haloView setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisVertical];
        [_contentView addSubview:haloView];
        [_haloViews addObject:haloView];
        // create the label
        UILabel *labelView = [[UILabel alloc] initWithFrame: CGRectZero];
        labelView.numberOfLines = 0;
        labelView.lineBreakMode = NSLineBreakByWordWrapping;
        labelView.translatesAutoresizingMaskIntoConstraints = NO;
        labelView.layer.borderColor = [UIColor redColor].CGColor;
        [labelView setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
        [_contentView addSubview:labelView];
        [_labelViews addObject:labelView];

        // MARK: Adaptive Color Backdrop
        // create backdrop view
        AnyBackdropView *backdropView = [[AnyBackdropView alloc] init];
        backdropView.translatesAutoresizingMaskIntoConstraints = NO;
        backdropView.layer.borderColor = [UIColor redColor].CGColor;
        [_contentView addSubview:backdropView];
        [_backdropViews addObject:backdropView];

        // create the mask label
        UILabel *maskLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        maskLabel.numberOfLines = 0;
        maskLabel.lineBreakMode = NSLineBreakByWordWrapping;
        maskLabel.translatesAutoresizingMaskIntoConstraints = NO;
        maskLabel.layer.borderColor = [UIColor redColor].CGColor;
        [maskLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
        [backdropView setMaskView:maskLabel];
        [_maskLabelViews addObject:maskLabel];
    }
}

- (void)updateViewConstraints
{
    [NSLayoutConstraint deactivateConstraints:_constraints];
    [_constraints removeAllObjects];

    BOOL isPad = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad);
    UILayoutGuide *layoutGuide = self.view.safeAreaLayoutGuide;
    
    // code from Lessica/TrollSpeed
    if ([self isLandscapeOrientation])
    {
        CGFloat notchHeight;
        CGFloat paddingNearNotch;
        CGFloat paddingFarFromNotch;

        notchHeight = CGRectGetMinY(layoutGuide.layoutFrame);
        paddingNearNotch = (notchHeight > 30) ? notchHeight - 16 : 4;
        paddingFarFromNotch = (notchHeight > 30) ? -24 : -4;

        [_constraints addObjectsFromArray:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:layoutGuide.leadingAnchor constant:(_orientation == UIInterfaceOrientationLandscapeLeft ? -paddingFarFromNotch : paddingNearNotch)],
            [_contentView.trailingAnchor constraintEqualToAnchor:layoutGuide.trailingAnchor constant:(_orientation == UIInterfaceOrientationLandscapeLeft ? -paddingNearNotch : paddingFarFromNotch)],
        ]];

        CGFloat minimumLandscapeTopConstant = 0;
        CGFloat minimumLandscapeBottomConstant = 0;

        minimumLandscapeTopConstant = (isPad ? 30 : 10);
        minimumLandscapeBottomConstant = (isPad ? -34 : -14);

        /* Fixed Constraints */
        [_constraints addObjectsFromArray:@[
            [_contentView.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.topAnchor constant:minimumLandscapeTopConstant],
            [_contentView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:minimumLandscapeBottomConstant],
        ]];

        /* Flexible Constraint */
        NSLayoutConstraint *_topConstraint = [_contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:minimumLandscapeTopConstant];
        _topConstraint.priority = UILayoutPriorityDefaultLow;

        [_constraints addObject:_topConstraint];
    }
    else
    {
        [_constraints addObjectsFromArray:@[
            [_contentView.leadingAnchor constraintEqualToAnchor:layoutGuide.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:layoutGuide.trailingAnchor],
        ]];

        CGFloat minimumTopConstraintConstant = 0;
        CGFloat minimumBottomConstraintConstant = 0;

        if (CGRectGetMinY(layoutGuide.layoutFrame) >= 51) {
            minimumTopConstraintConstant = -8;
            minimumBottomConstraintConstant = -4;
        } else if (CGRectGetMinY(layoutGuide.layoutFrame) > 30) {
            minimumTopConstraintConstant = -12;
            minimumBottomConstraintConstant = -4;
        } else {
            minimumTopConstraintConstant = (isPad ? 30 : 20);
            minimumBottomConstraintConstant = -20;
        }

        /* Fixed Constraints */
        [_constraints addObjectsFromArray:@[
            [_contentView.topAnchor constraintGreaterThanOrEqualToAnchor:layoutGuide.topAnchor constant:minimumTopConstraintConstant],
            [_contentView.bottomAnchor constraintLessThanOrEqualToAnchor:layoutGuide.bottomAnchor constant:minimumBottomConstraintConstant],
        ]];

        /* Flexible Constraint */
        NSLayoutConstraint *_topConstraint = [_contentView.topAnchor constraintEqualToAnchor:layoutGuide.topAnchor constant:minimumTopConstraintConstant];
        _topConstraint.priority = UILayoutPriorityDefaultLow;

        [_constraints addObject:_topConstraint];
    }

    // MARK: Set Label Constraints
    NSArray *widgetProps = [self widgetProperties];
    // DEFINITELY NEEDS OPTIMIZATION
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex:i];
        // UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];
        HeliumHaloLabel *haloView = (i < (NSInteger)_haloViews.count) ? [_haloViews objectAtIndex:i] : nil;
        NSDictionary *properties = [widgetProps objectAtIndex:i];
        if (!blurView || !labelView || !properties)
            break;
        if (!getBoolFromDictKey(properties, @"isEnabled"))
            continue;
        double offsetPX = getDoubleFromDictKey(properties, @"offsetPX");
        double offsetPY = getDoubleFromDictKey(properties, @"offsetPY");
        double offsetLX = getDoubleFromDictKey(properties, @"offsetLX");
        double offsetLY = getDoubleFromDictKey(properties, @"offsetLY");
        NSInteger anchorSide = getIntFromDictKey(properties, @"anchor");
        NSInteger anchorYSide = getIntFromDictKey(properties, @"anchorY");

        // set the vertical anchor
        if (anchorYSide == 1) {
            [_constraints addObject:[labelView.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor constant: ([self isLandscapeOrientation] ? offsetLY : offsetPY)]];
        } else if (anchorYSide == 0) {
            [_constraints addObject:[labelView.topAnchor constraintEqualToAnchor:_contentView.topAnchor constant: ([self isLandscapeOrientation] ? offsetLY : offsetPY)]];
        } else {
            [_constraints addObject:[labelView.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor constant: ([self isLandscapeOrientation] ? offsetLY : offsetPY)]];
        }
        // set the horizontal anchor
        //
        // Positive X is to the right, whichever edge the widget is anchored to.
        // This used to mean "inwards from the edge it is anchored to", so with
        // the right edge as the anchor a bigger value moved the widget left:
        // the arrow pointed one way and the widget went the other. Right
        // anchored sets were negated once when that changed -- see the
        // migration in WidgetManager -- so nothing on the screen moved.
        if (anchorSide == 1) {
            [_constraints addObject:[labelView.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor constant: ([self isLandscapeOrientation] ? offsetLX : offsetPX)]];
        } else if (anchorSide == 0) {
            [_constraints addObject:[labelView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant: ([self isLandscapeOrientation] ? offsetLX : offsetPX)]];
        } else {
            [_constraints addObject:[labelView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant: ([self isLandscapeOrientation] ? offsetLX : offsetPX)]];
        }

        // set the width
        if (!getBoolFromDictKey(properties, @"autoResizes")) {
            [_constraints addObject:[labelView.widthAnchor constraintEqualToConstant:getDoubleFromDictKey(properties, @"scale", 50.0)]];
            [_constraints addObject:[labelView.heightAnchor constraintEqualToConstant:getDoubleFromDictKey(properties, @"scaleY", 12.0)]];
        }
        
        [_constraints addObjectsFromArray:@[
            [blurView.topAnchor constraintEqualToAnchor:backdropView.topAnchor constant:-2],
            [blurView.leadingAnchor constraintEqualToAnchor:backdropView.leadingAnchor constant:-4],
            [blurView.trailingAnchor constraintEqualToAnchor:backdropView.trailingAnchor constant:4],
            [blurView.bottomAnchor constraintEqualToAnchor:backdropView.bottomAnchor constant:2],
        ]];
        
        [_constraints addObjectsFromArray:@[
            [blurView.topAnchor constraintEqualToAnchor:labelView.topAnchor constant:-2],
            [blurView.leadingAnchor constraintEqualToAnchor:labelView.leadingAnchor constant:-4],
            [blurView.trailingAnchor constraintEqualToAnchor:labelView.trailingAnchor constant:4],
            [blurView.bottomAnchor constraintEqualToAnchor:labelView.bottomAnchor constant:2],
        ]];

        // MARK: Text Halo Constraints
        // Same box as the text, grown on every side by the halo's width: a label
        // clips its own drawing, and the halo is by definition outside the text.
        // The inner text box is put back by HeliumHaloLabel itself, so growing
        // the frame does not move the glyphs.
        if (haloView) {
            CGFloat haloPad = haloView.haloPad;
            [_constraints addObjectsFromArray:@[
                [haloView.centerXAnchor constraintEqualToAnchor:labelView.centerXAnchor],
                [haloView.centerYAnchor constraintEqualToAnchor:labelView.centerYAnchor],
                [haloView.widthAnchor constraintEqualToAnchor:labelView.widthAnchor constant:haloPad * 2.0],
                [haloView.heightAnchor constraintEqualToAnchor:labelView.heightAnchor constant:haloPad * 2.0],
            ]];
        }
    }

    [_constraints addObjectsFromArray:@[
        [_horizontalLine.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor],
        [_horizontalLine.widthAnchor constraintEqualToAnchor:_contentView.widthAnchor],
        [_horizontalLine.heightAnchor constraintEqualToConstant:1]
    ]];
    
    [_constraints addObjectsFromArray:@[
        [_verticalLine.centerXAnchor constraintEqualToAnchor:_contentView.centerXAnchor],
        [_verticalLine.widthAnchor constraintEqualToConstant:1],
        [_verticalLine.heightAnchor constraintEqualToAnchor:_contentView.heightAnchor]
    ]];
    
    [NSLayoutConstraint activateConstraints:_constraints];
    [super updateViewConstraints];
}

static inline CGFloat orientationAngle(UIInterfaceOrientation orientation)
{
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown:
            return M_PI;
        case UIInterfaceOrientationLandscapeLeft:
            return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
            return M_PI_2;
        default:
            return 0;
    }
}

static inline CGRect orientationBounds(UIInterfaceOrientation orientation, CGRect bounds)
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return CGRectMake(0, 0, bounds.size.height, bounds.size.width);
        default:
            return bounds;
    }
}

- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration
{
    __weak typeof(self) weakSelf = self;
    NSArray *widgetProps = [weakSelf widgetProperties];
    for (int i = 0; i < [widgetProps count]; i++) {
        UIVisualEffectView *blurView = [_blurViews objectAtIndex:i];
        UILabel *labelView = [_labelViews objectAtIndex:i];
        AnyBackdropView *backdropView = [_backdropViews objectAtIndex: i];
        UILabel *maskLabelView = [_maskLabelViews objectAtIndex:i];
        HeliumHaloLabel *haloView = (i < (NSInteger)_haloViews.count) ? [_haloViews objectAtIndex:i] : nil;

        NSDictionary *properties = [widgetProps objectAtIndex:i];
        NSInteger orientationMode = getIntFromDictKey(properties, @"orientationMode", 0);
        BOOL isEnabled = getBoolFromDictKey(properties, @"isEnabled");
        BOOL dynamicColor = getBoolFromDictKey(properties, @"dynamicColor", true);
        if (isEnabled) {
            switch (orientationMode) {
                // Portrait
                case 1: {
                    if (UIInterfaceOrientationIsLandscape(orientation)) {
                        [blurView setHidden:YES];
                        [labelView setHidden:YES];
                        [backdropView setHidden:YES];
                        [maskLabelView setHidden:YES];
                    } else {
                        if (dynamicColor) {
                            [backdropView setHidden:NO];
                            [maskLabelView setHidden:NO];
                        } else {
                            [blurView setHidden:NO];
                            [labelView setHidden:NO];
                        }
                    }
                }break;
                // Landscape
                case 2: {
                    if (UIInterfaceOrientationIsLandscape(orientation)) {
                        if (dynamicColor) {
                            [backdropView setHidden:NO];
                            [maskLabelView setHidden:NO];
                        } else {
                            [blurView setHidden:NO];
                            [labelView setHidden:NO];
                        }
                    } else {
                        [blurView setHidden:YES];
                        [labelView setHidden:YES];
                        [backdropView setHidden:YES];
                        [maskLabelView setHidden:YES];
                    }
                }break;
            }
            // The halo follows the text it sits behind, so it hides and shows
            // with it rather than on its own schedule.
            if (haloView) {
                HeliumHaloStyle *haloStyle = HeliumHaloStyleFromProperties(properties);
                BOOL textVisible = dynamicColor ? !backdropView.hidden : !labelView.hidden;
                [haloView setHidden:!(textVisible && haloStyle.isActive)];
            }
        }
    }

    if (orientation == _orientation) {
        return;
    }

    _orientation = orientation;

    CGRect bounds = orientationBounds(orientation, [UIScreen mainScreen].bounds);
    [self.view setNeedsUpdateConstraints];
    [self.view setHidden:YES];
    [self.view setBounds:bounds];

    [UIView animateWithDuration:duration animations:^{
        [weakSelf.view setTransform:CGAffineTransformMakeRotation(orientationAngle(orientation))];
    } completion:^(BOOL finished) {
        [weakSelf.view setHidden:NO];
    }];
}

@end
