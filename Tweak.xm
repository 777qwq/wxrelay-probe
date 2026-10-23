// WXRelayProbe 1.5.0 - lie to UNS: WeChat is ALWAYS background (state=8)
// Hypothesis: with keep-alive keeping WeChat alive, forcing UNS state=8 for com.tencent.xin
// makes usernoted treat pushes as background -> native banner with avatar.
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
-(void)_didChangeApplicationState:(unsigned long long)arg1 forBundleIdentifier:(id)arg2 {
    if ([arg2 isKindOfClass:[NSString class]] && [(NSString *)arg2 isEqualToString:@"com.tencent.xin"]) {
        if (arg1 != 8) {
            PLog(@">>> LIE: WeChat state %llu -> 8", arg1);
            arg1 = 8;
        }
    }
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 1.5.0 loaded (state=8 lie), pid=%d", getpid());
    }
}
