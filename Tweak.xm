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
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>

@interface TUCall : NSObject
- (int)status;
- (int)callStatus;
- (BOOL)isIncoming;
- (NSString *)uniqueProxyIdentifier;
@end

static dispatch_queue_t IFProbeQueue;
static bool IFProbeEnabled;
static Method IFCallMethod, IFListMethod;
static IMP IFCallOriginal, IFListOriginal, IFCallInstalled, IFListInstalled;
static const CFStringRef IFDisableName = CFSTR("local.iphoneforward.ringingprobe.events.disable");
static const char *IFLog = "/var/mobile/Library/iPhoneForward/ringing-events-probe.jsonl";
static const off_t IFMaxLogBytes = 1024 * 1024;

static NSString *IFHash(NSString *identifier) {
    if (![identifier isKindOfClass:[NSString class]] || !identifier.length) return nil;
    NSData *data = [identifier dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length > 4096) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (unsigned int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        hex[2*i] = "0123456789abcdef"[digest[i] >> 4];
        hex[2*i+1] = "0123456789abcdef"[digest[i] & 15];
    }
    hex[sizeof(hex)-1] = 0;
    return [NSString stringWithUTF8String:hex];
}

// Durable metadata only. The Python consumer stores encrypted Bark envelopes.
// The event ID is a SHA-256 of a random per-call identifier, never a number.
static bool IFPersist(NSDictionary *record, const char *directory) {
    NSString *key = record[@"call_id_hash"];
    if (![key isKindOfClass:[NSString class]] || key.length != 64) return false;
    if ([key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return false;
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) return false;
    struct stat info;
    if (lstat(directory, &info) != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 0077) != 0) return false;
    NSString *base = [NSString stringWithUTF8String:directory];
    NSString *finalPath = [base stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
    NSString *tempPath = [base stringByAppendingPathComponent:[@".event-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
    if (!data || data.length > 2048) return false;
    int fd = open(tempPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    const char *bytes = (const char *)data.bytes;
    size_t left = data.length;
    while (left) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        bytes += n; left -= (size_t)n;
    }
    bool ok = left == 0 && fsync(fd) == 0;
    close(fd);
    if (ok) ok = link(tempPath.fileSystemRepresentation, finalPath.fileSystemRepresentation) == 0 || errno == EEXIST;
    unlink(tempPath.fileSystemRepresentation);
    return ok;
}

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
            if ([record[@"status"] intValue] == 4 && [record[@"call_status"] intValue] == 4 && [record[@"incoming"] boolValue] && [record[@"call_id_hash"] length] == 64) {
                if (IFPersist(record, "/var/mobile/Library/iPhoneForward/ringing-events")) {
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                        CFSTR("local.iphoneforward.ringing.events"), NULL, NULL, true);
                }
            }
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
        NSString *identity = [call respondsToSelector:@selector(uniqueProxyIdentifier)] ? IFHash([call uniqueProxyIdentifier]) : nil;
        IFWrite(@{
            @"call_id_hash": identity ?: @"",
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
    BOOL callRestored = NO, listRestored = NO;
    if (IFCallMethod && IFCallOriginal && method_getImplementation(IFCallMethod) == IFCallInstalled) {
        method_setImplementation(IFCallMethod, IFCallOriginal);
        callRestored = YES;
    }
    if (IFListMethod && IFListOriginal && method_getImplementation(IFListMethod) == IFListInstalled) {
        method_setImplementation(IFListMethod, IFListOriginal);
        listRestored = YES;
    }
    CFNotificationCenterRemoveObserver(center, observer, IFDisableName, NULL);
    IFWrite(@{@"event": @"diagnostic_hooks_disabled", @"call_restored": @(callRestored),
              @"list_restored": @(listRestored), @"process_id": @(getpid())});
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

%group CallListHook
%hook TUCallServicesInterface
- (void)_handleCurrentCallsChanged:(id)calls callsDisconnected:(id)disconnected {
    __attribute__((objc_precise_lifetime)) id retainedCalls = calls;
    %orig;
    if (!__atomic_load_n(&IFProbeEnabled, __ATOMIC_ACQUIRE)) return;
    @try {
        if ([retainedCalls isKindOfClass:[NSArray class]] ||
            [retainedCalls isKindOfClass:[NSSet class]] ||
            [retainedCalls isKindOfClass:[NSOrderedSet class]]) {
            NSUInteger observed = 0;
            for (id call in retainedCalls) {
                if (++observed > 64) break;
                IFObserve((TUCall *)call, @"TUCallServicesInterface.currentCallsChanged");
            }
        }
    } @catch (__unused NSException *exception) { }
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        IFProbeQueue = dispatch_queue_create("local.iphoneforward.ringingprobe", DISPATCH_QUEUE_SERIAL);
        Class callClass = NSClassFromString(@"TUCall");
        Class listClass = NSClassFromString(@"TUCallServicesInterface");
        IFCallMethod = callClass ? class_getInstanceMethod(callClass, NSSelectorFromString(@"_handleStatusChange")) : NULL;
        IFListMethod = listClass ? class_getInstanceMethod(listClass, NSSelectorFromString(@"_handleCurrentCallsChanged:callsDisconnected:")) : NULL;
        BOOL callValid = IFCallMethod && strcmp(method_getTypeEncoding(IFCallMethod), "v16@0:8") == 0;
        BOOL listValid = IFListMethod && strcmp(method_getTypeEncoding(IFListMethod), "Vv32@0:8@16@24") == 0;
        if (callValid) {
            IFCallOriginal = method_getImplementation(IFCallMethod);
            %init(CallStateHook);
            IFCallInstalled = method_getImplementation(IFCallMethod);
        }
        if (listValid) {
            IFListOriginal = method_getImplementation(IFListMethod);
            %init(CallListHook);
            IFListInstalled = method_getImplementation(IFListMethod);
        }
        __atomic_store_n(&IFProbeEnabled, true, __ATOMIC_RELEASE);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &IFProbeEnabled,
            IFDisable, IFDisableName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        IFWrite(@{@"event": @"diagnostic_hooks_loaded",
                  @"call_hook": @(callValid), @"call_list_hook": @(listValid),
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
        char tempDirectory[] = "/tmp/iphone-ring-fixture-XXXXXX";
        char *created = mkdtemp(tempDirectory);
        NSString *hash = IFHash(@"synthetic-random-call-fixture");
        BOOL durable = NO;
        if (created && hash.length == 64) {
            NSDictionary *event = @{@"call_id_hash": hash, @"status": @4, @"incoming": @YES};
            BOOL first = IFPersist(event, created), second = IFPersist(event, created);
            NSString *path = [[NSString stringWithUTF8String:created] stringByAppendingPathComponent:[hash stringByAppendingString:@".json"]];
            NSData *data = [NSData dataWithContentsOfFile:path];
            NSDictionary *decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            durable = first && second && [decoded[@"call_id_hash"] isEqualToString:hash] && [decoded[@"status"] intValue] == 4;
            unlink(path.fileSystemRepresentation); rmdir(created);
        }
        return result && hooked && restored && durable ? 1 : 0;
    }
}
