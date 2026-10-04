#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "MinerConfiguration.h"
#import "MinerSettingsViewController.h"
#import <TargetConditionals.h>

#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <sys/utsname.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include "App.h"
#include "base/kernel/Entry.h"
#include "base/kernel/Process.h"
#include "crypto/common/VirtualMemory.h"
#include "BatteryHysteresis.h"


static std::atomic<bool> g_minerRunning{false};
static std::atomic<bool> g_onDeviceJITRequested{false};
static std::atomic<bool> g_handoffBackgrounded{false};
static std::atomic<bool> g_forceInterpreterFallback{false};
static std::atomic<bool> g_batteryGuardPaused{false};
static std::atomic<bool> g_batteryDeferredStart{false};
static std::atomic<int> g_batteryPercent{-1};
static NSString *g_logPathOverride = nil;
static NSString *g_configPathOverride = nil;
static NSDictionary *g_activeProfile = nil;
static NSString *g_startError = nil;
static BOOL g_userRunRequested = NO;
static BOOL g_chargerPaused = NO;
static BOOL g_thermalPaused = NO;
static BOOL g_backgroundPaused = NO;

static NSString *documentsPath(void);
static NSString *profilePath(void) { return [documentsPath() stringByAppendingPathComponent:@"config.json"]; }


static BOOL startMiner(void);
static BOOL startAutomaticMiner(void);


static NSString *documentsPath(void)
{
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSString *path = urls.firstObject.path;
    if (path.length > 0) {
        return path;
    }

    NSString *home = NSHomeDirectory();
    if (home.length > 0) {
        return [home stringByAppendingPathComponent:@"Documents"];
    }

    return @"/tmp";
}


static NSString *logPath(void)
{
    if (g_logPathOverride.length > 0) {
        return g_logPathOverride;
    }

    return [documentsPath() stringByAppendingPathComponent:@"xmrig.log"];
}


static NSString *configPath(void)
{
    if (g_configPathOverride.length > 0) {
        return g_configPathOverride;
    }

    return [documentsPath() stringByAppendingPathComponent:@"runtime.json"];
}


static NSMutableDictionary *loadUserProfile(void)
{
    NSError *error = nil;
    NSMutableDictionary *profile = XMRLoadProfile(profilePath(), &error);
    if (!profile) g_startError = error.localizedDescription;
    return profile;
}

static NSInteger pausePercent(void) { return [g_activeProfile[@"xmrand"][@"pause-battery"] ?: @15 integerValue]; }
static NSInteger resumePercent(void) { return [g_activeProfile[@"xmrand"][@"resume-battery"] ?: @40 integerValue]; }
static BOOL pendingJITStart(void)
{
    double remaining = [NSUserDefaults.standardUserDefaults doubleForKey:@"jitStartDeadline"] - NSDate.date.timeIntervalSince1970;
    return remaining > 0 && remaining <= 180;
}
static void clearJITStart(void) { [NSUserDefaults.standardUserDefaults removeObjectForKey:@"jitStartDeadline"]; }
static BOOL prepareMinerConfig(NSError **error)
{
    NSMutableDictionary *profile = XMRLoadProfile(profilePath(), error);
    if (!profile) return NO;
    NSMutableDictionary *runtime = XMRRuntimeProfile(profile, logPath(), NSProcessInfo.processInfo.activeProcessorCount, error);
    if (!runtime) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:runtime options:NSJSONWritingPrettyPrinted error:error];
    if (!data || ![data writeToFile:configPath() options:NSDataWritingAtomic error:error]) return NO;
    g_activeProfile = profile;
    return YES;
}

static int runXmrigAtPath(NSString *path)
{
    using namespace xmrig;

    std::string config = path.UTF8String;
    std::vector<std::string> args = { "xmrig", "--config", config, "--no-color" };
    std::vector<char *> argv;
    argv.reserve(args.size());
    for (std::string &arg : args) {
        argv.push_back(const_cast<char *>(arg.c_str()));
    }

    Process process(static_cast<int>(argv.size()), argv.data());
    const Entry::Id entry = Entry::get(process);
    if (entry) {
        return Entry::exec(process, entry);
    }

    App app(&process);
    return app.exec();
}


static BOOL hasArgument(int argc, char *argv[], const char *name)
{
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], name) == 0) {
            return YES;
        }
    }

    return NO;
}


