// WXRelayProbe 1.3.0 - is Immortalizer's UNS hook point alive on iOS 16.3?
// 1. dump UNSUserNotificationServer method list
// 2. hook willPresentNotification:forBundleIdentifier:withCompletionHandler: (log fire + args)
// 3. hook _didChangeApplicationState:forBundleIdentifier: (log calls + values)
// Log: /var/mobile/Library/Logs/WXRelayProbe.log
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

%hook UNSUserNotificationServer
-(void)willPresentNotification:(id)arg1 forBundleIdentifier:(id)arg2 withCompletionHandler:(id)arg3 {
    PLog(@">>> UNS willPresentNotification fired! bundle=%@ notif=%@", arg2, [arg1 performSelector:@selector(description)]);
    %orig;
}
-(void)_didChangeApplicationState:(unsigned long long)arg1 forBundleIdentifier:(id)arg2 {
    PLog(@">>> UNS _didChangeApplicationState called: state=%llu bundle=%@", arg1, arg2);
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 1.3.0 loaded, pid=%d", getpid());
        Class uns = objc_getClass("UNSUserNotificationServer");
        PLog(@"UNSUserNotificationServer -> %@", uns ? @"EXISTS" : @"MISSING");
        if (uns) {
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(uns, &mc);
            NSMutableString *names = [NSMutableString string];
            for (unsigned int i = 0; i < mc; i++) [names appendFormat:@"%@; ", NSStringFromSelector(method_getName(ms[i]))];
            PLog(@"UNS instance methods(%u): %@", mc, names);
            free(ms);
            mc = 0;
            ms = class_copyMethodList(object_getClass(uns), &mc);
            names = [NSMutableString string];
            for (unsigned int i = 0; i < mc; i++) [names appendFormat:@"%@; ", NSStringFromSelector(method_getName(ms[i]))];
            PLog(@"UNS class methods(%u): %@", mc, names);
            free(ms);
        }
    }
}
