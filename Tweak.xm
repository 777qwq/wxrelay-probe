// WXRelayProbe 1.6.0 - assertion-based keep-alive experiment (SpringBoard process)
// Goal: hold a BKS/RBS process assertion on WeChat's pid so iOS won't suspend it,
// while WeChat's scene deactivates NORMALLY (real background state).
// Verify: lock screen -> WeChat stays alive (messages arrive without cold-start spin)
//         AND native WeChat localPush banner appears (avatar) because appState=Background.
#import <fcntl.h>
#import <unistd.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
// libproc.h 不在 SDK，手工声明（符号经 libSystem 可解析）
#define PROC_PIDPATHINFO_MAXSIZE 4096
extern "C" int proc_pidpath(int pid, void *buffer, unsigned int buffersize);
#import <objc/message.h>

static NSString *kLogPath = @"/var/mobile/Library/Logs/WXRelayProbe.log";

static void PLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                  dateStyle:NSDateFormatterNoStyle
                                                  timeStyle:NSDateFormatterMediumStyle];
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", ts, line];
    NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open([kLogPath fileSystemRepresentation], O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) { write(fd, d.bytes, d.length); close(fd); }
}

static id gAssertion = nil;
static int gWeChatPID = 0;



static void WXAcquireAssertionForPID(int pid) {
    PLog(@">>> acquiring assertion pid=%d", pid);
    Class bks = objc_getClass("BKSProcessAssertion");
    if (!bks) { PLog(@"BKS MISSING"); return; }
    SEL sel = @selector(initWithPID:flags:reason:name:);
    IMP imp = [bks instanceMethodForSelector:sel];
    unsigned long long flagCandidates[3] = {1, 2, 3};
    for (int i = 0; i < 3; i++) {
        @try {
            id alloc = [bks alloc];
            id (*fn)(id, SEL, int, unsigned long long, unsigned long long, NSString *) = (id (*)(id, SEL, int, unsigned long long, unsigned long long, NSString *))imp;
            id assertion = fn(alloc, sel, pid, flagCandidates[i], 0, @"WXRelay");
            PLog(@"attempt flags=0x%llx -> assertion=%@", flagCandidates[i], assertion);
            if (assertion) {
                if ([assertion respondsToSelector:@selector(acquire)]) {
                    [(id)assertion performSelector:@selector(acquire)];
                    PLog(@"acquire called (flags=0x%llx)", flagCandidates[i]);
                }
                gAssertion = assertion;
                PLog(@"#### ASSERTION HELD (flags=0x%llx) — 锁屏验微信存活", flagCandidates[i]);
                return;
            }
        } @catch (NSException *e) {
            PLog(@"attempt flags=0x%llx EXC: %@", flagCandidates[i], e);
        }
    }
    PLog(@"#### all flag candidates failed");
}


static void WXFindWeChatPID(void) {
    @try {
        NSString *foundPath = nil;
        int foundPid = 0;
        // 1) sysctl 扫描（经典姿势，越狱机稳定）
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        size_t size = 0;
        if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0) {
            struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
            if (procs && sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
                int count = (int)(size / sizeof(struct kinfo_proc));
                char path[PROC_PIDPATHINFO_MAXSIZE];
                for (int i = 0; i < count; i++) {
                    if (procs[i].kp_proc.p_pid <= 0) continue;
                    memset(path, 0, sizeof(path));
                    if (proc_pidpath(procs[i].kp_proc.p_pid, path, sizeof(path)) > 0) {
                        NSString *p = [NSString stringWithUTF8String:path];
                        if ([p containsString:@"WeChat.app/WeChat"] || [p hasSuffix:@"/WeChat"]) {
                            foundPid = procs[i].kp_proc.p_pid;
                            foundPath = p;
                            break;
                        }
                    }
                }
            }
            if (procs) free(procs);
        }
        // 2) SBApplicationController 兜底（Immortalizer 同款方法）
        if (foundPid == 0) {
            Class ctrlCls = objc_getClass("SBApplicationController");
            id ctrl = ctrlCls ? [(id)ctrlCls performSelector:@selector(sharedInstance)] : nil;
            SEL asel = @selector(applicationWithBundleIdentifier:);
            if (ctrl && [(id)ctrlCls instancesRespondToSelector:asel]) {
                id app = ((id (*)(id, SEL, id))objc_msgSend)(ctrl, asel, @"com.tencent.xin");
                id process = app ? [app valueForKey:@"process"] : nil;
                if (process) {
                    for (NSString *k in @[@"processIdentifier", @"pid"]) {
                        @try { id v = [process valueForKey:k]; if ([v respondsToSelector:@selector(intValue)]) { foundPid = [v intValue]; break; } } @catch (NSException *e) { }
                    }
                }
            }
        }
        if (foundPid > 0) {
            gWeChatPID = foundPid;
            PLog(@"WeChat pid found: %d path=%@", foundPid, foundPath ?: @"(sbctrl)");
            WXAcquireAssertionForPID(foundPid);
        } else {
            PLog(@"WeChat pid not found (app not running?)");
        }
    } @catch (NSException *e) {
        PLog(@"findpid EXC: %@", e);
    }
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)arg1 {
    %orig;
    // WeChat must be running: probe acquires assertion 20s after boot,
    // and re-checks every 60s (pid may change if WeChat restarts)
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WXFindWeChatPID();
        });
    });
}
%end

// re-check periodically: if assertion lost or WeChat restarted, re-acquire
%hook SBIconController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSTimer *t = [NSTimer timerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *timer) {
                if (!gAssertion) WXFindWeChatPID();
            }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        });
    });
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 1.6.0 loaded (assertion keep-alive experiment), pid=%d", getpid());
    }
}
