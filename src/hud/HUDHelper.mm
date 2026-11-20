#import <spawn.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <dlfcn.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <errno.h>

#import "HUDHelper.h"

extern "C" char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

#pragma mark - The switch as a preference

// The file SettingsView.swift calls USER_DEFAULTS_PATH, written the same way its
// Swift extension writes it: read the whole plist, change one key, write it
// back. That is what makes the HUD able to see the switch at all -- its own
// liveness cannot tell it whether the user still wants it.
BOOL HUDEnabledPreference(BOOL *known)
{
    NSDictionary *defaults = [NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH];
    id value = [defaults objectForKey:@"hudEnabled"];
    BOOL hasValue = ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]);
    if (known)
        *known = hasValue;
    if (!hasValue)
        return YES;
    if ([value isKindOfClass:[NSNumber class]])
        return [value boolValue];
    return ([value description].intValue != 0);
}

void SetHUDEnabledPreference(BOOL enabled)
{
    NSMutableDictionary *defaults = [[NSDictionary dictionaryWithContentsOfFile:USER_DEFAULTS_PATH] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    [defaults setObject:@(enabled ? 1 : 0) forKey:@"hudEnabled"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:defaults
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data)
        [data writeToFile:USER_DEFAULTS_PATH atomically:YES];
}

#pragma mark - Killing the HUD process

static NSString *HUDPIDFilePath(void)
{
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [caches stringByAppendingPathComponent:@"hud.pid"];
}

static NSString *CurrentExecutablePath(void);

#define HUD_PIDPATH_MAX 4096

// proc_pidpath is in the kernel library, but libproc.h is a macOS header and is
// not in the iPhoneOS SDK, so the symbol is looked up instead of included.
typedef int (*HUDProcPidPathFn)(int, void *, uint32_t);
static HUDProcPidPathFn HUDProcPidPath(void)
{
    static HUDProcPidPathFn function = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (HUDProcPidPathFn)dlsym(RTLD_DEFAULT, "proc_pidpath");
    });
    return function;
}

static NSString *HUDProcessName(pid_t pid)
{
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0)
        return nil;
    return [NSString stringWithUTF8String:info.kp_proc.p_comm] ?: nil;
}

/// True only when `pid` is alive, is not us, and is running this bundle's
/// executable. The HUD is spawned from the same binary as the app, so the
/// executable path is exactly the identity check needed here.
static BOOL HUDPIDIsOurHUD(pid_t pid, NSString **why)
{
    if (pid <= 0) {
        if (why) *why = @"hud.pid has no pid";
        return NO;
    }
    if (pid == getpid()) {
        if (why) *why = @"hud.pid holds this process";
        return NO;
    }
    if (kill(pid, 0) != 0) {
        if (why) *why = [NSString stringWithFormat:@"pid %d is not running", pid];
        return NO;
    }
    HUDProcPidPathFn pidpath = HUDProcPidPath();
    char path[HUD_PIDPATH_MAX] = {0};
    if (!pidpath || pidpath(pid, path, sizeof(path)) <= 0) {
        // Without proc_pidpath all that is left is the process name, which is
        // weaker but still refuses to kill anything that is not Helium.
        NSString *name = HUDProcessName(pid);
        NSString *myName = CurrentExecutablePath().lastPathComponent;
        if (name.length && myName.length && [name isEqualToString:myName]) {
            if (why) *why = [NSString stringWithFormat:@"pid %d is %@ (by process name)", pid, name];
            return YES;
        }
        if (why) *why = [NSString stringWithFormat:@"pid %d cannot be identified (%@)", pid, name ?: @"no name"];
        return NO;
    }
    NSString *executable = [[NSString stringWithUTF8String:path] stringByStandardizingPath];
    NSString *mine = [CurrentExecutablePath() stringByStandardizingPath];
    if (mine.length && ![executable isEqualToString:mine]) {
        if (why) *why = [NSString stringWithFormat:@"pid %d runs %@, not %@", pid, executable, mine];
        return NO;
    }
    if (why) *why = [NSString stringWithFormat:@"pid %d is %@", pid, executable.lastPathComponent];
    return YES;
}

BOOL TerminateHUDProcessIfRunning(NSString **how)
{
    NSString *path = HUDPIDFilePath();
    NSString *pidString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    pidString = [pidString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (pidString.length == 0) {
        if (how) *how = @"no hud.pid, nothing to kill";
        return NO;
    }
    pid_t pid = (pid_t)[pidString intValue];
    NSString *why = nil;
    if (!HUDPIDIsOurHUD(pid, &why)) {
        if (how) *how = [NSString stringWithFormat:@"refused to kill: %@", why ?: @"not our HUD"];
        return NO;
    }

    kill(pid, SIGTERM);
    for (int i = 0; i < 30; i++) {
        if (kill(pid, 0) != 0)
            break;
        usleep(20 * 1000);
    }
    BOOL stillThere = (kill(pid, 0) == 0);
    if (stillThere)
        kill(pid, SIGKILL);
    unlink([path fileSystemRepresentation]);
    if (how) {
        *how = [NSString stringWithFormat:@"%@ SIGTERM/pid %d",
                stillThere ? @"escalated to SIGKILL after" : @"sent", pid];
    }
    return YES;
}

BOOL IsHUDEnabled(void)
{
    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t task_pid;
    const char *args[] = { executablePath, "-check", NULL };
    posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);

#if DEBUG
    os_log_debug(OS_LOG_DEFAULT, "spawned %{public}s -check pid = %{public}d", executablePath, task_pid);
#endif
    
    int status;
    do {
        if (waitpid(task_pid, &status, 0) != -1)
        {
#if DEBUG
            os_log_debug(OS_LOG_DEFAULT, "child status %d", WEXITSTATUS(status));
#endif
        }
    } while (!WIFEXITED(status) && !WIFSIGNALED(status));

    return WEXITSTATUS(status) != 0;
}

