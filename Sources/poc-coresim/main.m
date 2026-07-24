// PoC: SimulatorCatalog の simctl スポーンを CoreSimulator 直叩きに置き換えられるかの計測。
// dlopen+objc_msgSend の作法は ftester-simstream/main.m と同一(リンクしない)。
// 使い方:
//   poc-coresim list            … CoreSimulator 経由の列挙を表示(等価性確認用)
//   poc-coresim bench <iters>   … 列挙: CoreSimulator(初期化1回+毎回列挙) vs simctl list -j
//                                  状態ポーリング: device.state 読み ×iters
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static id ftMsg0(id target, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel_registerName(sel));
}

static NSString *ftXcodeSelectPath(void) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"-p"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    [task launch];
    [task waitUntilExit];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// 初期化(dlopen+SimServiceContext+deviceSet)。戻り値は deviceSet
static id ftInitDeviceSet(void) {
    if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/Current/CoreSimulator", RTLD_NOW)) {
        fprintf(stderr, "dlopen CoreSimulator failed: %s\n", dlerror());
        return nil;
    }
    NSString *devDir = [[NSProcessInfo processInfo] environment][@"DEVELOPER_DIR"];
    if (devDir.length == 0) devDir = ftXcodeSelectPath();
    Class ctxClass = NSClassFromString(@"SimServiceContext");
    if (!ctxClass) { fprintf(stderr, "SimServiceContext class not found\n"); return nil; }
    NSError *err = nil;
    id ctx = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        ctxClass, sel_registerName("sharedServiceContextForDeveloperDir:error:"), devDir, &err);
    if (!ctx) { fprintf(stderr, "ctx error: %s\n", err.localizedDescription.UTF8String); return nil; }
    NSError *err2 = nil;
    id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(
        ctx, sel_registerName("defaultDeviceSetWithError:"), &err2);
    if (!set) { fprintf(stderr, "deviceSet error: %s\n", err2.localizedDescription.UTF8String); }
    return set;
}

// 列挙: SimulatorCatalog.devices() 相当(iOS runtime のみ・udid/name/os/booted)
static NSArray<NSDictionary *> *ftEnumerate(id set) {
    NSDictionary *byUDID = ftMsg0(set, "devicesByUDID");
    NSMutableArray *result = [NSMutableArray array];
    for (NSUUID *uuid in byUDID) {
        id device = byUDID[uuid];
        id runtime = ftMsg0(device, "runtime");
        NSString *runtimeName = runtime ? ftMsg0(runtime, "name") : @"";
        if (![runtimeName hasPrefix:@"iOS"]) continue;
        // 破損 runtime 等は available=NO(simctl の isAvailable と同義)
        BOOL available = ((BOOL (*)(id, SEL))objc_msgSend)(device, sel_registerName("available"));
        if (!available) continue;
        long state = ((long (*)(id, SEL))objc_msgSend)(device, sel_registerName("state"));
        NSString *name = ftMsg0(device, "name");
        [result addObject:@{ @"udid": uuid.UUIDString, @"name": name ?: @"",
                             @"os": runtimeName, @"booted": @(state == 3) }];
    }
    return result;
}

static double ftNowMs(void) {
    return [NSDate date].timeIntervalSince1970 * 1000.0;
}

static double ftMedian(NSMutableArray<NSNumber *> *values) {
    [values sortUsingSelector:@selector(compare:)];
    return values.count ? values[values.count / 2].doubleValue : 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"list";
        if ([mode isEqualToString:@"list"]) {
            id set = ftInitDeviceSet();
            if (!set) return 2;
            NSArray *devices = ftEnumerate(set);
            for (NSDictionary *d in devices) {
                printf("%s  %-28s %-10s booted=%s\n", [d[@"udid"] UTF8String],
                       [d[@"name"] UTF8String], [d[@"os"] UTF8String],
                       [d[@"booted"] boolValue] ? "true" : "false");
            }
            printf("# %lu devices\n", (unsigned long)devices.count);
            return 0;
        }
        if ([mode isEqualToString:@"bench"]) {
            int iters = argc > 2 ? atoi(argv[2]) : 20;

            double t0 = ftNowMs();
            id set = ftInitDeviceSet();
            double initMs = ftNowMs() - t0;
            if (!set) return 2;

            NSMutableArray *enumMs = [NSMutableArray array];
            NSUInteger count = 0;
            for (int i = 0; i < iters; i++) {
                double t = ftNowMs();
                count = ftEnumerate(set).count;
                [enumMs addObject:@(ftNowMs() - t)];
            }

            // 状態ポーリング相当(全デバイスの state 読み)
            NSMutableArray *pollMs = [NSMutableArray array];
            NSDictionary *byUDID = ftMsg0(set, "devicesByUDID");
            for (int i = 0; i < iters; i++) {
                double t = ftNowMs();
                for (NSUUID *uuid in byUDID) {
                    (void)((long (*)(id, SEL))objc_msgSend)(byUDID[uuid], sel_registerName("state"));
                }
                [pollMs addObject:@(ftNowMs() - t)];
            }

            // 比較対象: simctl list devices -j のスポーン
            NSMutableArray *simctlMs = [NSMutableArray array];
            for (int i = 0; i < iters; i++) {
                double t = ftNowMs();
                NSTask *task = [NSTask new];
                task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
                task.arguments = @[@"simctl", @"list", @"devices", @"-j"];
                task.standardOutput = [NSPipe pipe];
                task.standardError = [NSPipe pipe];
                [task launch];
                NSData *data = [[task.standardOutput fileHandleForReading] readDataToEndOfFile];
                [task waitUntilExit];
                (void)[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                [simctlMs addObject:@(ftNowMs() - t)];
            }

            printf("devices=%lu iters=%d\n", (unsigned long)count, iters);
            printf("CoreSimulator init(1回のみ): %.1f ms\n", initMs);
            printf("列挙   CoreSimulator: median %.2f ms | simctl list -j: median %.1f ms\n",
                   ftMedian(enumMs), ftMedian(simctlMs));
            printf("状態ポーリング(全台 state 読み): median %.3f ms\n", ftMedian(pollMs));
            return 0;
        }
        if ([mode isEqualToString:@"live"]) {
            // ハンドル live 更新の検証: 同一 deviceSet で N 秒ごとに booted 数を再列挙
            // (別プロセスで simctl boot/shutdown して数が追従するかを見る)
            int seconds = argc > 2 ? atoi(argv[2]) : 30;
            id set = ftInitDeviceSet();
            if (!set) return 2;
            for (int t = 0; t <= seconds; t += 5) {
                NSUInteger booted = 0;
                for (NSDictionary *d in ftEnumerate(set)) {
                    if ([d[@"booted"] boolValue]) booted++;
                }
                printf("t=%ds booted=%lu\n", t, (unsigned long)booted);
                fflush(stdout);
                if (t < seconds) [NSThread sleepForTimeInterval:5];
            }
            return 0;
        }
        fprintf(stderr, "usage: poc-coresim [list|bench <iters>|live <seconds>]\n");
        return 1;
    }
}