static NSString *argumentValue(int argc, char *argv[], const char *name)
{
    for (int i = 1; i + 1 < argc; ++i) {
        if (strcmp(argv[i], name) == 0) {
            return [NSString stringWithUTF8String:argv[i + 1]];
        }
    }

    return nil;
}


static void appendMinerDiagnostic(NSString *message)
{
    FILE *log = fopen(logPath().UTF8String, "a");
    if (log) {
        fprintf(log, "\n%s\n", message.UTF8String);
        fclose(log);
    }
}


static void appendEarlyDiagnostic(const char *message)
{
    NSString *path = [documentsPath() stringByAppendingPathComponent:@"xmrand-main.log"];
    FILE *log = fopen(path.fileSystemRepresentation, "a");
    if (log) {
        fprintf(log, "%s\n", message);
        fclose(log);
    }
}


static void appendEarlyDiagnosticNSString(NSString *message)
{
    appendEarlyDiagnostic(message.UTF8String ?: "XMRAnd diagnostic unavailable");
}


static void updateBatteryGuard(void)
{
    UIDevice *device = UIDevice.currentDevice;
    int percent = device.batteryLevel < 0 ? -1 : (int)(device.batteryLevel * 100 + 0.5F);
#if TARGET_OS_SIMULATOR
    percent = 100;
#endif
    g_batteryPercent.store(percent);
    const auto action = xmrand_ios::batteryGuardAction(percent,g_batteryGuardPaused.load(),(int)pausePercent(),(int)resumePercent());
    if (action == xmrand_ios::BatteryGuardAction::Pause) g_batteryGuardPaused.store(true);
    else if (action == xmrand_ios::BatteryGuardAction::Resume) g_batteryGuardPaused.store(false);
    BOOL charging = device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull;
    g_chargerPaused = [g_activeProfile[@"xmrand"][@"charging-only"] boolValue] && !charging;
    g_thermalPaused = NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious;
    BOOL permitted = percent >= 0 && !g_batteryGuardPaused.load() && !g_chargerPaused && !g_thermalPaused && !g_backgroundPaused;
    if (g_minerRunning.load()) xmrig::App::setMiningEnabled(permitted);
    UIApplication.sharedApplication.idleTimerDisabled = g_minerRunning.load() && permitted;
    if (permitted && g_userRunRequested && g_batteryDeferredStart.load() && !g_minerRunning.load()) {
        g_batteryDeferredStart.store(false);
        startMiner();
    }
}

static void installTerminateLogger(void)
{
    std::set_terminate([] {
        try {
            std::exception_ptr ex = std::current_exception();
            if (ex) {
                std::rethrow_exception(ex);
            }
        }
        catch (const std::exception &ex) {
            appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd terminate exception: %s", ex.what()]);
        }
        catch (...) {
            appendMinerDiagnostic(@"XMRAnd terminate exception: unknown");
        }

        abort();
    });
}


#if defined(XMRIG_IOS_JIT)
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <setjmp.h>
#include <signal.h>
#include <cerrno>
#include <sys/sysctl.h>
#include <mach/mach.h>
// <mach/mach_vm.h> is marked unsupported on iOS, but mach_vm_remap exists in
// libsystem. Declare the single call we need with plain integer types.
extern "C" kern_return_t mach_vm_remap(mach_port_t, uint64_t *, uint64_t, uint64_t,
    int, mach_port_t, uint64_t, int, vm_prot_t *, vm_prot_t *, unsigned int);
#ifndef VM_FLAGS_ANYWHERE
#define VM_FLAGS_ANYWHERE 0x0001
#endif
#ifndef VM_INHERIT_NONE
#define VM_INHERIT_NONE 2
#endif

extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

static bool iosIs26OrLater(void)
{
    char buf[64] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("kern.osproductversion", buf, &len, NULL, 0) == 0) {
        return atoi(buf) >= 26;
    }
    return false;
}


