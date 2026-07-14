// ヘッドレス iOS シミュレータ画面キャプチャ。CoreSimulator/SimulatorKit の private API を
// dlopen+objc_msgSend で叩く(リンクはしない。Package.swift 参照)。
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>

static id gDesc = nil;
static dispatch_queue_t gQueue = NULL;
static CIContext *gCtx = nil;
static CGColorSpaceRef gColorSpace = NULL;
static NSUUID *gFrameCbUUID = nil;
static NSUUID *gIoCbUUID = nil;
static int gFps = 12;
static int gMaxWidth = 0;
static double gLastEmit = 0;
static BOOL gTrailingArmed = NO;
static int gInitialAttempts = 0;
static BOOL gCodecH264 = NO;
// --codec h264 専用(IOSurfaceサイズ変化でInvalidateして作り直す。次フレームはVTが自動でキーフレームにする)。
static VTCompressionSessionRef gCompSession = NULL;
static size_t gCompWidth = 0;
static size_t gCompHeight = 0;

static double ftNow(void) { return CACurrentMediaTime(); }

// 未宣言セレクタ(private API)呼び出し専用。ブラケット構文は警告が出るため使わない。
static id ftMsg0(id r, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(r, sel_registerName(sel));
}
static void ftVoidMsg1(id r, const char *sel, id arg) {
    ((void (*)(id, SEL, id))objc_msgSend)(r, sel_registerName(sel), arg);
}

// セレクタ欠落は Xcode/CoreSimulator の ABI 変化。exit 3 で呼び出し側へポーリングへの
// フォールバックを促す(将来の互換切れに対する事故防止)。
static Class ftRequireClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) {
        fprintf(stderr, "error: incompatible CoreSimulator (missing class %s)\n", name.UTF8String);
        exit(3);
    }
    return c;
}
static void ftRequireResp(id obj, const char *sel) {
    if (!obj || ![obj respondsToSelector:sel_registerName(sel)]) {
        fprintf(stderr, "error: incompatible CoreSimulator (missing %s)\n", sel);
        exit(3);
    }
}

static void ftWriteAll(const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            exit(0);  // stdout側(親)が閉じている。以後の出力は無意味なので静かに終了
        }
        p += (size_t)n;
        left -= (size_t)n;
    }
}

// stdout レコード形式(契約。対向: Sources/ftester-androidstream/main.m・
// vscode-ftester/src/deviceStream.ts。3ファイルとも直すこと):
// - 既定/--codec mjpeg: v1。WIDTH(u16 BE) HEIGHT(u16 BE) LEN(u32 BE) JPEGバイト×LEN。
// - --codec h264: v2。KIND(u8: 2=H.264 AU Annex-B, 3=キープアライブping) FLAGS(u8: bit0=
//   キーフレーム、KIND=2のみ意味を持つ) WIDTH(u16 BE、実サイズ) HEIGHT(u16 BE) LEN(u32 BE、
//   KIND=3は0) DATA(LENバイト。キーフレームはSPS+PPS+IDR連結、開始コードは4バイトへ正規化)。
// stdout はこのバイナリ専用(ログ/診断は全て stderr)。バッファ済み stdio は EOF まで
// flush されない実績あり(Android版で実害)なので write() 都度発行+_IONBF を併用する。
static void ftWriteFrame(NSData *jpeg, uint16_t w, uint16_t h) {
    uint8_t hdr[8];
    hdr[0] = (uint8_t)(w >> 8);
    hdr[1] = (uint8_t)(w & 0xFF);
    hdr[2] = (uint8_t)(h >> 8);
    hdr[3] = (uint8_t)(h & 0xFF);
    uint32_t len = (uint32_t)jpeg.length;
    hdr[4] = (uint8_t)(len >> 24);
    hdr[5] = (uint8_t)(len >> 16);
    hdr[6] = (uint8_t)(len >> 8);
    hdr[7] = (uint8_t)(len & 0xFF);
    ftWriteAll(hdr, sizeof(hdr));
    ftWriteAll(jpeg.bytes, jpeg.length);
}

