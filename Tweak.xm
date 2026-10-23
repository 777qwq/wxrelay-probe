// WXRelayProbe 0.9.0 - BBBulletin route, final validation
// Proven (v0.8): own bulletin via BBServer on bbserverqueue -> banner + WeChat icon + tap opens WeChat
// v0.9 adds: sound passthrough + alwaysToLockScreen 3-arg variant probe
// Log: /var/mobile/Library/Logs/WXRelayProbe.log

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
    FILE *fp = fopen([kLogPath fileSystemRepresentation], "a");
    if (fp) { fwrite([out UTF8String], 1, [out lengthOfBytesUsingEncoding:NSUTF8StringEncoding], fp); fclose(fp); }
}

static void setKVC(id obj, NSString *key, id val) {
    @try { [(NSObject *)obj setValue:val forKey:key]; PLog(@"KVC SET %@ OK", key); }
    @catch (NSException *e) { PLog(@"KVC SET %@ FAIL: %@", key, e.reason); }
}

static unsigned long long gDestMask = 0;
static id gBBServer = nil;
static dispatch_queue_t gBBQueue = nil;
static id gSound = nil;
static id gDestObj = nil;
static void runOwnBulletinTest(void);

%hook BBServer
-(void)publishBulletinRequest:(id)bulletin destinations:(unsigned long long)destinations {
    PLog(@">>> publishBulletinRequest: %@ destinations=%llu", [bulletin performSelector:@selector(description)], destinations);
    @try {
        id s = [bulletin valueForKey:@"sound"];
        if (s && !gSound) { gSound = s; PLog(@"sound captured: %@", s); }
    } @catch (NSException *e) {}
    if (!gBBServer && destinations != 0) {
        gBBServer = (id)self;
        gDestMask = destinations;
        gDestObj = [NSNumber numberWithUnsignedLongLong:destinations];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        gBBQueue = dispatch_get_current_queue();
#pragma clang diagnostic pop
        PLog(@"BBServer captured, mask=0x%llx queue=%@", destinations, gBBQueue);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), gBBQueue, ^{
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
        if (gSound) setKVC(b, @"sound", gSound);
        setKVC(b, @"recordID", [[NSUUID UUID] UUIDString]);
        setKVC(b, @"publisherBulletinID", [[NSUUID UUID] UUIDString]);
        setKVC(b, @"bulletinID", [[NSUUID UUID] UUIDString]);
        Class actCls = objc_getClass("BBAction");
        id action = nil;
        if ([actCls respondsToSelector:@selector(actionWithLaunchBundleID:callblock:)])
            action = [actCls performSelector:@selector(actionWithLaunchBundleID:callblock:) withObject:@"com.tencent.xin" withObject:nil];
        if (action) setKVC(b, @"defaultAction", action);

        SEL sel = @selector(publishBulletinRequest:destinations:);
        IMP imp = [gBBServer methodForSelector:sel];
        void (*fn)(id, SEL, id, unsigned long long) = (void (*)(id, SEL, id, unsigned long long))imp;
        fn(gBBServer, sel, b, gDestMask);
        PLog(@"#### own bulletin posted, mask=0x%llx (with sound=%d)", gDestMask, gSound != nil);

        SEL sel2 = @selector(publishBulletin:destinations:alwaysToLockScreen:);
        if ([gBBServer respondsToSelector:sel2]) {
            setKVC(b, @"recordID", [[NSUUID UUID] UUIDString]);
            setKVC(b, @"publisherBulletinID", [[NSUUID UUID] UUIDString]);
            setKVC(b, @"bulletinID", [[NSUUID UUID] UUIDString]);
            IMP imp2 = [gBBServer methodForSelector:sel2];
            void (*fn2)(id, SEL, id, id, BOOL) = (void (*)(id, SEL, id, id, BOOL))imp2;
            fn2(gBBServer, sel2, b, gDestObj, YES);
            PLog(@"#### lockscreen variant posted (3-arg)");
        } else {
            PLog(@"#### 3-arg alwaysToLockScreen NOT available on BBServer");
        }
    } @catch (NSException *e) { PLog(@"#### own bulletin EX: %@", e); }
}

%hook SBUserNotificationCenter
+(void)dispatchUserNotification:(id)arg1 flags:(int)arg2 replyPort:(unsigned)arg3 auditToken:(id)arg4 {
    PLog(@"<<< dispatchUserNotification entry: %@ flags=%d", [arg1 performSelector:@selector(description)], arg2);
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 0.9.0 loaded, pid=%d", getpid());
        const char *cls[] = {"BBServer", "BBBulletin", "BBAction", "NCBulletinActionRunner"};
        for (unsigned long i = 0; i < sizeof(cls)/sizeof(cls[0]); i++)
            PLog(@"class %@ -> %@", @(cls[i]), objc_getClass(cls[i]) ? @"EXISTS" : @"MISSING");
    }
}
