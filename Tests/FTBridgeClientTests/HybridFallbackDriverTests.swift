// hybrid で「in-app が原理的に不可な操作だけを XCUITest へ回す」振り分けを固定する。
//
// ここが緩むと2種類の事故になる:
//   - 回さなすぎ: MCP の ft_* が in-app エンジンで素の 501 を返す(2026-07-28 に live/MCP を
//     xcuitest 固定にした理由そのもの)
//   - 回しすぎ: **ref を渡してしまい別要素を操作する**(ref はブリッジごとに別名前空間)

import XCTest
import FTCore
@testable import FTBridgeClient

/// 記録用のフェイク。指定した操作だけ任意のエラーを投げる
private final class RecordingDriver: AppDriver, @unchecked Sendable {
    let name: String
    let log: Log
    /// 操作名 → 投げるエラー(nil = 成功)
    var errors: [String: Error] = [:]
    var snapshotResponse = SnapshotResponse(
        sessionBundleID: "com.example.app",
        screen: FTRect(x: 0, y: 0, width: 390, height: 844),
        elements: [
            ElementInfo(ref: 3, type: "button", identifier: "row", label: "行",
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1),
        ],
        truncatedCount: 0)

    final class Log: @unchecked Sendable { var entries: [String] = [] }

    init(name: String, log: Log) {
        self.name = name
        self.log = log
    }

    private func record(_ call: String) throws {
        log.entries.append("\(name).\(call)")
        if let error = errors[call.components(separatedBy: "(")[0]] { throw error }
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: name, osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws { try record("launch") }
    func snapshot() async throws -> SnapshotResponse {
        try record("snapshot")
        return snapshotResponse
    }
    func tap(ref: Int) async throws { try record("tap(ref:\(ref))") }
    func tap(x: Double, y: Double) async throws { try record("tap(x:\(x),y:\(y))") }
    func type(ref: Int?, text: String) async throws {
        try record("type(ref:\(ref.map(String.init) ?? "nil"))")
    }
    func clearInput(ref: Int?) async throws {
        try record("clearInput(ref:\(ref.map(String.init) ?? "nil"))")
    }
    func hideKeyboard() async throws { try record("hideKeyboard") }
    func pressEnter() async throws { try record("pressEnter") }
    func swipe(_ direction: FTSwipeDirection) async throws { try record("swipe") }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        try record("drag")
    }
    func doubleTap(x: Double, y: Double) async throws { try record("doubleTap(x:\(x),y:\(y))") }
    func pinch(frame: FTRect?, identifier: String?, scale: Double,
               durationSeconds: Double) async throws {
        try record("pinch")
    }
    func press(ref: Int, duration: Double) async throws { try record("press(ref:\(ref))") }
    func press(x: Double, y: Double, duration: Double) async throws {
        try record("press(x:\(x),y:\(y))")
    }
    func home() async throws { try record("home") }
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class HybridFallbackDriverTests: XCTestCase {

    private var log: RecordingDriver.Log!
    private var primary: RecordingDriver!
    private var fallback: RecordingDriver!
    private var driver: HybridFallbackDriver!

    private static let notCapable = DriverError.badResponse(
        status: 501, body: "cannot run on the in-app engine")
    /// 一時的競合。**フォールバックしてはいけない**(理由は DriverError.isEngineIncapable)
    private static let conflict = DriverError.badResponse(status: 409, body: "no key window")

    override func setUp() {
        super.setUp()
        log = RecordingDriver.Log()
        primary = RecordingDriver(name: "inapp", log: log)
        fallback = RecordingDriver(name: "xcui", log: log)
        driver = HybridFallbackDriver(primary: primary, fallback: fallback)
    }

    /// 座標・identifier で完結する操作は 501 で回す
    func testCoordinateGesturesFallBackWhenTheEngineCannot() async throws {
        primary.errors = ["doubleTap": Self.notCapable, "pinch": Self.notCapable,
                          "drag": Self.notCapable, "home": Self.notCapable]

        try await driver.doubleTap(x: 1, y: 2)
        try await driver.pinch(frame: nil, identifier: "map", scale: 2, durationSeconds: 0.5)
        try await driver.drag(fromX: 1, fromY: 2, toX: 3, toY: 4,
                              pressSeconds: 0.05, durationSeconds: 1)
        try await driver.home()

        XCTAssertEqual(log.entries, ["inapp.doubleTap(x:1.0,y:2.0)", "xcui.doubleTap(x:1.0,y:2.0)",
                                     "inapp.pinch", "xcui.pinch",
                                     "inapp.drag", "xcui.drag",
                                     "inapp.home", "xcui.home"])
        XCTAssertEqual(driver.lastActionNote, "fell back to XCUITest")
    }

    /// **ref を使う操作は回さない**(別名前空間の ref を渡すと無関係な要素を操作する)
    func testRefBasedOperationsNeverFallBack() async {
        primary.errors = ["tap": Self.notCapable, "type": Self.notCapable,
                          "clearInput": Self.notCapable]

        for operation in [{ try await self.driver.tap(ref: 3) },
                          { try await self.driver.type(ref: 3, text: "x") },
                          { try await self.driver.clearInput(ref: 3) }] {
            do {
                try await operation()
                XCTFail("501 はそのまま伝播するはず")
            } catch {}
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("xcui.") },
                       "ref を使う操作を回してはいけない: \(log.entries)")
    }

    /// ref なし(フォーカス中の要素)は回してよい
    func testFocusBasedOperationsFallBack() async throws {
        primary.errors = ["type": Self.notCapable, "clearInput": Self.notCapable]
        try await driver.type(ref: nil, text: "x")
        try await driver.clearInput(ref: nil)
        XCTAssertEqual(log.entries, ["inapp.type(ref:nil)", "xcui.type(ref:nil)",
                                     "inapp.clearInput(ref:nil)", "xcui.clearInput(ref:nil)"])
    }

    /// 長押しは **ref を渡さず座標へ畳んで**回す(in-app は長押しを持たない)
    func testPressByRefFallsBackThroughCoordinates() async throws {
        primary.errors = ["press": Self.notCapable]
        try await driver.press(ref: 3, duration: 1)
        // 要素 ref=3 は (10,20 100x40) = 中心 (60, 40)
        XCTAssertEqual(log.entries, ["inapp.press(ref:3)", "inapp.snapshot", "xcui.press(x:60.0,y:40.0)"])
        XCTAssertEqual(driver.lastActionNote, "fell back to XCUITest (by coordinates)")
    }

    /// 一時的競合(409)は回さずそのまま返す
    func testTemporaryConflictIsNotAFallbackTrigger() async {
        primary.errors = ["drag": Self.conflict]
        do {
            try await driver.drag(fromX: 1, fromY: 2, toX: 3, toY: 4,
                                  pressSeconds: 0.05, durationSeconds: 1)
            XCTFail("409 はそのまま伝播するはず")
        } catch {}
        XCTAssertEqual(log.entries, ["inapp.drag"])
    }

    /// snapshot は常に primary(ref の名前空間を跨がせない)
    func testSnapshotAlwaysComesFromPrimary() async throws {
        _ = try await driver.snapshot()
        XCTAssertEqual(log.entries, ["inapp.snapshot"])
    }
}