static BOOL requestOnDeviceJIT(void)
{
    if (g_forceInterpreterFallback.load() || xmrig::VirtualMemory::isJITAvailable()) {
        return NO;
    }

    bool expected = false;
    if (!g_onDeviceJITRequested.compare_exchange_strong(expected, true)) {
        return YES;
    }
    g_handoffBackgrounded.store(false);

    NSString *helper = [NSBundle.mainBundle objectForInfoDictionaryKey:@"XMRAndHelperScheme"] ?: @"xmrand-stikdebug";
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = helper; components.host = @"enable-jit";
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"bundle-id" value:NSBundle.mainBundle.bundleIdentifier]];
    NSURL *url = components.URL;
    UIApplication *application = UIApplication.sharedApplication;
    if (url == nil || ![application canOpenURL:url]) {
        g_onDeviceJITRequested.store(false);
        appendMinerDiagnostic(@"XMRAnd on-device JIT helper is not installed; using interpreter fallback");
        return NO;
    }

    appendMinerDiagnostic(@"XMRAnd requesting on-device JIT via StikDebug");
    [application openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) {
            g_onDeviceJITRequested.store(false);
            g_forceInterpreterFallback.store(true);
            appendMinerDiagnostic(@"XMRAnd could not open StikDebug; using interpreter fallback");
            dispatch_async(dispatch_get_main_queue(), ^{
                startAutomaticMiner();
            });
        }
    }];
    return YES;
}

// Standalone probe of the platform JIT capability, independent of RandomX.
// Emits a 2-instruction AArch64 function (movz w0,#42 ; ret), flips the page to
// executable via the W^X path, and calls it. On stock iOS this only succeeds when
// the process is CS_DEBUGGED (a debugger attached), which is exactly what gates
// RandomX's JIT. Result is written to the app log for retrieval.
static void runJitSelfTest(void)
{
    const size_t pg = 16384;
    const uint32_t code[2] = { 0x52800540u, 0xd65f03c0u }; // movz w0,#42 ; ret

    // Mirror RandomX's strict W^X discipline (works on iOS 18 and iOS 26/arm64e):
    // RW alloc -> write -> mprotect(R+X) -> execute. A persistent-RWX test would
    // false-positive on iOS 26 (the RWX mmap succeeds but execution later faults).
    void *mem = mmap(0, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mem == MAP_FAILED) {
        appendMinerDiagnostic([NSString stringWithFormat:@"[jit-selftest] mmap failed errno=%d -> no executable memory", errno]);
        return;
    }

    memcpy(mem, code, sizeof(code));

    if (mprotect(mem, pg, PROT_READ | PROT_EXEC) != 0) {
        appendMinerDiagnostic([NSString stringWithFormat:@"[jit-selftest] mprotect R+X failed errno=%d -> CS_DEBUGGED not active, JIT unavailable (attach a debugger)", errno]);
        munmap(mem, pg);
        return;
    }

    sys_icache_invalidate(mem, pg);

    int (*fn)(void) = reinterpret_cast<int (*)(void)>(mem);
    const int result = fn();
    appendMinerDiagnostic([NSString stringWithFormat:@"[jit-selftest] mode=wx-toggle result=%d expected=42 -> %@",
                          result, result == 42 ? @"PASS (RandomX JIT will run)" : @"FAIL"]);
    munmap(mem, pg);
}


// --- iOS 26 executable-memory strategy probe (gated by XMRAND_JIT_PROBE) ------
// iOS 18 permits mprotect(RX)+execute on plain anon memory under CS_DEBUGGED;
// iOS 26 does not. Test whether MAP_JIT pages (which the kernel treats as JIT
// memory) change that. Each execute is guarded by a SIGBUS/SIGSEGV/SIGILL handler
// so a fault logs a result instead of killing the app. Run with lldb DETACHED
// (CS_DEBUGGED persists) so the handler, not lldb, catches the fault.
static sigjmp_buf g_probeJmp;
static void probeSig(int s) { siglongjmp(g_probeJmp, s); }

static bool guardedExec(void *mem)
{
    struct sigaction sa = {}, ob = {}, os = {}, oi = {};
    sa.sa_handler = probeSig;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS,  &sa, &ob);
    sigaction(SIGSEGV, &sa, &os);
    sigaction(SIGILL,  &sa, &oi);
    bool ok = false;
    if (sigsetjmp(g_probeJmp, 1) == 0) {
        int (*fn)(void) = reinterpret_cast<int (*)(void)>(mem);
        ok = (fn() == 42);
    }
    sigaction(SIGBUS,  &ob, NULL);
    sigaction(SIGSEGV, &os, NULL);
    sigaction(SIGILL,  &oi, NULL);
    return ok;
}

