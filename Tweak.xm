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

 } @catch (NSException *e) {}
    if (!gBBServer && destinations != 0) {
        gBBServer = (id)self;
        gDestMask = destinations;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        gBBQueue = dispatch_get_current_queue();
        gDestObj = [NSNumber numberWithUnsignedLongLong:destinations];
#pragma clang diagnostic pop
        PLog(@"BBServer captured, mask=0x%llx queue=%@", destinations, gBBQueue);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20*NSEC_PER_SEC)), gBBQueue, ^{
            runOwnBulletinTest();
        });
    }
    %orig;
}
%end

static void runOwnBulletinTest(void) {
    if (!gBBServer) { PLog(@"no BBServer captured"); return; }
    @try {
        id b = [[objc_getClass("BBBulletin") alloc] init];
        setKVC(b, @"sectionID", @"com.tencent.xin");
        setKVC(b, @"title", @"WXPROBE-BB 点击测试");
        setKVC(b, @"subtitle", @"BBBulletin 路线");
        setKVC(b, @"message", @"点我验证跳转微信");
        setKVC(b, @"showsMessagePreview", @YES);
        NSDate *now = [NSDate date];
        setKVC(b, @"publicationDate", now);
        setKVC(b, @"date", now);
        setKVC(b, @"lastInterruptDate", now);
        setKVC(b, @"recordID", [[NSUUID UUID] UUIDString]);
        setKVC(b, @"publisherBulletinID", [[NSUUID UUID] UUIDString]);
        setKVC(b, @"bulletinID", [[NSUUID UUID] UUIDString]);
        if (gSound) setKVC(b, @"sound", gSound);
        Class actCls = objc_getClass("BBAction");
        id action = nil;
        if ([actCls respondsToSelector:@selector(actionWithLaunchBundleID:callblock:)])
            action = [actCls performSelector:@selector(actionWithLaunchBundleID:callblock:) withObject:@"com.tencent.xin" withObject:nil];
        PLog(@"BBAction created: %@", action);
        if (action) setKVC(b, @"defaultAction", action);
        PLog(@"own bulletin: %@", [b performSelector:@selector(description)]);
        SEL sel = @selector(publishBulletinRequest:destinations:);
        IMP imp = [gBBServer methodForSelector:sel];
        void (*fn)(id, SEL, id, unsigned long long) = (void (*)(id, SEL, id, unsigned long long))imp;
        fn(gBBServer, sel, b, gDestMask);
        PLog(@"#### own bulletin posted with mask 0x%llx", gDestMask);
        // lock-screen variant: 3-arg alwaysToLockScreen if exists
        SEL sel2 = @selector(publishBulletin:destinations:alwaysToLockScreen:);
        if ([gBBServer respondsToSelector:sel2]) {
            setKVC(b, @"recordID", [[NSUUID UUID] UUIDString]);
            setKVC(b, @"publisherBulletinID", [[NSUUID UUID] UUIDString]);
            setKVC(b, @"bulletinID", [[NSUUID UUID] UUIDString]);
            IMP imp2 = [gBBServer methodForSelector:sel2];
            void (*fn2)(id, SEL, id, id, BOOL) = (void (*)(id, SEL, id, id, BOOL))imp2;
            fn2(gBBServer, sel2, b, gDestObj, YES);
            PLog(@"#### lockscreen variant posted");
        } else {
            PLog(@"#### 3-arg alwaysToLockScreen NOT available");
        }
    } @catch (NSException *e) { PLog(@"#### own bulletin EX: %@", e); }
}

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 0.9.0 loaded, pid=%d", getpid());
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
