#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "Helium-Swift.h"
#import "../extensions/FontUtils.h"
#import "../hud/HRMonitor.h"

@implementation MainApplicationDelegate

- (instancetype)init {
    if (self = [super init]) {
        os_log_debug(OS_LOG_DEFAULT, "- [MainApplicationDelegate init]");
    }
    return self;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions {
    os_log_debug(OS_LOG_DEFAULT, "- [MainApplicationDelegate application:%{public}@ didFinishLaunchingWithOptions:%{public}@]", application, launchOptions);

    // load fonts from app
    [FontUtils loadFontsFromFolder:[NSString stringWithFormat:@"%@%@", [[NSBundle mainBundle] resourcePath],  @"/fonts"]];
    // load fonts from documents
    [FontUtils loadFontsFromFolder:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]];
    [FontUtils loadAllFonts];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window setRootViewController:[[[ContentInterface alloc] init] createUI]];
    [self.window makeKeyAndVisible];

    // The heart rate link is hosted *here* as well as in the HUD.
    //
    // The HUD is a process posix_spawn'd out of this bundle and CoreBluetooth
    // does not reliably work from one: the central manager it creates never
    // reports a state, so it never scans. This app has the ordinary lifecycle
    // the Bluetooth stack expects, plus the bluetooth-central background mode,
    // so it holds the connection and writes every reading to the file the HUD's
    // heart rate widget already reads. Whichever process ends up owning the
    // band, the widget shows what that process saw.
    [HRMonitor startMonitoring];

    return YES;
}

@end