static void runJitStrategyProbe(void)
{
    uint32_t csflags = 0;
    csops(getpid(), CS_OPS_STATUS, &csflags, sizeof(csflags));
    appendMinerDiagnostic([NSString stringWithFormat:@"[probe] CS_DEBUGGED=%d csflags=0x%08x",
                          (csflags & CS_DEBUGGED) ? 1 : 0, csflags]);

    const size_t pg = 16384;
    const uint32_t code[2] = { 0x52800540u, 0xd65f03c0u };

    // A: plain anon, RW -> mprotect(RX) -> exec  (works iOS 18, faults iOS 26)
    {
        void *m = mmap(0, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        int prot = -1; bool exec = false;
        if (m != MAP_FAILED) { memcpy(m, code, sizeof(code)); prot = mprotect(m, pg, PROT_READ | PROT_EXEC); sys_icache_invalidate(m, pg); if (prot == 0) exec = guardedExec(m); munmap(m, pg); }
        appendMinerDiagnostic([NSString stringWithFormat:@"[probe A anon+mprotect] mmap=%d mprotectRX=%d exec=%@", m != MAP_FAILED, prot, exec ? @"PASS" : @"fault"]);
    }
    // B: MAP_JIT, RW -> mprotect(RX) -> exec
    {
        errno = 0;
        void *m = mmap(0, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        int me = errno; int prot = -1; bool exec = false;
        if (m != MAP_FAILED) { memcpy(m, code, sizeof(code)); prot = mprotect(m, pg, PROT_READ | PROT_EXEC); sys_icache_invalidate(m, pg); if (prot == 0) exec = guardedExec(m); munmap(m, pg); }
        appendMinerDiagnostic([NSString stringWithFormat:@"[probe B MAP_JIT+mprotect] mmap=%d(errno=%d) mprotectRX=%d exec=%@", m != MAP_FAILED, m == MAP_FAILED ? me : 0, prot, exec ? @"PASS" : @"fault"]);
    }
    // C: MAP_JIT, RWX at map time -> exec
    {
        errno = 0;
        void *m = mmap(0, pg, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        int me = errno; bool exec = false;
        if (m != MAP_FAILED) { memcpy(m, code, sizeof(code)); sys_icache_invalidate(m, pg); exec = guardedExec(m); munmap(m, pg); }
        appendMinerDiagnostic([NSString stringWithFormat:@"[probe C MAP_JIT rwx] mmap=%d(errno=%d) exec=%@", m != MAP_FAILED, m == MAP_FAILED ? me : 0, exec ? @"PASS" : @"fault"]);
    }
    appendMinerDiagnostic(@"[probe] done");
}


// --- iOS 26 debugger-cooperative JIT: the reusable primitive ------------------
// The app cannot make its own executable memory on iOS 26, but the attached
// debugger (which holds com.apple.private.cs.debugger) can. The app fills g_jitReq
// with a size and calls xmrand_jit_alloc_bp(); the lldb allocator service has a
// breakpoint there, allocates an R+X region (the _M,rx path) and writes the
// address back into g_jitReq.addr. The app then dual-maps that region RW via
// vm_remap so it can rewrite code at full speed (write RW alias, execute RX alias).
// Debugger-cooperative JIT allocation via StikDebug's universal JIT-call ABI
// (symbol-free, so it works in a stripped Release build). x0=0 requests an
// allocation, x1 is the size, x16=1 selects prepare-region, and brk #0xf00d
// dispatches it. The debugger returns the R+X address in x0 and steps past BRK.
// Returns nullptr if no debugger services it.
static void *xmrandDbgAllocRX(size_t size)
{
    uint32_t csflags = 0;
    csops(getpid(), CS_OPS_STATUS, &csflags, sizeof(csflags));
    if (!(csflags & CS_DEBUGGED)) {
        return nullptr;   // no debugger attached: a BRK would just crash us
    }
    register uint64_t x0 __asm__("x0") = 0;
    register uint64_t x1 __asm__("x1") = static_cast<uint64_t>(size);
    register uint64_t x16 __asm__("x16") = 1;
    __asm__ __volatile__("brk #0xf00d" : "+r"(x0), "+r"(x1), "+r"(x16) : : "memory", "cc");
    return reinterpret_cast<void *>(x0);
}

static void runDualMapTest(void)
{
    uint32_t cf = 0;
    int cr = csops(getpid(), CS_OPS_STATUS, &cf, sizeof(cf));
    appendMinerDiagnostic([NSString stringWithFormat:@"[dualmap] csops rc=%d CS_DEBUGGED=%d csflags=0x%08x",
                          cr, (cf & CS_DEBUGGED) ? 1 : 0, cf]);

    const size_t pg = 16384;
    void *rx = xmrandDbgAllocRX(pg);
    if (rx == nullptr) {
        appendMinerDiagnostic(@"[dualmap] debugger alloc returned 0 (guard bailed or BRK unserviced)");
        return;
    }

    uint64_t rw = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &rw, pg, 0, VM_FLAGS_ANYWHERE,
                                     mach_task_self(), (uint64_t)(uintptr_t)rx, 0,
                                     &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        appendMinerDiagnostic([NSString stringWithFormat:@"[dualmap] rx=%p vm_remap FAILED kr=%d", rx, kr]);
        return;
    }
    if (mprotect(reinterpret_cast<void *>(rw), pg, PROT_READ | PROT_WRITE) != 0) {
        appendMinerDiagnostic([NSString stringWithFormat:@"[dualmap] rw alias mprotect RW failed errno=%d", errno]);
        return;
    }

    // write movz w0,#105 ; ret through the RW alias, execute via the RX alias
    reinterpret_cast<uint32_t *>(rw)[0] = 0x52800d20u;
    reinterpret_cast<uint32_t *>(rw)[1] = 0xd65f03c0u;
    sys_icache_invalidate(rx, pg);

    int (*fn)(void) = reinterpret_cast<int (*)(void)>(rx);
    const int r = fn();
    appendMinerDiagnostic([NSString stringWithFormat:@"[dualmap] rx=%p rw=0x%llx exec=%d expect=105 -> %@",
                          rx, (unsigned long long)rw, r, r == 105 ? @"PASS (dual-map JIT works on iOS 26)" : @"FAIL"]);
}
#else
static BOOL requestOnDeviceJIT(void)
{
    return NO;
}
#endif


static BOOL startMiner(void)
{
    const int batteryPercent = g_batteryPercent.load();
    if (batteryPercent >= 0
        && batteryPercent <= pausePercent()
        && !g_batteryGuardPaused.exchange(true)) {
        xmrig::App::setMiningEnabled(false);
    }

    if (batteryPercent < 0 || g_batteryGuardPaused.load() || g_chargerPaused || g_thermalPaused || g_backgroundPaused) {
        const bool firstDeferredStart = !g_batteryDeferredStart.exchange(true);
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        if (firstDeferredStart) {
            if (batteryPercent < 0) {
                appendMinerDiagnostic(@"XMRAnd start deferred until the first valid battery reading");
            }
            else {
                appendMinerDiagnostic([NSString stringWithFormat:
                    @"XMRAnd start deferred by battery guard; automatic start threshold is %d%%",
                    (int)resumePercent()]);
            }
        }
        return NO;
    }

    g_batteryDeferredStart.store(false);
    bool expected = false;
    if (!g_minerRunning.compare_exchange_strong(expected, true)) {
        return NO;
    }

    NSString *path = configPath();
    std::string ownedPath = path.UTF8String;

    std::thread([ownedPath] {
        @autoreleasepool {
            NSString *threadPath = [NSString stringWithUTF8String:ownedPath.c_str()];
            int rc = -1;
            try {
#if defined(XMRIG_IOS_JIT)
                if (getenv("XMRAND_JIT_DUALMAP_TEST")) {
                    runDualMapTest();
                    while (true) { sleep(3600); }
                }
                if (getenv("XMRAND_JIT_PROBE")) {
                    runJitStrategyProbe();       // guarded; won't crash the app
                    while (true) { sleep(3600); }
                }
                // A stock iOS 18 process can report a successful mprotect(RX)
                // and still be code-signing-killed when the page executes. Only
                // run this diagnostic when the process actually has JIT rights.
                // iOS 26 uses the debugger-cooperative dual-map path instead.
                if (!iosIs26OrLater() && xmrig::VirtualMemory::isJITAvailable()) {
                    runJitSelfTest();
                }
#endif
                rc = runXmrigAtPath(threadPath);
            }
            catch (const std::exception &ex) {
                appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd miner exception: %s", ex.what()]);
            }
            catch (...) {
                appendMinerDiagnostic(@"XMRAnd miner exception: unknown");
            }
            appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd miner exited rc=%d", rc]);
            g_minerRunning.store(false);
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIApplication sharedApplication].idleTimerDisabled = NO;
            });
        }
    }).detach();

    [UIApplication sharedApplication].idleTimerDisabled = YES;
    return YES;
}