// v2ヘッダ(--codec h264 専用。フォーマット詳細は上のファイル冒頭契約コメント参照)。
static void ftWriteV2(uint8_t kind, uint8_t flags, uint16_t w, uint16_t h, const void *data, uint32_t len) {
    uint8_t hdr[10];
    hdr[0] = kind;
    hdr[1] = flags;
    hdr[2] = (uint8_t)(w >> 8); hdr[3] = (uint8_t)(w & 0xFF);
    hdr[4] = (uint8_t)(h >> 8); hdr[5] = (uint8_t)(h & 0xFF);
    hdr[6] = (uint8_t)(len >> 24); hdr[7] = (uint8_t)(len >> 16);
    hdr[8] = (uint8_t)(len >> 8);  hdr[9] = (uint8_t)(len & 0xFF);
    ftWriteAll(hdr, sizeof(hdr));
    if (len > 0) ftWriteAll(data, len);
}

// gLastEmitはkeepaliveタイマーのアイドル判定と共有するため、書き込みの都度ここで更新する。
static void ftWriteH264AU(NSData *au, BOOL keyframe, uint16_t w, uint16_t h) {
    if (au.length == 0) return;
    ftWriteV2(2, keyframe ? 1 : 0, w, h, au.bytes, (uint32_t)au.length);
    gLastEmit = ftNow();
}
static void ftWritePing(void) {
    ftWriteV2(3, 0, 0, 0, NULL, 0);
    gLastEmit = ftNow();
}

// gQueue 上でのみ呼ぶこと(CIContext・gLastEmit・gTrailingArmed の直列性が前提)。
static void ftEmitNow(void) {
    id so = ftMsg0(gDesc, "framebufferSurface");
    if (!so) return;  // 起動直後などまだサーフェス未生成。次のトリガ待ち
    IOSurfaceRef s = (__bridge IOSurfaceRef)so;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, s, NULL, &pb) != kCVReturnSuccess || !pb) {
        fprintf(stderr, "warning: CVPixelBufferCreateWithIOSurface failed\n");
        return;
    }
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    size_t w = IOSurfaceGetWidth(s);
    size_t h = IOSurfaceGetHeight(s);
    uint16_t outW = (uint16_t)w;
    uint16_t outH = (uint16_t)h;
    if (gMaxWidth > 0 && (size_t)gMaxWidth < w) {
        double scale = (double)gMaxWidth / (double)w;
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        outW = (uint16_t)llround((double)w * scale);
        outH = (uint16_t)llround((double)h * scale);
    }
    NSData *jpeg = [gCtx JPEGRepresentationOfImage:ci colorSpace:gColorSpace options:@{}];
    CVPixelBufferRelease(pb);
    if (!jpeg) {
        fprintf(stderr, "warning: JPEG encode failed\n");
        return;
    }
    ftWriteFrame(jpeg, outW, outH);
    gLastEmit = ftNow();
}

#pragma mark - H.264 encode (--codec h264)

// gQueue 上でのみ呼ぶこと(gCompSession/gCompWidth/gCompHeight の直列性が前提)。
static void ftInvalidateCompressionSession(void) {
    if (!gCompSession) return;
    VTCompressionSessionInvalidate(gCompSession);
    CFRelease(gCompSession);
    gCompSession = NULL;
}

static void ftCompressionOutputCB(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status,
                                   VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer);

