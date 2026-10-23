// WXRelayProbe 2.1.0 - WeChat process holds its own BKSProcessAssertion
// (self-assertion: the standard in-app keep-alive technique, SB cannot veto)
#import <fcntl.h>
#import <unistd.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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

static void WXSelfAssertion(void) {
    if (gAssertion) return;
    @try {
        Class bks = objc_getClass("BKSProcessAssertion");
        if (!bks) { PLog(@"BKS MISSING"); return; }
        int pid = getpid();
        // 自报家门变体：initWithBundleIdentifier:flags:reason:name:
        SEL sel = @selector(initWithBundleIdentifier:flags:reason:name:);
        IMP imp = [bks instanceMethodForSelector:sel];
        id (*fn)(id, SEL, NSString *, unsigned long long, unsigned long long, NSString *) = (id (*)(id, SEL, NSString *, unsigned long long, unsigned long long, NSString *))imp;
        id alloc = [bks alloc];
        id assertion = fn(alloc, sel, @"com.tencent.xin", 1ULL, 0ULL, @"WXRelayKeepAlive");
        PLog(@"attempt self flags=0x1 -> assertion=%@", assertion);
        if (assertion) {
            if ([assertion respondsToSelector:@selector(acquire)]) {
                [(id)assertion performSelector:@selector(acquire)];
                PLog(@"acquire called");
            }
            gAssertion = assertion;
            PLog(@"#### SELF-ASSERTION HELD — 锁屏验存活");
        }
    } @catch (NSException *e) {
        PLog(@"self assertion EXC: %@", e);
    }
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)arg1 {
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 2.1.0 loaded (WeChat self-assertion), pid=%d", getpid());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WXSelfAssertion();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gAssertion) { PLog(@"retry self-assertion"); WXSelfAssertion(); }
        });
    }
}
