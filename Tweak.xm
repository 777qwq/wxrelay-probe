// WXRelayProbe 3.3.0 - WeChat-side UNUserNotificationCenter delegate probe
// Hypothesis (probe-confirmed): alive WeChat is treated as "active" by usernoted;
// presentation decision falls to WeChat's own UNUserNotificationCenter delegate,
// whose willPresent returns nothing -> no banner, in-app sound only.
// This probe OBSERVES ONLY: logs delegate class + willPresent invocations.
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
static IMP gOrigWillPresent = NULL;
static SEL gWillPresentSel;

%hook UNUserNotificationCenter
- (void)setDelegate:(id)dlg {
    %orig;
    gDelegateClass = object_getClass(dlg);
    PLog(@"[WC] setDelegate -> %@", NSStringFromClass(gDelegateClass));
    PLog(@"[WC]   responds willPresent: %d",
         [dlg respondsToSelector:@selector(userNotificationCenter:willPresentNotification:withCompletionHandler:)]);
    PLog(@"[WC]   responds didReceive: %d",
         [dlg respondsToSelector:@selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)]);
}
%end

static void SwizzleWillPresent(void) {
    if (!gDelegateClass || gOrigWillPresent) return;
    Method m = class_getInstanceMethod(gDelegateClass, gWillPresentSel);
    if (!m) { PLog(@"[WC] willPresent method not found on %@", NSStringFromClass(gDelegateClass)); return; }
    gOrigWillPresent = method_getImplementation(m);
    IMP blk = imp_implementationWithBlock(^(id self, UNUserNotificationCenter *center,
                                            UNNotification *n,
                                            void (^handler)(UNNotificationPresentationOptions)) {
        UNNotificationContent *c = n.request.content;
        PLog(@"[WC] >>> willPresent FIRED: id=%@ title=%@ body=%@",
             n.request.identifier, c.title ?: @"(nil)", c.body ?: @"(nil)");
        ((void (*)(id, SEL, UNUserNotificationCenter *, UNNotification *,
                  void (^)(UNNotificationPresentationOptions)))gOrigWillPresent)
            (self, gWillPresentSel, center, n, handler);
    });
    method_setImplementation(m, blk);
    PLog(@"[WC] willPresent swizzled on %@", NSStringFromClass(gDelegateClass));
}


// v3.3.0 THE FIX: delegate lacks willPresent -> system default = show nothing.
// Add a willPresent implementation returning banner+list+sound (native path).
static void AddWillPresent(void) {
    if (!gDelegateClass || gOrigWillPresent) return;
    SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    if (class_getInstanceMethod(gDelegateClass, sel)) {
        PLog(@"[FIX] delegate already implements willPresent — swizzling instead");
        SwizzleWillPresent();
        return;
    }
    struct objc_method_description d =
        protocol_getMethodDescription(@protocol(UNUserNotificationCenterDelegate), sel, NO, YES);
    IMP blk = imp_implementationWithBlock(^(id self, UNUserNotificationCenter *center,
                                            UNNotification *n,
                                            void (^handler)(UNNotificationPresentationOptions)) {
        UNNotificationContent *c = n.request.content;
        PLog(@"[FIX] >>> willPresent (added) for id=%@ title=%@ -> banner+list+sound",
             n.request.identifier, c.title ?: @"(nil)");
        handler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList
              | UNNotificationPresentationOptionSound);
    });
    BOOL ok = class_addMethod(gDelegateClass, sel, blk, d.types ?: "v@:@@@@?");
    PLog(@"[FIX] class_addMethod willPresent on %@ -> %d", NSStringFromClass(gDelegateClass), ok);
    if (ok) gOrigWillPresent = (IMP)1; // mark handled
}

%ctor {
    @autoreleasepool {
        // v3.2.1: UIKit filter loads into all UI processes; only act in WeChat
        NSString *pn = [[NSProcessInfo processInfo] processName];
        if (![pn isEqualToString:@"WeChat"]) return;
        PLog(@"========== WXRelayProbe 3.3.0 loaded (WeChat UN delegate FIX: add willPresent), pid=%d", getpid());
        gWillPresentSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        // WeChat may set delegate late; retry swizzle a few times
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ AddWillPresent(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ AddWillPresent(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AddWillPresent();
            id dlg = [[NSClassFromString(@"UNUserNotificationCenter") performSelector:@selector(currentNotificationCenter)] delegate];
            PLog(@"[WC] t+60s delegate=%@ willPresentResponds=%d",
                 dlg ? NSStringFromClass(object_getClass(dlg)) : @"(nil)",
                 dlg ? [dlg respondsToSelector:gWillPresentSel] : -1);
        });
    }
}