// IOSurfaceサイズが変わったらInvalidateして作り直す(次フレームはVTが自動でキーフレームにする)。
static void ftEnsureCompressionSession(size_t w, size_t h) {
    if (gCompSession && gCompWidth == w && gCompHeight == h) return;
    ftInvalidateCompressionSession();
    gCompWidth = w;
    gCompHeight = h;
    VTCompressionSessionRef session = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)w, (int32_t)h,
        kCMVideoCodecType_H264, NULL, NULL, kCFAllocatorDefault, ftCompressionOutputCB, NULL, &session);
    if (st != noErr || !session) {
        fprintf(stderr, "error: VTCompressionSessionCreate failed status=%d\n", (int)st);
        return;
    }
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@120);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@4.0);
    VTCompressionSessionPrepareToEncodeFrames(session);
    gCompSession = session;
}

// gQueue上で呼ぶこと(ftWriteAllの直列性が前提)。AVCCの長さプレフィックス(NALUnitHeaderLength
// バイト)をAnnex-Bの4バイト開始コードへ変換し、キーフレームはSPS+PPSを前置してv2で書き出す。
static void ftHandleEncodedSample(CMSampleBufferRef sampleBuffer) {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!fmt) return;
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);

    BOOL keyframe = YES;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        keyframe = !CFDictionaryContainsKey(a, kCMSampleAttachmentKey_NotSync);
    }

    static const uint8_t kStartCode[4] = {0, 0, 0, 1};
    NSMutableData *annexB = [NSMutableData data];
    int nalHeaderLen = 4;
    size_t paramCount = 0;
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &paramCount, &nalHeaderLen);
    if (keyframe) {
        for (size_t i = 0; i < paramCount; i++) {
            const uint8_t *ps = NULL;
            size_t psLen = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &psLen, NULL, NULL) != noErr) continue;
            [annexB appendBytes:kStartCode length:4];
            [annexB appendBytes:ps length:psLen];
        }
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t totalLen = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (bb && totalLen > 0) {
        uint8_t *raw = malloc(totalLen);
        if (raw) {
            if (CMBlockBufferCopyDataBytes(bb, 0, totalLen, raw) == kCMBlockBufferNoErr) {
                size_t offset = 0;
                while (offset + (size_t)nalHeaderLen <= totalLen) {
                    uint32_t nalLen = 0;
                    for (int i = 0; i < nalHeaderLen; i++) nalLen = (nalLen << 8) | raw[offset + i];
                    offset += (size_t)nalHeaderLen;
                    if (offset + nalLen > totalLen) break;
                    [annexB appendBytes:kStartCode length:4];
                    [annexB appendBytes:raw + offset length:nalLen];
                    offset += nalLen;
                }
            } else {
                fprintf(stderr, "warning: CMBlockBufferCopyDataBytes failed\n");
            }
            free(raw);
        }
    }

    ftWriteH264AU(annexB, keyframe, (uint16_t)dims.width, (uint16_t)dims.height);
}

// VTの出力コールバックはgQueueとは別スレッドから来る。書き込みの直列性を保つためgQueueへhopする。
static void ftCompressionOutputCB(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status,
                                   VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    if (status != noErr) {
        fprintf(stderr, "warning: VTCompressionSession encode failed status=%d\n", (int)status);
        return;
    }
    if (!sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    CFRetain(sampleBuffer);
    dispatch_async(gQueue, ^{
        ftHandleEncodedSample(sampleBuffer);
        CFRelease(sampleBuffer);
    });
}

// gQueue 上でのみ呼ぶこと(ftEnsureCompressionSession/VTCompressionSessionEncodeFrame の直列性が前提)。
static void ftEmitNowH264(void) {
    id so = ftMsg0(gDesc, "framebufferSurface");
    if (!so) return;  // 起動直後などまだサーフェス未生成。次のトリガ待ち
    IOSurfaceRef s = (__bridge IOSurfaceRef)so;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, s, NULL, &pb) != kCVReturnSuccess || !pb) {
        fprintf(stderr, "warning: CVPixelBufferCreateWithIOSurface failed\n");
        return;
    }
    size_t w = IOSurfaceGetWidth(s);
    size_t h = IOSurfaceGetHeight(s);
    ftEnsureCompressionSession(w, h);
    if (gCompSession) {
        CMTime pts = CMTimeMakeWithSeconds(CACurrentMediaTime(), 90000);
        OSStatus st = VTCompressionSessionEncodeFrame(gCompSession, pb, pts, kCMTimeInvalid, NULL, NULL, NULL);
        if (st != noErr) fprintf(stderr, "warning: VTCompressionSessionEncodeFrame failed status=%d\n", (int)st);
    }
    CVPixelBufferRelease(pb);
}

