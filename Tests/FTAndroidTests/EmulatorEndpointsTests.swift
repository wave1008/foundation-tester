// ディスカバリ ini のパースとエンドポイント解決を検証する(エミュレータ不要)。
// FT_LIVE_EMULATOR=1 のときだけ、稼働中エミュレータへの実 gRPC スモーク(getStatus/screenshot)も回す。

import XCTest
import FTEmulatorGrpc
@testable import FTAndroid

final class EmulatorEndpointsTests: XCTestCase {

    private let sampleIni = """
        emulator.build=15081367
        avd.id=Pixel_9_Android_15_-02
        port.serial=5556
        port.adb=5557
        avd.name=Pixel 9(Android 15)-02
        emulator.version=36.5.10.0
        grpc.token=abc+def/ghi==
        grpc.port=8556
        """

    func testParseValidIni() {
        let ep = EmulatorEndpoints.parse(text: sampleIni, pid: 123)
        XCTAssertEqual(ep, EmulatorEndpoint(
            serial: "emulator-5556", avdID: "Pixel_9_Android_15_-02",
            grpcPort: 8556, token: "abc+def/ghi==", pid: 123))
    }

    func testParseRejectsMissingToken() {
        let text = sampleIni.replacingOccurrences(of: "grpc.token=abc+def/ghi==", with: "")
        XCTAssertNil(EmulatorEndpoints.parse(text: text, pid: 1))
    }

    func testParseRejectsMissingPort() {
        let text = sampleIni.replacingOccurrences(of: "grpc.port=8556", with: "grpc.port=")
        XCTAssertNil(EmulatorEndpoints.parse(text: text, pid: 1))
    }

    /// value 側に "=" を含むトークン(base64 の埋め草)が最初の "=" でだけ分割されること
    func testParseKeepsEqualsInValue() {
        let ep = EmulatorEndpoints.parse(text: sampleIni, pid: 1)
        XCTAssertEqual(ep?.token, "abc+def/ghi==")
    }

