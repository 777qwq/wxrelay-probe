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
static id gReq = nil;      // captured NCNotificationRequest
static id gDest = nil;     // captured SBNotificationBannerDestination
static int gPhase = 0;

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

static void dumpContent(id req) {
    @try {
        id content = [req valueForKey:@"content"];
        PLog(@"content.title=%@ | content.message=%@", [content valueForKey:@"title"], [content valueForKey:@"message"]);
        PLog(@"sectionIdentifier=%@ | notificationIdentifier=%@", [req valueForKey:@"sectionIdentifier"], [req valueForKey:@"notificationIdentifier"]);
    } @catch (NSException *e) { PLog(@"dumpContent err: %@", e); }
}

static void phase1Repost(void) {
    PLog(@"#### PHASE1 repost original begin");
    if (!gReq || !gDest) { PLog(@"no capture"); return; }
    @try { [(id)gDest performSelector:@selector(postNotificationRequest:) withObject:gReq]; PLog(@"PHASE1 posted"); }
    @catch (NSException *e) { PLog(@"PHASE1 EX: %@", e); }
}

static void phase2TextSwap(void) {
    PLog(@"#### PHASE2 text swap begin");
    if (!gReq || !gDest) { PLog(@"no capture"); return; }
    @try {
        id content = [gReq valueForKey:@"content"];
        setKVC(content, @"title", @"WXRELAY-TEST-标题");
        setKVC(content, @"message", @"WXRELAY-TEST-正文：这是一条克隆横幅");
        dumpContent(gReq);
        [(id)gDest performSelector:@selector(postNotificationRequest:) withObject:gReq];
        PLog(@"PHASE2 posted");
    } @catch (NSException *e) { PLog(@"PHASE2 EX: %@", e); }
}

static void phase3SectionSwap(void) {
    PLog(@"#### PHASE3 section/URL swap begin");
    if (!gReq || !gDest) { PLog(@"no capture"); return; }
    @try {
        setKVC(gReq, @"sectionIdentifier", @"com.tencent.xin");
        setKVC(gReq, @"topLevelSectionIdentifier", @"com.tencent.xin");
        id action = [gReq valueForKey:@"defaultAction"];
        if (action) setKVC(action, @"launchURL", @"weixin://");
        dumpContent(gReq);
        [(id)gDest performSelector:@selector(postNotificationRequest:) withObject:gReq];
        PLog(@"PHASE3 posted");
    } @catch (NSException *e) { PLog(@"PHASE3 EX: %@", e); }
}

static void phase4NewId(void) {
    PLog(@"#### PHASE4 new notificationId begin");
    if (!gReq || !gDest) { PLog(@"no capture"); return; }
    @try {
        NSString *nid = [[NSUUID UUID] UUIDString];
        setKVC(gReq, @"notificationIdentifier", nid);
        setKVC(gReq, @"notificationId", nid);
        [(id)gDest performSelector:@selector(postNotificationRequest:) withObject:gReq];
        PLog(@"PHASE4 posted");
    } @catch (NSException *e) { PLog(@"PHASE4 EX: %@", e); }
}

%hook SBNotificationBannerDestination
-(void)postNotificationRequest:(id)arg1 {
    PLog(@"=== postNotificationRequest: %@", [arg1 performSelector:@selector(description)]);
    if (!gReq) {
        gReq = arg1; gDest = self;
        PLog(@"captured first request, scheduling 4 phases (20s apart)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ phase1Repost(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ phase2TextSwap(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ phase3SectionSwap(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ phase4NewId(); });
    }
    %orig;
}
%end

%hook SBNCNotificationDispatcher
-(void)_updateActiveDestinations {
    %orig;
    PLog(@"_updateActiveDestinations: banner=%@ dashBoard=%@",
         [self valueForKey:@"bannerDestination"], [self valueForKey:@"dashBoardDestination"]);
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