static void ftEmitCurrent(void) {
    if (gCodecH264) ftEmitNowH264(); else ftEmitNow();
}

// frameCallback は60Hz超で発火しうるため fps 間隔でスロットル。間引かれた最後の1回は
// 末尾タイマーで拾う(motion後の最終フレーム欠落防止)。多重armはBOOLガードで防ぐ。
static void ftOnTrigger(void) {
    double n = ftNow();
    double interval = 1.0 / (double)gFps;
    if (n - gLastEmit >= interval) {
        ftEmitCurrent();
        return;
    }
    if (gTrailingArmed) return;
    gTrailingArmed = YES;
    double delay = (gLastEmit + interval) - n;
    if (delay < 0) delay = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), gQueue, ^{
        gTrailingArmed = NO;
        ftEmitCurrent();
    });
}

// 起動直後に静止画面へアタッチしても1枚は見えるようにする。framebufferSurface が
// まだ nil の場合は用意されるまで短間隔でリトライ(上限あり。以降は通常トリガに委ねる)。
static void ftEmitInitialFrame(void) {
    id so = ftMsg0(gDesc, "framebufferSurface");
    if (so) {
        ftEmitCurrent();
        return;
    }
    if (++gInitialAttempts > 25) {
        fprintf(stderr, "warning: no initial frame available after startup\n");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), gQueue, ^{
        ftEmitInitialFrame();
    });
}

static void ftShutdown(int code) {
    if (gDesc) {
        if ([gDesc respondsToSelector:sel_registerName("unregisterScreenCallbacksWithUUID:")]) {
            ftVoidMsg1(gDesc, "unregisterScreenCallbacksWithUUID:", gFrameCbUUID);
        }
        if ([gDesc respondsToSelector:sel_registerName("unregisterIOSurfacesChangeCallbackWithUUID:")]) {
            ftVoidMsg1(gDesc, "unregisterIOSurfacesChangeCallbackWithUUID:", gIoCbUUID);
        }
    }
    exit(code);
}

static NSString *ftXcodeSelectPath(void) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"-p"];
    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSPipe pipe];
    NSError *launchErr = nil;
    if (![task launchAndReturnError:&launchErr]) {
        fprintf(stderr, "warning: xcode-select -p failed to launch: %s\n", launchErr.localizedDescription.UTF8String);
        return nil;
    }
    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

