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
    if (gAssertion) return;
    @try {
        // BKSProcessAssertion init signature (iOS 13-16):
        // -initWithPID:flags:reason:error:
        Class bks = objc_getClass("BKSProcessAssertion");
        if (!bks) { PLog(@"BKSProcessAssertion MISSING"); return; }
        id alloc = [bks alloc];
        SEL sel = @selector(initWithPID:flags:reason:error:);
        if (![alloc respondsToSelector:sel]) {
            PLog(@"BKS init selector not responded");
            return;
        }
        // flags: BKSProcessAssertionFlagsPreventTaskSuspend = 1 << 0? use known combo 0x1 | 0x10 (prevent suspend + allow lock screen)
        unsigned long long flags = 0x1 | 0x10;
        // reason: BKSProcessAssertionReasonOther = 0? use 2 (backgroundContentFetching)? pass 0 first
        NSError *error = nil;
        id assertion = nil;
        IMP imp = [alloc methodForSelector:sel];
        id (*fn)(id, SEL, int, unsigned long long, unsigned long long, id *) = (id (*)(id, SEL, int, unsigned long long, unsigned long long, id *))imp;
        assertion = fn(alloc, sel, pid, flags, 0, &error);
        if (assertion) {
            gAssertion = assertion;
            PLog(@"BKSProcessAssertion ACQUIRED for pid=%d flags=0x%llx assertion=%@", pid, flags, assertion);
            @try { PLog(@"assertion state: %@", [assertion valueForKey:@"_assertionState"]); } @catch (NSException *e) { }
        } else {
            PLog(@"BKSProcessAssertion FAILED pid=%d error=%@", pid, error);
        }
    } @catch (NSException *e) {
        PLog(@"assertion EXC: %@", e);
    }
}

static void WXFindWeChatPID(void) {
    @try {
        // RunningBoard: query processes? simpler: hook SBApplication launch path won't help here.
        // Use libsanitizers-free approach: enumerate via RBSRunningAppService? Try FBSOpenApplication...
        // Simplest robust: SBApplicationController sharedInstance -> applications -> process (FBProcess with pid)
        Class appCtrlCls = objc_getClass("SBApplicationController");
        id ctrl = appCtrlCls ? [(id)appCtrlCls performSelector:@selector(sharedInstance)] : nil;
        NSArray *apps = ctrl ? [ctrl valueForKey:@"applications"] : nil;
        for (id app in apps) {
            NSString *bid = [app valueForKey:@"bundleIdentifier"];
            if ([bid isEqualToString:@"com.tencent.xin"]) {
                id process = [app valueForKey:@"process"];
                int pid = 0;
                @try {
                    id identity = [process valueForKey:@"identity"];
                    NSNumber *p = [identity valueForKey:@"pid"];
                    if (p) pid = p.intValue;
                    if (!pid) { NSNumber *p2 = [process valueForKey:@"processIdentifier"]; if (p2) pid = p2.intValue; }
                } @catch (NSException *e) { }
                if (pid > 0) {
                    gWeChatPID = pid;
                    PLog(@"WeChat pid found: %d (process=%@)", pid, process);
                }
                break;
            }
        }
        if (gWeChatPID > 0) WXAcquireAssertionForPID(gWeChatPID);
        else PLog(@"WeChat pid not found (app not running?)");
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
