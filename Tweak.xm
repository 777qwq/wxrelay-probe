// WXRelayProbe 0.2.0 - template mutation experiments
// Phase 1 (v0.1 findings): programmatic repost OK; structure known; copy=fake (same ptr)
// v0.2 agenda (timer-driven after first capture, 20s apart):
//   T+20s  repost original            -> sanity
//   T+40s  mutate content.title/message + repost   -> text swap visible?
//   T+60s  mutate sectionIdentifier + launchURL(weixin://) + repost -> icon/jump change?
//   T+80s  swap notificationIdentifier + repost    -> dedup bypass?
// Also: log ALL dispatchUserNotification entries + dashboard destination routing.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *kLogPath = @"/var/mobile/Library/Logs/WXRelayProbe.log";
static id gDest = nil;     // captured SBNotificationBannerDestination

static void PLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    static NSDateFormatter *df = nil;
    if (!df) { df = [[NSDateFormatter alloc] init]; [df setDateFormat:@"HH:mm:ss"]; }
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) { [[NSFileManager defaultManager] createFileAtPath:kLogPath contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath]; }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

static void setKVC(id obj, NSString *key, id val) {
    @try { [(NSObject *)obj setValue:val forKey:key]; PLog(@"KVC SET %@ OK (val=%@)", key, val); }
    @catch (NSException *e) { PLog(@"KVC SET %@ FAIL: %@", key, e.reason); }
}


%hook SBNotificationBannerDestination
-(void)postNotificationRequest:(id)arg1 {
    PLog(@"=== postNotificationRequest: %@", [arg1 performSelector:@selector(description)]);
    if (!gDest) gDest = self;
    static int gCount = 0;
    int n = ++gCount;
    NSString *sec = nil;
    @try { sec = [arg1 valueForKey:@"sectionIdentifier"]; } @catch (id e) {}
    // only mutate fresh SMS requests (stable template source), alternating strategy
    if ([sec isEqualToString:@"com.apple.MobileSMS"] && n <= 4) {
        @try {
            setKVC(arg1, @"sectionIdentifier", @"com.tencent.xin");
            setKVC(arg1, @"notificationIdentifier", [[NSUUID UUID] UUIDString]);
            id content = [arg1 valueForKey:@"content"];
            setKVC(content, @"title", [NSString stringWithFormat:@"WXPROBE-%d 点击测试", n]);
            setKVC(content, @"message", [NSString stringWithFormat:@"策略%d：点击我验证跳转", n]);
            id oldAction = [arg1 valueForKey:@"defaultAction"];
            id newAction = [[objc_getClass("NCNotificationAction") alloc] init];
            setKVC(newAction, @"identifier", @"com.apple.UNNotificationDefaultActionIdentifier");
            if (n % 2 == 1) {           // odd: URL scheme
                setKVC(newAction, @"launchURL", @"weixin://");
                PLog(@"mutate#%d strategy=launchURL weixin://", n);
            } else {                     // even: bundle id
                setKVC(newAction, @"launchBundleID", @"com.tencent.xin");
                PLog(@"mutate#%d strategy=launchBundleID", n);
            }
            setKVC(newAction, @"activationMode", @1);
            setKVC(newAction, @"shouldDismiss", @YES);
            setKVC(newAction, @"requiresUnlock", @NO);
            id runner = nil;
            @try { runner = [oldAction valueForKey:@"actionRunner"]; } @catch (id e) {}
            if (runner) setKVC(newAction, @"actionRunner", runner);
            setKVC(arg1, @"defaultAction", newAction);
            PLog(@"mutate#%d done, posting in-flight", n);
        } @catch (NSException *e) { PLog(@"mutate#%d EX: %@", n, e); }
    }
    %orig;
}
%end

%hook SBNCNotificationDispatcher
-(void)_updateActiveDestinations {
    %orig;
    PLog(@"_updateActiveDestinations: banner=%@ dashBoard=%@",
         [(id)self valueForKey:@"bannerDestination"], [(id)self valueForKey:@"dashBoardDestination"]);
}
-(id)dashBoardDestination {
    static BOOL once = NO;
    id r = %orig;
    if (!once) { once = YES; PLog(@"dashBoardDestination = %@ class=%@", r, NSStringFromClass([r class])); }
    return r;
}
%end

%hook SBUserNotificationCenter
+(void)dispatchUserNotification:(id)arg1 flags:(int)arg2 replyPort:(unsigned)arg3 auditToken:(id)arg4 {
    PLog(@"<<< dispatchUserNotification entry: %@ flags=%d", [arg1 performSelector:@selector(description)], arg2);
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 0.2.0 loaded, pid=%d", getpid());
        const char *cls[] = {"SBDashBoardNotificationDestination", "NCNotificationContent", "NCNotificationAction"};
        for (unsigned long i = 0; i < sizeof(cls)/sizeof(cls[0]); i++)
            PLog(@"class %@ -> %@", @(cls[i]), objc_getClass(cls[i]) ? @"EXISTS" : @"MISSING");
    }
}
