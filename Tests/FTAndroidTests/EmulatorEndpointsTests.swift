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
