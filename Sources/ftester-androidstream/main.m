// Android実機/エミュレータの画面ストリーミング。adb screenrecord(Annex-B H.264)をパースし
// VideoToolboxでデコードしてJPEGをstdoutへ流す常駐ヘルパー(ftester-simstreamのAndroid版)。
// デコード/Annex-B分割ロジックはspike(androidcap.m)を検証済みのまま流用。
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>

static dispatch_queue_t gQueue = NULL;
static CIContext *gCtx = nil;
static CGColorSpaceRef gColorSpace = NULL;
static int gFps = 12;
static int gMaxWidth = 0;
static double gLastEmit = 0;
static BOOL gTrailingArmed = NO;
static NSTask *gAdbTask = nil;
static BOOL gShuttingDown = NO;

static double ftNow(void) { return CACurrentMediaTime(); }

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

// stdoutフレーム形式はSources/ftester-simstream/main.mのftWriteFrameと同一契約(パーサは共通:
// vscode-ftester/src/deviceStream.ts)。変更する場合は3ファイルとも直すこと。stdoutはこの
// バイナリ専用(ログは全てstderr)。バッファ済みstdioはEOFまでflushされない実績がある
// (spike検証時に実害)ため、write()都度発行+_IONBF(main側で設定)を用いる。
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

#pragma mark - Annex-B parse + VideoToolbox decode (spike由来。ロジックは変更しない)

static CMVideoFormatDescriptionRef gFmt = NULL;
static VTDecompressionSessionRef gSession = NULL;
static uint8_t *gSPS = NULL; static size_t gSPSLen = 0;
static uint8_t *gPPS = NULL; static size_t gPPSLen = 0;
static NSMutableData *gBuf;
static CVImageBufferRef gLatest = NULL;

// gQueue上でのみ呼ぶこと(gLatest/gLastEmit/gTrailingArmedの直列性が前提)。
static void ftEncodeAndEmit(void) {
    CVImageBufferRef img = gLatest;
    if (!img) return;
    CIImage *ci = [CIImage imageWithCVImageBuffer:img];
    size_t w = CVPixelBufferGetWidth(img), h = CVPixelBufferGetHeight(img);
    uint16_t outW = (uint16_t)w, outH = (uint16_t)h;
    if (gMaxWidth > 0 && (size_t)gMaxWidth < w) {
        double scale = (double)gMaxWidth / (double)w;
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        outW = (uint16_t)llround((double)w * scale);
        outH = (uint16_t)llround((double)h * scale);
    }
    NSData *jpeg = [gCtx JPEGRepresentationOfImage:ci colorSpace:gColorSpace options:@{}];
    if (!jpeg) {
        fprintf(stderr, "warning: JPEG encode失敗\n");
        return;
    }
    ftWriteFrame(jpeg, outW, outH);
    gLastEmit = ftNow();
}

// デコード済みフレームはfps間隔でスロットルしてencode+emit(60fps超で来ても間引く)。
// 間引かれた最後の1回は末尾タイマーで拾う(motion後の最終フレーム欠落防止)。gLastEmitの
// 初期値0によりCACurrentMediaTime()基準では初回呼び出しは必ず即emitになる(起動直後の1枚)。
static void ftOnTrigger(void) {
    double n = ftNow();
    double interval = 1.0 / (double)gFps;
    if (n - gLastEmit >= interval) {
        ftEncodeAndEmit();
        return;
    }
    if (gTrailingArmed) return;
    gTrailingArmed = YES;
    double delay = (gLastEmit + interval) - n;
    if (delay < 0) delay = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), gQueue, ^{
        gTrailingArmed = NO;
        ftEncodeAndEmit();
    });
}

// VTDecompressionSessionDecodeFrameをflags=0(同期)で呼ぶため、このコールバックはgQueue上で
// 呼び出し元と同じスタックで inline に発火する。decodeは全AUで必須(P-frameは直前フレーム依存の
// ため間引くとストリームが壊れる)が、JPEGエンコード+emitはftOnTriggerでfpsスロットルする
// (decode-all/encode-throttled分離。ここがこのファイルの核)。
static void decompCB(void *ctx, void *srcCtx, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef img, CMTime pts, CMTime dur) {
    if (status != noErr) { fprintf(stderr, "warning: decode status=%d\n", (int)status); return; }
    if (!img) return;
    CVImageBufferRef old = gLatest;
    gLatest = CVBufferRetain(img);
    if (old) CVBufferRelease(old);
    ftOnTrigger();
}

