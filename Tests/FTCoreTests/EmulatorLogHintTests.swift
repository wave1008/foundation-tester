// 「device disappeared」に添えるエミュレータログの導線(FTCore.EmulatorLog)。
// AVD id は論理名と一致するとは限らない(非英数字→ _ の畳み込み)ので、実在するファイル
// だけを名指しし、引けないときはディレクトリを案内する。既定パスはホスト共有なので
// テストは in: で一時ディレクトリへ隔離する。

import XCTest
@testable import FTCore

final class EmulatorLogHintTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-emulog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    private func write(_ name: String, content: String) throws {
        try Data(content.utf8).write(to: dir.appendingPathComponent(name))
    }

    func testFindsLogBySanitizedAVDID() throws {
        // "Pixel 9(Android 15)-01" → 非英数字(スペース・括弧)を "_" に畳んだ AVD id のログ
        // (AndroidDeviceCatalog.canonicalAVDID の②と同じ変換。"-" と "." はそのまま)
        try touch("Pixel_9_Android_15_-01.log")
        let url = EmulatorLog.existingURL(deviceName: "Pixel 9(Android 15)-01", in: dir)
        XCTAssertEqual(url?.lastPathComponent, "Pixel_9_Android_15_-01.log")
    }

    func testPrefersExactNameOverSanitized() throws {
        try touch("Pixel-01.log")
        XCTAssertEqual(EmulatorLog.existingURL(deviceName: "Pixel-01", in: dir)?.lastPathComponent,
                       "Pixel-01.log")
    }

    func testHintNamesTheFileWhenItExists() throws {
        try touch("Pixel_9_Android_15_-01.log")
        let hint = EmulatorLog.dropoutHint(deviceName: "Pixel 9(Android 15)-01", in: dir)
        XCTAssertTrue(hint.contains("Pixel_9_Android_15_-01.log"), hint)
    }

    // 無いパスを名指しすると導線として逆効果 —— ファイルが引けないときはディレクトリを案内する
    func testHintFallsBackToTheDirectory() {
        let hint = EmulatorLog.dropoutHint(deviceName: "Pixel-99", in: dir)
        XCTAssertFalse(hint.contains("Pixel-99"), hint)
        XCTAssertTrue(hint.contains(dir.path), hint)
    }

    func testHintWithoutDeviceNameStillPointsAtTheDirectory() {
        let hint = EmulatorLog.dropoutHint(deviceName: nil, in: dir)
        XCTAssertTrue(hint.contains(dir.path), hint)
    }

    // `kill -9` で消えたエミュレータのログには FATAL/ERROR 行が無い
    // (末尾は無関係な Metal のエラー等)。断定してはいけない
    func testHintDoesNotClaimAFatalWhenTheLogHasNone() throws {
        try write("Pixel-06.log", content: """
            === boot header ===
            some info line
            Metal command buffer completion error: -1
            """)
        let hint = EmulatorLog.dropoutHint(deviceName: "Pixel-06", in: dir)
        XCTAssertFalse(hint.contains("qemu FATAL"), hint)
        XCTAssertTrue(hint.contains("does not record an exit reason"), hint)
        // ファイルの所在は引き続き名指しする
        XCTAssertTrue(hint.contains("Pixel-06.log"), hint)
    }

    // FATAL/ERROR 行が実在するときは、断定してよいだけでなくその行自体を引用する
    func testHintQuotesTheFatalLineWhenPresent() throws {
        try write("Pixel-07.log", content: """
            === boot header ===
            FATAL | Broken AVD system path
            """)
        let hint = EmulatorLog.dropoutHint(deviceName: "Pixel-07", in: dir)
        XCTAssertTrue(hint.contains("Broken AVD system path"), hint)
    }

    func testFatalLinesFindsFatalAndErrorMarkedLines() {
        let text = "info\nFATAL | boom\nERROR: also boom\ntrailing"
        XCTAssertEqual(EmulatorLog.fatalLines(in: text), ["FATAL | boom", "ERROR: also boom"])
    }

    func testFatalLinesIsEmptyWhenNoneMatch() {
        XCTAssertEqual(EmulatorLog.fatalLines(in: "info\nMetal command buffer error\n"), [])
    }

    /// ログは起動ごとに見出しを付けて追記される。前の起動の FATAL を今回の理由として引かない
    func testFatalLinesLooksOnlyAtTheLastBootSession() {
        let text = """
            === 2026-09-10T19:58:00Z emulator -avd Pixel_9_Android_15_-01
            FATAL | Broken AVD system path
            === 2026-09-11T06:16:00Z emulator -avd Pixel_9_Android_15_-01
            INFO | boot completed
            GLDRendererMetal command buffer completion error
            """
        XCTAssertEqual(EmulatorLog.fatalLines(in: text), [])
        XCTAssertEqual(EmulatorLog.fatalLines(in: text + "\nFATAL | new"), ["FATAL | new"])
    }
}
