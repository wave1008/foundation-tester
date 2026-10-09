// settle: false(SettleOverride.skip)の間は、adb のキー操作の後の整定(settleViaBridge = ブリッジの POST /settle、
// 失敗時は 800ms の固定待ち)を撃たない。back() はキー操作 → settleViaBridge の順なので、その後に adb が
// 呼ばれたか(ブリッジを起こしに行ったか)と所要で見分ける

import FTCore
import XCTest
@testable import FTAndroid

final class AndroidDriverSettleOverrideTests: XCTestCase {
    private var dir: URL!
    private var serial: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-settle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        serial = "fake-\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-android-\(serial!).json"))
    }

    /// キー操作だけ成功し、それ以外(ブリッジの起動・転送)は失敗する adb。呼び出しを1行ずつ記録する
    private func fakeADB() throws -> (path: String, log: URL) {
        let log = dir.appendingPathComponent("calls.log")
        let url = dir.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        case "$*" in *keyevent*) exit 0;; *) exit 1;; esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, log)
    }

    private func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testBackWithSettleFalseDoesNotSettleViaTheBridge() async throws {
        let adb = try fakeADB()
        let driver = AndroidDriver(serial: serial, adbPath: adb.path)
        let start = Date()
        try await SettleOverride.$skip.withValue(true) { try await driver.back() }
        let elapsed = Date().timeIntervalSince(start)
        let made = calls(adb.log)
        XCTAssertEqual(made.count, 1, "キー操作の後にブリッジを起こしに行った: \(made)")
        XCTAssertTrue(made.first?.contains("keyevent") == true, "\(made)")
        XCTAssertLessThan(elapsed, 0.5, "800ms の固定待ちへ落ちた")
    }

    /// 陽性対照: 既定(settle する)ではキー操作の後にブリッジへ整定を頼みに行き、失敗すると固定待ちへ落ちる
    func testBackByDefaultSettlesViaTheBridge() async throws {
        let adb = try fakeADB()
        let driver = AndroidDriver(serial: serial, adbPath: adb.path)
        let start = Date()
        try await driver.back()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(calls(adb.log).count, 1, "キー操作の後にブリッジへ整定を頼んでいない")
        XCTAssertGreaterThanOrEqual(elapsed, 0.8, "整定の失敗時の固定待ち(800ms)を払っていない")
    }
}