// SPS/PPSが揃うまでセッション生成不可。以後SPS/PPSが変化(解像度変更等)しても再生成しない
// (spike由来の既知制限。解像度変更が起きる運用なら要見直し)。
static void ensureSession(void) {
    if (gSession || !gSPS || !gPPS) return;
    const uint8_t *ps[2] = { gSPS, gPPS };
    size_t pl[2] = { gSPSLen, gPPSLen };
    OSStatus s = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, ps, pl, 4, &gFmt);
    if (s != noErr) { fprintf(stderr, "error: format description作成失敗 status=%d\n", (int)s); return; }
    VTDecompressionOutputCallbackRecord cb = { decompCB, NULL };
    s = VTDecompressionSessionCreate(kCFAllocatorDefault, gFmt, NULL, NULL, &cb, &gSession);
    if (s != noErr) fprintf(stderr, "error: VTDecompressionSessionCreate失敗 status=%d\n", (int)s);
}

static void decodeVCL(const uint8_t *nal, size_t len) {
    if (!gSession) return;
    size_t auLen = 4 + len;
    uint8_t *au = malloc(auLen);
    au[0] = (len >> 24) & 0xFF; au[1] = (len >> 16) & 0xFF; au[2] = (len >> 8) & 0xFF; au[3] = len & 0xFF;
    memcpy(au + 4, nal, len);
    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, au, auLen, kCFAllocatorMalloc, NULL, 0, auLen, 0, &bb) != noErr) { free(au); return; }
    CMSampleBufferRef sb = NULL;
    const size_t sz = auLen;
    if (CMSampleBufferCreateReady(kCFAllocatorDefault, bb, gFmt, 1, 0, NULL, 1, &sz, &sb) == noErr) {
        VTDecompressionSessionDecodeFrame(gSession, sb, 0, NULL, NULL);
        CFRelease(sb);
    }
    CFRelease(bb);
}

static void handleNAL(const uint8_t *nal, size_t len) {
    while (len > 0 && nal[len - 1] == 0x00) len--; // 末尾ゼロ除去(次の開始コードの先行ゼロを含み得る)
    if (len == 0) return;
    int type = nal[0] & 0x1F;
    if (type == 7) { free(gSPS); gSPS = malloc(len); memcpy(gSPS, nal, len); gSPSLen = len; }
    else if (type == 8) { free(gPPS); gPPS = malloc(len); memcpy(gPPS, nal, len); gPPSLen = len; ensureSession(); }
    else if (type == 1 || type == 5) decodeVCL(nal, len);
}

// 次の00 00 01開始コードをfrom以降から探す。3バイト開始コード基準(4バイト開始コードは
// 先行ゼロ1個が前NALの末尾に残るが、handleNALの末尾ゼロ除去で吸収される)。
static long findStart(const uint8_t *d, long n, long from) {
    for (long i = from; i + 3 <= n; i++) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) return i;
    }
    return -1;
}

// gQueue上でのみ呼ぶこと(gBufの直列性が前提。adbの readabilityHandler からdispatch_asyncで入る)。
static void processChunk(NSData *chunk) {
    [gBuf appendData:chunk];
    const uint8_t *d = gBuf.bytes; long n = gBuf.length;
    long first = findStart(d, n, 0);
    if (first < 0) return;
    long nalStart = first + 3;
    long consumed = first;
    for (;;) {
        long next = findStart(d, n, nalStart);
        if (next < 0) break; // 現在のNALは未完(続きを待つ)
        handleNAL(d + nalStart, next - nalStart);
        consumed = next;
        nalStart = next + 3;
    }
    if (consumed > 0) [gBuf replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
}

#pragma mark - adb path resolution

static NSString *ftResolveAdbPath(NSString *cliAdb) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (cliAdb.length > 0) [candidates addObject:cliAdb];
    NSDictionary<NSString *, NSString *> *env = [[NSProcessInfo processInfo] environment];
    NSString *androidHome = env[@"ANDROID_HOME"];
    if (androidHome.length > 0) {
        [candidates addObject:[androidHome stringByAppendingPathComponent:@"platform-tools/adb"]];
    }
    NSString *home = env[@"HOME"];
    if (home.length > 0) {
        [candidates addObject:[home stringByAppendingPathComponent:@"Library/Android/sdk/platform-tools/adb"]];
    }
    NSString *pathEnv = env[@"PATH"];
    if (pathEnv.length > 0) {
        for (NSString *dir in [pathEnv componentsSeparatedByString:@":"]) {
            if (dir.length == 0) continue;
            [candidates addObject:[dir stringByAppendingPathComponent:@"adb"]];
        }
    }
    [candidates addObject:@"/opt/homebrew/bin/adb"];
    [candidates addObject:@"/usr/local/bin/adb"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in candidates) {
        if ([fm isExecutableFileAtPath:c]) return c;
    }
    return nil;
}

#pragma mark - lifecycle

// adb子プロセスをterminateしてから終了する(SIGTERM/SIGINT/stdin EOF/シャットダウン共通経路)。
// 生かしたまま終了すると screenrecord が残存し続ける。
static void ftShutdown(int code) {
    gShuttingDown = YES;
    if (gAdbTask.isRunning) [gAdbTask terminate];
    exit(code);
}

