// WXRelayProbe 3.3.1 - THE FIX: WeChat delegate (DNDNotificationsService) lacks
// willPresent -> system default = show nothing. Add willPresent returning
// banner+list+sound via class_addMethod, executed inline in setDelegate (no
// dispatch_after - unreliable during WeChat early boot).
#import <fcntl.h>
#import <unistd.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
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

static Class gDelegateClass = nil;
static BOOL gHandled = NO;

static void AddWillPresent(void) {
    if (!gDelegateClass || gHandled) return;
    SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method existing = class_getInstanceMethod(gDelegateClass, sel);
    if (existing) {
        PLog(@"[FIX] delegate already implements willPresent — NOT adding (needs swizzle path, report back)");
        gHandled = YES;
        return;
    }
    struct objc_method_description d =
        protocol_getMethodDescription(@protocol(UNUserNotificationCenterDelegate), sel, NO, YES);
    IMP blk = imp_implementationWithBlock(^(id self, UNUserNotificationCenter *center,
                                            UNNotification *n,
                                            void (^handler)(UNNotificationPresentationOptions)) {
        UNNotificationContent *c = n.request.content;
        PLog(@"[FIX] >>> willPresent (added) id=%@ title=%@ -> banner+list+sound",
             n.request.identifier, c.title ?: @"(nil)");
        handler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList
              | UNNotificationPresentationOptionSound);
    });
    BOOL ok = class_addMethod(gDelegateClass, sel, blk, d.types ?: "v@:@@@@?");
    PLog(@"[FIX] class_addMethod willPresent on %@ -> %d", NSStringFromClass(gDelegateClass), ok);
    gHandled = ok;
}

%hook UNUserNotificationCenter
- (void)setDelegate:(id)dlg {
    %orig;
    gDelegateClass = object_getClass(dlg);
    AddWillPresent(); // inline: delegate class known here, no timing games
    PLog(@"[WC] setDelegate -> %@", NSStringFromClass(gDelegateClass));
    PLog(@"[WC]   responds willPresent: %d",
         [dlg respondsToSelector:@selector(userNotificationCenter:willPresentNotification:withCompletionHandler:)]);
    PLog(@"[WC]   responds didReceive: %d",
         [dlg respondsToSelector:@selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)]);
}
%end

%ctor {
    @autoreleasepool {
        NSString *pn = [[NSProcessInfo processInfo] processName];
        if (![pn isEqualToString:@"WeChat"]) return;
        %init;
        PLog(@"========== WXRelayProbe 1.0.0 loaded (WXRelayFix - same fix, fresh injection path), pid=%d", getpid());
    }
}