int main(int argc, char **argv) {
@autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGPIPE, SIG_IGN);  // 親がstdoutを閉じてもwrite()がEPIPEを返すようにする(exit(0)経路)

    NSString *udid = nil;
    int fps = 12;
    int maxWidth = 0;
    NSString *codec = @"mjpeg";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--udid") == 0 && i + 1 < argc) {
            udid = [NSString stringWithUTF8String:argv[++i]];
        } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
            fps = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--max-width") == 0 && i + 1 < argc) {
            maxWidth = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--codec") == 0 && i + 1 < argc) {
            codec = [NSString stringWithUTF8String:argv[++i]];
        }
    }
    if (udid.length == 0 || (![codec isEqualToString:@"mjpeg"] && ![codec isEqualToString:@"h264"])) {
        fprintf(stderr, "usage: ftester-simstream --udid <UDID> [--fps <n>] [--max-width <px>] [--codec h264|mjpeg]\n");
        return 2;
    }
    gFps = (fps > 0) ? fps : 12;
    gMaxWidth = (maxWidth > 0) ? maxWidth : 0;
    gCodecH264 = [codec isEqualToString:@"h264"];

    // CoreSimulator のこのパスは Xcode バージョン非依存で安定。SimulatorKit はベストエフォート
    // (無くても主要APIはCoreSimulator側にある)。ただしどちらもセレクタの存在自体は
    // Xcodeバージョンに依存し壊れうるため、以降は個別に respondsToSelector で確認する。
    if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/Current/CoreSimulator", RTLD_NOW)) {
        fprintf(stderr, "warning: dlopen CoreSimulator failed: %s\n", dlerror());
    }
    NSString *devDir = [[NSProcessInfo processInfo] environment][@"DEVELOPER_DIR"];
    if (devDir.length == 0) {
        devDir = ftXcodeSelectPath();
    }
    if (devDir.length > 0) {
        NSString *simKitPath = [devDir stringByAppendingPathComponent:@"../SharedFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit"];
        if (!dlopen(simKitPath.UTF8String, RTLD_NOW)) {
            fprintf(stderr, "warning: dlopen SimulatorKit failed: %s (%s)\n", dlerror(), simKitPath.UTF8String);
        }
    } else {
        fprintf(stderr, "warning: DEVELOPER_DIR not resolved; SimulatorKit not loaded\n");
    }

    Class ctxClass = ftRequireClass(@"SimServiceContext");
    ftRequireResp((id)ctxClass, "sharedServiceContextForDeveloperDir:error:");
    NSError *err = nil;
    id ctx = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        ctxClass, sel_registerName("sharedServiceContextForDeveloperDir:error:"), devDir, &err);
    if (!ctx) {
        fprintf(stderr, "error: SimServiceContext unavailable: %s\n", err.localizedDescription.UTF8String);
        return 4;
    }

    ftRequireResp(ctx, "defaultDeviceSetWithError:");
    NSError *err2 = nil;
    id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(ctx, sel_registerName("defaultDeviceSetWithError:"), &err2);
    if (!set) {
        fprintf(stderr, "error: defaultDeviceSetWithError failed: %s\n", err2.localizedDescription.UTF8String);
        return 4;
    }

    ftRequireResp(set, "devicesByUDID");
    id byUDID = ftMsg0(set, "devicesByUDID");
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
    if (!uuid) {
        fprintf(stderr, "error: invalid UDID: %s\n", udid.UTF8String);
        return 4;
    }
    id device = [byUDID objectForKey:uuid];
    if (!device) {
        fprintf(stderr, "error: device not found for udid %s\n", udid.UTF8String);
        return 4;
    }
    ftRequireResp(device, "state");
    long state = ((long (*)(id, SEL))objc_msgSend)(device, sel_registerName("state"));
    if (state != 3) {
        fprintf(stderr, "error: device not booted (state=%ld)\n", state);
        return 4;
    }

    ftRequireResp(device, "io");
    id io = ftMsg0(device, "io");
    ftRequireResp(io, "ioPorts");
    id ports = ftMsg0(io, "ioPorts");

    Protocol *renderableProto = objc_getProtocol("SimDisplayIOSurfaceRenderable");
    Protocol *displayProto = objc_getProtocol("SimDisplayRenderable");
    if (!renderableProto || !displayProto) {
        fprintf(stderr, "error: incompatible CoreSimulator (missing SimDisplay protocols)\n");
        return 3;
    }
    // 720x480のデフォルト表示や0x0のダミーもこれらのprotocolに適合するため、面積最大の
    // ディスクリプタを実画面として選ぶ(必須。最初に見つかったものを採用すると誤動作する)。
    id chosenDesc = nil;
    CGSize chosenSize = CGSizeZero;
    for (id port in ports) {
        if (![port respondsToSelector:sel_registerName("descriptor")]) continue;
        id desc = ftMsg0(port, "descriptor");
        if (!desc) continue;
        if (![desc conformsToProtocol:renderableProto] || ![desc conformsToProtocol:displayProto]) continue;
        if (![desc respondsToSelector:sel_registerName("displaySize")]) continue;
        CGSize sz = ((CGSize (*)(id, SEL))objc_msgSend)(desc, sel_registerName("displaySize"));
        if (sz.width * sz.height > chosenSize.width * chosenSize.height) {
            chosenSize = sz;
            chosenDesc = desc;
        }
    }
    if (!chosenDesc) {
        fprintf(stderr, "error: no renderable display found\n");
        return 5;
    }
    gDesc = chosenDesc;
    ftRequireResp(gDesc, "framebufferSurface");
    ftRequireResp(gDesc, "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:");
    ftRequireResp(gDesc, "registerCallbackWithUUID:ioSurfacesChangeCallback:");
    ftRequireResp(gDesc, "setPowerState:completionQueue:completionHandler:");

    gColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    gCtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    gQueue = dispatch_queue_create("com.foundation-tester.ftester-simstream.callback", DISPATCH_QUEUE_SERIAL);
    gFrameCbUUID = [NSUUID UUID];
    gIoCbUUID = [NSUUID UUID];

    ((void (*)(id, SEL, id, dispatch_queue_t, id, id, id))objc_msgSend)(
        gDesc,
        sel_registerName("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"),
        gFrameCbUUID, gQueue,
        ^{ ftOnTrigger(); },
        ^{ ftOnTrigger(); },
        ^{ });
    // ioSurfacesChangeCallbackは呼び出し元キューが不定なため、直列化のためgQueueへhopする。
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        gDesc, sel_registerName("registerCallbackWithUUID:ioSurfacesChangeCallback:"), gIoCbUUID,
        ^{ dispatch_async(gQueue, ^{ ftOnTrigger(); }); });

    // setPowerState:1 するまでframebufferSurfaceはnilのままでコールバックも発火しない
    // (ヘッドレス動作させるための必須呼び出し。省略すると無音のまま何も撮れない)。
    ((void (*)(id, SEL, int, dispatch_queue_t, void (^)(void)))objc_msgSend)(
        gDesc, sel_registerName("setPowerState:completionQueue:completionHandler:"), 1, gQueue,
        ^{ ftEmitInitialFrame(); });

    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    dispatch_source_t sigTermSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigTermSrc, ^{ ftShutdown(0); });
    dispatch_resume(sigTermSrc);
    dispatch_source_t sigIntSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigIntSrc, ^{ ftShutdown(0); });
    dispatch_resume(sigIntSrc);

    // stdin EOF = 親がパイプを閉じた = 終了指示(プロジェクト共通の常駐プロセス規約)。
    dispatch_source_t stdinSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(stdinSrc, ^{
        char buf[64];
        ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
        if (n <= 0) ftShutdown(0);
    });
    dispatch_resume(stdinSrc);

    // キープアライブ: 静止画面は表示変化が無く frameCallback が発火しないため、放置すると
    // 無フレームが続く。消費側(deviceStream.ts)の無フレーム wedge 監視の誤発火(=静止画面での
    // kill/再起動ループ)を防ぐため、アイドル時のみ再送する。動作中は gLastEmit が近いのでスキップ
    // (負荷はアイドル時 約0.33fps=ほぼ無視できる)。gQueue 上で実行。h264モードは再キャプチャ・
    // 再エンコードせずKIND=3 pingのみ送る(mjpegは現サーフェスを再送)。
    dispatch_source_t keepaliveSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(keepaliveSrc, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                              (uint64_t)(3.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(keepaliveSrc, ^{
        if (ftNow() - gLastEmit < 2.5) return;
        if (gCodecH264) ftWritePing(); else ftEmitNow();
    });
    dispatch_resume(keepaliveSrc);

    dispatch_main();
}
    return 0;
}
