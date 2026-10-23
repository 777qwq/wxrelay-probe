// WXRelayProbe 1.2.0 - identify app from UIMutableApplicationSceneSettings in deactivation flow
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

static int gDumps = 0;

%hook UIMutableApplicationSceneSettings
-(void)setDeactivationReasons:(unsigned long long)arg1 {
    if (gDumps < 6) {
        gDumps++;
        PLog(@"=== setDeactivationReasons #%d value=%llu ===", gDumps, arg1);
        PLog(@"class=%@", NSStringFromClass([(id)self class]));
        // candidate identity selectors
        NSDictionary *cands = @{@"representedApplicationBundleIdentifier": @"representedApplicationBundleIdentifier",
                                @"applicationBundleIdentifier": @"applicationBundleIdentifier",
                                @"bundleIdentifier": @"bundleIdentifier",
                                @"applicationIdentifier": @"applicationIdentifier",
                                @"sceneID": @"sceneID",
                                @"sceneIdentifier": @"sceneIdentifier"};
        [cands enumerateKeysAndObjectsUsingBlock:^(id k, id sel, BOOL *stop) {
            @try {
                SEL s2 = NSSelectorFromString(sel);
                if ([(id)self respondsToSelector:s2]) {
                    IMP imp = [(id)self methodForSelector:s2];
                    id v = ((id (*)(id, SEL))imp)((id)self, s2);
                    PLog(@"  %@ = %@", k, v);
                }
            } @catch (NSException *e) { }
        }];
        // full property dump (first two only, keep log small)
        if (gDumps <= 2) {
            unsigned int pc = 0;
            objc_property_t *props = class_copyPropertyList([(id)self class], &pc);
            PLog(@"  properties (%u):", pc);
            for (unsigned int i = 0; i < pc; i++) {
                NSString *key = @(property_getName(props[i]));
                @try { PLog(@"    %@ = %@", key, [(id)self valueForKey:key]); }
                @catch (NSException *e) { PLog(@"    %@ = <err>", key); }
            }
            if (props) free(props);
            PLog(@"  description: %@", [(id)self debugDescription]);
        }
    }
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 1.2.0 loaded, pid=%d", getpid());
        PLog(@"UIMutableApplicationSceneSettings -> %@", objc_getClass("UIMutableApplicationSceneSettings") ? @"EXISTS" : @"MISSING");
    }
}