static BOOL startAutomaticMiner(void)
{
    if (!g_userRunRequested || g_minerRunning.load() || g_batteryDeferredStart.load()) return NO;
    NSError *error = nil;
    if (!prepareMinerConfig(&error)) {
        g_startError = error.localizedDescription;
        g_userRunRequested = NO;
        clearJITStart();
        return NO;
    }
    if (!xmrig::VirtualMemory::isJITAvailable() && ![g_activeProfile[@"xmrand"][@"allow-interpreter"] boolValue]) {
        g_startError = @"JIT is unavailable. Open Setup to connect StikDebug/LocalDevVPN, or explicitly allow the slower interpreter in settings.";
        g_userRunRequested = NO;
        clearJITStart();
        return NO;
    }
    clearJITStart();
    g_startError = nil;
    updateBatteryGuard();
    return startMiner();
}

static void stopMiner(void)
{
    if (g_minerRunning.load()) {
        raise(SIGINT);
    }
}


@interface XMRAndAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NSTimer *batteryTimer;
@end


@implementation XMRAndAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if ([launchURL.scheme.lowercaseString isEqualToString:[NSBundle.mainBundle objectForInfoDictionaryKey:@"XMRAndCallbackScheme"] ?: @"xmrand"] && [launchURL.host isEqualToString:@"jit-fallback"] && pendingJITStart()) {
        g_forceInterpreterFallback.store(true);
        g_onDeviceJITRequested.store(false);
    }

    appendEarlyDiagnostic("XMRAnd didFinishLaunching");
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(batteryDidChange:) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [notifications addObserver:self selector:@selector(batteryDidChange:) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    self.batteryTimer = [NSTimer timerWithTimeInterval:30.0 target:self selector:@selector(batteryDidChange:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.batteryTimer forMode:NSRunLoopCommonModes];
    updateBatteryGuard();

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    MinerSettingsViewController *viewController = [MinerSettingsViewController new];
    viewController.profilePath = profilePath();
    viewController.minerLogPath = logPath();
    viewController.onStart = ^{
        if (g_minerRunning.load() || g_onDeviceJITRequested.load()) return;
        g_startError = nil;
        g_userRunRequested = YES;
        g_forceInterpreterFallback.store(false);
        [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 + 120 forKey:@"jitStartDeadline"];
        if (!requestOnDeviceJIT()) startAutomaticMiner();
    };
    viewController.onStop = ^{
        g_userRunRequested = NO;
        g_batteryDeferredStart.store(false);
        g_onDeviceJITRequested.store(false);
        clearJITStart();
        stopMiner();
        UIApplication.sharedApplication.idleTimerDisabled = NO;
    };
    viewController.isRunning = ^BOOL { return g_minerRunning.load() || g_onDeviceJITRequested.load(); };
    viewController.miningStatus = ^NSString *{
        if (g_startError.length) return g_startError;
        if (g_onDeviceJITRequested.load()) return @"Requesting JIT via StikDebug. See Setup if it does not return.";
        if (g_userRunRequested) {
            if (g_thermalPaused) return @"Paused while iOS reports serious heat.";
            if (g_chargerPaused) return @"Paused. Connect a charger, then keep XMRAnd foregrounded.";
            if (g_batteryGuardPaused.load()) return [NSString stringWithFormat:@"Paused at %d%% battery. Resume threshold: %ld%%.",g_batteryPercent.load(),(long)resumePercent()];
            if (g_batteryDeferredStart.load()) return @"Waiting for a battery reading and foreground access.";
        }
        if (g_minerRunning.load()) return xmrig::VirtualMemory::isJITAvailable() ? @"Mining with JIT. Keep this app foregrounded." : @"Mining in slow interpreter mode. Open Setup to enable JIT.";
        return @"Stopped. Saved settings apply on the next Start.";
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:viewController];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    appendMinerDiagnostic(@"XMRAnd didFinishLaunching");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDictionary *profile = loadUserProfile();
        BOOL pending = pendingJITStart();
        if (!g_minerRunning.load() && !g_onDeviceJITRequested.load() && profile
            && (pending || [profile[@"xmrand"][@"autostart"] boolValue])) {
            g_userRunRequested = YES;
            if (pending && !xmrig::VirtualMemory::isJITAvailable()) g_forceInterpreterFallback.store(true);
            if (!pending) [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 + 120 forKey:@"jitStartDeadline"];
            NSError *error = nil;
            if (!XMRValidateProfile(profile,YES,&error)) { g_startError = error.localizedDescription; g_userRunRequested = NO; clearJITStart(); return; }
            if (!requestOnDeviceJIT()) startAutomaticMiner();
        }
    });
    return YES;
}

