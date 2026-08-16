// domInterop(Compose/Flutter ホストの WebView)の入力が**届かなかったときに気付く**ことを守る。
//
// この経路の入力は「座標タップでフォーカス → フォーカス中要素へ typeText」なので、
// タップがフォーカスを立て損なうと**打鍵が丸ごと落ちる**(値は空のまま・200 が返る)。
// 実測 2026-08-04: E2E-CMP の WebView シナリオが 4/78 でこれを踏み、後段の検証だけが落ちていた。
//
// **判定は「値が入力前から1文字も変わっていない」ときだけ**。「期待した文字列を含まない」で
// 判定すると、入力を加工するフィールドで二重入力になる(Android の SET_TEXT で踏んだ型)。

import XCTest
import FTCore
@testable import FTBridgeClient

/// domInterop の snapshot を台本で返す primary(in-app 相当)
private final class DOMPrimaryDriver: AppDriver, @unchecked Sendable {
    var scripted: [[ElementInfo]]
    private(set) var snapshotCount = 0
    let log: Log
    final class Log: @unchecked Sendable { var entries: [String] = [] }

    init(scripted: [[ElementInfo]], log: Log) {
        self.scripted = scripted
        self.log = log
    }

    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        log.entries.append("primary.snapshot")
        let elements = scripted[min(snapshotCount - 1, scripted.count - 1)]
        return SnapshotResponse(sessionBundleID: "app",
                                screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                elements: elements, truncatedCount: 0,
                                webViewPath: "dom-interop")
    }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "d", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// XCUITest 側(委譲先)。タップと入力を記録するだけ
private final class DelegatedDriver: AppDriver, @unchecked Sendable {
    let log: DOMPrimaryDriver.Log
    init(log: DOMPrimaryDriver.Log) { self.log = log }

    func tap(x: Double, y: Double) async throws { log.entries.append("delegated.tap(\(x),\(y))") }
    func type(ref: Int?, text: String) async throws {
        log.entries.append("delegated.type(\(text))")
    }
    func snapshot() async throws -> SnapshotResponse {
        log.entries.append("delegated.snapshot")
        return SnapshotResponse(sessionBundleID: "app",
                                screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                elements: [], truncatedCount: 0)
    }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "d", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    func tap(ref: Int) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class WebViewTypeReadbackTests: XCTestCase {

    private func field(value: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: nil, label: nil, value: value,
                    placeholder: "WebView 入力", enabled: true,
                    frame: FTRect(x: 20, y: 200, width: 300, height: 40), depth: 2, web: true)
    }

    /// **値が入力前から変わっていない = 打鍵が落ちた**ので、1回だけ張り直す
    func testRetypesWhenTheValueDidNotChange() async throws {
        let log = DOMPrimaryDriver.Log()
        let primary = DOMPrimaryDriver(scripted: [[field(value: "")], [field(value: "")]], log: log)
        let driver = WebViewDelegatingDriver(primary: primary, delegated: DelegatedDriver(log: log))
        _ = try await driver.snapshot()   // domInterop へ入る

        try await driver.type(ref: 1, text: "hello123")

        XCTAssertEqual(log.entries.filter { $0.hasPrefix("delegated.type") }.count, 2,
                       "値が変わらなければ張り直すこと: \\(log.entries)")
    }

    /// 反映されていれば**張り直さない**(二重入力を作らない)
    func testDoesNotRetypeWhenTheValueChanged() async throws {
        let log = DOMPrimaryDriver.Log()
        let primary = DOMPrimaryDriver(scripted: [[field(value: "")], [field(value: "hello123")]],
                                       log: log)
        let driver = WebViewDelegatingDriver(primary: primary, delegated: DelegatedDriver(log: log))
        _ = try await driver.snapshot()

        try await driver.type(ref: 1, text: "hello123")

        XCTAssertEqual(log.entries.filter { $0.hasPrefix("delegated.type") }.count, 1,
                       "反映されていれば1回だけ: \\(log.entries)")
    }

    /// **加工されて期待どおりでない値でも、変わっていれば張り直さない**
    /// (大文字化・書式化するフィールドで二重入力にしない)
    func testDoesNotRetypeWhenTheFieldTransformsTheInput() async throws {
        let log = DOMPrimaryDriver.Log()
        let primary = DOMPrimaryDriver(scripted: [[field(value: "")], [field(value: "HELLO123")]],
                                       log: log)
        let driver = WebViewDelegatingDriver(primary: primary, delegated: DelegatedDriver(log: log))
        _ = try await driver.snapshot()

        try await driver.type(ref: 1, text: "hello123")

        XCTAssertEqual(log.entries.filter { $0.hasPrefix("delegated.type") }.count, 1,
                       "加工された値でも張り直さないこと: \\(log.entries)")
    }
}
