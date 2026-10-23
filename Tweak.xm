// WXRelayProbe 1.4.0 - WeChat-process: find UNUserNotificationCenter delegate, hook its willPresent
#import <fcntl.h>
#import <unistd.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
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

static IMP gOrigWillPresent = NULL;
static Class gDelegateClass = nil;

static void wxHookedWillPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions));

static void WXDUMPDelegate(void) {
    @try {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        id delegate = [center delegate];
        PLog(@"UNUserNotificationCenter center=%@ delegate=%@ class=%@", center, delegate, NSStringFromClass([delegate class]));
        if (![delegate isKindOfClass:[NSObject class]] || !delegate) return;
        gDelegateClass = [delegate class];
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(gDelegateClass, &mc);
        NSMutableString *names = [NSMutableString string];
        for (unsigned int i = 0; i < mc; i++) [names appendFormat:@"%@; ", NSStringFromSelector(method_getName(ms[i]))];
        PLog(@"delegate methods(%u): %@", mc, names);
        free(ms);
        // hook willPresentNotification:withCompletionHandler:
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(gDelegateClass, sel);
        if (m) {
            gOrigWillPresent = method_getImplementation(m);
            method_setImplementation(m, (IMP)wxHookedWillPresent);
            PLog(@"delegate willPresent HOOKED on %@", NSStringFromClass(gDelegateClass));
        } else {
            PLog(@"delegate does NOT implement willPresent (system default = silent!)");
        }
    } @catch (NSException *e) {
        PLog(@"dump EXC: %@", e);
    }
}

static void wxHookedWillPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    PLog(@">>> APP-side willPresent fired! request=%@ title=%@ body=%@",
         notification.request.identifier,
         notification.request.content.title,
         notification.request.content.body);
    if (gOrigWillPresent) ((void(*)(id,SEL,id,id,id))gOrigWillPresent)(self, _cmd, center, notification, completionHandler);
    else if (completionHandler) completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
    PLog(@">>> APP-side willPresent done (orig called=%d)", gOrigWillPresent != NULL);
}

__attribute__((constructor)) static void wxprobeCtor(void) {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 1.4.0 loaded (WeChat process), pid=%d", getpid());
        // scene/session ready delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WXDUMPDelegate();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gOrigWillPresent) { PLog(@"retry dump (delegate was nil)"); WXDUMPDelegate(); }
        });
    }
}
