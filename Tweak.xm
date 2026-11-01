// DIAGNOSTIC ONLY: not an installed or validated ringing notification service.
// Never log TUCall descriptions, userInfo, handles, telephone numbers or keys.
%config(generator=internal);
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

@interface TUCall : NSObject
- (int)status;
- (int)callStatus;
- (BOOL)isIncoming;
@end

static dispatch_queue_t IFProbeQueue;
static bool IFProbeEnabled;
static Method IFCallMethod, IFProxyMethod;
static IMP IFCallOriginal, IFProxyOriginal, IFCallInstalled, IFProxyInstalled;
static const CFStringRef IFDisableName = CFSTR("local.iphoneforward.ringingprobe.disable");
static const char *IFLog = "/var/mobile/Library/iPhoneForward/ringing-probe.jsonl";
static const off_t IFMaxLogBytes = 1024 * 1024;

static void IFWrite(NSDictionary *record) {
    if (!IFProbeQueue) return;
    dispatch_async(IFProbeQueue, ^{
        @autoreleasepool {
            // The existing private directory must be prepared before injection.
            // Open without following symlinks and refuse non-private files.
            struct stat directoryInfo;
            if (lstat("/var/mobile/Library/iPhoneForward", &directoryInfo) != 0 ||
                !S_ISDIR(directoryInfo.st_mode) || directoryInfo.st_uid != geteuid() ||
                (directoryInfo.st_mode & 0077) != 0) return;
            int fd = open(IFLog, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600);
            if (fd < 0) return;
            struct stat info;
            if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) ||
                info.st_uid != geteuid() || (info.st_mode & 0077) != 0 ||
                info.st_size >= IFMaxLogBytes) { close(fd); return; }
            NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
            if (json && json.length < 2048) {
                NSMutableData *line = [json mutableCopy];
                [line appendBytes:"\n" length:1];
                const char *bytes = (const char *)line.bytes;
                size_t left = line.length;
                while (left) {
                    ssize_t result = write(fd, bytes, left);
                    if (result < 0 && errno == EINTR) continue;
                    if (result <= 0) break;
                    bytes += result;
                    left -= (size_t)result;
                }
            }
            close(fd);
        }
    });
}

static void IFObserve(TUCall *call, NSString *hook) {
    // Capture immediately at callback time, before dispatching file I/O.
    // No status number is assumed to mean ringing until a real call verifies it.
    if (!__atomic_load_n(&IFProbeEnabled, __ATOMIC_ACQUIRE)) return;
    @try {
        if (!call || ![call respondsToSelector:@selector(status)] ||
            ![call respondsToSelector:@selector(callStatus)] ||
            ![call respondsToSelector:@selector(isIncoming)]) return;
        IFWrite(@{
            @"event": @"call_state_callback",
            @"hook": hook,
            @"observed_unix_time": @([[NSDate date] timeIntervalSince1970]),
            @"observed_uptime": @([[NSProcessInfo processInfo] systemUptime]),
            @"status": @([call status]),
            @"call_status": @([call callStatus]),
            @"incoming": @([call isIncoming]),
            @"process_id": @(getpid())
        });
    } @catch (__unused NSException *exception) {
        // Exception descriptions and object descriptions may disclose callers.
    }
}

static void IFDisable(CFNotificationCenterRef center, void *observer, CFStringRef name,
                      const void *object, CFDictionaryRef userInfo) {
    __atomic_store_n(&IFProbeEnabled, false, __ATOMIC_RELEASE);
    BOOL callRestored = NO, proxyRestored = NO;
    if (IFCallMethod && IFCallOriginal && method_getImplementation(IFCallMethod) == IFCallInstalled) {
        method_setImplementation(IFCallMethod, IFCallOriginal);
        callRestored = YES;
    }
    if (IFProxyMethod && IFProxyOriginal && method_getImplementation(IFProxyMethod) == IFProxyInstalled) {
        method_setImplementation(IFProxyMethod, IFProxyOriginal);
        proxyRestored = YES;
    }
    CFNotificationCenterRemoveObserver(center, observer, IFDisableName, NULL);
    IFWrite(@{@"event": @"diagnostic_hooks_disabled", @"call_restored": @(callRestored),
              @"proxy_restored": @(proxyRestored), @"process_id": @(getpid())});
}

