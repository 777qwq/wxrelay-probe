#import <fcntl.h>
#import <unistd.h>
// WXRelayProbe 1.0.0 - dump SBUserNotificationCenter dispatchUserNotification payload
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

static void dumpPayload(id arg1) {
    static int n = 0;
    int c = ++n;
    if (c > 6) return;
    PLog(@"=== dispatch #%d ===", c);
    PLog(@"class=%@ super=%@", NSStringFromClass([arg1 class]), NSStringFromClass([arg1 superclass]));
    PLog(@"description: %@", [arg1 performSelector:@selector(description)]);
    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList([arg1 class], &pc);
    PLog(@"property count=%u", pc);
    for (unsigned int p = 0; p < pc; p++) {
        NSString *key = @(property_getName(props[p]));
        @try { PLog(@"    %@ = %@", key, [arg1 valueForKey:key]); }
        @catch (NSException *e) { PLog(@"    %@ = <KVC err>", key); }
    }
    if (props) free(props);
    PLog(@"--- end dump ===");
}

%hook SBUserNotificationCenter
+(void)dispatchUserNotification:(id)arg1 flags:(int)arg2 replyPort:(unsigned)arg3 auditToken:(id)arg4 {
    dumpPayload(arg1);
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 1.0.0 loaded, pid=%d", getpid());
        PLog(@"SBUserNotificationCenter -> %@", objc_getClass("SBUserNotificationCenter") ? @"EXISTS" : @"MISSING");
    }
}
