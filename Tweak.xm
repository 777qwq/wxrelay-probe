// WXRelayProbe 3.0.2 - SB-side notification pipeline probe (iOS 16.3)
// Goal: locate where WeChat notification requests die on the 16.3 SB banner path.
// Layers hooked: SBNCNotificationDispatcher (lockscreen/destinations)
//                SBBannerAuthority (admission gate)
//                SBNotificationBannerDestination (banner endpoint + deny reason + test injection)
#import <fcntl.h>
#import <unistd.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *kLogPath = @"/var/mobile/Library/Logs/WXRelayProbe.log";
static NSString *kLogPath2 = @"/var/jb/usr/share/WXRelayProbe.log";

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
    for (NSString *p in @[kLogPath, kLogPath2]) {
        int fd = open([p fileSystemRepresentation], O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) { write(fd, d.bytes, d.length); close(fd); }
    }
}

// Safe summary of an NCNotificationRequest-ish object
static NSString *ReqSummary(id req) {
    if (!req) return @"(nil)";
    NSMutableString *s = [NSMutableString stringWithFormat:@"<%@:%p", NSStringFromClass([req class]), req];
    for (NSString *k in @[@"uniqueIdentifier", @"bundleIdentifier", @"sectionIdentifier",
                          @"threadIdentifier", @"title", @"subtitle", @"body"]) {
        @try {
            if ([req respondsToSelector:NSSelectorFromString(k)]) {
                id v = [req valueForKeyPath:k];
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 60)
                    v = [(NSString *)v substringToIndex:60];
                [s appendFormat:@" %@=%@", k, v];
            }
        } @catch (NSException *e) {}
    }
    return [s stringByAppendingString:@">"];
}

static id gDest = nil; // captured SBNotificationBannerDestination

%hook SBNotificationBannerDestination
- (id)init {
    id o = %orig;
    if (!gDest) { gDest = o; PLog(@"[DEST] captured instance %p", o); }
    return o;
}
- (BOOL)canReceiveNotificationRequest:(id)req {
    BOOL r = %orig;
    PLog(@"[DEST] canReceive %@ -> %@", ReqSummary(req), r ? @"YES" : @"NO");
    return r;
}
- (void)postNotificationRequest:(id)req {
    PLog(@"[DEST] postNotificationRequest %@", ReqSummary(req));
    %orig;
}
- (void)modifyNotificationRequest:(id)req {
    PLog(@"[DEST] modifyNotificationRequest %@", ReqSummary(req));
    %orig;
}
- (void)withdrawNotificationRequest:(id)req {
    PLog(@"[DEST] withdraw %@", ReqSummary(req));
    %orig;
}
- (void)presentableWillAppearAsBanner:(id)p {
    PLog(@"[DEST] >>> banner WILL appear: %@", p);
    %orig;
}
- (void)presentableDidAppearAsBanner:(id)p {
    PLog(@"[DEST] >>> BANNER SHOWN: %@", p);
    %orig;
}
- (void)presentableWillNotAppearAsBanner:(id)p withReason:(id)r {
    PLog(@"[DEST] !!! banner DENIED: %@ reason=%@", p, r);
    %orig;
}
%end

%hook SBBannerAuthority
- (long long)shouldPostPresentable:(id)p userInfo:(id)ui reason:(id*)reason {
    long long r = %orig;
    id rr = reason ? *reason : nil;
    PLog(@"[AUTH] shouldPost %@ userInfo=%@ -> ret=%lld reason=%@",
         p, ui ? NSStringFromClass([ui class]) : @"(nil)", r, rr);
    return r;
}
- (long long)shouldPresentPresentable:(id)p withPresentedPresentables:(id)others
            responsiblePresentable:(id*)resp {
    long long r = %orig;
    PLog(@"[AUTH] shouldPresent %@ -> ret=%lld", p, r);
    return r;
}
%end

%hook SBNCNotificationDispatcher
- (BOOL)_lockScreenWantsBanners {
    BOOL r = %orig;
    PLog(@"[DISPATCH] _lockScreenWantsBanners -> %@", r ? @"YES" : @"NO");
    return r;
}
- (void)_updateActiveDestinations {
    PLog(@"[DISPATCH] _updateActiveDestinations");
    %orig;
}
%end

static void WXTestBanner(void) {
    if (!gDest) { PLog(@"[TEST] no destination captured yet"); return; }
    Class cls = [gDest class];
    @try {
        SEL mk = @selector(_test_notificationRequestForBannerWithIcon);
        if (![cls respondsToSelector:mk]) { PLog(@"[TEST] _test_notificationRequestForBannerWithIcon MISSING"); return; }
        id req = ((id (*)(id, SEL))objc_msgSend)(cls, mk);
        PLog(@"[TEST] built request: %@", ReqSummary(req));
        SEL post = @selector(_test_postNotificationRequest:completion:);
        if ([gDest respondsToSelector:post]) {
            ((void (*)(id, SEL, id, void (^)(id)))(objc_msgSend))(gDest, post, req, ^(id err) {
                PLog(@"[TEST] _test completion err=%@", err);
            });
            PLog(@"[TEST] _test_postNotificationRequest called — 看屏幕是否出横幅");
        } else {
            PLog(@"[TEST] _test_postNotificationRequest missing, fallback postNotificationRequest:");
            ((void (*)(id, SEL, id))(objc_msgSend))(gDest, @selector(postNotificationRequest:), req);
        }
    } @catch (NSException *e) {
        PLog(@"[TEST] EXC: %@", e);
    }
}

%ctor {
    @autoreleasepool {
        // 3.0.1: no plist filter (ellekit/roothide SB filter unproven) — dylib loads
        // into every process; only act inside SpringBoard.
        NSString *pn = [[NSProcessInfo processInfo] processName];
        if (![pn isEqualToString:@"SpringBoard"]) return;
        %init;
        PLog(@"========== WXRelayProbe 3.0.2 loaded (SB-side pipeline probe, no test injection), pid=%d", getpid());
    }
}
