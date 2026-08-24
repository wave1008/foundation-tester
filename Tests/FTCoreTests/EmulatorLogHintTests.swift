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
}