%group CallStateHook
%hook TUCall
- (void)_handleStatusChange {
    __attribute__((objc_precise_lifetime)) TUCall *retainedCall = self;
    %orig;
    IFObserve(retainedCall, @"TUCall._handleStatusChange");
}
%end
%end

%group ProxyStateHook
%hook TUProxyCall
- (void)setCallStatus:(int)status {
    __attribute__((objc_precise_lifetime)) TUCall *retainedCall = (TUCall *)self;
    %orig;
    IFObserve(retainedCall, @"TUProxyCall.setCallStatus");
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        IFProbeQueue = dispatch_queue_create("local.iphoneforward.ringingprobe", DISPATCH_QUEUE_SERIAL);
        Class callClass = NSClassFromString(@"TUCall");
        Class proxyClass = NSClassFromString(@"TUProxyCall");
        IFCallMethod = callClass ? class_getInstanceMethod(callClass, NSSelectorFromString(@"_handleStatusChange")) : NULL;
        IFProxyMethod = proxyClass ? class_getInstanceMethod(proxyClass, NSSelectorFromString(@"setCallStatus:")) : NULL;
        BOOL callValid = IFCallMethod && strcmp(method_getTypeEncoding(IFCallMethod), "v16@0:8") == 0;
        BOOL proxyValid = IFProxyMethod && strcmp(method_getTypeEncoding(IFProxyMethod), "v20@0:8i16") == 0;
        if (callValid) {
            IFCallOriginal = method_getImplementation(IFCallMethod);
            %init(CallStateHook);
            IFCallInstalled = method_getImplementation(IFCallMethod);
        }
        if (proxyValid) {
            IFProxyOriginal = method_getImplementation(IFProxyMethod);
            %init(ProxyStateHook);
            IFProxyInstalled = method_getImplementation(IFProxyMethod);
        }
        __atomic_store_n(&IFProbeEnabled, true, __ATOMIC_RELEASE);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &IFProbeEnabled,
            IFDisable, IFDisableName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        IFWrite(@{@"event": @"diagnostic_hooks_loaded",
                  @"call_hook": @(callValid), @"proxy_hook": @(proxyValid),
                  @"process_id": @(getpid())});
    }
}

// An isolated CLI test can exercise compiled Objective-C, ARC and blocks without
// installing hooks or writing logs. This function never touches real call APIs.
static int IFTestOriginal(id object, SEL selector) { return 7; }
static int IFTestReplacement(id object, SEL selector) { return 9; }

extern "C" unsigned int IFProbeSelfTest(void) {
    @autoreleasepool {
        __block unsigned int result = 0;
        dispatch_queue_t queue = dispatch_queue_create("local.iphoneforward.ringingprobe.selftest", DISPATCH_QUEUE_SERIAL);
        dispatch_sync(queue, ^{
            NSDictionary *record = @{@"status": @4, @"incoming": @YES, @"fixture": @"synthetic"};
            NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
            NSDictionary *decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if ([decoded[@"status"] intValue] == 4 && [decoded[@"incoming"] boolValue] &&
                [decoded[@"fixture"] isEqualToString:@"synthetic"]) result = 1;
        });
        Class fixture = objc_allocateClassPair([NSObject class], "IFRingingProbeSelfTestObject", 0);
        if (!fixture) return 0;
        SEL selector = sel_registerName("if_probe_testValue");
        if (!class_addMethod(fixture, selector, (IMP)IFTestOriginal, "i@:")) return 0;
        objc_registerClassPair(fixture);
        id object = [[fixture alloc] init];
        Method method = class_getInstanceMethod(fixture, selector);
        IMP original = method_setImplementation(method, (IMP)IFTestReplacement);
        int (*send)(id, SEL) = (int (*)(id, SEL))objc_msgSend;
        BOOL hooked = send(object, selector) == 9;
        method_setImplementation(method, original);
        BOOL restored = send(object, selector) == 7;
        object = nil;
        objc_disposeClassPair(fixture);
        return result && hooked && restored ? 1 : 0;
    }
}