- (void)batteryDidChange:(id)sender
{
    updateBatteryGuard();
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    g_backgroundPaused = YES;
    if (g_minerRunning.load()) xmrig::App::setMiningEnabled(false);
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    if (g_onDeviceJITRequested.load()) {
        g_handoffBackgrounded.store(true);
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    g_backgroundPaused = NO;
    updateBatteryGuard();

    if (!g_onDeviceJITRequested.load() || !g_handoffBackgrounded.exchange(false)) {
        return;
    }

    g_onDeviceJITRequested.store(false);
    g_forceInterpreterFallback.store(true);
    appendMinerDiagnostic(@"XMRAnd JIT helper returned without relaunch; using interpreter fallback");
    startAutomaticMiner();
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
    NSString *scheme = [NSBundle.mainBundle objectForInfoDictionaryKey:@"XMRAndCallbackScheme"] ?: @"xmrand";
    if (![url.scheme.lowercaseString isEqualToString:scheme] || ![url.host isEqualToString:@"jit-fallback"] || (!g_userRunRequested && !pendingJITStart())) {
        return NO;
    }

    g_onDeviceJITRequested.store(false);
    g_handoffBackgrounded.store(false);
    g_forceInterpreterFallback.store(true);
    appendMinerDiagnostic(@"XMRAnd received JIT fallback callback");
    g_userRunRequested = YES;
    startAutomaticMiner();
    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [self.batteryTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    UIDevice.currentDevice.batteryMonitoringEnabled = NO;
    stopMiner();
}

@end


int main(int argc, char *argv[])
{
    installTerminateLogger();

    @autoreleasepool {
        appendEarlyDiagnostic("XMRAnd main entry");

        if (hasArgument(argc, argv, "--xmrand-cli")) {
            appendEarlyDiagnostic("XMRAnd main cli");
            g_logPathOverride = argumentValue(argc, argv, "--xmrand-log");

            NSString *config = argumentValue(argc, argv, "--xmrand-config");
            if (config.length == 0) {
                NSError *error = nil;
                if (!prepareMinerConfig(&error)) {
                    appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd CLI config error: %@", error.localizedDescription]);
                    return 2;
                }
                config = configPath();
            }

            int rc = -1;
            try {
                rc = runXmrigAtPath(config);
            }
            catch (const std::exception &ex) {
                appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd CLI exception: %s", ex.what()]);
                return 3;
            }
            catch (...) {
                appendMinerDiagnostic(@"XMRAnd CLI exception: unknown");
                return 3;
            }

            appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd CLI exited rc=%d", rc]);
            return rc;
        }

#if defined(XMRIG_IOS_JIT)
        if (hasArgument(argc, argv, "--xmrand-headless") && XMRValidateProfile(loadUserProfile(), YES, nil)) {
            appendEarlyDiagnostic("XMRAnd main headless seed=yes");
            NSError *error = nil;
            if (!prepareMinerConfig(&error)) {
                appendEarlyDiagnostic("XMRAnd main headless config error");
                appendEarlyDiagnosticNSString(error.localizedDescription ?: @"XMRAnd headless config error without description");
                appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd headless config error: %@", error.localizedDescription]);
                return 2;
            }

            [[NSFileManager defaultManager] removeItemAtPath:logPath() error:nil];
            appendMinerDiagnostic(@"XMRAnd headless JIT launch");

            int rc = -1;
            try {
                rc = runXmrigAtPath(configPath());
            }
            catch (const std::exception &ex) {
                appendEarlyDiagnostic("XMRAnd main headless exception");
                appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd headless exception: %s", ex.what()]);
                return 3;
            }
            catch (...) {
                appendEarlyDiagnostic("XMRAnd main headless unknown exception");
                appendMinerDiagnostic(@"XMRAnd headless exception: unknown");
                return 3;
            }

            appendEarlyDiagnostic("XMRAnd main headless exit");
            appendMinerDiagnostic([NSString stringWithFormat:@"XMRAnd headless exited rc=%d", rc]);
            return rc;
        }
        appendEarlyDiagnostic("XMRAnd main headless seed=no");
#endif

        appendEarlyDiagnostic("XMRAnd main UIApplicationMain");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(XMRAndAppDelegate.class));
    }
}