int main(int argc, char **argv) {
@autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);

    NSString *serial = nil;
    NSString *adbArg = nil;
    int fps = 12;
    int maxWidth = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--serial") == 0 && i + 1 < argc) {
            serial = [NSString stringWithUTF8String:argv[++i]];
        } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
            fps = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--max-width") == 0 && i + 1 < argc) {
            maxWidth = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--adb") == 0 && i + 1 < argc) {
            adbArg = [NSString stringWithUTF8String:argv[++i]];
        }
    }
    if (serial.length == 0) {
        fprintf(stderr, "usage: ftester-androidstream --serial <adb-serial> [--fps <n>] [--max-width <px>] [--adb <path>]\n");
        return 2;
    }
    gFps = (fps > 0) ? fps : 12;
    gMaxWidth = (maxWidth > 0) ? maxWidth : 0;

    NSString *adbPath = ftResolveAdbPath(adbArg);
    if (adbPath.length == 0) {
        fprintf(stderr, "error: adbが見つかりません(--adb / $ANDROID_HOME / ~/Library/Android/sdk / $PATH / /opt/homebrew/bin / /usr/local/bin を確認)\n");
        return 3;
    }

    gColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    gCtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    gQueue = dispatch_queue_create("com.foundation-tester.ftester-androidstream.frame", DISPATCH_QUEUE_SERIAL);
    gBuf = [NSMutableData data];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:adbPath];
    // --time-limit 0 = 無制限。有限値だとscreenrecordが期限切れで終了し、consumer側は
    // ストリーム断のまま古いプロセスが残る不整合を起こす(仕様上ここは変更禁止)。
    task.arguments = @[@"-s", serial, @"exec-out", @"screenrecord", @"--output-format=h264", @"--time-limit", @"0", @"-"];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    gAdbTask = task;

    NSFileHandle *outHandle = outPipe.fileHandleForReading;
    outHandle.readabilityHandler = ^(NSFileHandle *h) {
        NSData *chunk = h.availableData;
        if (chunk.length == 0) return; // EOF自体はtask終了として terminationHandler 側で扱う
        dispatch_async(gQueue, ^{ processChunk(chunk); });
    };

    __block NSString *errTail = @"";
    NSFileHandle *errHandle = errPipe.fileHandleForReading;
    errHandle.readabilityHandler = ^(NSFileHandle *h) {
        NSData *chunk = h.availableData;
        if (chunk.length == 0) return;
        NSString *text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
        if (text.length == 0) return;
        NSString *combined = [errTail stringByAppendingString:text];
        NSArray<NSString *> *lines = [combined componentsSeparatedByString:@"\n"];
        errTail = lines.lastObject ?: @"";
        NSUInteger completeCount = lines.count - 1;
        for (NSUInteger i = 0; i < completeCount; i++) {
            fprintf(stderr, "[adb] %s\n", lines[i].UTF8String);
        }
    };

    // adbが自発的に終了=fatal(拡張側の常駐監視が再起動する。ここで内部再試行はしない)。
    task.terminationHandler = ^(NSTask *t) {
        if (gShuttingDown) return;
        fprintf(stderr, "error: adbが終了しました(status=%d)。screenrecordセッション終了/端末切断/回転などの可能性\n", (int)t.terminationStatus);
        exit(4);
    };

    NSError *launchErr = nil;
    if (![task launchAndReturnError:&launchErr]) {
        fprintf(stderr, "error: adb起動失敗: %s\n", launchErr.localizedDescription.UTF8String);
        return 4;
    }

    dispatch_source_t sigTermSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigTermSrc, ^{ ftShutdown(0); });
    dispatch_resume(sigTermSrc);
    dispatch_source_t sigIntSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigIntSrc, ^{ ftShutdown(0); });
    dispatch_resume(sigIntSrc);

    // stdin EOF = 親がパイプを閉じた = 終了指示(常駐プロセス共通規約。ftester-simstreamと同じ)。
    dispatch_source_t stdinSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(stdinSrc, ^{
        char buf[64];
        ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
        if (n <= 0) ftShutdown(0);
    });
    dispatch_resume(stdinSrc);

    // キープアライブ: screenrecordは通常静止画面でもフレームを吐き続けるが、万一途切れても
    // consumer側(deviceStream.ts)の無フレームwedge監視が誤って再起動ループに入らないよう、
    // 直近デコード済みフレームを低レートで再送する(gQueue上で実行)。
    dispatch_source_t keepaliveSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(keepaliveSrc, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                              (uint64_t)(3.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(keepaliveSrc, ^{
        if (gLatest && ftNow() - gLastEmit >= 2.5) ftEncodeAndEmit();
    });
    dispatch_resume(keepaliveSrc);

    dispatch_main();
}
    return 0;
}
