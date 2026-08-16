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

// devicesByUDID は NSUUID キー(FTCoreSimListDevices と同じ)。文字列 udid が不正な UUID なら nil
static id ftDeviceForUDID(NSString *udid) {
    id set = ftDeviceSet();
    if (!set) return nil;
    NSDictionary *byUDID = ftMsg0(set, "devicesByUDID");
    if (![byUDID isKindOfClass:[NSDictionary class]]) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
    if (!uuid) return nil;
    return byUDID[uuid];
}

// launch options 辞書のキーは Xcode 版で値が変わり得る私有 API 定数なので dlsym で引く。
// シンボルが引けない(=フレームワークが未読み込み・版差でリネーム)場合だけリテラルへフォールバックする
// (2026-08-02 時点の実値は Xcode 27 beta 4 で採取: "environment" / "terminate_running_process")
static NSString *ftSimConstant(const char *symbolName, NSString *fallback) {
    // dlopen は呼ぶたび参照カウントが増えるので1回だけ(launch のたびに2回呼ばれる)
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/Current/CoreSimulator", RTLD_NOW);
    });
    if (!handle) return fallback;
    void *raw = dlsym(handle, symbolName);
    if (!raw) return fallback;
    NSString * __unsafe_unretained *symbol = (NSString * __unsafe_unretained *)raw;
    if (!*symbol) return fallback;
    return *symbol;
}

NSDictionary<NSString *, id> *FTCoreSimLaunch(NSString *udid, NSString *bundleID,
                                              NSDictionary<NSString *, NSString *> *environment,
                                              BOOL terminateRunningProcess) {
    id device = ftDeviceForUDID(udid);
    if (!device || !ftResponds(device, "launchApplicationWithID:options:error:")) return nil;

    NSString *environmentKey = ftSimConstant("SimDeviceLaunchApplicationKeyEnvironment", @"environment");
    NSString *terminateKey = ftSimConstant("SimDeviceLaunchApplicationKeyTerminateRunningProcess",
                                           @"terminate_running_process");
    NSMutableDictionary<NSString *, id> *options = [NSMutableDictionary dictionary];
    if (environment.count > 0) options[environmentKey] = environment;
    options[terminateKey] = @(terminateRunningProcess);

    NSError *error = nil;
    // -launchApplicationWithID:options:error: i40@0:8@16@24^@32(Xcode 27 beta 4 実採取)。
    // 戻り値は起動した pid、失敗時は負値(呼び出し側は pid<=0 を失敗として扱う)
    int pid = ((int (*)(id, SEL, id, id, NSError **))objc_msgSend)(
        device, sel_registerName("launchApplicationWithID:options:error:"),
        bundleID, options, &error);
    if (pid > 0) {
        return @{ @"success": @YES, @"pid": @(pid) };
    }
    return @{ @"success": @NO,
              @"error": error.localizedDescription ?: @"launchApplicationWithID:options:error: failed" };
}

NSNumber *FTCoreSimIsInstalled(NSString *udid, NSString *bundleID) {
    id device = ftDeviceForUDID(udid);
    if (!device || !ftResponds(device, "applicationIsInstalled:type:error:")) return nil;

    // -applicationIsInstalled:type:error: B40@0:8@16^@24^@32(Xcode 27 beta 4 実採取)。
    // type は out パラメータ(id*)。ARC 下は素の NSString ** を渡せないため
    // __unsafe_unretained で受ける。値は使わないが渡し忘れると呼び出しの引数数が合わず落ちる
    NSString * __unsafe_unretained typeOut = nil;
    NSError *error = nil;
    BOOL installed = ((BOOL (*)(id, SEL, id, NSString * __unsafe_unretained *, NSError **))objc_msgSend)(
        device, sel_registerName("applicationIsInstalled:type:error:"),
        bundleID, &typeOut, &error);
    if (installed) return @YES;
    // **NO は2種類ある**。未インストールは NSPOSIXErrorDomain code 3
    // ("failed to lookup application properties"。2026-08-02 実採取)で、これだけを
    // 「入っていない」と断定してよい。それ以外(端末が未 boot 等のエラー、および
    // 採取では出なかった error なしの NO)を「入っていない」と読むと appNotInstalled として
    // run を止め、原因と食い違う失敗になる。**断定できるのは POSIX 3 だけ**なので残りは
    // nil = 判定不能にして simctl 側の判定へ委ねる(遅くなるだけで誤らない側に倒す)
    if (error && [error.domain isEqualToString:NSPOSIXErrorDomain] && error.code == 3) return @NO;
    return nil;
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