void SetHUDEnabled(BOOL isEnabled)
{
#ifdef NOTIFY_DISMISSAL_HUD
    notify_post(NOTIFY_DISMISSAL_HUD);
#endif

    // Store the switch first: the HUD reads this when it is told to reload, so
    // a HUD that is asleep, wedged, or holding a stale pid still finds out that
    // it is no longer wanted.
    SetHUDEnabledPreference(isEnabled);

    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    if (isEnabled)
    {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

        pid_t task_pid;
        const char *args[] = { executablePath, "-hud", NULL };
        posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);

#if DEBUG
        os_log_debug(OS_LOG_DEFAULT, "spawned %{public}s -hud pid = %{public}d", executablePath, task_pid);
#endif
    }
    else
    {
        [NSThread sleepForTimeInterval:0.25];

        pid_t task_pid;
        const char *args[] = { executablePath, "-exit", NULL };
        posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);

#if DEBUG
        os_log_debug(OS_LOG_DEFAULT, "spawned %{public}s -exit pid = %{public}d", executablePath, task_pid);
#endif
        
        int status;
        do {
            if (waitpid(task_pid, &status, 0) != -1)
            {
#if DEBUG
                os_log_debug(OS_LOG_DEFAULT, "child status %d", WEXITSTATUS(status));
#endif
            }
        } while (!WIFEXITED(status) && !WIFSIGNALED(status));

        // Belt and braces: -exit kills the pid it reads from hud.pid, but that
        // only works if that file is there, readable and current. If a HUD is
        // still alive now, kill it here -- after checking that the pid really
        // is this bundle's executable.
        NSString *how = nil;
        BOOL terminated = TerminateHUDProcessIfRunning(&how);
        os_log_debug(OS_LOG_DEFAULT, "hud switch off: %{public}s", how ? how.UTF8String : "?");
        (void)terminated;
    }
}

#pragma mark - Which build the running HUD is

static NSString *CurrentExecutablePath(void)
{
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *buffer = (char *)calloc(1, size);
    _NSGetExecutablePath(buffer, &size);
    NSString *path = [NSString stringWithUTF8String:buffer];
    free(buffer);
    return path;
}

// Next to hud.pid and for the same reason: the app and the HUD are the same
// bundle, so they share this directory, and deleting the app clears both.
static NSString *GetBuildRecordPath(void)
{
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        path = [caches stringByAppendingPathComponent:@"hud.build"];
    });
    return path;
}

NSString *HUDBuildFingerprint(void)
{
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:CurrentExecutablePath() error:nil];
    if (!attributes)
        return @"unknown";

    NSDate *modified = [attributes objectForKey:NSFileModificationDate];
    NSNumber *size = [attributes objectForKey:NSFileSize];
    return [NSString stringWithFormat:@"%lld-%lld", (long long)[modified timeIntervalSince1970], [size longLongValue]];
}

void RecordHUDBuildFingerprint(void)
{
    [HUDBuildFingerprint() writeToFile:GetBuildRecordPath()
                          atomically:YES
                            encoding:NSUTF8StringEncoding
                               error:nil];
}

void ClearHUDBuildFingerprint(void)
{
    [[NSFileManager defaultManager] removeItemAtPath:GetBuildRecordPath() error:nil];
}

BOOL IsHUDBuildStale(void)
{
    // Nothing running: starting one is the switch's job, not this function's.
    if (!IsHUDEnabled())
        return NO;

    NSString *recorded = [NSString stringWithContentsOfFile:GetBuildRecordPath()
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    // A running HUD with no record at all is a HUD that predates this
    // bookkeeping, ie one from before this version. That is the case this
    // function exists for, so it counts as stale.
    if (!recorded)
        return YES;

    recorded = [recorded stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ![recorded isEqualToString:HUDBuildFingerprint()];
}

#pragma mark -

void waitForNotification(void (^onFinish)(), BOOL isEnabled)
{
    if (isEnabled)
   {
       dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

       int token;
       notify_register_dispatch(NOTIFY_LAUNCHED_HUD, &token, dispatch_get_main_queue(), ^(int token) {
           notify_cancel(token);
           dispatch_semaphore_signal(semaphore);
       });

       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
           int timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
           dispatch_async(dispatch_get_main_queue(), ^{
               if (timedOut)
                   os_log_error(OS_LOG_DEFAULT, "Timed out waiting for HUD to launch");
               
               onFinish();
           });
       });
   }
   else
   {
       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
           onFinish();
       });
   }
}