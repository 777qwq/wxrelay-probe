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
    if ([sec isEqualToString:@"com.apple.MobileSMS"] && n <= 2) {
        @try {
            setKVC(arg1, @"sectionIdentifier", @"com.tencent.xin");
            setKVC(arg1, @"notificationIdentifier", [[NSUUID UUID] UUIDString]);
            id content = [arg1 valueForKey:@"content"];
            setKVC(content, @"title", [NSString stringWithFormat:@"WXPROBE-%d 点击测试", n]);
            setKVC(content, @"message", [NSString stringWithFormat:@"策略%d：点击我验证跳转", n]);
            id oldAction = [arg1 valueForKey:@"defaultAction"];
            setKVC(oldAction, @"launchURL", @"weixin://");
            PLog(@"mutate#%d in-flight: oldAction.launchURL=weixin:// (mutated ORIGINAL action)", n);
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

%hook SBNotificationBannerDestination
-(void)modifyNotificationRequest:(id)arg1 {
    PLog(@"### modifyNotificationRequest (coalesce path): %@", [arg1 performSelector:@selector(description)]);
    @try {
        id content = [arg1 valueForKey:@"content"];
        setKVC(content, @"title", @"WXPROBE-MOD 点击测试");
        setKVC(content, @"message", @"modify路径：点击我验证跳转");
        id oldAction = [arg1 valueForKey:@"defaultAction"];
        setKVC(oldAction, @"launchURL", @"weixin://");
        setKVC(arg1, @"notificationIdentifier", [[NSUUID UUID] UUIDString]);
        PLog(@"### modify path mutated in-flight");
    } @catch (NSException *e) { PLog(@"### modify EX: %@", e); }
    %orig;
}
%end

%hook SBNotificationBannerDestination
-(void)notificationRequestPresenter:(id)arg1 executeAction:(id)arg2 withParameters:(id)arg3 completion:(id)arg4 {
    PLog(@">>> DEST click: presenter=%@ action=%@ params=%@", arg1, arg2, arg3);
    @try {
        PLog(@">>> DEST action.launchURL=%@ launchBundleID=%@", [arg2 valueForKey:@"launchURL"], [arg2 valueForKey:@"launchBundleID"]);
    } @catch (NSException *e) { PLog(@">>> DEST dump EX: %@", e); }
    %orig;
}
%end

%hook SBUserNotificationCenter
+(void)dispatchUserNotification:(id)arg1 flags:(int)arg2 replyPort:(unsigned)arg3 auditToken:(id)arg4 {
    PLog(@"<<< dispatchUserNotification entry: %@ flags=%d", [arg1 performSelector:@selector(description)], arg2);
    %orig;
}
%end

static id gBBServer = nil;
static id gDestinations = nil;

%hook BBServer
-(void)publishBulletin:(id)bulletin destinations:(id)destinations {
    PLog(@">>> publishBulletin: %@ destinations=%@", [bulletin performSelector:@selector(description)], destinations);
    if (!gBBServer) { gBBServer = (id)self; gDestinations = destinations;
        PLog(@"BBServer captured: %@", (id)self);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            runOwnBulletinTest(NO);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            runOwnBulletinTest(YES);
        });
    }
    %orig;
}
-(void)publishBulletin:(id)bulletin destinations:(id)destinations alwaysToLockScreen:(BOOL)lock {
    PLog(@">>> publishBulletin(locked=%d): %@ destinations=%@", lock, [bulletin performSelector:@selector(description)], destinations);
    %orig;
}
%end

static void runOwnBulletinTest(BOOL lockScreen) {
    if (!gBBServer) { PLog(@"no BBServer captured"); return; }
    @try {
        Class bbCls = objc_getClass("BBBulletin");
        id b = [[bbCls alloc] init];
        setKVC(b, @"sectionID", @"com.tencent.xin");
        setKVC(b, @"title", @"WXPROBE-BB 点击测试");
        setKVC(b, @"subtitle", @"FakeNotify 路线");
        setKVC(b, @"message", lockScreen ? @"锁屏变体：点我跳微信" : @"普通变体：点我跳微信");
        setKVC(b, @"showsMessagePreview", @YES);
        NSDate *now = [NSDate date];
        setKVC(b, @"publicationDate", now);
        setKVC(b, @"date", now);
        setKVC(b, @"lastInterruptDate", now);
        setKVC(b, @"updatedAt", now);
        setKVC(b, @"recordID", [[NSUUID UUID] UUIDString]);
        setKVC(b, @"publisherBulletinID", [[NSUUID UUID] UUIDString]);
        setKVC(b, @"bulletinID", [[NSUUID UUID] UUIDString]);
        Class actCls = objc_getClass("BBAction");
        id action = nil;
        if ([actCls respondsToSelector:@selector(actionWithLaunchBundleID:callblock:)])
            action = [actCls performSelector:@selector(actionWithLaunchBundleID:callblock:) withObject:@"com.tencent.xin" withObject:nil];
        PLog(@"BBAction created: %@", action);
        if (action) setKVC(b, @"defaultAction", action);
        PLog(@"own bulletin built: %@", [b performSelector:@selector(description)]);
        if (lockScreen)
            [(id)gBBServer performSelector:@selector(publishBulletin:destinations:alwaysToLockScreen:) withObject:b withObject:gDestinations withObject:(id)kCFBooleanTrue];
        else
            [(id)gBBServer performSelector:@selector(publishBulletin:destinations:) withObject:b withObject:gDestinations];
        PLog(@"#### own bulletin posted (lockScreen=%d)", lockScreen);
    } @catch (NSException *e) { PLog(@"#### own bulletin EX: %@", e); }
}

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 0.4.0 loaded, pid=%d", getpid());
        const char *cls[] = {"SBDashBoardNotificationDestination", "NCNotificationContent", "NCNotificationAction", "NCBulletinActionRunner"};
        for (unsigned long i = 0; i < sizeof(cls)/sizeof(cls[0]); i++)
            PLog(@"class %@ -> %@", @(cls[i]), objc_getClass(cls[i]) ? @"EXISTS" : @"MISSING");
        Class runner = objc_getClass("NCBulletinActionRunner");
        if (runner) {
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(object_getClass(runner), &mc);
            NSMutableString *names = [NSMutableString string];
            for (unsigned int i = 0; i < mc; i++) [names appendFormat:@"%@; ", NSStringFromSelector(method_getName(ms[i]))];
            PLog(@"Runner class methods(%u): %@", mc, names);
            free(ms);
            ms = class_copyMethodList(runner, &mc);
            names = [NSMutableString string];
            for (unsigned int i = 0; i < mc; i++) [names appendFormat:@"%@; ", NSStringFromSelector(method_getName(ms[i]))];
            PLog(@"Runner instance methods(%u): %@", mc, names);
            free(ms);
        }
    }
}