    func testDirectoryScanSkipsDeadPidAndForeignFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 生存 pid(自プロセス)は拾う
        try sampleIni.write(to: dir.appendingPathComponent("pid_\(getpid()).ini"),
                            atomically: true, encoding: .utf8)
        // 死亡 pid(ESRCH 相当の巨大値)と無関係ファイルはスキップ
        try sampleIni.write(to: dir.appendingPathComponent("pid_999999.ini"),
                            atomically: true, encoding: .utf8)
        try "junk".write(to: dir.appendingPathComponent("other.txt"),
                         atomically: true, encoding: .utf8)
        let found = EmulatorEndpoints.all(directory: dir)
        XCTAssertEqual(found.map(\.pid), [getpid()])
        XCTAssertEqual(EmulatorEndpoints.endpoint(serial: "emulator-5556", directory: dir)?.grpcPort, 8556)
        XCTAssertNil(EmulatorEndpoints.endpoint(serial: "emulator-9999", directory: dir))
    }

    /// 稼働フリートに対する実 gRPC スモーク(FT_LIVE_EMULATOR=1 のときのみ。CI では走らない)
    func testLiveGrpcSmoke() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_EMULATOR"] == "1",
                          "FT_LIVE_EMULATOR=1 のときのみ")
        let endpoints = EmulatorEndpoints.all()
        try XCTSkipIf(endpoints.isEmpty, "稼働中エミュレータなし")
        let ep = endpoints[0]
        let booted = try await EmulatorGrpcSession.statusBooted(endpoint: ep)
        XCTAssertTrue(booted, "稼働中エミュレータの booted は true のはず(\(ep.serial))")
        let png = try await EmulatorGrpcSession.screenshotPNG(endpoint: ep)
        XCTAssertGreaterThan(png.count, 1000, "PNG が空(\(ep.serial))")
        // EmulatorControl 経由(ポリシー層)でも同じ結果になること
        let viaControl = await EmulatorControl.screenshotPNG(serial: ep.serial)
        XCTAssertNotNil(viaControl)
        // PNG デコード→一様判定: 健全機の実画面は非一様(blank 誤検知しない)
        let rgba = AndroidHealthProbe.decodeRGBA(png: png)
        XCTAssertNotNil(rgba, "PNG デコード失敗(\(ep.serial))")
        XCTAssertFalse(AndroidHealthProbe.uniformFrame(rgba: rgba ?? Data()),
                       "健全画面が一様判定された(\(ep.serial))")
    }

    /// uniformFrame: 一様=blank / 非一様=健全 の純粋判定
    /// (実凍結フレームは spread 0(2026-07-25 証跡 PNG の画素解析)。tolerance 8 はノイズ余裕)
    func testUniformFrameDetection() {
        func rgba(_ pixels: [[UInt8]]) -> Data {
            Data(pixels.flatMap { [$0[0], $0[1], $0[2], 255] })
        }
        // 一様黒・一様白(gRPC 黒凍結 / adb 白凍結の生画素相当)
        XCTAssertTrue(AndroidHealthProbe.uniformFrame(rgba: rgba(Array(repeating: [0, 0, 0], count: 1000))))
        XCTAssertTrue(AndroidHealthProbe.uniformFrame(rgba: rgba(Array(repeating: [255, 255, 255], count: 1000))))
        // tolerance 内の微小ノイズは一様扱い
        var noisy: [[UInt8]] = Array(repeating: [100, 100, 100], count: 1000)
        noisy[500] = [104, 96, 100]
        XCTAssertTrue(AndroidHealthProbe.uniformFrame(rgba: rgba(noisy)))
        // 実コンテンツ(グラデーション)は非一様
        let gradient: [[UInt8]] = (0..<1000).map { [UInt8($0 % 256), 50, 200] }
        XCTAssertFalse(AndroidHealthProbe.uniformFrame(rgba: rgba(gradient)))
        // 1画素だけ大きく違う(サンプリングに乗る先頭)も非一様
        var oneOff: [[UInt8]] = Array(repeating: [0, 0, 0], count: 1000)
        oneOff[0] = [200, 0, 0]
        XCTAssertFalse(AndroidHealthProbe.uniformFrame(rgba: rgba(oneOff)))
        // 空・端数は判定不能=false(安全側)
        XCTAssertFalse(AndroidHealthProbe.uniformFrame(rgba: Data()))
        XCTAssertFalse(AndroidHealthProbe.uniformFrame(rgba: Data([1, 2, 3])))
    }

    /// decodeRGBA → uniformFrame の結合: 生成した一様/非一様 PNG で判定が通ること
    func testDecodeRGBAUniformity() throws {
        func makePNG(fill: (CGContext, Int, Int) -> Void) throws -> Data {
            let w = 64, h = 64
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            fill(ctx, w, h)
            let image = ctx.makeImage()!
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
        let black = try makePNG { ctx, w, h in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let rgbaBlack = try XCTUnwrap(AndroidHealthProbe.decodeRGBA(png: black))
        XCTAssertTrue(AndroidHealthProbe.uniformFrame(rgba: rgbaBlack))
        let mixed = try makePNG { ctx, w, h in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        }
        let rgbaMixed = try XCTUnwrap(AndroidHealthProbe.decodeRGBA(png: mixed))
        XCTAssertFalse(AndroidHealthProbe.uniformFrame(rgba: rgbaMixed))
        XCTAssertNil(AndroidHealthProbe.decodeRGBA(png: Data([0, 1, 2])))
    }

    /// 実凍結の証跡 PNG に対する回帰検証(FT_EVIDENCE_PNG=<path> 指定時のみ。
    /// 2026-07-25 の PoC 証跡: gRPC 黒 51KB / adb 白 10KB がどちらも一様=blank と判定されること)
    func testEvidencePngIsUniform() throws {
        guard let path = ProcessInfo.processInfo.environment["FT_EVIDENCE_PNG"] else {
            throw XCTSkip("FT_EVIDENCE_PNG 未指定")
        }
        let png = try Data(contentsOf: URL(fileURLWithPath: path))
        let rgba = try XCTUnwrap(AndroidHealthProbe.decodeRGBA(png: png))
        XCTAssertTrue(AndroidHealthProbe.uniformFrame(rgba: rgba), "証跡 PNG が一様判定されない: \(path)")
    }

    /// metalErrorCount: 行カウント・ログ無し・サイズ超過の各分岐
    func testMetalErrorCount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("a.log")
        try """
        === 2026-07-25T00:00:00Z emulator -avd X
        INFO | Android emulator version
        GLDRendererMetal command buffer completion error: MTLCommandBufferErrorDomain Code=1
        normal line
        NSUnderlyingError=IOGPUCommandQueueErrorDomain Code=518
        GLDRendererMetal command buffer completion error: MTLCommandBufferErrorDomain Code=1
        """.write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(AndroidHealthProbe.metalErrorCount(logFile: log), 3)
        XCTAssertNil(AndroidHealthProbe.metalErrorCount(logFile: dir.appendingPathComponent("nai.log")))
        // サイズ超過は数えず即・閾値超過
        let big = dir.appendingPathComponent("big.log")
        FileManager.default.createFile(atPath: big.path,
                                       contents: Data(count: AndroidHealthProbe.metalErrorLogSizeCap + 1))
        XCTAssertEqual(AndroidHealthProbe.metalErrorCount(logFile: big), Int.max)
    }

    /// metal-errors 警報の実配線スモーク(FT_LIVE_EMULATOR=1。実ログに一時的に偽エラー行を
    /// 追記して observeIssues が警報を立てることを確認し、原状復帰する)
    func testLiveMetalErrorIssue() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_EMULATOR"] == "1",
                          "FT_LIVE_EMULATOR=1 のときのみ")
        let endpoints = EmulatorEndpoints.all()
        try XCTSkipIf(endpoints.isEmpty, "稼働中エミュレータなし")
        let ep = endpoints[0]
        let log = EmulatorLog.url(avdID: ep.avdID)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: log.path),
                          "emulator ログ無し(ログ保存実装前のブート)")
        let original = try Data(contentsOf: log)
        defer { try? original.write(to: log) }
        let fake = String(repeating: "GLDRendererMetal command buffer completion error: fake\n",
                          count: AndroidHealthProbe.metalErrorWarnThreshold)
        try (original + Data(fake.utf8)).write(to: log)
        let issues = await AndroidHealthProbe.observeIssues(serial: ep.serial)
        XCTAssertTrue(issues.contains(AndroidHealthProbe.issueMetalErrors),
                      "metal-errors が立たない(\(ep.serial)): \(issues)")
    }

    /// 入力系(named key / touch 合成)実発射のスモーク(対象機の画面を操作するため
    /// FT_LIVE_EMULATOR_INPUT=1 でのみ実行)
    func testLiveInputSmoke() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_EMULATOR_INPUT"] == "1",
                          "FT_LIVE_EMULATOR_INPUT=1 のときのみ(対象機のホーム画面を操作する)")
        let endpoints = EmulatorEndpoints.all()
        try XCTSkipIf(endpoints.isEmpty, "稼働中エミュレータなし")
        let serial = endpoints[0].serial
        let home = await EmulatorControl.namedKeypress(serial: serial, key: "GoHome")
        XCTAssertTrue(home, "GoHome 送出失敗(\(serial))")
        let dragged = await EmulatorControl.drag(serial: serial, fromX: 540, fromY: 1200,
                                                 toX: 540, toY: 800, durationMs: 300)
        XCTAssertTrue(dragged, "drag 送出失敗(\(serial))")
        let pressed = await EmulatorControl.longPress(serial: serial, x: 540, y: 1200, durationMs: 400)
        XCTAssertTrue(pressed, "longPress 送出失敗(\(serial))")
    }

    /// sleep/wake 実発射のスモーク(画面を数秒消灯するため FT_LIVE_EMULATOR_REPAIR=1 でのみ実行)
    func testLiveSleepWakeSmoke() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_EMULATOR_REPAIR"] == "1",
                          "FT_LIVE_EMULATOR_REPAIR=1 のときのみ(対象機の画面を一瞬消灯する)")
        let endpoints = EmulatorEndpoints.all()
        try XCTSkipIf(endpoints.isEmpty, "稼働中エミュレータなし")
        let serial = endpoints[0].serial
        let ok = await EmulatorControl.sleepWake(serial: serial, dwellNs: 1_500_000_000)
        XCTAssertTrue(ok, "gRPC sleep/wake が失敗(\(serial))")
        // wake 後に非 blank へ戻ること(健全機なら repairBlankDisplay 相当の後段プローブが通る)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let png = await EmulatorControl.screenshotPNG(serial: serial)
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png?.count ?? 0, AndroidHealthProbe.blankScreenMaxPNGBytes,
                             "wake 後も blank のまま(\(serial))")
    }
}
