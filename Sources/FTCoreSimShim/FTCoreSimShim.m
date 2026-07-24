#import "include/FTCoreSimShim.h"
#import <objc/message.h>
#import <dlfcn.h>

static id ftMsg0(id target, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}

static BOOL ftResponds(id target, const char *sel) {
    return [target respondsToSelector:sel_registerName(sel)];
}

static NSString *ftXcodeSelectPath(void) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"-p"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return @"";
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// deviceSet は初回取得後プロセス生存中保持(live 追従するため)。取得失敗も一度だけ確定
static id ftDeviceSet(void) {
    static id gSet = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/Current/CoreSimulator", RTLD_NOW)) {
            return;
        }
        NSString *devDir = [[NSProcessInfo processInfo] environment][@"DEVELOPER_DIR"];
        if (devDir.length == 0) devDir = ftXcodeSelectPath();
        if (devDir.length == 0) return;
        Class ctxClass = NSClassFromString(@"SimServiceContext");
        if (!ctxClass || !ftResponds((id)ctxClass, "sharedServiceContextForDeveloperDir:error:")) return;
        NSError *err = nil;
        id ctx = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
            ctxClass, sel_registerName("sharedServiceContextForDeveloperDir:error:"), devDir, &err);
        if (!ctx || !ftResponds(ctx, "defaultDeviceSetWithError:")) return;
        NSError *err2 = nil;
        id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(
            ctx, sel_registerName("defaultDeviceSetWithError:"), &err2);
        if (!set || !ftResponds(set, "devicesByUDID")) return;
        gSet = set;
    });
    return gSet;
}

NSArray<NSDictionary<NSString *, id> *> *FTCoreSimListDevices(void) {
    id set = ftDeviceSet();
    if (!set) return nil;
    NSDictionary *byUDID = ftMsg0(set, "devicesByUDID");
    if (![byUDID isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (NSUUID *uuid in byUDID) {
        id device = byUDID[uuid];
        if (!ftResponds(device, "runtime") || !ftResponds(device, "state") ||
            !ftResponds(device, "name") || !ftResponds(device, "available")) {
            return nil;  // セレクタ欠落 = Xcode 版差。列挙ごと諦めて simctl へ
        }
        id runtime = ftMsg0(device, "runtime");
        NSString *runtimeName = (runtime && ftResponds(runtime, "name")) ? ftMsg0(runtime, "name") : nil;
        if (![runtimeName isKindOfClass:[NSString class]] || ![runtimeName hasPrefix:@"iOS"]) continue;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(device, sel_registerName("available"))) continue;
        long state = ((long (*)(id, SEL))objc_msgSend)(device, sel_registerName("state"));
        NSString *name = ftMsg0(device, "name");
        if (![name isKindOfClass:[NSString class]]) continue;
        [result addObject:@{ @"udid": uuid.UUIDString, @"name": name,
                             @"os": runtimeName, @"booted": @(state == 3) }];
    }
    return result;
}
