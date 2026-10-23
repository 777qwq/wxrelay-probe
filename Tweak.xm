// WXRelayProbe 0.1.0 - SpringBoard notification probe
// Goals:
//  1. Dump the real NCNotificationRequest object that flows into
//     SBNotificationBannerDestination postNotificationRequest:
//  2. Re-post the captured request after 20s  -> validates programmatic posting
//  3. Clone the request (copy / KVC title swap) after 40s -> validates banner cloning
// Log file: /var/mobile/Library/Logs/WXRelayProbe.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *kLogPath = @"/var/mobile/Library/Logs/WXRelayProbe.log";
static id gCapturedRequest = nil;
static id gCapturedDest = nil;
static BOOL gDumpedMethods = NO;

static void PLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                 dateStyle:NSDateFormatterNoStyle
                                                 timeStyle:NSDateFormatterMediumStyle];
    FILE *f = fopen([kLogPath fileSystemRepresentation], "a");
    if (f) {
        fprintf(f, "[%s] %s\n", ts.UTF8String, line.UTF8String);
        fclose(f);
    }
}

static void dumpRequest(id req) {
    if (!req) { PLog(@"request is nil"); return; }
    Class c = [req class];
    PLog(@"--- request class=%@ super=%@", NSStringFromClass(c), NSStringFromClass([c superclass]));

    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList([c class], &pc);
    PLog(@"property count=%u", pc);
    for (unsigned int i = 0; i < pc; i++) {
        const char *name = property_getName(props[i]);
        NSString *nsName = @(name);
        @try {
            id val = [req valueForKey:nsName];
            PLog(@"  %@ = %@", nsName, val);
        } @catch (NSException *e) {
            PLog(@"  %@ = <KVC err: %@>", nsName, e.reason);
        }
    }
    free(props);

    // description for full picture
    PLog(@"description: %@", [req performSelector:@selector(description)]);
}

static void dumpDestinationMethods(id dest) {
    if (gDumpedMethods || !dest) return;
    gDumpedMethods = YES;
    Class c = object_getClass(dest);
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(c, &mc);
    PLog(@"--- %@ method dump (%u):", NSStringFromClass(c), mc);
    NSMutableString *buf = [NSMutableString string];
    for (unsigned int i = 0; i < mc; i++) {
        [buf appendFormat:@"%@; ", NSStringFromSelector(method_getName(methods[i]))];
        if (buf.length > 3000) { PLog(@"%@", buf); [buf setString:@""]; }
    }
    PLog(@"%@", buf);
    free(methods);
}

static void runRepostTest(void) {
    PLog(@"### repost test begin (dest=%@, req=%@)", gCapturedDest, gCapturedRequest);
    if (!gCapturedDest || !gCapturedRequest) { PLog(@"missing capture, abort"); return; }
    @try {
        // re-post the very same request object
        [(id)gCapturedDest performSelector:@selector(postNotificationRequest:) withObject:gCapturedRequest];
        PLog(@"### repost test: postNotificationRequest: called OK");
    } @catch (NSException *e) {
        PLog(@"### repost test EXCEPTION: %@", e);
    }
}

static void runCloneTest(void) {
    PLog(@"### clone test begin");
    if (!gCapturedDest || !gCapturedRequest) { PLog(@"missing capture, abort"); return; }
    @try {
        id clone = nil;
        if ([gCapturedRequest respondsToSelector:@selector(copy)]) {
            clone = [gCapturedRequest copy];
            PLog(@"clone via copy: %@", clone);
        } else if ([gCapturedRequest respondsToSelector:@selector(mutableCopy)]) {
            clone = [gCapturedRequest mutableCopy];
            PLog(@"clone via mutableCopy: %@", clone);
        }
        if (!clone) {
            PLog(@"no copy protocol, trying NSKeyedArchiver round-trip");
            if ([gCapturedRequest conformsToProtocol:@protocol(NSCoding)]) {
                NSData *d = [NSKeyedArchiver archivedDataWithRootObject:gCapturedRequest requiringSecureCoding:NO error:nil];
                clone = [NSKeyedUnarchiver unarchivedObjectOfClass:[gCapturedRequest class] fromData:d error:nil];
                PLog(@"clone via NSCoding: %@", clone);
            } else {
                PLog(@"request not NSCoding either; clone test skipped");
                return;
            }
        }
        // try swapping readable content
        @try { [clone setValue:@"WXRelayProbe 克隆横幅" forKey:@"title"]; PLog(@"title swapped"); }
        @catch (NSException *e) { PLog(@"title swap err: %@", e.reason); }
        PLog(@"clone final: %@", clone);
        [gCapturedDest performSelector:@selector(postNotificationRequest:) withObject:clone];
        PLog(@"### clone test: posted OK");
    } @catch (NSException *e) {
        PLog(@"### clone test EXCEPTION: %@", e);
    }
}

%hook SBNotificationBannerDestination
-(void)postNotificationRequest:(id)arg1 {
    PLog(@"=== postNotificationRequest: called, req=%@", arg1);
    if (!gCapturedRequest && arg1) {
        gCapturedRequest = arg1;
        gCapturedDest = self;
        PLog(@"captured first request from dest %@", self);
        dumpRequest(arg1);
        dumpDestinationMethods(self);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            runRepostTest();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            runCloneTest();
        });
    }
    %orig;
}
%end

%hook SBNCNotificationDispatcher
-(id)bannerDestination {
    id r = %orig;
    static BOOL once = NO;
    if (!once) {
        once = YES;
        PLog(@"SBNCNotificationDispatcher.bannerDestination = %@", r);
    }
    return r;
}
%end

%ctor {
    @autoreleasepool {
        PLog(@"========== WXRelayProbe 0.1.0 loaded, pid=%d", getpid());
        // list a few interesting classes exist
        const char *cls[] = {"UNSUserNotificationServer", "SBBannerAuthority", "SBBannerManager",
                             "SBUserNotificationCenter", "SBNCNotificationDispatcher",
                             "SBNotificationBannerDestination", "NCNotificationRequest"};
        for (unsigned long i = 0; i < sizeof(cls)/sizeof(cls[0]); i++) {
            PLog(@"class %@ -> %@", @(cls[i]), objc_getClass(cls[i]) ? @"EXISTS" : @"MISSING");
        }
    }
}
